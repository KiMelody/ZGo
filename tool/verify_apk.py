#!/usr/bin/env python3
"""Verify release APK/AAB artifacts contain the Flutter plugin classes.

An artifact built while `.flutter-plugins-dependencies` was missing (e.g.
`flutter build --no-pub` after a failed `pub get`) is an "empty shell": no
plugin project joins the Gradle build, so the DEX carries no plugin classes
and every platform channel fails at runtime with `channel-error` (2026-11-02
incident). The marker classes below are compiled in whenever plugin
registration works, so a zero count means the build pipeline is broken — fail
the artifact instead of shipping it.

`GeneratedPluginRegistrant` is NOT a usable marker: the Flutter embedding
keeps its class name as a reflection string even in an empty shell.

Usage:
    python3 tool/verify_apk.py <artifact.apk|.aab> [more artifacts...]

Exit code: 0 = every artifact PASSes, 1 = any FAIL (missing marker, file not
found, no .dex), 2 = usage error.
"""

from __future__ import annotations

import sys
import zipfile
from pathlib import Path

MARKERS = (
    "SharedPreferencesPlugin",
    "MobileScannerPlugin",
    "FlutterSecureStoragePlugin",
    "FlutterLocalNotificationsPlugin",
    "HomeWidgetPlugin",
)

USAGE = (
    "usage: python3 tool/verify_apk.py <artifact.apk|.aab> "
    "[more artifacts...]"
)


def verify(path: Path) -> bool:
    """Scan every DEX member of one artifact and print its verdict."""
    if not path.is_file():
        print(f"FAIL {path}")
        print("  file not found")
        return False
    try:
        with zipfile.ZipFile(path) as archive:
            # APK: classes*.dex; AAB: base/dex/classes*.dex — any depth.
            members = [n for n in archive.namelist() if n.endswith(".dex")]
            if not members:
                print(f"FAIL {path}")
                print("  no .dex entries")
                return False
            counts = {
                marker: sum(
                    archive.read(name).count(marker.encode())
                    for name in members
                )
                for marker in MARKERS
            }
    except (OSError, zipfile.BadZipFile) as exc:
        print(f"FAIL {path}")
        print(f"  unreadable archive: {exc}")
        return False

    counts_line = "  ".join(f"{m}={c}" for m, c in counts.items())
    missing = [m for m, c in counts.items() if c == 0]
    if not missing:
        print(f"PASS {path}")
        print(f"  {counts_line}")
        return True
    print(f"FAIL {path}")
    print(f"  {counts_line}")
    for marker in missing:
        print(f"  missing: {marker}")
    return False


def main(argv: list[str]) -> int:
    if not argv:
        print(USAGE, file=sys.stderr)
        return 2
    results = [verify(Path(raw)) for raw in argv]
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
