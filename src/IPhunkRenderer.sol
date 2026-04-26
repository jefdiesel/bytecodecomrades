// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPhunkRenderer {
    /// @notice Render the on-chain SVG for a seed at a given holder tier.
    function renderSVG(bytes32 seed, uint256 holderPhunkCount) external view returns (string memory);

    /// @notice Build the data:application/json;base64,... metadata blob.
    /// @param holderPhunkCount  Number of Phunks the current holder owns;
    ///        determines which trait pool the seed picks from.
    function tokenURI(uint256 id, bytes32 seed, uint256 holderPhunkCount) external view returns (string memory);
}
