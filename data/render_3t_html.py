#!/usr/bin/env python3
"""
Render the 3-trait items from new_items.json as an HTML grid by stacking
CDC's CC0 trait-layer PNGs from GitHub raw URLs.

Output: samples/new_3trait.html
"""
import json
import os
from urllib.parse import quote

OUT_DIR = os.path.dirname(os.path.abspath(__file__))
SAMPLES_DIR = os.path.join(os.path.dirname(OUT_DIR), "samples")

# Map trait_type -> the numbered subfolder in the GitHub repo
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

# Z-order from bottom -> top. Background at the bottom; head/relics on top.
Z_ORDER = ["Background", "Type", "Skin Stuff", "Cloths",
           "Audio Indexer Derivations", "Mouth", "Eyes", "Head", "Relics"]

REPO_BASE = "https://raw.githubusercontent.com/NoMoreLabs/Comrades/main/art/call-data-comrades/cdc_trait_layers"


# Known filename mismatches between metadata trait values and the actual
# PNG filenames in the GitHub repo. Add more as we discover them.
FILENAME_OVERRIDES = {
    ("Type", "Human Melanin Level 30"):   "Human, Melanin Level 30",
    ("Type", "Human Melanin Level 80"):   "Human, Melanin Level 80",
    ("Type", "Human Melanin Level Goth"): "Human, Melanin Level Goth",
}


def url_for(trait_type, value):
    folder = FOLDER.get(trait_type)
    if not folder:
        return None
    filename = FILENAME_OVERRIDES.get((trait_type, value), value)
    return f"{REPO_BASE}/{quote(folder)}/{quote(filename)}.png"


def main():
    items = json.load(open(os.path.join(OUT_DIR, "new_items.json")))
    threes = [it for it in items if len(it["attrs"]) == 3]
    print(f"3-trait items: {len(threes)}")

    cards = []
    for it in threes:
        # Sort attrs by z-order so first <img> is bottom layer
        sorted_attrs = sorted(it["attrs"], key=lambda a: Z_ORDER.index(a["trait_type"])
                              if a["trait_type"] in Z_ORDER else 99)
        layers = []
        for a in sorted_attrs:
            url = url_for(a["trait_type"], a["value"])
            if url:
                # alt="" + onerror hides broken images cleanly instead of showing ugly alt-text
                layers.append(f'<img src="{url}" alt="" onerror="this.style.display=\'none\'" />')
        attrs_text = "<br>".join(f'<span class="t">{a["trait_type"]}</span>: {a["value"]}' for a in sorted_attrs)
        cards.append(f'''
        <div class="card">
            <div class="stack">{"".join(layers)}</div>
            <div class="meta">
                <div class="id">#{it["id"]}</div>
                <div class="attrs">{attrs_text}</div>
            </div>
        </div>''')

    html = f"""<!doctype html>
<html><head>
<meta charset="utf-8">
<title>New Comrades — 3-trait items ({len(threes)})</title>
<style>
  body {{ background:#0e0e0e; color:#eee; font:14px system-ui,sans-serif; padding:24px; margin:0; }}
  h1 {{ margin:0 0 16px; font-weight:500; font-size:18px; color:#c3ff00; }}
  .grid {{ display:grid; grid-template-columns:repeat(auto-fill, minmax(220px, 1fr)); gap:16px; }}
  .card {{ background:#1a1a1a; border:1px solid #333; padding:12px; border-radius:6px; }}
  .stack {{ position:relative; width:100%; aspect-ratio:1; background:#000; image-rendering:pixelated; }}
  .stack img {{ position:absolute; inset:0; width:100%; height:100%;
                image-rendering:pixelated; image-rendering:crisp-edges; }}
  .meta {{ margin-top:8px; font-size:12px; }}
  .id {{ color:#c3ff00; font-weight:600; margin-bottom:4px; }}
  .attrs {{ color:#aaa; line-height:1.5; }}
  .t {{ color:#888; }}
</style></head>
<body>
<h1>New Comrades — 3-trait items ({len(threes)} of 10,000)</h1>
<div class="grid">
{''.join(cards)}
</div>
</body></html>
"""

    out_path = os.path.join(SAMPLES_DIR, "new_3trait.html")
    open(out_path, "w").write(html)
    print(f"wrote {out_path}")
    print(f"open in browser: file://{out_path}")


if __name__ == "__main__":
    main()
