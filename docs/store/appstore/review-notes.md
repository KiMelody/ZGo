# App Review Notes — ZLinker 1.6.1 (10)

## 1. Screen recording

Two recordings are attached:

- `docs/demo/zlinker-add-device.mp4` — scripted walkthrough of the onboarding
  flow: empty device list → tap "Add device" → paste pairing URL → confirm →
  device appears in the list → settings page (theme / language / notifications).
- `docs/store/appstore/zlinker-review-demo.mp4` — device list with connected
  desktops → native task list (pinned group, running/completed/queued states) →
  full conversation (streaming markdown reply, file-change summary).

No account registration / login / paid content / user-generated content /
sensitive-permission prompts are present in the app, so those flows do not
appear in the recordings.

## 2. Tested devices and OS versions

- iPhone 16 Pro — iOS 26 (simulator)
- iPad Pro 13-inch — iPadOS 26 (simulator)
- Pixel-class Android emulator — Android 14 (cross-platform build sanity check)

## 3. App functions and target audience

ZLinker is a mobile remote client for ZCode, a desktop AI coding agent. It
speaks ZCode's native protocol and lets the developer monitor and control
their desktop agent from a phone: live task list with running state and
reply previews, stop/pause/resume, full streaming conversations with tool
diffs and file changes, scheduled automations, off-peak task queueing and
push notifications.

Target audience: developers who already run ZCode on their desktop and want
to keep an eye on long-running agent tasks while away from the machine. The
value is turning dead time (commute, meetings) into productive oversight of
agent work.

## 4. Setup and access instructions

No account, no login, no subscription. The app pairs with the user's own
desktop ZCode instance:

1. On the desktop, open ZCode → Settings → Remote Control → enable. This
   shows a QR code and a pairing URL.
2. In ZLinker, tap "+" on the device list, scan the QR code (or paste the
   URL). The device appears in the list with a live connection dot.
3. Tap the device to open its task list; tap a task to open the conversation.

If the reviewer does not have a ZCode desktop instance, the app still opens
and shows the empty state with the add-device instructions; the demo video
shows the paired flow end-to-end.

## 5. External services

- **ZCode desktop instance** (user's own machine, via WebSocket relay) —
  source of all task/conversation data.
- **Z.ai relay** (`zcode.z.ai`) — the pairing QR codes route through this
  relay so phone and desktop can find each other across networks.
- **AI models** (GLM series) — run on the desktop ZCode instance, not in the
  app. ZLinker only renders the streamed output.

No payment processor, analytics SDK, advertising SDK, or third-party data
broker is integrated.

## 6. Regional differences

None. Feature set is identical in all regions.

## 7. Regulated industry / protected content

Not applicable. ZLinker is a developer tool, does not operate in a regulated
industry, and does not include protected third-party material.

---

**Privacy note:** pairing links and device data are stored only on the user's
phone (SharedPreferences). No telemetry leaves the device except the direct
connection to the user's own desktop and the Z.ai pairing relay.
