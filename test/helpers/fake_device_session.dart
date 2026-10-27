import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/state/device_session.dart';
import 'package:zgo/state/task_directory.dart';

import 'recording_chat_gateway.dart';

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
    List<Map<String, dynamic>> entries = const [],
    List<Map<String, dynamic>> workspaces = const [],
    this.relayTasks = const [],
    this.chatRows = const [],
    this.snapshotExtra = const {},
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
    // Replay the production wiring (openWorkspace attaches the session's
    // live-frame listener to the subscribed index): every frame this fake
    // delivers re-confirms the sticky home cache (design 10-02), records
    // cross-terminal deletion tombstones (task 10-06) AND snapshots into
    // the per-workspace cache (design 10-15 live-snapshot) — the seeded
    // snapshot included, same order as _onSessionsChanged.
    sessions.addListener(_onLiveFrame);
    deliver({
      'toSeq': 1,
      'payload': {
        'kind': 'snapshot',
        'snapshot': {'workspaceId': 'ws-1', 'sessions': entries},
      },
    });
  }

  void _onLiveFrame() {
    recordVanishedSessions();
    confirmLiveHomes();
    snapshotSessionsIntoCache(sessions);
  }

  /// Tombstone-diff signals (the device_session.dart override seam): the
  /// live index's subscription generation and the kind of the frame
  /// currently being applied. Tests bump [generation] to replay a
  /// bridge-swing resubscribe; [deliver] publishes the frame kind around
  /// applyFrame exactly like the production subscription does.
  int generation = 0;
  String? frameKind;

  @override
  int get indexGeneration => generation;
  @override
  String? get applyingFrameKind => frameKind;

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
  /// runs the [DeviceSession.reconcileTaskHomes] both production
  /// application points run (anchor reconcile + tombstone TTL prune +
  /// absence prune). Tests drive overview changes through this instead of
  /// poking [relayTasks] directly, so the application wiring stays
  /// guarded.
  void applyRelayOverview(List<Map<String, dynamic>> tasks) {
    relayTasks = tasks;
    reconcileTaskHomes();
  }

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

  /// Answers the open with a controllable success flag: `false` reproduces
  /// the window-gate failure path (bridge still points at the old
  /// workspace) without switching the fake's active workspace.
  bool openWorkspaceSucceeds = true;

  @override
  Future<bool> openWorkspace(
    Map<String, dynamic> workspace, {
    String? taskId,
    WorkspaceOpenPurpose? purpose,
  }) async {
    openWorkspaceCalls.add((workspace, taskId));
    openWorkspacePurposes.add(purpose);
    if (!openWorkspaceSucceeds) return false;
    _active = workspace;
    notifyListeners();
    return true;
  }

  @override
  Future<ChatHandle> subscribe(String sessionId) async {
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
    return ChatHandle(state: state, close: () async {});
  }

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
}
