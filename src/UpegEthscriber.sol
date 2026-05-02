// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title UpegEthscriber
/// @notice ESIP-3 ethscription minter with a linear bonding curve.
///         price(n) = basePrice + priceStep * n   (n = number of prior successful mints)
///         User calls `mint{value: ≥ currentPrice()}(contentURI)`.
///         Contract emits the canonical ESIP-3 event (ethscription owned by msg.sender),
///         forwards the price to feeRecipient, and refunds any excess. All atomic.
contract UpegEthscriber {
    /// @notice ESIP-3 creation event. Indexers credit the ethscription to `initialOwner`.
    event ethscriptions_protocol_CreateEthscription(
        address indexed initialOwner,
        string contentURI
    );

    address payable public immutable feeRecipient;
    uint256        public immutable basePrice;   // wei
    uint256        public immutable priceStep;   // wei added per prior mint
    uint256        public mintCount;             // bumps on every successful mint

    error InsufficientFee();
    error FeeTransferFailed();
    error RefundFailed();

    constructor(
        address payable feeRecipient_,
        uint256 basePrice_,
        uint256 priceStep_
    ) {
        require(feeRecipient_ != address(0), "feeRecipient=0");
        feeRecipient = feeRecipient_;
        basePrice    = basePrice_;
        priceStep    = priceStep_;
    }

    /// @notice Current price in wei. Reads cleanly from the page before signing.
    function currentPrice() public view returns (uint256) {
        return basePrice + priceStep * mintCount;
    }

    /// @notice Mint an ethscription owned by msg.sender at `currentPrice()`.
    function mint(string calldata contentURI) external payable {
        _mint(msg.sender, contentURI);
    }

    /// @notice Mint to a different recipient at `currentPrice()`.
    function mintTo(address recipient, string calldata contentURI) external payable {
        _mint(recipient, contentURI);
    }

    function _mint(address recipient, string calldata contentURI) internal {
        uint256 price = currentPrice();
        if (msg.value < price) revert InsufficientFee();

        unchecked { ++mintCount; }
        emit ethscriptions_protocol_CreateEthscription(recipient, contentURI);

        (bool ok, ) = feeRecipient.call{value: price}("");
        if (!ok) revert FeeTransferFailed();

        uint256 excess = msg.value - price;
        if (excess > 0) {
            (bool refundOk, ) = payable(msg.sender).call{value: excess}("");
            if (!refundOk) revert RefundFailed();
        }
    }
}
