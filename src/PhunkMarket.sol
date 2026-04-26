// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721}   from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {IERC20Min} from "./IERC20Min.sol";

/// @notice Minimal on-chain marketplace for PhunkRare ERC-721s, priced in PHUNK.
/// - Sellers list with `list(tokenId, price)` after approving the market for transfers.
/// - Buyers pay in PHUNK via `buy(tokenId)` after approving the market to spend.
/// - A configurable fee (in basis points) goes to feeRecipient.
///
/// Bids/auctions are intentionally not implemented in this version. Add a
/// successor market contract later if you want them — both can coexist
/// because the rare is transferable to either market.
contract PhunkMarket {
    IERC721  public immutable rareNft;
    IERC20Min public immutable phunkToken;

    address public owner;
    address public feeRecipient;
    uint16  public feeBps; // 0..1000 = 0..10%
    bool    public paused;

    struct Listing {
        address seller;
        uint256 price; // in PHUNK wei
    }

    mapping(uint256 => Listing) public listings;

    event Listed(uint256 indexed tokenId, address indexed seller, uint256 price);
    event Cancelled(uint256 indexed tokenId, address indexed seller);
    event Sold(uint256 indexed tokenId, address indexed seller, address indexed buyer, uint256 price, uint256 fee);
    event FeeUpdated(uint16 feeBps, address recipient);
    event PauseUpdated(bool paused);

    error NotOwner();
    error NotSeller();
    error NotApproved();
    error NotListed();
    error AlreadyListed();
    error Paused();
    error FeeTooHigh();
    error ZeroPrice();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    constructor(IERC721 _rareNft, IERC20Min _phunkToken, address _feeRecipient, uint16 _feeBps) {
        if (_feeBps > 1000) revert FeeTooHigh();
        rareNft      = _rareNft;
        phunkToken   = _phunkToken;
        owner        = msg.sender;
        feeRecipient = _feeRecipient;
        feeBps       = _feeBps;
    }

    // -------- admin --------

    function setFee(uint16 bps, address recipient) external onlyOwner {
        if (bps > 1000) revert FeeTooHigh();
        feeBps = bps;
        feeRecipient = recipient;
        emit FeeUpdated(bps, recipient);
    }

    function setPaused(bool p) external onlyOwner {
        paused = p;
        emit PauseUpdated(p);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
    }

    // -------- core --------

    /// @notice List a PhunkRare for sale at a fixed PHUNK price.
    /// Seller must have approved this contract for the token (approve or setApprovalForAll).
    function list(uint256 tokenId, uint256 price) external whenNotPaused {
        if (price == 0) revert ZeroPrice();
        if (rareNft.ownerOf(tokenId) != msg.sender) revert NotSeller();
        if (!_isApproved(msg.sender, tokenId)) revert NotApproved();
        if (listings[tokenId].seller != address(0)) revert AlreadyListed();

        listings[tokenId] = Listing({seller: msg.sender, price: price});
        emit Listed(tokenId, msg.sender, price);
    }

    /// @notice Cancel a listing. Only the seller (or current owner if seller transferred away) can cancel.
    function cancelListing(uint256 tokenId) external {
        Listing memory l = listings[tokenId];
        if (l.seller == address(0)) revert NotListed();
        // Allow seller OR current owner to cancel (handles the case where the rare moved).
        if (msg.sender != l.seller && msg.sender != rareNft.ownerOf(tokenId)) revert NotSeller();
        delete listings[tokenId];
        emit Cancelled(tokenId, l.seller);
    }

    /// @notice Buy a listed rare. Buyer must have approved this contract to spend
    /// at least `price` PHUNK. The rare is transferred from seller to buyer.
    function buy(uint256 tokenId) external whenNotPaused {
        Listing memory l = listings[tokenId];
        if (l.seller == address(0)) revert NotListed();
        // Re-check approval & ownership at buy time
        address currentOwner = rareNft.ownerOf(tokenId);
        if (currentOwner != l.seller) revert NotSeller(); // seller moved the rare out
        if (!_isApproved(l.seller, tokenId)) revert NotApproved();

        uint256 fee   = (l.price * feeBps) / 10000;
        uint256 paid  = l.price - fee;

        delete listings[tokenId];

        // Pull buyer's PHUNK
        require(phunkToken.transferFrom(msg.sender, l.seller, paid), "phunk to seller");
        if (fee > 0 && feeRecipient != address(0)) {
            require(phunkToken.transferFrom(msg.sender, feeRecipient, fee), "phunk fee");
        }

        // Transfer rare from seller to buyer
        rareNft.transferFrom(l.seller, msg.sender, tokenId);

        emit Sold(tokenId, l.seller, msg.sender, l.price, fee);
    }

    // -------- view helpers --------

    function isListed(uint256 tokenId) external view returns (bool) {
        return listings[tokenId].seller != address(0);
    }

    function priceOf(uint256 tokenId) external view returns (uint256) {
        return listings[tokenId].price;
    }

    // -------- internals --------

    function _isApproved(address holder, uint256 tokenId) internal view returns (bool) {
        return rareNft.isApprovedForAll(holder, address(this))
            || rareNft.getApproved(tokenId) == address(this);
    }
}
