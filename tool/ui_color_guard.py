#!/usr/bin/env python3
"""CI guard: lib/ui must not hardcode dark-mode-only surfaces.

Since the 2026-09-19 light/dark token split, component code reads the
theme-aware ZInk slots (lib/ui/theme.dart) instead of referencing the
dark-side constants directly. This script fails when a file outside the
whitelist carries, on a line that is not a comment:

  * an unguarded `ZColors.dark*` / `ZColors.neutral700/800/900/950` /
    `ZColors.pillRunningBg` reference — guarded means the same expression
    picks between a dark and a light value (`isDark ? …` / the `?` arm of a
    multi-line ternary), or
  * an opaque very-dark hex literal (`0xFF00xxxx` … `0xFF2Fxxxx`).

Whitelist: theme.dart itself (the token definitions) and comment lines.
Run standalone (`python tool/ui_color_guard.py`) or as the CI step before
`flutter analyze`.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCAN_DIR = REPO_ROOT / "lib" / "ui"

# File allowed to reference the dark constants: the token definitions.
WHITELIST_FILES = {"theme.dart"}

BANNED_TOKENS = (
    "ZColors.dark",  # darkBackground / darkCard / darkSidebar / darkSecondary
    "ZColors.neutral700",
    "ZColors.neutral800",
    "ZColors.neutral900",
    "ZColors.neutral950",
    "ZColors.pillRunningBg",
)

# Opaque very-dark RGB (the 0x00-0x2F red channel band). Bright/alpha-prefixed
# literals (0x14FFFFFF hairlines etc.) do not match.
DARK_HEX_RE = re.compile(r"0xFF[0-2][0-9A-Fa-f]{4}")

# A line carries its own brightness guard: `isDark ? …`, `… == Brightness.dark`,
# `ZInk.isDark(...)`, or is the `?` arm of a ternary whose condition sits on an
# earlier line.
GUARD_RE = re.compile(
    r"isDark\b|Brightness\.dark|_dark\(|^\s*\?\s*ZColors\."
)


def code_part(line: str) -> str:
    """Strip a trailing // comment (hex literals and ZColors names never
    appear inside string literals in this tree, and '//' in string URLs
    cannot precede either pattern)."""
    return line.split("//", 1)[0]


def violations(path: Path) -> list[str]:
    found: list[str] = []
    for no, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        stripped = raw.strip()
        if not stripped or stripped.startswith("//") or stripped.startswith("*"):
            continue
        code = code_part(raw)
        hit = None
        if any(token in code for token in BANNED_TOKENS) and not GUARD_RE.search(raw):
            hit = next(t for t in BANNED_TOKENS if t in code)
        elif DARK_HEX_RE.search(code):
            hit = DARK_HEX_RE.search(code).group(0)
        if hit:
            found.append(f"  {path.relative_to(REPO_ROOT)}:{no}: {hit} — {stripped}")
    return found


def main() -> int:
    bad: list[str] = []
    for path in sorted(SCAN_DIR.rglob("*.dart")):
        if path.name in WHITELIST_FILES:
            continue
        bad.extend(violations(path))
    if bad:
        print("ui_color_guard: hardcoded dark surfaces found:\n" + "\n".join(bad),
              file=sys.stderr)
        print("Read them through a ZInk slot (lib/ui/theme.dart) instead.",
              file=sys.stderr)
        return 1
    print("ui_color_guard: OK (lib/ui free of hardcoded dark surfaces)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
