#!/usr/bin/env python3
"""
Walk every CDC token id and call ownerOf() to build the full holder map.
Resumable: re-running picks up where it left off.

Output:
  data/cdc_owners.jsonl  — one record per token: {id, owner}
  data/cdc_holders.json  — aggregated: {address: {count, ids: [...]}, ...}
"""
import json
import os
import subprocess
import threading
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed

RPC = "https://mainnet.ethscriptions.com"
ADDR = "0xBB41E24dA83DcAb001bd085879c66cFCB4eED522"  # Call Data Comrades
TOTAL = 9962
WORKERS = 16

OUT_DIR = os.path.dirname(os.path.abspath(__file__))
write_lock = threading.Lock()


def fetch_owner(token_id):
    out = subprocess.check_output(
        ["cast", "call", ADDR, "ownerOf(uint256)(address)", str(token_id),
         "--rpc-url", RPC],
        text=True, stderr=subprocess.DEVNULL, timeout=20,
    ).strip()
    return out  # already a 0x address


def fetch_one(i):
    try:
        owner = fetch_owner(i)
        return (i, {"id": i, "owner": owner})
    except Exception:
        return (i, None)


def main():
    owners_path = os.path.join(OUT_DIR, "cdc_owners.jsonl")
    holders_path = os.path.join(OUT_DIR, "cdc_holders.json")

    done = set()
    if os.path.exists(owners_path):
        with open(owners_path) as f:
            for line in f:
                try:
                    done.add(json.loads(line)["id"])
                except Exception:
                    pass
        print(f"resuming, {len(done)} already done", flush=True)

    pending = [i for i in range(TOTAL) if i not in done]
    if pending:
        print(f"fetching {len(pending)} owners with {WORKERS} workers ...", flush=True)
        out_f = open(owners_path, "a")
        completed = errors = 0
        with ThreadPoolExecutor(max_workers=WORKERS) as ex:
            futs = {ex.submit(fetch_one, i): i for i in pending}
            for fut in as_completed(futs):
                _, rec = fut.result()
                completed += 1
                if rec is None:
                    errors += 1
                    continue
                with write_lock:
                    out_f.write(json.dumps(rec, separators=(",", ":")) + "\n")
                    out_f.flush()
                if completed % 200 == 0:
                    print(f"  {completed}/{len(pending)}  errors={errors}", flush=True)
        out_f.close()
        print(f"done: completed={completed} errors={errors}", flush=True)

    # Aggregate
    holders = defaultdict(lambda: {"count": 0, "ids": []})
    with open(owners_path) as f:
        for line in f:
            r = json.loads(line)
            o = r["owner"].lower()
            holders[o]["count"] += 1
            holders[o]["ids"].append(r["id"])

    # Sort by count desc
    sorted_holders = dict(sorted(holders.items(), key=lambda kv: -kv[1]["count"]))
    json.dump(sorted_holders, open(holders_path, "w"), indent=2)

    total_holders = len(sorted_holders)
    total_items = sum(h["count"] for h in sorted_holders.values())
    print(f"\n{total_holders} unique holders across {total_items} items")
    print(f"\ntop 20 holders:")
    for i, (addr, info) in enumerate(list(sorted_holders.items())[:20]):
        print(f"  {i+1:2d}. {addr}  {info['count']:5d}")
    print(f"\nwrote {holders_path}")


if __name__ == "__main__":
    main()
