// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IComradeBloom {
    function fingerprintOf(uint16[] memory ids) external pure returns (bytes32);
    function mightContain(bytes32 fp) external view returns (bool);
    function mightContainPick(uint16[] memory ids) external view returns (bool);
}
