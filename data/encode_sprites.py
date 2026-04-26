#!/usr/bin/env python3
"""
Encode all CDC trait-layer PNGs into a compact on-chain format.

Encoding scheme (per sprite):
  - Build a shared palette across all sprites (RGBA tuples)
  - Each sprite is run-length encoded across a row-major 32x32 scan
  - Each run = (count: u8, palette_idx: u8 or u16)
  - Sentinel palette_idx 0 = transparent

Output:
  data/sprite_palette.hex       — concatenated RGBA bytes
  data/sprite_blob.hex          — concatenated RLE bytes for all sprites
  data/sprite_table.json        — {category: [{name, offset, length, runs}, ...]}
  data/sprite_summary.txt       — human-readable stats
"""
import json
import os
from PIL import Image
from collections import OrderedDict

REPO = "data/comrades_repo/art/call-data-comrades/cdc_trait_layers"
OUT_DIR = os.path.dirname(os.path.abspath(__file__))

# Categories we'll use (order = z-order if you stacked all of them)
CATEGORIES = [
    "10_Backgrounds",
    "08_Type",
    "07_Skin Stuff",
    "06_Cloths",
    "04_Audio Indexer Derivations",
    "03_Mouth",
    "02_Eyes",
    "05_Head",
    "01_Relics",
]


def collect_sprites():
    """Return dict {category_folder: [(name, pixels_2d), ...]}"""
    sprites = OrderedDict()
    for cat in CATEGORIES:
        d = os.path.join(REPO, cat)
        if not os.path.isdir(d):
            continue
        files = sorted(f for f in os.listdir(d) if f.endswith(".png"))
        cat_list = []
        for f in files:
            im = Image.open(os.path.join(d, f)).convert("RGBA")
            if im.size != (32, 32):
                print(f"  WARN: {cat}/{f} is {im.size}, skipping")
                continue
            pixels = list(im.getdata())  # 1024 RGBA tuples
            name = f[:-4]  # strip .png
            cat_list.append((name, pixels))
        sprites[cat] = cat_list
        print(f"  {cat}: {len(cat_list)} sprites")
    return sprites


def build_palette(sprites):
    """Single shared palette of unique RGBA tuples. Index 0 = transparent."""
    palette = OrderedDict()
    palette[(0, 0, 0, 0)] = 0   # reserve index 0 for transparent
    for cat, lst in sprites.items():
        for name, pixels in lst:
            for px in pixels:
                if px[3] == 0:
                    continue   # transparent - all map to index 0
                if px not in palette:
                    palette[px] = len(palette)
    return palette


def encode_sprite(pixels, palette, idx_bytes):
    """RLE-encode 1024 pixels. Each run: (count: u8, idx: u8 or u16 BE)."""
    out = bytearray()
    if not pixels:
        return bytes(out)

    def to_idx(p):
        return 0 if p[3] == 0 else palette[p]

    def emit(count, idx):
        out.append(count)
        if idx_bytes == 1:
            out.append(idx)
        else:
            out.append((idx >> 8) & 0xFF)
            out.append(idx & 0xFF)

    cur_idx = to_idx(pixels[0])
    run_len = 1
    for p in pixels[1:]:
        idx = to_idx(p)
        if idx == cur_idx and run_len < 255:
            run_len += 1
        else:
            emit(run_len, cur_idx)
            cur_idx = idx
            run_len = 1
    emit(run_len, cur_idx)
    return bytes(out)


def main():
    print("collecting sprites...")
    sprites = collect_sprites()
    total_sprites = sum(len(v) for v in sprites.values())
    print(f"\ntotal: {total_sprites} sprites\n")

    print("building palette...")
    palette = build_palette(sprites)
    idx_bytes = 1 if len(palette) <= 256 else 2
    print(f"palette size: {len(palette)} colors → {idx_bytes}-byte indices")

    print("\nencoding sprites...")
    table = OrderedDict()
    blob = bytearray()
    total_runs = 0

    for cat, lst in sprites.items():
        cat_entries = []
        for name, pixels in lst:
            encoded = encode_sprite(pixels, palette, idx_bytes)
            offset = len(blob)
            blob.extend(encoded)
            num_runs = len(encoded) // (1 + idx_bytes)
            total_runs += num_runs
            cat_entries.append({
                "name": name,
                "offset": offset,
                "length": len(encoded),
                "runs": num_runs,
            })
        table[cat] = cat_entries

    # Palette as concatenated 4-byte RGBA
    palette_bytes = bytearray()
    for color in palette:
        palette_bytes.extend(color)

    print(f"\npalette: {len(palette_bytes)} bytes ({len(palette)} entries)")
    print(f"sprite blob: {len(blob)} bytes ({total_sprites} sprites, {total_runs} runs total)")
    print(f"avg bytes per sprite: {len(blob)/total_sprites:.1f}")
    print(f"\nfits in EIP-170 contracts:")
    chunk_size = 24000  # leave headroom
    chunks_needed = (len(blob) + chunk_size - 1) // chunk_size
    print(f"  blob needs {chunks_needed} SSTORE2 chunks (24KB each)")

    # Write outputs
    open(os.path.join(OUT_DIR, "sprite_palette.hex"), "w").write(bytes(palette_bytes).hex())
    open(os.path.join(OUT_DIR, "sprite_blob.hex"), "w").write(bytes(blob).hex())
    json.dump(table, open(os.path.join(OUT_DIR, "sprite_table.json"), "w"), indent=2)

    with open(os.path.join(OUT_DIR, "sprite_summary.txt"), "w") as f:
        f.write(f"palette colors: {len(palette)}\n")
        f.write(f"total sprites:  {total_sprites}\n")
        f.write(f"blob bytes:     {len(blob)}\n")
        f.write(f"avg/sprite:     {len(blob)/total_sprites:.1f}\n\n")
        for cat, entries in table.items():
            f.write(f"{cat}: {len(entries)} sprites\n")
            for e in entries:
                f.write(f"  {e['length']:4d}b  runs={e['runs']:4d}  {e['name']}\n")

    print(f"\nwrote sprite_palette.hex, sprite_blob.hex, sprite_table.json, sprite_summary.txt")


if __name__ == "__main__":
    main()
