#!/usr/bin/env python3
"""CI warning: lib/ui icon-only buttons should carry a screen-reader name.

A bare `IconButton(` paints a glyph with no text, so TalkBack announces an
unnamed button. The accepted fix in this tree is a `tooltip:` (IconButton
hangs it off the button node's semantics data — one string serves both the
long-press bubble and the screen reader) or an explicit `semanticLabel:`.

This script counts `IconButton(` constructions that have neither within the
next 10 lines and compares the total against BASELINE:

  * equal to BASELINE  -> OK
  * below BASELINE     -> OK, with a nudge to lower the constant
  * above BASELINE     -> WARN lines with the file:line list, still exit 0

Scope decisions, so the numbers stay low-noise:

  1. Location of the call is irrelevant: `IconButton(` is counted wherever it
     starts on a line (`return IconButton(`, `child: IconButton(`,
     `suffixIcon: IconButton(`, …). A narrower "line starts with IconButton("
     rule silently skips 4 of the 57 sites in this tree — including the two
     assistant-feedback buttons this guard was built to keep fixed.
     `IconButton.styleFrom(` is a style factory, not a button: excluded.
  2. `InkWell` is NOT scanned. The tree carries 19 of them and their children
     are readable text/cards — TalkBack already reads the content, so
     flagging them would be 19 permanent warnings (design V6).
  3. Only `*.dart` under `lib/ui` is read, matching `ui_color_guard.py`. The
     non-Dart `lib/ui/devices_page.dart` is outside that surface (design V8).
  4. A hit is a WARNING, never a failure. `flutter analyze` already gates the
     build at zero warnings; turning this into an error would add a second
     blocking gate for a cosmetic-only regression.

Whitelist matches `ui_color_guard.py`: theme.dart (token definitions, no
controls) and image_viewer_page.dart (theme-independent full-screen viewer).

Run standalone: `python tool/a11y_label_guard.py`.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCAN_DIR = REPO_ROOT / "lib" / "ui"

WHITELIST_FILES = {"theme.dart", "image_viewer_page.dart"}

# How far past the `IconButton(` line the label may sit: the constructor args
# in this tree wrap at most a handful of lines before `tooltip:`/`onPressed:`.
WINDOW = 10

ICON_BUTTON_RE = re.compile(r"(?<![\w$.])IconButton(?:\.(?!styleFrom)\w+)?\s*\(")
LABEL_RE = re.compile(r"tooltip\s*:|semanticLabel\s*:")

# Measured 2026-11-07 (HEAD=bd44cde + this task's three label fixes): 13
# unlabeled IconButton constructions. HEAD alone measured 15; the diff is the
# two assistant-feedback buttons (_FeedbackButton / _CopyFeedbackButton) that
# took `chat.copyCode` / `chat.feedback.*` tooltips. The thirteen pre-existing
# hits are out of this task's scope and are held by this baseline, so a NEW
# unlabeled button is what trips the warning.
#
# Note (artifact drift, measured not assumed): an earlier plan expected
# "12 → 9" from a start-of-line-only rule. That rule cannot see `return
# IconButton(` at all, so it never counted the two timeline buttons this task
# fixed, and it counted `remote_page.dart:216` — which is the pre-existing
# refresh button, not child 04's new "back to native" one (that one sits at
# :208 and already carries `remote.backToNative`). The baseline below is the
# real post-fix count.
BASELINE = 13


def unlabeled(path: Path) -> list[int]:
    lines = path.read_text(encoding="utf-8").splitlines()
    found: list[int] = []
    for index, raw in enumerate(lines):
        stripped = raw.strip()
        if stripped.startswith("//") or stripped.startswith("*"):
            continue
        if not ICON_BUTTON_RE.search(raw):
            continue
        window = "\n".join(lines[index : index + WINDOW + 1])
        if not LABEL_RE.search(window):
            found.append(index + 1)
    return found


def main() -> int:
    hits: list[tuple[Path, int]] = []
    for path in sorted(SCAN_DIR.rglob("*.dart")):
        if path.name in WHITELIST_FILES:
            continue
        hits.extend((path, line) for line in unlabeled(path))

    count = len(hits)
    if count > BASELINE:
        print(
            f"a11y_label_guard: WARN: {count} unlabeled IconButton "
            f"(+{count - BASELINE} above baseline {BASELINE})"
        )
        for path, line in hits:
            print(f"  {path.relative_to(REPO_ROOT)}:{line}")
        print(
            "Give each one a `tooltip:` (TalkBack reads it) or a "
            "`semanticLabel:`. Non-blocking: investigate when convenient.",
        )
        return 0

    if count == BASELINE:
        print(
            f"a11y_label_guard: OK ({count} unlabeled IconButton, "
            f"at baseline {BASELINE})"
        )
    else:
        print(
            f"a11y_label_guard: OK ({count}, below baseline {BASELINE} — "
            f"lower the constant)"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())