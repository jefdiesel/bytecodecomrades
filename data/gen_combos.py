#!/usr/bin/env python3
"""
Generate 10k unique trait combinations modeled after CDC's structure.

Structural rules (derived from CDC distribution):
  - REQUIRED categories (in 99%+ of CDC): Background, Eyes, Type — always included
  - Optional categories included with their per-CDC-presence probability,
    so total trait count tracks CDC's distribution (peaks at 6, range 4-8).
  - Trait values within a category are weighted by their CDC frequency.

Outputs:
  data/new_items.json       — array of {id, attrs[], fp}
  data/trait_stats.json     — derived taxonomy

Dedup:
  Visual fingerprint (Rank/Affiliation/Classification excluded) compared
  against CDC + CRC + previously-generated items.
"""
import hashlib
import json
import os
import random
from collections import Counter, defaultdict

OUT_DIR = os.path.dirname(os.path.abspath(__file__))
TARGET_COUNT = 10_000
SEED = 0xCAFEC0DE

VISUAL_CATEGORIES = {
    "Background", "Type", "Cloths", "Head", "Audio Indexer Derivations",
    "Mouth", "Eyes", "Skin Stuff", "Accessories", "Relics",
}
REQUIRED = ["Background", "Eyes", "Type"]
OPTIONAL = ["Mouth", "Cloths", "Head", "Audio Indexer Derivations",
            "Skin Stuff", "Accessories", "Relics"]

# Trait values that don't have a corresponding PNG in the GitHub repo.
# Excluded from the generation taxonomy so every item is fully renderable.
# Discovered by data/scan_broken_files.py.
BROKEN_VALUES = {
    ("Background", "Block City during Rollback(Chainrunners)"),  # actually exists with space
    ("Background", "Jazz"),
    ("Background", "Perky Pork Pink"),                            # typo: Porky
    ("Background", "Lava"),
    ("Background", "Rainbow Mayhem"),
    ("Background", "The Blocks are Fine"),
    ("Background", "Matrix Animated"),
    ("Cloths",     "Block Construction Crew Exoskeleton"),
    ("Audio Indexer Derivations", "You Should See His.."),
    ("Eyes",       "Nyan Goggles"),
    ("Head",       "Block Construction Forman Helmet"),
    ("Head",       "Blockchain Maintenance Helmet"),
    ("Head",       "Bandana"),
    ("Head",       "Knights Helmet"),
    ("Head",       "Imaginary Scriptoadz Companion"),
    ("Mouth",      "Genuine Unjaw"),
    ("Mouth",      "Floored Ape Theory"),
    ("Mouth",      "For Real I Promise"),
    ("Mouth",      "Ménage à neuf"),
    ("Mouth",      "Quadruple Block Speak"),  # typo: Quadrupel
    ("Mouth",      "Vomit Tier 2 Call the Gender Studies Teacher!!"),
    ("Mouth",      "Vomit Tier 1 Call The Doctor!"),
    ("Mouth",      "Vomit Tier 3 CALL THE UNICORNS!!!"),
    ("Mouth",      "Vomit Tier 4 CaLL tHe GoDS!!!!"),
    ("Type",       "We the people"),  # capital T in actual file
}


def fingerprint(attrs):
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
    print(f"loaded {len(cdc)} CDC + {len(crc)} CRC items")

    exclusion = set()
    for it in cdc + crc:
        if it.get("attrs"):
            exclusion.add(fingerprint(it["attrs"]))
    print(f"exclusion set: {len(exclusion)} unique visual fingerprints")

    # Build value-frequency taxonomy from CDC, skipping JSON-list values
    # (multi-value attrs CDC sometimes uses) and values without a PNG file.
    value_freq = defaultdict(Counter)
    for it in cdc:
        for a in it.get("attrs", []):
            cat = a["trait_type"]
            val = a["value"]
            if cat not in VISUAL_CATEGORIES:
                continue
            if isinstance(val, list) or (isinstance(val, str) and val.startswith("[")):
                continue
            if (cat, val) in BROKEN_VALUES:
                continue
            value_freq[cat][val] += 1

    # Per-category presence rate (probability the category appears at all on a CDC item)
    # Force REQUIRED to 1.0; OPTIONAL gets its observed rate
    presence = {}
    for it in cdc:
        seen = {a["trait_type"] for a in it.get("attrs", []) if a["trait_type"] in VISUAL_CATEGORIES}
        for cat in VISUAL_CATEGORIES:
            presence.setdefault(cat, [0, 0])
            presence[cat][1] += 1
            if cat in seen:
                presence[cat][0] += 1
    presence_rate = {cat: p[0] / p[1] for cat, p in presence.items()}

    print("\npresence rates (chance category appears on a generated item):")
    for cat in REQUIRED:
        print(f"  {cat:35s}  100.0%  (required)")
    for cat in OPTIONAL:
        print(f"  {cat:35s}  {presence_rate[cat]*100:5.1f}%")

    # Generate
    rng = random.Random(SEED)
    generated = []
    used = set(exclusion)
    rerolls = 0
    attempts = 0
    count_distribution = Counter()

    while len(generated) < TARGET_COUNT:
        attempts += 1
        if attempts > TARGET_COUNT * 50:
            raise RuntimeError(f"too many attempts; only {len(generated)} done")

        attrs = []
        # required slots
        for cat in REQUIRED:
            vals = list(value_freq[cat].items())
            value = rng.choices([v for v, _ in vals], weights=[w for _, w in vals], k=1)[0]
            attrs.append({"trait_type": cat, "value": value})
        # optional slots — independent biased coin per category
        for cat in OPTIONAL:
            if rng.random() < presence_rate[cat]:
                vals = list(value_freq[cat].items())
                value = rng.choices([v for v, _ in vals], weights=[w for _, w in vals], k=1)[0]
                attrs.append({"trait_type": cat, "value": value})

        fp = fingerprint(attrs)
        if fp in used:
            rerolls += 1
            continue
        used.add(fp)
        count_distribution[len(attrs)] += 1
        generated.append({"id": len(generated), "attrs": attrs, "fp": fp})
        if len(generated) % 2000 == 0:
            print(f"  generated {len(generated)} (rerolls={rerolls})")

    print(f"\ndone. {len(generated)} unique. {rerolls} rerolls. {attempts} attempts.")
    print("\ngenerated trait-count distribution:")
    for n in sorted(count_distribution):
        pct = count_distribution[n] / TARGET_COUNT * 100
        bar = "#" * int(pct / 2)
        print(f"  {n} traits  {count_distribution[n]:5d}  {pct:5.1f}%  {bar}")

    out_path = os.path.join(OUT_DIR, "new_items.json")
    with open(out_path, "w") as f:
        json.dump(generated, f)
    print(f"\nwrote {out_path}")


if __name__ == "__main__":
    main()
