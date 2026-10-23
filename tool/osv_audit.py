#!/usr/bin/env python3
"""Audit the dependency stack against the OSV vulnerability database.

Reads every package pinned in pubspec.lock, batch-queries api.osv.dev (the
GHSA data pub.dev's security advisories are built on), and additionally
probes the bundled pdf.js asset as npm pdfjs-dist — the one shipped
dependency whose version pub does not track.

Usage:
    python tool/osv_audit.py

Exit code: 0 = no known advisories, 1 = at least one hit, 2 = query failed.
Run before tagging a release, or whenever a new CVE makes the news.
"""

from __future__ import annotations

import json
import re
import sys
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
LOCK_FILE = REPO_ROOT / "pubspec.lock"
PDFJS_BUNDLE = REPO_ROOT / "assets" / "pdfjs" / "pdf.min.mjs"
OSV_BATCH_URL = "https://api.osv.dev/v1/querybatch"


def pub_lock_deps() -> dict[str, str]:
    """Package name -> locked version, skipping sdk-only 0.0.0 sections."""
    deps: dict[str, str] = {}
    name = None
    for line in LOCK_FILE.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^  ([a-z0-9_]+):", line)
        if m:
            name = m.group(1)
        m = re.match(r'^    version: "?(.+?)"?\s*$', line)
        if m and name and m.group(1) != "0.0.0":
            deps[name] = m.group(1)
    return deps


def pdfjs_version() -> str | None:
    text = PDFJS_BUNDLE.read_text(encoding="utf-8", errors="ignore")
    m = re.search(r'apiVersion:"([\d.]+)"', text)
    return m.group(1) if m else None


def main() -> int:
    deps = pub_lock_deps()
    queries = [
        {"package": {"name": n, "ecosystem": "Pub"}, "version": v}
        for n, v in sorted(deps.items())
    ]
    pdfjs = pdfjs_version()
    if pdfjs:
        queries.append(
            {"package": {"name": "pdfjs-dist", "ecosystem": "npm"}, "version": pdfjs}
        )
    else:
        print("note: pdf.js version not found in assets/pdfjs/ — skipped")

    try:
        req = urllib.request.Request(
            OSV_BATCH_URL,
            data=json.dumps({"queries": queries}).encode(),
            headers={"Content-Type": "application/json"},
        )
        results = json.loads(urllib.request.urlopen(req, timeout=120).read())[
            "results"
        ]
    except Exception as e:  # noqa: BLE001 — report and bail, not crash
        print(f"OSV query failed: {e}", file=sys.stderr)
        return 2

    hits = 0
    for q, r in zip(queries, results):
        for v in r.get("vulns", []):
            # The batch endpoint returns trimmed records (id only) — fetch the
            # full advisory lazily, only when there is something to report.
            with urllib.request.urlopen(
                f"https://api.osv.dev/v1/vulns/{v['id']}", timeout=30
            ) as resp:
                v = json.loads(resp.read())
            hits += 1
            ident = ", ".join(v.get("aliases", [])) or v["id"]
            print(f"HIT {q['package']['name']}@{q['version']} — {ident}")
            print(f"     {v.get('summary', '')}")
            fixed = {
                ev["fixed"]
                for a in v.get("affected", [])
                if a.get("package", {}).get("name") == q["package"]["name"]
                for rg in a.get("ranges", [])
                for ev in rg.get("events", [])
                if "fixed" in ev
            }
            if fixed:
                print(f"     fixed in: {', '.join(sorted(fixed))}")

    print(f"{len(queries)} packages checked against OSV — {hits} hit(s).")
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
