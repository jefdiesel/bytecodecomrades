#!/usr/bin/env python3
"""
Independently re-verify that data/new_items.json has zero VISUAL collisions
against CDC + CRC. Confirms what gen_combos.py already enforced; prints
detailed stats so we can see exactly what's going on.
"""
import hashlib
import json
import os
from collections import Counter

OUT_DIR = os.path.dirname(os.path.abspath(__file__))

# Same visual-only categories as gen_combos.py
VISUAL_CATEGORIES = {
    "Background", "Type", "Cloths", "Head", "Audio Indexer Derivations",
    "Mouth", "Eyes", "Skin Stuff", "Accessories", "Relics",
}

# Categories explicitly excluded — non-visual metadata
META_CATEGORIES = {"Rank", "Affiliation", "Classification"}


def fp(attrs):
    pairs = sorted(
        (a["trait_type"], a["value"]) for a in attrs
        if a.get("value") and a["trait_type"] in VISUAL_CATEGORIES
    )
    return hashlib.sha256("|".join(f"{k}={v}" for k, v in pairs).encode()).hexdigest()


def load_jsonl(path):
    out = []
    with open(path) as f:
        for line in f:
            try:
                out.append(json.loads(line))
            except Exception:
                pass
    return out


def main():
    cdc = load_jsonl(os.path.join(OUT_DIR, "cdc_items.jsonl"))
    crc = load_jsonl(os.path.join(OUT_DIR, "crc_items.jsonl"))
    new = json.load(open(os.path.join(OUT_DIR, "new_items.json")))

    print(f"loaded: {len(cdc)} CDC, {len(crc)} CRC, {len(new)} generated")

    # Build the existing-items fingerprint set + remember source per fp
    existing = {}
    cdc_dupes_within = 0
    for it in cdc:
        f = fp(it.get("attrs", []))
        if f in existing:
            cdc_dupes_within += 1
        else:
            existing[f] = ("CDC", it["id"])
    for it in crc:
        f = fp(it.get("attrs", []))
        if f not in existing:
            existing[f] = ("CRC", it["id"])

    print(f"\nunique existing visual fingerprints: {len(existing)}")
    print(f"  CDC self-collisions (different items with identical visuals): {cdc_dupes_within}")

    # Check generated against existing
    new_fps = []
    collisions = []
    self_dupes = 0
    seen = set()
    for item in new:
        f = fp(item["attrs"])
        if f in seen:
            self_dupes += 1
        seen.add(f)
        new_fps.append(f)
        if f in existing:
            collisions.append((item["id"], existing[f]))

    print(f"\ngenerated set unique fingerprints: {len(seen)} / {len(new)}")
    print(f"generated self-duplicates: {self_dupes}")
    print(f"\n>>> COLLISIONS WITH CDC + CRC: {len(collisions)} <<<")
    if collisions:
        for cid, src in collisions[:10]:
            print(f"  generated #{cid} matches {src[0]} #{src[1]}")
    else:
        print("  none. zero clones.")

    # Bonus: show category coverage stats for the generated set
    print("\ngenerated trait variety per category:")
    by_cat = {c: Counter() for c in VISUAL_CATEGORIES}
    for item in new:
        for a in item["attrs"]:
            if a["trait_type"] in by_cat:
                by_cat[a["trait_type"]][a["value"]] += 1
    for cat in sorted(by_cat):
        c = by_cat[cat]
        if c:
            print(f"  {cat:35s}  {len(c):3d} unique values used  (most picked: {c.most_common(1)[0][1]}, rarest: {min(c.values())})")


if __name__ == "__main__":
    main()
