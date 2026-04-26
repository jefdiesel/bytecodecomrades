#!/usr/bin/env python3
"""
Pull tokenURI metadata for every item in CDC + Cuberekt Comrades on the
Ethscriptions AppChain. Save attributes only (skip the embedded image bytes).

Output:
  data/cdc_items.jsonl   {id, name, attrs}
  data/crc_items.jsonl   {id, name, attrs}

Resumable: re-running picks up where it left off.
"""
import base64
import json
import os
import subprocess
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed

RPC = "https://mainnet.ethscriptions.com"
COLLECTIONS = [
    {"name": "cdc", "addr": "0xBB41E24dA83DcAb001bd085879c66cFCB4eED522", "total": 9962},
    {"name": "crc", "addr": "0x5D5ebc7BffB886e94a09a757f81975Ee300aab92", "total": 1366},
]
WORKERS = 12

OUT_DIR = os.path.dirname(os.path.abspath(__file__))
write_lock = threading.Lock()


def fetch_uri(addr, token_id):
    out = subprocess.check_output(
        ["cast", "call", addr, "tokenURI(uint256)(string)", str(token_id), "--rpc-url", RPC],
        text=True, stderr=subprocess.DEVNULL, timeout=30,
    ).strip()
    if out.startswith('"') and out.endswith('"'):
        out = out[1:-1]
    return out


def parse_metadata(uri):
    prefix = "data:application/json;base64,"
    if not uri.startswith(prefix):
        return None
    try:
        return json.loads(base64.b64decode(uri[len(prefix):]))
    except Exception:
        return None


def fetch_one(addr, i):
    try:
        uri = fetch_uri(addr, i)
        meta = parse_metadata(uri)
        if meta is None:
            return (i, None)
        meta.pop("image", None)
        return (i, {"id": i, "name": meta.get("name"), "attrs": meta.get("attributes", [])})
    except subprocess.CalledProcessError:
        return (i, None)
    except Exception as e:
        return (i, {"id": i, "error": str(e)})


def run_collection(c):
    path = os.path.join(OUT_DIR, f"{c['name']}_items.jsonl")
    done = set()
    if os.path.exists(path):
        with open(path) as f:
            for line in f:
                try:
                    done.add(json.loads(line)["id"])
                except Exception:
                    pass
        print(f"[{c['name']}] resuming, {len(done)} already done", flush=True)

    pending = [i for i in range(c["total"]) if i not in done]
    if not pending:
        print(f"[{c['name']}] complete ({c['total']} items)", flush=True)
        return

    print(f"[{c['name']}] fetching {len(pending)} items with {WORKERS} workers ...", flush=True)
    out_f = open(path, "a")
    completed = 0
    errors = 0

    with ThreadPoolExecutor(max_workers=WORKERS) as ex:
        futs = {ex.submit(fetch_one, c["addr"], i): i for i in pending}
        for fut in as_completed(futs):
            try:
                _, rec = fut.result()
            except Exception as e:
                errors += 1
                continue
            completed += 1
            if rec is None:
                continue
            if "error" in rec:
                errors += 1
                continue
            with write_lock:
                out_f.write(json.dumps(rec, separators=(",", ":")) + "\n")
                out_f.flush()
            if completed % 100 == 0:
                print(f"[{c['name']}] {completed}/{len(pending)}  (errors={errors})", flush=True)

    out_f.close()
    print(f"[{c['name']}] done. completed={completed} errors={errors}", flush=True)


def main():
    for c in COLLECTIONS:
        run_collection(c)


if __name__ == "__main__":
    main()
