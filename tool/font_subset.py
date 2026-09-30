#!/usr/bin/env python3
"""Build the bundled CJK UI font subsets.

Downloads the Noto Sans SC variable font, instances it into the three static
weights the theme uses (400/500/600), subsets each to the app character set and
writes `assets/fonts/NotoSansSC-{Regular,Medium,SemiBold}.ttf`.

Character set:
  * all 6763 GB2312 hanzi (rows 16-87)
  * every CJK / fullwidth / ASCII character used by `lib/**/*.dart`
  * ASCII visible range + fullwidth forms + common CJK punctuation/symbols

The variable font is cached in the OS temp dir (never committed). The script is
idempotent: re-run it after changing UI copy or bumping the upstream font.

Usage:
    python tool/font_subset.py [--keep-hinting]

Exit code is non-zero when a subset fails to cover the character set or when the
three files exceed the 8 MiB budget.
"""

from __future__ import annotations

import argparse
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
    "https://github.com/google/fonts/raw/main/ofl/notosanssc/"
    "NotoSansSC%5Bwght%5D.ttf"
)
MAX_TOTAL_BYTES = 8 * 1024 * 1024

# weight -> output file stem
WEIGHTS = {
    400: "NotoSansSC-Regular",
    500: "NotoSansSC-Medium",
    600: "NotoSansSC-SemiBold",
}

# Characters the subset must carry beyond hanzi and the lib/ corpus: ideographic
# space (indentation) and the fullwidth ASCII forms U+FF01-FF5E (！ … ～), which
# carry the CJK punctuation the UI uses alongside its own copy.
EXTRA_CHARS = "\u3000"
ASCII_VISIBLE = "".join(chr(c) for c in range(0x20, 0x7F))
FULLWIDTH = "".join(chr(c) for c in range(0xFF01, 0xFF5F))


def gb2312_hanzi() -> set[str]:
    """All 6763 hanzi of GB2312 rows 16-87."""
    chars = set()
    for lead in range(0xB0, 0xF8):
        for trail in range(0xA1, 0xFF):
            try:
                ch = bytes([lead, trail]).decode("gb2312")
            except UnicodeDecodeError:
                continue
            if "\u4e00" <= ch <= "\u9fff":
                chars.add(ch)
    assert len(chars) == 6763, f"GB2312 hanzi count is {len(chars)}, want 6763"
    return chars


def corpus_chars() -> set[str]:
    """Every non-ASCII character appearing in the Dart sources under lib/."""
    chars = set()
    for path in sorted((REPO_ROOT / "lib").rglob("*.dart")):
        chars.update(c for c in path.read_text(encoding="utf-8") if c > "\x7f")
    return chars


def wanted_charset() -> set[str]:
    charset = gb2312_hanzi()
    charset |= corpus_chars()
    charset |= set(EXTRA_CHARS)
    charset |= set(ASCII_VISIBLE)
    charset |= set(FULLWIDTH)
    return {c for c in charset if c.isprintable() or c == "\u3000"}


def download_source() -> Path:
    cache = Path(tempfile.gettempdir()) / "NotoSansSC-var.ttf"
    if cache.exists() and cache.stat().st_size > 1_000_000:
        print(f"[font] cached variable font: {cache}")
        return cache
    print(f"[font] downloading {SOURCE_URL}")
    with urllib.request.urlopen(SOURCE_URL) as resp, open(cache, "wb") as out:
        while chunk := resp.read(1 << 20):
            out.write(chunk)
    print(f"[font] saved {cache.stat().st_size / 1024 / 1024:.1f} MiB -> {cache}")
    return cache


def instantiate(source: Path, weight: int) -> TTFont:
    font = TTFont(source)
    instancer.instantiateVariableFont(
        font, {"wght": weight}, inplace=True, updateFontNames=True
    )
    return font


def subset(font: TTFont, charset: set[str], keep_hinting: bool) -> TTFont:
    options = Options()
    options.hinting = keep_hinting
    options.glyph_names = False
    options.notdef_outline = True
    options.drop_tables += ["DSIG"]
    subsetter = Subsetter(options=options)
    subsetter.populate(unicodes={ord(c) for c in charset})
    subsetter.subset(font)
    return font


def verify(font: TTFont, charset: set[str], label: str) -> list[str]:
    cmap = set(font.getBestCmap())
    return sorted(c for c in charset if ord(c) not in cmap)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--keep-hinting",
        action="store_true",
        help="keep TrueType hinting instructions (bigger files; default strips)",
    )
    args = parser.parse_args()

    charset = wanted_charset()
    print(f"[font] character set: {len(charset)} chars "
          f"(GB2312 hanzi + lib/ corpus + punctuation/ASCII)")

    source = download_source()
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    # Characters the upstream font itself lacks (emoji-adjacent symbols etc.)
    # cannot be subset in; they ride the platform fallback chain instead.
    source_cmap = set(TTFont(source, lazy=True).getBestCmap())
    absent = sorted(c for c in charset if ord(c) not in source_cmap)
    if absent:
        print(f"[font] not in upstream font, fallback handles them: {absent}")
    required = charset - set(absent)

    totals = {}
    failures: list[str] = []
    for weight, stem in WEIGHTS.items():
        font = instantiate(source, weight)
        font = subset(font, required, args.keep_hinting)
        missing = verify(font, required, stem)
        out_path = OUT_DIR / f"{stem}.ttf"
        font.save(out_path)
        size = out_path.stat().st_size
        totals[stem] = size
        print(f"[font] {out_path.name}: {size / 1024 / 1024:.2f} MiB "
              f"({size:,} bytes), coverage "
              f"{len(required) - len(missing)}/{len(required)}")
        if missing:
            failures.append(
                f"{stem}: {len(missing)} chars missing from subset: "
                + "".join(missing)
            )

    total = sum(totals.values())
    print(f"[font] total: {total:,} bytes ({total / 1024 / 1024:.2f} MiB) / "
          f"budget {MAX_TOTAL_BYTES:,} bytes")

    if failures:
        print("[font] FAILED:\n  " + "\n  ".join(failures), file=sys.stderr)
        return 1
    if total > MAX_TOTAL_BYTES:
        print("[font] FAILED: over the 8 MiB budget", file=sys.stderr)
        return 1
    print("[font] OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
