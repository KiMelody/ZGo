import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../protocol/automation.dart';
import '../protocol/channel_client.dart'
    show Channels, isBridgeGateTimeoutError, isChannelLevelError, isChannelMissingError;
import '../protocol/connection_params.dart';
import '../protocol/conversation.dart';
import '../protocol/file_service.dart';
import '../protocol/method_probe.dart';
import '../protocol/model_selection.dart' show parseModelSelectionCatalog;
import '../protocol/off_peak.dart';
import '../protocol/relay_client.dart';
import '../protocol/remote_client.dart';
import '../protocol/task_commands.dart';
import '../protocol/task_groups.dart';
import 'device_store.dart';
import 'entitlement_poller.dart';
import 'link_supervisor.dart';
import 'quota_reset.dart';
import 'quota_watch.dart' show QuotaWatchSource;
import 'task_directory.dart';

/// Workspace key:
/// key = workspaceIdentity?.trim() || workspacePath.
String? workspaceKeyOf(Map<String, dynamic> w) {
  final identity = w['workspaceIdentity'];
  if (identity is String && identity.trim().isNotEmpty) {
    return identity.trim();
  }
  final path = w['workspacePath'];
  if (path is String && path.isNotEmpty) return path;
  for (final key in const ['workspaceKey', 'key', 'id']) {
    final v = w[key];
    if (v is String && v.isNotEmpty) return v;
  }
  return null;
}

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

  /// Deletes a task (`zcode-task.deleteTask`). Callers confirm first.
  Future<dynamic> deleteTask(String sessionId);

  /// mobile-view-state-update: report the task the chat UI is showing
  /// (or just the workspace when [taskId] is null).
  void sendViewState({String? taskId});

  /// `workspaceId` for draft-mode createSession, plus the workspace path
  /// for the chat page's copy action.
  String? get chatWorkspaceId;
  String? get workspacePath;

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

  /// @-mention data sources (web chat.mention.* picker).
  /// Files of the active workspace: {name, path, relativePath, type}.
  Future<List<Map<String, dynamic>>> mentionFiles();

  /// Skills (id/name/description) — same data as the $ picker.
  Future<List<Map<String, dynamic>>> mentionSkills();

  /// Subagents (name/description); empty on desktops rejecting the call.
  Future<List<Map<String, dynamic>>> mentionSubagents();

  /// Open sessions of the active workspace (id/title).
  List<({String id, String title})> mentionSessions();

  /// Skills synchronously from the last known list (mention picker reads
  /// this without awaiting a fresh RPC).
  List<Map<String, dynamic>> mentionSkillsSync();

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

  /// Relay-overview display status (`idle|running|completed|error`) of one
  /// task, read from the relay task view keyed by taskId. The shell-
  /// session error card's only signal (design 09-25 D1): a session that
  /// fails its first turn pushes `displayStatus:"error"` while its
  /// snapshot `control.phase` is unreliable. Null when that view doesn't
  /// hold the session (not yet bootstrapped / other-workspace lag) —
  /// callers must treat null as "don't render", never as an error.
  String? taskDisplayStatus(String sessionId);

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

  /// Tunable stall-defense durations (tests shrink the defaults).
  @visibleForTesting
  final StallTimings timings;

  DeviceSession({
    required this.deviceId,
    required this.params,
    this.preferredWorkspaceKey,
    this.onWorkspaceOpened,
    this.clientFactory,
    this.timings = const StallTimings(),
  });

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
  List<Map<String, dynamic>> _workspaces = [];
  Map<String, dynamic>? _activeWorkspace;

  /// Relay-level task list (`Dg` model from bootstrap /
  /// workspace-list-updated): every workspace's tasks with
  /// displayStatus/pinned/archived/unreadAt. The web mobile home renders
  /// non-active workspaces (and the archive view) from exactly this list.
  List<Map<String, dynamic>> _relayTasks = [];

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

  /// Merged task directory (relay overview ⊕ live sessions-index),
  /// recomputed on every read — see [TaskDirectory].
  @override
  TaskDirectory get taskDirectory => TaskDirectory(
        relayTasks: relayTasks,
        sessions: sessions,
      );

  /// True while a workspace bridge + sessions-index open is in flight.
  bool get openingWorkspace => _openingWorkspace;

  /// Workspaces reported by bootstrap (raw maps).
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
    final sw = Stopwatch()..start();
    final client = clientFactory != null
        ? clientFactory!()
        : RemoteClient(params, onLog: _log);
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
      _setStatus(DeviceStatus.connected);
      // Status must read connected before arming: the watchdog only guards
      // the healthy-looking-but-never-ready state.
      _armListWatchdog();
    } catch (e) {
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
  }

  void _onRelayFailure(RelayFailure failure) {
    if (_disposed) return;
    _error = '$failure';
    _failureReason ??= failure.reason;
    _kicked = _kicked || failure.reason == 'kicked';
    if (_kicked) {
      // Another terminal took over; stay quiet until the user acts.
      _retryTimer?.cancel();
    }
    notifyListeners();
  }

  /// Relay push (`workspace-list-updated {result:{workspaces, tasks?, ...}}`):
  /// the live workspace+task overview the web mobile home renders from.
  /// Workspaces merge here; task rows are re-rendered by listeners.
  void _onWorkspaceListUpdated(dynamic result) {
    if (_disposed || result is! Map) return;
    final list = result['workspaces'];
    if (list is List) {
      _workspaces = [
        for (final w in list)
          if (w is Map) w.cast<String, dynamic>(),
      ];
    }
    final tasks = result['tasks'];
    if (tasks is List) {
      _relayTasks = [
        for (final t in tasks)
          if (t is Map) t.cast<String, dynamic>(),
      ];
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

  void _setStatus(DeviceStatus s) {
    if (_status == s) return;
    _status = s;
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
    _workspaces = [
      if (list is List)
        for (final w in list)
          if (w is Map) w.cast<String, dynamic>(),
    ];
    final tasks = bootstrap['tasks'];
    _relayTasks = [
      if (tasks is List)
        for (final t in tasks)
          if (t is Map) t.cast<String, dynamic>(),
    ];
  }

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
    return conv.createSession(workspaceId, firstText: text, config: config);
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
    scope: () => offPeakScope,
  );

  /// Workspace file reads on the `file` channel (the desktop's fileService —
  /// the markdown-image / HTML-preview data source). Late final like the
  /// ports above; dispose needs no action. The gateway surface is the three
  /// file* forwards below — the port itself stays session-internal.
  late final FileServicePort fileService = FileServicePort(
    (method, args) => callChannel(Channels.file, method, args),
  );

  @override
  Future<dynamic> renameTask(String sessionId, String title) =>
      taskCommands.rename(sessionId, title);

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
  Future<dynamic> deleteTask(String sessionId) =>
      taskCommands.delete(sessionId);

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
    final sub = await _requireConversation.subscribe(sessionId);
    _chatSubs[sessionId] = sub;
    return ChatHandle(
      state: sub.state,
      close: () async {
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
  Future<List<Map<String, dynamic>>> mentionFiles() async {
    final root = workspacePath;
    if (root == null || root.isEmpty) return const [];
    try {
      final res = await callChannel('file', 'listWorkspaceFiles', [
        {'rootPath': root}
      ]);
      return res is List
          ? res.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
          : const [];
    } catch (_) {
      return const [];
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
  List<Map<String, dynamic>> mentionSkillsSync() {
    return [
      for (final s in (conversation?.lastSkills ?? const <SkillEntry>[]))
        {
          'name': s.name,
          if (s.description != null) 'description': s.description,
        },
    ];
  }

  @override
  String? taskDisplayStatus(String sessionId) {
    for (final task in _relayTasks) {
      if ('${task['taskId']}' == sessionId) {
        return task['displayStatus'] as String?;
      }
    }
    return null;
  }

  /// Session-wide entitlement poller — the usage page and the chat quota
  /// pill / warning banner share one cache per connection. Created lazily
  /// on first use and disposed with the session.
  EntitlementPoller? _entitlementPoller;

  /// Fallback plan access — the maintainer's plan. Other plans rely on the
  /// derivation in [_resolvePlanAccess] or degrade to the pre-3.12.3
  /// display until the desktop's provider registry backfills.
  static const _planAccessConstant = {
    'providerId': 'account:zai-individual-coding-plan',
    'accountAccess': {
      'type': 'zhipu-account',
      'family': 'zai',
      'planKind': 'individual-coding-plan',
    },
  };

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

  /// The coding-plan provider the 3.12.3+ quota wire targets, resolved once
  /// per session: derived from the current model selection when its provider
  /// is a coding-plan id, else the constant fallback. Cached including
  /// misses so the 5-minute entitlement refresh never stacks an extra RPC.
  Map<String, dynamic>? _planAccess;

  Future<Map<String, dynamic>> _resolvePlanAccess() async {
    final cached = _planAccess;
    if (cached != null) return cached;
    Map<String, dynamic> plan = _planAccessConstant;
    try {
      final relay = _relayTasks;
      if (relay.isNotEmpty) {
        final first = relay.first;
        final sel = await callChannel('zcode-task', 'getTaskModelSelection', [
          {
            'taskId': '${first['taskId']}',
            'workspacePath': '${first['workspacePath']}',
            if (first['workspaceIdentity'] != null)
              'workspaceIdentity': first['workspaceIdentity'],
          }
        ]);
        final providerId = sel is Map ? sel['providerId'] : null;
        if (providerId is String) {
          plan = parsePlanAccess(providerId) ?? plan;
        }
      }
    } catch (_) {
      // Best-effort derivation; the constant fallback covers it.
    }
    return _planAccess = plan;
  }

  /// usage-stats channel fetch for [_entitlementPoller]. Pre-3.12.3 the
  /// bare call is the legacy wire; 3.12.3+ gates the quota APIs on the
  /// full parameter set (accountAccess — live-probed 2026-09-17).
  /// A failing full call throws into the
  /// poller's error phase — no bare retry: on 3.12.3 the bare form answers
  /// not_configured, so a retry would add zero information.
  Future<dynamic> _fetchEntitlement() async {
    if (!params.atLeast(3, 12, 3)) {
      return callChannel('usage-stats', 'getEntitlementSnapshot', [
        {'includeSubscription': true}
      ]);
    }
    final plan = await _resolvePlanAccess();
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
    final view = await (_entitlementPoller ??=
        EntitlementPoller(fetch: _fetchEntitlement))
        .refresh(force: force);
    // The reset scope rides the snapshot (design Q2a): the session injects
    // the provider id, so consumers never touch the raw map. Same value is
    // a no-op.
    quotaResetController.updateScope(view.resetScopeProviderId);
    return view;
  }

  /// Session-wide reset-opportunity controller — lazily created like
  /// [_entitlementPoller], disposed with the session. The scope
  /// (`preferredProviderId`) is injected by [entitlementSnapshot] from
  /// the entitlement snapshot; the forwarded RPCs below read it back as
  /// the single source.
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
    // required otherwise); before the first snapshot lands the scope is
    // still null, so the resolved plan provider stands in.
    final plan = await _resolvePlanAccess();
    return callChannel('usage-stats', 'getCodingPlanResetStatus', [
      {
        'preferredProviderId':
            quotaResetController.scopeProviderId ?? plan['providerId'],
        'accountAccess': plan['accountAccess'],
      }
    ]);
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
    // probe; the status call's accepted shape validates the form).
    final plan = await _resolvePlanAccess();
    await callChannel('usage-stats', 'useCodingPlanReset', [
      {
        'preferredProviderId': preferredProviderId ?? plan['providerId'],
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
    _workspaces = [];
    _relayTasks = [];
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
    _entitlementPoller?.dispose();
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

  DeviceSessionHub({required this.nativeListEnabled});

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
