# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.14.1] - 2026-10-08

### Added

- **Fork & deferred drafts**: fork ack carries the new session id and the
  app jumps straight into the forked session; session-only rows surface
  in session lists; `deleteSession` wired end-to-end; draft rows
  delete/route/gate correctly.
- **Cross-terminal delete banner**: a session deleted from another
  terminal shows a tombstone banner; its retry rides the unified reload
  entry.
- **Tri-strike link protection**: the strike ledger and escalation
  (LinkSupervisor) now cover every send path with managed channel
  listeners.
- **Framework localizations wired**, plus localized thought section
  titles and a fork-page theme button.
- **Landscape density**: compact header, collapsed composer, workspace
  chip inline.
- **UI polish**: copy feedback as a 1.2s icon morph, sky-brand FABs and
  sliders, indented setting subrows, live device meta, desktop sidebar
  group dots.

### Changed

- **Architecture deepening**: send/queue decision (`sendTextOrQueue`),
  rowsRange fallback chain (`parseRowsRangeResponse`) and history-load
  decisions (`HistoryPager`) each get a single home; `conversation.dart`
  splits into four files behind a barrel; lexicon moves to `lib/i18n/`;
  ask-question answers become a value object (`InteractionAnswers`);
  `ConfirmGate` unifies the held-window confirm timers; `workspaceForKey`
  sinks into TaskDirectory; the subagent detail page joins the
  SubagentFeed pool.
- **Switch resilience**: a bridge-lost model/thought switch auto-retries
  once before reverting; the revert trace arms on lost ack only;
  epoch-drifted history pages now apply in sheet and detail too.

### Fixed

- **Task mutations address the owning workspace** (per-taskId scope) —
  cross-workspace list operations no longer fail `resolveTaskAddress`;
  task rows stay pinned to their live-confirmed workspace home across
  bridge swings; locally-confirmed deletes tombstone immediately.
- Task-list radio freeze, empty groups and group-dot parity; composer
  cursor visible in the empty state; inline agent timeline stays at the
  tail window; reload-window input guard.

## [1.14.0] - 2026-09-29

The debut release under the ZGo name.

### Changed

- **ZGo.** New name, new icon, new home
  ([github.com/KiMelody/ZGo](https://github.com/KiMelody/ZGo)): display
  name, update-check coordinates and the about page all point here now.
  The application id changes with the name
  (`org.kimelody.zgo`): install fresh, re-pair your devices, then
  remove the old app.
- Version 1.14.0+21.

### Added

- Bundled font licenses (OFL / Apache-2.0) surfaced through the
  in-app licenses page.
- Release artifacts published as `ZGo-<tag>.apk`.
