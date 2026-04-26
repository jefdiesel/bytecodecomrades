#!/usr/bin/env python3
"""Generate src/PhunkSpriteData.sol from data/palette.hex + data/assets.json."""
import json
import os

OUT_DIR = os.path.dirname(os.path.abspath(__file__))
SRC_DIR = os.path.join(os.path.dirname(OUT_DIR), "src")

palette = open(os.path.join(OUT_DIR, "palette.hex")).read().strip()
assets  = json.load(open(os.path.join(OUT_DIR, "assets.json")))

max_idx = max(int(k) for k in assets)
n = max_idx + 1

# Build sprite blob + offset/length pairs (4 bytes per entry: 2 offset + 2 length, big-endian)
sprite_parts = []
sprite_offsets = bytearray()
cur = 0
for i in range(n):
    hx = assets.get(str(i), {}).get("hex", "")
    sprite_parts.append(hx)
    length = len(hx) // 2
    sprite_offsets += cur.to_bytes(2, "big")
    sprite_offsets += length.to_bytes(2, "big")
    cur += length
sprite_blob = "".join(sprite_parts)

# Build name blob + offset/length pairs (same encoding)
name_parts = []
name_offsets = bytearray()
cur = 0
for i in range(n):
    nm = assets.get(str(i), {}).get("name", "")
    nm_bytes = nm.encode("utf-8")
    name_parts.append(nm_bytes.hex())
    length = len(nm_bytes)
    name_offsets += cur.to_bytes(2, "big")
    name_offsets += length.to_bytes(2, "big")
    cur += length
name_blob = "".join(name_parts)

print(f"palette:       {len(palette)//2:5d} bytes")
print(f"sprite blob:   {len(sprite_blob)//2:5d} bytes")
print(f"sprite offsets:{len(sprite_offsets):5d} bytes  ({n} entries)")
print(f"name blob:     {len(name_blob)//2:5d} bytes")
print(f"name offsets:  {len(name_offsets):5d} bytes  ({n} entries)")

sol = f"""// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Canonical CryptoPunks sprite + name data extracted from
/// 0x16F5A35647D6F03D5D3da7b35409D65ba03aF3B2 (CryptopunksData on mainnet).
/// CC0 — original art and trait names by Larva Labs.
contract PhunkSpriteData {{
    /// @dev RGBA palette: 120 colors x 4 bytes
    bytes public constant palette = hex"{palette}";

    /// @dev Concatenated sprite bytes for indices 0..{max_idx}
    bytes public constant assetData = hex"{sprite_blob}";

    /// @dev Packed (offset, length) pairs, 4 bytes per entry, for assetData
    bytes public constant assetTable = hex"{sprite_offsets.hex()}";

    /// @dev Concatenated UTF-8 name bytes for indices 0..{max_idx}
    bytes public constant nameData = hex"{name_blob}";

    /// @dev Packed (offset, length) pairs, 4 bytes per entry, for nameData
    bytes public constant nameTable = hex"{name_offsets.hex()}";

    uint256 public constant ASSET_COUNT = {n};

    function _readU16(bytes memory b, uint256 off) internal pure returns (uint16) {{
        return (uint16(uint8(b[off])) << 8) | uint16(uint8(b[off + 1]));
    }}

    function assetOffset(uint256 i) public pure returns (uint16) {{
        return _readU16(assetTable, i * 4);
    }}

    function assetLength(uint256 i) public pure returns (uint16) {{
        return _readU16(assetTable, i * 4 + 2);
    }}

    /// @notice Sprite bytes for asset index i.
    function asset(uint256 i) external pure returns (bytes memory out) {{
        uint16 off = assetOffset(i);
        uint16 len = assetLength(i);
        out = new bytes(len);
        bytes memory blob = assetData;
        for (uint256 k = 0; k < len; k++) {{
            out[k] = blob[off + k];
        }}
    }}

    /// @notice Human-readable name for asset index i (e.g. "Wild Hair").
    function assetName(uint256 i) external pure returns (string memory) {{
        uint16 off = _readU16(nameTable, i * 4);
        uint16 len = _readU16(nameTable, i * 4 + 2);
        bytes memory result = new bytes(len);
        bytes memory blob = nameData;
        for (uint256 k = 0; k < len; k++) {{
            result[k] = blob[off + k];
        }}
        return string(result);
    }}

    /// @notice Lookup an RGBA color from the palette.
    function color(uint256 idx) external pure returns (bytes4) {{
        bytes memory p = palette;
        uint256 b = idx * 4;
        return bytes4(uint32(uint8(p[b])) << 24 | uint32(uint8(p[b+1])) << 16 | uint32(uint8(p[b+2])) << 8 | uint32(uint8(p[b+3])));
    }}
}}
"""

out_path = os.path.join(SRC_DIR, "PhunkSpriteData.sol")
open(out_path, "w").write(sol)
print(f"wrote {out_path} ({len(sol)} chars)")
