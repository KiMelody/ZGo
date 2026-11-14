// R7 lifetime/preflight tests for task 11-13-command-reconcile step 8.
//
// Group 1 drives the REAL DeviceSession: a suspended command's resend must
// first restore the entry's session onto the active bridge (open its
// workspace + subscribe) through the app's own resume path, and only then
// let the envelope out. Acceptance Run B showed the desktop refusing a
// resend after the bridge drifted to another workspace.
//
// Group 2 covers the lifetime move: suspend + connect replaces the whole
// link, but the SAME ledger instance must survive and the fresh bridge must
// run the compensation query (Run C observed zero compensation because the
// old ledger died with its bridge).
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/connection_params.dart';
import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/protocol/ipc_codec.dart';
import 'package:zgo/protocol/remote_client.dart';
import 'package:zgo/state/device_session.dart';

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

Map<String, dynamic> _ws(String path) => {'workspacePath': path};

typedef _OpenCall = ({
  String key,
  String? taskId,
  Map<String, dynamic>? project,
  String? taskHostId,
});

/// Records opens and hands out scripted bridges (session_restore harness
/// pattern: two listed workspaces, one bridge per open).
class _ScriptedClient extends RemoteClient {
  _ScriptedClient(super.params);

  final opens = <_OpenCall>[];
  Future<BridgeSession> Function(_OpenCall call)? handler;
  List<Map<String, dynamic>> bootstrapWorkspaces = const [];
  List<Map<String, dynamic>> bootstrapTasks = const [];
  String? desktopAppVersion;

  @override
  Future<void> connect() => Future.value();

  @override
  Future<void> waitPaired({Duration timeout = const Duration(seconds: 60)}) =>
      Future.value();

  @override
  Future<Map<String, dynamic>> bootstrap() async => {
        'workspaces': bootstrapWorkspaces,
        'tasks': bootstrapTasks,
        if (desktopAppVersion != null) 'desktopAppVersion': desktopAppVersion!,
      };

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

/// Live bridge stand-in answering the conversation handshake, both
/// subscribes, command sends and the single-leg reconciliation query. Every
/// observable order lands in [events] so a test can assert
/// subscribe-before-resend.
class _FakeBridge implements BridgeSession {
  _FakeBridge(this.harness);

  final _Harness harness;
  final events = <String>[];
  final conversationSubscribes = <String>[];
  final envelopes = <Map<String, dynamic>>[];
  final queries = <List<Map<String, dynamic>>>[];

  @override
  String? workspaceKey;

  @override
  late final ChannelClient channels = _buildChannels();

  ChannelClient _buildChannels() {
    late final ChannelClient client;
    client = ChannelClient(sendBody: (body) {
      final reader = ValueReader(body);
      final header = decodeValue(reader) as List;
      final decoded = decodeValue(reader);
      final args = decoded is List ? decoded : <Object?>[decoded];
      final type = (header[0] as num).toInt();
      final id = header[1] as int;
      if (type == ChannelClient.reqEventListen ||
          type == ChannelClient.reqEventDispose) {
        return;
      }
      final method = '${header[3]}';
      var resType = ChannelClient.resPromiseSuccess;
      Object? payload;
      switch (method) {
        case 'helloConversationV4':
          payload = <String, dynamic>{'connectionId': 'conn-1'};
        case 'subscribeSessionsIndexV4':
          payload = <String, dynamic>{
            'ack': <String, dynamic>{'subscriptionId': 'idx-1'},
          };
        case 'subscribeConversationV4':
          final sid = args.isNotEmpty && args.first is Map
              ? '${(args.first as Map)['sessionId'] ?? ''}'
              : '';
          conversationSubscribes.add(sid);
          events.add('subscribe:$sid');
          payload = <String, dynamic>{
            'ack': <String, dynamic>{
              'subscriptionId': 'conv-${conversationSubscribes.length}',
            },
          };
        case 'sendConversationCommandV4':
          final sendRequest = args.single as Map;
          final envelope = (sendRequest['envelope'] as Map? ?? const {})
              .cast<String, dynamic>();
          envelopes.add(envelope);
          events.add('send:${envelope['type']}');
          payload = <String, dynamic>{
            'status': 'accepted',
            'commandId': envelope['commandId'],
          };
        case 'queryConversationCommandsV4':
          final queryRequest = args.single as Map;
          final commands = [
            for (final raw in (queryRequest['commands'] as List? ?? const []))
              (raw as Map).cast<String, dynamic>(),
          ];
          queries.add(commands);
          events.add('query');
          payload = harness.queryResponder?.call(commands) ??
              _unknownReply(commands);
        default:
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

Map<String, dynamic> _unknownReply(List<Map<String, dynamic>> commands) => {
      'results': [
        for (final command in commands)
          {
            'key': {
              'sessionId': command['sessionId'],
              'commandId': command['commandId'],
            },
            'result': 'unknown',
          },
      ],
    };

/// Every addressed command answers `stale`: the reconcile loop re-enters it
/// through the host resend seam immediately.
Map<String, dynamic> _staleReply(List<Map<String, dynamic>> commands) => {
      'results': [
        for (final command in commands)
          {
            'key': {
              'sessionId': command['sessionId'],
              'commandId': command['commandId'],
            },
            'result': {
              'commandId': command['commandId'],
              'status': 'stale',
              'reasonCode': 'proto.staleRevision',
              'revisionAtDecision': 7,
            },
          },
      ],
    };

/// Two-workspace desktop; [homeOfTaskA] is the relay overview's home for
/// 'sA' (the preflight test points it away from the auto-opened workspace).
class _Harness {
  _Harness({String homeOfTaskA = '/repo/a'}) {
    client = _ScriptedClient(_params('3.16.3'))
      ..desktopAppVersion = '3.16.3'
      ..bootstrapWorkspaces = [_ws('/repo/a'), _ws('/repo/b')]
      ..bootstrapTasks = [
        {'taskId': 'sA', 'workspacePath': homeOfTaskA, 'updatedAt': 10},
        {'taskId': 'sB', 'workspacePath': '/repo/b', 'updatedAt': 9},
      ]
      ..handler = (_) async {
        final bridge = _FakeBridge(this);
        bridges.add(bridge);
        return bridge;
      };
  }

  late final _ScriptedClient client;
  final bridges = <_FakeBridge>[];
  late final DeviceSession session;

  /// Optional override for `queryConversationCommandsV4` replies; null
  /// answers the `"unknown"` sentinel for every address.
  Object? Function(List<Map<String, dynamic>> commands)? queryResponder;

  Future<void> start() async {
    session = DeviceSession(
      deviceId: 'd1',
      params: client.params,
      timings: _fastTimings,
      clientFactory: () => client,
    );
    await session.connect();
    await settle();
  }
}

Future<void> settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> pumpUntil(bool Function() condition) async {
  for (var i = 0; i < 400 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue, reason: 'condition never became true');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('resend preflight (R7)', () {
    test('opens the session workspace and subscribes before the resend '
        'envelope', () async {
      // The bridge auto-opens /repo/a, the suspended entry's session lives
      // in /repo/b: exactly the Run B drift shape.
      final h = _Harness(homeOfTaskA: '/repo/b');
      h.queryResponder = _staleReply;
      await h.start();
      addTearDown(h.session.dispose);

      final transport =
          h.session.conversationCommands as ConversationTransport;
      final ledger = transport.ledger;
      final outcomes = <CommandLedgerOutcome>[];
      final sub = ledger.outcomes.listen(outcomes.add);
      addTearDown(sub.cancel);

      ledger.record(
        commandId: 'c1',
        sessionId: 'sA',
        kind: 'sendText',
        semanticPayload: const {'text': 'hi'},
        channelExtra: const {'extra': 'x'},
      );
      ledger.suspend('c1');

      // The stale query resend must go through the host preflight first:
      // one open back to /repo/b, one subscribe, then the envelope.
      await pumpUntil(
        () => h.bridges.length == 2 && h.bridges.last.envelopes.isNotEmpty,
      );
      final fresh = h.bridges.last;
      expect(h.client.opens.last.key, '/repo/b',
          reason: 'preflight re-points the bridge at the session workspace');
      expect(fresh.conversationSubscribes, contains('sA'));
      expect(
        fresh.events.indexOf('subscribe:sA'),
        lessThan(fresh.events.indexOf('send:sendText')),
        reason: 'the session must be live before the envelope goes out',
      );
      final resend = fresh.envelopes.single;
      expect(resend['type'], 'sendText');
      expect(resend['payload'], {'text': 'hi'});
      expect('${resend['commandId']}', isNot('c1'));

      await pumpUntil(() => outcomes.isNotEmpty);
      expect(outcomes.single.settlement, CommandLedgerSettlement.delivered);
      expect(outcomes.single.rootCommandId, 'c1');
    });

    test('a live subscription skips the open/subscribe preflight', () async {
      final h = _Harness();
      h.queryResponder = _staleReply;
      await h.start();
      addTearDown(h.session.dispose);

      // The chat page is open: the session is already live on the bridge.
      await h.session.subscribe('sA');
      await settle();
      final opensBefore = h.client.opens.length;

      final transport =
          h.session.conversationCommands as ConversationTransport;
      final ledger = transport.ledger;
      final outcomes = <CommandLedgerOutcome>[];
      final sub = ledger.outcomes.listen(outcomes.add);
      addTearDown(sub.cancel);
      ledger.record(
        commandId: 'c1',
        sessionId: 'sA',
        kind: 'sendText',
        semanticPayload: const {'text': 'hi'},
      );
      ledger.suspend('c1');

      await pumpUntil(() => h.bridges.last.envelopes.isNotEmpty);
      expect(h.client.opens.length, opensBefore,
          reason: 'a live session needs no workspace reopen');
      await pumpUntil(() => outcomes.isNotEmpty);
      expect(outcomes.single.settlement, CommandLedgerSettlement.delivered);
    });
  });

  group('ledger lifetime across a whole-link rebuild (R7)', () {
    test('suspend + connect keeps the same ledger and the new bridge runs '
        'the compensation query', () async {
      final h = _Harness();
      await h.start();
      addTearDown(h.session.dispose);

      final first = h.session.conversationCommands as ConversationTransport;
      final ledger = first.ledger;
      final outcomes = <CommandLedgerOutcome>[];
      final sub = ledger.outcomes.listen(outcomes.add);
      addTearDown(sub.cancel);

      ledger.record(
        commandId: 'c1',
        sessionId: 'sA',
        kind: 'sendText',
        semanticPayload: const {'text': 'hi'},
      );
      ledger.suspend('c1');
      await pumpUntil(() => h.bridges.first.queries.isNotEmpty);
      await settle();
      expect(ledger.entry('c1')?.state, CommandLedgerState.suspended);

      // The whole link is replaced (WebView handover / KICK recovery): the
      // bridge, transport and conversation all die; the ledger must not.
      await h.session.suspend();
      await settle();
      expect(ledger.entry('c1'), isNotNull,
          reason: 'suspend detaches the ledger instead of dropping it');

      await h.session.connect();
      await pumpUntil(
        () => h.bridges.length == 2 && h.bridges.last.queries.isNotEmpty,
      );
      await settle();

      final rebuilt =
          h.session.conversationCommands as ConversationTransport;
      expect(identical(rebuilt.ledger, ledger), isTrue,
          reason: 'the new transport adopted the same ledger instance');
      expect(rebuilt.ledger.entry('c1')?.state,
          CommandLedgerState.suspended);
      expect(outcomes, isEmpty,
          reason: 'a compensation query is not a terminal outcome');
      expect(h.bridges.last.envelopes, isEmpty,
          reason: 'unknown means confirm-then-resend, never a blind resend');
    });
  });
}
