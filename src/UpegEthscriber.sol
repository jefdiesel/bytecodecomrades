// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title UpegEthscriber
/// @notice Minimal ESIP-3 contract for minting ethscriptions of uPEG unicorns.
///         Emits the canonical event indexers watch for; the unicorn's SVG is
///         passed in as a Data URI from the caller (gallery page constructs it
///         from the on-chain seed). First mint of a given content wins per
///         ethscription uniqueness rules.
contract UpegEthscriber {
    /// @notice ESIP-3 creation event. Recognized by ethscription indexers.
    event ethscriptions_protocol_CreateEthscription(
        address indexed initialOwner,
        string contentURI
    );

    /// @notice Mint an ethscription owned initially by msg.sender.
    /// @param contentURI A valid Data URI, e.g. "data:image/svg+xml;base64,PHN2..."
    function mint(string calldata contentURI) external {
        emit ethscriptions_protocol_CreateEthscription(msg.sender, contentURI);
    }

    /// @notice Mint an ethscription owned initially by `recipient`.
    /// @param recipient The address that becomes the initial owner.
    /// @param contentURI A valid Data URI.
    function mintTo(address recipient, string calldata contentURI) external {
        emit ethscriptions_protocol_CreateEthscription(recipient, contentURI);
    }
}
