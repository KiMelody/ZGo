# Store screenshots

The App Store sets are **full-bleed captures of the real app** (Guideline
2.3.3: screenshots must show the app in use — no marketing composites),
captured natively on the iOS simulator with seeded fake data, then assembled
by `tool/make_appstore_screenshots.py`. The framed marketing composites this
slot used before the 2.3.3 rejection are kept in
`appstore/screenshots/archive-framed/`; Google Play still uses framed
composites from `tool/gen_store_assets.py`.

## Layout

```
docs/screenshots/
├── raw/           iPhone 17 Pro Max captures, native 1320×2868 (6.9" slot)
│                  {01-devices,02-tasks,03-chat,04-automations}-{en,zh}.png
├── raw-ipad/      iPad Pro 13" captures, native 2064×2752 (13" slot)
│                  same 4 pages + 05-dualpane-{en,zh}.png
├── iphone/        unframed fallback at 1290×2796 (regenerated, = 6.7" set)
└── play/          legacy Play-size fallbacks (not regenerated)
```

Store sets under `docs/store/appstore/screenshots/`:

- `iphone-6.9/` — 1320×2868 native copies of `raw/` (01–04, en+zh)
- `iphone-6.7/` — same set scaled/center-cropped to 1290×2796
- `ipad-13/`    — 2064×2752 portrait `raw-ipad/05-dualpane-{en,zh}.png`
- `archive-framed/` — pre-rejection framed marketing composites (do not upload)

## Capture

Run on booted simulators (iPhone 17 Pro Max = 6.9" native size, iPad Pro
13" = 13" native size), once per language:

```bash
xcrun simctl boot "iPhone 17 Pro Max"
ZLINKER_SHOT_DIR=docs/screenshots/raw flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/screenshots_test.dart \
  -d <iphone-udid> --dart-define=SHOT_LOCALE=zh-CN
# repeat with SHOT_LOCALE=en-US

xcrun simctl boot "iPad Pro 13-inch (M5)"
ZLINKER_SHOT_DIR=docs/screenshots/raw-ipad flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/screenshots_test.dart \
  -d <ipad-udid> --dart-define=SHOT_LOCALE=zh-CN
# repeat with SHOT_LOCALE=en-US
```

- `SHOT_LOCALE` switches the app UI language AND the seeded data language.
- The test injects a fake `DeviceSessionHub` — a real hub would dial the
  seeded (bogus) relay URLs and retry forever, so `pumpAndSettle` never
  settles.
- Pages driven by async data (automations list, the dual-pane conversation)
  are pumped in repeated short frames so the capture happens after their
  data lands; the automation port is prewarmed in the test body.
- `05-dualpane` only renders when the surface is ≥768dp wide (iPad).
- Do not point `ZLINKER_SHOT_DIR` for the iPad run at `raw/` — the first
  four page names would overwrite the iPhone captures.

## Assemble

```bash
python3 tool/make_appstore_screenshots.py
```

Copy text lives in `fastlane/metadata/{zh-Hans,en-US}` and
`docs/store/*/copy/`; feature graphic and Play icon are in
`docs/store/googleplay/`.
