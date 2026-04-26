#!/usr/bin/env python3
"""
Export holder data in three usable formats. Safe to run anytime — works
on whatever's in cdc_owners.jsonl, partial or complete.

Outputs:
  data/cdc_holders.json         — {address: {count, ids[]}, ...}, sorted by count desc
  data/cdc_holders_addresses.txt — one address per line, lowercase
  data/cdc_holders_csv.csv      — address,count CSV
"""
import json
import os
from collections import defaultdict

OUT_DIR = os.path.dirname(os.path.abspath(__file__))


def main():
    src = os.path.join(OUT_DIR, "cdc_owners.jsonl")
    if not os.path.exists(src):
        print("no cdc_owners.jsonl yet")
        return

    holders = defaultdict(lambda: {"count": 0, "ids": []})
    total_records = 0
    with open(src) as f:
        for line in f:
            try:
                r = json.loads(line)
            except Exception:
                continue
            total_records += 1
            o = r["owner"].lower()
            holders[o]["count"] += 1
            holders[o]["ids"].append(r["id"])

    sorted_holders = dict(sorted(holders.items(), key=lambda kv: -kv[1]["count"]))

    json_path = os.path.join(OUT_DIR, "cdc_holders.json")
    txt_path  = os.path.join(OUT_DIR, "cdc_holders_addresses.txt")
    csv_path  = os.path.join(OUT_DIR, "cdc_holders.csv")

    json.dump(sorted_holders, open(json_path, "w"), indent=2)
    with open(txt_path, "w") as f:
        for addr in sorted_holders:
            f.write(addr + "\n")
    with open(csv_path, "w") as f:
        f.write("address,count\n")
        for addr, info in sorted_holders.items():
            f.write(f"{addr},{info['count']}\n")

    print(f"records processed: {total_records}")
    print(f"unique holders:    {len(sorted_holders)}")
    print(f"avg items/holder:  {total_records/max(len(sorted_holders),1):.2f}")
    print()
    print("top 10 holders:")
    for i, (addr, info) in enumerate(list(sorted_holders.items())[:10]):
        print(f"  {i+1:2d}. {addr}  {info['count']:5d}")
    print()
    print("wrote:")
    print(f"  {json_path}")
    print(f"  {txt_path}  (one address per line)")
    print(f"  {csv_path}  (address,count)")


if __name__ == "__main__":
    main()
