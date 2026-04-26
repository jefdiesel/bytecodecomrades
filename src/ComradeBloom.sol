// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ComradeBloomChunk0} from "./ComradeBloomChunk0.sol";
import {ComradeBloomChunk1} from "./ComradeBloomChunk1.sol";

interface IBloomChunk {
    function data() external pure returns (bytes memory);
}

/// @notice Bloom filter over the 5841 CDC+CRC visual fingerprints.
/// 262144-bit (32 KB) filter, k=14 hash functions, theoretical FPR ~1.5e-5.
///
/// Fingerprint format = keccak256(packed_bigendian_uint16(sorted_sprite_ids))
contract ComradeBloom {
    uint256 public constant M_BITS = 262144;
    uint256 public constant M_BYTES = 32768;
    uint8 public constant K = 14;
    uint256 public constant CHUNK_BYTES = 16384;

    address public immutable chunk0;
    address public immutable chunk1;

    constructor() {
        chunk0 = address(new ComradeBloomChunk0());
        chunk1 = address(new ComradeBloomChunk1());
    }

    /// @notice Compute the canonical fingerprint of a list of sprite ids
    /// (the same format Python uses to populate the bloom).
    function fingerprintOf(uint16[] memory ids) public pure returns (bytes32) {
        // Sort ascending in place (insertion sort — small N)
        for (uint256 i = 1; i < ids.length; i++) {
            uint16 v = ids[i];
            uint256 j = i;
            while (j > 0 && ids[j-1] > v) {
                ids[j] = ids[j-1];
                j--;
            }
            ids[j] = v;
        }
        bytes memory packed = new bytes(ids.length * 2);
        for (uint256 i = 0; i < ids.length; i++) {
            packed[i*2]     = bytes1(uint8(ids[i] >> 8));
            packed[i*2 + 1] = bytes1(uint8(ids[i] & 0xff));
        }
        return keccak256(packed);
    }

    /// @notice Test whether a fingerprint *might* be in the CDC+CRC set.
    /// Returns false: definitely NOT in set.
    /// Returns true:  probably in set (FPR ~1.5e-5).
    function mightContain(bytes32 fp) public view returns (bool) {
        bytes memory c0 = IBloomChunk(chunk0).data();
        bytes memory c1 = IBloomChunk(chunk1).data();
        uint256 bits = uint256(fp);
        for (uint8 i = 0; i < K; i++) {
            uint256 shift = 256 - (uint256(i) + 1) * 18;
            uint256 pos = (bits >> shift) & 0x3ffff;  // 18 bits
            uint256 byteIdx = pos >> 3;
            uint256 bitIdx  = pos & 7;
            uint8 b = byteIdx < CHUNK_BYTES
                ? uint8(c0[byteIdx])
                : uint8(c1[byteIdx - CHUNK_BYTES]);
            if ((b & (1 << bitIdx)) == 0) return false;
        }
        return true;
    }

    /// @notice Convenience: check by sprite-id list directly.
    function mightContainPick(uint16[] memory ids) external view returns (bool) {
        return mightContain(fingerprintOf(ids));
    }
}
