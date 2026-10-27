# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.15.2] - 2026-10-27

### Changed

- **Bridge window gate**: degradation chain and recovery addressing —
  workspaces outside the gated window resolve via the secondary leg, the
  relayed leg and form-B drafts; the addressing bridge replays pending
  requests on recovery; a draft's first send is guarded (10 s handshake
  fast-fail with earlier feedback, silent-chain fix).
- **Quota monitoring cadence**: the background poll now cooperates with the
  keep-alive switch — the forced 5-minute silent backoff after un-pausing
  no longer applies while keep-alive is active (toggling only re-arms the
  timer, no extra RPC); failure backoff stays independent; returning to the
  foreground triggers an immediate refresh behind a 60 s staleness gate.

### Fixed

- **Workspace card ordering**: cards sort by the same recent-activity
  timestamp shown on the card's time chip — completion-appended entries no
  longer sink to the bottom; keyless/empty/archive-only workspaces stay
  last in stable title order; the archived view follows the same order.

## [1.15.1] - 2026-10-26

### Added

- **Plan auto-switch**: when the Start plan runs out or expires, chat
  switches automatically to an available subscription (three trigger
  signals, same-`modelId` preference, per-session dedup), and a plan
  expiry banner closes the gap where expiry was completely silent.

### Changed

- **Usage page**: subscription and Start snapshots render side by side
  (providerId-keyed pollers, latest-`updatedAt` task derivation, reset
  scope aligned with accountAccess). Remaining-semantics unified across
  bars and big numbers — limit percentages and bar fills inverted so a
  short red bar means "nearly exhausted"; token counts abbreviated
  k/M/B; larger limit-row figures; mirror-card dual-% template;
  localized ISO timestamps; plan-card titles fall back to the provider
  name; 6 dp progress-bar token; 17 dp placeholder keeps row height on
  plans without a time column.
- **Android build**: release CI ships arm64 / arm32 / universal APKs
  instead of one fat artifact — arm64 payload 92.85 → 36.6 MB; R8
  minify + resource shrinking enabled (dex halved; the lasting value
  is obfuscation and the mapping file).

### Fixed

- **Entitlement routing**: plan snapshots resolve by the entitled flag —
  starter-account detection fixed, Start bucket projection normalized.
- **Model catalog**: provider groups without entitlement are hidden
  from the config panel; Z.AI/BigModel same-name families disambiguated
  with a prefix on the providers page.
- **Start snapshot percentage scale**: the wire carries a 0..1 decimal
  remaining ratio (asar S3 verdict) — normalized as (1−p)×100 instead
  of the previous misread.
- **Task list**: the default workspace card stays resident — wire
  entries carrying `workspacePurpose: 'conversation'` were wrongly
  dropped by the conversation-workspace predicate; the
  `/.zcode/workspace/default` suffix path is now exempt (draft- folding
  and the purpose enum unchanged). Workspace completion moves onto the
  bootstrap frame, mergeProjectWorkspaces gains a home-synthesis
  fallback, and list growth re-dials from the merged full set.

## [1.15.0] - 2026-10-23

### Added

- **ZCode 3.16.2 adaptation**: Relay V2 account authentication (token API
  + ws2 transport + auth_init; link-shape fallback keeps hash-link V1
  desktops on the old path). The task overview rebuilds on `listTaskList`
  three legs (timeline / pinned / archived) with dual-read row form
  (`displayStatus ?? status`) after bootstrap stopped carrying tasks.
  Project-layer ownership: `ProjectResolver` learns root→projectId from
  the desktop tasks-index.sqlite through a pure-Dart paged reader (8 reads
  / 28 KiB on a 24.9 MB index; the sqlite3 dependency is gone), and
  `createSession` injects the outer projectId. Workspace completion:
  bootstrap's single-window workspace registry is unioned with project
  roots (`mergeProjectWorkspaces`; wire entries first, path-normalized
  dedup, zero-allocation no-op on old desktops), and conversation draft
  workspaces fold into the default card (draft- path predicate) instead
  of spawning orphan cards.
- **Cloud device catalog**: devices in the account connect one-tap from
  the devices page (GET /device, mid dedup, three-state partition
  listing not-added devices only).
- **Chat draft persistence**: composer text and attachments survive app
  restarts — `ChatDraftStore` keeps metadata in prefs and bytes under
  appSupport, with 20-entry / 32 KiB / 64 MiB oldest-first caps, orphan
  sweep, and 500 ms debounced writes.
- **Conversation badge**: session rows inside default cards carry a
  conversation-type marker.

### Changed

- **Release gate**: CI now runs an OSV dependency vulnerability audit
  (`tool/osv_audit.py`, 140 packages incl. pdf.js probing) before
  building artifacts; transient network failures retry then degrade to
  a warning.

### Fixed

- **Relay V2 auth-failure convergence**: token rejection reaches a
  circuit-breaker terminal state with backoff re-ratio and login
  self-heal instead of retry storms.
- **Bridge restore failure memory**: reconnects doomed by missing
  workspace windows are remembered and skipped.
- **Resolver home derivation**: falls back to the last successful value
  when the single-window registry lacks a workspace entry.

## [1.14.5] - 2026-10-20

### Added

- **File preview system**: chat file previews render by type — markdown
  (AppMarkdown + highlighting), SVG (sandboxed zero-bridge WebView),
  source code (`re_highlight` 24 grammars on the ZInk palette, 32 KiB
  linear-render threshold), and PDF (pdf.js 5.4.296 in a sandboxed
  WebView; dataUrl / whole-read / range transport, three read-only
  handlers, 8 s watchdog). Text files get graded rendering: 2 MiB cap
  with 96 KiB line-aligned chunked SelectionArea virtualization.
- **Chunked file reads**: reads loop in 256 KB steps up to a 2 MiB cap,
  defeating the server-side silent truncation above 256 KB; a
  five-state `FileReadFailure` classification (ENOENT / isBinary /
  empty / tooLarge) with a binary-extension fallback dispatch replaces
  the single-shot read.
- **Preview entry points**: the task-search file tab and the Git review
  panel route through the same `ChatPreview` dispatch, which moved out
  of the shared timeline.
- **readFileRange protocol endpoint**: byte-range reads with TextChunk
  metadata (Uint8Array direct payload, empty payload = terminator),
  wired through ChatGateway/DeviceSession; live probes under `tool/`.

### Changed

- **Edit-and-resend inline card**: global button tokens converged
  (reset = constant gray outline, direct send; send = solid white short
  label); the card goes full-width with the 56 dp gutter removed and
  the three actions on a single row on narrow screens.

### Fixed

- **Android high refresh rate**: MainActivity requests the preferred
  display mode, unlocking 120 Hz panels that were pinned to 60 Hz.
- **Timeline row order**: cold-restored wire rows re-sort within their
  `assistantResponseId` group and non-execute rows flush buffered text,
  fixing inverted/stalled rows after cold resume.

## [1.14.3] - 2026-10-17

### Added

- **Usage heatmap interactions**: month label row plus a tap bubble
  anchored to the hit day (scroll clears it; snapshot refresh and mode
  switches dismiss it); short histories synthesize dates for the null
  leading columns from the first real week's anchor, so month groups
  render even when the window starts mid-month; the heatmap scrollbar
  shows only while dragging instead of sitting permanently visible.
- **Usage trend tap details**: tapping the chart opens a detail bubble
  for the nearest day with an active-dot marker.
- **Desktop 3.15.1 autonomy mode**: `guarded` joins the autonomy
  lexicon (bilingual) and the config write-back whitelist; `edit`
  remains accepted for compatibility with older desktops.
- **Task ownership corrections**: long-pressing a duplicated task row
  opens a dialog to re-assign its owning workspace.

### Changed

- **Trend chart X-axis ticks**: greedy spacing by measured label width
  (first and last ticks always kept, middle ticks yield) replaces the
  previous show-all-up-to-14 / step 5|7 rule, fixing first/last label
  overlap on 360 dp screens.

### Fixed

- **Usage limit rows on narrow screens**: `UsageLimitRow` is extracted
  into its own widget with a two-tier flex that sacrifices in the
  order title tail → clock → right value; smoke-tested at
  320/360/384 dp with quantified truncation assertions.
- **Keyboard-short viewport folding**: a hysteresis probe (100/80 px)
  treats a keyboard-inset viewport as an equivalent short viewport —
  the second header row folds and long banner strings fall back to
  single-slot scrolling; overflow behavior is pinned by a test matrix
  across keyboard dimensions.
- **Task list multi-copy ownership**: per-workspace live snapshot
  caches keep rows from vanishing when switching workspaces; live
  group keys stay stable so rows no longer migrate between groups;
  cold pick prefers pinned rows and exits grouping on terminal
  states, and anchors honor user-corrected ownership.

## [1.14.2] - 2026-10-12

### Added

- **Account plan quota**: plan page with billing balance/current REST
  queries; OAuth device-flow browser sign-in as the primary path
  (polling, cancel, copy-link, timeout/reject retry) with manual JWT
  paste kept as fallback; an explicit expired state via a local expiry
  memo when the server silently empties balances; Noto Sans SC fonts
  bundled.
- **Landscape immersive fullscreen**: system bars hide app-wide in
  landscape (Android immersiveSticky / iOS overlays) and restore in
  portrait, re-asserted idempotently from a root observer; SafeArea,
  manifest and plist stay untouched.

### Changed

- **Composer aligned with official stop/send behavior**: stop
  visibility follows `control.canStop` with an empty composer; tapping
  stop optimistically hides the button and recalibrates on the next
  authoritative write; the redundant skill button is removed and the
  tool-row running-state overflow is closed out (compact + button
  48→40, model/thought chips capped at 150dp).

### Fixed

- **Subscription resilience**: tombstone baselines bind to subscription
  generations, so bridge-swing resubscribes no longer read reseeded
  snapshot gaps as deletes; `sessionNotFound` is a one-way terminal
  state with an authoritative rejection banner and send gating;
  resubscribes back off 3/6/12 s; `deviceInfo.updatedAt` backfilled on
  view-state updates; diagnostic `failureReason` sanitized
  (`kicked` → `session-conflict`).
- **Task list & session operations**: duplicate-id rows resolve display
  status by terminal-first precedence (no more zombie running rows);
  chat-page delete routes through `deleteTask` (persistent soft delete,
  draft-row fallback), fixing the delete-revive loop; mutation scope
  row selection aligns with `TaskDirectory.byId`; failure-toast prefix
  no longer leaks a literal `$0`.

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
