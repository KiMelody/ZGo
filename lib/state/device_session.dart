import 'dart:async';
import 'dart:io' show Directory;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../protocol/automation.dart';
import '../protocol/channel_client.dart'
    show
        Channels,
        isBridgeGateTimeoutError,
        isChannelLevelError,
        isChannelMissingError,
        isSessionNotFoundError;
import '../protocol/connection_params.dart';
import '../protocol/conversation.dart';
import '../protocol/file_service.dart';
import '../protocol/git_service.dart';
import '../protocol/method_probe.dart';
import '../protocol/model_selection.dart' show parseModelSelectionCatalog;
import '../protocol/off_peak.dart';
import '../protocol/project_resolver.dart';
import '../protocol/provider_settings.dart';
import '../protocol/relay_client.dart';
import '../protocol/relay_v2.dart' show RelayV2StartException;
import '../protocol/remote_client.dart';
import '../protocol/task_commands.dart';
import '../protocol/task_groups.dart';
import 'chat_draft_store.dart';
import 'device_store.dart';
import 'entitlement_poller.dart';
import 'link_supervisor.dart';
import 'quota_reset.dart';
import 'quota_watch.dart' show QuotaWatchSource;
import 'task_directory.dart';
import 'task_home_store.dart';

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

/// What the automations UI needs from a device link: live status plus the
/// automation port. [DeviceSession] implements this; tests fake it.
abstract interface class AutomationHost {
  DeviceStatus get status;
  AutomationPort get automation;

  /// Active workspace scope (`workspacePath`/`workspaceIdentity`) attached
  /// to run-now triggers; the desktop requires it server-side.
  Map<String, dynamic> get automationScope;
}

/// Same for the off-peak UI: live status, the off-peak port and the
/// workspace scope the submitted run binds to.
abstract interface class OffPeakHost {
  DeviceStatus get status;
  OffPeakPort get offPeak;

  /// `workspacePath` (+ identity) of the active workspace for submissions.
  Map<String, dynamic> get offPeakScope;
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
class ChatHandle {
  final ConversationState state;
  final Future<void> Function() close;

  const ChatHandle({required this.state, required this.close});
}

/// The Conversation V4 surface the native chat page drives — the
/// [AutomationHost]/[OffPeakHost] seam pattern applied to conversations.
/// [DeviceSession] implements it against the live transport; tests fake it
/// (recording calls, answering from a real [ConversationState] fed by hand).
///
/// Lifecycle and state reading stay on the gateway; the whole conversation
/// command surface collapses into [conversationCommands] (a
/// [ConversationTransport] accessor — UI-holding protocol types has
/// precedent in [ConversationState], so no layering rule is broken and no
/// narrower command interface is invented for a single implementation).
abstract interface class ChatGateway
    implements Listenable, QuotaResetGateway {
  DeviceStatus get status;
  bool get kicked;
  String? get error;

  /// Conversation V4 commands of the active workspace (sendText / stop /
  /// queue / model switches / row actions / attachments / …). The session
  /// owns the transport; throws when no workspace is open.
  ConversationTransport get conversationCommands;

  /// Offline replayable-command queue (3.12.3 `web-remote-replayable`):
  /// sendText failures at bridge level land here and are replayed via
  /// `enqueueTaskCommand` once the bridge recovers. Null on older desktops
  /// (`params.atLeast(3, 12, 3)` gate — the chat page then never queues,
  /// zero behavior change) and while no workspace is open.
  ReplayableCommandQueue? get replayableQueue;

  /// Task metadata commands (rename/pin/archive/unread). Method names are
  /// source-confirmed — see [TaskCommandsPort].
  Future<dynamic> renameTask(String sessionId, String title);
  Future<dynamic> setTaskPinned(String sessionId, bool pinned);
  Future<dynamic> setTaskArchived(String sessionId, bool archived);
  Future<dynamic> setTaskUnread(String sessionId, bool unread);

  /// Desktop-local native session log file path (`getTaskNativeSessionLogFile`
  /// on the zcode-task channel, F2): `{provider, path, exists}` — the chat
  /// 更多菜单「复制日志路径」data source. Throws when the bridge is down or the
  /// desktop lacks the method; callers degrade (hide the entry / toast).
  Future<dynamic> taskNativeSessionLogFile(String sessionId);

  /// Deletes a task (`zcode-task.deleteTask`). Callers confirm first.
  Future<dynamic> deleteTask(String sessionId);

  /// mobile-view-state-update: report the task the chat UI is showing
  /// (or just the workspace when [taskId] is null).
  void sendViewState({String? taskId});

  /// `workspaceId` for draft-mode createSession, plus the workspace path
  /// for the chat page's copy action.
  String? get chatWorkspaceId;
  String? get workspacePath;

  /// Composer-draft persistence for this device's chat pages (text +
  /// attachment metadata in SharedPreferences, attachment bytes under the
  /// hub-injected root). Pages restore once on init and debounce writes
  /// into it; failures degrade to no persistence, never blocking chat.
  ChatDraftStore get chatDraftStore;

  /// Original remote-control URL (for "copy task link").
  String? get remoteUrl;

  /// Manual recovery after a KICK: full suspend + reconnect.
  Future<void> reconnect();

  Future<ChatHandle> subscribe(String sessionId);
  Future<WorkspacePrep> prepareWorkspace();
  Future<List<SkillEntry>> skills();

  /// Fallback model catalog for the chat config sheet (PRD 09-19): enabled
  /// providers from the `model-provider` channel (`getAll`), or — on ≥3.14
  /// desktops where that channel is gone — the `model-selection.getView`
  /// registry mapped to the same shape. Used when
  /// prepareWorkspace ships no model options. Cached for the session
  /// lifetime like [DeviceSession.probeModelProvider]; never throws —
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

  /// @-mention data sources (web chat.mention.* picker).
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

  /// Skills (id/name/description) — same data as the $ picker.
  Future<List<Map<String, dynamic>>> mentionSkills();

  /// Subagents (name/description); empty on desktops rejecting the call.
  Future<List<Map<String, dynamic>>> mentionSubagents();

  /// Open sessions of the active workspace (id/title).
  List<({String id, String title})> mentionSessions();

  /// Workspace file reads for the preview surfaces (markdown local images,
  /// HTML preview assembly). Backed by the desktop `file` channel's
  /// fileService — method names are bundle-derived and probed at runtime,
  /// never hardcoded (see [FileServicePort]; the args scope shape is pending
  /// live-probe certification and lives only in the port).
  Future<FileStat> fileStat(String workspacePath, String path);
  Future<MediaPreview> fileReadMedia(String workspacePath, String path,
      {int? maxBytes});
  Future<TextChunk> fileReadText(String workspacePath, String path,
      {int offset = 0, required int length});

  /// Byte-range read on the same port (`{path, offset, length}`, byte units)
  /// — the pdf range transport's data source. The desktop clamps one call to
  /// 1 MiB and answers an empty payload past EOF (the loop's termination
  /// signal); callers follow the official 256 KiB step. See
  /// [FileServicePort.readFileRange].
  Future<FileRange> fileReadRange(String workspacePath, String path,
      {required int offset, required int length});

  /// Workspace Git operations (the desktop `git` channel's gitService) for
  /// the chat status-panel Git group and the review panel. Method names are
  /// probed at runtime with both naming sets — see [GitPort].
  GitPort get git;

  /// Relay-overview display status (`idle|running|completed|error`) of one
  /// task, read from the relay task view keyed by taskId. The shell-
  /// session error card's only signal (design 09-25 D1): a session that
  /// fails its first turn pushes `displayStatus:"error"` while its
  /// snapshot `control.phase` is unreliable. Null when that view doesn't
  /// hold the session (not yet bootstrapped / other-workspace lag) —
  /// callers must treat null as "don't render", never as an error.
  String? taskDisplayStatus(String sessionId);

  /// Cross-terminal deletion tombstone (task 10-06 chat tombstone): true
  /// once the live sessions-index of the active workspace dropped
  /// [sessionId] after having listed it — another terminal deleted the
  /// session. The chat page renders a tombstone banner and disables the
  /// composer send; the messages stay read-only (no pop, no clearing).
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

  /// Entitlement/quota snapshot (usage-stats.getEntitlementSnapshot) via
  /// the session-wide [EntitlementPoller]: cached within the staleness
  /// window, [force] bypasses it. Never throws — failures arrive as an
  /// [EntitlementView] with phase [EntitlementPhase.error].
  @override
  Future<EntitlementView> entitlementSnapshot({bool force = false});

  /// Session-wide reset-opportunity controller (usage page card + chat
  /// banner action). Lazily created with the gateway, disposed with the
  /// session; UI only reads [QuotaResetController.pools] and calls
  /// refresh/use — the scope is injected by [entitlementSnapshot].
  QuotaResetController get quotaResetController;
}

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
        ChatGateway,
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

  DeviceSession({
    required this.deviceId,
    required this.params,
    this.preferredWorkspaceKey,
    this.onWorkspaceOpened,
    this.draftsRoot,
    this.clientFactory,
    this.projectResolverFactory,
    this.jwtProvider,
    this.loadCachedHome,
    this.saveCachedHome,
    this.timings = const StallTimings(),
  }) : _homeStore = TaskHomeStore(deviceId: deviceId) {
    // Persisted task-home anchors + local delete tombstones (design
    // 10-15): fire-and-forget like every store load — until it lands the
    // directory keeps the cold-pick behavior; one notify re-groups rows
    // once the disk state has merged in.
    unawaited(_homeStore.load().then((_) {
      // Only a disk state that actually merged in is worth a re-group
      // notify; an empty/cold store must not add noise notifies.
      if (!_disposed && _homeStore.hasPersistedState) notifyListeners();
    }));
    // Composer drafts (design 10-20): fire-and-forget warm-up like the
    // home store; page ops await the load themselves, so this only
    // front-runs the first restore. No notify — nothing listens.
    unawaited(_chatDraftStore.load());
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

  /// Test seam overriding the live bridge gate in [callChannel].
  WorkspaceGate? _testGate;

  bool _disposed = false;
  bool _connecting = false;
  bool _openingWorkspace = false;
  bool _kicked = false;
  String? _error;

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

  /// Relay-level task list (`Dg` model from bootstrap /
  /// workspace-list-updated): every workspace's tasks with
  /// displayStatus/pinned/archived/unreadAt. The web mobile home renders
  /// non-active workspaces (and the archive view) from exactly this list.
  List<Map<String, dynamic>> _relayTasks = [];

  /// Persisted home anchors + local delete tombstones (design 10-15,
  /// [TaskHomeStore] — SharedPreferences, per-device keys). Replaces the
  /// 10-02 pure-memory sticky-home map and the 10-02 in-memory delete
  /// set: both survive restarts now, so a confirmed home keeps its group
  /// and a deleted task cannot resurrect from a surviving mirror copy.
  /// Writes go through the store (memory-sync + fire-and-forget save);
  /// the directory reads its live views, so every update re-merges on the
  /// next rebuild.
  final TaskHomeStore _homeStore;

  /// Last live sessions-index snapshot per workspace key (design
  /// 10-15-task-live-snapshot-cache §数据结构): the merge layer's gap
  /// filler while a workspace is NOT the subscribed one. Switching
  /// workspaces disposes the old subscription, and a session whose registry
  /// row is still stuck in the desktop's stale overview cache would
  /// otherwise vanish from the list until the workspace is re-entered.
  /// Pure in-memory, no TTL, no cap (workspace counts are tiny); cleared
  /// with the rest of the directory state on suspend; whole-map replaced
  /// by each fresh first frame of the same key.
  final Map<String, List<SessionEntry>> _liveSnapshots = {};

  /// Cross-terminal deletion tombstones (task 10-06 chat tombstone):
  /// session ids that VANISHED from the live sessions-index while this
  /// session held the subscription — the desktop-side signal that another
  /// terminal deleted the session (app-initiated deletes land in the
  /// home store's local tombstones instead; the index-disappearance path
  /// also records them here, harmless — the page for such a session is
  /// already exiting). Consumed by the chat page through
  /// [ChatGateway.isSessionDeleted]. Add-only in memory (session ids are
  /// never reused); the open chat page drops its own id on dispose
  /// ([forgetDeletedSession]).
  final Set<String> _deletedSessionIds = <String>{};

  /// Authoritative subscribe refusals (10-11 sessionNotFound terminal):
  /// session ids the desktop's subscribe channel refused with
  /// `fault.subscribe.sessionNotFound`. Distinct from
  /// [_deletedSessionIds] in EPISTEMIC STATUS, not in UI form: the
  /// tombstone set holds sessions-index diff INFERENCE (revocable), this
  /// holds the channel's AUTHORITATIVE rejection (a session that is not
  /// active and not persisted cannot come back on this link). Two entry
  /// points: the initial open's subscribe throw, and a live
  /// subscription's terminal-failure broadcast (the resubscribe path —
  /// no more retry timers once here). Consumed by the chat page through
  /// [ChatGateway.isSessionMissing]; the page drops its own id on dispose
  /// ([forgetMissingSession]) — same reader-recovery shape as the
  /// tombstone set.
  final Set<String> _sessionMissingIds = <String>{};

  /// Diff baseline of [recordVanishedSessions], tagged with the workspace
  /// key AND the subscription generation they belong to. Two sets with
  /// different refresh rules (see [recordVanishedSessions]):
  /// [snapshotIds] holds only SNAPSHOT-confirmed ids (snapshot omissions
  /// are diffed against it — a delta-admitted id missing from a re-seeded
  /// snapshot is re-seed lag, not a deletion); [seenIds] additionally
  /// holds delta-admitted ids (an explicit `session.removed` delta is
  /// trusted for every id the state held). Cleared on every workspace
  /// open (new subscription), and invalidated by generation: every
  /// successful resubscribe of [_sessionsSub] (the ~45s bridge swing's
  /// `_resubscribe`, `SessionsIndexSubscription.generation`) starts a new
  /// generation whose first frames may only ESTABLISH a fresh baseline —
  /// never diff against a foreign one (10-11 tombstone false positive).
  ({String? key, int gen, Set<String> snapshotIds, Set<String> seenIds})?
  _indexDiffBase;

  /// Well-known `app-error` reason of the last fatal failure (the
  /// web's `webRemoteControl.failure.*` enum); UI maps it to localized copy.
  String? _failureReason;

  @override
  DeviceStatus get status => _status;
  @override
  bool get kicked => _kicked;
  @override
  String? get error => _error;

  /// Reason code (`session-not-found`, `session-conflict`,
  /// `unsupported-action`, ...) of the current failure, if any.
  String? get failureReason => _failureReason;

  /// Relay task list (raw `Dg` maps).
  @override
  List<Map<String, dynamic>> get relayTasks => _relayTasks;

  /// Whether the latest bootstrap carried an authoritative `tasks` list
  /// (legacy V1 wire, desktops ≤3.15). 3.16.2 dropped the field — the task
  /// list then rides the channel leg (`zcode-task.listTaskList`) instead.
  /// Kept private; the leg decision lives in [_applyRelayOverview] /
  /// [_refreshRelayTasksFromChannel].
  bool _tasksFromBootstrap = false;

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
        _relayTasks = _normalizeRelayTasks(deduped.values);
        reconcileTaskHomes();
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
        if (_relayTasks.isEmpty) return;
        final res = await _overviewProbe.run(
          'listPinnedTaskIds',
          const ['listPinnedTaskIds'],
        );
        if (_disposed || _client != client || res is! List) return;
        final ids = {
          for (final id in res)
            if (id is String && id.isNotEmpty) id,
        };
        _relayTasks = [
          for (final row in _relayTasks)
            {...row, 'pinned': ids.contains('${row['taskId'] ?? ''}')},
        ];
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

  /// Merged task directory (relay overview ⊕ live sessions-index),
  /// recomputed on every read — see [TaskDirectory]. Anchors and local
  /// delete tombstones read live off [_homeStore], so a write re-merges
  /// on the next rebuild without extra state. [TaskDirectory.keyAliases]
  /// rides along so [TaskDirectory.bestRelayRow]'s anchor matching
  /// canonicalizes path-spelled relay keys (check P1-2).
  @override
  TaskDirectory get taskDirectory => TaskDirectory(
        relayTasks: relayTasks,
        sessions: sessions,
        locallyDeletedTaskIds: _homeStore.locallyDeletedTaskIds,
        confirmedHomeKeys: _homeStore.homeKeys,
        keyAliases: _workspaceKeyAliases,
        groupKeyAliases: _workspaceGroupAliases,
        cachedSessions: _liveSnapshots,
      );

  /// The display group of every 3.16.2 conversation workspace: the default
  /// workspace's canonical key, else the fixed synthetic key. Computed off
  /// the VIRTUAL [workspaces] getter (fake sessions seed it through the
  /// override), so the group can never drift from the listed entry set.
  String get _conversationGroupKey {
    for (final ws in workspaces) {
      if (isConversationWorkspace(ws)) continue;
      if (ws['label'] == 'default') {
        final key = workspaceKeyOf(ws);
        if (key != null) return key;
      }
    }
    return conversationsWorkspaceKey;
  }

  /// Group-key aliases for the merged directory's row ownership: only
  /// conversation workspaces are redirected (design 10-21 A2a). Kept
  /// separate from [_workspaceKeyAliases] so general path↔identity
  /// canonicalization stays out of group assignment — a path-spelled row of
  /// an identity-spelled workspace keeps its old group (and its old
  /// open-scope fallback), while conversation rows merge into default.
  Map<String, String> get _workspaceGroupAliases {
    final groupKey = _conversationGroupKey;
    final aliases = <String, String>{};
    for (final ws in workspaces) {
      if (!isConversationWorkspace(ws)) continue;
      final key = workspaceKeyOf(ws);
      if (key != null) aliases[key] = groupKey;
      final path = ws['workspacePath'];
      if (path is String && path.isNotEmpty) aliases[path] = groupKey;
    }
    aliases.putIfAbsent(conversationsWorkspaceKey, () => groupKey);
    return aliases;
  }

  /// Workspace key alias table (check P1-2, 2026-10-15): every listed
  /// workspace contributes `workspacePath → workspaceKeyOf(ws)` plus the
  /// canonical key mapping to itself. The live channel spells keys in the
  /// workspaceKeyOf form (liveKeyOf falls back to
  /// subscribedWorkspaceKey = workspaceKeyOf), relay rows the path form —
  /// one workspace, two strings. Every anchor write / comparison
  /// canonicalizes through this so the same workspace can never be misread
  /// as a move. Computed at every use point off the VIRTUAL [workspaces]
  /// getter (the fake session seeds it through the override) — always
  /// fresh, no staleness window of its own.
  ///
  /// 3.16.2 conversation workspaces additionally alias to the default
  /// workspace group (design 10-21 A2a): the desktop hides them from
  /// workspace pickers by default, so their rows merge into the default
  /// card instead of each draft directory owning one. The group key is the
  /// FIXED [conversationsWorkspaceKey] when no default workspace is
  /// listed — never the first conversation path (frame order must not move
  /// the group). The synthetic key itself maps to the same target so
  /// normalization is idempotent whichever spelling a caller starts from.
  Map<String, String> get _workspaceKeyAliases {
    final conversationKey = _conversationGroupKey;
    final aliases = <String, String>{};
    for (final ws in workspaces) {
      final key = workspaceKeyOf(ws);
      if (key == null) continue;
      final path = ws['workspacePath'];
      final target = isConversationWorkspace(ws) ? conversationKey : key;
      aliases[key] = target;
      if (path is String && path.isNotEmpty) aliases[path] = target;
    }
    aliases.putIfAbsent(conversationsWorkspaceKey, () => conversationKey);
    return aliases;
  }

  /// Confirms live sessions-index membership into the persisted home
  /// anchors — design 10-15 §1.1 write sources ②/③ (replacing the 10-02
  /// sticky home's unconditional write): the index is the product of
  /// `listSessions(directory = workspace)`, so membership in it IS the
  /// ground truth of a task's home (task-registry-semantics §3.2) — but
  /// only while the relay overview does not contradict itself for the id:
  /// - relay single copy → write the anchor (establish / follow / flip):
  ///   an unambiguous registry cannot be mirror pollution;
  /// - relay MULTI-copy → the anti-pollution gate: NO establish, NO flip
  ///   (the index copies disagreeing among themselves makes membership
  ///   evidence untrusted — the biggest false-anchor source of the 10-02
  ///   sticky home); a confirmation AGREEING with the existing anchor
  ///   only refreshes its timestamp (source ③ — harmless, keeps the
  ///   anchor fresh against the absence prune);
  /// - no relay row (session-only / registry window) → no establish; an
  ///   agreeing confirmation refreshes (covers ids anchored at creation
  ///   whose registry row has not landed yet).
  /// Entries without any attribution confirm nothing. Anchor write
  /// sources ①(creation, [createTaskWithMessage]) ②(single-copy live)
  /// ③(agreeing refresh) + ④(user adjudication,
  /// [correctTaskHome] — outside this gate by design). Wired to every live
  /// frame via [_onSessionsChanged]; the fake session replays the same
  /// wiring.
  void confirmLiveHomes() {
    final state = sessions;
    if (state == null || !state.ready) return;
    final aliases = _workspaceKeyAliases;
    for (final entry in state.list) {
      final raw = TaskDirectory.liveKeyOf(entry, state.subscribedWorkspaceKey);
      if (raw == null) continue;
      // 键规范化（check P1-2）：锚一律写 workspaceKeyOf 规范拼写，path
      // 拼写先归一再比较/写入。
      final key = aliases[raw] ?? raw;
      final id = entry.sessionId;
      var copies = 0;
      // The virtual getter, not the private field: the fake session seeds
      // the overview through the override. The count rides the possibly-
      // stale in-memory overview: inside a lag window a single-copy view
      // can anchor an actually-multi-copy id — that is exactly what the
      // App rendered at the time, deterministic and loss-free (check P2-5).
      for (final task in relayTasks) {
        if ('${task['taskId'] ?? ''}' == id) copies++;
      }
      if (copies == 1) {
        _homeStore.anchorHome(id, key, now: clock.now());
      } else if (_homeStore.homeKeys[id] == key) {
        // Gate holds (multi-copy) or the registry row has not landed: an
        // agreeing confirmation only refreshes the anchor it agrees with.
        _homeStore.refreshHome(id, now: clock.now());
      }
    }
  }

  /// Snapshots a ready live sessions-index into [_liveSnapshots] under its
  /// subscription key (design 10-15-task-live-snapshot-cache §写点):
  /// probe-deleted ids (the registry's add-only `deleted=1` rows — valid
  /// at snapshot time, valid forever) and locally-confirmed tombstones are
  /// filtered at this write point; the merge layer additionally re-checks
  /// the tombstones at its read point (a local delete can land between
  /// the two). Called from [_onSessionsChanged] on every frame AND from
  /// the manual first-frame catch-up in [_openWorkspaceNow] (the listener
  /// only attaches after the tombstone probe — a snapshot landing during
  /// it would be missed, same race [confirmLiveHomes] patches). Public so
  /// the fake session can replay the same wiring.
  void snapshotSessionsIntoCache(SessionsIndexState state) {
    final cacheKey = state.subscribedWorkspaceKey;
    if (cacheKey == null || cacheKey.isEmpty || !state.ready) return;
    final probeDeleted = state.deletedTaskIds;
    final localDeleted = _homeStore.locallyDeletedTaskIds;
    final rows = [
      for (final e in state.list)
        if (!probeDeleted.contains(e.sessionId) &&
            !localDeleted.contains(e.sessionId))
          e,
    ];
    final previous = _liveSnapshots[cacheKey];
    // Diagnostic (10-15 live-snapshot acceptance): only log content CHANGES —
    // the write rides every live frame, an unconditional log would flood.
    if (previous == null || _snapshotChanged(previous, rows)) {
      _log('[session] live snapshot cached: key=$cacheKey '
          'rows=${rows.length} (was ${previous?.length ?? 'none'})');
    }
    _liveSnapshots[cacheKey] = rows;
  }

  /// Content fingerprint for the snapshot-cache diagnostic: id →
  /// lastActivityAt. Map comparison, not positional — [SessionsIndexState
  /// .list] sorts by lastActivityAt only and Dart's sort is unstable, so
  /// equal-timestamp rows can swap positions across snapshots and a
  /// positional compare would false-positive (design 10-15
  /// multi-copy-stable-group §插桩, check P2-4).
  static bool _snapshotChanged(List<SessionEntry> a, List<SessionEntry> b) {
    if (a.length != b.length) return true;
    final byId = {for (final e in b) e.sessionId: e.lastActivityAt};
    for (final e in a) {
      if (byId[e.sessionId] != e.lastActivityAt) return true;
    }
    return false;
  }

  /// Anchor reconciliation + lifecycle (design 10-15 §1.1), run after
  /// every relay overview application ([_applyRelayOverview] /
  /// [_onWorkspaceListUpdated]) — never per live frame, so the stale
  /// in-memory overview can't flip an anchor the live channel owns:
  /// - tombstoned id → drop its anchor (a confirmed delete is definitive);
  /// - anchored id NOT visible in the live index whose relay set collapsed
  ///   to a single copy with a different key → obey the relay and
  ///   overwrite the anchor (the self-heal exit: post-cleanup stale
  ///   anchors AND real moves both land here). Both keys canonicalize
  ///   through [_workspaceKeyAliases] first (check P1-2: the live anchor
  ///   is workspaceKeyOf-spelled, the relay row may be path-spelled — the
  ///   SAME workspace must not read as a move). Live-visible ids are
  ///   skipped — their anchors are managed by the live confirmation
  ///   channel ([confirmLiveHomes]); the two channels must never fight
  ///   over one id.
  /// - tombstones past [TaskHomeStore.tombstoneTtl] → pruned (check P1-1:
  ///   TTL is their only removal path — a re-listing overview never lifts
  ///   a tombstone; surviving copies and stale frames re-list deleted ids
  ///   legitimately, so「复现移除」was removed).
  /// - ids absent from relay∪live for [TaskHomeStore.absenceTtl] → prune.
  /// Public so the fake session can replay the same wiring.
  void reconcileTaskHomes() {
    final liveIds = sessions?.sessions.keys.toSet() ?? const <String>{};
    final copyCounts = <String, int>{};
    final singleKeys = <String, String?>{};
    // The virtual getter, not the private field: the fake session seeds
    // the overview through the override.
    for (final task in relayTasks) {
      final id = '${task['taskId'] ?? ''}';
      if (id.isEmpty) continue;
      copyCounts[id] = (copyCounts[id] ?? 0) + 1;
      singleKeys[id] = copyCounts[id] == 1 ? TaskDirectory.relayKeyOf(task) : null;
    }
    final aliases = _workspaceKeyAliases;
    final tombstoned = _homeStore.locallyDeletedTaskIds;
    for (final id in _homeStore.homeKeys.keys.toList()) {
      if (tombstoned.contains(id)) {
        _homeStore.dropAnchor(id);
        continue;
      }
      if (liveIds.contains(id)) continue;
      if (copyCounts[id] == 1) {
        final raw = singleKeys[id];
        final key = raw == null ? null : (aliases[raw] ?? raw);
        if (key != null && key != _homeStore.homeKeys[id]) {
          _homeStore.anchorHome(id, key, now: clock.now());
        }
      }
    }
    _homeStore.pruneExpiredTombstones(now: clock.now());
    _homeStore.pruneAbsent({...liveIds, ...copyCounts.keys}, now: clock.now());
  }

  /// Live-frame signals of the active sessions-index subscription,
  /// consumed by [recordVanishedSessions] (10-11 tombstone fix): the
  /// subscription generation (bumped by every successful (re)subscribe —
  /// the bridge swing's resubscribe included) and the kind of the frame
  /// currently being applied ('snapshot' | 'deltas'; null when no frame
  /// is in flight, e.g. the post-attach baseline call in
  /// [_openWorkspaceNow]). Overridable so the fake session can replay
  /// resubscribes and drive frames without a real subscription.
  @protected
  int get indexGeneration => _sessionsSub?.generation ?? 0;
  @protected
  String? get applyingFrameKind => _sessionsSub?.applyingFrameKind;

  /// Records cross-terminal deletion tombstones from a live index frame
  /// (task 10-06 chat tombstone). Conservative by design (宁可漏报不可
  /// 误报 — a false tombstone bans sends on a live session):
  ///
  /// Diffing only happens within one subscription generation + workspace
  /// key, and the two baseline sets answer different questions
  /// (findings 10-11 §4-A/B):
  /// - A **delta** frame may only drop an id through an explicit
  ///   `session.removed` op — a trusted deletion signal. It is diffed
  ///   against [seenIds] (every id the state held, delta-admitted ones
  ///   included), so a same-generation removal delta records instantly
  ///   (10-06 red line — even for a session no snapshot confirmed yet).
  /// - A **snapshot** is a complete re-seed of the listing, so an
  ///   omission only indicts SNAPSHOT-confirmed ids
  ///   ([_indexDiffBase.snapshotIds]): a delta-admitted id missing from
  ///   a re-seeded snapshot (a bridge-rebuild or gap-resync first frame)
  ///   is re-seed lag, NOT a deletion (10-11 H1/H3). The sessions-index
  ///   is the desktop's own sidebar set (see spec
  ///   task-registry-semantics §2), so a same-generation re-snapshot
  ///   without a snapshot-confirmed id IS a deletion.
  ///
  /// Wired next to [confirmLiveHomes] on every live frame — public so
  /// the fake session can replay the same wiring
  /// (test/helpers/fake_device_session.dart).
  void recordVanishedSessions() {
    final state = sessions;
    if (state == null || !state.ready) return;
    final current = state.sessions.keys.toSet();
    final gen = indexGeneration;
    final base = _indexDiffBase;
    final fresh = base == null ||
        base.key != state.subscribedWorkspaceKey ||
        base.gen != gen;
    final delta = applyingFrameKind == 'deltas';
    if (!fresh) {
      // Delta frames only lose ids through an explicit `session.removed`
      // op (see the doc above) — every disappearance is a real deletion.
      if (delta) {
        _deletedSessionIds.addAll(base.seenIds.difference(current));
      } else {
        _deletedSessionIds.addAll(base.snapshotIds.difference(current));
      }
    }
    // Snapshots re-seed the listing: they refresh BOTH sets. Only an
    // EXPLICIT delta frame keeps snapshotIds anchored at the last
    // snapshot while seenIds tracks the delta-admitted growth — a call
    // with nothing in flight (the post-attach baseline call in
    // [_openWorkspaceNow], tests driving the state directly) refreshes
    // like a snapshot.
    if (fresh || !delta) {
      _indexDiffBase = (
        key: state.subscribedWorkspaceKey,
        gen: gen,
        snapshotIds: current,
        seenIds: current,
      );
    } else {
      _indexDiffBase = (
        key: base.key,
        gen: gen,
        snapshotIds: base.snapshotIds,
        seenIds: current,
      );
    }
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
    _error = null;
    _failureReason = null;
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
      _relayTasks = _normalizeRelayTasks([
        for (final t in tasks)
          if (t is Map) t.cast<String, dynamic>(),
      ]);
      // Push frames carry a fresh task overview: same anchor reconcile as
      // [_applyRelayOverview] (design 10-15 §1.1). The rows keep their own
      // `pinned` bits — the cross-workspace pinned merge belongs to the
      // 3.16.2 channel leg only.
      reconcileTaskHomes();
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
          _error = null;
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
    _diag('state-transition', {
      'state': s.name,
      'previousState': previous.name,
    });
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
  Future<void> openWorkspace(Map<String, dynamic> workspace, {String? taskId}) {
    final previous = _openChain;
    final completer = Completer<void>();
    _openChain = completer;
    () async {
      try {
        if (previous != null) {
          try {
            await previous.future;
          } catch (_) {}
        }
        if (_disposed) return;
        await _openWorkspaceNow(workspace, taskId: taskId);
      } finally {
        if (identical(_openChain, completer)) _openChain = null;
        completer.complete();
      }
    }();
    return completer.future;
  }

  Completer<void>? _openChain;

  Future<void> _openWorkspaceNow(
    Map<String, dynamic> workspace, {
    String? taskId,
  }) async {
    final key = workspaceKeyOf(workspace);
    final client = _client;
    if (key == null || client == null || _disposed || _openingWorkspace) {
      return;
    }
    _openingWorkspace = true;
    final sw = Stopwatch()..start();
    _listWatchdog?.cancel();
    try {
      final bridge = await client.openBridge(key, taskId: taskId);
      if (_disposed || _client != client) {
        bridge.dispose();
        return;
      }
      final oldSub = _sessionsSub;
      final oldBridge = _bridge;
      final oldChats = List.of(_chatSubs.values);
      _sessionsSub = null;
      // Fresh subscription = fresh tombstone diff baseline: the first
      // ready frame of the new index only establishes it (a workspace
      // switch must never read the previous workspace's ids as mass
      // deletions; see [recordVanishedSessions]).
      _indexDiffBase = null;
      _conversation = null;
      _chatSubs.clear();
      _bridge = bridge;
      _activeWorkspace = workspace;
      // Fresh bridge = fresh channel client: re-hang the managed listeners.
      _reattachChannelListeners();
      unawaited(oldSub?.dispose());
      for (final s in oldChats) {
        unawaited(s.dispose());
      }
      oldBridge?.dispose();

      final scope = <String, dynamic>{
        'workspacePath': workspace['workspacePath'],
        if (workspace['workspaceIdentity'] != null)
          'workspaceIdentity': workspace['workspaceIdentity'],
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
        return;
      }
      _sessionsSub = sub;
      sub.state.subscribedWorkspaceKey = key;
      // 3.16.2 project prewarm + workspace-list completion (acceptance
      // round 1 P1-2; research/07 方案 A): read the desktop's project
      // index off the createSession critical path — a handful of pages, so
      // the first create hits the cache instead of paying the read on its
      // own 30 s RPC budget — and complete the workspace list with the
      // project roots the single-window bootstrap registry omits.
      // Fire-and-forget: the resolver never throws; a create landing
      // mid-read shares the in-flight future, and a failed read leaves both
      // consumers in their pre-feature shape.
      if (params.atLeast(3, 16, 2)) {
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
        if (_disposed || _bridge != bridge) return;
        if (deleted != null) sub.state.deletedTaskIds = Set.of(deleted);
      } catch (_) {
        sub.state.deletedTaskIds = const {};
      }
      sub.state.addListener(_onSessionsChanged);
      _log('[session] workspace open ok: key=$key '
          '(${sw.elapsed.inMilliseconds}ms)');
      // A snapshot may have landed during the tombstone probe above —
      // before the listener attached. Confirm whatever is already there
      // (a no-op while the index is still empty) and baseline the
      // tombstone diff against it, so a removal delta in the very first
      // post-attach frame still finds its before-ids.
      confirmLiveHomes();
      // Same race, same patch for the snapshot cache (design §写点 调用点二).
      snapshotSessionsIntoCache(sub.state);
      recordVanishedSessions();
      _error = null;
      onWorkspaceOpened?.call(key);
      notifyListeners();
    } catch (e) {
      _log('[session] workspace open failed: $e');
      // The relay link itself is fine; only the native list is degraded —
      // surface the reason so the UI can offer retry / web fallback
      // instead of an eternal spinner.
      _error = '$e';
      notifyListeners();
    } finally {
      _openingWorkspace = false;
      sw.stop();
      // Connected-but-never-ready (open failed OR subscribed with no
      // snapshot yet) is exactly the cold-start loading bug: guard it.
      _armListWatchdog();
    }
  }

  void _onSessionsChanged() {
    if (_disposed) return;
    final sub = _sessionsSub;
    if (sub != null && sub.state.ready) {
      // Tombstones first: the notify below is what flips the chat page's
      // banner, so the set must already hold the vanished ids.
      recordVanishedSessions();
      confirmLiveHomes();
      snapshotSessionsIntoCache(sub.state);
      // First snapshot landed — the list is alive again.
      _listWatchdog?.cancel();
      _listEscalations = 0;
      _softReloadFails = 0;
    }
    notifyListeners();
  }

  /// Arms the never-ready watchdog while the task list has no snapshot.
  /// Disarmed instantly by [_onSessionsChanged] once frames arrive, and by
  /// suspend/connect teardowns via the shared cancel points.
  void _armListWatchdog() {
    _listWatchdog?.cancel();
    if (_disposed || status != DeviceStatus.connected) return;
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
    _log('[session] link stalled ($reason); rebuilding connection');
    _diag('recover-start', {'failureMessage': reason});
    unawaited(() async {
      await suspend();
      _rebuilding = false;
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
      // resurrect rows the desktop just cleared.
      _relayTasks = _normalizeRelayTasks([
        for (final t in tasks)
          if (t is Map) t.cast<String, dynamic>(),
      ]);
      // Legacy rows keep their own `pinned` bit: the cross-workspace
      // `listPinnedTaskIds` authority only applies to the 3.16.2 channel
      // leg (see [_mergePinnedTaskFlags]).
      _tasksFromBootstrap = true;
    } else {
      // 3.16.2 dropped `tasks` from bootstrap (live-probed: key absent).
      // Keep the previous rows; the channel leg replaces them on answer.
      _tasksFromBootstrap = false;
    }
    // Fresh overview = fresh anchor evidence: tombstone expiry, single-copy
    // reconcile, absence prune (design 10-15 §1.1).
    reconcileTaskHomes();
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
    if (params.atLeast(3, 16, 2) &&
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
    final merged = params.atLeast(3, 16, 2)
        ? mergeProjectWorkspaces(
            _bootstrapWorkspaces,
            _projectResolver.projectRoots,
            home: _projectResolver.knownHome,
          )
        : _bootstrapWorkspaces;
    if (_sameWorkspaces(_workspaces, merged)) return false;
    _workspaces = merged;
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
    if (!params.atLeast(3, 16, 2) || _disposed) return;
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

  /// In-flight dedup for [refreshTaskOverview].
  Future<void>? _overviewRefresh;

  /// Best-effort refresh of the relay task overview: one `client.bootstrap()`
  /// → `_workspaces`/`_relayTasks` → notify. Purpose-built for the task
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
  /// Overlapping calls share one in-flight bootstrap.
  Future<void> refreshTaskOverview() {
    final client = _client;
    if (client == null || _disposed) return Future.value();
    return _overviewRefresh ??= () async {
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
        notifyListeners();
      } catch (e) {
        _log('[session] overview refresh failed (kept old values): $e');
      } finally {
        _overviewRefresh = null;
      }
    }();
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
  /// Never throws: like the [ChatGateway] fallbacks, a listener is an
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

  /// In-flight/cached [ChatGateway.modelProviderCatalog] future.
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
        if (params.atLeast(3, 14, 0)) {
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

  /// Server-side automations of the connected desktop. Bound to the
  /// zcode-agent channel (listAllAutomations was probed there). The wire
  /// shape (scheduleRule/modelSelection/setAutomationEnabled) is gated on
  /// the desktop version — it cannot change mid-session.
  @override
  late final AutomationPort automation = AutomationPort(
    (method, args) => callChannel('zcode-agent', method, args),
    newWire: params.atLeast(3, 12, 3),
  );

  /// Off-peak tasks of the connected desktop (off-peak-task channel). The
  /// wire (lifecycle positional args, positional updateTask) and the status
  /// family (3.14 take-a-number probes) are gated on the desktop version —
  /// it cannot change mid-session.
  @override
  late final OffPeakPort offPeak = OffPeakPort(
    (method, args) => callChannel('off-peak-task', method, args),
    newWire: params.atLeast(3, 12, 3),
    statusV314: params.atLeast(3, 14, 0),
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
    final ws = _activeWorkspace;
    final key = ws == null ? null : workspaceKeyOf(ws);
    // Same alias canonicalization as anchor sources ②③④ (spec §3.8): a
    // conversation active workspace must anchor at its DISPLAY group key —
    // a raw draft-path spelling would fail bestRelayRow's canonicalized
    // anchor matching until the next reconcile.
    if (key != null) {
      final aliases = _workspaceKeyAliases;
      _homeStore.anchorHome(id, aliases[key] ?? key, now: clock.now());
    }
    return id;
  }

  // ------------------------------------------------------------ ChatGateway

  ConversationTransport get _requireConversation {
    final conv = _conversation;
    if (conv == null) throw StateError('not connected');
    return conv;
  }

  /// Conversation V4 command surface (ChatGateway): the live transport of
  /// the active workspace. Commands go straight to it — no per-command
  /// forwarding — while lifecycle (subscribe/prepare/skills) and state
  /// reading stay on the session below.
  @override
  ConversationTransport get conversationCommands => _requireConversation;

  /// Offline replayable-command queue (ChatGateway), version-gated the
  /// same way as the automation/off-peak wire gates above: pre-3.12.3
  /// desktops have no enqueueTaskCommand, so send failures surface as
  /// before instead of being queued.
  @override
  ReplayableCommandQueue? get replayableQueue {
    if (!params.atLeast(3, 12, 3)) return null;
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
  String? get remoteUrl => params.source.toString();

  /// Task metadata commands on the zcode-task channel (method names
  /// source-confirmed; probe kept as a safety net — see [TaskCommandsPort]).
  late final TaskCommandsPort taskCommands = TaskCommandsPort(
    (method, args) => callChannel('zcode-task', method, args),
    scope: _taskMutationScope,
  );

  /// Mutation 作用域按目标任务的归属工作区组装（桌面 resolveTaskAddress
  /// 按 taskId+workspacePath+workspaceIdentity 三元组寻址）；relay 概览
  /// 全工作区覆盖，查不到（冷启动未拉到/会话库私有行）回退活动工作区。
  /// 同 id 多归属行（桌面镜像行）取 [TaskDirectory.bestRelayRow] 并传入
  /// 持久锚 —— 与 TaskDirectory 合并视图完全同规则的分层 home（锚定副本
  /// 优先，否则冷启动稳定 pick），所见=所删；帧序 firstOrNull 会把
  /// mutation 寻址到非用户所见的那份孪生行（10-11 核查 V3）。
  Map<String, dynamic> _taskMutationScope(String taskId) {
    final row = TaskDirectory.bestRelayRow(
      relayTasks,
      taskId,
      homeKeys: _homeStore.homeKeys,
      // Same canonicalization the directory's visible-row pick uses
      // (check P1-2): without it the alias mismatch would leave the scope
      // on the cold pick while the UI shows the anchored copy — 所见≠所删.
      keyAliases: _workspaceKeyAliases,
    );
    if (row == null) return offPeakScope;
    return {
      'workspacePath': row['workspacePath'],
      if (row['workspaceIdentity'] != null)
        'workspaceIdentity': row['workspaceIdentity'],
    };
  }

  /// The relay home row of [taskId] as the merged directory shows it —
  /// [TaskDirectory.bestRelayRow] with THIS session's anchors and key
  /// aliases (private here, so the UI must come through this forward).
  /// Design 10-16 multi-copy-home-correction: the home-correction dialog
  /// uses it as BOTH the default selection and the「当前显示」marker — the
  /// returned row IS the row the list currently shows.
  Map<String, dynamic>? relayHomeRowOf(String taskId) =>
      TaskDirectory.bestRelayRow(
        relayTasks,
        taskId,
        homeKeys: _homeStore.homeKeys,
        keyAliases: _workspaceKeyAliases,
      );

  /// User home adjudication (anchor write source ④, design 10-16
  /// multi-copy-home-correction): the user picks the TRUE home copy among
  /// a multi-copy id's rows. Writes the anchor canonicalized through
  /// [_workspaceKeyAliases] (same spelling rule as every other anchor
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
  }) async {
    final aliases = _workspaceKeyAliases;
    final rawKey = TaskDirectory.relayKeyOf(homeCopy);
    if (rawKey != null) {
      _homeStore.anchorHome(taskId, aliases[rawKey] ?? rawKey,
          now: clock.now());
    }
    notifyListeners();
    if (!deleteOtherCopies) return;
    Object? firstError;
    // NOT identical(): _applyRelayOverview rebuilds every relay map on each
    // landing (bootstrap / 30s refresh / push / reloadTasks), so the map
    // the dialog picked may already be a stale instance by confirm time —
    // an identity test would then delete the TRUE row as a "mirror" (check
    // P1-1). Compare fields instead: same path+identity = same copy.
    final homePath = '${homeCopy['workspacePath'] ?? ''}';
    final homeIdentity = '${homeCopy['workspaceIdentity'] ?? ''}';
    for (final task in List.of(relayTasks)) {
      if ('${task['taskId'] ?? ''}' != taskId) continue;
      if ('${task['workspacePath'] ?? ''}' == homePath &&
          '${task['workspaceIdentity'] ?? ''}' == homeIdentity) {
        continue;
      }
      final path = task['workspacePath'];
      if (path is! String || path.isEmpty) continue; // unaddressable copy
      try {
        await taskCommands.delete(taskId, scope: {
          'workspacePath': path,
          if (task['workspaceIdentity'] != null)
            'workspaceIdentity': task['workspaceIdentity'],
        });
      } catch (e) {
        firstError ??= e; // keep deleting the rest, surface the first failure
      }
    }
    if (firstError != null) throw firstError;
  }

  /// Workspace file reads on the `file` channel (the desktop's fileService —
  /// the markdown-image / HTML-preview data source). Late final like the
  /// ports above; dispose needs no action. The gateway surface is the three
  /// file* forwards below — the port itself stays session-internal.
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

  /// `createSession`'s project id — the transport consults it only there.
  /// Explicit 3.16.2 gate (design decision 1): older desktops have no
  /// project layer, so nothing is read and the payload stays unchanged.
  ///
  /// A create can be the FIRST resolver consumer (no workspace opened, so
  /// the prewarm never ran): the mapping that just landed also completes
  /// the workspace list, fired without blocking the create.
  Future<String?> _projectIdForCreate(String workspacePath) async {
    if (!params.atLeast(3, 16, 2)) return null;
    final projectId = await _projectResolver.projectIdFor(workspacePath);
    if (!_disposed) unawaited(_applyProjectWorkspaceCompletion());
    return projectId;
  }

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
    _rememberLocalDelete(sessionId);
    notifyListeners();
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
    _rememberLocalDelete(sessionId);
    notifyListeners();
    return res;
  }

  /// Records a confirmed local delete (design 10-02 Step 3 + 10-15 §1.2):
  /// the id enters the PERSISTED tombstone set (surviving mirror copies
  /// can no longer resurrect it across restarts) and its home anchor —
  /// if any — drops at once (a deleted id never keeps a home).
  void _rememberLocalDelete(String sessionId) {
    _homeStore.addLocalDelete(sessionId);
    _homeStore.dropAnchor(sessionId);
  }

  @override
  Future<FileStat> fileStat(String workspacePath, String path) =>
      fileService.stat(workspacePath, path);

  @override
  Future<MediaPreview> fileReadMedia(String workspacePath, String path,
          {int? maxBytes}) =>
      fileService.readMedia(workspacePath, path, maxBytes: maxBytes);

  @override
  Future<TextChunk> fileReadText(String workspacePath, String path,
          {int offset = 0, required int length}) =>
      fileService.readText(workspacePath, path, offset: offset, length: length);

  @override
  Future<FileRange> fileReadRange(String workspacePath, String path,
          {required int offset, required int length}) =>
      fileService.readFileRange(workspacePath, path,
          offset: offset, length: length);

  /// Grouped task view of every known workspace (`zcode-task
  /// .listGroupedTaskViewStructure`, desktop 3.12.3 — live-probed
  /// 2026-09-18).
  /// Read-only 一期: group titles/colors/ordering only. Null on any miss
  /// (pre-3.12.3 desktops reject the method; no workspace open) — callers
  /// keep the flat list, no version gate (R4 silent degrade).
  Future<GroupedTaskView?> groupedTaskView() async {
    final scopes = [
      for (final ws in workspaces)
        {
          'workspacePath': ws['workspacePath'],
          if (ws['workspaceIdentity'] != null)
            'workspaceIdentity': ws['workspaceIdentity'],
        },
    ];
    if (scopes.isEmpty) return null;
    try {
      final res = await callChannel(
        'zcode-task',
        'listGroupedTaskViewStructure',
        [
          {'workspaceScopes': scopes},
        ],
      );
      return GroupedTaskView.fromMap(res);
    } catch (_) {
      return null;
    }
  }

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
      return ChatHandle(
        state: existing.state,
        close: () async {
          if (_chatSubs[sessionId] == existing) {
            _chatSubs.remove(sessionId);
            await existing.dispose();
          }
        },
      );
    }
    late final StreamSubscription<Object?> terminalSub;
    final ConversationSubscription sub;
    try {
      sub = await _requireConversation.subscribe(sessionId);
    } catch (e) {
      if (isSessionNotFoundError(e)) {
        // Initial open of a dead session (10-11): the authoritative
        // refusal arrives straight from the first subscribe — record it
        // so the page renders the「会话不存在」terminal state instead of
        // the retryable error banner, and rethrow as before.
        _sessionMissingIds.add(sessionId);
        notifyListeners();
      }
      rethrow;
    }
    _chatSubs[sessionId] = sub;
    // Resubscribe-path refusals surface through the terminal broadcast
    // (the subscription has already stopped its own retry queue); the
    // gateway notify re-runs the open page's banner builder.
    terminalSub = sub.terminalFailures.listen((_) {
      _sessionMissingIds.add(sessionId);
      notifyListeners();
    });
    return ChatHandle(
      state: sub.state,
      close: () async {
        await terminalSub.cancel();
        if (_chatSubs[sessionId] == sub) {
          _chatSubs.remove(sessionId);
          await sub.dispose();
        }
      },
    );
  }

  @override
  Future<WorkspacePrep> prepareWorkspace() async {
    if (params.atLeast(3, 12, 3)) {
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
          taskConfigOptionsArgs(_relayTasks.firstOrNull, scope),
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
  bool isSessionDeleted(String sessionId) =>
      _deletedSessionIds.contains(sessionId);

  @override
  void forgetDeletedSession(String sessionId) {
    _deletedSessionIds.remove(sessionId);
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
    if (!params.atLeast(3, 12, 3)) {
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
    if (params.atLeast(3, 12, 3)) {
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
    if (!params.atLeast(3, 12, 3)) {
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
    if (!params.atLeast(3, 12, 3)) {
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
    if (!params.atLeast(3, 12, 3)) {
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
    final chats = List.of(_chatSubs.values);
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
    _activeWorkspace = null;
    _bootstrapWorkspaces = [];
    _workspaces = [];
    _relayTasks = [];
    _tasksFromBootstrap = false;
    _tasksRefresh = null;
    _pinnedMerge = null;
    // A project read in flight belongs to the closed link; a fresh
    // connection must start its own instead of joining the old answer
    // (whose late-merge guard would drop it anyway).
    _projectWorkspaceRefresh = null;
    // Snapshot cache dies with the rest of the directory state — a rebuild
    // is a cold start (design §清点). Retry loops don't pass through here,
    // so a flapping link keeps its cached rows.
    if (_liveSnapshots.isNotEmpty) {
      _log('[session] live snapshots cleared (${_liveSnapshots.length} keys)');
    }
    _liveSnapshots.clear();
    _failureReason = null;
    _kicked = false;
    _error = null;
    _setStatus(DeviceStatus.disconnected);
    await _failureSub?.cancel();
    _failureSub = null;
    await _wsListSub?.cancel();
    _wsListSub = null;
    await _appErrSub?.cancel();
    _appErrSub = null;
    unawaited(sub?.dispose());
    for (final s in chats) {
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

  void _log(String line) => debugPrint('[$deviceId] $line');
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
