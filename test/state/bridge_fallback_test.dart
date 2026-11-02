import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/connection_params.dart';
import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/protocol/ipc_codec.dart';
import 'package:zgo/protocol/remote_client.dart';
import 'package:zgo/protocol/relay_transport.dart';
import 'package:zgo/state/device_session.dart';

/// Workspace bridge window-gate fallback (3.16.3+): when the bound-window
/// registry misses the workspace, an open retries with an addressing leg —
/// `taskId + taskHostId` for an existing task (and for a new chat by
/// borrowing a task of the target workspace), or a null-project draft leg
/// for desktop-managed default/draft workspaces. These tests drive the real
/// [DeviceSession] open path with a scripted client (the bridge is a
/// stand-in, the frames are what we assert on) and the real
/// [RemoteClient.openBridge] serialization is pinned separately.

const _fastTimings = StallTimings(
  healthyWaitTimeout: Duration(milliseconds: 40),
  rpcTimeout: Duration(milliseconds: 200),
  dialTimeout: Duration(milliseconds: 60),
  listReadyTimeout: Duration(seconds: 300),
  minRebuildInterval: Duration(milliseconds: 5),
  retryBackoff: Duration(milliseconds: 60),
);

RemoteConnectionParams _params(String appVersion) =>
    RemoteConnectionParams.parse(
      'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=1&mid=m'
      '&app_version=$appVersion',
    )!;

const _windowGateMessage = 'workspace-bridge-error: 目标工作区不在当前桌面窗口中，无法创建 '
    'Web 远程控制 bridge。';

const _draftWorkspacePath = '/home/me/.zcode/workspace/default';
const _newDraftPath = '/home/me/.zcode/workspace/draft-123';

Map<String, dynamic> _ws(String path) => {'workspacePath': path};

/// Bridge stand-in that attaches but answers the sessions-index subscribe
/// with the desktop's cold-runtime refusal (`ZCODE_AGENT_RUNTIME_UNAVAILABLE`).
_FakeBridge _coldRuntimeBridge() => _FakeBridge(
      subscribeError: {
        'message': 'ZCode Agent runtime is not running.',
        'code': 'ZCODE_AGENT_RUNTIME_UNAVAILABLE',
      },
    );

typedef _OpenCall = ({
  String key,
  String? taskId,
  Map<String, dynamic>? project,
  String? taskHostId,
});

/// Records every openBridge call and answers from [handler]. The second leg
/// is distinguished by its addressing fields, exactly what the production
/// fallback passes.
class _ScriptedClient extends RemoteClient {
  _ScriptedClient(super.params, {super.transportFactory});

  final opens = <_OpenCall>[];

  Future<BridgeSession> Function(_OpenCall call)? handler;

  /// Live desktop version riding the bootstrap-response frame (null models
  /// a desktop that does not report it).
  String? desktopAppVersion;

  /// Relay overview rows the bootstrap frame carries (the channel leg is
  /// not scripted here).
  List<Map<String, dynamic>> bootstrapTasks = const [];

  /// Workspaces the bootstrap frame carries (identity-keyed entries drive
  /// the alias normalization the borrower relies on).
  List<Object> bootstrapWorkspaces = const [];

  /// One-shot failure knob for the connect-start clear test: the next
  /// bootstrap throws so the reconnect lands in `error` right after its
  /// start cleared the remembered failure.
  bool failBootstrapOnce = false;

  @override
  Future<void> connect() => Future.value();

  @override
  Future<void> waitPaired({Duration timeout = const Duration(seconds: 60)}) =>
      Future.value();

  @override
  Future<Map<String, dynamic>> bootstrap() async {
    if (failBootstrapOnce) {
      failBootstrapOnce = false;
      throw StateError('bootstrap exploded');
    }
    return {
      'workspaces': bootstrapWorkspaces,
      'tasks': bootstrapTasks,
      if (desktopAppVersion != null) 'desktopAppVersion': desktopAppVersion!,
    };
  }

  @override
  Future<BridgeSession> openBridge(
    String workspaceKey, {
    String? taskId,
    Map<String, dynamic>? project,
    String? taskHostId,
    Duration timeout = const Duration(seconds: 30),
  }) {
    final call = (
      key: workspaceKey,
      taskId: taskId,
      project: project,
      taskHostId: taskHostId,
    );
    opens.add(call);
    final h = handler;
    if (h == null) throw StateError('openBridge is not scripted');
    return h(call);
  }

  @override
  Future<void> dispose() => Future.value();
}

/// Minimal live bridge for the session's success path: a real [ChannelClient]
/// answering the conversation handshake + sessions-index subscribe, so
/// [_openWorkspaceNow] can finish exactly like it does against a desktop.
class _FakeBridge implements BridgeSession {
  _FakeBridge({this.workspaceKey, this.subscribeError});

  /// The workspace the READY frame points at (null = same as requested).
  @override
  final String? workspaceKey;

  /// When non-null, `subscribeSessionsIndexV4` answers this 202 error map
  /// instead of the ack — the cold-runtime refusal shape
  /// (`{message, code}`).
  final Map<String, dynamic>? subscribeError;

  /// Event-listener request ids registered on [channels], so a test can
  /// deliver a `onDynamicSessionsIndexFrame` event exactly like the relay
  /// fan-out does (every listener gets the same data; the subscription's
  /// topic gate routes it).
  final List<int> _eventListenIds = [];
  int _frameSeq = 0;

  @override
  late final ChannelClient channels = _buildChannels();

  /// Number of `EventListen` registrations (one per live subscription).
  int get eventListenerCount => _eventListenIds.length;

  ChannelClient _buildChannels() {
    late final ChannelClient client;
    client = ChannelClient(sendBody: (body) {
      final reader = ValueReader(body);
      final header = decodeValue(reader) as List;
      decodeValue(reader); // the request args; answers are fixed here
      final type = (header[0] as num).toInt();
      final id = header[1] as int;
      // EventListen carries a free-form arg; the channel answers it with
      // nothing (delivery happens through `resEventFire` below).
      if (type == ChannelClient.reqEventListen) {
        _eventListenIds.add(id);
        return;
      }
      if (type == ChannelClient.reqEventDispose) return;
      final method = '${header[3]}';
      var resType = ChannelClient.resPromiseSuccess;
      Object? payload;
      if (method == 'helloConversationV4') {
        payload = <String, dynamic>{'connectionId': 'conn-1'};
      } else if (method == 'subscribeSessionsIndexV4' &&
          subscribeError != null) {
        resType = ChannelClient.resPromiseError;
        payload = subscribeError;
      } else if (method == 'subscribeSessionsIndexV4') {
        payload = <String, dynamic>{
          'ack': <String, dynamic>{'subscriptionId': 'sub-1'},
        };
      } else {
        payload = <String, dynamic>{};
      }
      final writer = ValueWriter();
      encodeValue(writer, [resType, id]);
      encodeValue(writer, payload);
      client.handleMessage(writer.toBytes());
    });
    final init = ValueWriter();
    encodeValue(init, [ChannelClient.resInitialize, 0]);
    client.handleMessage(init.toBytes());
    return client;
  }

  /// Delivers one complete sessions-index snapshot frame to every event
  /// listener registered on this bridge (the relay's fan-out shape). The
  /// topic follows the subscription scope: `sessions-index/<key>` where the
  /// key is the scope's `workspaceIdentity` when present, else its path.
  void fireIndexFrame({
    required String topic,
    required List<Map<String, dynamic>> sessions,
    String subscriptionId = 'sub-1',
  }) {
    final frame = <String, dynamic>{
      'wireVersion': 3,
      'kind': 'complete',
      'topic': topic,
      'subscriptionId': subscriptionId,
      'logicalFrameId': 'lf-${_frameSeq++}',
      'frame': {
        'topic': topic,
        'subscriptionId': subscriptionId,
        'fromSeq': 1,
        'toSeq': 1,
        'payload': {
          'kind': 'snapshot',
          'snapshot': {'workspaceId': topic, 'sessions': sessions},
        },
      },
    };
    for (final id in List.of(_eventListenIds)) {
      final writer = ValueWriter();
      encodeValue(writer, [ChannelClient.resEventFire, id]);
      encodeValue(writer, frame);
      channels.handleMessage(writer.toBytes());
    }
  }

  @override
  final ValueNotifier<int> recovered = ValueNotifier(0);

  @override
  final ValueNotifier<String?> degraded = ValueNotifier(null);

  @override
  DateTime? lastDegradedAt;

  @override
  void markDegraded(String reason) {
    lastDegradedAt = DateTime.now();
    degraded.value = reason;
  }

  @override
  Future<void> waitHealthy({
    Duration timeout = const Duration(seconds: 45),
  }) =>
      Future.value();

  @override
  ConversationTransport conversation(
    Map<String, dynamic> scope, {
    void Function(String line)? onLog,
    void Function(String channel, Object error)? onLinkLevelFailure,
    void Function(String channel)? onChannelSuccess,
    Future<String?> Function(String workspacePath)? projectIdFor,
  }) =>
      ConversationTransport(
        session: this,
        scope: scope,
        onLog: onLog,
        onLinkLevelFailure: onLinkLevelFailure,
        onChannelSuccess: onChannelSuccess,
        projectIdFor: projectIdFor,
      );

  @override
  void dispose() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<DeviceSession> _connected(
  _ScriptedClient client, {
  StallTimings timings = _fastTimings,
}) async {
  final session = DeviceSession(
    deviceId: 'd1',
    params: client.params,
    timings: timings,
    clientFactory: () => client,
  );
  await session.connect();
  return session;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('isWorkspaceWindowGateError', () {
    test('matches both desktop window-gate spellings', () {
      expect(
        isWorkspaceWindowGateError(StateError(_windowGateMessage)),
        isTrue,
      );
      expect(
        isWorkspaceWindowGateError(
          StateError('远程 workspace 不在当前窗口中，无法重连: /draft/a'),
        ),
        isTrue,
      );
    });

    test('does not treat other bridge failures as the window gate', () {
      expect(
        isWorkspaceWindowGateError(
          StateError('workspace-bridge-error: permission denied'),
        ),
        isFalse,
      );
      expect(
        isWorkspaceWindowGateError(
          TimeoutException('workspace-bridge-open timed out'),
        ),
        isFalse,
      );
    });
  });

  group('bootstrap desktop version', () {
    test('the frame desktopAppVersion is exposed for version gates', () async {
      final client = _ScriptedClient(_params('3.16.2'))
        ..desktopAppVersion = '3.16.3';
      final session = await _connected(client);
      addTearDown(session.dispose);

      expect(session.desktopAppVersion, '3.16.3');
    });
  });

  group('openWorkspace addressing fallback', () {
    test('first-leg success sends no addressing fields', () async {
      final client = _ScriptedClient(_params('3.16.3'))
        ..handler = (_) async => _FakeBridge();
      final session = await _connected(client);
      addTearDown(session.dispose);

      final opened = await session.openWorkspace(
        _ws('/repo/beta'),
        purpose: WorkspaceOpenPurpose.chatNew,
      );

      expect(opened, isA<WorkspaceOpenOpened>());
      expect(client.opens, hasLength(1));
      expect(client.opens.single.key, '/repo/beta');
      expect(client.opens.single.taskId, isNull);
      expect(client.opens.single.project, isNull);
      expect(client.opens.single.taskHostId, isNull);
      expect(session.activeWorkspace?['workspacePath'], '/repo/beta');
      expect(session.error, isNull);
    });

    test(
        'chatNew borrows the workspace task after a window miss, even when '
        'the link snapshot lags the live desktop', () async {
      // Real-device bug (2026-10-26): the paired link carried 3.16.2 while
      // the desktop was 3.16.3, so the old link-snapshot gate never sent the
      // second leg. The bootstrap-frame desktopAppVersion must win.
      final client = _ScriptedClient(_params('3.16.2'))
        ..desktopAppVersion = '3.16.3'
        ..bootstrapTasks = [
          {
            'taskId': 'task-old',
            'workspacePath': '/repo/beta',
            'updatedAt': 1,
          },
          {
            'taskId': 'task-new',
            'workspacePath': '/repo/beta',
            'updatedAt': 9,
          },
          {
            'taskId': 'task-archived',
            'workspacePath': '/repo/beta',
            'updatedAt': 99,
            'archived': true,
          },
          {
            'taskId': 'task-other',
            'workspacePath': '/repo/gamma',
            'updatedAt': 100,
          },
        ]
        ..handler = (call) async {
          if (call.taskHostId == null) throw StateError(_windowGateMessage);
          return _FakeBridge();
        };
      final session = await _connected(client);
      addTearDown(session.dispose);

      final opened = await session.openWorkspace(
        _ws('/repo/beta'),
        purpose: WorkspaceOpenPurpose.chatNew,
      );

      expect(opened, isA<WorkspaceOpenOpened>());
      expect(client.opens, hasLength(2));
      expect(client.opens[1].key, '/repo/beta');
      expect(client.opens[1].taskId, 'task-new',
          reason: 'most recently updated non-archived task of the workspace');
      expect(client.opens[1].taskHostId, 'local');
      expect(client.opens[1].project, isNull,
          reason: 'the borrowed-task leg never sends project');
      expect(session.activeWorkspace?['workspacePath'], '/repo/beta');
      expect(session.error, isNull,
          reason: 'a successful second leg is a normal open');
    });

    test('mirror copies cannot win the borrow (check W2, 10-26)', () async {
      // Pollution shape: the TARGET workspace's freshest row is a mirror
      // copy — the same id also lives in /repo/gamma. Borrowing it would
      // make the desktop prepare /repo/gamma (or worse); without an anchor
      // the multi-copy id is ambiguous and must be skipped, leaving the
      // clean single-copy row as the borrower despite losing on recency.
      final client = _ScriptedClient(_params('3.16.2'))
        ..desktopAppVersion = '3.16.3'
        ..bootstrapTasks = [
          {
            'taskId': 'task-mirror',
            'workspacePath': '/repo/beta',
            'updatedAt': 999,
          },
          {
            'taskId': 'task-mirror',
            'workspacePath': '/repo/gamma',
            'updatedAt': 1,
          },
          {
            'taskId': 'task-clean',
            'workspacePath': '/repo/beta',
            'updatedAt': 5,
          },
        ]
        ..handler = (call) async {
          if (call.taskHostId == null) throw StateError(_windowGateMessage);
          return _FakeBridge();
        };
      final session = await _connected(client);
      addTearDown(session.dispose);

      final opened = await session.openWorkspace(
        _ws('/repo/beta'),
        purpose: WorkspaceOpenPurpose.chatNew,
      );

      expect(opened, isA<WorkspaceOpenOpened>());
      expect(client.opens, hasLength(2));
      expect(client.opens[1].taskId, 'task-clean',
          reason: 'un-anchored multi-copy ids are ambiguous, not borrowed');
    });

    test('an anchored multi-copy id borrows through its anchor home only',
        () async {
      final client = _ScriptedClient(_params('3.16.2'))
        ..desktopAppVersion = '3.16.3'
        ..bootstrapTasks = [
          {
            'taskId': 'task-anchored',
            'workspacePath': '/repo/beta',
            'updatedAt': 50,
          },
          {
            'taskId': 'task-anchored',
            'workspacePath': '/repo/gamma',
            'updatedAt': 900,
          },
        ]
        ..handler = (call) async {
          if (call.taskHostId == null) throw StateError(_windowGateMessage);
          return _FakeBridge();
        };
      final session = await _connected(client);
      addTearDown(session.dispose);
      // The persisted anchor (the user's 归属纠正 write path) settles the
      // ambiguity: the id's home IS /repo/beta, so its copy there is the
      // true row and borrowable even though the mirror is fresher.
      await session.correctTaskHome('task-anchored', {
        'taskId': 'task-anchored',
        'workspacePath': '/repo/beta',
      });

      final opened = await session.openWorkspace(
        _ws('/repo/beta'),
        purpose: WorkspaceOpenPurpose.chatNew,
      );

      expect(opened, isA<WorkspaceOpenOpened>());
      expect(client.opens[1].taskId, 'task-anchored');
    });

    test('a workspace with only un-anchored mirrors stays blocked', () async {
      final client = _ScriptedClient(_params('3.16.2'))
        ..desktopAppVersion = '3.16.3'
        ..bootstrapTasks = [
          {
            'taskId': 'task-m1',
            'workspacePath': '/repo/beta',
            'updatedAt': 900,
          },
          {
            'taskId': 'task-m1',
            'workspacePath': '/repo/gamma',
            'updatedAt': 1,
          },
        ]
        ..handler = (call) async {
          throw StateError(_windowGateMessage);
        };
      final session = await _connected(client);
      addTearDown(session.dispose);

      final opened = await session.openWorkspace(
        _ws('/repo/beta'),
        purpose: WorkspaceOpenPurpose.chatNew,
      );

      expect(opened, isA<WorkspaceOpenUnreachable>());
      expect(client.opens, hasLength(1),
          reason: 'no borrowable row and a project path — no second leg');
    });

    test('an identity-keyed workspace borrows its path-keyed rows (W1)',
        () async {
      // The workspace lists with an identity; its relay rows carry only the
      // path until the overview leg normalizes them — alias normalization
      // must bridge the two spellings or the borrow silently never fires.
      final client = _ScriptedClient(_params('3.16.2'))
        ..desktopAppVersion = '3.16.3'
        ..bootstrapWorkspaces = [
          {
            'workspacePath': '/repo/beta',
            'workspaceIdentity': 'beta-id',
            'label': 'beta',
          },
        ]
        ..bootstrapTasks = [
          {'taskId': 'task-p', 'workspacePath': '/repo/beta', 'updatedAt': 3},
        ]
        ..handler = (call) async {
          if (call.taskHostId == null) throw StateError(_windowGateMessage);
          return _FakeBridge();
        };
      final session = await _connected(client);
      addTearDown(session.dispose);

      final opened = await session.openWorkspace(
        {
          'workspacePath': '/repo/beta',
          'workspaceIdentity': 'beta-id',
          'label': 'beta',
        },
        purpose: WorkspaceOpenPurpose.chatNew,
      );

      expect(opened, isA<WorkspaceOpenOpened>());
      // opens: [auto-open(first workspace), first leg, borrowed leg]
      expect(client.opens.last.taskId, 'task-p',
          reason: 'path-keyed row normalizes onto the identity key');
    });

  test('default/draft workspaces without tasks use the null-project leg',
        () async {
      final client = _ScriptedClient(_params('3.16.2'))
        ..desktopAppVersion = '3.16.3'
        ..handler = (call) async {
          if (call.project == null) throw StateError(_windowGateMessage);
          // Live-probed formB: the desktop prepares a NEW draft workspace.
          return _FakeBridge(workspaceKey: _newDraftPath);
        };
      final session = await _connected(client);
      addTearDown(session.dispose);

      final opened = await session.openWorkspace(
        _ws(_draftWorkspacePath),
        purpose: WorkspaceOpenPurpose.chatNew,
      );

      expect(opened, isA<WorkspaceOpenOpened>());
      expect(client.opens, hasLength(2));
      expect(client.opens[1].project, {
        'projectId': null,
        'hostId': 'local',
      });
      expect(client.opens[1].taskId, isNull,
          reason: 'project addressing is mutually exclusive with taskId');
      expect(session.activeWorkspace?['workspacePath'], _newDraftPath,
          reason: 'the reply workspaceKey is the workspace that opened');
      expect(session.sessions?.subscribedWorkspaceKey, _newDraftPath,
          reason: 'the subscription follows the bridge, not the request');
      expect(session.chatWorkspaceId, _newDraftPath,
          reason: 'createSession must land in the prepared draft workspace');
      expect(session.error, isNull);
    });

    test('a task-less project workspace has no viable addressing leg',
        () async {
      final client = _ScriptedClient(_params('3.16.3'))
        ..handler = (_) async => throw StateError(_windowGateMessage);
      final session = await _connected(client);
      addTearDown(session.dispose);

      final opened = await session.openWorkspace(
        _ws('/repo/beta'),
        purpose: WorkspaceOpenPurpose.chatNew,
      );

      expect(opened, isA<WorkspaceOpenUnreachable>());
      expect(client.opens, hasLength(1),
          reason: 'no borrowed task and not desktop-managed: formA is '
              'rejected by 3.16.3 (project.not-found), so no second send');
      expect(session.lastWorkspaceOpenFailure,
          isA<WorkspaceOpenUnreachable>());
      expect(session.activeWorkspace, isNull);
    });

    test('a cold per-workspace runtime surfaces its own result', () async {
      // Bridge attach succeeds — the runtime is per-workspace and only the
      // desktop starts it. The sessions-index subscribe then answers the
      // runtime-unavailable refusal: this is NOT the window gate, so the
      // session must surface the runtime variant (the UI localizes it to
      // actionable copy instead of "workspace is not open").
      final client = _ScriptedClient(_params('3.16.3'))
        ..handler = (_) async => _FakeBridge(
              subscribeError: {
                'message': 'ZCode Agent runtime is not running.',
                'code': 'ZCODE_AGENT_RUNTIME_UNAVAILABLE',
              },
            );
      final session = await _connected(client);
      addTearDown(session.dispose);

      final opened = await session.openWorkspace(
        _ws('/repo/beta'),
        purpose: WorkspaceOpenPurpose.openTask,
      );

      expect(opened, isA<WorkspaceOpenRuntimeNotRunning>());
      expect(session.lastWorkspaceOpenFailure,
          isA<WorkspaceOpenRuntimeNotRunning>());
      expect(session.lastWorkspaceOpenFailure,
          isNot(isA<WorkspaceOpenUnreachable>()),
          reason: 'the window-gate result would tell the user to open a '
              'workspace that is already attached');
    });

    test('a cold runtime parks the list watchdog instead of rebuilding',
        () async {
      // Reconnecting cannot start a per-workspace runtime, so the never-ready
      // watchdog must not reopen/rebuild in a loop: that would flash the
      // banner between "connecting" and the runtime copy forever. One failed
      // open, then silence until the user retries.
      const coldTimings = StallTimings(
        healthyWaitTimeout: Duration(milliseconds: 40),
        rpcTimeout: Duration(milliseconds: 200),
        dialTimeout: Duration(milliseconds: 60),
        listReadyTimeout: Duration(milliseconds: 80),
        minRebuildInterval: Duration(milliseconds: 5),
        retryBackoff: Duration(milliseconds: 60),
      );
      final client = _ScriptedClient(_params('3.16.3'))
        ..handler = (_) async => _FakeBridge(
              subscribeError: {
                'message': 'ZCode Agent runtime is not running.',
                'code': 'ZCODE_AGENT_RUNTIME_UNAVAILABLE',
              },
            );
      final session = await _connected(client, timings: coldTimings);
      addTearDown(session.dispose);

      final opened = await session.openWorkspace(
        _ws('/repo/beta'),
        purpose: WorkspaceOpenPurpose.openTask,
      );
      expect(opened, isA<WorkspaceOpenRuntimeNotRunning>());
      expect(session.lastWorkspaceOpenFailure,
          isA<WorkspaceOpenRuntimeNotRunning>());

      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(client.opens, hasLength(1),
          reason: 'the cold-runtime dead end must not feed the watchdog');
      expect(session.lastWorkspaceOpenFailure,
          isA<WorkspaceOpenRuntimeNotRunning>());
    });

    test('openTask retries with task host addressing', () async {
      final client = _ScriptedClient(_params('3.16.3'))
        ..handler = (call) async {
          if (call.taskHostId == null) throw StateError(_windowGateMessage);
          return _FakeBridge();
        };
      final session = await _connected(client);
      addTearDown(session.dispose);

      final opened = await session.openWorkspace(
        _ws('/repo/beta'),
        taskId: 'task-9',
        purpose: WorkspaceOpenPurpose.openTask,
      );

      expect(opened, isA<WorkspaceOpenOpened>());
      expect(client.opens, hasLength(2));
      expect(client.opens[1].taskId, 'task-9');
      expect(client.opens[1].taskHostId, 'local');
      expect(client.opens[1].project, isNull,
          reason: 'host addressing reuses taskId, never project');
    });

    test('an unknown desktop version falls back to the link snapshot gate',
        () async {
      final client = _ScriptedClient(_params('3.16.2'))
        ..handler = (_) async => throw StateError(_windowGateMessage);
      final session = await _connected(client);
      addTearDown(session.dispose);

      final opened = await session.openWorkspace(
        _ws(_draftWorkspacePath),
        purpose: WorkspaceOpenPurpose.chatNew,
      );

      expect(opened, isA<WorkspaceOpenUnreachable>());
      expect(client.opens, hasLength(1),
          reason: 'no desktopAppVersion and a 3.16.2 link: conservative '
              'single leg');
      expect(session.lastWorkspaceOpenFailure,
          isA<WorkspaceOpenUnreachable>());
    });

    test('a live desktop version below 3.16.3 suppresses the second leg',
        () async {
      final client = _ScriptedClient(_params('3.16.3'))
        ..desktopAppVersion = '3.16.2'
        ..handler = (_) async => throw StateError(_windowGateMessage);
      final session = await _connected(client);
      addTearDown(session.dispose);

      final opened = await session.openWorkspace(
        _ws(_draftWorkspacePath),
        purpose: WorkspaceOpenPurpose.chatNew,
      );

      expect(opened, isA<WorkspaceOpenUnreachable>());
      expect(client.opens, hasLength(1),
          reason: 'the live desktop version outranks the newer link snapshot');
      expect(session.lastWorkspaceOpenFailure,
          isA<WorkspaceOpenUnreachable>());
    });

    test('both legs failing blocks the open and keeps the error', () async {
      final client = _ScriptedClient(_params('3.16.3'))
        ..handler = (call) async {
          if (call.project == null) throw StateError(_windowGateMessage);
          throw StateError('workspace-bridge-error: project 不可用');
        };
      final session = await _connected(client);
      addTearDown(session.dispose);

      final opened = await session.openWorkspace(
        _ws(_draftWorkspacePath),
        purpose: WorkspaceOpenPurpose.chatNew,
      );

      expect(opened, isA<WorkspaceOpenUnreachable>());
      expect(client.opens, hasLength(2));
      expect(session.lastWorkspaceOpenFailure,
          isA<WorkspaceOpenUnreachable>(),
          reason: 'a dead-end window gate is localized by the UI, so the '
              'session surfaces the typed unreachable result instead of '
              'desktop text');
      expect(session.activeWorkspace, isNull);
    });

    test('a purpose-less open keeps the single-leg behavior', () async {
      final client = _ScriptedClient(_params('3.16.3'))
        ..handler = (_) async => throw StateError(_windowGateMessage);
      final session = await _connected(client);
      addTearDown(session.dispose);

      final opened = await session.openWorkspace(_ws('/repo/beta'));

      expect(opened, isA<WorkspaceOpenUnreachable>());
      expect(client.opens, hasLength(1),
          reason: 'internal opens do not opt into addressing');
    });
  });

  group('workspace switch carry-over (11-02 R3)', () {
    test('the switch seeds the old active layer (ready-only, normalized), '
        're-subscribes on the new bridge, replaces it on the first ready '
        'frame, and suspend clears everything', () async {
      final bridges = <_FakeBridge>[];
      final client = _ScriptedClient(_params('3.16.3'))
        ..desktopAppVersion = '3.16.3'
        ..bootstrapWorkspaces = [
          {'workspacePath': '/repo/a', 'workspaceIdentity': 'a-id'},
          {'workspacePath': '/repo/b'},
        ]
        ..bootstrapTasks = [
          {'taskId': 't-a', 'workspacePath': '/repo/a', 'updatedAt': 700},
          {'taskId': 't-b', 'workspacePath': '/repo/b', 'updatedAt': 600},
        ]
        ..handler = (_) async {
          final bridge = _FakeBridge();
          bridges.add(bridge);
          return bridge;
        };
      final session = await _connected(client);
      addTearDown(session.dispose);
      await _settle();

      // Reopen A with a path-only map (the shape the UI passes): the open
      // records the RAW path on the subscription while the workspace list
      // normalizes it to the identity key. The seed must speak the manager's
      // normalized spelling (P3-9).
      final reopened = await session.openWorkspace(_ws('/repo/a'));
      expect(reopened, isA<WorkspaceOpenOpened>());
      await _settle();
      // The first open has no oldSub at all, so the seam's ready-only guard
      // (manager unit case: seedStale ignores a non-ready state) is not
      // exercised here — this asserts the visible effect: nothing carried.
      expect(session.sidecarManager.indexes.containsKey('a-id'), isFalse,
          reason: 'an unsnapshotted active state would seed a fake empty '
              'card');

      final activeA = session.sessions!;
      expect(activeA.subscribedWorkspaceKey, '/repo/a',
          reason: 'the open path records the raw active key');
      bridges.last.fireIndexFrame(
        topic: 'sessions-index//repo/a',
        sessions: [
          {'sessionId': 't-a', 'title': 'live-a', 'phase': 'running'},
        ],
      );
      expect(activeA.ready, isTrue);

      // Switch A -> B: the old active state is handed over as a stale layer
      // before `_activeWorkspace` moves, and the sidecars detach (data
      // kept) instead of being disposed.
      final opened = await session.openWorkspace(_ws('/repo/b'));
      expect(opened, isA<WorkspaceOpenOpened>());
      await _settle();

      final indexes = session.sidecarManager.indexes;
      expect(indexes['a-id'], same(activeA),
          reason: 'the ready old active state survives the bridge switch '
              '(P1-2 seed under the normalized key)');
      expect(activeA.subscribedWorkspaceKey, 'a-id',
          reason: 'the seed rewrites the raw open key to the canonical one');
      expect(session.sidecarReadiness['a-id'], isTrue,
          reason: 'ready carry-over data keeps the card on the live layer');

      final carried = session.taskDirectory.allEntries()
          .firstWhere((e) => e.$1.sessionId == 't-a');
      expect(carried.$1.phase, 'running',
          reason: 'the run state must not flash back to the relay outcome '
              'during the switch window');

      // The new bridge's fresh subscribe is in flight. Its ack must NOT
      // replace the stale layer (P2-3): wait until both the active B and
      // the fresh A subscriptions hold event listeners.
      final freshBridge = bridges.last;
      await _pumpUntil(() => freshBridge.eventListenerCount >= 2);
      expect(indexes['a-id'], same(activeA),
          reason: 'the ack alone leaves the carry-over data in place');

      freshBridge.fireIndexFrame(
        topic: 'sessions-index/a-id',
        sessions: [
          {'sessionId': 't-a', 'title': 'fresh-a', 'phase': 'completedSuccess'},
        ],
      );
      expect(indexes['a-id'], isNot(same(activeA)),
          reason: 'the first READY frame replaces the stale layer');
      expect(indexes['a-id']!.ready, isTrue);
      expect(indexes['a-id']!.list.single.phase, 'completedSuccess');

      await session.suspend();
      expect(session.sidecarManager.indexes, isEmpty,
          reason: 'suspend is still a cold start (disposeAll)');
      expect(session.sidecarReadiness, isEmpty);
    });
  });

  group('draft send workspace guard', () {
    test('an already-active target answers opened without any RPC', () async {
      final client = _ScriptedClient(_params('3.16.3'))
        ..bootstrapWorkspaces = [
          _ws('/repo/tao'),
          _ws('/repo/chat'),
        ]
        ..handler = (_) async => _FakeBridge();
      final session = await _connected(client);
      addTearDown(session.dispose);
      final opensAfterConnect = client.opens.length;
      expect(session.workspacePath, '/repo/tao');

      final ok = await session.ensureDraftWorkspace('/repo/tao');

      expect(ok, isA<WorkspaceOpenOpened>());
      expect(client.opens, hasLength(opensAfterConnect),
          reason: 'a matching target must not re-open anything');
    });

    test('a drifted bridge is re-opened on the draft target with the '
        'addressing fallback', () async {
      final client = _ScriptedClient(_params('3.16.3'))
        ..bootstrapWorkspaces = [
          _ws('/repo/tao'),
          _ws(_draftWorkspacePath),
        ]
        ..handler = (call) async {
          if (call.key == _draftWorkspacePath && call.project == null) {
            throw StateError(_windowGateMessage);
          }
          if (call.key == _draftWorkspacePath) {
            // Live-probed formB: the desktop prepares a NEW draft workspace.
            return _FakeBridge(workspaceKey: _newDraftPath);
          }
          return _FakeBridge();
        };
      final session = await _connected(client);
      addTearDown(session.dispose);
      // The reconnect auto-open landed on the preferred (first) workspace —
      // the draft page, however, was opened in the desktop-managed one.
      expect(session.workspacePath, '/repo/tao');

      final ok = await session.ensureDraftWorkspace(_draftWorkspacePath);

      expect(ok, isA<WorkspaceOpenOpened>());
      expect(client.opens.last.key, _draftWorkspacePath);
      expect(client.opens.last.project, {'projectId': null, 'hostId': 'local'});
      expect(session.workspacePath, _newDraftPath,
          reason: 'createSession must follow the bridge reply workspace');
      expect(session.chatWorkspaceId, _newDraftPath,
          reason: 'the first create lands in the re-opened target workspace');
      expect(session.error, isNull);
    });

    test('an unreachable draft target answers with its typed failure',
        () async {
      final client = _ScriptedClient(_params('3.16.3'))
        ..bootstrapWorkspaces = [
          _ws('/repo/tao'),
          _ws('/repo/chat'),
        ]
        ..handler = (call) async {
          if (call.key == '/repo/chat') throw StateError(_windowGateMessage);
          return _FakeBridge();
        };
      final session = await _connected(client);
      addTearDown(session.dispose);

      final ok = await session.ensureDraftWorkspace('/repo/chat');

      expect(ok, isA<WorkspaceOpenUnreachable>());
      expect(session.workspacePath, '/repo/tao',
          reason: 'the bridge must stay on the previous workspace');
      expect(session.lastWorkspaceOpenFailure,
          isA<WorkspaceOpenUnreachable>(),
          reason: 'the UI localizes the typed failure and blocks the send');
    });

    test('a cold-runtime draft target answers with its typed failure',
        () async {
      final client = _ScriptedClient(_params('3.16.3'))
        ..bootstrapWorkspaces = [
          _ws('/repo/tao'),
          _ws('/repo/chat'),
        ]
        ..handler = (call) async => call.key == '/repo/chat'
            ? _FakeBridge(
                subscribeError: {
                  'message': 'ZCode Agent runtime is not running.',
                  'code': 'ZCODE_AGENT_RUNTIME_UNAVAILABLE',
                },
              )
            : _FakeBridge();
      final session = await _connected(client);
      addTearDown(session.dispose);

      final ok = await session.ensureDraftWorkspace('/repo/chat');

      expect(ok, isA<WorkspaceOpenRuntimeNotRunning>());
      expect(session.lastWorkspaceOpenFailure,
          isA<WorkspaceOpenRuntimeNotRunning>(),
          reason: 'the draft-first-send guard keeps the typed failure so the '
              'chat page can pick the runtime copy');
    });
  });

  group('workspace open result lifecycle', () {
    test('an open without a live client aborts without a recorded failure',
        () async {
      final client = _ScriptedClient(_params('3.16.3'));
      final session = DeviceSession(
        deviceId: 'd1',
        params: client.params,
        timings: _fastTimings,
        clientFactory: () => client,
      );
      addTearDown(session.dispose);

      final result = await session.openWorkspace(_ws('/repo/beta'));

      expect(result, isA<WorkspaceOpenAborted>(),
          reason: 'no client: the open never ran, which is not a failure');
      expect(session.lastWorkspaceOpenFailure, isNull);
    });

    test('an open superseded by a suspend aborts without a recorded failure',
        () async {
      final gate = Completer<BridgeSession>();
      final client = _ScriptedClient(_params('3.16.3'))
        ..handler = (_) => gate.future;
      final session = await _connected(client);
      addTearDown(session.dispose);

      final opening = session.openWorkspace(_ws('/repo/beta'));
      await session.suspend();
      gate.complete(_FakeBridge());
      final result = await opening;

      expect(result, isA<WorkspaceOpenAborted>());
      expect(session.lastWorkspaceOpenFailure, isNull);
    });

    test('a successful open clears the remembered cold-runtime failure',
        () async {
      final client = _ScriptedClient(_params('3.16.3'))
        ..handler = (_) async => _coldRuntimeBridge();
      final session = await _connected(client);
      addTearDown(session.dispose);

      await session.openWorkspace(
        _ws('/repo/beta'),
        purpose: WorkspaceOpenPurpose.openTask,
      );
      expect(session.lastWorkspaceOpenFailure,
          isA<WorkspaceOpenRuntimeNotRunning>());

      client.handler = (_) async => _FakeBridge();
      final result = await session.openWorkspace(_ws('/repo/gamma'));

      expect(result, isA<WorkspaceOpenOpened>());
      expect(session.lastWorkspaceOpenFailure, isNull,
          reason: 'any successful open clears the remembered failure');
      expect(session.error, isNull);
    });

    test('a connect start clears the remembered cold-runtime failure',
        () async {
      final relay = _CapturingRelay();
      final client = _ScriptedClient(
        _params('3.16.3'),
        transportFactory: (_) => relay,
      )..handler = (_) async => _coldRuntimeBridge();
      final session = await _connected(client);
      addTearDown(session.dispose);

      await session.openWorkspace(
        _ws('/repo/beta'),
        purpose: WorkspaceOpenPurpose.openTask,
      );
      expect(session.lastWorkspaceOpenFailure,
          isA<WorkspaceOpenRuntimeNotRunning>());

      // Move off `connected` so connect() actually dials again; the error
      // transition itself must not clear the remembered open failure.
      relay.stateNotifier.value = RelayState.error;
      expect(session.status, DeviceStatus.error);
      expect(session.lastWorkspaceOpenFailure,
          isA<WorkspaceOpenRuntimeNotRunning>());

      client.failBootstrapOnce = true;
      await session.connect();

      expect(session.status, DeviceStatus.error);
      expect(session.lastWorkspaceOpenFailure, isNull,
          reason: 'connect start resets the whole failure episode');
    });

    test('relay paired clears the remembered cold-runtime failure', () async {
      // Not clearing here would change _needsWorkspaceOpen: every task tap
      // after a transient re-pair would force an extra bridge open.
      final relay = _CapturingRelay();
      final client = _ScriptedClient(
        _params('3.16.3'),
        transportFactory: (_) => relay,
      )..handler = (_) async => _coldRuntimeBridge();
      final session = await _connected(client);
      addTearDown(session.dispose);

      await session.openWorkspace(
        _ws('/repo/beta'),
        purpose: WorkspaceOpenPurpose.openTask,
      );
      expect(session.lastWorkspaceOpenFailure,
          isA<WorkspaceOpenRuntimeNotRunning>());

      relay.stateNotifier.value = RelayState.error;
      expect(session.status, DeviceStatus.error);
      relay.stateNotifier.value = RelayState.paired;

      expect(session.status, DeviceStatus.connected);
      expect(session.lastWorkspaceOpenFailure, isNull,
          reason: 'a transient re-pair is a fresh failure episode');
    });

    test('suspend clears the remembered cold-runtime failure', () async {
      final client = _ScriptedClient(_params('3.16.3'))
        ..handler = (_) async => _coldRuntimeBridge();
      final session = await _connected(client);
      addTearDown(session.dispose);

      await session.openWorkspace(
        _ws('/repo/beta'),
        purpose: WorkspaceOpenPurpose.openTask,
      );
      expect(session.lastWorkspaceOpenFailure,
          isA<WorkspaceOpenRuntimeNotRunning>());

      await session.suspend();

      expect(session.lastWorkspaceOpenFailure, isNull);
    });
  });

  group('bridge recovery addressing', () {
    test('an addressed bridge replays taskId/taskHostId on reopen', () async {
      final relay = _CapturingRelay();
      final client = RemoteClient(
        _params('3.16.3'),
        transportFactory: (_) => relay,
      );
      addTearDown(client.dispose);

      final opening = client.openBridge(
        '/repo/a',
        taskId: 'task-1',
        taskHostId: 'local',
      );
      final openFrame = await _nextFrame(relay, 'workspace-bridge-open', 0);
      _answerReady(relay, openFrame);
      final bridge = await opening;

      final baseline = relay.sent.length;
      relay.deliver({
        'zcode_type': 'bridge-degraded',
        'bridgeSessionId': bridge.bridge['bridgeSessionId'],
        'reason': 'rpc-transport-fault',
      });
      final reconnect =
          await _nextFrame(relay, 'workspace-reconnect-request', baseline);
      _answerWindowMiss(relay, reconnect);

      final reopen = await _nextFrame(
        relay,
        'workspace-bridge-open',
        baseline + 1,
      );
      expect(reopen['taskId'], 'task-1');
      expect(reopen['taskHostId'], 'local');
      expect(
        reopen.keys.toList(),
        [
          'zcode_type',
          'requestId',
          'bridgeSessionId',
          'bridgeGeneration',
          'workspaceKey',
          'taskId',
          'taskHostId',
        ],
        reason: 'addressing fields ride at the end of the reopen frame',
      );
      _answerReady(relay, reopen);
      await _settle();
    });

    test('a plain bridge reopen frame stays byte-identical', () async {
      final relay = _CapturingRelay();
      final client = RemoteClient(
        _params('3.16.3'),
        transportFactory: (_) => relay,
      );
      addTearDown(client.dispose);

      final opening = client.openBridge('/repo/a', taskId: 'task-legacy');
      final openFrame = await _nextFrame(relay, 'workspace-bridge-open', 0);
      _answerReady(relay, openFrame);
      final bridge = await opening;

      final baseline = relay.sent.length;
      relay.deliver({
        'zcode_type': 'bridge-degraded',
        'bridgeSessionId': bridge.bridge['bridgeSessionId'],
        'reason': 'rpc-transport-fault',
      });
      final reconnect =
          await _nextFrame(relay, 'workspace-reconnect-request', baseline);
      _answerWindowMiss(relay, reconnect);

      final reopen = await _nextFrame(
        relay,
        'workspace-bridge-open',
        baseline + 1,
      );
      expect(reopen.containsKey('taskId'), isFalse,
          reason: 'a first-leg taskId needs no re-addressing');
      expect(reopen.containsKey('taskHostId'), isFalse);
      expect(reopen.containsKey('project'), isFalse);
      // Exact pre-addressing serialization: key order + values, ids aside.
      expect(
        jsonEncode(reopen),
        '{"zcode_type":"workspace-bridge-open",'
        '"requestId":"${reopen['requestId']}",'
        '"bridgeSessionId":"${reopen['bridgeSessionId']}",'
        '"bridgeGeneration":${reopen['bridgeGeneration']},'
        '"workspaceKey":"/repo/a"}',
      );
      _answerReady(relay, reopen);
      await _settle();
    });

    test('a project-leg bridge does not replay project on reopen', () async {
      final relay = _CapturingRelay();
      final client = RemoteClient(
        _params('3.16.3'),
        transportFactory: (_) => relay,
      );
      addTearDown(client.dispose);

      final opening = client.openBridge(
        '/repo/a',
        project: {'projectId': null, 'hostId': 'local'},
      );
      final openFrame = await _nextFrame(relay, 'workspace-bridge-open', 0);
      _answerReady(relay, openFrame);
      final bridge = await opening;

      final baseline = relay.sent.length;
      relay.deliver({
        'zcode_type': 'bridge-degraded',
        'bridgeSessionId': bridge.bridge['bridgeSessionId'],
        'reason': 'rpc-transport-fault',
      });
      final reconnect =
          await _nextFrame(relay, 'workspace-reconnect-request', baseline);
      _answerWindowMiss(relay, reconnect);

      final reopen = await _nextFrame(
        relay,
        'workspace-bridge-open',
        baseline + 1,
      );
      expect(reopen.containsKey('project'), isFalse,
          reason: 'replaying a draft formB would prepare a FRESH draft '
          'workspace and silently drift the bridge');
      expect(reopen.containsKey('taskId'), isFalse);
      expect(reopen.containsKey('taskHostId'), isFalse);
      _answerReady(relay, reopen);
      await _settle();
    });
  });

  group('RemoteClient.openBridge frame shape', () {
    test('addressing fields appear only when explicitly passed', () async {
      final relay = _CapturingRelay();
      final client = RemoteClient(
        _params('3.16.3'),
        transportFactory: (_) => relay,
      );
      addTearDown(client.dispose);

      final plain = client.openBridge('/repo/a');
      await _settle();
      final plainFrame = relay.sent.single;
      expect(plainFrame['workspaceKey'], '/repo/a');
      expect(plainFrame.containsKey('taskId'), isFalse);
      expect(plainFrame.containsKey('taskHostId'), isFalse);
      expect(plainFrame.containsKey('project'), isFalse);
      _answerWindowGate(relay, plainFrame);
      await expectLater(plain, throwsStateError);

      relay.sent.clear();
      final hosted = client.openBridge(
        '/repo/a',
        taskId: 't1',
        taskHostId: 'local',
      );
      await _settle();
      final hostedFrame = relay.sent.single;
      expect(hostedFrame['taskId'], 't1');
      expect(hostedFrame['taskHostId'], 'local');
      expect(hostedFrame.containsKey('project'), isFalse);
      _answerWindowGate(relay, hostedFrame);
      await expectLater(hosted, throwsStateError);

      relay.sent.clear();
      final project = client.openBridge(
        '/repo/a',
        project: {'projectId': null, 'hostId': 'local'},
      );
      await _settle();
      final projectFrame = relay.sent.single;
      expect(projectFrame['project'], {
        'projectId': null,
        'hostId': 'local',
      });
      expect(projectFrame.containsKey('taskId'), isFalse);
      _answerWindowGate(relay, projectFrame);
      await expectLater(project, throwsStateError);
    });
  });
}

/// Drains the relay stream so a request frame has been published.
Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Pumps microtasks until [condition] holds (test-side seam waits).
Future<void> _pumpUntil(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue, reason: 'condition never became true');
}

void _answerWindowGate(_CapturingRelay relay, Map<String, dynamic> frame) {
  relay.deliver({
    'zcode_type': 'workspace-bridge-error',
    'bridgeSessionId': frame['bridgeSessionId'],
    'error': '目标工作区不在当前桌面窗口中，无法创建 Web 远程控制 bridge。',
  });
}

/// Polls the sent buffer (from [from]) until a frame of [type] appears.
Future<Map<String, dynamic>> _nextFrame(
  _CapturingRelay relay,
  String type,
  int from,
) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    for (var i = from; i < relay.sent.length; i++) {
      if (relay.sent[i]['zcode_type'] == type) return relay.sent[i];
    }
    await Future<void>.delayed(Duration.zero);
  }
  throw StateError('$type frame was never sent');
}

/// Answers an open/reopen request with a READY bridge echoing the ids.
void _answerReady(_CapturingRelay relay, Map<String, dynamic> frame) {
  relay.deliver({
    'zcode_type': 'workspace-bridge-ready',
    'bridgeSessionId': frame['bridgeSessionId'],
    'bridge': {
      'bridgeSessionId': frame['bridgeSessionId'],
      'bridgeGeneration': frame['bridgeGeneration'],
      'workspaceKey': frame['workspaceKey'],
      if (frame['taskId'] != null) 'initialTaskId': frame['taskId'],
    },
  });
}

/// Answers the cheap reconnect leg with the window gate, pushing recovery
/// onto the reopen path.
void _answerWindowMiss(_CapturingRelay relay, Map<String, dynamic> frame) {
  relay.deliver({
    'zcode_type': 'workspace-reconnect-response',
    'requestId': frame['requestId'],
    'workspaceKey': frame['workspaceKey'],
    'success': false,
    'error': '远程 workspace 不在当前窗口中，无法重连',
  });
}

/// Payload-layer relay stand-in (same shape as
/// test/protocol/remote_client_transport_test.dart).
class _CapturingRelay implements RelayTransport {
  final _payloads = StreamController<Map<String, dynamic>>.broadcast();
  final _failures = StreamController<RelayFailure>.broadcast();
  final stateNotifier = ValueNotifier<RelayState>(RelayState.paired);
  final sent = <Map<String, dynamic>>[];

  @override
  Stream<Map<String, dynamic>> get payloads => _payloads.stream;

  @override
  ValueListenable<RelayState> get stateListenable => stateNotifier;

  @override
  RelayState get state => stateNotifier.value;

  @override
  Stream<RelayFailure> get failures => _failures.stream;

  @override
  Future<void> start() async {}

  @override
  void sendPayload(Map<String, dynamic> payload) => sent.add(payload);

  @override
  void sendMobileDiagnostic(String event, [Map<String, dynamic>? fields]) {}

  void deliver(Map<String, dynamic> payload) => _payloads.add(payload);

  @override
  Future<void> dispose() async {
    await _payloads.close();
    await _failures.close();
    stateNotifier.dispose();
  }
}
