// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IComradeRenderer {
    function tokenURI(uint256 id, bytes32 seed) external view returns (string memory);
    function renderFromSeed(bytes32 seed) external view returns (string memory);
    function pick(bytes32 seed) external view returns (uint16[] memory);
}
