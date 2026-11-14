import 'dart:async';
import 'dart:io' show Directory;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../protocol/automation.dart';
import '../protocol/channel_client.dart'
    show
        ChannelRpcError,
        Channels,
        isAgentRuntimeNotRunningError,
        isBridgeGateTimeoutError,
        isChannelLevelError,
        isChannelMissingError,
        isSessionNotFoundError,
        isSessionNotFoundText;
import '../protocol/connection_params.dart';
import '../protocol/conversation.dart';
import '../protocol/desktop_capabilities.dart';
import '../protocol/file_service.dart';
import '../protocol/git_service.dart';
import '../protocol/id.dart' show generateUuid;
import '../protocol/method_probe.dart';
import '../protocol/model_selection.dart' show parseModelSelectionCatalog;
import '../protocol/off_peak.dart';
import '../protocol/project_resolver.dart';
import '../protocol/provider_settings.dart';
import '../protocol/relay_client.dart';
import '../protocol/relay_v2.dart' show RelayV2StartException;
import '../protocol/remote_client.dart';
import '../protocol/task_commands.dart';
import '../protocol/task_group_resolver.dart';
import '../protocol/task_groups.dart';
import '../protocol/window_controller.dart';
import 'chat_draft_store.dart';
import 'device_store.dart';
import 'entitlement_poller.dart';
import 'link_supervisor.dart';
import 'quota_reset.dart';
import 'quota_watch.dart' show QuotaWatchSource;
import 'side_chat_registry.dart';
import 'side_chat_tab_store.dart';
import 'sidecar_index_manager.dart';
import 'task_directory.dart';
import 'task_home_service.dart';
import 'task_home_store.dart';
import 'workspace_activity_store.dart';

/// Fixed group key for conversation workspaces (3.16.2 desktop "New task"
/// drafts: `.zcode/workspace/draft-<uuid>`). Their rows display under the
/// default workspace group; when no default workspace is listed they group
/// under this synthetic key instead — NEVER under the first conversation
/// path, which would drift with frame order and drag anchor matching along
/// (design 10-21 Part 1 decision 1).
const String conversationsWorkspaceKey = '__conversations';

String workspaceTitle(Map<String, dynamic> w) {
  final label = w['label'] as String?;
  if (label != null && label.isNotEmpty) return label;
  final path = w['workspacePath'] as String?;
  if (path != null && path.isNotEmpty) {
    final parts = path.split(RegExp(r'[\\/]'));
    return parts.lastWhere((p) => p.isNotEmpty, orElse: () => path);
  }
  final identity = w['workspaceIdentity'] as String?;
  if (identity != null && identity.isNotEmpty) return identity;
  return workspaceKeyOf(w) ?? '?';
}

/// Completes the wire workspace list with the desktop's project roots
/// (research/07 方案 A, 3.16.2): `getAvailableWorkspaces` answers only the
/// bound window's registry ∪ the active workspace, so workspaces of other
/// (or closed) windows never reach the wire — and their task rows never
/// reach the overview, because the listTaskList scopes are built from this
/// list too. The resolver's `projects ⋈ project_roots` rows cover the
/// project workspaces the registry misses.
///
/// Each root whose normalized path is not already listed becomes a
/// synthetic entry with `kind:'local'`, `label` = the project name,
/// `workspacePath` = the root path and `workspacePurpose:'project'`.
/// Wire entries always win the dedupe — they
/// carry the desktop's label/identity (and conversation entries must keep
/// their own shape). Entries are appended, never reordered: the first
/// listed workspace stays the auto-open target.
///
/// [home], when known, also synthesizes the `default` workspace
/// (`<home>/.zcode/workspace/default`, 10-26 D2): the old desktop grouped
/// un-grouped conversations there and ZGo's draft merge anchors on that
/// group, but the current desktop's single-window registry no longer lists
/// it. The entry is appended AFTER the project roots and deduped by
/// normalized path against both sources — a wire entry or a user-registered
/// root row of the same directory keeps its own spelling/label.
///
/// Returns [workspaces] itself when nothing was appended, so the pre-merge
/// behavior (and the object identity of the list) is preserved exactly.
///
/// Known upstream limit (P2-3, not fixed here): the desktop's window gate
/// may refuse to OPEN a session of a workspace outside the bound window
/// (「远程 workspace 不在当前窗口中」). Task-row visibility is this
/// completion's goal; opening those rows may still be refused desktop-side
/// and that is accepted.
List<Map<String, dynamic>> mergeProjectWorkspaces(
  List<Map<String, dynamic>> workspaces,
  Iterable<ProjectRoot> roots, {
  String? home,
}) {
  final seen = <String>{};
  for (final ws in workspaces) {
    final path = ws['workspacePath'];
    if (path is String && path.isNotEmpty) {
      seen.add(ProjectResolver.normalizeProjectRoot(path));
    }
  }
  List<Map<String, dynamic>>? merged;
  for (final root in roots) {
    final path = root.rootPath;
    if (path.isEmpty) continue;
    if (!seen.add(ProjectResolver.normalizeProjectRoot(path))) continue;
    merged ??= List<Map<String, dynamic>>.of(workspaces);
    merged.add({
      'kind': 'local',
      'label': root.name,
      'workspacePath': path,
      'workspacePurpose': 'project',
    });
  }
  if (home != null && home.isNotEmpty) {
    final path = ProjectResolver.defaultWorkspacePath(home);
    if (seen.add(ProjectResolver.normalizeProjectRoot(path))) {
      merged ??= List<Map<String, dynamic>>.of(workspaces);
      merged.add({
        'kind': 'local',
        'label': 'default',
        'workspacePath': path,
      });
    }
  }
  return merged ?? workspaces;
}

/// Health-gated workspace RPC surface behind [DeviceSession.callChannel].
///
/// The default implementation wraps the live bridge; tests inject a fake
/// through [DeviceSession.debugAttachGateForTest] to drive the
/// stall→rebuild policy without sockets.
abstract interface class WorkspaceGate {
  Future<void> waitHealthy({required Duration timeout});
  Future<dynamic> call(String channel, String method, List<Object?> args);
}

class _LiveWorkspaceGate implements WorkspaceGate {
  final BridgeSession bridge;
  _LiveWorkspaceGate(this.bridge);

  @override
  Future<void> waitHealthy({required Duration timeout}) =>
      bridge.waitHealthy(timeout: timeout);

  @override
  Future<dynamic> call(String channel, String method, List<Object?> args) =>
      bridge.channels.call(channel, method, args);
}

/// Tunable durations of [DeviceSession]'s stall defenses. Production uses
/// the default; tests shrink them to drive the policy with real short
/// delays instead of a fake clock.
class StallTimings {
  /// Gate bound while a channel RPC waits on a degraded bridge; on expiry
  /// the link counts as wedged and a full rebuild is forced (the cold-start
  /// permanent-loading defence).
  final Duration healthyWaitTimeout;

  /// Hard cap for one channel RPC after the gate passes.
  final Duration rpcTimeout;

  /// Bound for a single relay dial (`socket.ready` has no internal timeout
  /// and can otherwise park `connect` forever).
  final Duration dialTimeout;

  /// How long the sessions-index may stay un-ready on a connected session
  /// before the list watchdog escalates (reopen once, then rebuild).
  final Duration listReadyTimeout;

  /// Minimum spacing between forced rebuilds so probe storms can't thrash.
  final Duration minRebuildInterval;

  /// Delay between automatic retries after a retryable connect failure.
  final Duration retryBackoff;

  const StallTimings({
    this.healthyWaitTimeout = const Duration(seconds: 12),
    this.rpcTimeout = const Duration(seconds: 30),
    this.dialTimeout = const Duration(seconds: 30),
    this.listReadyTimeout = const Duration(seconds: 20),
    this.minRebuildInterval = const Duration(seconds: 30),
    this.retryBackoff = const Duration(seconds: 30),
  });
}

enum DeviceStatus { disconnected, connecting, connected, error }

/// Why a workspace bridge is being pointed at a workspace — decides which
/// addressing leg the window-gate fallback may use. [chatNew] targets a new
/// draft chat in the workspace (project addressing); [openTask] targets an
/// existing task (host addressing via `taskHostId`). Null on internal opens
/// (auto-open, watchdog reloads), which keep the pre-addressing behavior.
enum WorkspaceOpenPurpose { chatNew, openTask }

/// Whether a bridge-open failure is the desktop's "workspace is not in the
/// bound window" refusal. The upstream frame carries no error code, so the
/// message is the only discriminator (the desktop answers
/// 「目标工作区不在当前桌面窗口中…」 for bridge-open and
/// 「…不在当前窗口中…」 for reconnect — both mean the same window gate).
/// Not user-visible: this only decides whether the 3.16.3+ addressing leg
/// may retry.
bool isWorkspaceWindowGateError(Object error) {
  final text = '$error';
  return text.contains('不在当前桌面窗口中') || text.contains('不在当前窗口中');
}

/// Typed outcome of [DeviceSession.openWorkspace] — one variant per dead
/// end the UI distinguishes. A successful open clears the session's
/// remembered failure; any failure is remembered as the latest failed open
/// ([DeviceSession.lastWorkspaceOpenFailure]) so the list watchdog and the
/// failure banner derive from the same value (2026-10-29: the former
/// `_error` sentinel strings are retired).
sealed class WorkspaceOpenResult {
  const WorkspaceOpenResult();
}

/// The bridge is attached to the requested (or desktop-prepared draft)
/// workspace and its sessions-index subscription is live.
final class WorkspaceOpenOpened extends WorkspaceOpenResult {
  const WorkspaceOpenOpened();
}

/// The desktop refused the open: the window gate dead end survived both
/// addressing legs (or the requested workspace was unaddressable). The UI
/// maps this to `tasks.workspaceUnreachable`; [cause] keeps the raw desktop
/// refusal available to logs.
final class WorkspaceOpenUnreachable extends WorkspaceOpenResult {
  const WorkspaceOpenUnreachable(this.cause);

  final Object cause;
}

/// The bridge attached but the workspace's agent runtime is not running
/// (desktop code `ZCODE_AGENT_RUNTIME_UNAVAILABLE`) — a per-workspace dead
/// end only a desktop-side open of the workspace can resolve. Unlike
/// [WorkspaceOpenUnreachable], the open got far enough to attach. The UI
/// maps this to the actionable `tasks.agentRuntimeNotRunning` copy instead
/// of the desktop's English message.
final class WorkspaceOpenRuntimeNotRunning extends WorkspaceOpenResult {
  const WorkspaceOpenRuntimeNotRunning(this.cause);

  final Object cause;
}

/// Any other failure (transport / channel RPC). Callers keep the raw error
/// object as before; it is not a typed dead end.
final class WorkspaceOpenTransportFailure extends WorkspaceOpenResult {
  const WorkspaceOpenTransportFailure(this.error);

  final Object error;
}

/// The open never ran or was superseded (no active client, disposed,
/// concurrent open, or the link/bridge was replaced while it was in
/// flight). NOT a failure: it must not be remembered as one, and the UI
/// shows no failure copy for it — the caller only skips the chat push.
final class WorkspaceOpenAborted extends WorkspaceOpenResult {
  const WorkspaceOpenAborted();
}

/// Internal marker: the first leg hit the window gate and the addressing
/// retry failed too. Keeps the raw desktop refusal available to logs while
/// the session surfaces [WorkspaceOpenUnreachable] to the UI.
class _WorkspaceUnreachable implements Exception {
  const _WorkspaceUnreachable(this.cause);

  final Object cause;

  @override
  String toString() => '$cause';
}

/// What the automations UI needs from a device link: live status plus the
/// automation port. [DeviceSession] implements this; tests fake it.
abstract interface class AutomationHost {
  DeviceStatus get status;
  AutomationPort get automation;

  /// Active workspace scope (`workspacePath`/`workspaceIdentity`) attached
  /// to run-now triggers; the desktop requires it server-side.
  Map<String, dynamic> get automationScope;

  /// `prepareWorkspace` loader for the sheet's model / thought selectors.
  Future<WorkspacePrep> prepareWorkspace();
}

/// Same for the off-peak UI: live status, the off-peak port and the
/// workspace scope the submitted run binds to.
abstract interface class OffPeakHost {
  DeviceStatus get status;
  OffPeakPort get offPeak;

  /// `workspacePath` (+ identity) of the active workspace for submissions.
  Map<String, dynamic> get offPeakScope;

  /// `prepareWorkspace` fallback loader when the availability payload ships
  /// no `allowedModels`.
  Future<WorkspacePrep> prepareWorkspace();
}

/// A device link the notification hub can observe: live task phases plus
/// the automation / off-peak ports. [DeviceSession] implements this.
abstract interface class NotifiableSession
    implements AutomationHost, OffPeakHost, Listenable {
  String get deviceId;
  @override
  DeviceStatus get status;
  SessionsIndexState? get sessions;

  /// Relay-level task overview of EVERY workspace (bootstrap /
  /// `workspace-list-updated`) — the notification hub's second phase source,
  /// since [sessions] only ever covers the subscribed workspace. Raw `Dg`
  /// maps; a device that never got an overview reports an empty list.
  List<Map<String, dynamic>> get relayTasks;

  /// The merged task directory over [relayTasks] ⊕ [sessions] — the one
  /// projection of the merge rule (see [TaskDirectory]).
  TaskDirectory get taskDirectory;
}

/// A live conversation subscription handed to the chat UI: [state] is the
/// live rows/snapshot notifier, [close] unsubscribes.
///
/// [isRevoked] is the orphan token (11-08 session restore): the host revokes
/// a reader's subscription when it re-points the bridge at another workspace
/// (one bridge at a time) — the page keeps its State alive across the pop,
/// so nothing would tell it its subscription died. A revocation generation
/// carried by the handle distinguishes that host-side teardown from the
/// page's own [close] (normal page death needs no recovery, so it never
/// advances the generation).
class ChatHandle {
  ChatHandle({
    required this.state,
    required this.close,
    this.generation = 0,
    bool Function()? revoked,
  }) : _revoked = revoked ?? _neverRevoked;

  final ConversationState state;
  final Future<void> Function() close;

  /// The revoke generation this handle was issued at. Compare with
  /// [isRevoked], never with the host's counter directly.
  final int generation;

  final bool Function() _revoked;

  /// True once the host tore this subscription down behind the reader's back
  /// (workspace switch / link teardown). The page reads this on return
  /// (`didPopNext`) and resumes through [ConversationPort.resumeSessionOnReturn].
  bool get isRevoked => _revoked();

  static bool _neverRevoked() => false;
}

/// Connection/link surface of the chat link (ADR-0008 revision): the live
/// status flags, the mobile view-state report and manual recovery after a
/// KICK. [DeviceSession] implements it; chat widgets hold just this role.
///
/// [Listenable]: the kicked overlay and the gateway banner listen on it.
abstract interface class SessionLinkPort implements Listenable {
  DeviceStatus get status;
  bool get kicked;
  String? get error;

  /// mobile-view-state-update: report the task the chat UI is showing
  /// (or just the workspace when [taskId] is null).
  void sendViewState({String? taskId});

  /// Original remote-control URL (for "copy task link").
  String? get remoteUrl;

  /// Manual recovery after a KICK: full suspend + reconnect.
  Future<void> reconnect();
}

/// The 「open one existing task」 surface shared by every entry that does not
/// know the task's workspace up front (task-list rows, notification taps
/// and the notification transition page): connection readiness plus the
/// ownership resolution + on-demand workspace warm-up ([prepareTaskOpen]).
/// [DeviceSession] implements it; tests fake it.
abstract interface class TaskOpenHost implements SessionLinkPort {
  /// Whether the relay task overview has landed this connection episode
  /// (bootstrap ⊕ `listTaskList`). Before it does, the directory cannot
  /// answer ownership for tasks outside the live index — a null
  /// [prepareTaskOpen] answer in that window is TRANSIENT, and the caller
  /// should wait for this flag instead of failing (2026-11-07 acceptance
  /// AC4: cold start reported scopeUnknown and succeeded on manual retry).
  bool get taskOverviewLoaded;

  /// Resolves [taskId]'s workspace, opens it when the bridge is not already
  /// there, and answers the typed outcome. Null means the ownership cannot
  /// be determined — the caller must not push a chat (the server would
  /// reject every command under the guessed scope, `proto.sessionNotFound`).
  /// [WorkspaceOpenAborted] keeps its documented meaning: no copy at all.
  ///
  /// [workspaceHint] (`workspacePath` / `workspaceIdentity`) is the
  /// notification payload's own origin fields; it answers only when the task
  /// directory has no ownership answer yet (cold start before the overview
  /// lands) — a directory resolution always wins.
  Future<WorkspaceOpenResult?> prepareTaskOpen(
    String taskId, {
    Map<String, dynamic>? workspaceHint,
  });
}

/// Conversation V4 surface a chat surface drives: the command group, the
/// replayable queue, the draft-workspace guard and the live subscription.
///
/// [Listenable]: the queue bar and the page-level merge listen on it.
abstract interface class ConversationPort implements Listenable {
  /// Conversation V4 commands of the active workspace (sendText / stop /
  /// queue / model switches / row actions / attachments / …).
  ConversationCommands get conversationCommands;

  /// Offline replayable-command queue (3.12.3 `web-remote-replayable`);
  /// null on older desktops and while no workspace is open.
  ReplayableCommandQueue? get replayableQueue;

  /// Draft-page send guard: before the first `createSession`, verifies the
  /// bridge still points at [workspacePath] — the workspace the draft page
  /// was opened in. A connection rebuild auto-opens the preferred workspace
  /// under an open draft; without this check the create would silently land
  /// there (the original window-gate bug in disguise, live 2026-10-27).
  /// A drifted bridge re-opens through the same 3.16.3+ addressing fallback
  /// chain as the list page. Returns the typed open outcome: anything but
  /// [WorkspaceOpenOpened] means the caller must not send (draft text
  /// stays untouched); a null/empty or already-active target answers
  /// [WorkspaceOpenOpened] with zero RPC.
  Future<WorkspaceOpenResult> ensureDraftWorkspace(String? workspacePath);

  /// Live conversation subscription; per-sessionId handles are reused.
  Future<ChatHandle> subscribe(String sessionId);

  /// Orphan recovery (11-08 session restore): the page was showing
  /// [sessionId] when the host revoked its subscription behind its back (a
  /// workspace switch keeps ONE bridge). Re-points the bridge at the
  /// session's own workspace through the same ownership resolution
  /// [prepareTaskOpen] uses, re-subscribes and answers the fresh handle.
  ///
  /// - same workspace and the subscription is still live → no-op, answers
  ///   the live handle (zero RPC);
  /// - concurrent calls for one id share one in-flight future;
  /// - a superseded open ([WorkspaceOpenAborted] — `_openChain` is last-wins)
  ///   is re-run ONCE in place; a second abort throws;
  /// - every failure throws [SessionResumeException] so the page renders
  ///   classified copy (never a raw desktop line).
  Future<ChatHandle> resumeSessionOnReturn(String sessionId);
}

/// Why [ConversationPort.resumeSessionOnReturn] could not bring a session
/// back. The page maps each to voice-table copy; the raw cause rides
/// [SessionResumeException.cause] for logs.
enum SessionResumeFailure {
  /// The task directory cannot say which workspace owns the session — the
  /// same dead end [TaskOpenHost.prepareTaskOpen] answers null for.
  scopeUnknown,

  /// Ownership names another workspace and re-pointing the bridge there
  /// failed (window gate / cold runtime / transport).
  foreignWorkspace,

  /// The workspace open was superseded twice (`_openChain` last-wins).
  openAborted,

  /// The subscribe itself failed after the bridge was pointed home.
  subscribe,

  /// The bridge was home and the desktop still answered
  /// `fault.subscribe.sessionNotFound` — the session really is gone (the
  /// sticky missing set already carries it).
  sessionMissing,
}

/// Classified orphan-recovery failure ([ConversationPort.resumeSessionOnReturn]).
class SessionResumeException implements Exception {
  const SessionResumeException(this.failure, {this.cause});

  final SessionResumeFailure failure;

  /// The underlying typed open result / subscribe error, for logs.
  final Object? cause;

  @override
  String toString() => 'SessionResumeException($failure): $cause';
}

/// Task-metadata commands and reads the chat page owns (row actions, the
/// shell-session error card). Method names are source-confirmed — see
/// [TaskCommandsPort].
abstract interface class TaskMetaPort {
  Future<dynamic> renameTask(String sessionId, String title);
  Future<dynamic> setTaskPinned(String sessionId, bool pinned);
  Future<dynamic> setTaskArchived(String sessionId, bool archived);
  Future<dynamic> setTaskUnread(String sessionId, bool unread);

  /// Desktop-local native session log file path
  /// (`getTaskNativeSessionLogFile` on the zcode-task channel, F2):
  /// `{provider, path, exists}` — the chat 更多菜单「复制日志路径」data
  /// source. Throws when the bridge is down or the desktop lacks the
  /// method; callers degrade (hide the entry / toast).
  Future<dynamic> taskNativeSessionLogFile(String sessionId);

  /// Deletes a task (`zcode-task.deleteTask`). Callers confirm first.
  Future<dynamic> deleteTask(String sessionId);

  /// Relay-overview display status (`idle|running|completed|error`) of one
  /// task; null when the relay view doesn't hold the session.
  String? taskDisplayStatus(String sessionId);

  /// The task row's `lastError` meta as the merged directory holds it —
  /// `{message, code?, traceId?, attribution?}`, null when the row carries
  /// none (or the directory doesn't know the id).
  ///
  /// This is the ONLY carrier of the error detail the chat surfaces show:
  /// the task row keeps the LAST error of the task (not of one turn), and
  /// the V4 conversation snapshot has no `status.lastError` member at all
  /// (2026-11-08 wire probe + official 3.17.2 bundle; the `detail`/`type`
  /// schema belongs to the unimplemented `getTaskSnapshot` RPC). Callers
  /// present it as 「最近一次错误」.
  Map<String, dynamic>? taskLastError(String sessionId);

  /// Anchor write source ① of the task registry (spec
  /// task-registry-semantics §3.8): the phone created this session, so the
  /// App is the source of truth for its home workspace.
  /// [workspacePathOrKey] is the ACTIVE workspace's path/key — NOT a draft
  /// page's captured path, which may not be the bridge's real landing point
  /// (`_openWorkspaceNow` prefers the bridge's own key). The state layer
  /// canonicalizes it through the workspace alias table (`normalizeKey`)
  /// before writing.
  void anchorCreatedTask(String sessionId, String? workspacePathOrKey);

  /// Re-pulls the relay task overview now (bootstrap + the three
  /// `listTaskList` legs) and notifies once it lands.
  ///
  /// Best-effort and silent: a failure keeps the old rows (the 30 s cadence
  /// retries naturally). Callers are the two create-time triggers (design
  /// 11-01 §2): the createSession ack (new row is listed ~230 ms after the
  /// ack — run8) and the turn terminal (status-word correction).
  ///
  /// Anti-swallow: a call landing on a round built from the OLD state waits
  /// that round out and re-dials instead of joining it.
  ///
  /// [bypassThrottle] skips the throttle window for one-shot USER-action
  /// triggers (create / turn terminal) — they are not a storm source, and
  /// letting a cadence round's window swallow them would reproduce the
  /// visibility bug. The anti-swallow wait is NOT weakened: a bypass call
  /// still waits the in-flight round out, then re-dials. A bypass call also
  /// advances the throttle anchor, so later cadence calls keep a stable
  /// window. The 30 s cadence keeps the default `false`.
  Future<void> refreshTaskOverview({bool bypassThrottle = false});
}

/// Workspace context a chat surface reads: ids/paths, the draft store,
/// workspace preparation, the model/entitlement catalogs, the @-mention
/// data sources and the workspace-file port.
///
/// [mentionSkills] is parity-retained (the `$` picker reads [skills]); it
/// has no direct consumer in `lib/` today.
abstract interface class WorkspaceContextPort {
  /// `workspaceId` for draft-mode createSession, plus the workspace path
  /// for the chat page's copy action.
  String? get chatWorkspaceId;
  String? get workspacePath;

  /// Composer-draft persistence for this device's chat pages (text +
  /// attachment metadata in SharedPreferences, attachment bytes under the
  /// hub-injected root). Pages restore once on init and debounce writes
  /// into it; failures degrade to no persistence, never blocking chat.
  ChatDraftStore get chatDraftStore;

  /// `prepareWorkspace` of the active bridge (model/thought selectors and
  /// slash commands).
  Future<WorkspacePrep> prepareWorkspace();
  Future<List<SkillEntry>> skills();

  /// Fallback model catalog for the chat config sheet (PRD 09-19): enabled
  /// providers from the `model-provider` channel (`getAll`), or — on ≥3.14
  /// desktops where that channel is gone — the `model-selection.getView`
  /// registry mapped to the same shape. Used when [prepareWorkspace] ships
  /// no model options. Cached for the session lifetime; never throws —
  /// transport/channel failures resolve to an empty list (and stay
  /// uncached, so the next sheet open retries).
  Future<List<Map<String, dynamic>>> modelProviderCatalog();

  /// Entitled `account:*` provider ids of the provider-settings view (the
  /// chat config sheet hides unentitled account model groups, design
  /// 10-24 §3). Null means the view could not be read (old desktop /
  /// bridge failure): entitlement is unknown, so nothing is filtered. An
  /// empty set is a successful read with zero entitlement and hides every
  /// unentitled account group. Never throws.
  Future<Set<String>?> entitledProviderIds();

  /// Workspace file SEARCH for the add-context panel / `@` file picker —
  /// task 2's probed `searchWorkspaceFiles` path (falls back to the packed
  /// listing on desktops without it). Rows are {name, path, relativePath,
  /// type}. THROWS when the desktop serves neither method; callers treat
  /// that as "file section unreachable" and hide it.
  Future<List<Map<String, dynamic>>> searchWorkspaceFiles(
    String query, {
    int limit = 50,
  });

  /// Reachability verdict for the workspace file pickers (task 2's probe:
  /// `searchWorkspaceFiles` with a limit-1 empty query, falling back to the
  /// packed listing length). Never throws — any failure reads false, and the
  /// caller hides the file section.
  Future<bool> workspaceFilesReachable();

  /// Skills (id/name/description) — parity retained; the `$` picker reads
  /// [skills] instead, so there is no consumer in `lib/` today.
  Future<List<Map<String, dynamic>>> mentionSkills();

  /// Subagents (name/description); empty on desktops rejecting the call.
  Future<List<Map<String, dynamic>>> mentionSubagents();

  /// Open sessions of the active workspace (id/title).
  List<({String id, String title})> mentionSessions();

  /// Workspace-file reads for the preview surfaces (ADR-0008 rule i:
  /// role interfaces may expose a protocol port directly instead of
  /// forwarding each method).
  FileServicePort get fileService;
}

/// Cross-terminal session truth: deletion tombstones and the authoritative
/// subscribe-refusal set. The chat page renders a tombstone banner, disables
/// the composer send and keeps the messages read-only (no pop, no clearing).
///
/// [Listenable]: the tombstone/missing banners rebuild on it.
abstract interface class SessionTruthPort implements Listenable {
  /// Cross-terminal deletion tombstone (task 10-06 chat tombstone): true
  /// once the live sessions-index of the active workspace dropped
  /// [sessionId] after having listed it — another terminal deleted the
  /// session.
  bool isSessionDeleted(String sessionId);

  /// Drops [sessionId] from the cross-terminal tombstone set. The chat
  /// page calls this on dispose so a page-held tombstone does not outlive
  /// its reader — the set is add-only otherwise.
  void forgetDeletedSession(String sessionId);

  /// Authoritative subscribe refusal (10-11 sessionNotFound terminal):
  /// true once the desktop's subscribe channel answered
  /// `fault.subscribe.sessionNotFound` for [sessionId] — the session is
  /// neither active nor persisted, so the subscription is terminally
  /// failed (no more retries). Semantic boundary vs [isSessionDeleted]:
  /// the tombstone INFERS a cross-terminal deletion from sessions-index
  /// diffs; THIS is the subscribe channel's AUTHORITATIVE rejection.
  /// Where both hold, the UI presents this one (authority over inference).
  bool isSessionMissing(String sessionId);

  /// Drops [sessionId] from the missing-session set (chat page dispose —
  /// same reader-recovery shape as [forgetDeletedSession]).
  void forgetMissingSession(String sessionId);
}

/// Workspace Git operations the chat page hands to `GitWorkspaceController`
/// (ADR-0008 rule i: the protocol port is exposed directly).
abstract interface class GitAccessPort {
  GitPort get git;
}

/// Entitlement/quota surface of the chat page (usage/quota banner).
///
/// [QuotaResetGateway] stays separate: it serves [QuotaResetController],
/// not the UI.
abstract interface class QuotaAccessPort {
  /// Entitlement/quota snapshot (usage-stats.getEntitlementSnapshot) via
  /// the session-wide [EntitlementPoller]: cached within the staleness
  /// window, [force] bypasses it. Never throws — failures arrive as an
  /// [EntitlementView] with phase [EntitlementPhase.error].
  Future<EntitlementView> entitlementSnapshot({bool force = false});

  /// Session-wide reset-opportunity controller (usage page card + chat
  /// banner action). Lazily created with the session, disposed with the
  /// session; UI only reads [QuotaResetController.pools] and calls
  /// refresh/use — the scope is injected by [entitlementSnapshot].
  QuotaResetController get quotaResetController;
}

/// Side-chat (`selection_side_chat`) tab surface the chat page drives
/// (design 11-11-btw-side-chat §12; R4/R6/R8/R9). Every piece of
/// orchestration lives in the state layer — the page never touches
/// [SideChatRegistry], [SideChatTabStore], [SessionsIndexState] or the task
/// directory directly.
///
/// Two lifecycle tiers (R8): [closeSideChatTab] is a restorable collapse
/// (runtime stopped, record removed, manifest entry kept — the next page
/// entry rebuilds the tab) while [destroySideChatTab] is permanent (soft
/// delete + manifest prune, never restored).
abstract interface class SideChatPort {
  /// Tabs of [parent] in ordinal order (the tab bar's order). Read-only view.
  List<SideChatTab> sideChatTabs(String parent);

  /// Rebuilds [parent]'s tabs from the persisted manifest (R8/AC9). The page
  /// awaits this before building its tab children, so a subscription that
  /// fails afterwards can read the restored ids and self-heal.
  Future<void> restoreSideChatTabs(String parent);

  /// Closes the tab's desktop runtime (`zcode-session.closeSession`, R4/AC5)
  /// and removes the record; the manifest entry survives (restorable
  /// collapse). Fault-tolerant: an unavailable bridge or any RPC fault still
  /// completes the local teardown — losing the tab beats a stuck one.
  Future<void> closeSideChatTab(String parent, String sessionId);

  /// Destroys the tab permanently (R9/AC10): soft-deletes the session
  /// (`deleteSession`, tombstoned through the task-home store) and prunes the
  /// manifest entry. Idempotent when the session is already gone;
  /// non-idempotent faults rethrow with the tab untouched.
  Future<void> destroySideChatTab(String parent, String sessionId);

  /// Creates a side chat attached to [parent] (R6/R2) and registers its tab;
  /// answers the new tab so the page can switch to it at once. [firstInput]
  /// becomes the side chat's first message when non-blank.
  Future<SideChatTab> createSideChatTab(String parent, {String? firstInput});
}

/// Page-construction boundary of the chat UI (ADR-0008 rule ii): the union
/// of every role a chat page may need, held only by the page classes
/// ([ChatPage] / [SubagentDetailPage]) and the composition root
/// ([DeviceSession]). Inner widgets narrow to a single role; page-level
/// navigation travels through callbacks, never through this union.
///
/// The three [Listenable] roles make this naturally [Listenable].
abstract interface class ChatPageHost
    implements
        SessionLinkPort,
        ConversationPort,
        TaskMetaPort,
        WorkspaceContextPort,
        SessionTruthPort,
        SideChatPort,
        GitAccessPort,
        QuotaAccessPort {}

/// One quota route the usage page renders (design 10-25): the resolved plan
/// access the snapshot was requested for, and that route's poller view.
/// [plan] is null on the legacy wire (<3.12.3), where a single unrouted
/// snapshot answers and no `accountAccess` exists.
typedef EntitlementSnapshotRoute = ({
  Map<String, dynamic>? plan,
  EntitlementView view,
});

/// One native protocol connection to one device. Owns the full stack
/// (relay → bridge → conversation → sessions-index) and exposes just what
/// the native UI needs: online status, the live task list and task
/// commands.
///
/// Lifecycle notes (verified against the live server):
/// - A device (same sid) allows exactly ONE terminal connection. Before
///   handing the device over to the WebView, [suspend] must close this
///   connection cleanly, otherwise the WebView auth kicks us (or vice
///   versa).
/// - Being KICKED by another terminal is terminal for this session: no
///   auto-reconnect (the relay already suppresses it).
class DeviceSession extends ChangeNotifier
    implements
        AutomationHost,
        OffPeakHost,
        NotifiableSession,
        ChatPageHost,
        TaskOpenHost,
        QuotaResetGateway,
        QuotaWatchSource {
  @override
  final String deviceId;
  final RemoteConnectionParams params;

  /// Last workspace this device showed (hub memory; survives WebView
  /// handovers within one app run).
  final String? preferredWorkspaceKey;
  final void Function(String workspaceKey)? onWorkspaceOpened;

  /// Test seam: replaces the default [RemoteClient] construction in
  /// [connect]; production keeps the real relay-backed client.
  @visibleForTesting
  final RemoteClient Function()? clientFactory;

  /// Test seam: builds the lazily created [ProjectResolver]. The production
  /// resolver reads through the file channel (which needs an open bridge),
  /// so state-level tests inject one that answers from a local fixture. The
  /// callback parameter is the RAW bootstrap workspace list the resolver
  /// derives the desktop home from — never the merged view (a merged-input
  /// resolver would form a cycle with its own output).
  @visibleForTesting
  final ProjectResolver Function(
    List<Map<String, dynamic>> Function() bootstrapWorkspaces,
  )? projectResolverFactory;

  /// Test seam: builds the lazily created [TaskGroupResolver] (desktop
  /// 3.17.1 direct read of the `task_group_*` tables). The production
  /// resolver reads through the file channel, which needs an open bridge —
  /// state-level tests inject one answering from a local fixture. The
  /// callback parameter is the home seam bridged from the project resolver.
  @visibleForTesting
  final TaskGroupResolver Function(String? Function() homeOf)?
      taskGroupResolverFactory;

  /// Desktop-home cache seam for the project resolver
  /// (resolver-home-fallback, 10-23): `loadCachedHome` answers the home a
  /// previous connection learned, `saveCachedHome` persists a wire-derived
  /// one. Injected by the composition root so the protocol layer stays
  /// plugin-free; the resolver only consults the cache when the workspace
  /// list carries no `.zcode/workspace` path.
  final String? Function()? loadCachedHome;
  final Future<void> Function(String home)? saveCachedHome;

  /// ZCode account JWT seam for the V2 relay (desktop 3.16.2+): the
  /// protocol layer must never import `lib/plan`, so the composition root
  /// injects this callback. Null means an account-authenticated (V2) link
  /// cannot connect — [connect] fails with `auth-required` instead of
  /// silently dialing. Required only for [RemoteConnectionParams.v2] links.
  final Future<String?> Function()? jwtProvider;

  /// Tunable stall-defense durations (tests shrink the defaults).
  @visibleForTesting
  final StallTimings timings;

  /// Minimum spacing between two [refreshTaskOverview] rounds (design 11-01
  /// §2): the create and turn-terminal triggers can land seconds apart, and
  /// live-frame noise may re-arm the terminal edge — a trigger inside the
  /// window joins the round already running instead of stacking another
  /// three-leg pull. Tests that drive several rounds back to back pass
  /// [Duration.zero].
  @visibleForTesting
  final Duration overviewRefreshThrottle;

  /// How long a workspace that answered its sidecar subscribe with the
  /// benign cold-runtime refusal stays out of the sidecar set (design
  /// 10-28: ~10 minutes). A collection change (the key leaving the top-N)
  /// clears the cooldown, so a re-entering workspace retries at once.
  @visibleForTesting
  final Duration sidecarCooldown;

  DeviceSession({
    required this.deviceId,
    required this.params,
    this.preferredWorkspaceKey,
    this.onWorkspaceOpened,
    this.draftsRoot,
    this.clientFactory,
    this.projectResolverFactory,
    this.taskGroupResolverFactory,
    this.jwtProvider,
    this.loadCachedHome,
    this.saveCachedHome,
    this.timings = const StallTimings(),
    this.sidecarCooldown = const Duration(minutes: 10),
    this.overviewRefreshThrottle = const Duration(milliseconds: 2500),
  }) : _homeStore = TaskHomeStore(deviceId: deviceId),
       _activityStore = WorkspaceActivityStore(deviceId: deviceId) {
    // Persisted task-home anchors + local delete tombstones (design
    // 10-15): fire-and-forget like every store load — until it lands the
    // directory keeps the cold-pick behavior; one notify re-groups rows
    // once the disk state has merged in.
    unawaited(_homeStore.load().then((_) {
      // Only a disk state that actually merged in is worth a re-group
      // notify; an empty/cold store must not add noise notifies.
      if (!_disposed && _homeStore.hasPersistedState) notifyListeners();
    }));
    // Persisted workspace activity keys (design 11-01 §4): the cold-start
    // card order gets its idle-tier keys back before any live rows land, so
    // one notify re-sorts the cards with the restored values.
    unawaited(_activityStore.load().then((_) {
      if (!_disposed && _activityStore.hasPersistedState) notifyListeners();
    }));
    // Composer drafts (design 10-20): fire-and-forget warm-up like the
    // home store; page ops await the load themselves, so this only
    // front-runs the first restore. No notify — nothing listens.
    unawaited(_chatDraftStore.load());
    // Side-chat tab manifest (design 11-11-btw-side-chat §3): fire-and-forget
    // warm-up; [restoreSideChatTabs] awaits the load itself. No notify —
    // tabs only materialize on an explicit page entry.
    unawaited(_sideChatTabStore.load());
  }

  /// Composer-draft attachment root resolver (hub-injected so lib/state
  /// stays free of platform plugins — production resolves
  /// `<appSupport>/chat_drafts` via path_provider in main).
  final Future<Directory?> Function()? draftsRoot;

  late final ChatDraftStore _chatDraftStore = ChatDraftStore(
    deviceId: deviceId,
    attachmentRoot: draftsRoot,
  );

  @override
  ChatDraftStore get chatDraftStore => _chatDraftStore;

  RemoteClient? _client;
  BridgeSession? _bridge;
  ConversationTransport? _conversation;
  SessionsIndexSubscription? _sessionsSub;
  final Map<String, ConversationSubscription> _chatSubs = {};

  /// Terminal-failure listeners of [_chatSubs], one per live subscription
  /// (a second reader shares it — see [subscribe]). Cancelled when the
  /// subscription dies: page close, host revoke, or terminal refusal.
  final Map<String, StreamSubscription<Object?>> _chatTerminalSubs = {};

  /// Per-session revoke generation (11-08 session restore). The ONLY writer
  /// is [_openWorkspaceNow]'s teardown (the host revokes readers behind
  /// their back); a page's own [ChatHandle.close] never touches it, so
  /// "page closed" and "host revoked" stay distinguishable. A handle issued
  /// at generation N is orphaned once the counter moved past N.
  final Map<String, int> _chatGenerations = {};

  /// In-flight [resumeSessionOnReturn] futures by session id (AC4 debounce:
  /// a burst of `didPopNext` callbacks shares ONE open/subscribe chain).
  final Map<String, Future<ChatHandle>> _resumeInFlight = {};

  // --- Side-chat tabs (design 11-11-btw-side-chat §2/§3) ---

  /// Parent session id → side-chat tabs for the life of this process. The
  /// persisted manifest [SideChatTabStore] is the recovery source
  /// ([restoreSideChatTabs]); every mutation here keeps it in sync.
  final SideChatRegistry _sideChats = SideChatRegistry();

  /// Persisted tab manifest (device + workspace keyed): registers and
  /// destroys write through, a restart restores from it (design §3). The
  /// sessions-index is NOT a source — `selection_side_chat` never enters it.
  late final SideChatTabStore _sideChatTabStore =
      SideChatTabStore(deviceId: deviceId);

  /// Session ids whose resume currently owns the open/subscribe chain —
  /// guards the subscribe→reroute→subscribe recursion in [subscribe].
  final Set<String> _resumingSessions = <String>{};

  /// Managed channel-event listeners registered via [listenChannel]: their
  /// wire attaches die with every bridge and are re-hung from this registry
  /// on the next bridge rebuild.
  final List<_ManagedChannelListener> _channelListeners = [];
  StreamSubscription? _failureSub;
  StreamSubscription? _wsListSub;
  StreamSubscription? _appErrSub;
  Timer? _retryTimer;
  Timer? _listWatchdog;
  int _retryAttempts = 0;

  // --- Stall bookkeeping (cold-start permanent-loading defence) ---
  /// Consecutive soft reloads (bootstrap/open) that produced no progress.
  int _softReloadFails = 0;

  /// List-watchdog escalation step: 0 idle; 1 = reopen once failed.
  int _listEscalations = 0;

  /// Whether the cold-runtime dead end was already logged by the current
  /// parking episode — connect and open-finally both arm the watchdog, and
  /// the duplicate line is pure noise.
  bool _watchdogParked = false;

  // --- Channel-level failure isolation (dead-channel defence) ---
  /// Failure-tier ledger (per-channel tri-strike) + escalation policy —
  /// the tier semantics live on [LinkSupervisor]. Escalations (bridge-level
  /// and tri-strike alike) land in [_forceRebuildAfterStall], which keeps
  /// the authoritative debounce window shared with the list watchdog and
  /// reloadTasks.
  late final LinkSupervisor _linkSupervisor = LinkSupervisor(
    onEscalate: _forceRebuildAfterStall,
    now: clock.now,
    escalationDebounce: timings.minRebuildInterval,
    // `_log` prepends the device id; the `[session]` tag keeps the
    // tri-strike line byte-identical to the pre-extraction output.
    onLog: (line) => _log('[session] $line'),
  );

  /// Wall clock of the last forced rebuild, for debouncing.
  DateTime _lastStallRebuildAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _rebuilding = false;

  /// Read-only display projection of the long "not fully usable yet" phases:
  /// `pairing` / `reconnecting` / `rebuilding`. Deliberately independent of
  /// [status]: a drop redial keeps `connected` and a forced rebuild runs on
  /// `disconnected`, so the UI must read this instead of gating on a status.
  /// `kicked` stays on [kicked] — never duplicated here.
  ///
  /// Written only at three low-frequency points ([_setStatus],
  /// [_onRelayState], [_forceRebuildAfterStall]) and de-duplicated in
  /// [_setConnectionStage], so the per-frame notify path never flips it.
  String? _connectionStage;

  /// Test seam overriding the live bridge gate in [callChannel].
  WorkspaceGate? _testGate;

  bool _disposed = false;
  bool _connecting = false;
  bool _openingWorkspace = false;
  bool _kicked = false;
  String? _error;

  /// Latest failed [openWorkspace] outcome; null after any successful open,
  /// a connect start, a relay re-pair or suspend. The list watchdog and the
  /// failure banner derive from this single value (the former machine
  /// sentinel strings in [_error] are retired).
  WorkspaceOpenResult? _lastWorkspaceOpenFailure;

  /// Desktop's live app version from the bootstrap-response top level
  /// (`desktopAppVersion`, live-probed 3.16.3). Null until a frame carries
  /// it. Addressing gates prefer this over [params]: the paired link's
  /// `app_version` is a generation-time snapshot and can lag the running
  /// desktop (a 3.16.3 desktop behind a 3.16.2 link — live acceptance
  /// 2026-10-26; the stale gate was why the fallback leg never fired).
  String? _desktopAppVersion;

  /// Named desktop capability matrix (protocol layer). One long-lived
  /// instance per session; its callbacks re-read [desktopAppVersion] and
  /// [modelProviderAvailable] on every evaluation, so a bootstrap frame
  /// landing after construction is honoured.
  late final DesktopCapabilities capabilities = DesktopCapabilities(
    params,
    liveDesktopVersion: () => desktopAppVersion,
    providerVerdict: () => modelProviderAvailable,
  );

  DeviceStatus _status = DeviceStatus.disconnected;

  /// Raw wire workspace list (bootstrap / `workspace-list-updated`). The
  /// desktop reports only the registry of its BOUND window (3.16.2
  /// `getAvailableWorkspaces`, research/07), so [workspaces] adds the
  /// project roots read by [ProjectResolver] on top. THIS list stays the
  /// raw set on purpose: the resolver derives the desktop home from it,
  /// and feeding the merged view back would be circular (the merged list
  /// depends on the resolver's answer).
  List<Map<String, dynamic>> _bootstrapWorkspaces = [];

  /// Workspaces the UI and the listTaskList scopes see: [_bootstrapWorkspaces]
  /// completed with the desktop's project roots (3.16.2 only, research/07
  /// 方案 A). Wire entries keep their original label/identity and order;
  /// synthetic project-root entries are appended.
  List<Map<String, dynamic>> _workspaces = [];
  Map<String, dynamic>? _activeWorkspace;

  /// Persisted home anchors + local delete tombstones (design 10-15,
  /// [TaskHomeStore] — SharedPreferences, per-device keys). Replaces the
  /// 10-02 pure-memory sticky-home map and the 10-02 in-memory delete
  /// set: both survive restarts now, so a confirmed home keeps its group
  /// and a deleted task cannot resurrect from a surviving mirror copy.
  /// Writes go through the store (memory-sync + fire-and-forget save);
  /// the directory reads its live views, so every update re-merges on the
  /// next rebuild.
  final TaskHomeStore _homeStore;

  /// Persisted per-workspace activity keys (design 11-01 §4). Written at
  /// every overview / live-frame landing, read by the task list as the
  /// idle-tier fallback while a non-active workspace has no rows yet.
  final WorkspaceActivityStore _activityStore;

  // --- Sidecar sessions-index subscriptions (design 10-28) ---

  /// Upper bound on the RANKED sidecar set (non-active workspaces, newest
  /// `updatedAt` first, key lexicographic tie-break). Retained running-row
  /// layers and the switch carry-over's stale layers may exceed it — the
  /// bound exists so a bridge swing's resubscribe wave stays cheap, not as a
  /// hard subscription cap.
  ///
  /// 12 is evidence-backed (11-02 live probe): twelve concurrent
  /// sessions-index subscriptions on one bridge all acked with independent
  /// subscription ids — no per-connection subscription cap at 12. Cost per
  /// bridge generation: 12 sidecars replay ≈590KB of event-layer JSON
  /// (≈810KB on the wire) of first snapshots, vs ≈246KB (≈337KB) at 5;
  /// between replays the traffic is incremental-only. Workspace counts are
  /// usually lower, so the ceiling is rarely reached.
  static const int sidecarWorkspaceLimit = 12;

  /// Wire handles of the sidecar subscriptions, by workspace key. The
  /// policy (candidate ranking / cooldown / in-flight / running slot /
  /// failure classification / eviction) lives in [SidecarIndexManager];
  /// this session only owns the wire lifetime and the single notify.
  final Map<String, SessionsIndexSubscription> _sidecarSubs = {};

  /// Authoritative subscribe refusals (10-11 sessionNotFound terminal):
  /// session ids the desktop's subscribe channel refused with
  /// `fault.subscribe.sessionNotFound`. Distinct from
  /// the cross-terminal tombstone set (now in [TaskHomeService]) in
  /// EPISTEMIC STATUS, not in UI form: the
  /// tombstone set holds sessions-index diff INFERENCE (revocable), this
  /// holds the channel's AUTHORITATIVE rejection (a session that is not
  /// active and not persisted cannot come back on this link). Two entry
  /// points: the initial open's subscribe throw, and a live
  /// subscription's terminal-failure broadcast (the resubscribe path —
  /// no more retry timers once here). Consumed by the chat page through
  /// [SessionTruthPort.isSessionMissing]; the page drops its own id on dispose
  /// ([forgetMissingSession]) — same reader-recovery shape as the
  /// tombstone set.
  final Set<String> _sessionMissingIds = <String>{};

  /// Well-known `app-error` reason of the last fatal failure (the
  /// web's `webRemoteControl.failure.*` enum); UI maps it to localized copy.
  String? _failureReason;

  @override
  DeviceStatus get status => _status;
  @override
  bool get kicked => _kicked;
  @override
  String? get error => _error;

  /// Latest failed [openWorkspace] outcome, if any (typed replacement for
  /// the former `_error` machine sentinels). Sole writer is the open path;
  /// link/app error writes never touch it.
  WorkspaceOpenResult? get lastWorkspaceOpenFailure =>
      _lastWorkspaceOpenFailure;

  /// Display-only projection of the long "not fully usable yet" phases:
  /// `pairing`, `reconnecting` or `rebuilding`; null whenever none applies.
  /// It outranks [status] for copy because the three production windows do
  /// not line up with any single status. `kicked` is deliberately NOT a
  /// stage — read [kicked] for that (and for the terminal copy).
  String? get connectionStage => _connectionStage;

  /// Reason code (`session-not-found`, `session-conflict`,
  /// `unsupported-action`, ...) of the current failure, if any.
  String? get failureReason => _failureReason;

  /// Relay task list (raw `Dg` maps) — owned by [TaskHomeService].
  @override
  List<Map<String, dynamic>> get relayTasks => _taskHome.relayTasks;

  /// Whether the latest bootstrap carried an authoritative `tasks` list
  /// (legacy V1 wire, desktops ≤3.15). 3.16.2 dropped the field — the task
  /// list then rides the channel leg (`zcode-task.listTaskList`) instead.
  /// Kept private; the leg decision lives in [_applyRelayOverview] /
  /// [_refreshRelayTasksFromChannel].
  bool _tasksFromBootstrap = false;

  /// Set once a relay task overview lands successfully (see
  /// [taskOverviewLoaded]); reset on suspend/connect teardown so a cold
  /// start never shows a stale "loaded" verdict.
  bool _taskOverviewLanded = false;

  /// In-flight dedup for the channel task leg.
  Future<void>? _tasksRefresh;

  /// In-flight dedup for the cross-workspace pinned-id merge.
  Future<void>? _pinnedMerge;

  /// `zcode-task.listTaskList` scopes assembled from [workspaces] — the
  /// wire list completed with the desktop's project roots on 3.16.2
  /// (research/07), so workspaces outside the bound window are still
  /// pulled. The desktop throws (`reading 'map'`) on an empty scope
  /// list, so callers MUST skip the call when this is empty. Only the
  /// fields the wire requires go out: `workspacePath` is mandatory,
  /// `workspaceIdentity` is optional (and often absent in 3.16.2's
  /// workspace maps).
  List<Map<String, dynamic>> _relayTaskScopes() {
    final scopes = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final ws in workspaces) {
      final path = ws['workspacePath'];
      if (path is! String || path.isEmpty) continue;
      if (!seen.add(path)) continue;
      final identity = ws['workspaceIdentity'];
      scopes.add({
        'workspacePath': path,
        if (identity is String && identity.trim().isNotEmpty)
          'workspaceIdentity': identity.trim(),
      });
    }
    return scopes;
  }

  /// Injects the missing `workspaceIdentity` from the workspace list by
  /// `workspacePath` (3.16.2 relay rows carry no identity — the desktop's
  /// `Dg` schema made it optional and stopped emitting it). Rows that
  /// already carry an identity and rows whose path matches no listed
  /// workspace pass through untouched.
  List<Map<String, dynamic>> _normalizeRelayTasks(
    Iterable<Map<String, dynamic>> rows,
  ) {
    final identityByPath = <String, String>{};
    for (final ws in workspaces) {
      final path = ws['workspacePath'];
      final identity = ws['workspaceIdentity'];
      if (path is String &&
          path.isNotEmpty &&
          identity is String &&
          identity.trim().isNotEmpty) {
        identityByPath.putIfAbsent(path, () => identity.trim());
      }
    }
    final normalized = <Map<String, dynamic>>[];
    for (final row in rows) {
      final current = row['workspaceIdentity'];
      if (current is String && current.trim().isNotEmpty) {
        normalized.add(row);
        continue;
      }
      final path = row['workspacePath'];
      final identity = path is String ? identityByPath[path] : null;
      normalized.add(
        identity == null ? row : {...row, 'workspaceIdentity': identity},
      );
    }
    return normalized;
  }

  /// Channel task leg (desktop 3.16.2+): `zcode-task.listTaskList`
  /// `{kind, workspaceScopes:[non-empty]}` → `{items,total,hasMore}`.
  /// The desktop's queryTaskList SQL filters by kind (3.16.2 asar
  /// @278543112): `timeline` is `pinned = 0 AND archived = 0`, while
  /// `pinned`/`archived` only ever appear under their own kind — a
  /// timeline-only pull loses both classes from the overview. The rows use
  /// the same shape as the legacy methods (`status` instead of
  /// `displayStatus`, no pinned/archived/unreadAt), so the leg itself is
  /// the only evidence: pinned/archived rows are tagged on merge and the
  /// result is consumed through the dual-read parsing layer.
  ///
  /// Any failure (method missing on an old desktop, no bridge yet, desktop
  /// error) keeps the previous rows — never an empty overwrite, so a
  /// transient miss cannot wipe the list or seed false tombstones. A failed
  /// leg aborts the whole round for the same reason: committing a
  /// timeline-only merge would drop pinned/archived rows again.
  Future<void> _refreshRelayTasksFromChannel() {
    if (_tasksFromBootstrap) return Future.value();
    final pending = _tasksRefresh;
    if (pending != null) return pending;
    final future = () async {
      final client = _client;
      try {
        final scopes = _relayTaskScopes();
        // Empty scopes throw desktop-side (`reading 'map'`) — skip and keep
        // the last overview until workspaces are available.
        if (scopes.isEmpty) return;
        final rows = <Map<String, dynamic>>[];
        for (final kind in const ['timeline', 'pinned', 'archived']) {
          final res = await _overviewProbe.run(
            'listTaskList',
            const ['listTaskList'],
            argsOf: (method) => [
              {'kind': kind, 'workspaceScopes': scopes},
            ],
          );
          final items = res is Map ? res['items'] : null;
          if (items is! List) {
            throw StateError('listTaskList($kind) returned no items');
          }
          for (final t in items) {
            if (t is! Map) continue;
            final row = t.cast<String, dynamic>();
            // 3.16.2 wire rows carry no pinned/archived bits (asar
            // rowToTaskListItem + live ITEM0); the leg's SQL is the only
            // evidence, so tag here. The pinned leg's rows are guaranteed
            // pinned=1 AND archived=0, which keeps the pinned section
            // populated even when listPinnedTaskIds fails.
            if (kind == 'pinned') {
              rows.add({...row, 'pinned': true});
            } else if (kind == 'archived') {
              rows.add({...row, 'archived': true});
            } else {
              rows.add(row);
            }
          }
        }
        if (_disposed || _client != client) return;
        // A legacy bootstrap carrying tasks may have landed while the legs
        // were in flight — its authoritative list must not be overwritten.
        if (_tasksFromBootstrap) return;
        // The legs are disjoint by SQL, but a task can still repeat across
        // them; first occurrence wins (timeline, then pinned, archived).
        final deduped = <String, Map<String, dynamic>>{};
        for (final row in rows) {
          deduped.putIfAbsent(
            '${row['taskId'] ?? ''}|${row['workspacePath'] ?? ''}|'
            '${row['workspaceIdentity'] ?? ''}',
            () => row,
          );
        }
        // Fresh overview = fresh anchor evidence + fresh sidecar evidence
        // (30s cadence): reconcile anchors, then re-diff the recently
        // active non-active workspaces.
        _taskHome.applyRelayOverview(_normalizeRelayTasks(deduped.values));
        _taskOverviewLanded = true;
        _recordOverviewWorkspaceActivity();
        notifyListeners();
        await _mergePinnedTaskFlags();
      } catch (e) {
        _log('[session] listTaskList failed (kept old tasks): $e');
      }
    }();
    _tasksRefresh = future;
    // Clear only our own entry: an early (synchronous) completion must not
    // leave a finished Future in the field, or every later refresh would
    // join it and never retry.
    return future.whenComplete(() {
      if (identical(_tasksRefresh, future)) _tasksRefresh = null;
    });
  }

  /// Pinned flags of the channel overview rows: 3.16.2's `listTaskList`
  /// items carry no `pinned` field (the pinned leg already tagged its rows
  /// on merge). The cross-workspace `listPinnedTaskIds` (no args) stays the
  /// authority on top — a successful answer overrides whatever the rows
  /// carried, and a failure keeps the flags tagged by the legs.
  ///
  /// Only the CHANNEL leg merges: legacy bootstrap rows carry their own
  /// `pinned` bit, and the old desktop's cross-workspace semantics of
  /// `listPinnedTaskIds` are not probed (it may only cover the active
  /// workspace, which would wrongly clear other workspaces' pins).
  Future<void> _mergePinnedTaskFlags() {
    final pending = _pinnedMerge;
    if (pending != null) return pending;
    final future = () async {
      final client = _client;
      try {
        if (_tasksFromBootstrap) return;
        if (_taskHome.relayTasks.isEmpty) return;
        final res = await _overviewProbe.run(
          'listPinnedTaskIds',
          const ['listPinnedTaskIds'],
        );
        if (_disposed || _client != client || res is! List) return;
        final ids = {
          for (final id in res)
            if (id is String && id.isNotEmpty) id,
        };
        _taskHome.setRelayTasks([
          for (final row in _taskHome.relayTasks)
            {...row, 'pinned': ids.contains('${row['taskId'] ?? ''}')},
        ]);
        notifyListeners();
      } catch (e) {
        _log('[session] listPinnedTaskIds failed (kept pinned flags): $e');
      }
    }();
    _pinnedMerge = future;
    // Same early-completion guard as [_refreshRelayTasksFromChannel]: an
    // empty overview returns before the first await, and a finished Future
    // parked in the field would disable the merge for good.
    return future.whenComplete(() {
      if (identical(_pinnedMerge, future)) _pinnedMerge = null;
    });
  }

  /// Silently-bound `zcode-task` RPCs for the task overview. These are
  /// best-effort polls: they must NOT feed the link supervisor (a miss here
  /// escalates nothing — the 30s cadence retries naturally, and a refresh
  /// failure is contractually silent).
  late final MethodProbe _overviewProbe = MethodProbe(
    (method, args) => _callChannelQuiet(Channels.zcodeTask, method, args),
  );

  Future<dynamic> _callChannelQuiet(
    String channel,
    String method,
    List<Object?> args,
  ) async {
    final gate = _testGate ?? _liveGate();
    if (gate == null) throw StateError('not connected');
    await gate.waitHealthy(timeout: timings.healthyWaitTimeout);
    return gate.call(channel, method, args).timeout(timings.rpcTimeout);
  }

  /// The task-home assembly (design 10-29 §2): relay rows, both alias
  /// tables, live-frame wiring, the snapshot cache, tombstones and the
  /// materialized directory. Lazy so the fake can replace the sidecar
  /// manager factory (this service builds on it).
  late final TaskHomeService _taskHome = createTaskHomeService();

  /// Test seam: the task-home service (real implementation in tests too —
  /// design §2.11).
  @visibleForTesting
  TaskHomeService get taskHome => _taskHome;

  /// Builds the service with this session's capabilities.
  @visibleForTesting
  TaskHomeService createTaskHomeService() => TaskHomeService(
        store: _homeStore,
        sidecars: _sidecars,
        conversationGroupKey: conversationsWorkspaceKey,
        fallbackScope: () => offPeakScope,
        deleteCopy: (taskId, scope) =>
            taskCommands.delete(taskId, scope: scope),
        onActiveFrameApplied: _onActiveFrameApplied,
        onChanged: notifyMergedChanged,
        log: _log,
      );

  /// Single guarded notify shared by the sidecar manager (subscribe / drop
  /// / frame / probe) and the home-adjudication anchor write.
  @visibleForTesting
  void notifyMergedChanged() {
    if (_disposed) return;
    _recordLiveWorkspaceActivity();
    notifyListeners();
  }

  /// The materialized merged directory — one `_merge()` per dirty revision
  /// (TaskHomeService.directory); reads on one revision are identical.
  @override
  TaskDirectory get taskDirectory => _taskHome.directory;

  // ------------------------------------ sidecar sessions-index (10-28)

  /// The sidecar subscription policy (six strategies + the four state maps)
  /// lives in [SidecarIndexManager]; this session contributes only the
  /// capabilities. Lazy so the test fake can override the factory.
  late final SidecarIndexManager _sidecars = createSidecarManager();

  /// Test seam: the sidecar manager (tests drive reconciliation through it).
  @visibleForTesting
  SidecarIndexManager get sidecarManager => _sidecars;

  /// Test seam: whether [dispose] already ran — the manager's disposed guard
  /// reads it, and the fake manager override needs the same fact.
  @visibleForTesting
  bool get debugDisposed => _disposed;

  /// Builds the manager with this session's capabilities. Overridable so
  /// state tests can drive the policy without a bridge (the fake replaces
  /// the three former `@protected` sidecar seams with this one factory).
  @visibleForTesting
  SidecarIndexManager createSidecarManager() => SidecarIndexManager(
        subscribe: _subscribeSidecar,
        dispose: _disposeSidecar,
        available: () => _conversation != null,
        probeDeleted: (scope) => probeListDeletedTaskIds(
          (method, args) => _callChannelQuiet(Channels.zcodeTask, method, args),
          scope: scope,
        ),
        relayRows: () => relayTasks,
        activeKey: _sidecarActiveKey,
        normalizeKey: (rawKey) => _taskHome.normalizeKey(rawKey),
        onChanged: notifyMergedChanged,
        isDisposed: () => _disposed,
        log: _log,
        limit: sidecarWorkspaceLimit,
        cooldown: sidecarCooldown,
        clock: clock.now,
      );

  /// The normalized active workspace key (null = none). The same alias
  /// normalization the candidate ranking applies.
  String? _sidecarActiveKey() {
    final active = activeWorkspace;
    if (active == null) return null;
    final rawKey = workspaceKeyOf(active);
    if (rawKey == null) return null;
    return _taskHome.normalizeKey(rawKey);
  }

  /// Starts ONE sidecar sessions-index subscription for [scope] on the
  /// active bridge (design 10-28: the same bridge, a different workspace
  /// scope — live-probed). The manager passes the per-key resubscribe
  /// failure hook through.
  Future<SessionsIndexState> _subscribeSidecar(
    String key,
    Map<String, dynamic> scope,
    void Function(Object error) onSubscribeFailure,
  ) async {
    final conversation = _conversation;
    if (conversation == null) throw StateError('not connected');
    final sub = await conversation.subscribeSessionsIndex(
      scope: scope,
      onSubscribeFailure: onSubscribeFailure,
    );
    if (_disposed || _conversation != conversation) {
      // The link / active workspace changed under us: nobody will ever
      // read this subscription — dispose it instead of leaking its timers
      // and its bridge-recovery hook.
      unawaited(sub.dispose());
      throw StateError('sidecar subscription superseded');
    }
    _sidecarSubs[key] = sub;
    return sub.state;
  }

  /// Disposes one sidecar wire subscription (the manager removed its own
  /// state listener already).
  Future<void> _disposeSidecar(String key) async {
    final sub = _sidecarSubs.remove(key);
    if (sub == null) return;
    await sub.dispose();
  }

  /// True while a workspace bridge + sessions-index open is in flight.
  bool get openingWorkspace => _openingWorkspace;

  /// Workspaces reported by bootstrap, completed with the desktop's project
  /// roots on 3.16.2 (research/07 方案 A; see [mergeProjectWorkspaces]).
  /// Every consumer — workspace cards, task search, listTaskList scopes —
  /// reads this merged view; the raw wire list stays private for the
  /// resolver's home derivation.
  List<Map<String, dynamic>> get workspaces => _workspaces;
  Map<String, dynamic>? get activeWorkspace => _activeWorkspace;

  /// Live desktop version reported by the latest bootstrap-response frame,
  /// null until one carries `desktopAppVersion`. Callers that gate wire
  /// shapes on the desktop version should prefer this over [params]
  /// (whose `app_version` is a link-generation snapshot).
  String? get desktopAppVersion => _desktopAppVersion;

  /// Live sessions-index state of the active workspace, if subscribed.
  @override
  SessionsIndexState? get sessions => _sessionsSub?.state;

  /// Conversation transport of the active workspace (chat UI seam).
  ConversationTransport? get conversation => _conversation;

  /// Workspace bridge of the active workspace.
  BridgeSession? get bridge => _bridge;

  /// Sessions with phase running/prewarming — the card badge count.
  int get runningTaskCount =>
      sessions?.list
          .where((e) => e.phase == 'running' || e.phase == 'prewarming')
          .length ??
      0;

  bool get _busy => _connecting;

  /// Connects and subscribes the sessions-index. Safe to call repeatedly;
  /// a live connection is reused, a retryable failure is re-attempted.
  Future<void> connect() async {
    if (_disposed || _busy || _status == DeviceStatus.connected) return;
    _connecting = true;
    _retryTimer?.cancel();
    _listWatchdog?.cancel();
    _kicked = false;
    final clearedColdFailure =
        _lastWorkspaceOpenFailure is WorkspaceOpenRuntimeNotRunning;
    _lastWorkspaceOpenFailure = null;
    _error = null;
    if (clearedColdFailure) {
      _log('[session] cold runtime failure cleared by connect start');
    }
    // New connection episode: a later cold parking must log again.
    _watchdogParked = false;
    _failureReason = null;
    // Live version belongs to the connection that reported it. Until this
    // episode's bootstrap lands with a `desktopAppVersion`, live-then-
    // snapshot capabilities must read the link snapshot, never a previous
    // desktop's value (reconnect to an older desktop would otherwise keep a
    // stale gate open).
    _desktopAppVersion = null;
    _setStatus(DeviceStatus.connecting);
    // V2 links authenticate with the ZCode account JWT. Without the seam
    // there is nothing to dial: fail with the explicit auth-required state
    // so the UI can point the user at the account page (A2). A test-built
    // client bypasses this (clientFactory owns its own wire).
    if (params.v2 && jwtProvider == null && clientFactory == null) {
      _failureReason = 'auth-required';
      _error =
          'auth-required: sign in to your ZCode account to use this remote link';
      _connecting = false;
      _setStatus(DeviceStatus.error);
      return;
    }
    final sw = Stopwatch()..start();
    final client = clientFactory != null
        ? clientFactory!()
        : RemoteClient(
            params,
            onLog: _log,
            jwtProvider: jwtProvider,
          );
    _failureSub = client.relay.failures.listen(_onRelayFailure);
    try {
      // socket.ready has no internal timeout: a black-holed dial would park
      // connect (and the whole UI) in `connecting` forever.
      await client.connect().timeout(timings.dialTimeout);
      sw.reset();
      await client.waitPaired(timeout: const Duration(seconds: 90));
      _log('[session] paired in ${sw.elapsedMilliseconds}ms');
      if (_disposed) {
        await client.dispose();
        return;
      }
      _client = client;
      client.relay.stateListenable.addListener(_onRelayState);
      _wsListSub = client.workspaceListUpdated.listen(_onWorkspaceListUpdated);
      _appErrSub = client.appErrors.listen(_onAppError);
      _onRelayState();
      sw.reset();
      final bootstrap = await client.bootstrap();
      _log('[session] bootstrap in ${sw.elapsedMilliseconds}ms');
      _applyRelayOverview(bootstrap);
      _retryAttempts = 0;
      // Auto-open a workspace so the native list works immediately: the
      // last-used one when known, else the first. (The web mobile flow
      // auto-opens only a single workspace and shows a picker otherwise;
      // here the picker is the fallback, never a blocking spinner.)
      if (_activeWorkspace == null && _workspaces.isNotEmpty) {
        await openWorkspace(_preferredWorkspace ?? _workspaces.first);
      }
      // 3.16.2 bootstrap carries no tasks: pull the channel leg now that a
      // bridge may exist. On legacy links the bootstrap leg already won and
      // this is a no-op; any failure keeps the last overview.
      if (_bridge != null) await _refreshRelayTasksFromChannel();
      _setStatus(DeviceStatus.connected);
      // Status must read connected before arming: the watchdog only guards
      // the healthy-looking-but-never-ready state.
      _armListWatchdog();
    } catch (e) {
      // The relay's failure stream is async and this catch cancels the
      // listener before the event lands; carry the typed start failure's
      // reason over explicitly so `auth-required` survives to the banner.
      if (e is RelayV2StartException) _failureReason ??= e.reason;
      await _failureSub?.cancel();
      _failureSub = null;
      await _wsListSub?.cancel();
      _wsListSub = null;
      await _appErrSub?.cancel();
      _appErrSub = null;
      if (_disposed) {
        await client.dispose();
        return;
      }
      await client.dispose();
      _error = '$e';
      _log(
        '[session] connect failed after '
        '${sw.elapsedMilliseconds}ms: $e',
      );
      _diag('failure', {
        if (_failureReason != null) 'failureReason': _failureReason,
        'failureMessage': '$e',
      });
      _setStatus(DeviceStatus.error);
      _maybeScheduleRetry();
    } finally {
      _connecting = false;
    }
  }

  /// Failures worth retrying a few times: server unreachable or the
  /// desktop temporarily gone. Credential errors (expired URL, conflict,
  /// kicked) never retry — they need user action.
  void _maybeScheduleRetry() {
    if (_disposed || _kicked) return;
    final msg = _error ?? '';
    final retryable =
        msg.contains('relay-unavailable') ||
        msg.contains('desktop-disconnected') ||
        msg.contains('TimeoutException');
    if (!retryable || _retryAttempts >= 3) return;
    _retryAttempts += 1;
    _retryTimer?.cancel();
    _retryTimer = Timer(timings.retryBackoff, () {
      if (!_disposed && _status == DeviceStatus.error) connect();
    });
    _diag('recover-scheduled', {'state': _status.name});
  }

  void _onRelayFailure(RelayFailure failure) {
    if (_disposed) return;
    _error = '$failure';
    // A terminal credential failure must supersede the retryable reasons the
    // transport reports on earlier reconnect rounds (`??=` would pin the
    // first relay-unavailable): the banner and the login self-heal key on
    // auth-required.
    if (failure.reason == 'auth-required') {
      _failureReason = failure.reason;
    } else {
      _failureReason ??= failure.reason;
    }
    _kicked = _kicked || failure.reason == 'kicked';
    if (_kicked) {
      // Another terminal took over; stay quiet until the user acts.
      _retryTimer?.cancel();
    }
    _diag('failure', {
      'failureReason': failure.reason,
      if (failure.message != null) 'failureMessage': failure.message,
    });
    notifyListeners();
  }

  /// Relay push (`workspace-list-updated {result:{workspaces, tasks?, ...}}`):
  /// the live workspace+task overview the web mobile home renders from.
  /// Workspaces merge here; task rows are re-rendered by listeners.
  void _onWorkspaceListUpdated(dynamic result) {
    if (_disposed || result is! Map) return;
    final list = result['workspaces'];
    if (list is List) {
      _setBootstrapWorkspaces([
        for (final w in list)
          if (w is Map) w.cast<String, dynamic>(),
      ]);
    }
    final tasks = result['tasks'];
    if (tasks is List) {
      // Push frames carry a fresh task overview: same anchor reconcile +
      // sidecar re-diff as [_applyRelayOverview] (design 10-15 §1.1,
      // design 10-28). The rows keep their own `pinned` bits — the
      // cross-workspace pinned merge belongs to the 3.16.2 channel leg only.
      _taskHome.applyRelayOverview(_normalizeRelayTasks([
        for (final t in tasks)
          if (t is Map) t.cast<String, dynamic>(),
      ]));
      _taskOverviewLanded = true;
      _recordOverviewWorkspaceActivity();
    }
    notifyListeners();
  }

  /// `app-error` reason → session failure state. session-conflict means the
  /// single mobile slot was taken by another page (web `singlePageNote`
  /// semantics): treated like a kick — no auto-reconnect until the user acts.
  void _onAppError(RemoteAppError e) {
    if (_disposed || _kicked) return;
    _log('[session] app-error ${e.reason}');
    switch (e.reason) {
      case 'session-conflict':
      case 'kicked':
        _kicked = true;
        _failureReason = e.reason;
        _error = e.message;
        _retryTimer?.cancel();
        _setStatus(DeviceStatus.error);
      case 'relay-unavailable':
      case 'desktop-disconnected':
      case 'session-expired':
      case 'workspace-closed':
      case 'session-not-found':
      case 'invalid-mobile-connection':
      case 'desktop-bootstrap-timeout':
      case 'connection-recovery-timeout':
      case 'unsupported-action':
      case 'unexpected-error':
        _failureReason = e.reason;
        _error = e.message;
        _setStatus(DeviceStatus.error);
      default:
        _failureReason = e.reason;
        _error = e.message;
        _setStatus(DeviceStatus.error);
    }
    _diag('failure', {
      'failureReason': e.reason,
      if (e.message != null) 'failureMessage': e.message,
    });
    notifyListeners();
  }

  void _onRelayState() {
    if (_disposed) return;
    switch (_client?.relay.state) {
      case RelayState.paired:
        // Transient reconnects pass through here again; only clear the
        // error banner, sessions state keeps its last snapshot.
        if (_status == DeviceStatus.connecting ||
            _status == DeviceStatus.error) {
          final clearedColdFailure =
              _lastWorkspaceOpenFailure is WorkspaceOpenRuntimeNotRunning;
          _lastWorkspaceOpenFailure = null;
          _error = null;
          if (clearedColdFailure) {
            _log('[session] cold runtime failure cleared by relay paired');
          }
          _setStatus(DeviceStatus.connected);
        }
      case RelayState.connecting:
      case RelayState.authenticating:
      case RelayState.waiting:
      case RelayState.reconnecting:
        if (_status != DeviceStatus.connected) {
          _setStatus(DeviceStatus.connecting);
        }
      case RelayState.kicked:
        _kicked = true;
        _setStatus(DeviceStatus.error);
      case RelayState.error:
        _setStatus(DeviceStatus.error);
      case RelayState.closed:
      case null:
      case RelayState.idle:
        break;
    }
    _setConnectionStage(_deriveConnectionStage());
  }

  /// Derives the display-only [connectionStage] purely from authoritative
  /// state (V10): [_rebuilding] first — the forced rebuild suspends the link,
  /// so a status-only read would flash "disconnected" mid-window — then the
  /// relay's own state, which is the only place `pairing` and `reconnecting`
  /// are distinguishable (the session flattens both into `connecting`).
  /// Every other combination derives null.
  String? _deriveConnectionStage() {
    if (_disposed) return null;
    if (_rebuilding) return 'rebuilding';
    return switch (_client?.relay.state) {
      RelayState.waiting => 'pairing',
      RelayState.reconnecting => 'reconnecting',
      _ => null,
    };
  }

  /// mobile-diagnostic emitter (D3): the session state machine's reporting
  /// line. [_client] may be null (or the link already closed) during early
  /// transitions — the relay drops then. Void, never awaited, never throws.
  ///
  /// D3 is a closed set: the wire `failureReason` must stay inside the
  /// desktop's 11-value enum. The relay KICKED path's internal 'kicked'
  /// (RelayFailure.reason / `_kicked`, both consumed unchanged by the
  /// kicked state machine and the UI) maps to its semantic desktop
  /// equivalent 'session-conflict' on this outbound line only — relay
  /// close code 4009 is the same event.
  void _diag(String event, [Map<String, dynamic>? fields]) {
    if (fields != null) {
      final reason = fields['failureReason'];
      if (reason == 'kicked') {
        fields = {...fields, 'failureReason': 'session-conflict'};
      } else if (reason == 'auth-required') {
        // D3 is a closed 11-value enum and has no auth value; the V2
        // account gate is a client-side state, so the wire keeps the
        // generic value while the UI keeps the precise reason.
        fields = {...fields, 'failureReason': 'unexpected-error'};
      }
    }
    _client?.sendMobileDiagnostic(event, fields);
  }

  void _setStatus(DeviceStatus s) {
    if (_status == s) return;
    final previous = _status;
    _status = s;
    // Stage rides the state machine: re-derived at this single status write
    // entry, assigned directly (never through [_setConnectionStage]) so the
    // notify below — one per status change, as before — is the only repaint
    // this path emits. [_rebuilding] wins inside the derivation, so the
    // forced rebuild's `suspend()` frame (which flips the status to
    // disconnected) keeps "rebuilding" on screen instead of blanking it.
    _connectionStage = _deriveConnectionStage();
    _diag('state-transition', {
      'state': s.name,
      'previousState': previous.name,
    });
    notifyListeners();
  }

  /// Writes the display-only [_connectionStage] projection: a value-identical
  /// write is a no-op (dedupe), a real change repaints once. Only the two
  /// low-frequency writers outside [_setStatus] call it — [_onRelayState] and
  /// [_forceRebuildAfterStall] — never [_onActiveFrameApplied] (per-frame
  /// notify). [_setStatus] assigns the field directly instead, so its own
  /// single notify is not doubled.
  void _setConnectionStage(String? next) {
    if (_connectionStage == next) return;
    _connectionStage = next;
    notifyListeners();
  }

  /// The workspace matching [preferredWorkspaceKey], if still listed.
  Map<String, dynamic>? get _preferredWorkspace {
    final key = preferredWorkspaceKey;
    if (key == null) return null;
    for (final w in _workspaces) {
      if (workspaceKeyOf(w) == key) return w;
    }
    return null;
  }

  /// Opens (or switches to) a workspace bridge and subscribes its
  /// sessions-index. Switching disposes the previous bridge first.
  ///
  /// Concurrent calls are serialized (last wins) instead of dropped: an
  /// open already in flight used to swallow overlapping retries silently,
  /// which read exactly like the dead "retry" button of the loading bug.
  /// [taskId] rides the `workspace-bridge-open` payload (tapping
  /// a task of a non-active workspace opens the bridge straight onto it).
  /// [purpose] opts the open into the 3.16.3+ window-gate fallback chain
  /// (project / task-host addressing); null keeps the single-leg behavior
  /// for internal opens.
  ///
  /// Returns the typed outcome. Callers that push a chat page after the
  /// open use a non-[WorkspaceOpenOpened] result to block it (the bridge
  /// still points at the previous workspace, so a chat there would
  /// subscribe under the wrong scope). Failures are also remembered as
  /// [lastWorkspaceOpenFailure] for the watchdog and the banner; a success
  /// clears it.
  Future<WorkspaceOpenResult> openWorkspace(
    Map<String, dynamic> workspace, {
    String? taskId,
    WorkspaceOpenPurpose? purpose,
  }) {
    final previous = _openChain;
    final completer = Completer<WorkspaceOpenResult>();
    _openChain = completer;
    () async {
      WorkspaceOpenResult result = const WorkspaceOpenAborted();
      try {
        if (previous != null) {
          try {
            await previous.future;
          } catch (_) {}
        }
        if (_disposed) return;
        result = await _openWorkspaceNow(
          workspace,
          taskId: taskId,
          purpose: purpose,
        );
      } finally {
        if (identical(_openChain, completer)) _openChain = null;
        completer.complete(result);
      }
    }();
    return completer.future;
  }

  Completer<WorkspaceOpenResult>? _openChain;

  /// The shared 「open an existing task」 entry (design 11-07 D1): resolve
  /// the task's workspace, open it only when the bridge is not already
  /// there, and answer the typed outcome. Both the task list and the
  /// notification transition page call THIS — the branch logic lives here,
  /// never copied into a caller.
  ///
  /// The open decision is the former list-page `_needsWorkspaceOpen` rule:
  /// a non-active workspace needs the bridge re-pointed, and so does the
  /// active one after a cold-runtime failure (a successful re-open is what
  /// clears the banner and rebuilds its live index).
  ///
  /// [workspaceHint] is the notification payload's own `workspacePath` /
  /// `workspaceIdentity` (design 11-07 R1): a cold-start tap arrives before
  /// the relay overview, so the directory may not know the task yet. The
  /// hint is used ONLY when the directory has no answer — a directory
  /// resolution always wins (it carries the anchored home pick), and a hint
  /// that names no listed workspace still yields its minimal origin scope.
  @override
  Future<WorkspaceOpenResult?> prepareTaskOpen(
    String taskId, {
    Map<String, dynamic>? workspaceHint,
  }) async {
    final active = activeWorkspace;
    final workspace = _resolveOwnership(taskId, workspaceHint: workspaceHint);
    if (workspace == null) return null;
    final needsOpen = workspaceKeyOf(workspace) !=
            workspaceKeyOf(active ?? const <String, dynamic>{}) ||
        lastWorkspaceOpenFailure is WorkspaceOpenRuntimeNotRunning;
    if (!needsOpen) return const WorkspaceOpenOpened();
    return openWorkspace(
      workspace,
      taskId: taskId,
      purpose: WorkspaceOpenPurpose.openTask,
    );
  }

  /// The revoke generation [sessionId] currently sits at (0 = never revoked).
  int _chatGenerationOf(String sessionId) => _chatGenerations[sessionId] ?? 0;

  /// Ownership resolution shared by [prepareTaskOpen] and
  /// [resumeSessionOnReturn]: the directory's answer wins, [workspaceHint]
  /// only fills in when the directory is silent (design 11-07 D3). Null
  /// means ownership is undeterminable.
  Map<String, dynamic>? _resolveOwnership(
    String sessionId, {
    Map<String, dynamic>? workspaceHint,
  }) {
    final active = activeWorkspace;
    return _taskHome.workspaceOfTask(
          sessionId,
          activeKey: active == null ? null : workspaceKeyOf(active),
        ) ??
        _hintWorkspace(workspaceHint);
  }

  /// Orphan recovery (11-08 session restore, AC1/AC4/AC5).
  ///
  /// [sessionId] was the visible page's session when the host revoked its
  /// subscription (a workspace switch keeps one bridge — see
  /// [_openWorkspaceNow]'s teardown). This re-points the bridge at the
  /// SESSION'S OWN workspace and re-subscribes, answering the fresh handle.
  ///
  /// Same-workspace + live subscription is a no-op answering the live
  /// handle (zero RPC). Concurrent calls for one id share one future. The
  /// `_openChain` is last-wins and re-entry answers [WorkspaceOpenAborted]:
  /// that is re-run ONCE in place (the TaskOpenPage rule), a second abort
  /// throws. All failures throw [SessionResumeException], never raw wire
  /// text.
  @override
  Future<ChatHandle> resumeSessionOnReturn(String sessionId) {
    final existing = _resumeInFlight[sessionId];
    // In-flight merge (AC4 debounce): a burst of didPopNext callbacks must
    // not chain two open/subscribe rounds for one session.
    if (existing != null) return existing;
    final future = _resumeSessionNow(sessionId);
    _resumeInFlight[sessionId] = future;
    return future.whenComplete(() {
      if (identical(_resumeInFlight[sessionId], future)) {
        _resumeInFlight.remove(sessionId);
      }
    });
  }

  Future<ChatHandle> _resumeSessionNow(String sessionId) async {
    final workspace = _resolveOwnership(sessionId);
    if (workspace == null) {
      // Same dead end as prepareTaskOpen's null: ownership is undeterminable,
      // a guessed scope would produce the exact dead page this task fixes.
      throw const SessionResumeException(SessionResumeFailure.scopeUnknown);
    }
    final live = _chatSubs[sessionId];
    if (live != null) {
      // Already home and subscribed — zero RPC. A revoke clears the map
      // entry for the same id, so a live entry can only mean "still alive"
      // (the page's handle may merely be an older view of it).
      return _handleFor(sessionId, live);
    }
    if (_disposed) {
      throw const SessionResumeException(
        SessionResumeFailure.subscribe,
        cause: 'disposed',
      );
    }
    _resumingSessions.add(sessionId);
    try {
      // Reuse prepareTaskOpen's decision rule: a bridge already home needs no
      // open; a cold-runtime failure on the active workspace still needs the
      // re-open that clears the banner. workspaceHint is unused here — the
      // directory (or a live-only row) is the only ownership source a visible
      // page has.
      final ownerKey = _taskHome.normalizeKey(workspaceKeyOf(workspace) ?? '');
      final needsOpen = ownerKey != _sidecarActiveKey() ||
          lastWorkspaceOpenFailure is WorkspaceOpenRuntimeNotRunning;
      if (needsOpen) {
        // Aborted = superseded by a concurrent open (last-wins chain). Re-run
        // ONCE in place, exactly like TaskOpenPage; a second abort is the
        // classified dead end.
        var result = await openWorkspace(
          workspace,
          purpose: WorkspaceOpenPurpose.openTask,
        );
        if (result is WorkspaceOpenAborted) {
          result = await openWorkspace(
            workspace,
            purpose: WorkspaceOpenPurpose.openTask,
          );
        }
        switch (result) {
          case WorkspaceOpenOpened():
            break;
          case WorkspaceOpenAborted():
            throw const SessionResumeException(
              SessionResumeFailure.openAborted,
            );
          case WorkspaceOpenRuntimeNotRunning() ||
                WorkspaceOpenUnreachable() ||
                WorkspaceOpenTransportFailure():
            // `foreignWorkspace` covers "the workspace home could not be
            // prepared"; the page maps it through the same open-failure copy
            // chain TaskOpenPage uses (runtime-not-running vs unreachable).
            throw SessionResumeException(
              SessionResumeFailure.foreignWorkspace,
              cause: result,
            );
        }
      }
      try {
        return await subscribe(sessionId);
      } catch (e) {
        if (isSessionNotFoundError(e)) {
          // The bridge is home and the desktop STILL refuses the session:
          // this one is a genuine missing session (subscribe recorded it in
          // [_sessionMissingIds] — correct here). Classified, not raw.
          throw SessionResumeException(
            SessionResumeFailure.sessionMissing,
            cause: e,
          );
        }
        throw SessionResumeException(
          SessionResumeFailure.subscribe,
          cause: e,
        );
      }
    } finally {
      _resumingSessions.remove(sessionId);
    }
  }

  /// One reader's view of a live subscription.
  ChatHandle _handleFor(String sessionId, ConversationSubscription sub) {
    final generation = _chatGenerationOf(sessionId);
    return ChatHandle(
      generation: generation,
      revoked: () => _chatGenerationOf(sessionId) != generation,
      state: sub.state,
      close: () async {
        // Guarded by identity: an older handle closing AFTER a resume
        // installed a fresh subscription must not tear down the new one (or
        // its terminal listener).
        if (_chatSubs[sessionId] != sub) return;
        _chatSubs.remove(sessionId);
        final terminal = _chatTerminalSubs.remove(sessionId);
        await terminal?.cancel();
        await sub.dispose();
      },
    );
  }

  /// The payload hint as a workspace map: a listed entry when the path
  /// names one (label/identity preserved), else the minimal origin scope.
  Map<String, dynamic>? _hintWorkspace(Map<String, dynamic>? hint) {
    if (hint == null) return null;
    final path = hint['workspacePath'];
    if (path is! String || path.isEmpty) return null;
    final identity = hint['workspaceIdentity'];
    for (final ws in _workspaces) {
      if (ws['workspacePath'] == path ||
          (identity is String && ws['workspaceIdentity'] == identity)) {
        return ws;
      }
    }
    return {
      'workspacePath': path,
      if (identity is String && identity.isNotEmpty)
        'workspaceIdentity': identity,
    };
  }

  Future<WorkspaceOpenResult> _openWorkspaceNow(
    Map<String, dynamic> workspace, {
    String? taskId,
    WorkspaceOpenPurpose? purpose,
  }) async {
    final key = workspaceKeyOf(workspace);
    final client = _client;
    if (key == null || client == null || _disposed || _openingWorkspace) {
      return const WorkspaceOpenAborted();
    }
    _openingWorkspace = true;
    final sw = Stopwatch()..start();
    _listWatchdog?.cancel();
    try {
      final bridge = await _openBridgeAddressed(
        client,
        key: key,
        workspace: workspace,
        taskId: taskId,
        purpose: purpose,
      );
      if (_disposed || _client != client) {
        bridge.dispose();
        return const WorkspaceOpenAborted();
      }
      // The bridge's OWN workspace key, not the requested one: project-draft
      // addressing (formB) makes the desktop prepare a NEW draft workspace,
      // so the reply can differ. Everything downstream (active card, scope,
      // sessions-index subscription, createSession) must follow the reply.
      final active = _workspaceOfBridge(bridge, workspace, key);
      final activeKey = workspaceKeyOf(active) ?? key;
      if (activeKey != key) {
        _log('[session] bridge opened $activeKey '
            'for requested key=$key');
      }
      final oldSub = _sessionsSub;
      // The OLD active workspace key, captured before `_activeWorkspace`
      // is replaced below: its ready state is the newest-sidecar seed of the
      // carry-over (design 11-02 §3.1, review P1-2). Normalized like every
      // manager map key.
      final oldActiveKey = _sidecarActiveKey();
      final oldBridge = _bridge;
      final oldChats = Map.of(_chatSubs);
      final oldTerminalSubs = Map.of(_chatTerminalSubs);
      _sessionsSub = null;
      // Detach the old index listener now (the old subscription may still
      // deliver during its async dispose — the service must not diff the
      // replaced state).
      _taskHome.setActiveSessions(
        null,
        generation: () => 0,
        frameKind: () => null,
      );
      // Fresh subscription = fresh tombstone diff baseline: the first
      // ready frame of the new index only establishes it (a workspace
      // switch must never read the previous workspace's ids as mass
      // deletions).
      _taskHome.onWorkspaceOpened();
      _conversation = null;
      _chatSubs.clear();
      _chatTerminalSubs.clear();
      // Host revoke (11-08 session restore): the readers behind these
      // subscriptions keep their page State across the switch and get no
      // signal anywhere else — bump their generation so a later
      // `didPopNext` can tell "my subscription was torn down by the host"
      // from "I closed it myself". Only THIS path advances the counter.
      for (final sessionId in oldChats.keys) {
        _chatGenerations[sessionId] = _chatGenerationOf(sessionId) + 1;
      }
      // Sidecar subscriptions live on the same bridge as the active one
      // (per-scope EventListens + subscribes): drop them BEFORE the old
      // bridge dies, or their recovery hooks and timers outlive it.
      // ORDER MATTERS: `_conversation = null` above must ALSO precede
      // `detachAll()` — it is what stops in-flight sidecar subscribes from
      // installing on the dying bridge (check 11-02 P3-1).
      // The switch keeps their DATA as stale carry-over (design 11-02 §3):
      // the merge renders the last real phases until the new bridge's fresh
      // subscriptions deliver their first snapshots instead of flapping
      // back to the relay's last-turn outcome.
      _sidecars.detachAll();
      final oldState = oldSub?.state;
      if (oldActiveKey != null && oldState != null) {
        // Seed the workspace being left; only a ready state is accepted
        // (an unsnapshotted one has nothing to carry and would paint a fake
        // empty card). `seedStale` rewrites the subscription identity to
        // the canonical key (the open recorded the raw spelling).
        _sidecars.seedStale(oldActiveKey, oldState, now: clock.now());
      }
      _bridge = bridge;
      _activeWorkspace = active;
      // Fresh bridge = fresh channel client: re-hang the managed listeners.
      _reattachChannelListeners();
      unawaited(oldSub?.dispose());
      // The dedicated terminal listener dies with the subscription it
      // guards: a subscription disposed by the HOST path also gets a fresh
      // refused-state read on resume, so a stale listener would double-add
      // a missing id.
      for (final t in oldTerminalSubs.values) {
        unawaited(t.cancel());
      }
      for (final s in oldChats.values) {
        unawaited(s.dispose());
      }
      oldBridge?.dispose();

      final scope = <String, dynamic>{
        'workspacePath': active['workspacePath'],
        if (active['workspaceIdentity'] != null)
          'workspaceIdentity': active['workspaceIdentity'],
      };
      final conversation = bridge.conversation(
        scope,
        onLog: _log,
        projectIdFor: _projectIdForCreate,
        // Chat sends feed the same failure ledger callChannel uses
        // (ADR-0009 covers every send path).
        onLinkLevelFailure: _onTransportLinkLevelFailure,
        onChannelSuccess: _onTransportChannelSuccess,
      );
      _conversation = conversation;
      final sub = await conversation.subscribeSessionsIndex();
      if (_disposed || _bridge != bridge) {
        await sub.dispose();
        return const WorkspaceOpenAborted();
      }
      _sessionsSub = sub;
      sub.state.subscribedWorkspaceKey = activeKey;
      // 3.16.2 project prewarm + workspace-list completion (acceptance
      // round 1 P1-2; research/07 方案 A): read the desktop's project
      // index off the createSession critical path — a handful of pages, so
      // the first create hits the cache instead of paying the read on its
      // own 30 s RPC budget — and complete the workspace list with the
      // project roots the single-window bootstrap registry omits.
      // Fire-and-forget: the resolver never throws; a create landing
      // mid-read shares the in-flight future, and a failed read leaves both
      // consumers in their pre-feature shape.
      if (capabilities.projectLayer) {
        unawaited(_refreshProjectWorkspaces());
      }
      // Deleted-task tombstones for the live-index filter (Addendum 2):
      // probed once per open; any failure (old desktop without the method,
      // channel gone) degrades to an empty set and must never block
      // opening the workspace.
      try {
        final deleted = await probeListDeletedTaskIds(
          (method, args) => callChannel(Channels.zcodeTask, method, args),
          scope: scope,
        );
        // Same early-exit chain as above: the open may have been
        // superseded while the probe was in flight — whoever replaced the
        // bridge already disposed this sub, so plain return.
        if (_disposed || _bridge != bridge) {
          return const WorkspaceOpenAborted();
        }
        if (deleted != null) sub.state.deletedTaskIds = Set.of(deleted);
      } catch (_) {
        sub.state.deletedTaskIds = const {};
      }
      _taskHome.setActiveSessions(
        sub.state,
        generation: () => sub.generation,
        frameKind: () => sub.applyingFrameKind,
      );
      _log('[session] workspace open ok: key=$key '
          '(${sw.elapsed.inMilliseconds}ms)');
      // A snapshot may have landed during the tombstone probe above —
      // before the listener attached. Confirm whatever is already there
      // (a no-op while the index is still empty), snapshot it into the
      // cache and baseline the tombstone diff against it, so a removal
      // delta in the very first post-attach frame still finds its
      // before-ids. Deliberately the open-path order (confirm → snapshot
      // → record), not the listener order (design §0.6).
      _taskHome.applyWorkspaceOpenedCatchUp(
        sub.state,
        generation: sub.generation,
        frameKind: sub.applyingFrameKind,
      );
      final clearedColdFailure =
          _lastWorkspaceOpenFailure is WorkspaceOpenRuntimeNotRunning;
      _lastWorkspaceOpenFailure = null;
      _error = null;
      if (clearedColdFailure) {
        // Diagnose what clears the actionable banner: a successful open of
        // any workspace (not necessarily the cold one) used to hide it.
        _log('[session] cold runtime failure cleared by open ok: '
            'key=$activeKey');
      }
      onWorkspaceOpened?.call(activeKey);
      notifyListeners();
      // The active workspace changed: re-diff the sidecar set on the fresh
      // bridge (the old active workspace is now a candidate; the newly
      // active one must leave the set).
      _sidecars.reconcile();
      return const WorkspaceOpenOpened();
    } catch (e) {
      final code = e is ChannelRpcError && e.data is Map
          ? (e.data as Map)['code']
          : null;
      _log('[session] workspace open failed: $e'
          '${code == null ? '' : ' (code=$code)'}'
          ' (${sw.elapsedMilliseconds}ms)');
      // The relay link itself is fine; only the native list is degraded —
      // surface the reason so the UI can offer retry / web fallback
      // instead of an eternal spinner. A window-gate dead end and a cold
      // per-workspace runtime are DIFFERENT typed dead ends (the latter's
      // bridge IS attached; the desktop has not started this workspace's
      // agent process); everything else keeps the raw message.
      final WorkspaceOpenResult result;
      if (e is _WorkspaceUnreachable || isWorkspaceWindowGateError(e)) {
        result = WorkspaceOpenUnreachable(
          e is _WorkspaceUnreachable ? e.cause : e,
        );
      } else if (isAgentRuntimeNotRunningError(e)) {
        result = WorkspaceOpenRuntimeNotRunning(e);
      } else {
        // Single source: the raw error object rides the typed result and
        // the UI renders it verbatim; [_error] stays reserved for
        // link/app errors (connect failure, app-error, reload bootstrap).
        result = WorkspaceOpenTransportFailure(e);
      }
      _lastWorkspaceOpenFailure = result;
      notifyListeners();
      return result;
    } finally {
      _openingWorkspace = false;
      sw.stop();
      // Connected-but-never-ready (open failed OR subscribed with no
      // snapshot yet) is exactly the cold-start loading bug: guard it.
      _armListWatchdog();
    }
  }

  /// The desktop local host id every 3.16.3 addressing leg carries. Project
  /// rows the resolver can name and tasks in the relay overview all belong
  /// to this machine (`projects.host_id == 'local'`; remote hosts live in
  /// another machine's index).
  static const String _localHostId = 'local';

  /// Whether the desktop understands the 3.16.3 addressing fields. The
  /// bootstrap frame's live [desktopAppVersion] wins when present — the
  /// paired link's `app_version` is a generation-time snapshot that can lag
  /// the running desktop (live acceptance: a 3.16.3 desktop behind a 3.16.2
  /// link, where the stale gate kept the fallback leg from ever firing) —
  /// and falls back to that snapshot when the frame carries nothing.
  bool get _supportsBridgeAddressing => capabilities.bridgeAddressing;

  /// First addressing leg is the pre-3.16.3 frame. When the desktop's
  /// bounded-window registry misses [key], the 3.16.3+ schemas accept a
  /// second leg (live-probed against 3.16.3):
  /// - [WorkspaceOpenPurpose.openTask]: `taskId + taskHostId` (READY — the
  ///   desktop opens the task's own workspace into the bound window);
  /// - [WorkspaceOpenPurpose.chatNew]: borrow a non-archived task of the
  ///   workspace as `taskId + taskHostId` (same READY form — the workspace
  ///   lands in the window and the following createSession stays on the
  ///   existing success path), or, for a desktop-managed default/draft
  ///   workspace with no task row, `project:{projectId:null, hostId}`
  ///   (READY — the desktop prepares a NEW draft workspace; the reply's
  ///   workspaceKey differs and [_openWorkspaceNow] follows it).
  ///   A project workspace with no task has no viable leg: the live probe
  ///   rejected `project:{projectId}` with `project.not-found` (the
  ///   external projectId is not admitted by the renderer's project
  ///   navigation domain), so the dead end stands.
  ///
  /// The version gate is mandatory BEFORE the first send of the extra
  /// fields (an older strict validator may drop the whole frame);
  /// purpose-less internal opens keep the single-leg behavior.
  ///
  /// A second-leg failure is wrapped in [_WorkspaceUnreachable], so the
  /// caller's catch localizes the dead end while the log keeps the desktop's
  /// raw refusal.
  Future<BridgeSession> _openBridgeAddressed(
    RemoteClient client, {
    required String key,
    required Map<String, dynamic> workspace,
    String? taskId,
    WorkspaceOpenPurpose? purpose,
  }) async {
    try {
      return await client.openBridge(key, taskId: taskId);
    } catch (e) {
      if (purpose == null ||
          !isWorkspaceWindowGateError(e) ||
          !_supportsBridgeAddressing) {
        rethrow;
      }
      if (purpose == WorkspaceOpenPurpose.openTask) {
        if (taskId == null || taskId.isEmpty) rethrow;
        _log('[session] workspace outside the desktop window; retrying with '
            'task host addressing: key=$key task=$taskId');
        try {
          return await client.openBridge(
            key,
            taskId: taskId,
            taskHostId: _localHostId,
          );
        } catch (e) {
          throw _WorkspaceUnreachable(e);
        }
      }
      final borrowed = _relayTaskIdFor(key);
      if (borrowed != null) {
        _log('[session] workspace outside the desktop window; retrying by '
            'borrowing task host addressing: key=$key task=$borrowed');
        try {
          return await client.openBridge(
            key,
            taskId: borrowed,
            taskHostId: _localHostId,
          );
        } catch (e) {
          throw _WorkspaceUnreachable(e);
        }
      }
      if (!_isDesktopManagedWorkspacePath(workspace['workspacePath'])) rethrow;
      _log('[session] workspace outside the desktop window; retrying with '
          'draft project addressing: key=$key');
      try {
        return await client.openBridge(
          key,
          // `project` is mutually exclusive with `taskId` server-side. The
          // null projectId is the desktop's draft shape (formB): it
          // prepares a fresh draft workspace instead of reusing one.
          project: {'projectId': null, 'hostId': _localHostId},
        );
      } catch (e) {
        throw _WorkspaceUnreachable(e);
      }
    }
  }

  /// A non-archived relay task living in [key]'s workspace, most recently
  /// updated first — the taskId the chatNew fallback borrows to make the
  /// desktop open that workspace into the bound window. Keys normalize
  /// through the service's key aliases (an identity-keyed workspace lists its
  /// rows by path until the overview leg re-normalizes them — check W1,
  /// 10-26), and mirror copies cannot win: an id whose persisted home anchor
  /// points elsewhere is skipped outright (the anchor is the anti-pollution
  /// truth — a pollution copy IS the freshest row by construction), and an
  /// un-anchored multi-copy id is ambiguous by definition (check W2 —
  /// borrowing either would prepare the wrong workspace, the exact bug
  /// this task fixes). No group aliases: borrowing a task from another
  /// workspace would prepare the wrong directory.
  String? _relayTaskIdFor(String key) {
    String norm(String k) => _taskHome.normalizeKey(k);
    final wanted = norm(key);
    final copiesById = <String, int>{};
    for (final task in _taskHome.relayTasks) {
      final id = task['taskId'];
      if (id is String && id.isNotEmpty) {
        copiesById[id] = (copiesById[id] ?? 0) + 1;
      }
    }
    String? bestId;
    var bestUpdatedAt = -1;
    for (final task in _taskHome.relayTasks) {
      if (task['archived'] == true) continue;
      final rowKey = TaskDirectory.relayKeyOf(task);
      if (rowKey == null || norm(rowKey) != wanted) continue;
      final id = task['taskId'];
      if (id is! String || id.isEmpty) continue;
      if (_homeStore.locallyDeletedTaskIds.contains(id)) continue;
      final anchored = _homeStore.homeKeys[id];
      if (anchored != null) {
        if (norm(anchored) != wanted) continue;
      } else if ((copiesById[id] ?? 0) > 1) {
        continue;
      }
      final updatedAt = (task['updatedAt'] as num?)?.toInt() ?? 0;
      if (updatedAt > bestUpdatedAt) {
        bestUpdatedAt = updatedAt;
        bestId = id;
      }
    }
    return bestId;
  }

  /// Whether [path] names a workspace the desktop itself manages under
  /// `.zcode/workspace` (`default` or a `draft-*` directory). Those have no
  /// project row and accept the null-project draft leg; project roots do
  /// not. Slash-normalized so both Windows and POSIX spellings match.
  bool _isDesktopManagedWorkspacePath(Object? path) =>
      path is String &&
      path.replaceAll(r'\', '/').contains('/.zcode/workspace/');

  /// The workspace the READY bridge actually points at: `bridge.workspaceKey`,
  /// falling back to the requested map when the reply names the same
  /// workspace (the usual path — keeps identity/label) or is absent. When
  /// the reply names a different workspace (the draft-project leg prepares
  /// a fresh draft), the listed entry for it is used, else a minimal path
  /// map, so the subsequent subscription and createSession carry the real
  /// scope instead of the requested one.
  Map<String, dynamic> _workspaceOfBridge(
    BridgeSession bridge,
    Map<String, dynamic> requested,
    String requestedKey,
  ) {
    final replyKey = bridge.workspaceKey;
    if (replyKey == null || replyKey.isEmpty || replyKey == requestedKey) {
      return requested;
    }
    for (final ws in _workspaces) {
      if (workspaceKeyOf(ws) == replyKey ||
          ws['workspacePath'] == replyKey ||
          ws['workspaceIdentity'] == replyKey) {
        return ws;
      }
    }
    return {'workspacePath': replyKey};
  }

  /// The active sessions-index listener tail (invoked by
  /// [TaskHomeService] after its record/confirm/snapshot wiring): watchdog
  /// reset + the single notify. The service calls this for EVERY active
  /// index notification, including not-ready ones (the pre-extraction
  /// shape: only the wiring was gated on `ready`, never the notify).
  void _onActiveFrameApplied() {
    if (_disposed) return;
    // The list is alive again (a fresh snapshot landed) — or a not-ready
    // repaint arrived: both re-arm the stall defenses from zero.
    _listWatchdog?.cancel();
    _listEscalations = 0;
    _softReloadFails = 0;
    _recordLiveWorkspaceActivity();
    notifyListeners();
  }

  /// Arms the never-ready watchdog while the task list has no snapshot.
  /// Disarmed instantly by [_onActiveFrameApplied] once frames arrive, and by
  /// suspend/connect teardowns via the shared cancel points.
  void _armListWatchdog() {
    _listWatchdog?.cancel();
    if (_disposed || status != DeviceStatus.connected) return;
    // A cold per-workspace agent runtime is a benign, user-actionable dead
    // end: reconnecting cannot start it (only the desktop can), so the
    // watchdog would rebuild the relay every timeout and the banner would
    // flash between "connecting" and the runtime copy. Park it until the
    // user retries after opening the workspace on the desktop.
    if (_lastWorkspaceOpenFailure is WorkspaceOpenRuntimeNotRunning) {
      if (!_watchdogParked) {
        _watchdogParked = true;
        _log('[session] list watchdog parked: agent runtime not running');
      }
      return;
    }
    _watchdogParked = false;
    final sub = _sessionsSub;
    if (sub != null && sub.state.ready) return;
    if (_activeWorkspace == null &&
        _preferredWorkspace == null &&
        _workspaces.isEmpty) {
      // Desktop reports no workspaces: an empty list IS the ready state.
      return;
    }
    _log(
      '[session] list not ready; watchdog armed '
      '(${timings.listReadyTimeout.inSeconds}s)',
    );
    _listWatchdog = Timer(timings.listReadyTimeout, _onListNotReady);
  }

  void _onListNotReady() {
    if (_disposed || _kicked || status != DeviceStatus.connected) return;
    // A timer callback can already be queued when the open's synchronous
    // segment parks the watchdog; the typed cold-runtime result still
    // means "do not escalate" (a soft reopen cannot start the runtime and
    // only churns the link).
    if (_lastWorkspaceOpenFailure is WorkspaceOpenRuntimeNotRunning) return;
    final sub = _sessionsSub;
    if (sub != null && sub.state.ready) return;
    _listEscalations += 1;
    final target =
        _activeWorkspace ?? _preferredWorkspace ?? _workspaces.firstOrNull;
    if (target == null) return;
    if (_listEscalations == 1) {
      // Soft escalation: a fresh bridge + subscribe usually recovers a
      // snapshot lost between the subscribe ack and its delivery.
      _log(
        '[session] sessions-index never became ready; reopening '
        'workspace (soft)',
      );
      unawaited(_reopenForWatchdog(target));
      return;
    }
    final scheduled = _forceRebuildAfterStall(
      'sessions-index still not ready after reopen',
    );
    if (!scheduled && !_disposed && !_kicked) {
      // Rebuild was debounced (one just ran); keep guarding until its
      // outcome lands instead of going silent forever.
      _listWatchdog = Timer(timings.listReadyTimeout, _onListNotReady);
    }
  }

  Future<void> _reopenForWatchdog(Map<String, dynamic> target) async {
    try {
      await openWorkspace(target);
    } finally {
      if (!_disposed) _armListWatchdog();
    }
  }

  /// The link wedged even though [status] may still read connected. Soft
  /// retries would queue on the same dead bridge forever (the reported
  /// "retry does nothing" symptom), so drop the whole stack and reconnect.
  /// Debounced so parallel probe failures rebuild at most once per window.
  /// Returns whether a rebuild was actually scheduled.
  bool _forceRebuildAfterStall(String reason) {
    if (_disposed || _kicked || _rebuilding) return false;
    final now = clock.now();
    if (now.difference(_lastStallRebuildAt) < timings.minRebuildInterval) {
      return false;
    }
    _lastStallRebuildAt = now;
    _rebuilding = true;
    _setConnectionStage(_deriveConnectionStage());
    _log('[session] link stalled ($reason); rebuilding connection');
    _diag('recover-start', {'failureMessage': reason});
    unawaited(() async {
      await suspend();
      _rebuilding = false;
      _setConnectionStage(_deriveConnectionStage());
      if (!_disposed && !_kicked) {
        await connect();
      }
    }());
    return true;
  }

  /// Task-list retry. Soft by design (re-runs bootstrap and re-opens the
  /// active/preferred workspace), but after repeated no-progress reloads it
  /// escalates to a full rebuild — reloading over a wedged link is the
  /// reported "retry does nothing" path.
  Future<void> reloadTasks() async {
    final client = _client;
    if (client == null || _disposed) {
      await connect();
      return;
    }
    try {
      _applyRelayOverview(await client.bootstrap());
    } catch (e) {
      _log('[session] reload bootstrap failed: $e');
      _softReloadFails += 1;
      if (_softReloadFails >= 2 &&
          _forceRebuildAfterStall('reload kept failing: $e')) {
        return;
      }
      _error = '$e';
      notifyListeners();
      return;
    }
    final target =
        _activeWorkspace ?? _preferredWorkspace ?? _workspaces.firstOrNull;
    if (target != null) {
      await openWorkspace(target);
      // Same leg decision as [connect]: bootstrap tasks win on legacy
      // links, otherwise refresh the channel overview.
      if (_bridge != null) await _refreshRelayTasksFromChannel();
    } else {
      // Nothing to open (no workspace on the desktop) — just repaint.
      notifyListeners();
    }
  }

  /// Applies a bootstrap frame's `workspaces` / `tasks` lists to the relay
  /// overview state (rows cast to `Map<String, dynamic>`). Shared by
  /// [connect], [reloadTasks] and [refreshTaskOverview]. Push frames
  /// (`workspace-list-updated`) keep their own lenient parse — a missing
  /// field there keeps the previous list, a bootstrap frame always carries
  /// both.
  void _applyRelayOverview(Map<String, dynamic> bootstrap) {
    // Live desktop version (top level of the bootstrap-response frame, not
    // inside `result`): the only real-time version source — the link's
    // `app_version` is a generation-time snapshot. Replace it every frame so
    // a reconnect to another desktop cannot keep a stale gate open.
    final desktopVersion = bootstrap['desktopAppVersion'];
    _desktopAppVersion =
        desktopVersion is String && desktopVersion.trim().isNotEmpty
            ? desktopVersion.trim()
            : null;
    final list = bootstrap['workspaces'];
    _setBootstrapWorkspaces([
      if (list is List)
        for (final w in list)
          if (w is Map) w.cast<String, dynamic>(),
    ]);
    final tasks = bootstrap['tasks'];
    if (tasks is List) {
      // Legacy overview leg (V1 links / desktops ≤3.15). An empty list is
      // authoritative here — never fall through to the channel leg and
      // resurrect rows the desktop just cleared. Legacy rows keep their own
      // `pinned` bit: the cross-workspace `listPinnedTaskIds` authority only
      // applies to the 3.16.2 channel leg (see [_mergePinnedTaskFlags]).
      _tasksFromBootstrap = true;
      _taskOverviewLanded = true;
      // Fresh overview = fresh anchor evidence (tombstone expiry,
      // single-copy reconcile, absence prune) + a sidecar re-diff.
      _taskHome.applyRelayOverview(_normalizeRelayTasks([
        for (final t in tasks)
          if (t is Map) t.cast<String, dynamic>(),
      ]));
    } else {
      // 3.16.2 dropped `tasks` from bootstrap (live-probed: key absent).
      // Keep the previous rows; the channel leg replaces them on answer.
      _tasksFromBootstrap = false;
      // The landing still re-runs the reconcile + sidecar re-diff (the
      // workspace list may have changed under the same frame).
      _taskHome.reconcileTaskHomes();
      _sidecars.reconcile();
    }
    _recordOverviewWorkspaceActivity();
  }

  /// Stores a raw wire workspace list and recomputes the merged view from
  /// whatever the resolver has loaded so far. A bootstrap frame landing
  /// after the mapping resolved (reconnects, the 30 s overview cadence)
  /// gets the completion without waiting for another read.
  ///
  /// Also the connection-initialisation trigger of the project read
  /// (10-26 D3): the wire list is the home source, and this is the first
  /// point where it is known. Every frame may fire it — the resolver's
  /// one-shot answer plus the in-flight dedup make repeat calls free.
  void _setBootstrapWorkspaces(List<Map<String, dynamic>> list) {
    _bootstrapWorkspaces = list;
    final changed = _mergeResolvedProjectWorkspaces();
    if (capabilities.projectLayer &&
        changed &&
        (_testGate != null || _bridge != null)) {
      // A merge landing through a bootstrap/push frame grows the list, but
      // not every caller re-pulls afterwards (the relay push path has no
      // pull at all, and a caller's own pull can join a round built from
      // the OLD scopes). Route every growth through the same
      // wait-out-then-redial path the late resolver answer uses (10-26
      // Bug B) so `listTaskList` scopes follow the merged list.
      unawaited(_refreshTaskScopesAfterMerge());
    }
    unawaited(_refreshProjectWorkspaces());
  }

  /// Recomputes [_workspaces] as RAW list ∪ resolver project roots
  /// (+ the synthesized `default` entry, 10-26 D2; 3.16.2 only — older
  /// desktops have no project layer, so the merged view is the raw list
  /// itself and behavior stays byte-identical). Answers whether the merged
  /// list changed.
  bool _mergeResolvedProjectWorkspaces() {
    final merged = capabilities.projectLayer
        ? mergeProjectWorkspaces(
            _bootstrapWorkspaces,
            _projectResolver.projectRoots,
            home: _projectResolver.knownHome,
          )
        : _bootstrapWorkspaces;
    if (_sameWorkspaces(_workspaces, merged)) return false;
    _workspaces = merged;
    // The ONLY workspace-list push point: both alias tables recompute here
    // (bootstrap/push, late resolver answer and suspend all land through
    // this setter or clear()).
    _taskHome.setWorkspaces(merged);
    return true;
  }

  /// Value comparison for the merge's change detection: the synthetic
  /// entries are rebuilt on every recompute, so identity is not enough.
  static bool _sameWorkspaces(
    List<Map<String, dynamic>> a,
    List<Map<String, dynamic>> b,
  ) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i];
      final y = b[i];
      if (identical(x, y)) continue;
      if (x.length != y.length) return false;
      for (final entry in x.entries) {
        if (y[entry.key] != entry.value) return false;
      }
    }
    return true;
  }

  /// Publishes a workspace-list change caused by a LATE resolver answer:
  /// notify the card lists, then re-pull the task overview so the new
  /// workspaces' rows land through the usual three legs. Awaits the
  /// refresh; callers that must not block a command fire it unawaited.
  Future<void> _applyProjectWorkspaceCompletion() async {
    if (!_mergeResolvedProjectWorkspaces() || _disposed) return;
    notifyListeners();
    await _refreshTaskScopesAfterMerge();
  }

  /// In-flight dedup of [_refreshProjectWorkspaces] (10-26 D3): the trigger
  /// now fires on every bootstrap/push frame, so overlapping calls must join
  /// one read instead of stacking. Cleared on completion (the resolver's
  /// `_resolved` one-shot is what makes repeat rounds cheap; this field only
  /// guards the concurrent window).
  Future<void>? _projectWorkspaceRefresh;

  /// Resolves (or joins) the project mapping and applies the completion.
  /// Triggered by the connection-initialisation bootstrap landing, the
  /// workspace-open prewarm and the first createSession that lands before
  /// it. Never blocks a handshake: every caller fires it unawaited.
  Future<void> _refreshProjectWorkspaces() {
    final pending = _projectWorkspaceRefresh;
    if (pending != null) return pending;
    final future = _resolveProjectWorkspaces();
    _projectWorkspaceRefresh = future;
    // Same early-completion guard as the task leg: a version-gated no-op
    // completes synchronously, and a finished Future parked in the field
    // would swallow every later retry.
    return future.whenComplete(() {
      if (identical(_projectWorkspaceRefresh, future)) {
        _projectWorkspaceRefresh = null;
      }
    });
  }

  Future<void> _resolveProjectWorkspaces() async {
    if (!capabilities.projectLayer || _disposed) return;
    final client = _client;
    // The read rides the workspace file channel; without a live link (or an
    // injected test gate) there is nothing to read yet — the next frame
    // retries, and the workspace-open prewarm stays the live trigger.
    if (client == null) return;
    try {
      await _projectResolver.mapping();
    } catch (_) {
      // The resolver's contract is "never throws"; stay defensive anyway —
      // a completion failure must not disturb the workspace open.
      return;
    }
    // The read can outlive the link: suspend() clears the workspace state
    // (session-lifecycle §2), and completing the EMPTY raw list would
    // resurrect synthetic-only workspaces after it. Same late-answer guard
    // as [refreshTaskOverview].
    if (_disposed || _client != client) return;
    await _applyProjectWorkspaceCompletion();
  }

  /// Pulls the task overview again with the completed scope list. A round
  /// already in flight was built from the OLD scopes; the channel helper's
  /// dedup would hand back that stale future, so wait it out before
  /// dialing again.
  Future<void> _refreshTaskScopesAfterMerge() async {
    final pending = _tasksRefresh;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {}
    }
    if (_disposed) return;
    await _refreshRelayTasksFromChannel();
  }

  /// Test seam: runs the project completion round exactly like the
  /// workspace-open prewarm does. The live trigger needs an open bridge,
  /// which the stub-client harness cannot provide.
  @visibleForTesting
  Future<void> debugRefreshProjectWorkspacesForTest() =>
      _refreshProjectWorkspaces();

  /// In-flight round of [refreshTaskOverview].
  Future<void>? _overviewRefresh;

  /// Start time of the last [refreshTaskOverview] round — the throttle
  /// window anchor ([overviewRefreshThrottle]).
  DateTime? _overviewRefreshStartedAt;

  /// Best-effort refresh of the relay task overview: one `client.bootstrap()`
  /// → `_workspaces`/relay rows → notify. Purpose-built for the task
  /// list page's 30s cadence (Addendum 3): a NON-active workspace's new
  /// chats only surface through this overview — the desktop's
  /// `workspace-list-updated` push stalls while its renderer is
  /// backgrounded, and connect's bootstrap reads the same stale cache.
  ///
  /// Deliberately NOT [reloadTasks]: that one re-opens the active workspace
  /// (interrupting the live sessions-index subscription) and escalates into
  /// a forced rebuild after repeated failures. This refresh is silent by
  /// design — a failure keeps the old values, counts toward nothing,
  /// rebuilds nothing, and the next cadence tick naturally retries.
  ///
  /// Two live triggers (design 11-01 §2) ride it: the createSession ack —
  /// the new row is listed ~230 ms after the ack (run8), so the 0 ms pull
  /// already sees it — and the turn terminal (status-word correction).
  ///
  /// Anti-swallow: a round already in flight was built from the OLD state
  /// (e.g. before the create landed); joining it would hand back stale rows.
  /// Same「先 await 在途，再重新发起」shape as
  /// [_refreshTaskScopesAfterMerge]. [overviewRefreshThrottle] keeps a
  /// trigger storm from stacking rounds; a call inside the window joins the
  /// round already running (or just finished).
  ///
  /// [bypassThrottle] is for the one-shot user-action triggers (design 11-01
  /// §2 create / turn terminal): they skip the window check so a cadence
  /// round cannot swallow them, but still take the anti-swallow wait and
  /// still advance the anchor (the next cadence window starts from them).
  @override
  Future<void> refreshTaskOverview({bool bypassThrottle = false}) {
    final client = _client;
    if (client == null || _disposed) return Future.value();
    final startedAt = _overviewRefreshStartedAt;
    if (!bypassThrottle &&
        startedAt != null &&
        clock.now().difference(startedAt) < overviewRefreshThrottle) {
      return _overviewRefresh ?? Future.value();
    }
    _overviewRefreshStartedAt = clock.now();
    final pending = _overviewRefresh;
    final round = () async {
      if (pending != null) {
        try {
          await pending;
        } catch (_) {}
      }
      // `_tasksRefresh` may be a leg started by the stale round (or a push
      // landing) — it would answer with the pre-create rows too.
      final pendingLeg = _tasksRefresh;
      if (pendingLeg != null) {
        try {
          await pendingLeg;
        } catch (_) {}
      }
      if (_disposed || _client != client) return;
      try {
        final bootstrap = await client.bootstrap();
        // The link may have been suspended/replaced while the RPC was in
        // flight — a late answer must not resurrect state suspend cleared.
        if (_disposed || _client != client) return;
        _applyRelayOverview(bootstrap);
        // 3.16.2: bootstrap carries no tasks — the cadence pulls the
        // `listTaskList` leg here (a legacy bootstrap leg short-circuits
        // inside the helper). Failure keeps the old rows.
        await _refreshRelayTasksFromChannel();
        if (_disposed || _client != client) return;
        _recordOverviewWorkspaceActivity();
        notifyListeners();
      } catch (e) {
        _log('[session] overview refresh failed (kept old values): $e');
      }
    }();
    _overviewRefresh = round;
    // Clear only our own entry: a suspended link nulls the field, and the
    // old round must not wipe the new connection's round.
    unawaited(round.whenComplete(() {
      if (identical(_overviewRefresh, round)) _overviewRefresh = null;
    }));
    return round;
  }

  /// Records the overview's per-workspace activity keys (design 11-01 §4).
  /// Reads the merged directory — the same projection the card order uses,
  /// so the persisted key is exactly what a live build would show for the
  /// current rows.
  void _recordOverviewWorkspaceActivity() {
    if (_disposed) return;
    final newest = <String, int>{};
    for (final (entry, key) in _taskHome.directory.allEntries()) {
      if (key == null) continue;
      final at = entry.lastActivityAt;
      final previous = newest[key];
      if (previous == null || at > previous) newest[key] = at;
    }
    for (final MapEntry(key: key, value: at) in newest.entries) {
      _activityStore.record(key, at);
    }
  }

  /// Records the live indexes' per-workspace activity keys (design 11-01
  /// §4) without materializing the directory: the active index and every
  /// sidecar layer carry their subscribed workspace key and their rows'
  /// `lastActivityAt` directly.
  void _recordLiveWorkspaceActivity() {
    if (_disposed) return;
    void recordIndex(SessionsIndexState? state) {
      if (state == null || !state.ready) return;
      final key = state.subscribedWorkspaceKey;
      if (key == null || key.isEmpty) return;
      int? newest;
      for (final entry in state.list) {
        if (newest == null || entry.lastActivityAt > newest) {
          newest = entry.lastActivityAt;
        }
      }
      if (newest != null) {
        _activityStore.record(_taskHome.normalizeKey(key), newest);
      }
    }

    recordIndex(sessions);
    for (final state in _sidecars.indexes.values) {
      recordIndex(state);
    }
  }

  Future<void> stopTask(String sessionId) async {
    final conv = _conversation;
    if (conv == null) throw StateError('not connected');
    await conv.stop(sessionId);
  }

  Future<void> pauseTask(String sessionId) async {
    final conv = _conversation;
    if (conv == null) throw StateError('not connected');
    await conv.pauseGoal(sessionId);
  }

  Future<void> resumeTask(String sessionId) async {
    final conv = _conversation;
    if (conv == null) throw StateError('not connected');
    await conv.resumeGoal(sessionId);
  }

  /// Raw channel RPC over the active workspace bridge (usage-stats,
  /// model-provider, automations, off-peak...). Throws when no bridge is
  /// open.
  ///
  /// Failure tiers: the bridge-level waitHealthy expiry escalates
  /// immediately ([LinkSupervisor.noteGateTimeout]); channel-level failures
  /// (the desktop's `Channel name … timed out` answer, or the RPC timing
  /// out) feed the per-channel tri-strike ledger on [LinkSupervisor].
  Future<dynamic> callChannel(
    String channel,
    String method, [
    List<Object?> args = const [],
  ]) async {
    final gate = _testGate ?? _liveGate();
    if (gate == null) throw StateError('not connected');
    try {
      await gate.waitHealthy(timeout: timings.healthyWaitTimeout);
    } on TimeoutException {
      _linkSupervisor.noteGateTimeout(
        'workspace bridge unhealthy > ${timings.healthyWaitTimeout.inSeconds}s',
      );
      rethrow;
    }
    try {
      final result =
          await gate.call(channel, method, args).timeout(timings.rpcTimeout);
      // Any success proves the channel rides a live bridge again.
      _linkSupervisor.noteChannelSuccess(channel);
      return result;
    } on TimeoutException {
      _linkSupervisor.noteChannelLevelFailure(
          channel, '$channel.$method timed out');
      rethrow;
    } catch (e) {
      // Only the desktop's channel-missing shape is channel-level; other
      // RPC errors (method not found, bad args) are deterministic answers
      // and never imply a stalled link.
      if (isChannelMissingError(e)) {
        _linkSupervisor.noteChannelLevelFailure(
            channel, 'channel $channel unavailable: $e');
      }
      rethrow;
    }
  }

  /// Transport-side report of the chat send paths
  /// ([ConversationTransport.sendCommand] / its replayable wire call),
  /// feeding the SAME ledger [callChannel] uses. Tier classification
  /// mirrors callChannel by error shape: the bridge-health gate expiring
  /// escalates immediately ([LinkSupervisor.noteGateTimeout]); RPC timeouts
  /// and channel-missing answers count toward the per-channel tri-strike.
  void _onTransportLinkLevelFailure(String channel, Object error) {
    if (isBridgeGateTimeoutError(error)) {
      _linkSupervisor.noteGateTimeout('conversation bridge gate expired: $error');
      return;
    }
    _linkSupervisor.noteChannelLevelFailure(channel, '$error');
  }

  void _onTransportChannelSuccess(String channel) {
    _linkSupervisor.noteChannelSuccess(channel);
  }

  /// Managed channel-event listen — the controlled alternative to reaching
  /// for [bridge] directly: subscribes [handler] to [event] on the active
  /// workspace bridge and re-attaches automatically after every bridge
  /// rebuild (a raw `bridge.channels.addEventListener` attach dies with its
  /// bridge and would strand the listener). With no bridge open the
  /// registration idles until the next rebuild. Returns the cancel
  /// function.
  ///
  /// Never throws: like the chat-port fallbacks, a listener is an
  /// enhancement — attach and cancel failures stay silent and the page
  /// keeps working off its initial load.
  VoidCallback listenChannel(
    String channel,
    String event,
    void Function(dynamic) handler,
  ) {
    final entry = _ManagedChannelListener(channel, event, handler);
    _channelListeners.add(entry);
    entry.attachTo(_bridge);
    return () {
      _channelListeners.remove(entry);
      entry.detach();
    };
  }

  /// Bridge (re)build hook: drops the stale wire attaches and re-hangs
  /// every registration on the fresh bridge. Attach failures are silent —
  /// a listener that cannot attach must not break the workspace open.
  void _reattachChannelListeners() {
    for (final entry in _channelListeners) {
      entry.detach();
      entry.attachTo(_bridge);
    }
  }

  // --- model-provider capability gate (removed in desktop 3.12.3) ---
  /// Cached probe verdict: null = not probed yet, true = the desktop still
  /// serves the `model-provider` channel, false = removed. Cached for the
  /// whole session lifetime — a channel does not come back mid-session.
  bool? _modelProviderAvailable;

  /// In-flight dedup for [probeModelProvider].
  Future<bool>? _modelProviderProbe;

  /// Current knowledge about the `model-provider` channel; null until the
  /// first probe landed. Callers treat unknown as available — the providers
  /// page carries its own channel-unavailable fallback for that case.
  bool? get modelProviderAvailable => _modelProviderAvailable;

  /// One lightweight `model-provider.getAll` capability probe, deduplicated
  /// while in flight; both verdicts are cached for the session lifetime.
  /// Channel-level failures (the desktop's `Channel name … timed out`
  /// answer or an RPC timeout — [isChannelLevelError], no new heuristics)
  /// mean the channel is gone; any other error proves nothing about the
  /// channel and stays uncached so the next trigger re-runs the probe.
  Future<bool> probeModelProvider() {
    final cached = _modelProviderAvailable;
    if (cached != null) return Future.value(cached);
    return _modelProviderProbe ??= _probeModelProvider();
  }

  Future<bool> _probeModelProvider() async {
    try {
      await callChannel(Channels.modelProvider, 'getAll');
      return _modelProviderAvailable = true;
    } catch (e) {
      if (!isChannelLevelError(e)) return true;
      return _modelProviderAvailable = false;
    } finally {
      _modelProviderProbe = null;
    }
  }

  /// In-flight/cached [WorkspaceContextPort.modelProviderCatalog] future.
  Future<List<Map<String, dynamic>>>? _modelProviderCatalogFuture;

  @override
  Future<List<Map<String, dynamic>>> modelProviderCatalog() {
    return _modelProviderCatalogFuture ??= () async {
      try {
        // Desktop ≥3.14 removed model-provider outright; the read-only
        // model-selection.getView registry (same catalog shape via
        // parseModelSelectionCatalog) takes over as the sheet's data
        // source. CRUD (save/delete) has no counterpart — the providers
        // page stays capability-gated on [probeModelProvider].
        if (capabilities.modelSelectionCatalog) {
          return parseModelSelectionCatalog(
              await callChannel(Channels.modelSelection, 'getView'));
        }
        final res = await callChannel(Channels.modelProvider, 'getAll');
        return [
          for (final p in (res is List ? res : const <dynamic>[]))
            if (p is Map && p['enabled'] != false)
              Map<String, dynamic>.from(p),
        ];
      } catch (e) {
        // Transport/channel failure proves nothing about the catalog —
        // stay uncached so the next open retries (probeModelProvider's
        // uncached-error branch).
        _modelProviderCatalogFuture = null;
        return const <Map<String, dynamic>>[];
      }
    }();
  }

  WorkspaceGate? _liveGate() {
    final bridge = _bridge;
    return bridge == null ? null : _LiveWorkspaceGate(bridge);
  }

  /// Test-only: route every channel RPC through [gate].
  @visibleForTesting
  void debugAttachGateForTest(WorkspaceGate gate) => _testGate = gate;

  /// Test seam: the persisted anchor/tombstone store — anchor tests seed
  /// homes / assert the persisted sets directly through it (FakeDeviceSession
  /// inherits the seam).
  @visibleForTesting
  TaskHomeStore get taskHomeStore => _homeStore;

  /// Test seam: the persisted workspace-activity store (design 11-01 §4).
  @visibleForTesting
  WorkspaceActivityStore get workspaceActivityStore => _activityStore;

  /// Persisted last-activity epoch ms of one workspace — the task list's
  /// idle-tier fallback while the workspace's live rows are still loading
  /// (design 11-01 §4). Null when never recorded.
  int? persistedWorkspaceActivity(String workspaceKey) =>
      _activityStore.activityOf(workspaceKey);

  /// Per-workspace sidecar readiness for the task-list card skeleton
  /// (design 11-01 §3): absent key = no sidecar subscription (relay rows are
  /// the whole truth); `false` = subscribed but the first snapshot has not
  /// landed; `true` = the live layer is in.
  Map<String, bool> get sidecarReadiness => _sidecars.readinessByWorkspace;

  /// Whether the relay task overview has landed at least once since this
  /// connection was established. False during the cold-start window between
  /// the bootstrap workspaces and the first successful task pull — a
  /// non-active card is then "not loaded yet", not "no tasks".
  @override
  bool get taskOverviewLoaded => _taskOverviewLanded;

  /// Server-side automations of the connected desktop. Bound to the
  /// zcode-agent channel (listAllAutomations was probed there). The wire
  /// shape (scheduleRule/modelSelection/setAutomationEnabled) is gated on
  /// the desktop version — it cannot change mid-session.
  @override
  late final AutomationPort automation = AutomationPort(
    (method, args) => callChannel('zcode-agent', method, args),
    newWire: capabilities.scopeFirstWire,
  );

  /// Off-peak tasks of the connected desktop (off-peak-task channel). The
  /// wire (lifecycle positional args, positional updateTask) and the status
  /// family (3.14 take-a-number probes) are gated on the desktop version —
  /// it cannot change mid-session.
  @override
  late final OffPeakPort offPeak = OffPeakPort(
    (method, args) => callChannel('off-peak-task', method, args),
    newWire: capabilities.scopeFirstWire,
    statusV314: capabilities.offPeakStatusProbes,
  );

  /// Workspace scope (workspacePath/identity) for off-peak submissions and
  /// automation run-now triggers.
  @override
  Map<String, dynamic> get offPeakScope {
    final ws = _activeWorkspace ?? const <String, dynamic>{};
    return {
      'workspacePath': ws['workspacePath'],
      if (ws['workspaceIdentity'] != null)
        'workspaceIdentity': ws['workspaceIdentity'],
    };
  }

  @override
  Map<String, dynamic> get automationScope => offPeakScope;

  /// mobile-view-state-update for the ACTIVE workspace (the
  /// phone reports which workspace/task it is looking at; the desktop shows
  /// the「手机正在操作此任务」badge from it). Fire-and-forget; safe to call
  /// on every navigation.
  @override
  void sendViewState({String? taskId}) {
    final ws = _activeWorkspace;
    final client = _client;
    final key = ws == null ? null : workspaceKeyOf(ws);
    if (client == null || key == null) return;
    unawaited(client.sendMobileViewState(workspaceKey: key, taskId: taskId));
  }

  /// Minimal automation primitive: creates a new task (session) on the
  /// active workspace with [text] as the first message. [config] rides
  /// createSession's `config` payload (new-task defaults / scheduled-send
  /// overrides, assembled by sanitizeNewTaskConfig). Returns the new
  /// sessionId.
  Future<String> createTaskWithMessage(
    String text, {
    Map<String, dynamic>? config,
  }) async {
    final conv = _conversation;
    if (conv == null) throw StateError('not connected');
    final workspaceId = chatWorkspaceId;
    if (workspaceId == null || workspaceId.isEmpty) {
      throw StateError('no workspace');
    }
    final id = await conv.createSession(
      workspaceId,
      firstText: text,
      config: config,
    );
    // 写入源①（design 10-15 §1.1）：手机端创建会话 = App 即真值源，成功
    // 即锚定到活动工作区 —— 注册表行落地前（甚至被镜像污染前）home 已定。
    // The service canonicalizes the key (conversation workspaces anchor at
    // their DISPLAY group key, spec §3.8).
    final ws = _activeWorkspace;
    _taskHome.anchorCreatedTask(id, ws == null ? null : workspaceKeyOf(ws));
    return id;
  }

  // -------------------------------------------------------- ConversationPort

  ConversationTransport get _requireConversation {
    final conv = _conversation;
    if (conv == null) throw StateError('not connected');
    return conv;
  }

  /// Conversation V4 command surface (ConversationPort): the live transport of
  /// the active workspace, narrowed to [ConversationCommands]. Commands go
  /// straight to it — no per-command forwarding — while lifecycle
  /// (subscribe/prepare/skills) and state reading stay on the session below.
  @override
  ConversationCommands get conversationCommands => _requireConversation;

  /// Offline replayable-command queue (ConversationPort), version-gated the
  /// same way as the automation/off-peak wire gates above: pre-3.12.3
  /// desktops have no enqueueTaskCommand, so send failures surface as
  /// before instead of being queued.
  @override
  ReplayableCommandQueue? get replayableQueue {
    if (!capabilities.replayableQueue) return null;
    return _conversation?.replayableQueue;
  }

  @override
  String? get chatWorkspaceId {
    final fromIndex = sessions?.workspaceId;
    if (fromIndex != null && fromIndex.isNotEmpty) return fromIndex;
    final ws = _activeWorkspace;
    if (ws == null) return null;
    return '${ws['workspaceId'] ?? workspaceKeyOf(ws)}';
  }

  @override
  String? get workspacePath => _activeWorkspace?['workspacePath'] as String?;

  @override
  Future<WorkspaceOpenResult> ensureDraftWorkspace(String? workspacePath) async {
    final target = workspacePath;
    if (target == null || target.isEmpty) return const WorkspaceOpenOpened();
    String norm(String key) => _taskHome.normalizeKey(key);
    final wanted = norm(target);
    final active = _activeWorkspace;
    if (active != null) {
      final activePath = active['workspacePath'];
      if (activePath is String && norm(activePath) == wanted) {
        return const WorkspaceOpenOpened();
      }
      final activeKey = workspaceKeyOf(active);
      if (activeKey != null && norm(activeKey) == wanted) {
        return const WorkspaceOpenOpened();
      }
    }
    Map<String, dynamic>? row;
    for (final ws in _workspaces) {
      final path = ws['workspacePath'];
      final key = workspaceKeyOf(ws);
      if (path == target || key == target) {
        row = ws;
        break;
      }
    }
    if (row == null) {
      // Conversation-group siblings (default + draft-*) normalize together;
      // the exact-row pass above must win so the session lands in the
      // target directory, not whichever sibling lists first.
      for (final ws in _workspaces) {
        final path = ws['workspacePath'];
        final key = workspaceKeyOf(ws);
        if ((path is String && norm(path) == wanted) ||
            (key != null && norm(key) == wanted)) {
          row = ws;
          break;
        }
      }
    }
    _log('[session] draft target drifted from the bridge workspace; '
        're-opening $target');
    return openWorkspace(
      row ?? {'workspacePath': target},
      purpose: WorkspaceOpenPurpose.chatNew,
    );
  }

  @override
  String? get remoteUrl => params.source.toString();

  /// Task metadata commands on the zcode-task channel (method names
  /// source-confirmed; probe kept as a safety net — see [TaskCommandsPort]).
  late final TaskCommandsPort taskCommands = TaskCommandsPort(
    (method, args) => callChannel('zcode-task', method, args),
    scope: _taskHome.taskScopeFor,
  );

  /// Archived-task permanent deletion on the window-controller channel
  /// (desktop ≥3.18.0 — see [WindowControllerPort]).
  late final WindowControllerPort windowController = WindowControllerPort(
    (channel, method, args) => callChannel(channel, method, args),
    scope: _taskHome.taskScopeFor,
  );

  /// Whether the desktop serves the archived-deletion pair. Positive
  /// boolean: true until an unknown-method reply pins it false for the rest
  /// of the session (a desktop never changes version mid-session). Only the
  /// exact `Method not found:` + method-name wording flips it — see
  /// [isArchivalDeletionMethodMissing].
  bool _windowControllerAvailable = true;

  /// Session-lifetime degrade verdict for the archived-deletion pair (for
  /// tests / diagnostics).
  bool get windowControllerAvailable => _windowControllerAvailable;

  /// One preview for ONE task. Deliberately NOT deduplicated in flight: the
  /// answer carries the task's own revision, so a shared future would feed
  /// task A's revision to task B's execute — deleting the wrong session
  /// (design §2 P1-1). Concurrent callers each issue their own RPC.
  Future<ArchivalDeletionPreview> previewArchiveDeletion(String taskId) async {
    if (!_windowControllerAvailable) {
      throw const ArchivalPreviewUnavailable();
    }
    try {
      return await windowController.previewArchivedDeletion(taskId);
    } on ArchivalPreviewUnavailable catch (e) {
      _windowControllerAvailable = false;
      throw ArchivalPreviewUnavailable(e.message);
    }
  }

  /// Executes the permanent delete with [preview]'s revision; the
  /// operationId is generated here (the desktop only uses it for its own
  /// idempotent retries — ZGo never retries automatically).
  ///
  /// Tombstones every id the desktop reports as deleted (`status ==
  /// "deleted"` only; blocked/incomplete remove nothing) so the 30 s
  /// overview poll cannot resurrect the rows, then notifies once.
  Future<ArchivalDeletionResult> executeArchiveDeletion(
    ArchivalDeletionPreview preview,
    String taskId,
  ) async {
    if (!_windowControllerAvailable) {
      throw const ArchivalPreviewUnavailable();
    }
    final ArchivalDeletionResult res;
    try {
      res = await windowController.permanentlyDeleteArchived(
        taskId,
        revision: preview.revision,
        operationId: generateUuid(),
      );
    } on ArchivalPreviewUnavailable catch (e) {
      _windowControllerAvailable = false;
      throw ArchivalPreviewUnavailable(e.message);
    }
    if (res.status == 'deleted') {
      for (final id in res.sessionIds) {
        _taskHome.rememberLocalDelete(id);
      }
      notifyListeners();
    }
    return res;
  }

  /// The relay home row of [taskId] as the merged directory shows it —
  /// [TaskHomeService.relayHomeRowOf] (design 10-16 multi-copy-home-
  /// correction: the home-correction dialog's default selection and its
  /// 「当前显示」marker).
  Map<String, dynamic>? relayHomeRowOf(String taskId) =>
      _taskHome.relayHomeRowOf(taskId);

  /// User home adjudication (anchor write source ④, design 10-16
  /// multi-copy-home-correction): the user picks the TRUE home copy among
  /// a multi-copy id's rows. The service writes the anchor canonicalized
  /// through its key aliases (same spelling rule as every other anchor
  /// source), then optionally deletes every OTHER registry copy with its
  /// OWN per-copy scope (the desktop's resolveTaskAddress matches the
  /// taskId+scope triple — the merged scope would address the true row,
  /// not the mirror). NO local tombstone: tombstones are per-id and would
  /// hide the true row too. The anti-pollution gate is untouched — it
  /// governs AUTOMATIC live-frame writes; an explicit user write is the
  /// adjudication the gate defers to (multi-copy live frames keep
  /// refreshing an agreeing anchor only).
  Future<void> correctTaskHome(
    String taskId,
    Map<String, dynamic> homeCopy, {
    bool deleteOtherCopies = false,
  }) =>
      _taskHome.adjudicate(
        taskId,
        homeCopy,
        deleteOtherCopies: deleteOtherCopies,
      );

  /// Workspace file reads on the `file` channel (the desktop's fileService —
  /// the markdown-image / HTML-preview data source). Late final like the
  /// ports above; dispose needs no action. Exposed as
  /// [WorkspaceContextPort.fileService] (ADR-0008 rule i); the legacy
  /// per-method forwards below are coexistence-only.
  @override
  late final FileServicePort fileService = FileServicePort(
    (method, args) => callChannel(Channels.file, method, args),
  );

  /// 3.16.2 project attribution (design 10-21 Part 2): learns the desktop's
  /// `rootPath → projectId` map — and its project list, which completes the
  /// workspace list (research/07) — from its own `tasks-index.sqlite` over
  /// the file channel, so `createSession` can carry the outer `projectId`
  /// the desktop's `reserveCreatedTask` expects. Prewarmed fire-and-forget
  /// after a workspace opens (the read is a handful of pages, acceptance
  /// round 1); transient failures retry on the next creation, every failure
  /// degrades to null (the old NULL-project payload), never to an error.
  late final ProjectResolver _projectResolver =
      projectResolverFactory?.call(() => _bootstrapWorkspaces) ??
          ProjectResolver(
            // RAW list, never the merged view: see [_bootstrapWorkspaces].
            workspaces: () => _bootstrapWorkspaces,
            readRange: _readProjectIndexRange,
            onLog: _log,
            loadCachedHome: loadCachedHome,
            saveCachedHome: saveCachedHome,
          );

  /// The seam's failure contract: a channel error/timeout THROWS (the
  /// resolver retries it on the next creation); a successful read answers
  /// whatever bytes the desktop returned, possibly empty/short at EOF.
  Future<Uint8List> _readProjectIndexRange(
    String path,
    int offset,
    int length,
  ) async {
    final ws = _activeWorkspace?['workspacePath'];
    final range = await fileService.readFileRange(
      ws is String ? ws : path,
      path,
      offset: offset,
      length: length,
    );
    return range.bytes;
  }

  /// 3.17.1 task groups (task-group-resolver, 10-30): the desktop removed
  /// its grouped-task RPC and its renderer now derives groups from the
  /// `task_group_*` tables in the same `tasks-index.sqlite`
  /// [ProjectResolver] reads. One home source (the project resolver's wire
  /// first / cached fallback) and the same row-range seam; built at the
  /// same time as the project resolver (connection lifetime) with a 30 s
  /// answer cache inside.
  late final TaskGroupResolver _taskGroupResolver =
      taskGroupResolverFactory?.call(() => _projectResolver.knownHome) ??
          TaskGroupResolver(
            homeOf: () => _projectResolver.knownHome,
            readRange: _readProjectIndexRange,
            onLog: _log,
          );

  /// `createSession`'s project id — the transport consults it only there.
  /// Explicit 3.16.2 gate (design decision 1): older desktops have no
  /// project layer, so nothing is read and the payload stays unchanged.
  ///
  /// A create can be the FIRST resolver consumer (no workspace opened, so
  /// the prewarm never ran): the mapping that just landed also completes
  /// the workspace list, fired without blocking the create.
  Future<String?> _projectIdForCreate(String workspacePath) async {
    if (!capabilities.projectCreateAddressing) return null;
    final projectId = await _projectResolver.projectIdFor(workspacePath);
    if (!_disposed) unawaited(_applyProjectWorkspaceCompletion());
    return projectId;
  }

  /// Test seam for the create-session project gate: the production path is
  /// [ConversationTransport.createSession]'s `projectIdFor` callback, which
  /// cannot be observed without a live transport.
  @visibleForTesting
  Future<String?> debugProjectIdForCreate(String workspacePath) =>
      _projectIdForCreate(workspacePath);

  /// Workspace Git operations on the `git` channel (status-panel Git group,
  /// review panel, branch/commit/push writes). Late final like the ports
  /// above; written calls go through the caller's confirmation dialogs.
  @override
  late final GitPort git = GitPort(
    (method, args) => callChannel(Channels.git, method, args),
  );

  @override
  Future<dynamic> renameTask(String sessionId, String title) async {
    final res = await taskCommands.rename(sessionId, title);
    // V4 双写（官方 renameTask 语义，10-08 static-forensics R2）：task-index
    // 写成功后补发 V4 renameSession；V4 失败静默——官方同样只 warn「保留
    // task-index 标题」，不回滚不误报。桥未开（任务列表冷重命名）时
    // [conversationCommands] 直接 throw → 同样被吞；task-index 标题本就是
    // 权威，偏差可接受（官方 task service 恒双写，受 remote 通道形态所限）。
    try {
      await conversationCommands.renameSession(sessionId, title);
    } catch (e) {
      debugPrint('[session] renameSession dual-write failed: $e');
    }
    return res;
  }

  @override
  Future<dynamic> taskNativeSessionLogFile(String sessionId) =>
      taskCommands.nativeSessionLogFile(sessionId);

  @override
  Future<dynamic> setTaskPinned(String sessionId, bool pinned) =>
      taskCommands.setPinned(sessionId, pinned);

  @override
  Future<dynamic> setTaskArchived(String sessionId, bool archived) =>
      taskCommands.setArchived(sessionId, archived);

  @override
  Future<dynamic> setTaskUnread(String sessionId, bool unread) =>
      taskCommands.setUnread(sessionId, unread);

  @override
  Future<dynamic> deleteTask(String sessionId) async {
    final res = await taskCommands.delete(sessionId);
    // Explicit success only (the await above threw on timeout / error):
    // tombstone the row and re-notify so the merged directory recomputes
    // even when the desktop's workspace-list-updated push was swallowed
    // by a bridge reopen (design 10-02 Step 3).
    _taskHome.rememberLocalDelete(sessionId);
    notifyListeners();
    return res;
  }

  @override
  void anchorCreatedTask(String sessionId, String? workspacePathOrKey) {
    // The service canonicalizes the key (conversation workspaces anchor at
    // their DISPLAY group key, spec §3.8) — the port takes whatever the
    // caller knows (the active workspace's path), never a draft page's
    // captured path.
    _taskHome.anchorCreatedTask(sessionId, workspacePathOrKey);
  }

  /// Deletes ONE archived row (`zcode-task.deleteArchivedTask`, desktop
  /// 3.17.1 — archive view row delete, gated by
  /// `capabilities.archivedDelete`). Returns the desktop's answer verbatim:
  /// null means skipped (row no longer archived / already gone) — no
  /// tombstone in that case, nothing was deleted. On a non-null answer the
  /// row is tombstoned so the 30s poll window cannot resurrect it (same
  /// discipline as [deleteTask]).
  Future<dynamic> deleteArchived(String sessionId) async {
    final res = await taskCommands.deleteArchived(sessionId);
    if (res != null) {
      _taskHome.rememberLocalDelete(sessionId);
      notifyListeners();
    }
    return res;
  }

  /// Clears one workspace group's archived rows (`deleteArchivedTasks`,
  /// desktop 3.17.1 — 归档视图「清空」, gated by
  /// `capabilities.archivedDelete`). [scope] is the group's own workspace
  /// scope; `taskIds` must all belong to it. Returns the desktop's
  /// `{deletedTaskIds, skippedTaskIds, failedTaskIds}` verbatim — every
  /// deleted id is tombstoned, skipped/failed rows stay put for the user
  /// to see on the next render.
  Future<dynamic> deleteArchivedAll(
    List<String> taskIds, {
    required Map<String, dynamic> scope,
  }) async {
    final res = await taskCommands.deleteArchivedBatch(taskIds, scope: scope);
    final deleted = res is Map ? res['deletedTaskIds'] : null;
    if (deleted is List && deleted.isNotEmpty) {
      for (final id in deleted) {
        if (id is String) _taskHome.rememberLocalDelete(id);
      }
      notifyListeners();
    }
    return res;
  }

  /// Deletes a session through the V4 conversation command (`deleteSession`,
  /// addressed by sessionId — no task-registry resolve). C1 (10-05): fork
  /// drafts are parked outside the registry (createZCodeDeferredDraftRegistry,
  /// research.md R2), so [deleteTask] can never resolve them — the session
  /// command is the only deletion channel (device-verified against a
  /// deferred draft, research-emulator.md A-2), and a registry delete that
  /// resolves zero rows falls back to it. Deliberately a session-level
  /// wrapper, not a page call through [conversationCommands]: the tombstone
  /// + re-notify below are session-owned state, and a successful delete must
  /// drop the row from the merged directory at once — the sessions-index
  /// `session.removed` push can be swallowed by a bridge reopen (same
  /// resurrection paths [deleteTask]'s tombstone covers). Callers confirm
  /// first.
  Future<dynamic> deleteSession(String sessionId) async {
    final res = await conversationCommands.deleteSession(sessionId);
    _taskHome.rememberLocalDelete(sessionId);
    notifyListeners();
    return res;
  }

  /// Side-chat tabs of [parent] in ordinal order (the tab bar's order).
  /// Read-only view; the page renders it and never mutates the registry
  /// directly.
  @override
  List<SideChatTab> sideChatTabs(String parent) => _sideChats.tabsOf(parent);

  /// The persisted tab manifest (device + workspace keyed). Test seam.
  @visibleForTesting
  SideChatTabStore get sideChatTabStore => _sideChatTabStore;

  /// Registers a freshly created side chat under [parent] and persists it
  /// (creation path, R8). Returns the tab (ordinal assigned here); an id
  /// that is already known answers the existing tab and touches nothing.
  SideChatTab registerSideChatTab(String parent, String sessionId) {
    final tab = _sideChats.register(parent, sessionId);
    final scope = _sideChatScope(parent);
    if (scope != null) _sideChatTabStore.put(scope.key, parent, tab);
    return tab;
  }

  /// Drops the record of [sessionId] (close path, R4): page-level removal
  /// only. The desktop runtime is stopped by the caller and the manifest
  /// entry deliberately survives — close means restorable collapse, so the
  /// next page entry rebuilds the tab (R8).
  void closeSideChatTabRecord(String parent, String sessionId) {
    _sideChats.close(parent, sessionId);
  }

  /// Drops the record of [sessionId] (destroy path, R9) AND its manifest
  /// entry — the session is soft-deleted, so no restore may ever rebuild it.
  void destroySideChatTabRecord(String parent, String sessionId) {
    _sideChats.destroy(parent, sessionId);
    final scope = _sideChatScope(parent);
    if (scope != null) {
      _sideChatTabStore.remove(scope.key, parent, sessionId);
    }
  }

  /// Closes the tab (R4/AC5, [SideChatPort.closeSideChatTab]): stops the
  /// desktop runtime through the channel, tears the local subscription down
  /// and removes the record. The manifest entry survives — close is a
  /// restorable collapse (R8).
  ///
  /// Fault tolerance (design §6): `-32004` / sessionNotFound answer success
  /// (nothing left to close, exactly the official web remote's reading); any
  /// other failure still completes the local teardown — losing the tab beats
  /// a stuck one — and only logs.
  @override
  Future<void> closeSideChatTab(String parent, String sessionId) async {
    if (_disposed) return;
    final scope = _sideChatScope(parent);
    if (scope != null) {
      try {
        await _closeSideChatRuntime(scope.owner, sessionId);
      } catch (e) {
        if (!_isSideChatSessionGone(e)) {
          _log('[side-chat] closeSession $sessionId degraded to local '
              'teardown: $e');
        }
      }
    }
    if (_disposed) return;
    await _releaseSideChatSubscription(sessionId);
    closeSideChatTabRecord(parent, sessionId);
    if (!_disposed) notifyListeners();
  }

  /// Destroys the tab (R9/AC10, [SideChatPort.destroySideChatTab]): soft
  /// deletes the session through [deleteSession] (keeping its local
  /// tombstone), tears the subscription down and prunes the manifest entry —
  /// no restore can ever rebuild it.
  ///
  /// Idempotent by wire shape, not by exception (verified 2026-11-13,
  /// research/wire-recheck.md C): the host answers a delete of an already
  /// soft-deleted or missing id with a *failed ack*
  /// (`reasonCode: fault.command.queryUnavailable`), not a throw, so
  /// [deleteSession] records the tombstone and this teardown proceeds
  /// exactly like a first-time delete. The catch below therefore only sees
  /// transport/encode faults (a non-gone failure rethrows with the tab
  /// untouched so the user may retry); its gone-marker branch is defensive
  /// and not reachable on today's wire.
  @override
  Future<void> destroySideChatTab(String parent, String sessionId) async {
    if (_disposed) return;
    try {
      await deleteSession(sessionId);
    } catch (e) {
      if (!_isSideChatSessionGone(e)) rethrow;
      // deleteSession threw before its own tombstone step; the row must not
      // resurrect on the next directory rebuild.
      _taskHome.rememberLocalDelete(sessionId);
    }
    if (_disposed) return;
    await _releaseSideChatSubscription(sessionId);
    destroySideChatTabRecord(parent, sessionId);
    if (!_disposed) notifyListeners();
  }

  /// Creates a side chat attached to [parent] (R6/R2,
  /// [SideChatPort.createSideChatTab]): the V4 ack names the new session, its
  /// tab is registered (and persisted) here, and the tab answers so the page
  /// can switch to it immediately. [firstInput] is sent as the side chat's
  /// first message when non-blank (the transport trims and omits a blank
  /// one); a rejected create throws with nothing registered.
  @override
  Future<SideChatTab> createSideChatTab(
    String parent, {
    String? firstInput,
  }) async {
    if (_disposed) throw StateError('disposed');
    final sessionId = await conversationCommands.createSelectionSideSession(
      parent,
      firstText: firstInput,
    );
    final tab = registerSideChatTab(parent, sessionId);
    if (!_disposed) notifyListeners();
    return tab;
  }

  /// Thin `zcode-session.closeSession` wrapper (design §6 / D3, M0-d):
  /// [workspacePath] is mandatory — the host routes the agent process by
  /// `workspaceIdentity?.trim() || workspacePath`; with both absent the call
  /// dies before any session RPC at the sqlite bind (`TypeError
  /// [ERR_INVALID_ARG_TYPE]`, verified 2026-11-13 research/wire-recheck.md
  /// A), and a non-empty identity alone can short-circuit onto a wrong/left-
  /// over process. [workspaceIdentity] joins only when non-empty (the same
  /// shape A1's listSessions check uses).
  /// `expectedPersistence` is NEVER sent: a value that differs from the
  /// runtime's mode answers `closed:false` without closing, while omitting
  /// it always closes. The host wrapper swallows the answer ("then(()=>{})"),
  /// so `closed` is unobservable here — callers read success/throw only.
  Future<void> _closeSideChatRuntime(
    Map<String, dynamic> owner,
    String sessionId,
  ) async {
    final path = owner['workspacePath'];
    if (path is! String || path.isEmpty) {
      throw StateError('closeSession: no workspacePath for $sessionId');
    }
    final identity = owner['workspaceIdentity'];
    await callChannel(Channels.zcodeSession, 'closeSession', [
      {
        'workspacePath': path,
        if (identity is String && identity.isNotEmpty)
          'workspaceIdentity': identity,
        'sessionId': sessionId,
      },
    ]);
  }

  /// Drops [sessionId]'s live subscription from this session (close/destroy).
  /// The tab is the side chat's only reader, so whatever subscription is
  /// currently registered is the one to drop; a page handle closing later
  /// sees its subscription gone and stops there (its own close is
  /// identity-guarded in [_handleFor]). The viewer's handle keeps
  /// `isRevoked` false on purpose — this is not the host revoke (workspace
  /// switch / suspend), it is the tab's own teardown.
  Future<void> _releaseSideChatSubscription(String sessionId) async {
    final sub = _chatSubs.remove(sessionId);
    final terminal = _chatTerminalSubs.remove(sessionId);
    if (sub == null && terminal == null) return;
    await terminal?.cancel();
    await sub?.dispose();
  }

  /// The desktop's "nothing there" answers of the side-chat close/destroy
  /// paths, treated as idempotent success (research close-delete-wire.md):
  /// the channel `-32004` code (number, always — its `Session is not active`
  /// / `Session runtime is not ready` wordings both carry it, verified
  /// 2026-11-13 research/wire-recheck.md B) and the sessionNotFound family.
  /// Deliberately strict on the bare phrase: unlike the subscribe path, a
  /// wording without the code is NOT proof of "already gone" here (the
  /// subscribe-side bare phrase itself ships a ` (fault.subscribe.
  /// sessionNotFound)` suffix), and the destroy path must never prune the
  /// manifest on an unverified answer.
  bool _isSideChatSessionGone(Object error) {
    if (isSessionNotFoundError(error)) return true;
    if (isSessionNotFoundText('$error')) return true;
    if (error is ChannelRpcError) {
      final data = error.data;
      if (data is Map) {
        final code = data['code'];
        if (code == -32004 || code == '-32004') return true;
      }
      if (error.message.contains('-32004')) return true;
    }
    return false;
  }

  /// Manifest scope of [parent]: the owning workspace map (the same one the
  /// open paths resolve — directory ownership, falling back to the ACTIVE
  /// workspace, which is the page's own scope; a conversation-workspace
  /// parent has no directory row and must not lose its manifest) plus the
  /// normalized bucket key. Null only when neither source names a workspace.
  ({Map<String, dynamic> owner, String key})? _sideChatScope(String parent) {
    final owner = _resolveOwnership(parent) ?? activeWorkspace;
    if (owner == null) return null;
    final raw = workspaceKeyOf(owner);
    if (raw == null || raw.isEmpty) return null;
    return (owner: owner, key: _taskHome.normalizeKey(raw));
  }

  /// Rebuilds [parent]'s side-chat tabs from the persisted manifest
  /// (R8/AC9; design §3). Call on every entry into the parent chat page.
  ///
  /// Data source: the local manifest per device+workspace — NOT the
  /// sessions-index, which never carries `selection_side_chat` (host
  /// whitelist `[interactive, fork, workflow_parent]`, research Q1), and not
  /// `listSessions` enumeration, which is hard-wired to the same whitelist
  /// (research Q2). The official web remote keeps tabs in memory only and
  /// loses them on reload, hence the local manifest.
  ///
  /// Verification: when the bridge answers, every manifest id is checked in
  /// batches of ≤64 through `zcode-session.listSessions({workspacePath,
  /// sessionIds})`. A live side-chat row keeps its tab; a missing id or a
  /// row of another kind is dropped from the manifest — that id no longer
  /// names a side chat. When the check itself is unavailable (no bridge, RPC
  /// failure, malformed answer) the manifest is restored as-is:
  /// over-restoring is the safe direction, and a tab whose subscription then
  /// fails self-heals in B1 (the subscription-failure contract this stage
  /// only documents). A destroyed tab was already pruned from the manifest,
  /// so it never comes back.
  ///
  /// Restored tabs keep their persisted ordinals; ids already live are
  /// skipped, making repeated page entries idempotent. Notifies only on an
  /// actual change (the page listens through [addListener]).
  @override
  Future<void> restoreSideChatTabs(String parent) async {
    if (_disposed) return;
    await _sideChatTabStore.load();
    if (_disposed) return;
    final scope = _sideChatScope(parent);
    if (scope == null) return;
    final entries = _sideChatTabStore.entriesOf(scope.key, parent);
    if (entries.isEmpty) return;
    final validated = await _validateSideChatTabs(scope.owner, entries);
    if (_disposed) return;
    final restore = validated ?? entries;
    if (validated != null && validated.length != entries.length) {
      _sideChatTabStore.retain(scope.key, parent, {
        for (final tab in validated) tab.sessionId,
      });
    }
    if (_sideChats.restoreFromEntries(parent, restore)) notifyListeners();
  }

  /// `zcode-session.listSessions` batch cap (V4 schema `Yln`: sessionIds
  /// 1..64). One batch per call; an app-level parent rarely exceeds it.
  static const int sideChatValidationBatch = 64;

  /// Existence check of manifest [entries] against
  /// `zcode-session.listSessions` (research Q2). Answers the confirmed live
  /// side-chat entries in manifest order, or null when the check itself is
  /// unavailable (degrade: restore the manifest untouched).
  ///
  /// The channel layer answers a BARE array of session rows (the host's
  /// `agentService.listSessions` returns `Z.sessions`), each carrying
  /// `sessionId`, `sessionKind`. Soft-deleted rows are filtered server-side. A
  /// row counts as live only when its kind is
  /// [SideChatRegistry.sessionKind] — the exact kind check R8 asks for; the
  /// manifest already owns the parent relation, so a row of another kind (or
  /// an absent one) is refuted. `workspacePath` is mandatory (it is the
  /// agent process routing key, not a V4 param); `workspaceIdentity` joins it
  /// when the workspace has one.
  Future<List<SideChatTab>?> _validateSideChatTabs(
    Map<String, dynamic> owner,
    List<SideChatTab> entries,
  ) async {
    final alive = <SideChatTab>[];
    for (var start = 0;
        start < entries.length;
        start += sideChatValidationBatch) {
      final end = start + sideChatValidationBatch > entries.length
          ? entries.length
          : start + sideChatValidationBatch;
      final batch = entries.sublist(start, end);
      final List<dynamic> rows;
      try {
        final answer =
            await callChannel(Channels.zcodeSession, 'listSessions', [
          {
            'workspacePath': owner['workspacePath'],
            if (owner['workspaceIdentity'] is String &&
                (owner['workspaceIdentity'] as String).isNotEmpty)
              'workspaceIdentity': owner['workspaceIdentity'],
            'sessionIds': [for (final tab in batch) tab.sessionId],
          },
        ]);
        if (answer is! List) return null;
        rows = answer;
      } catch (e) {
        _log('[side-chat] restore validation unavailable: $e');
        return null;
      }
      final live = <String>{
        for (final row in rows)
          if (row is Map &&
              row['sessionKind'] == SideChatRegistry.sessionKind &&
              row['sessionId'] is String)
            row['sessionId'] as String,
      };
      for (final tab in batch) {
        if (live.contains(tab.sessionId)) alive.add(tab);
      }
    }
    return alive;
  }

  /// Grouped task view of every known workspace, read directly from the
  /// desktop's `tasks-index.sqlite` (`task_group_*` tables). The 3.12.3
  /// grouped-task RPC on `zcode-task` is gone in desktop 3.17.1 — the old
  /// body was deleted on purpose (no dual path: the table family predates
  /// 3.16.2, a missing table is the only version gate).
  /// Read-only 一期: group titles/colors/ordering only. Null on any miss
  /// (no desktop home, missing tables, unreadable index) — callers keep the
  /// flat list, no version gate (R4 silent degrade). Cached for 30 s inside
  /// the resolver; the panel re-asks after the TTL.
  Future<GroupedTaskView?> groupedTaskView() => _taskGroupResolver.load();

  /// Token usage of one task (`zcode-task.getTaskTokenUsage`, desktop
  /// 3.12.3 — live-probed 2026-09-18). Flat
  /// `{taskId, workspacePath, workspaceIdentity?}` payload, same scope form
  /// as the task-config read. Null on any miss — callers hide the usage
  /// row (R4).
  Future<TaskTokenUsage?> taskTokenUsage(String taskId) async {
    final scope = offPeakScope;
    if (scope['workspacePath'] == null) return null;
    try {
      final res = await callChannel('zcode-task', 'getTaskTokenUsage', [
        {'taskId': taskId, ...scope},
      ]);
      return res is Map ? TaskTokenUsage.fromMap(res) : null;
    } catch (_) {
      return null;
    }
  }

  /// Full reconnect after a KICK: drop everything and dial again.
  @override
  Future<void> reconnect() async {
    await suspend();
    await connect();
  }

  @override
  Future<ChatHandle> subscribe(String sessionId) async {
    final existing = _chatSubs[sessionId];
    if (existing != null) {
      // The first handle's terminal-failure listener is still live on this
      // shared subscription (it cancels only when its own handle closes,
      // which also disposes the subscription) — a second reader needs none.
      return _handleFor(sessionId, existing);
    }
    late final StreamSubscription<Object?> terminalSub;
    final ConversationSubscription sub;
    try {
      sub = await _requireConversation.subscribe(sessionId);
    } catch (e) {
      if (isSessionNotFoundError(e)) {
        // Initial open of a dead session (10-11): the authoritative
        // refusal arrives straight from the first subscribe. WRITE ENTRY ①
        // (design 11-08 P1-5): before it sticks, check whether the session
        // simply belongs to another workspace — that refusal is about the
        // scope, so it must reroute instead of marking the session missing.
        // Guarded by [_resumingSessions]: inside a resume the bridge is
        // already home, and joining the in-flight future would deadlock.
        if (!_resumingSessions.contains(sessionId) &&
            _foreignOwnership(sessionId) != null) {
          return _rerouteToForeignWorkspace(sessionId);
        }
        // Recorded so the page renders the「会话不存在」terminal state
        // instead of the retryable error banner, and rethrow as before.
        _sessionMissingIds.add(sessionId);
        notifyListeners();
      }
      rethrow;
    }
    _chatSubs[sessionId] = sub;
    // Resubscribe-path refusals surface through the terminal broadcast
    // (the subscription has already stopped its own retry queue); the
    // gateway notify re-runs the open page's banner builder. WRITE ENTRY ②
    // (design 11-08 P1-5): same ownership reverse-lookup — a terminal
    // refusal under a foreign scope is not a dead session.
    terminalSub = sub.terminalFailures.listen((_) async {
      if (_foreignOwnership(sessionId) != null) {
        await _rerouteAfterTerminalRefusal(sessionId, sub);
        return;
      }
      _sessionMissingIds.add(sessionId);
      notifyListeners();
    });
    _chatTerminalSubs[sessionId] = terminalSub;
    return _handleFor(sessionId, sub);
  }

  /// The session's owning workspace when it is NOT the active one; null when
  /// the directory cannot tell (or says the active workspace is home — then
  /// a sessionNotFound refusal is about the session itself).
  Map<String, dynamic>? _foreignOwnership(String sessionId) {
    final owner = _resolveOwnership(sessionId);
    if (owner == null) return null;
    final ownerKey = _taskHome.normalizeKey(workspaceKeyOf(owner) ?? '');
    final activeKey = _sidecarActiveKey();
    if (ownerKey.isEmpty) return null;
    return ownerKey == activeKey ? null : owner;
  }

  /// Reroutes a subscribe refused under a foreign scope (both write entries
  /// converge here): resume through [resumeSessionOnReturn] and answer the
  /// fresh handle, or throw [SessionResumeException]. The page's terminal
  /// contract (design 11-08 P1-1) is "handle or classified error", never a
  /// silent null.
  Future<ChatHandle> _rerouteToForeignWorkspace(String sessionId) async {
    _log('[session] subscribe $sessionId landed under a foreign scope; '
        'rerouting to its workspace');
    return resumeSessionOnReturn(sessionId);
  }

  /// The terminal-broadcast flavour of the reroute (write entry ②): the live
  /// subscription is terminal-failed and must die before the resume installs
  /// a fresh one — otherwise the shared-handle branch of [subscribe] would
  /// hand the dead state back. The generation advances here (this IS a
  /// host-side revoke of the reader) so a visible page detects the orphan on
  /// the host notify and re-binds to the resumed handle.
  Future<void> _rerouteAfterTerminalRefusal(
    String sessionId,
    ConversationSubscription dead,
  ) async {
    if (_chatSubs[sessionId] != dead) return; // a newer subscription owns it
    _chatSubs.remove(sessionId);
    final terminal = _chatTerminalSubs.remove(sessionId);
    await terminal?.cancel();
    await dead.dispose();
    _chatGenerations[sessionId] = _chatGenerationOf(sessionId) + 1;
    notifyListeners();
    try {
      await resumeSessionOnReturn(sessionId);
    } catch (e) {
      // No caller to throw to (the broadcast is fire-and-forget). The page's
      // orphan check sees the advanced generation and runs the resume
      // itself, surfacing the classified failure banner there — no sticky
      //「会话不存在」marker, which would be the wrong verdict for a scope
      // problem.
      _log('[session] terminal-refusal reroute failed for $sessionId: $e');
    }
  }

  @override
  Future<WorkspacePrep> prepareWorkspace() => _prepareWorkspace();

  /// Test seam: the production [prepareWorkspace] body. The test fake
  /// overrides the public method with a canned answer, so consumer-level
  /// capability tests drive the real body through here.
  @visibleForTesting
  Future<WorkspacePrep> debugPrepareWorkspace() => _prepareWorkspace();

  Future<WorkspacePrep> _prepareWorkspace() async {
    if (capabilities.prepareWorkspaceTaskOptions) {
      // 3.12.3 removed prepareWorkspace: config selectors come from the
      // task-level options RPC, slash commands (incl. custom ones) from
      // readWorkspacePresentation alongside it — then the legacy call
      // (misses on 3.12.3 — callers tolerate).
      final v2 = await _prepareWorkspaceViaTaskOptions();
      if (v2 != null) return v2;
    }
    return _requireConversation.prepareWorkspace();
  }

  /// getTaskConfigOptions arg assembly — static for unit tests. [relayFirst]
  /// is the latest relay task (config is workspace-level, task-insensitive);
  /// a null task or task id falls back to the bare workspace scope.
  static Map<String, dynamic> taskConfigOptionsArgs(
    Map<String, dynamic>? relayFirst,
    Map<String, dynamic> workspaceScope,
  ) {
    final taskId = relayFirst?['taskId'];
    if (taskId == null) return {...workspaceScope};
    return {
      'taskId': '$taskId',
      'workspacePath': '${relayFirst!['workspacePath']}',
      if (relayFirst['workspaceIdentity'] != null)
        'workspaceIdentity': relayFirst['workspaceIdentity'],
    };
  }

  Future<WorkspacePrep?> _prepareWorkspaceViaTaskOptions() async {
    final scope = offPeakScope;
    if (scope['workspacePath'] == null) return null;
    try {
      // Both sources fire in parallel; a presentation miss never fails
      // the config selectors (see [_readSlashCommands]).
      final pair = await Future.wait<dynamic>([
        callChannel('zcode-task', 'getTaskConfigOptions', [
          taskConfigOptionsArgs(_taskHome.relayTasks.firstOrNull, scope),
        ]),
        _readSlashCommands(),
      ]);
      final res = pair[0];
      final slash = pair[1] as List<Object>;
      if (res is List && res.isNotEmpty) {
        return WorkspacePrep.fromMap({
          'configOptions': res,
          'slashCommands': slash,
        });
      }
    } catch (_) {
      // Chain rolls on to the legacy prepareWorkspace call.
    }
    return null;
  }

  /// readWorkspacePresentation → raw slashCommands list; empty on any
  /// miss (null / non-List field / channel rejection) — the composer
  /// tolerates an empty panel, not a failed prep.
  Future<List<Object>> _readSlashCommands() async {
    try {
      final presentation =
          await _requireConversation.readWorkspacePresentation();
      final raw = presentation?['slashCommands'];
      return raw is List ? List<Object>.from(raw) : const [];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<List<SkillEntry>> skills() async {
    try {
      return await _requireConversation.skills();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<List<Map<String, dynamic>>> searchWorkspaceFiles(
    String query, {
    int limit = 50,
  }) async {
    final root = workspacePath;
    if (root == null || root.isEmpty) return const [];
    final rows = await fileService.searchWorkspaceFiles(
      root,
      query: query,
      limit: limit,
    );
    return [
      for (final e in rows)
        {
          'name': e.name,
          'path': e.path,
          'relativePath': e.relativePath,
          'type': e.isDirectory ? 'directory' : 'file',
        },
    ];
  }

  @override
  Future<bool> workspaceFilesReachable() async {
    final root = workspacePath;
    if (root == null || root.isEmpty) return false;
    try {
      return await fileService.workspaceFilesReachable(root);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<Map<String, dynamic>>> mentionSkills() async {
    try {
      return [
        for (final s in await skills())
          {
            'id': s.name,
            'name': s.name,
            if (s.description != null) 'description': s.description,
          },
      ];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<List<Map<String, dynamic>>> mentionSubagents() async {
    try {
      final res = await callChannel('subagents', 'list', []);
      final list = res is Map ? res['agents'] : res;
      return list is List
          ? list.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
          : const [];
    } catch (_) {
      // Desktops without the subagent runtime reject the call — empty state.
      return const [];
    }
  }

  @override
  List<({String id, String title})> mentionSessions() {
    final list = sessions?.list ?? const [];
    return [
      for (final e in list) (id: e.sessionId, title: e.title),
    ];
  }

  @override
  String? taskDisplayStatus(String sessionId) {
    // M1 择优（spec task-registry-semantics §3.6，2026-10-11）已迁入
    // [TaskDirectory.displayStatusWinner] 并成为合成行 displayStatus 的
    // 同一选择（design 10-15 §2.2 字段级合成）—— 这里只读该结果，两套
    // 择优合一：同输入下列表行的相位与这里返回的状态必然一致。规则不变
    // （终态优先 → 同类取 updatedAt 大 → workspacePath 字典序 → 状态串
    // 兜底；未识别值按运行态类）。
    return TaskDirectory.displayStatusWinner(relayTasks, sessionId);
  }

  @override
  Map<String, dynamic>? taskLastError(String sessionId) {
    // 读合并目录的合成行，不是 relayTasks：live sessions-index 覆盖会重建 raw
    // 并剥掉 relay 源字段，lastError 由 TaskDirectory._withRelayMeta 从 relay
    // 行补齐（task_directory.dart）—— relay 直读会让「live 覆盖中的任务」
    // 永远拿不到错误详情。合并结果是列表行呈现的同一行，两处不会漂移。
    for (final (entry, _, _) in taskDirectory.mergedRows().rows) {
      if (entry.sessionId != sessionId) continue;
      // 缺省/空白字段不进 map（AC5 的单一归一化点：UI 只判 key 在不在）；
      // 空白串同样算缺省（wire 漂移的垃圾值不得渲染成空行），一个可用字段
      // 都没有 = 与「该行没有错误」同义，回 null。
      final error = <String, dynamic>{};
      void put(String key, String? value) {
        if (value != null && value.trim().isNotEmpty) error[key] = value;
      }

      put('message', entry.lastErrorMessage);
      put('code', entry.lastErrorCode);
      put('traceId', entry.lastErrorTraceId);
      put('attribution', entry.lastErrorAttribution);
      return error.isEmpty ? null : error;
    }
    return null;
  }

  @override
  bool isSessionDeleted(String sessionId) =>
      _taskHome.isSessionDeleted(sessionId);

  @override
  void forgetDeletedSession(String sessionId) {
    _taskHome.forgetDeletedSession(sessionId);
  }

  @override
  bool isSessionMissing(String sessionId) =>
      _sessionMissingIds.contains(sessionId);

  @override
  void forgetMissingSession(String sessionId) {
    _sessionMissingIds.remove(sessionId);
  }

  /// Session-wide entitlement pollers keyed by `preferredProviderId` — one
  /// cache per quota route, shared by the usage page's parallel groups, the
  /// chat quota pill / warning banner and the quota-reset controller. Keying
  /// by provider id is what lets the dual-plan usage page (subscription +
  /// Start, design 10-25) refresh each route on its own staleness clock
  /// while the main route still reuses the same instance. Created lazily and
  /// disposed with the session.
  final Map<String, EntitlementPoller> _entitlementPollers = {};

  /// Pre-3.12.3 wire: one global snapshot, no plan routing.
  EntitlementPoller? _legacyEntitlementPoller;

  /// Last resolved main route ([entitlementSnapshot]): while its poller is
  /// fresh a non-forced call answers without resolving the plan again —
  /// the pre-10-25 request profile (cache hit issues no RPC).
  ({Map<String, dynamic> plan, EntitlementPoller poller})? _mainRoute;

  EntitlementPoller _pollerFor(Map<String, dynamic> plan) {
    final key = '${plan['providerId']}';
    return _entitlementPollers.putIfAbsent(
      key,
      () => EntitlementPoller(fetch: () => _fetchEntitlement(plan)),
    );
  }

  EntitlementPoller _legacyPoller() =>
      _legacyEntitlementPoller ??=
          EntitlementPoller(fetch: () => _fetchEntitlement(const {}));

  /// Entitled account providers of the `provider-settings` view, mapped onto
  /// the `{providerId, accountAccess}` shape [parsePlanAccess] produces —
  /// the shared entry the quota wire and the model catalog both read
  /// (design 10-24 §2). Only account providers whose
  /// `effectiveConfig.access.entitled` is true and whose id parses onto a
  /// known plan family are returned, in view order.
  ///
  /// Never cached: entitlement refreshes (5-minute poller staleness) and
  /// config-sheet opens are user-throttled, and a live re-read is what lets
  /// a plan change heal without reconnecting (the removed session-wide
  /// cache is what pinned starter-only accounts to the coding-plan route).
  /// A missing channel (old desktop) or a failed getView answers an empty
  /// list — callers fall back to their own derivation. Callers that must
  /// tell "failed" from "zero entitled" use the throwing core through
  /// [entitledProviderIds].
  Future<List<Map<String, dynamic>>> entitledPlanAccesses() async {
    try {
      return await _readEntitledPlanAccesses();
    } catch (_) {
      return const [];
    }
  }

  /// Throwing core of [entitledPlanAccesses]: the model-catalog filter needs
  /// getView failure (no filtering) and a successful view with zero
  /// entitlements (filter every unentitled account group) to stay apart
  /// (design 10-24 §3).
  Future<List<Map<String, dynamic>>> _readEntitledPlanAccesses() async {
    final port = ProviderSettingsPort(callChannel);
    final view = ProviderSettingsView.parse(await port.getView());
    return [
      for (final provider in view.accountProviders)
        if (provider.entitled)
          if (parsePlanAccess(provider.providerId) case final plan?) plan,
    ];
  }

  /// Provider-id projection for the chat config sheet's group filter: null
  /// when the provider-settings view cannot be read (old desktop / bridge
  /// failure → entitlement unknown, show everything), otherwise the
  /// entitled account ids (possibly empty → hide every unentitled account
  /// group).
  @override
  Future<Set<String>?> entitledProviderIds() async {
    try {
      final plans = await _readEntitledPlanAccesses();
      return {for (final plan in plans) '${plan['providerId']}'};
    } catch (_) {
      return null;
    }
  }

  /// Maps a coding-plan provider id (`account:<family>-<planKind>`) onto the
  /// `{providerId, accountAccess}` pair the 3.12.3 quota wire requires;
  /// null for ids outside the known families (zai|bigmodel, from the
  /// desktop bundle's zod schema).
  static Map<String, dynamic>? parsePlanAccess(String providerId) {
    final m = RegExp(r'^account:(zai|bigmodel)-(.+)$').firstMatch(providerId);
    if (m == null) return null;
    return {
      'providerId': providerId,
      'accountAccess': {
        'type': 'zhipu-account',
        'family': m.group(1),
        'planKind': m.group(2),
      },
    };
  }

  /// Coding-plan kinds (the subscription family) — the first of these in
  /// view order is the usage page's subscription group representative.
  static const _codingPlanKinds = {
    'individual-coding-plan',
    'team-coding-plan',
  };

  /// planKinds that are quota-snapshot targets. Off-peak (idle plan) and
  /// highspeed are deliberately absent: the official client excludes them
  /// (hw), and asking the desktop for an idle-plan snapshot only answers
  /// `no_plan` — the exact false negative this resolution removes.
  static const _snapshotPlanKinds = {..._codingPlanKinds, 'start-plan'};

  static const _startPlanKinds = {'start-plan'};

  /// `accountAccess.planKind` of a parsed plan access; null when absent.
  static String? _planKindOf(Map<String, dynamic> plan) {
    final access = plan['accountAccess'];
    final kind = access is Map ? access['planKind'] : null;
    return kind is String ? kind : null;
  }

  /// First plan of one of [kinds] in view order; null when none matches.
  static Map<String, dynamic>? _firstPlanOfKind(
    List<Map<String, dynamic>> plans,
    Set<String> kinds,
  ) {
    for (final plan in plans) {
      final kind = _planKindOf(plan);
      if (kind != null && kinds.contains(kind)) return plan;
    }
    return null;
  }

  /// The plan provider the 3.12.3+ quota wire targets, resolved fresh on
  /// every use (design 10-24 §3). Priority follows the official xPe/FPe
  /// order: the current task's derived provider when entitled → an entitled
  /// coding plan (individual/team, view order) → an entitled Start plan →
  /// the legacy derivation. Off-peak/highspeed entries are parseable but
  /// are not snapshot targets, so they never match the kind filters.
  ///
  /// Only when no entitled plan and no derivation exists does the coding-plan
  /// probe literal stand in: the desktop must still be asked once so it can
  /// answer `no_plan` (the phase machine depends on that authoritative
  /// answer, design §3).
  ///
  /// [entitled] lets a caller that already read the entitled set
  /// ([entitlementSnapshots]) pass it in instead of paying a second getView.
  Future<Map<String, dynamic>> _resolvePlanAccess({
    List<Map<String, dynamic>>? entitled,
  }) async {
    final entitledPlans = entitled ?? await entitledPlanAccesses();
    final derived = await _derivePlanAccess();
    // 1. Follow the session's actual provider when it is entitled AND a
    // snapshot target: a session running an off-peak task derives
    // `account:zai-*-off-peak`, which the desktop cannot snapshot — it must
    // never outrank a purchased coding/Start plan.
    final derivedKind = derived == null ? null : _planKindOf(derived);
    if (derived != null &&
        derivedKind != null &&
        _snapshotPlanKinds.contains(derivedKind)) {
      for (final plan in entitledPlans) {
        if (plan['providerId'] == derived['providerId']) return derived;
      }
    }

    // 2. Official FPe: a purchased coding plan outranks a Start plan.
    final coding = _firstPlanOfKind(entitledPlans, _codingPlanKinds);
    if (coding != null) return coding;
    // 3. Starter-only accounts ride the Start plan.
    final start = _firstPlanOfKind(entitledPlans, _startPlanKinds);
    if (start != null) return start;
    // 4. Degrade to the legacy derivation, or the coding-plan probe literal.
    return derived ??
        {
          'providerId': 'account:zai-individual-coding-plan',
          'accountAccess': {
            'type': 'zhipu-account',
            'family': 'zai',
            'planKind': 'individual-coding-plan',
          },
        };
  }

  /// Best-effort plan access of the most recently updated relay task's
  /// model selection — null when there is no task, no task answers an
  /// account provider, or every probe fails. The newest task wins
  /// (`updatedAt`, the relay row's real field; ties keep list order); a
  /// failed / non-account selection on it falls back to the first task, so
  /// a lagging newest row never loses the derivation entirely.
  Future<Map<String, dynamic>?> _derivePlanAccess() async {
    final relay = relayTasks;
    if (relay.isEmpty) return null;
    final first = relay.first;
    final latest = _newestRelayTask(relay);
    final fromLatest = await _planAccessOfTask(latest);
    if (fromLatest != null) return fromLatest;
    if (identical(latest, first)) return null;
    return _planAccessOfTask(first);
  }

  /// Relay task with the greatest `updatedAt`; ties keep list order (strict
  /// `>` scan, no unstable sort). A missing/mistyped field counts as 0 —
  /// the derivation is best-effort and must never throw on a drifted row.
  static Map<String, dynamic> _newestRelayTask(
    List<Map<String, dynamic>> tasks,
  ) {
    int updatedAtOf(Map<String, dynamic> task) {
      final raw = task['updatedAt'];
      return raw is num ? raw.toInt() : 0;
    }

    var best = tasks.first;
    var bestAt = updatedAtOf(best);
    for (final task in tasks.skip(1)) {
      final at = updatedAtOf(task);
      if (at > bestAt) {
        best = task;
        bestAt = at;
      }
    }
    return best;
  }

  /// One `getTaskModelSelection` probe, mapped onto a parsed plan access;
  /// null (never throws) on RPC failure or a non-account provider.
  Future<Map<String, dynamic>?> _planAccessOfTask(
    Map<String, dynamic> task,
  ) async {
    try {
      final sel = await callChannel('zcode-task', 'getTaskModelSelection', [
        {
          'taskId': '${task['taskId']}',
          'workspacePath': '${task['workspacePath']}',
          if (task['workspaceIdentity'] != null)
            'workspaceIdentity': task['workspaceIdentity'],
        }
      ]);
      final providerId = sel is Map ? sel['providerId'] : null;
      return providerId is String ? parsePlanAccess(providerId) : null;
    } catch (_) {
      // Best-effort derivation; the entitled set / literal fallback covers it.
      return null;
    }
  }

  /// usage-stats channel fetch for one route's poller. Pre-3.12.3 the bare
  /// call is the legacy wire (the plan is ignored); 3.12.3+ gates the quota
  /// APIs on the full parameter set (accountAccess — live-probed
  /// 2026-09-17). A failing full call throws into the poller's error phase —
  /// no bare retry: on 3.12.3 the bare form answers not_configured, so a
  /// retry would add zero information.
  Future<dynamic> _fetchEntitlement(Map<String, dynamic> plan) async {
    if (!capabilities.quotaWire) {
      return callChannel('usage-stats', 'getEntitlementSnapshot', [
        {'includeSubscription': true}
      ]);
    }
    return callChannel('usage-stats', 'getEntitlementSnapshot', [
      {
        'includeSubscription': true,
        'preferredProviderId': plan['providerId'],
        'accountAccess': plan['accountAccess'],
        'allowDisabledPreferredProvider': true,
        'requirePreferredProvider': true,
        'allowEnvApiKey': false,
      }
    ]);
  }

  @override
  Future<EntitlementView> entitlementSnapshot({bool force = false}) async {
    final EntitlementPoller poller;
    Map<String, dynamic>? plan;
    if (capabilities.quotaWire) {
      final cached = _mainRoute;
      if (!force && cached != null && cached.poller.isFresh) {
        poller = cached.poller;
        plan = cached.plan;
      } else {
        plan = await _resolvePlanAccess();
        poller = _pollerFor(plan);
        _mainRoute = (plan: plan, poller: poller);
      }
    } else {
      poller = _legacyPoller();
    }
    final view = await poller.refresh(force: force);
    // The reset scope rides the snapshot (design Q2a): the session injects
    // the provider id — and, on the routed wire, the plan pair the fetch
    // was made for, so the reset RPCs keep `accountAccess` same-source
    // with the scope (design 10-25). Same value is a no-op.
    quotaResetController.updateScope(view.resetScopeProviderId, plan: plan);
    return view;
  }

  /// The quota routes the usage page renders side by side (design 10-25):
  /// the entitled subscription representative (first individual/team coding
  /// plan in provider-settings view order) and the entitled Start
  /// representative (first start-plan), each fetched through its own
  /// provider-keyed [EntitlementPoller]. Kinds outside [_snapshotPlanKinds]
  /// (off-peak, highspeed) never become routes — the official xPe limit is
  /// one coding + one Start route.
  ///
  /// With an unreadable provider-settings view or no entitled snapshot
  /// target, the single main route ([_resolvePlanAccess]) stands in — the
  /// page then renders exactly the pre-10-25 one-group form. The legacy
  /// wire (<3.12.3) answers one unrouted snapshot, so its route carries a
  /// null plan. Never throws beyond the per-poller error phase; the reset
  /// scope rides the first (primary) route's view like [entitlementSnapshot].
  Future<List<EntitlementSnapshotRoute>> entitlementSnapshots({
    bool force = false,
  }) async {
    if (!capabilities.quotaWire) {
      final view = await _legacyPoller().refresh(force: force);
      quotaResetController.updateScope(view.resetScopeProviderId);
      return [(plan: null, view: view)];
    }
    final entitled = await entitledPlanAccesses();
    final coding = _firstPlanOfKind(entitled, _codingPlanKinds);
    final start = _firstPlanOfKind(entitled, _startPlanKinds);
    final plans = <Map<String, dynamic>>[
      if (coding != null) coding,
      if (start != null) start,
    ];
    if (plans.isEmpty) {
      plans.add(await _resolvePlanAccess(entitled: entitled));
    }
    final views = await Future.wait([
      for (final plan in plans) _pollerFor(plan).refresh(force: force),
    ]);
    // The reset card is single and rides the primary (subscription) route:
    // its plan pair is injected alongside the view's provider id so the
    // reset RPCs stay same-source even when the main route derived a
    // different (e.g. Start) provider.
    quotaResetController.updateScope(
      views.first.resetScopeProviderId,
      plan: plans.first,
    );
    return [
      for (var i = 0; i < plans.length; i++)
        (plan: plans[i], view: views[i]),
    ];
  }

  /// Session-wide reset-opportunity controller — lazily created like the
  /// entitlement pollers, disposed with the session. The scope
  /// (`preferredProviderId`) is injected by [entitlementSnapshot] /
  /// [entitlementSnapshots] from the snapshot; the forwarded RPCs below
  /// read it back as the single source.
  QuotaResetController? _quotaReset;

  @override
  QuotaResetController get quotaResetController =>
      _quotaReset ??= QuotaResetController(gateway: this);

  @override
  Future<Object?> quotaResetStatus({bool force = false}) async {
    if (!capabilities.quotaWire) {
      return callChannel('usage-stats', 'getCodingPlanResetStatus', [
        {'preferredProviderId': quotaResetController.scopeProviderId},
      ]);
    }
    // 3.12.3 requires accountAccess (coding_plan_reset_account_access_
    // required otherwise). It must come from the SAME plan as
    // `preferredProviderId` — pairing a Start access with a coding scope
    // (the derived-main / dual-plan case) is a rejected shape (10-25).
    final plan = await _resetScopePlan();
    return callChannel('usage-stats', 'getCodingPlanResetStatus', [
      {
        'preferredProviderId': plan['providerId'],
        'accountAccess': plan['accountAccess'],
      }
    ]);
  }

  /// The plan pair the reset RPCs must carry: the scope injected with its
  /// snapshot (same-source `accountAccess`), or — for callers that only
  /// injected a bare provider id — that id's parsed access; the main-route
  /// resolution is only the last resort (before the first snapshot lands).
  Future<Map<String, dynamic>> _resetScopePlan() async {
    final scoped = quotaResetController.scopePlan;
    if (scoped != null) return scoped;
    final providerId = quotaResetController.scopeProviderId;
    if (providerId != null) {
      final parsed = parsePlanAccess(providerId);
      if (parsed != null) return parsed;
    }
    return _resolvePlanAccess();
  }

  @override
  Future<void> useQuotaReset(
    String resetType,
    String idempotencyKey, {
    String? preferredProviderId,
  }) async {
    if (!capabilities.quotaWire) {
      return callChannel('usage-stats', 'useCodingPlanReset', [
        {
          'preferredProviderId': preferredProviderId,
          'idempotencyKey': idempotencyKey,
          'resetType': resetType,
        },
      ]);
    }
    // Same injection as the status call (destructive op — unverifiable by
    // probe; the status call's accepted shape validates the form). The
    // scope's plan pair wins over the bare argument so the two fields stay
    // same-source (10-25).
    final plan = await _resetScopePlan();
    await callChannel('usage-stats', 'useCodingPlanReset', [
      {
        'preferredProviderId': plan['providerId'],
        'idempotencyKey': idempotencyKey,
        'resetType': resetType,
        'accountAccess': plan['accountAccess'],
      }
    ]);
  }

  /// Cleanly closes the connection so the in-app WebView (or another
  /// terminal) can take the slot without a KICK race. Callers reconnect
  /// via [connect] later (the hub adds the ~1s grace delay).
  Future<void> suspend() async {
    if (_disposed) return;
    _retryTimer?.cancel();
    _listWatchdog?.cancel();
    _listEscalations = 0;
    _softReloadFails = 0;
    _linkSupervisor.reset();
    _connecting = false;
    _openingWorkspace = false;
    final client = _client;
    final bridge = _bridge;
    final sub = _sessionsSub;
    final chats = Map.of(_chatSubs);
    final chatTerminals = Map.of(_chatTerminalSubs);
    _client = null;
    _bridge = null;
    _conversation = null;
    // Registrations survive the suspend (their owners are UI pages); only
    // the wire attaches die with the bridge and re-attach on the next one.
    for (final entry in _channelListeners) {
      entry.detach();
    }
    _sessionsSub = null;
    _chatSubs.clear();
    _chatTerminalSubs.clear();
    // Host teardown of every chat reader (same rationale as the workspace
    // switch: suspend is the handover/rebuild path, never a page's own
    // close) — a chat page left in the stack must still be able to tell its
    // subscription died behind its back.
    for (final sessionId in chats.keys) {
      _chatGenerations[sessionId] = _chatGenerationOf(sessionId) + 1;
    }
    _activeWorkspace = null;
    _bootstrapWorkspaces = [];
    _workspaces = [];
    _tasksFromBootstrap = false;
    _taskOverviewLanded = false;
    _tasksRefresh = null;
    _pinnedMerge = null;
    _overviewRefresh = null;
    _overviewRefreshStartedAt = null;
    // A project read in flight belongs to the closed link; a fresh
    // connection must start its own instead of joining the old answer
    // (whose late-merge guard would drop it anyway).
    _projectWorkspaceRefresh = null;
    // Snapshot cache / relay rows / aliases / active listener die with the
    // rest of the directory state — a rebuild is a cold start (design
    // §清点). Retry loops don't pass through here, so a flapping link keeps
    // its cached rows.
    _taskHome.clear();
    // Sidecar subscriptions die with the bridge below — dispose them first
    // so their timers / recovery hooks never outlive it (design 10-28).
    _sidecars.disposeAll();
    _failureReason = null;
    _kicked = false;
    _error = null;
    _lastWorkspaceOpenFailure = null;
    _watchdogParked = false;
    // The live version dies with the link (see [connect]): a later
    // connection starts in snapshot-only mode until its bootstrap lands.
    _desktopAppVersion = null;
    _setStatus(DeviceStatus.disconnected);
    await _failureSub?.cancel();
    _failureSub = null;
    await _wsListSub?.cancel();
    _wsListSub = null;
    await _appErrSub?.cancel();
    _appErrSub = null;
    unawaited(sub?.dispose());
    for (final t in chatTerminals.values) {
      unawaited(t.cancel());
    }
    for (final s in chats.values) {
      unawaited(s.dispose());
    }
    bridge?.dispose();
    await client?.dispose();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await suspend();
    for (final poller in _entitlementPollers.values) {
      poller.dispose();
    }
    _legacyEntitlementPoller?.dispose();
    _quotaReset?.dispose();
    super.dispose();
  }

  /// Single funnel for the protocol log chain (ipc per-RPC lines, rpc
  /// transport, bridge) — guarded here so hot-path logging costs nothing in
  /// release/profile while the text stays intact for debug runs.
  void _log(String line) {
    if (kDebugMode) debugPrint('[$deviceId] $line');
  }
}

/// Owns one [DeviceSession] per device and mediates the
/// native-connection ↔ WebView handover. Kept as a plain ChangeNotifier so
/// device cards can rebuild on any session change.
class DeviceSessionHub extends ChangeNotifier {
  /// Whether the native task list feature is enabled (settings switch).
  final bool Function() nativeListEnabled;

  /// Grace period after the WebView closes before the native connection
  /// comes back — the relay needs a moment to free the device slot.
  static const resumeDelay = Duration(seconds: 1);

  final Map<String, DeviceSession> _sessions = {};
  final Map<String, Timer> _resumes = {};

  /// Last-opened workspace per device (survives WebView handovers).
  final Map<String, String> _lastWorkspaceKey = {};
  bool _disposed = false;

  DeviceSessionHub({
    required this.nativeListEnabled,
    this.draftsRoot,
    this.jwtProvider,
    this.loadCachedHome,
    this.saveCachedHome,
  });

  /// Desktop-home cache seam, threaded into every [ensure]d session's project
  /// resolver (see [DeviceSession.loadCachedHome]).
  final String? Function()? loadCachedHome;
  final Future<void> Function(String home)? saveCachedHome;

  /// Composer-draft attachment root, threaded into every [ensure]d
  /// session's [ChatDraftStore].
  final Future<Directory?> Function()? draftsRoot;

  /// ZCode account JWT seam for the V2 relay, threaded into every
  /// [DeviceSession] this hub creates (see
  /// [DeviceSession.jwtProvider]). Null on hosts without the plan plane —
  /// V2 links then fail with `auth-required` instead of dialing.
  final Future<String?> Function()? jwtProvider;

  DeviceSession? sessionOf(String deviceId) => _sessions[deviceId];

  /// All live native sessions (notification hub observes these).
  Iterable<DeviceSession> get activeSessions => _sessions.values;

  /// Test seam: place a pre-built session (FakeDeviceSession) into the hub
  /// with the same wiring [ensure] uses, without connecting anything.
  @visibleForTesting
  void installForTesting(DeviceSession session) {
    _sessions[session.deviceId] = session;
    session.addListener(_onSessionChanged);
    _onSessionChanged();
  }

  /// Ensures [device] has a (re)connecting native session. Returns null
  /// for devices whose URL cannot be parsed (no protocol layer possible).
  DeviceSession? ensure(Device device) {
    if (_disposed || !nativeListEnabled()) return null;
    final existing = _sessions[device.id];
    if (existing != null) {
      if (existing.status == DeviceStatus.disconnected ||
          (existing.status == DeviceStatus.error && !existing.kicked)) {
        unawaited(existing.connect());
      }
      return existing;
    }
    final params = device.params;
    if (params == null) return null;
    final session = DeviceSession(
      deviceId: device.id,
      params: params,
      preferredWorkspaceKey: _lastWorkspaceKey[device.id],
      onWorkspaceOpened: (key) => _lastWorkspaceKey[device.id] = key,
      draftsRoot: draftsRoot,
      jwtProvider: jwtProvider,
      loadCachedHome: loadCachedHome,
      saveCachedHome: saveCachedHome,
    );
    _sessions[device.id] = session;
    session.addListener(_onSessionChanged);
    unawaited(session.connect());
    _onSessionChanged();
    return session;
  }

  /// Closes the native connection for the WebView handover. The pending
  /// resume timer (if any) is cancelled — the new one is armed by
  /// [scheduleResume] when the WebView page pops.
  Future<void> suspend(String deviceId) async {
    _resumes.remove(deviceId)?.cancel();
    final session = _sessions.remove(deviceId);
    if (session != null) {
      session.removeListener(_onSessionChanged);
      await session.suspend();
      _onSessionChanged();
    }
  }

  /// Reconnects [device] after [resumeDelay] (native list must be on).
  void scheduleResume(Device device) {
    if (_disposed || !nativeListEnabled()) return;
    final id = device.id;
    _resumes.remove(id)?.cancel();
    _resumes[id] = Timer(resumeDelay, () {
      _resumes.remove(id);
      if (_disposed) return;
      final current = _sessions[id];
      if (current == null) {
        ensure(device);
      } else if (current.status == DeviceStatus.disconnected) {
        unawaited(current.connect());
      }
    });
  }

  Future<void> disconnect(String deviceId) async {
    await suspend(deviceId);
  }

  /// Drops every native connection (native list disabled in settings).
  Future<void> disconnectAll() async {
    for (final id in _sessions.keys.toList()) {
      await disconnect(id);
    }
  }

  /// Reconciles native connections with the current device list and the
  /// native-list switch: connect new devices, drop removed ones, tear
  /// everything down when the feature is off.
  void syncWith(List<Device> devices) {
    if (_disposed) return;
    final ids = devices.map((d) => d.id).toSet();
    for (final id in _sessions.keys.toList()) {
      if (!ids.contains(id)) unawaited(disconnect(id));
    }
    if (nativeListEnabled()) {
      for (final d in devices) {
        ensure(d);
      }
    } else {
      unawaited(disconnectAll());
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final t in _resumes.values) {
      t.cancel();
    }
    _resumes.clear();
    final all = _sessions.values.toList();
    _sessions.clear();
    for (final s in all) {
      s.removeListener(_onSessionChanged);
      await s.dispose();
    }
    super.dispose();
  }

  void _onSessionChanged() {
    if (!_disposed) notifyListeners();
  }
}

/// One [DeviceSession.listenChannel] registration: the handler plus its
/// current wire attach. Attach and detach never throw — listeners decorate
/// the session, so they must not break connects or suspends.
class _ManagedChannelListener {
  _ManagedChannelListener(this.channel, this.event, this.handler);

  final String channel;
  final String event;
  final void Function(dynamic) handler;

  /// Cancel function of the current wire attach (null while detached).
  void Function()? _cancel;

  /// Attaches to [bridge]'s channel client unless already attached.
  void attachTo(BridgeSession? bridge) {
    if (bridge == null || _cancel != null) return;
    try {
      _cancel = bridge.channels.addEventListener(channel, event, handler);
    } catch (_) {
      _cancel = null;
    }
  }

  /// Drops the current wire attach (no-op while detached). The EventDispose
  /// send can hit a bridge that just died — swallowed by design.
  void detach() {
    final cancel = _cancel;
    _cancel = null;
    if (cancel == null) return;
    try {
      cancel();
    } catch (_) {}
  }
}
