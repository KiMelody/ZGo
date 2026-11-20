# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.16.8] - 2026-11-20

### Added

- **OLED pure-black theme**: a global theme flag flattens all surfaces to black with semantic ink awareness, plus a subtle five-slot elevation ladder for cards, tiles and code blocks
- Two-stage splash theme: a fixed brand-dark first stage followed by the in-app theme
- Redesigned launcher icon (L6e pipeline) with adaptive/monochrome layers, splash density buckets and notification icon

### Changed

- Chat list scrolling: image decode by display size, hop-based cache eviction, subtree and instance memoization, single-pass grouping
- Task list scrolling: narrow signal splitting and row-level keys

### Fixed

- Jump-to-location chain and blank rendering in long conversations

## [1.16.7] - 2026-11-18

### Added

- Cold-runtime fallback leg for waking from legacy desktop, with provider-not-ready probing and self-healing
- Workspace-level dormant marker and banner online-state convergence

### Fixed

- Cold runtime no longer auto-wakes; degrades gracefully when provider is not ready
- Resume single-shot probe self-heals the cold-runtime banner
- Dedupe workspace-level banner text against similar toasts
- ACK frame now carries bridge identity fields and discards stale-generation assembly

## [1.16.5] - 2026-11-15

### Added

- **Side conversations**: `/side` and `/btw` slash commands spawn
  auxiliary chats as tabs over the main conversation — pill tab bar
  with long-press close/destroy menu (destroy behind a confirm
  dialog), chromeless sub-pages, and restricted command entries gated
  inside side chats.
- **Selection quote & annotation**: long-press a message to quote a
  freely selected passage (optional annotation); the quote chip rides
  the next outgoing message via structured `conversationQuotes` —
  replay-queue passthrough with runtime-enforced limits (8 quotes,
  8,000 chars each, 16,000 total, 2,000 annotation).
- **Archive deletion three-stage flow**: window-controller port with
  lazy degradation; preview and idempotent execution in the task list.
- **V4 command reconcile**: `queryConversationCommandsV4` parsing with
  single-leg batched queries, a command ledger with degradation gate,
  downgrade-timeout pending chips, resend pre-check (re-open the
  entry session before resending), and ledger lifetime lifted above
  the transport so workspace switches no longer drop pending commands.
- **Worktree branch chip**: read-only branch name on task rows,
  pinned cards and the desktop sidebar, with connection-level
  negative caching when the Git channel is absent.

### Changed

- **Row-action availability gating**: sheet edit/fork/rewind and
  related entries now consume desktop-pushed row-level actions
  (`canFork`/`canEdit`/`canRewindFiles`); a missing key hides the
  entry, and conversations that never surfaced actions fall back to
  the previous rendering.

### Fixed

- **Row-action sheet unreachable on device**: message text and
  assistant markdown downgraded from SelectableText (it captured the
  long-press inside row gesture detectors); copy buttons preserved
  and free selection moved to the quote view.
- **Slash popup overflow** on compressed viewports: height capped at
  40% of the body with internal scrolling.
- **Closing the active side tab** no longer sends a bare view-state
  clear (dispose read a stale isActive).
- **Empty body with a quote attached** now toasts instead of being
  silently swallowed (no wire call; send button stays enabled).
- **Ledger retry guard**: in-flight resends are no longer
  double-sent, and retry/TTL timers terminate on dispose.

## [1.16.0] - 2026-11-10

### Added

- **Notification tap hand-off**: task notifications now carry workspace
  attribution (raw-row scope fallback); tapping opens a transition page
  that waits out transient attribution, classifies failures with retry,
  and lands on the right conversation. Cold-start taps are delivered via
  a launch-payload latch (fixes silent drop after process death), and
  completed-task notifications are re-delivered on foreground return
  (differential-baseline fix).
- **Task error details**: task rows preview `lastError` and open an
  error detail sheet with the concrete error text.
- **Desktop show-reasoning setting**: third desktop-settings card
  (`messageStreamShowReasoning`), optimistic merge with failure
  SnackBar, zh/en copy.
- **Scan-to-pair shortcut** on the devices empty state: one-hop entry
  into the full pairing chain.
- **Usage reset-card entry**: header-row reset button reusing the quota
  reset dialog; buttons aligned with the chat reset-coupon green style.
- **Connection state visibility**: hand-off loading/failure no longer
  navigates into a doomed page; WebView failure returns to native;
  three-state stage copy across devices/task-list/off-peak pages.

### Changed

- **Preview link resolution hardening**: local-link entry decodes
  URL-encoded paths; per-file link resolution splits into layered
  parsing — context-base relative links, bounded filename search, and
  an absolute-path basename fallback via a candidate sheet.
- **Actionable failure copy**: subscription failures classified
  (runtime not running / connection not ready); hot-path logs behind
  `kDebugMode`; global error hooks log without swallowing.
- **CI quality gates**: token-discipline and a11y label-guard gates now
  block in CI; keyboard focus-survival regression net extended to the
  search and provider-settings pages.
- **Harmony workflow**: intentional-decision register + HAP artifact
  gate.

### Fixed

- **Interaction trust series**: zero-feedback actions now give SnackBar
  feedback, chip touch targets meet size guidance, task-list sync state,
  notification permission guidance.
- **Queue command & keep-alive failures**: five queue commands roll back
  and toast on failure (local inverse op for queue item removal);
  keep-alive flips back on failure instead of silently staying on.
- **Cross-workspace orphan session auto-restore**: the previous
  conversation recovers automatically after a workspace switch.
- **Thought-level tier chain**: switching models updates tiers instantly,
  draft validates against the target model's table, and the sheet tier
  region redraws in place after switching models in draft.

## [1.15.7] - 2026-11-05

### Added

- **Encrypted device backup v2**: passphrase-encrypted credentials with a
  file/share export channel — restore on a new device without re-login.
- **Workflow run panel**: typed views + official settled projection in the
  protocol layer; tool cards (create / resume / get / list), a read-only
  run detail page, and a session section listing ended runs; zh/en copy,
  44×48 chevron targets, sheet auto-close that never removes a drill-in
  route, and actor-count summary fallback when nobody is running.
- **APK artifact gate**: `tool/verify_apk.py` self-check for release
  artifacts (fails on an "empty shell" build with no plugin classes) plus
  device-list load-error states.

### Fixed

- **Sidecar reliability series**: cooldown activity release (30 s-level
  recovery of the cold-runtime 10 min blind spot), workspace-switch
  carry-over (sidecar data survives bridge re-attach; phase-flicker fix,
  TTL-exempt running rows with a 10 min hard cap), ranked set 5→12 with
  key-lexicographic tie-break (slot-flip jitter under equal `updatedAt`),
  and a regression lock for the cold-reject-keeps-stale branch.
- **3.17.2 tool progress stall**: desktop 3.17.2 replaced the tool
  progress face (bytes/previewLine → fraction/total/message) while ZGo
  only understood the old face, freezing running tool rows — a content
  watchdog (three mutually exclusive criteria, 20 s→40/80/120 s backoff),
  progress faces rendered through the shared timeline (`_ProgressRow`
  segments, Bash `outputPreview` tail window, terminal two-layer
  collapse), and the content clock now survives resubscribes.

## [1.15.5] - 2026-11-01

### Added

- **Task grouping via sqlite direct read**: organize-panel task groups are
  read straight from the desktop sqlite store after the RPC was removed in
  desktop 3.17.1 (pure-Dart page reader); archived tasks can now be deleted
  (`deleteArchivedTask(s)` adaptation), and workspace cards gained an
  alphabetical sort group (`activity` / `nameAsc` / `nameDesc`).
- **Inactive workspace runtime truth**: running/terminal state for
  workspaces without an open terminal comes from a sidecar
  `sessions-index` subscription merged under a four-tier priority; new
  sessions in inactive workspaces refresh via a dual trigger (create edge
  at 0 ms + terminal-state edge, bypassing the anti-flap throttle),
  fixing 20 s-level card staleness; cold start shows an inactive-card
  skeleton with persisted activity keys.
- **Workspace runtime cold-start routing**: dedicated sentinel for the
  window-gate dead end, consumer-point copy in four places, watchdog
  parking with forced reopen.
- **Plan empty-window rendering**: `plans[]` from the balance response
  enters the snapshot; the active card wins over expired/none copy.

### Changed

- **ADR-0008 UI surface narrowing**: `ConversationCommands` extraction
  (35 commands) + `prepareWorkspace` on AutomationHost/OffPeakHost,
  `ChatGateway` split into 7 role interfaces, `WorkspaceOpenResult` sealed
  typing, `DesktopCapabilities` single-source version gates, relay V1/V2
  kernel merge, `TaskHomeService` consolidation, `TranscriptViewport`
  deepening, `copy_mappings` localization sink.
- **Task list ordering**: active cards sort by name within the active
  band, finished cards by time below — no more shuffling with multiple
  active tasks.
- **Model selection and labels**: composer and detail page share one
  `modelLabelOf` rule (official labels for builtin models); composite
  model values split on the first slash so providers whose model id
  contains `/` resolve correctly, with explicit draft choices preserved.

### Fixed

- **Permission prompts**: options localize by `kind` — English wire
  labels no longer override zh button copy.
- **Bridge disposal**: recovery paths guard every notifier write against
  a session disposed mid-flight (degraded stamp, reopen, rebuild
  callbacks).

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
