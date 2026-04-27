#!/usr/bin/env python3
"""
Extract per-category trait taxonomy + weights from CDC items, map to our
sprite IDs, emit a packed binary blob + a Solidity ComradeTaxonomy contract.

Format (packed, big-endian):
  9 categories in z-order (BG, Type, SkinStuff, Cloths, Audio, Mouth, Eyes, Head, Relics)
  For each category:
    uint16 numValues
    uint32 totalWeight
    uint16 presenceBps        // 0-10000 (basis points)
    [numValues] x (uint16 spriteId, uint32 weight)

Categories present in trait_stats.json may have values whose sprite name
doesn't match any file in sprite_table.json — those are skipped.
"""
import json
import os
from collections import OrderedDict

OUT_DIR = os.path.dirname(os.path.abspath(__file__))
SRC_DIR = os.path.join(os.path.dirname(OUT_DIR), "src")

# Z-order: BG drawn first (lowest), Relics on top.
CATEGORIES = [
    ("Background",                "10_Backgrounds"),
    ("Type",                      "08_Type"),
    ("Skin Stuff",                "07_Skin Stuff"),
    ("Cloths",                    "06_Cloths"),
    ("Audio Indexer Derivations", "04_Audio Indexer Derivations"),
    ("Mouth",                     "03_Mouth"),
    ("Eyes",                      "02_Eyes"),
    ("Head",                      "05_Head"),
    ("Relics",                    "01_Relics"),
]
REQUIRED = {"Background", "Type", "Eyes"}

# CDC's trait_stats names sometimes diverge from our sprite_table filenames
# (typos, spacing, renames). Map (cat_folder, cdc_name) → our_name so the
# weight from CDC stats lands on the right sprite. Without this, traits like
# "Green" / "Perky Porky Pink" had zero weight and never rolled.
NAME_ALIAS = {
    # Backgrounds
    ("10_Backgrounds", "Block City during Rollback(Chainrunners)"): "Block City during Rollback (Chainrunners)",
    ("10_Backgrounds", "Giga Green"):       "Green",
    ("10_Backgrounds", "Perky Pork Pink"):  "Perky Porky Pink",
    ("10_Backgrounds", "The Blocks are Fine"): "The Chain is Fine",
    # Type
    ("08_Type", "Human Melanin Level Goth"): "Human, Melanin Level Goth",
    ("08_Type", "Human Melanin Level 80"):   "Human, Melanin Level 80",
    ("08_Type", "Human Melanin Level 30"):   "Human, Melanin Level 30",
    ("08_Type", "We the people"):            "We The People",
    # Cloths
    ("06_Cloths", "Block Construction Crew Exoskeleton"): "Block Construction Crew Exosceleton",
    # Audio
    ("04_Audio Indexer Derivations", "You Should See His.."): "You Should See His...",
    # Mouth
    ("03_Mouth", "For Real I Promise"):                                  "For Real, I Promise",
    ("03_Mouth", "Ménage à neuf"):                                       "Ménage  à Neuf",
    ("03_Mouth", "Vomit Tier 1 Call The Doctor!"):                       "Vomit, Tier 1 Call The Doctor!",
    ("03_Mouth", "Vomit Tier 2 Call the Gender Studies Teacher!!"):      "Vomit, Tier 2 Call the Gender Studies Teacher!!",
    ("03_Mouth", "Vomit Tier 3 CALL THE UNICORNS!!!"):                   "Vomit, Tier 3 CALL THE UNICORNS!!!",
    ("03_Mouth", "Vomit Tier 4 CaLL tHe GoDS!!!!"):                      "Vomit, Tier 4 CaLL tHe GoDS!!!!",
    ("03_Mouth", "Quadruple Block Speak"):                               "Quadrupel Block Speak",
    # Eyes
    ("02_Eyes", "Quadruple Block Vision"): "Quadrupel Block Vision",
    # Head
    ("05_Head", "Knights Helmet"):                  "Kinights Helmet",
    ("05_Head", "Block Construction Forman Helmet"):"Block Construction Foreman Helmet",
    ("05_Head", "Blockchain Maintenance Helmet"):   "Blockchain Maintanance Helmet",
    ("05_Head", "Imaginary Scriptoadz Companion"):  "Invisible Scriptoadz Companion",
    ("05_Head", "Bandana"):                         "Bandana Pirate",
}


def main():
    sprite_table = json.load(open(os.path.join(OUT_DIR, "sprite_table.json")))
    trait_stats  = json.load(open(os.path.join(OUT_DIR, "trait_stats.json")))

    # Build a (category, name) -> global sprite_id map
    sid_map = {}
    sid = 0
    for cat_folder, entries in sprite_table.items():
        for e in entries:
            sid_map[(cat_folder, e["name"])] = sid
            sid += 1

    # Compute per-category presence rate from CDC items
    cdc = []
    with open(os.path.join(OUT_DIR, "cdc_items.jsonl")) as f:
        for l in f:
            cdc.append(json.loads(l))
    presence = {}
    for cat_meta, _ in CATEGORIES:
        present = sum(1 for it in cdc
                      if any(a["trait_type"] == cat_meta for a in it.get("attrs", [])))
        presence[cat_meta] = present / len(cdc)

    # Build packed blob
    blob = bytearray()
    summary = []
    for cat_meta, cat_folder in CATEGORIES:
        # Map metadata category name → values in trait_stats
        # trait_stats has keys = trait_type strings (e.g. "Background", "Type")
        # Check if the stats use the metadata name or the folder name
        stats = trait_stats.get(cat_meta, {})
        if not stats:
            print(f"WARN: no trait stats for {cat_meta}, skipping")
            blob.extend((0).to_bytes(2, "big"))   # numValues
            blob.extend((0).to_bytes(4, "big"))   # totalWeight
            blob.extend((0).to_bytes(2, "big"))   # presenceBps
            continue

        values = []
        skipped = []
        for value_name, freq in stats.items():
            # First try exact match, then the alias map.
            sprite_id = sid_map.get((cat_folder, value_name))
            if sprite_id is None:
                aliased = NAME_ALIAS.get((cat_folder, value_name))
                if aliased is not None:
                    sprite_id = sid_map.get((cat_folder, aliased))
            if sprite_id is None:
                skipped.append(value_name)
                continue
            values.append((sprite_id, freq))

        total_weight = sum(w for _, w in values)
        pres_bps = 10000 if cat_meta in REQUIRED else int(presence[cat_meta] * 10000)

        blob.extend(len(values).to_bytes(2, "big"))
        blob.extend(total_weight.to_bytes(4, "big"))
        blob.extend(pres_bps.to_bytes(2, "big"))
        for sid, w in values:
            blob.extend(sid.to_bytes(2, "big"))
            blob.extend(w.to_bytes(4, "big"))

        summary.append(f"{cat_meta:35s} values={len(values):3d} totalWeight={total_weight:5d} pres={pres_bps/100:5.1f}%  skipped={len(skipped)}")
        if skipped:
            for s in skipped[:5]:
                summary.append(f"    skip: {s}")

    print(f"taxonomy blob: {len(blob)} bytes")
    for line in summary:
        print(line)

    # Generate Solidity contract
    sol = f"""// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Trait-pool taxonomy for procedural Comrade generation.
///
/// Packed format (per-category, in z-order):
///   uint16 numValues
///   uint32 totalWeight
///   uint16 presenceBps   (0-10000; 10000 = always included)
///   [numValues] x (uint16 spriteId, uint32 weight)
///
/// Category z-order (drawn bottom-to-top):
///   0 Background  1 Type     2 Skin Stuff   3 Cloths   4 Audio
///   5 Mouth       6 Eyes     7 Head         8 Relics
contract ComradeTaxonomy {{
    bytes public constant data = hex"{blob.hex()}";
    uint8 public constant CATEGORY_COUNT = 9;

    /// @notice Parse the offset of category `cat` (0-8) in the packed blob.
    /// Returns (offset_to_first_value_byte, numValues, totalWeight, presenceBps).
    function categoryHeader(uint8 cat) public pure returns (
        uint256 valuesOffset, uint16 numValues, uint32 totalWeight, uint16 presenceBps
    ) {{
        bytes memory d = data;
        uint256 cur = 0;
        for (uint8 i = 0; i < cat; i++) {{
            uint16 n = (uint16(uint8(d[cur])) << 8) | uint16(uint8(d[cur + 1]));
            cur += 8 + uint256(n) * 6;  // skip header (8 bytes) + n entries (6 bytes each)
        }}
        numValues   = (uint16(uint8(d[cur])) << 8) | uint16(uint8(d[cur + 1]));
        totalWeight = (uint32(uint8(d[cur + 2])) << 24)
                    | (uint32(uint8(d[cur + 3])) << 16)
                    | (uint32(uint8(d[cur + 4])) << 8)
                    |  uint32(uint8(d[cur + 5]));
        presenceBps = (uint16(uint8(d[cur + 6])) << 8) | uint16(uint8(d[cur + 7]));
        valuesOffset = cur + 8;
    }}

    /// @notice Read the i-th (spriteId, weight) entry for a category.
    function categoryEntry(uint256 valuesOffset, uint16 i)
        public pure returns (uint16 spriteId, uint32 weight)
    {{
        bytes memory d = data;
        uint256 p = valuesOffset + uint256(i) * 6;
        spriteId = (uint16(uint8(d[p])) << 8) | uint16(uint8(d[p + 1]));
        weight = (uint32(uint8(d[p + 2])) << 24)
               | (uint32(uint8(d[p + 3])) << 16)
               | (uint32(uint8(d[p + 4])) << 8)
               |  uint32(uint8(d[p + 5]));
    }}

    /// @notice Pick a sprite ID from category `cat` weighted by frequency.
    /// `r` should be a uniformly random uint32 < totalWeight (caller scales).
    function pickValue(uint8 cat, uint256 r) external pure returns (uint16) {{
        (uint256 off, uint16 n, uint32 totalW, ) = categoryHeader(cat);
        if (n == 0) return type(uint16).max;
        uint256 target = r % totalW;
        uint256 acc = 0;
        for (uint16 i = 0; i < n; i++) {{
            (uint16 sid, uint32 w) = categoryEntry(off, i);
            acc += w;
            if (target < acc) return sid;
        }}
        // unreachable — fallback
        (uint16 sid0, ) = categoryEntry(off, 0);
        return sid0;
    }}

    /// @notice Whether category `cat` should be included for a given roll `r`
    /// (uint16 0-65535). Required categories always return true.
    function shouldInclude(uint8 cat, uint16 r) external pure returns (bool) {{
        ( , , , uint16 pres) = categoryHeader(cat);
        if (pres >= 10000) return true;
        // r in [0, 65535] mapped to bps via /6.5536; use multiplication-instead-of-divide
        return uint256(r) * 10000 < uint256(pres) * 65536;
    }}
}}
"""
    out_path = os.path.join(SRC_DIR, "ComradeTaxonomy.sol")
    open(out_path, "w").write(sol)
    print(f"\nwrote {out_path}")
    print(f"deployed bytecode estimate: ~{len(blob) + 2000} bytes (well under 24KB)")


if __name__ == "__main__":
    main()
