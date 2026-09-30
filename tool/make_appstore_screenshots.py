#!/usr/bin/env python3
"""Assemble the App Store screenshot sets from the native iOS captures.

Per Guideline 2.3.3 the store screenshots must show the app in use, so the
upload sets are the unframed, full-bleed captures straight from the iOS
simulator (no marketing overlays — those live on in archive-framed/):

  docs/screenshots/raw/          iPhone 17 Pro Max, native 1320x2868 -> 6.9" set
  docs/screenshots/raw-ipad/     iPad Pro 13", native 2064x2752      -> 13" set
  iphone-6.7/                    width-scaled copy of the 6.9" set at 1290x2796
  docs/screenshots/iphone/       unframed fallback at 1290x2796 (kept in sync)

Capture them first (see docs/store/SCREENSHOTS.md), then run:
    python3 tool/make_appstore_screenshots.py
"""
import os
import shutil

from PIL import Image

ROOT = os.path.join(os.path.dirname(__file__), "..")
RAW = os.path.join(ROOT, "docs", "screenshots", "raw")
RAW_IPAD = os.path.join(ROOT, "docs", "screenshots", "raw-ipad")
OUT = os.path.join(ROOT, "docs", "store", "appstore", "screenshots")
FALLBACK = os.path.join(ROOT, "docs", "screenshots", "iphone")

PAGES = ["01-devices", "02-tasks", "03-chat", "04-automations"]
LANGS = ["en", "zh"]


def store(path, img):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path)
    print("wrote", os.path.relpath(path, ROOT))


def scale_to_width(img, width, height):
    scaled = img.resize((width, round(img.height * width / img.width)),
                        Image.LANCZOS)
    top = (scaled.height - height) // 2
    return scaled.crop((0, top, width, top + height))


def main():
    for lang in LANGS:
        for page in PAGES:
            src = os.path.join(RAW, f"{page}-{lang}.png")
            with Image.open(src) as im:
                # 6.9" set: native capture, byte-for-byte copy.
                shutil.copyfile(
                    src, os.path.join(OUT, "iphone-6.9", f"{page}-{lang}.png"))
                # 6.7" set: 1290x2796 (scale by width, center-crop the rest).
                store(os.path.join(OUT, "iphone-6.7", f"{page}-{lang}.png"),
                      scale_to_width(im, 1290, 2796))
                # Unframed fallback dir, kept at the 6.7" size.
                store(os.path.join(FALLBACK, f"{page}-{lang}.png"),
                      scale_to_width(im, 1290, 2796))

        # iPad 13": native portrait dual-pane capture.
        shutil.copyfile(
            os.path.join(RAW_IPAD, f"05-dualpane-{lang}.png"),
            os.path.join(OUT, "ipad-13", f"01-dualpane-{lang}.png"))
        print("wrote", os.path.relpath(
            os.path.join(OUT, "ipad-13", f"01-dualpane-{lang}.png"), ROOT))


if __name__ == "__main__":
    main()
