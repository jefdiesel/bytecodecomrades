#!/usr/bin/env python3
"""
Scan every (trait_type, value) used in new_items.json and HEAD-request
the GitHub raw URL. Report which 404. Helps us find all filename
mismatches in one pass.

Output:
  data/broken_traits.txt — list of (category, value) that 404
"""
import json
import os
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from urllib.parse import quote
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

OUT_DIR = os.path.dirname(os.path.abspath(__file__))

FOLDER = {
    "Relics":                    "01_Relics",
    "Eyes":                      "02_Eyes",
    "Mouth":                     "03_Mouth",
    "Audio Indexer Derivations": "04_Audio Indexer Derivations",
    "Head":                      "05_Head",
    "Cloths":                    "06_Cloths",
    "Skin Stuff":                "07_Skin Stuff",
    "Type":                      "08_Type",
    "Background":                "10_Backgrounds",
}
REPO_BASE = "https://raw.githubusercontent.com/NoMoreLabs/Comrades/main/art/call-data-comrades/cdc_trait_layers"

# already-known overrides — skip
KNOWN = {
    ("Type", "Human Melanin Level 30"),
    ("Type", "Human Melanin Level 80"),
    ("Type", "Human Melanin Level Goth"),
    ("Background", "Giga Green"),
    ("Eyes", "Quadruple Block Vision"),
}


def head(url):
    req = Request(url, method="HEAD")
    try:
        with urlopen(req, timeout=10) as r:
            return r.status
    except HTTPError as e:
        return e.code
    except URLError:
        return -1


def main():
    items = json.load(open(os.path.join(OUT_DIR, "new_items.json")))
    pairs = set()
    for it in items:
        for a in it["attrs"]:
            t, v = a["trait_type"], a["value"]
            if t in FOLDER and (t, v) not in KNOWN:
                pairs.add((t, v))
    pairs = sorted(pairs)
    print(f"checking {len(pairs)} unique (category,value) pairs ...")

    broken = []
    lock = threading.Lock()
    done = 0

    def check(p):
        nonlocal done
        cat, val = p
        url = f"{REPO_BASE}/{quote(FOLDER[cat])}/{quote(val)}.png"
        st = head(url)
        with lock:
            done += 1
            if st != 200:
                broken.append((cat, val, st))
                print(f"  [{done}] BROKEN ({st}): {cat} / {val}")

    with ThreadPoolExecutor(max_workers=24) as ex:
        list(ex.map(check, pairs))

    print(f"\ndone. {len(broken)} broken / {len(pairs)} total")
    out_path = os.path.join(OUT_DIR, "broken_traits.txt")
    with open(out_path, "w") as f:
        for cat, val, st in sorted(broken):
            f.write(f"{cat}\t{val}\t{st}\n")
    print(f"wrote {out_path}")


if __name__ == "__main__":
    main()
