// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title UpegEthscriberOnChain
/// @notice ESIP-3 ethscription minter that builds the AppChain collection
///         Data URI on-chain so user calldata stays tiny (~64 bytes).
///         Necessary because Phantom-EVM rejects mint(string) calls with
///         large string args (returns -32603 "Unexpected error" client-side).
///
///         User calls mint(upegId, seed) with msg.value >= currentPrice().
///         Contract reads SVG via staticcall to the uPEG hook, builds the
///         add_self_to_collection Data URI in memory, emits the ESIP-3 event
///         with msg.sender as initialOwner. Fee forwarded atomically; refund
///         on overpay.
contract UpegEthscriberOnChain {
    using Strings for uint256;

    event ethscriptions_protocol_CreateEthscription(
        address indexed initialOwner,
        string contentURI
    );

    address payable public immutable feeRecipient;
    uint256        public immutable basePrice;
    uint256        public immutable priceStep;
    address        public immutable upegHook;       // SvgGenerator (has generate(uint256))
    string         public           collectionId;   // 0x... lowercase hex

    uint256 public mintCount;

    error InsufficientFee();
    error FeeTransferFailed();
    error RefundFailed();
    error SvgGenerateFailed();

    constructor(
        address payable feeRecipient_,
        uint256 basePrice_,
        uint256 priceStep_,
        address upegHook_,
        string memory collectionId_
    ) {
        require(feeRecipient_ != address(0), "feeRecipient=0");
        require(upegHook_ != address(0), "upegHook=0");
        require(bytes(collectionId_).length == 66, "collectionId must be 0x + 64 hex chars");
        feeRecipient = feeRecipient_;
        basePrice = basePrice_;
        priceStep = priceStep_;
        upegHook = upegHook_;
        collectionId = collectionId_;
    }

    function currentPrice() public view returns (uint256) {
        return basePrice + priceStep * mintCount;
    }

    /// @notice Mint a uPEG unicorn ethscription into the collection.
    /// @param upegId The on-chain uPEG ID (e.g. 19125)
    /// @param seed   The on-chain seed for that ID (read from token contract storage)
    function mint(uint256 upegId, uint256 seed) external payable {
        uint256 price = currentPrice();
        if (msg.value < price) revert InsufficientFee();
        unchecked { ++mintCount; }

        // Fetch SVG from the uPEG hook
        (bool ok, bytes memory ret) = upegHook.staticcall(
            abi.encodeWithSignature("generate(uint256)", seed)
        );
        if (!ok) revert SvgGenerateFailed();
        string memory svg = abi.decode(ret, (string));

        // Build JSON payload (key order MUST match parser spec exactly).
        // item_index and max_supply MUST be strings per spec, not numbers.
        string memory upegIdStr = upegId.toString();
        string memory seedStr   = seed.toString();
        bytes memory jsonBytes = abi.encodePacked(
            '{"collection_id":"', collectionId,
            '","item":{"item_index":"', upegIdStr,
            '","name":"uPEG #', upegIdStr,
            '","background_color":"0b0c10"',
            ',"description":"uPEG unicorn #', upegIdStr,
            '. On-chain SVG, deterministic from seed."',
            ',"attributes":[{"trait_type":"upeg_id","value":"', upegIdStr,
            '"},{"trait_type":"seed","value":"', seedStr,
            '"}],"merkle_proof":[]}}'
        );

        // Build the header-form Data URI.
        // rule=esip6 is MANDATORY — without it, the AppChain system contract
        // skips the protocol handler and creates a plain ethscription instead.
        string memory dataURI = string.concat(
            "data:image/svg+xml;rule=esip6;p=erc-721-ethscriptions-collection;op=add_self_to_collection;d=",
            Base64.encode(jsonBytes),
            ";base64,",
            Base64.encode(bytes(svg))
        );

        emit ethscriptions_protocol_CreateEthscription(msg.sender, dataURI);

        // Forward fee atomically
        (bool feeOk, ) = feeRecipient.call{value: price}("");
        if (!feeOk) revert FeeTransferFailed();

        // Refund excess
        uint256 excess = msg.value - price;
        if (excess > 0) {
            (bool refundOk, ) = payable(msg.sender).call{value: excess}("");
            if (!refundOk) revert RefundFailed();
        }
    }
}
