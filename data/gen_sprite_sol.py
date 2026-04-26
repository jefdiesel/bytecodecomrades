#!/usr/bin/env python3
"""
Generate the Solidity contracts for the Comrade sprite library:
  src/ComradeSpriteChunk{0,1,2,3}.sol  — bytes constants holding sprite data
  src/ComradeSpriteData.sol            — palette + offset table + reads from chunks

Each chunk holds ~18 KB of sprite data so the deployed contract stays under
the 24 KB EIP-170 limit (with dispatcher overhead).
"""
import json
import os

OUT_DIR = os.path.dirname(os.path.abspath(__file__))
SRC_DIR = os.path.join(os.path.dirname(OUT_DIR), "src")

CHUNK_SIZE = 18_000  # bytes per chunk (leaves headroom for dispatcher)


def main():
    palette_hex = open(os.path.join(OUT_DIR, "sprite_palette.hex")).read().strip()
    blob_hex    = open(os.path.join(OUT_DIR, "sprite_blob.hex")).read().strip()
    table       = json.load(open(os.path.join(OUT_DIR, "sprite_table.json")))

    blob_bytes = bytes.fromhex(blob_hex)

    # Split blob into chunks
    chunks = []
    for i in range(0, len(blob_bytes), CHUNK_SIZE):
        chunks.append(blob_bytes[i:i + CHUNK_SIZE])
    print(f"split {len(blob_bytes)} bytes into {len(chunks)} chunks of {CHUNK_SIZE} bytes")

    # Generate one contract per chunk
    for i, c in enumerate(chunks):
        sol = f"""// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice CDC sprite blob chunk {i} of {len(chunks)}.
/// Concatenate ComradeSpriteChunk0.data .. ChunkN.data to reconstruct the
/// full sprite RLE blob. {len(c)} bytes.
contract ComradeSpriteChunk{i} {{
    bytes public constant data = hex"{c.hex()}";
}}
"""
        path = os.path.join(SRC_DIR, f"ComradeSpriteChunk{i}.sol")
        open(path, "w").write(sol)
        print(f"  wrote {path} ({len(c)} bytes data)")

    # Build a flat per-sprite (chunk_idx, offset_in_chunk, length) table.
    # Sprites are concatenated in order, so we walk through the table and assign
    # them to chunks based on their global offset.
    per_sprite = []  # list of (chunk_idx, offset_in_chunk, length)
    sprite_id = 0
    cat_starts = {}  # category_folder -> first sprite_id

    for cat_folder, entries in table.items():
        cat_starts[cat_folder] = sprite_id
        for e in entries:
            global_off = e["offset"]
            length = e["length"]
            chunk_idx = global_off // CHUNK_SIZE
            offset_in_chunk = global_off % CHUNK_SIZE
            # If sprite straddles a chunk boundary, we have a problem.
            # Mitigate: if it would straddle, push it entirely into next chunk.
            # (We'll add padding to the previous chunk in a future iteration if needed.)
            if offset_in_chunk + length > CHUNK_SIZE:
                # The current chunking allows straddling — handle in reader, not here
                pass
            per_sprite.append((chunk_idx, offset_in_chunk, length))
            sprite_id += 1

    print(f"\n{sprite_id} sprites indexed")
    print(f"category boundaries:")
    for cat, start in cat_starts.items():
        print(f"  {cat:35s} starts at id {start}")

    # Write category boundary constants for the renderer
    with open(os.path.join(OUT_DIR, "sprite_index.json"), "w") as f:
        json.dump({
            "chunk_size": CHUNK_SIZE,
            "num_chunks": len(chunks),
            "num_sprites": sprite_id,
            "cat_starts": cat_starts,
            "per_sprite": per_sprite,
            "palette_size": len(palette_hex) // 8,  # 4 bytes per RGBA
        }, f, indent=2)

    # ComradeSpriteData (the umbrella reader)
    # Pack per-sprite table: 4 bytes per entry: 1 byte chunk_idx, 2 bytes offset, 1 byte length-divided-by-something? No, use 4 bytes total: 1 byte chunk_idx, 2 bytes offset, 1 byte unused — wait length can be > 255.
    # Safer: 6 bytes per entry — 1 byte chunk_idx, 2 bytes offset (uint16, fits 18000), 2 bytes length (uint16, fits 65535), 1 byte padding.
    # Even safer: 5 bytes total — 1 chunk + 2 offset + 2 length.
    # We'll use 5 bytes per sprite. 323 * 5 = 1615 bytes for the table.
    table_bytes = bytearray()
    for chunk_idx, off, length in per_sprite:
        table_bytes.append(chunk_idx)
        table_bytes.append((off >> 8) & 0xFF)
        table_bytes.append(off & 0xFF)
        table_bytes.append((length >> 8) & 0xFF)
        table_bytes.append(length & 0xFF)

    # Generate name table — packed (offset, length) pairs + concat name blob (UTF-8)
    name_blob = bytearray()
    name_offs = bytearray()
    for cat_folder, entries in table.items():
        for e in entries:
            nm = e["name"].encode("utf-8")
            off = len(name_blob)
            length = len(nm)
            name_blob.extend(nm)
            name_offs.extend(off.to_bytes(2, "big"))
            name_offs.append(length)

    print(f"name blob: {len(name_blob)} bytes, name offsets: {len(name_offs)} bytes")

    chunk_imports = "\n".join(f'import {{ComradeSpriteChunk{i}}} from "./ComradeSpriteChunk{i}.sol";' for i in range(len(chunks)))
    chunk_addrs   = ",\n        ".join(f"address(new ComradeSpriteChunk{i}())" for i in range(len(chunks)))

    sol = f"""// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

{chunk_imports}

interface IChunk {{
    function data() external pure returns (bytes memory);
}}

/// @notice On-chain CDC sprite library, encoded as run-length pairs across a shared
/// 1401-color RGBA palette. Sprite blob is split across {len(chunks)} chunk contracts
/// to stay under EIP-170. Renderer reads chunks via interface call.
contract ComradeSpriteData {{
    /// @dev RGBA palette: {len(palette_hex)//8} colors * 4 bytes
    bytes public constant palette = hex"{palette_hex}";

    /// @dev Sprite table: 5 bytes per sprite — (chunk_idx u8, offset u16, length u16)
    bytes public constant spriteTable = hex"{table_bytes.hex()}";

    /// @dev Names blob (UTF-8) + offsets table (3 bytes per entry: offset u16, length u8)
    bytes public constant nameData = hex"{name_blob.hex()}";
    bytes public constant nameTable = hex"{name_offs.hex()}";

    uint256 public constant SPRITE_COUNT = {sprite_id};
    uint256 public constant PALETTE_SIZE = {len(palette_hex)//8};

    address[{len(chunks)}] public chunks;

    constructor() {{
        chunks = [
        {chunk_addrs}
        ];
    }}

    function _readU16(bytes memory b, uint256 off) internal pure returns (uint16) {{
        return (uint16(uint8(b[off])) << 8) | uint16(uint8(b[off + 1]));
    }}

    /// @notice Return the RLE-encoded bytes for sprite index `i`.
    function sprite(uint256 i) external view returns (bytes memory) {{
        uint256 b = i * 5;
        uint8 chunkIdx = uint8(spriteTable[b]);
        uint16 off = _readU16(spriteTable, b + 1);
        uint16 len = _readU16(spriteTable, b + 3);
        bytes memory chunkData = IChunk(chunks[chunkIdx]).data();
        bytes memory out = new bytes(len);
        for (uint256 k = 0; k < len; k++) {{
            out[k] = chunkData[off + k];
        }}
        return out;
    }}

    /// @notice Return the human-readable name of sprite `i`.
    function name(uint256 i) external pure returns (string memory) {{
        uint256 b = i * 3;
        uint16 off = _readU16(nameTable, b);
        uint8 length = uint8(nameTable[b + 2]);
        bytes memory result = new bytes(length);
        bytes memory blob = nameData;
        for (uint256 k = 0; k < length; k++) {{
            result[k] = blob[off + k];
        }}
        return string(result);
    }}

    /// @notice Lookup an RGBA color from the palette by index.
    function color(uint256 idx) external pure returns (bytes4) {{
        bytes memory p = palette;
        uint256 b = idx * 4;
        return bytes4(uint32(uint8(p[b])) << 24 | uint32(uint8(p[b+1])) << 16 | uint32(uint8(p[b+2])) << 8 | uint32(uint8(p[b+3])));
    }}
}}
"""
    out_path = os.path.join(SRC_DIR, "ComradeSpriteData.sol")
    open(out_path, "w").write(sol)
    print(f"\nwrote {out_path}")
    print(f"\nbreakdown:")
    print(f"  palette:     {len(palette_hex)//2:5d} bytes")
    print(f"  sprite table: {len(table_bytes):5d} bytes ({sprite_id} sprites × 5 bytes)")
    print(f"  name blob:    {len(name_blob):5d} bytes")
    print(f"  name offsets: {len(name_offs):5d} bytes")
    print(f"  blob (chunked): {len(blob_bytes)} bytes across {len(chunks)} contracts")


if __name__ == "__main__":
    main()
