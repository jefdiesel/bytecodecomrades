#!/usr/bin/env python3
"""
Build a bloom filter of all CDC + CRC visual fingerprints, encoded for
on-chain dedup. The fingerprint is the keccak256 of sorted sprite IDs
(matching what ComradeRenderer can compute from a pick result).

Layout:
  m = 2**18 bits = 262144 bits = 32 KB
  k = 14 hash functions (one keccak256 of fp gives 14 x 18-bit positions)
  Expected FPR with n=11253: ~1.5e-5

Output:
  data/bloom.bin                    — raw 32 KB bloom filter
  src/ComradeBloomChunk{0,1}.sol    — bytes constants holding halves of the filter
  src/ComradeBloom.sol              — reader contract, exposes mightContain(bytes32)
"""
import hashlib
import json
import os

OUT_DIR = os.path.dirname(os.path.abspath(__file__))
SRC_DIR = os.path.join(os.path.dirname(OUT_DIR), "src")

VISUAL = {"Background","Type","Cloths","Head","Audio Indexer Derivations",
          "Mouth","Eyes","Skin Stuff","Accessories","Relics"}

# m = 2^18, k = 14 (each requires log2(m) = 18 bits, 14 * 18 = 252 fits in 256-bit keccak)
M_BITS = 1 << 18
M_BYTES = M_BITS // 8
K = 14

# Folder name per category (matches encode_sprites.py)
FOLDER = {
    "Relics":                    "01_Relics",
    "Eyes":                      "02_Eyes",
    "Mouth":                     "03_Mouth",
    "Audio Indexer Derivations": "04_Audio Indexer Derivations",
    "Head":                      "05_Head",
    "Cloths":                    "06_Cloths",
    "Skin Stuff":                "07_Skin Stuff",
    "Type":                      "08_Type",
    "Background":                "10_Backgrounds",
}


def build_sprite_id_map():
    """Return {(folder_name, sprite_name): global_sprite_id}."""
    sprite_table = json.load(open(os.path.join(OUT_DIR, "sprite_table.json")))
    sid_map = {}
    sid = 0
    for cat_folder, entries in sprite_table.items():
        for e in entries:
            sid_map[(cat_folder, e["name"])] = sid
            sid += 1
    return sid_map


def fingerprint(sprite_ids):
    """keccak256(abi.encode(sorted_uint16_ids)). Simple, on-chain reproducible."""
    sorted_ids = sorted(sprite_ids)
    # Mirror Solidity abi.encode for uint16[]:
    # offset (32 bytes) + length (32 bytes) + ids each padded to 32 bytes
    # But for simplicity we'll use abi.encodePacked equivalent: just concat 2-byte big-endian.
    # The Solidity side will use the same packed encoding.
    payload = b""
    for sid in sorted_ids:
        payload += sid.to_bytes(2, "big")
    # keccak256 in Python — use sha3 module via hashlib (Python 3.6+)
    import hashlib
    h = hashlib.new("sha3_256")
    # hashlib's sha3_256 is FIPS SHA3, which differs from Ethereum's keccak256.
    # For matching keccak256 on-chain we need the eth_utils style. Use pycryptodome if available, else use sha256 fallback.
    try:
        from Crypto.Hash import keccak
        k = keccak.new(digest_bits=256)
        k.update(payload)
        return k.digest()
    except ImportError:
        # Fallback: implement keccak256 inline (small)
        return _keccak256(payload)


# Minimal keccak256 (for fallback if pycryptodome isn't installed)
def _keccak256(data: bytes) -> bytes:
    # Use eth-hash/sha3 equivalent via the keccak256 of pysha3 if avail
    try:
        import sha3
        k = sha3.keccak_256()
        k.update(data)
        return k.digest()
    except ImportError:
        raise RuntimeError("Need pycryptodome OR pysha3 installed: pip install pycryptodome")


def hash_to_positions(fp):
    """Derive 14 x 18-bit positions directly from the fingerprint bits.
    Matches Solidity's `bits = uint256(fp)` then bit-slicing — no extra hash.
    """
    bits = int.from_bytes(fp, "big")
    positions = []
    for i in range(K):
        shift = 256 - (i + 1) * 18
        pos = (bits >> shift) & ((1 << 18) - 1)
        positions.append(pos)
    return positions


def main():
    sid_map = build_sprite_id_map()

    # Load CDC + CRC items, map to sprite ID lists
    items = []
    for path in ["cdc_items.jsonl", "crc_items.jsonl"]:
        with open(os.path.join(OUT_DIR, path)) as f:
            for line in f:
                items.append(json.loads(line))
    print(f"loaded {len(items)} items")

    # Build per-item fingerprint (sprite_ids only)
    fps = []
    skipped = 0
    for it in items:
        sid_list = []
        ok = True
        for a in it.get("attrs", []):
            cat = a["trait_type"]
            val = a["value"]
            if cat not in VISUAL:
                continue
            # Skip JSON-list multi-value attrs (CDC has a few)
            if isinstance(val, list) or (isinstance(val, str) and val.startswith("[")):
                ok = False
                break
            folder = FOLDER.get(cat)
            if folder is None:
                continue
            sid = sid_map.get((folder, val))
            if sid is None:
                # Value has no sprite file (broken filename, animated, etc.)
                # We CAN'T generate this combo so it's safe to skip the entire item.
                ok = False
                break
            sid_list.append(sid)
        if not ok or not sid_list:
            skipped += 1
            continue
        fps.append(fingerprint(sid_list))

    print(f"computed {len(fps)} fingerprints, {skipped} items skipped (had unmappable values)")

    # Build the bloom filter
    bloom = bytearray(M_BYTES)  # 32 KB of zeros
    for fp in fps:
        for pos in hash_to_positions(fp):
            byte_idx = pos // 8
            bit_idx  = pos % 8
            bloom[byte_idx] |= (1 << bit_idx)

    set_bits = sum(bin(b).count("1") for b in bloom)
    print(f"bloom: {len(bloom)} bytes, {set_bits} bits set ({set_bits/M_BITS*100:.2f}% fill)")
    print(f"theoretical FPR: ~{(set_bits/M_BITS)**K:.2e}")

    # Save raw + emit Solidity contracts
    open(os.path.join(OUT_DIR, "bloom.bin"), "wb").write(bytes(bloom))

    # Split into 2 chunks of 16 KB each
    chunk_size = M_BYTES // 2
    chunks = [bytes(bloom[:chunk_size]), bytes(bloom[chunk_size:])]
    for i, c in enumerate(chunks):
        sol = f"""// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Bloom filter chunk {i} of {len(chunks)} (CDC+CRC dedup).
/// Concatenate Chunk0.data + Chunk1.data to reconstruct the full {M_BYTES}-byte filter.
contract ComradeBloomChunk{i} {{
    bytes public constant data = hex"{c.hex()}";
}}
"""
        open(os.path.join(SRC_DIR, f"ComradeBloomChunk{i}.sol"), "w").write(sol)
        print(f"  wrote ComradeBloomChunk{i}.sol ({len(c)} bytes)")

    # ComradeBloom reader
    sol = f"""// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {{ComradeBloomChunk0}} from "./ComradeBloomChunk0.sol";
import {{ComradeBloomChunk1}} from "./ComradeBloomChunk1.sol";

interface IBloomChunk {{
    function data() external pure returns (bytes memory);
}}

/// @notice Bloom filter over the {len(fps)} CDC+CRC visual fingerprints.
/// {M_BITS}-bit (32 KB) filter, k={K} hash functions, theoretical FPR ~1.5e-5.
///
/// Fingerprint format = keccak256(packed_bigendian_uint16(sorted_sprite_ids))
contract ComradeBloom {{
    uint256 public constant M_BITS = {M_BITS};
    uint256 public constant M_BYTES = {M_BYTES};
    uint8 public constant K = {K};
    uint256 public constant CHUNK_BYTES = {chunk_size};

    address public immutable chunk0;
    address public immutable chunk1;

    constructor() {{
        chunk0 = address(new ComradeBloomChunk0());
        chunk1 = address(new ComradeBloomChunk1());
    }}

    /// @notice Compute the canonical fingerprint of a list of sprite ids
    /// (the same format Python uses to populate the bloom).
    function fingerprintOf(uint16[] memory ids) public pure returns (bytes32) {{
        // Sort ascending in place (insertion sort — small N)
        for (uint256 i = 1; i < ids.length; i++) {{
            uint16 v = ids[i];
            uint256 j = i;
            while (j > 0 && ids[j-1] > v) {{
                ids[j] = ids[j-1];
                j--;
            }}
            ids[j] = v;
        }}
        bytes memory packed = new bytes(ids.length * 2);
        for (uint256 i = 0; i < ids.length; i++) {{
            packed[i*2]     = bytes1(uint8(ids[i] >> 8));
            packed[i*2 + 1] = bytes1(uint8(ids[i] & 0xff));
        }}
        return keccak256(packed);
    }}

    /// @notice Test whether a fingerprint *might* be in the CDC+CRC set.
    /// Returns false: definitely NOT in set.
    /// Returns true:  probably in set (FPR ~1.5e-5).
    function mightContain(bytes32 fp) public view returns (bool) {{
        bytes memory c0 = IBloomChunk(chunk0).data();
        bytes memory c1 = IBloomChunk(chunk1).data();
        uint256 bits = uint256(fp);
        for (uint8 i = 0; i < K; i++) {{
            uint256 shift = 256 - (uint256(i) + 1) * 18;
            uint256 pos = (bits >> shift) & 0x3ffff;  // 18 bits
            uint256 byteIdx = pos >> 3;
            uint256 bitIdx  = pos & 7;
            uint8 b = byteIdx < CHUNK_BYTES
                ? uint8(c0[byteIdx])
                : uint8(c1[byteIdx - CHUNK_BYTES]);
            if ((b & (1 << bitIdx)) == 0) return false;
        }}
        return true;
    }}

    /// @notice Convenience: check by sprite-id list directly.
    function mightContainPick(uint16[] memory ids) external view returns (bool) {{
        return mightContain(fingerprintOf(ids));
    }}
}}
"""
    open(os.path.join(SRC_DIR, "ComradeBloom.sol"), "w").write(sol)
    print(f"\nwrote ComradeBloom.sol")
    print(f"\nSummary:")
    print(f"  fingerprints loaded: {len(fps)}")
    print(f"  filter size:         {M_BYTES} bytes ({M_BITS} bits)")
    print(f"  hash functions:      k={K}")
    print(f"  fill rate:           {set_bits/M_BITS*100:.2f}%")
    print(f"  expected FPR:        {(set_bits/M_BITS)**K:.2e}")


if __name__ == "__main__":
    main()
