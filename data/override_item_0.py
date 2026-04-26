#!/usr/bin/env python3
"""
Replace generated item #0 with a hand-crafted homage to CDC's Comrade #1:
same Background, same Eyes (Aviators), same Mouth (Beard of the Gods).
Body and Cloths are fresh picks. Verify the combo doesn't collide with
CDC/CRC or with any other generated item, then write back.
"""
import hashlib
import json
import os

OUT_DIR = os.path.dirname(os.path.abspath(__file__))

VISUAL = {"Background","Type","Cloths","Head","Audio Indexer Derivations",
          "Mouth","Eyes","Skin Stuff","Accessories","Relics"}

OVERRIDE_ATTRS = [
    {"trait_type": "Background", "value": "Sir Pinkalot"},        # same as CDC #1
    {"trait_type": "Type",       "value": "Alien People"},        # our choice
    {"trait_type": "Cloths",     "value": "Hardbass Uniform"},    # our choice
    {"trait_type": "Mouth",      "value": "Beard of the Gods"},   # same (moustache)
    {"trait_type": "Eyes",       "value": "Aviators"},            # same (glasses)
]


def fp(attrs):
    pairs = sorted((a["trait_type"], a["value"]) for a in attrs
                   if a.get("value") and a["trait_type"] in VISUAL)
    return hashlib.sha256("|".join(f"{k}={v}" for k,v in pairs).encode()).hexdigest()


def main():
    cdc = []
    with open(os.path.join(OUT_DIR, "cdc_items.jsonl")) as f:
        for l in f: cdc.append(json.loads(l))
    crc = []
    with open(os.path.join(OUT_DIR, "crc_items.jsonl")) as f:
        for l in f: crc.append(json.loads(l))
    existing_fps = {fp(it.get("attrs", [])) for it in cdc + crc}

    items = json.load(open(os.path.join(OUT_DIR, "new_items.json")))
    self_fps = {it["fp"] for it in items if it["id"] != 0}

    new_fp = fp(OVERRIDE_ATTRS)
    if new_fp in existing_fps:
        print("COLLISION with CDC/CRC — pick different combo")
        return
    if new_fp in self_fps:
        print("COLLISION with another generated item — pick different combo")
        return

    print("override combo unique. ✓")
    print("traits:")
    for a in OVERRIDE_ATTRS:
        print(f"  {a['trait_type']:35s}  {a['value']}")
    print(f"  fingerprint: {new_fp[:16]}...")

    # Replace item with id=0
    new_item = {"id": 0, "attrs": OVERRIDE_ATTRS, "fp": new_fp}
    items[0] = new_item

    json.dump(items, open(os.path.join(OUT_DIR, "new_items.json"), "w"))
    print(f"\nwrote new_items.json (item #0 replaced)")


if __name__ == "__main__":
    main()
