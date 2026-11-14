import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/connection_params.dart';
import 'package:zgo/state/device_session.dart';

import '../helpers/chat_role_fakes.dart';
import '../helpers/fake_device_session.dart';

/// `SideChatPort` orchestration on `DeviceSession` (design
/// 11-11-btw-side-chat §12, A2): the five host ports a chat page drives,
/// the `zcode-session.closeSession` thin wrapper (M0-d shape + fault
/// matrix), destroy over `deleteSession` (tombstone kept, idempotent for
/// the already-gone answers) and create (ack → register → tab).
///
/// The manifest/restore matrix lives in side_chat_restore_test.dart; the
/// page-observable fake surface is exercised at the bottom here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const workspacePath = r'F:\proj';
  const workspaceIdentity = 'ws-uuid';

  final params = RemoteConnectionParams.parse(
    'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1'
    '&name=songsong&app_version=3.14.0',
  )!;

  Map<String, dynamic> workspace(
    String path, {
    String? identity,
    String label = 'proj',
  }) =>
      {
        'label': label,
        'workspacePath': path,
        if (identity != null) 'workspaceIdentity': identity,
      };

  FakeDeviceSession newSession({
    Future<dynamic> Function(String, String, List<Object?>)? channel,
    List<Map<String, dynamic>>? workspaces,
  }) =>
      FakeDeviceSession(
        deviceId: 'd1',
        params: params,
        workspaces: workspaces ?? [workspace(workspacePath)],
        channelHandler: channel,
      );

  List<String> ids(FakeDeviceSession session, [String parent = 'p1']) =>
      [for (final t in session.sideChatTabs(parent)) t.sessionId];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('closeSession wire shape (M0-d)', () {
    test('carries workspacePath + sessionId, omits identity when absent and '
        'never sends expectedPersistence', () async {
      final session = newSession(channel: (c, m, a) async => null);
      session.registerSideChatTab('p1', 's1');

      await session.closeSideChatTab('p1', 's1');

      final call = session.channelCalls.last;
      expect(call.$1, Channels.zcodeSession);
      expect(call.$2, 'closeSession');
      final payload = call.$3.single as Map;
      expect(payload['workspacePath'], workspacePath,
          reason: 'the agent-process routing key is mandatory');
      expect(payload['sessionId'], 's1');
      expect(payload.containsKey('workspaceIdentity'), isFalse,
          reason: 'no identity on this workspace');
      expect(payload.containsKey('expectedPersistence'), isFalse,
          reason: 'a supplied mode can answer closed:false without closing');
    });

    test('joins workspaceIdentity when the workspace has a non-empty one',
        () async {
      final session = newSession(
        workspaces: [
          workspace(workspacePath, identity: workspaceIdentity),
        ],
        channel: (c, m, a) async => null,
      );
      session.registerSideChatTab('p1', 's1');

      await session.closeSideChatTab('p1', 's1');

      final payload = session.channelCalls.last.$3.single as Map;
      expect(payload['workspaceIdentity'], workspaceIdentity);
      expect(payload['workspacePath'], workspacePath);
    });

    test('an empty identity string is omitted, not sent blank', () async {
      final session = newSession(
        workspaces: [workspace(workspacePath, identity: '')],
        channel: (c, m, a) async => null,
      );
      session.registerSideChatTab('p1', 's1');

      await session.closeSideChatTab('p1', 's1');

      final payload = session.channelCalls.last.$3.single as Map;
      expect(payload.containsKey('workspaceIdentity'), isFalse);
    });
  });

  group('close fault matrix (design §6)', () {
    test('success: the runtime closes, the record leaves, the manifest entry '
        'survives (restorable collapse)', () async {
      final session = newSession(channel: (c, m, a) async => null);
      session.registerSideChatTab('p1', 's1');
      var notified = 0;
      session.addListener(() => notified++);

      await session.closeSideChatTab('p1', 's1');

      expect(ids(session), isEmpty);
      expect(notified, greaterThan(0));
      await session.sideChatTabStore.pendingSave;
      expect(
        session.sideChatTabStore
            .entriesOf(workspacePath, 'p1')
            .single
            .sessionId,
        's1',
        reason: 'close keeps the recovery entry (R8)',
      );
    });

    test('-32004 answers success: the local teardown still completes',
        () async {
      final session = newSession(
        channel: (c, m, a) async => throw ChannelRpcError(
          'Session is not active: s1',
          {'code': -32004},
        ),
      );
      session.registerSideChatTab('p1', 's1');

      await session.closeSideChatTab('p1', 's1');

      expect(ids(session), isEmpty);
      expect(session.channelCalls, hasLength(1),
          reason: 'no retry — the -32004 means nothing is left to close');
    });

    test('-32004 as a string code answers success too', () async {
      final session = newSession(
        channel: (c, m, a) async => throw ChannelRpcError(
          'Session is not active: s1',
          {'code': '-32004'},
        ),
      );
      session.registerSideChatTab('p1', 's1');

      await session.closeSideChatTab('p1', 's1');

      expect(ids(session), isEmpty);
    });

    test('sessionNotFound answers success (already gone)', () async {
      final session = newSession(
        channel: (c, m, a) async => throw ChannelRpcError(
          'Session is not active and not persisted: s1 '
          '(fault.subscribe.sessionNotFound)',
          {'code': 'fault.subscribe.sessionNotFound'},
        ),
      );
      session.registerSideChatTab('p1', 's1');

      await session.closeSideChatTab('p1', 's1');

      expect(ids(session), isEmpty);
    });

    test('a network fault still tears the tab down locally (lose the tab '
        'rather than stick it)', () async {
      final session = newSession(
        channel: (c, m, a) async => throw StateError('bridge exploded'),
      );
      session.registerSideChatTab('p1', 's1');
      session.registerSideChatTab('p1', 's2');

      await session.closeSideChatTab('p1', 's1');

      expect(ids(session), ['s2'],
          reason: 'the failed close must not strand the dead tab');
      expect(session.sideChatTabStore.entriesOf(workspacePath, 'p1'),
          hasLength(2), reason: 'the manifest still lists both');
    });

    test('no workspace can be resolved: the local teardown proceeds without '
        'an RPC', () async {
      final session = newSession(
        workspaces: const [],
        channel: (c, m, a) async => fail('no workspace → no closeSession'),
      );
      // The registry is workspace-agnostic; only the manifest needs a scope.
      session.registerSideChatTab('p1', 's1');
      expect(ids(session), ['s1']);

      await session.closeSideChatTab('p1', 's1');

      expect(ids(session), isEmpty);
      expect(session.channelCalls, isEmpty);
    });
  });

  group('destroy orchestration (R9/AC10)', () {
    test('soft-deletes through deleteSession (tombstone kept), drops the '
        'record and the manifest entry', () async {
      final session = newSession();
      session.registerSideChatTab('p1', 's1');
      await session.sideChatTabStore.pendingSave;

      await session.destroySideChatTab('p1', 's1');

      expect(
        session.conversationCalls.map((c) => c.$1),
        ['deleteSession'],
        reason: 'the v4 command is the destroy path — no closeSession',
      );
      expect(session.conversationCalls.single.$2, ['s1']);
      expect(session.taskHomeStore.locallyDeletedTaskIds, contains('s1'),
          reason: 'deleteSession keeps the local tombstone');
      expect(ids(session), isEmpty);
      await session.sideChatTabStore.pendingSave;
      expect(session.sideChatTabStore.entriesOf(workspacePath, 'p1'), isEmpty);
    });

    test('sessionNotFound is idempotent success: the record still goes and '
        'the tombstone is recorded', () async {
      final session = newSession();
      session.deleteSessionResults.add(ChannelRpcError(
        'Session is not active and not persisted: s1 '
        '(fault.subscribe.sessionNotFound)',
        {'code': 'fault.subscribe.sessionNotFound'},
      ));
      session.registerSideChatTab('p1', 's1');

      await session.destroySideChatTab('p1', 's1');

      expect(ids(session), isEmpty);
      expect(session.taskHomeStore.locallyDeletedTaskIds, contains('s1'),
          reason: 'the row must not resurrect after a failed delete');
    });

    test('-32004 is idempotent success too', () async {
      final session = newSession();
      session.deleteSessionResults.add(ChannelRpcError(
        'Session is not active: s1',
        {'code': -32004},
      ));
      session.registerSideChatTab('p1', 's1');

      await session.destroySideChatTab('p1', 's1');

      expect(ids(session), isEmpty);
      expect(session.taskHomeStore.locallyDeletedTaskIds, contains('s1'));
    });

    test('-32004 carried only in the message (errorObj shape) is idempotent '
        'success as well', () async {
      final session = newSession();
      session.deleteSessionResults.add(
        ChannelRpcError('Session is not active: s1 (-32004)', null),
      );
      session.registerSideChatTab('p1', 's1');

      await session.destroySideChatTab('p1', 's1');

      expect(ids(session), isEmpty);
      expect(session.taskHomeStore.locallyDeletedTaskIds, contains('s1'));
    });

    test('a real delete failure rethrows with the tab untouched (retryable)',
        () async {
      final session = newSession();
      session.deleteSessionResults.add(Exception('desktop exploded'));
      session.registerSideChatTab('p1', 's1');

      await expectLater(
        session.destroySideChatTab('p1', 's1'),
        throwsA(isA<Exception>()),
      );

      expect(ids(session), ['s1'],
          reason: 'an unknown outcome must leave the tab for a retry');
      expect(session.sideChatTabStore.entriesOf(workspacePath, 'p1'),
          hasLength(1), reason: 'a destroyed tab was never confirmed');
    });
  });

  group('create orchestration (R6/R2)', () {
    test('ack sessionId → register (persisted, ordinal) → the tab answers',
        () async {
      final session = newSession();
      session.createSelectionSideSessionResults.add('s_new');

      final tab = await session.createSideChatTab('p1', firstInput: '你好');

      expect(tab.sessionId, 's_new');
      expect(tab.ordinal, 1);
      expect(ids(session), ['s_new']);
      final call = session.conversationCalls.single;
      expect(call.$1, 'createSelectionSideSession');
      expect(call.$2, ['p1', '你好', null],
          reason: 'the transport wire shape: parent, firstText, selection');
      await session.sideChatTabStore.pendingSave;
      expect(
        session.sideChatTabStore.entriesOf(workspacePath, 'p1').single.sessionId,
        's_new',
      );
    });

    test('a blank firstInput is passed through as null text — nothing is '
        'sent as a first message', () async {
      final session = newSession();
      session.createSelectionSideSessionResults.add('s_new');

      await session.createSideChatTab('p1');

      expect(session.conversationCalls.single.$2, ['p1', null, null]);
    });

    test('a rejected create throws and registers nothing', () async {
      final session = newSession();
      session.createSelectionSideSessionResults.add(
        StateError('createSelectionSideSession rejected: guard'),
      );

      await expectLater(
        session.createSideChatTab('p1', firstInput: 'x'),
        throwsA(isA<StateError>()),
      );

      expect(ids(session), isEmpty);
      expect(session.sideChatTabStore.entriesOf(workspacePath, 'p1'), isEmpty);
    });

    test('the ordinal is the smallest unused one under the parent', () async {
      final session = newSession();
      session.registerSideChatTab('p1', 'old1');
      session.registerSideChatTab('p1', 'keep2');
      session.closeSideChatTabRecord('p1', 'old1');
      session.createSelectionSideSessionResults.add('s_new');

      final tab = await session.createSideChatTab('p1');

      expect(tab.ordinal, 1, reason: 'a closed tab frees its number');
      expect(ids(session), ['s_new', 'keep2'],
          reason: 'tabsOf answers ordinal order: the reused #1 leads');
    });
  });

  group('host port surface', () {
    test('the five ports are reachable through ChatPageHost', () async {
      final session = newSession(channel: (c, m, a) async => null);
      final ChatPageHost host = session;

      session.registerSideChatTab('p1', 's1');
      expect(host.sideChatTabs('p1').single.sessionId, 's1');

      session.createSelectionSideSessionResults.add('s2');
      final created = await host.createSideChatTab('p1');
      expect(created.sessionId, 's2');
      expect([for (final t in host.sideChatTabs('p1')) t.ordinal], [1, 2]);

      await host.restoreSideChatTabs('p1');
      await host.closeSideChatTab('p1', 's1');
      expect([for (final t in host.sideChatTabs('p1')) t.sessionId], ['s2']);

      await host.destroySideChatTab('p1', 's2');
      expect(host.sideChatTabs('p1'), isEmpty);
    });

    test('the fake bundle answers the same surface (page tests stand in)',
        () async {
      final bundle = FakeChatGateway();
      addTearDown(bundle.dispose);

      await bundle.restoreSideChatTabs('p1');
      expect(bundle.restoredSideChatParents, ['p1']);

      final tab = await bundle.createSideChatTab('p1', firstInput: '问题');
      expect(tab.sessionId, 'sess_side');
      expect(bundle.createdSideChatRequests.single, ('p1', '问题'));
      expect(bundle.sideChatTabs('p1').single.sessionId, 'sess_side');

      await bundle.closeSideChatTab('p1', 'sess_side');
      expect(bundle.closedSideChatTabs.single, ('p1', 'sess_side'));
      expect(bundle.sideChatTabs('p1'), isEmpty);

      bundle.createSideChatTabResults.add('s_other');
      final other = await bundle.createSideChatTab('p1');
      expect(other.sessionId, 's_other');
      expect(other.ordinal, 1, reason: 'the freed number is reused');
      await bundle.destroySideChatTab('p1', 's_other');
      expect(bundle.destroyedSideChatTabs.single, ('p1', 's_other'));
      expect(bundle.sideChatTabs('p1'), isEmpty);
    });
  });
}