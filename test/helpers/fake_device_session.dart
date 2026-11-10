import 'package:clock/clock.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/state/device_session.dart';
import 'package:zgo/state/sidecar_index_manager.dart';
import 'package:zgo/state/task_directory.dart';

import 'chat_role_fakes.dart';

/// DeviceSession subclass answering from local tables (never connects).
///
/// [channelHandler] intercepts every channel RPC (automation/off-peak ports
/// route through [DeviceSession.callChannel]): answer locally and assert on
/// [channelCalls] in tests.
class FakeDeviceSession extends DeviceSession {
  @override
  DeviceStatus status;
  @override
  final SessionsIndexState sessions;

  FakeDeviceSession({
    required super.deviceId,
    required super.params,
    super.sidecarCooldown,
    super.projectResolverFactory,
    super.taskGroupResolverFactory,
    List<Map<String, dynamic>> entries = const [],
    List<Map<String, dynamic>> workspaces = const [],
    this.relayTasks = const [],
    this.chatRows = const [],
    this.snapshotExtra = const {},
    this.desktopVersionOverride,
    this.channelHandler,
  }) : status = DeviceStatus.connected,
       sessions = SessionsIndexState(),
       super() {
    _workspaces = workspaces;
    _active = workspaces.isEmpty ? null : workspaces.first;
    // Like _openWorkspaceNow: the seeded index carries the identity of
    // the workspace it was "subscribed" to (live-only rows attribute here).
    // Recorded BEFORE the seed frame so the confirmation below sees it.
    sessions.subscribedWorkspaceKey =
        _active == null ? null : workspaceKeyOf(_active!);
    // Drive the REAL TaskHomeService wiring (design 10-29 §2.11): the fake
    // no longer replays the production listener by hand. The seeded
    // snapshot lands through the service listener exactly like a first
    // ready frame (record → confirm → snapshot), and every later
    // `sessions.applyFrame` keeps running the full production wiring.
    taskHome.setWorkspaces(workspaces);
    taskHome.setRelayTasks(relayTasks);
    taskHome.setActiveSessions(
      sessions,
      generation: () => generation,
      frameKind: () => frameKind,
    );
    deliver({
      'toSeq': 1,
      'payload': {
        'kind': 'snapshot',
        'snapshot': {'workspaceId': 'ws-1', 'sessions': entries},
      },
    });
  }

  /// Tombstone-diff signals read by the real service's listener closures:
  /// tests bump [generation] to replay a bridge-swing resubscribe;
  /// [deliver] publishes the frame kind around applyFrame exactly like the
  /// production subscription does.
  int generation = 0;
  String? frameKind;

  /// Delivers a live sessions-index frame the way
  /// [SessionsIndexSubscription] does: the frame kind is published
  /// before applyFrame (state listeners read it synchronously) and
  /// cleared after.
  void deliver(Map<String, dynamic> frame, {void Function()? onGap}) {
    frameKind = (frame['payload'] as Map?)?['kind'] as String?;
    sessions.applyFrame(frame, onGap: onGap ?? () {});
    frameKind = null;
  }

  /// A bridge-swing resubscribe: bumps the subscription generation so
  /// the next delivered frame only establishes a fresh tombstone
  /// baseline — never diffs against this generation's ids (10-11 fix).
  void resubscribeSessionsIndex() => generation++;

  late List<Map<String, dynamic>> _workspaces;

  /// Seeded relay overview tasks (`Dg`).
  @override
  List<Map<String, dynamic>> relayTasks;

  /// Overview-application seam mirroring the production wiring
  /// ([DeviceSession._applyRelayOverview] and the
  /// `workspace-list-updated` push path): replaces the relay overview AND
  /// runs the TaskHomeService.reconcileTaskHomes both production
  /// application points run (anchor reconcile + tombstone TTL prune +
  /// absence prune). Tests drive overview changes through this instead of
  /// poking [relayTasks] directly, so the application wiring stays
  /// guarded.
  void applyRelayOverview(List<Map<String, dynamic>> tasks) {
    relayTasks = tasks;
    // The real landing wiring: relay rows + anchor reconcile + sidecar
    // re-diff (TaskHomeService.applyRelayOverview).
    taskHome.applyRelayOverview(tasks);
  }

  // --- sidecar sessions-index subscriptions (design 10-28) ---

  /// Every sidecar subscribe attempt, in order: (workspace key, scope).
  final List<(String, Map<String, dynamic>)> sidecarSubscribeCalls = [];

  /// Keys whose sidecar subscription the manager disposed, in order.
  final List<String> sidecarDisposed = [];

  /// States handed out by the injected subscribe closure, by workspace key —
  /// tests drive frames through them (the manager attaches its listener).
  final Map<String, SessionsIndexState> sidecarStates = {};

  /// When true, the injected subscribe closure throws the desktop's benign
  /// cold-runtime refusal (the manager must cool the workspace down).
  bool sidecarColdRuntime = false;

  /// Optional gate the injected subscribe closure awaits before handing the
  /// state back — lets a test move the relay overview while a subscribe is
  /// still in flight (the P2-2 candidate recheck).
  Future<void>? sidecarSubscribeGate;

  /// The fake has no bridge/transport: only this one factory is replaced,
  /// and the REAL manager runs its six strategies over the fake
  /// capabilities (the three former @protected sidecar overrides are gone).
  @override
  SidecarIndexManager createSidecarManager() => SidecarIndexManager(
        subscribe: (key, scope, onSubscribeFailure) async {
          sidecarSubscribeCalls.add((key, scope));
          final gate = sidecarSubscribeGate;
          if (gate != null) await gate;
          if (sidecarColdRuntime) {
            throw ChannelRpcError(
              'ZCode Agent runtime is not running for workspace '
              '${scope['workspacePath']}',
              null,
            );
          }
          return sidecarStates[key] ??= SessionsIndexState();
        },
        dispose: (key) async {
          sidecarDisposed.add(key);
          sidecarStates.remove(key);
        },
        available: () => true,
        probeDeleted: (scope) async => null,
        relayRows: () => relayTasks,
        activeKey: () {
          final active = activeWorkspace;
          if (active == null) return null;
          return workspaceKeyOf(active);
        },
        normalizeKey: (raw) => raw,
        onChanged: notifyMergedChanged,
        isDisposed: () => debugDisposed,
        log: (line) {},
        limit: DeviceSession.sidecarWorkspaceLimit,
        cooldown: sidecarCooldown,
        clock: clock.now,
      );

  Map<String, dynamic>? _active;
  final List<Map<String, dynamic>> chatRows;

  /// Extra snapshot fields (queue / pendingInteractions) merged into the
  /// seeded chat feed.
  final Map<String, dynamic> snapshotExtra;

  /// Optional local answers for channel RPCs; every call is recorded in
  /// [channelCalls] regardless.
  final Future<dynamic> Function(
    String channel,
    String method,
    List<Object?> args,
  )?
  channelHandler;
  final List<(String, String, List<Object?>)> channelCalls = [];

  @override
  Future<dynamic> callChannel(
    String channel,
    String method, [
    List<Object?> args = const [],
  ]) async {
    channelCalls.add((channel, method, args));
    final handler = channelHandler;
    if (handler != null) return handler(channel, method, args);
    return null;
  }

  /// Live desktop version (bootstrap-frame `desktopAppVersion`) for this
  /// never-connecting fake. The capability matrix reads the public
  /// [desktopAppVersion] getter, so setting this moves every
  /// live-then-snapshot capability exactly like a real bootstrap would.
  String? desktopVersionOverride;

  @override
  String? get desktopAppVersion =>
      desktopVersionOverride ?? super.desktopAppVersion;

  @override
  List<Map<String, dynamic>> get workspaces => _workspaces;
  @override
  Map<String, dynamic>? get activeWorkspace => _active;

  /// Like production: the active workspace's absolute path (the file
  /// channel ports and the search page's file probe read it).
  @override
  String? get workspacePath => _active?['workspacePath'] as String?;

  /// Seeded failure reason (app-error / close-code mapping).
  @override
  String? failureReason;

  /// Seeded degraded-link error (null = healthy).
  @override
  String? error;

  @override
  Map<String, dynamic> get offPeakScope {
    final ws = _active ?? const <String, dynamic>{};
    return {
      'workspacePath': ws['workspacePath'],
      if (ws['workspaceIdentity'] != null)
        'workspaceIdentity': ws['workspaceIdentity'],
    };
  }

  @override
  Future<void> reloadTasks() async {}

  /// Conversation V4 command surface (C1 10-05): a recording transport so
  /// the session's REAL [DeviceSession.deleteSession] — transport call +
  /// local tombstone + notify — runs end-to-end in tests (the inherited
  /// getter throws `not connected`; this fake never opens a workspace).
  /// Every call lands in [conversationCalls]; [deleteSessionResults]
  /// programs outcomes front-per-call (empty → plain accepted, an
  /// Exception entry is thrown — the fallback-failure branch).
  final List<(String, List<Object?>)> conversationCalls = [];
  final List<Object?> deleteSessionResults = [];
  late final RecordingConversationTransport _conversationCommands =
      RecordingConversationTransport(
    (method, args) {
      conversationCalls.add((method, args));
      if (method == 'deleteSession' && deleteSessionResults.isNotEmpty) {
        final next = deleteSessionResults.removeAt(0);
        if (next is Exception) throw next;
        return next;
      }
      return const {'status': 'accepted'};
    },
    () => false,
  );

  @override
  ConversationTransport get conversationCommands => _conversationCommands;

  /// Recorded [openWorkspace] calls `(workspace, taskId)` for assertions on
  /// the open path's workspace scope; [openWorkspacePurposes] keeps the
  /// purpose of each call in the same order.
  final List<(Map<String, dynamic>, String?)> openWorkspaceCalls = [];
  final List<WorkspaceOpenPurpose?> openWorkspacePurposes = [];

  /// Answers the open with a controllable result: `openWorkspaceSucceeds =
  /// false` returns [openWorkspaceFailure] (and remembers it as the latest
  /// failure) without switching the fake's active workspace.
  bool openWorkspaceSucceeds = true;

  /// The typed failure [openWorkspace] answers with when
  /// [openWorkspaceSucceeds] is false. Defaults to the window-gate dead end
  /// (the pre-existing "workspace unreachable" copy).
  WorkspaceOpenResult openWorkspaceFailure =
      const WorkspaceOpenUnreachable('window gate dead end');

  /// Latest failed open outcome — settable so UI tests can seed a banner /
  /// re-open state without driving [openWorkspace] (production keeps the
  /// same field as the single source for the watchdog and banner copy).
  @override
  WorkspaceOpenResult? lastWorkspaceOpenFailure;

  @override
  Future<WorkspaceOpenResult> openWorkspace(
    Map<String, dynamic> workspace, {
    String? taskId,
    WorkspaceOpenPurpose? purpose,
  }) async {
    openWorkspaceCalls.add((workspace, taskId));
    openWorkspacePurposes.add(purpose);
    if (!openWorkspaceSucceeds) {
      // Mirrors production: an aborted open is not a failure, so it never
      // becomes the remembered last failure.
      if (openWorkspaceFailure is! WorkspaceOpenAborted) {
        lastWorkspaceOpenFailure = openWorkspaceFailure;
      }
      return openWorkspaceFailure;
    }
    _active = workspace;
    lastWorkspaceOpenFailure = null;
    notifyListeners();
    return const WorkspaceOpenOpened();
  }

  @override
  Future<ChatHandle> subscribe(String sessionId) async {
    chatSubscribes.add(sessionId);
    final state = ConversationState();
    if (chatRows.isNotEmpty) {
      state.applyFrame({
        'toSeq': 1,
        'payload': {
          'kind': 'snapshot',
          'snapshot': {
            'sessionId': sessionId,
            'logEpoch': 'e1',
            'revision': 1,
            'rows': {'window': chatRows, 'totalCount': chatRows.length},
            ...snapshotExtra,
          },
        },
      }, onGap: () {});
    }
    return ChatHandle(
      state: state,
      close: () async {},
      revoked: () => revokedChatSessions.contains(sessionId),
    );
  }

  /// Every sessionId a subscribe was issued for, in order (orphan-resume
  /// assertions: exactly one re-subscribe per resume).
  final List<String> chatSubscribes = [];

  /// Session ids whose handles read `isRevoked` — the host-revoke simulation.
  final Set<String> revokedChatSessions = {};

  @override
  Future<WorkspacePrep> prepareWorkspace() async => WorkspacePrep.fromMap({
    'configOptions': [
      {
        'id': 'model',
        'name': '模型',
        'currentValue': 'builtin/glm-5.2',
        'options': [
          {
            'value': 'builtin/glm-5.2',
            'name': 'GLM-5.2',
            'modelProviderName': 'BigModel',
          },
          {
            'value': 'kimi/moonshot-v2',
            'name': 'Moonshot V2',
            'modelProviderName': 'kimi_zz',
          },
        ],
      },
      {
        'id': 'thought_level',
        'name': '思考等级',
        'currentValue': 'max',
        'options': [
          {'value': 'max', 'name': '最高'},
          {'value': 'high', 'name': '高'},
          {'value': 'nothink', 'name': '关闭'},
        ],
      },
    ],
    'slashCommands': [
      {'name': 'compact', 'description': '压缩上下文', 'source': 'builtin'},
    ],
  });

  @override
  Future<List<SkillEntry>> skills() async => const [];

  @override
  String? get chatWorkspaceId => 'ws-1';

  /// The fake seeds its relay overview through [applyRelayOverview] (which
  /// bypasses the production landing flag): treat the overview as landed so
  /// non-active cards keep the empty-state copy instead of the cold-start
  /// skeleton unless a test says otherwise.
  @override
  bool taskOverviewLoaded = true;
}
