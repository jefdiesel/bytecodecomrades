#!/usr/bin/env python3
"""
Render all 10k generated items as a 10-wide grid using CDC's CC0 trait
layer PNGs from GitHub raw URLs. Lazy-loaded images so the page doesn't
blow up on initial load.

Output: samples/all_10k.html
"""
import json
import os
from urllib.parse import quote

OUT_DIR = os.path.dirname(os.path.abspath(__file__))
SAMPLES_DIR = os.path.join(os.path.dirname(OUT_DIR), "samples")

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

Z_ORDER = ["Background", "Type", "Skin Stuff", "Cloths",
           "Audio Indexer Derivations", "Mouth", "Eyes", "Head", "Relics"]

REPO_BASE = "https://raw.githubusercontent.com/NoMoreLabs/Comrades/main/art/call-data-comrades/cdc_trait_layers"

# Known metadata-vs-filename mismatches in the CDC repo.
FILENAME_OVERRIDES = {
    ("Type", "Human Melanin Level 30"):    "Human, Melanin Level 30",
    ("Type", "Human Melanin Level 80"):    "Human, Melanin Level 80",
    ("Type", "Human Melanin Level Goth"):  "Human, Melanin Level Goth",
    ("Background", "Giga Green"):          "Green",
    ("Eyes", "Quadruple Block Vision"):    "Quadrupel Block Vision",
}


def url_for(trait_type, value):
    folder = FOLDER.get(trait_type)
    if not folder:
        return None
    filename = FILENAME_OVERRIDES.get((trait_type, value), value)
    return f"{REPO_BASE}/{quote(folder)}/{quote(filename)}.png"


def main():
    items = json.load(open(os.path.join(OUT_DIR, "new_items.json")))
    print(f"rendering {len(items)} items in 10-wide grid")

    cards = []
    for it in items:
        sorted_attrs = sorted(it["attrs"], key=lambda a: Z_ORDER.index(a["trait_type"])
                              if a["trait_type"] in Z_ORDER else 99)
        layers = []
        for a in sorted_attrs:
            url = url_for(a["trait_type"], a["value"])
            if url:
                layers.append(
                    f'<img src="{url}" alt="" loading="lazy" '
                    f'onerror="this.style.display=\'none\'" />'
                )
        title_attrs = " | ".join(f"{a['trait_type']}: {a['value']}" for a in sorted_attrs)
        cards.append(
            f'<div class="cell" title="#{it["id"]} — {title_attrs}">'
            f'<div class="stack">{"".join(layers)}</div>'
            f'<div class="id">#{it["id"]}</div>'
            f'</div>'
        )

    html = f"""<!doctype html>
<html><head>
<meta charset="utf-8">
<title>10k Comrades — full set</title>
<style>
  body {{ background:#0a0a0a; color:#eee; font:11px system-ui,sans-serif; margin:0; padding:12px; }}
  h1 {{ font-weight:500; font-size:14px; color:#c3ff00; margin:0 0 12px; }}
  .grid {{ display:grid; grid-template-columns:repeat(10, 1fr); gap:4px; }}
  .cell {{ background:#000; border:1px solid #222; }}
  .stack {{ position:relative; aspect-ratio:1; image-rendering:pixelated; }}
  .stack img {{ position:absolute; inset:0; width:100%; height:100%;
                image-rendering:pixelated; image-rendering:crisp-edges; }}
  .id {{ font-size:9px; color:#666; text-align:center; padding:2px; }}
  .cell:hover {{ outline:2px solid #c3ff00; z-index:10; position:relative; }}
</style></head>
<body>
<h1>10,000 generated Comrades — fully on-chain ready, dedup'd against CDC + CRC</h1>
<div class="grid">
{''.join(cards)}
</div>
</body></html>
"""

    out_path = os.path.join(SAMPLES_DIR, "all_10k.html")
    open(out_path, "w").write(html)
    size_mb = len(html) / 1024 / 1024
    print(f"wrote {out_path} ({size_mb:.1f} MB HTML)")
    print(f"open: file://{out_path}")


if __name__ == "__main__":
    main()
