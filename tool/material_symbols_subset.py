#!/usr/bin/env python3
"""Build the bundled Material Symbols Rounded icon subset.

Downloads the Material Symbols Rounded variable font, pins the variant axes
to the values the app freezes (Rounded / wght 400 / FILL 0 / GRAD 0 /
opsz 24), subsets it to the icon codepoints below and writes
`assets/fonts/MaterialSymbolsRounded.ttf`.

Mirrors `tool/font_subset.py`: cached upstream download, hard failure when a
codepoint is missing from the output cmap. Re-run after adding an icon to
ICONS.

Usage:
    python tool/material_symbols_subset.py
"""

from __future__ import annotations

import sys
import tempfile
import urllib.request
from pathlib import Path

from fontTools.subset import Options, Subsetter
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

REPO_ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = REPO_ROOT / "assets" / "fonts"
SOURCE_URL = (
    "https://github.com/google/material-design-icons/raw/master/variablefont/"
    "MaterialSymbolsRounded%5BFILL%2CGRAD%2Copsz%2Cwght%5D.ttf"
)

# name -> codepoint (official MaterialSymbolsRounded codepoints table).
# Keep in sync with lib/ui/theme.dart `ZSymbols`.
ICONS = {
    "terminal": 0xEB8E,  # slash popup: command entries
    "extension": 0xE87B,  # slash popup: skill entries
}


def download_source() -> Path:
    cache = Path(tempfile.gettempdir()) / "MaterialSymbolsRounded-var.ttf"
    if cache.exists() and cache.stat().st_size > 1_000_000:
        print(f"[symbols] cached variable font: {cache}")
        return cache
    print(f"[symbols] downloading {SOURCE_URL}")
    with urllib.request.urlopen(SOURCE_URL) as resp, open(cache, "wb") as out:
        while chunk := resp.read(1 << 20):
            out.write(chunk)
    print(f"[symbols] saved {cache.stat().st_size / 1024 / 1024:.1f} MiB -> {cache}")
    return cache


def main() -> int:
    source = download_source()
    font = TTFont(source)
    instancer.instantiateVariableFont(
        font,
        {"FILL": 0, "GRAD": 0, "opsz": 24, "wght": 400},
        inplace=True,
        updateFontNames=True,
    )

    options = Options()
    options.glyph_names = False
    options.notdef_outline = True
    options.drop_tables += ["DSIG"]
    subsetter = Subsetter(options=options)
    subsetter.populate(unicodes=set(ICONS.values()))
    subsetter.subset(font)

    out_path = OUT_DIR / "MaterialSymbolsRounded.ttf"
    font.save(out_path)
    size = out_path.stat().st_size

    cmap = set(font.getBestCmap())
    missing = [name for name, cp in sorted(ICONS.items()) if cp not in cmap]
    print(f"[symbols] {out_path.name}: {size:,} bytes, "
          f"{len(ICONS) - len(missing)}/{len(ICONS)} icons")
    if missing:
        print(f"[symbols] FAILED: missing {missing}", file=sys.stderr)
        return 1
    print("[symbols] OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
