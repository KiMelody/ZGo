import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/connection_params.dart';
import 'package:zgo/state/side_chat_registry.dart';
import 'package:zgo/state/side_chat_tab_store.dart';

import '../helpers/fake_device_session.dart';

/// Shape of the fake's `channelHandler` field.
typedef ChannelHandler = Future<dynamic> Function(
  String channel,
  String method,
  List<Object?> args,
);

/// `DeviceSession.restoreSideChatTabs` orchestration
/// (design 11-11-btw-side-chat §3, A1-rev2, R8/AC9).
///
/// The pure registry matrix lives in side_chat_registry_test.dart; this file
/// covers the session wiring: the persisted manifest (register/close/destroy),
/// the `zcode-session.listSessions` existence check (sessionKind gate, absent
/// ids pruned, RPC failure degrading to the raw manifest), batching, restart,
/// and the notify contract.
///
/// Why the manifest: `selection_side_chat` never enters the sessions-index
/// (host whitelist), and `listSessions` cannot enumerate it — the official web
/// remote keeps tabs in pure memory. ZGo persists the ids it created and uses
/// the by-id check as its only server-side source of truth.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const workspacePath = r'F:\proj';
  const otherPath = r'F:\other';

  final params = RemoteConnectionParams.parse(
    'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1'
    '&name=songsong&app_version=3.14.0',
  )!;

  Map<String, dynamic> workspace(String path) => {
        'label': path.split(r'\').last,
        'workspacePath': path,
      };

  /// One row of the channel-level `listSessions` answer (bare array). The
  /// `sessionKind` is the desktop's `task_type`; soft-deleted rows never
  /// reach the client (filtered server-side).
  Map<String, dynamic> sessionRow(
    String id, {
    String kind = SideChatRegistry.sessionKind,
    String? parent = 'p1',
  }) =>
      {
        'sessionId': id,
        'sessionKind': kind,
        'status': 'idle',
        'title': 'Side chat',
        if (parent != null) 'parentSessionId': parent,
      };

  /// A `zcode-session.listSessions` answer echoing exactly the ids it was
  /// asked about, with [kinds] overriding the kind of specific ids (an id
  /// mapped to another kind must not come back as a side chat).
  ChannelHandler echoCheck([Map<String, String> kinds = const {}]) =>
      (channel, method, args) async => [
            for (final id in (args.single as Map)['sessionIds'] as List)
              sessionRow(
                '$id',
                kind: kinds['$id'] ?? SideChatRegistry.sessionKind,
              ),
          ];

  /// A fake session on the seeded install; [channel] answers its channel RPCs
  /// (the restore tests program `zcode-session.listSessions` there).
  FakeDeviceSession newSession({
    ChannelHandler? channel,
    String deviceId = 'd1',
    List<Map<String, dynamic>>? workspaces,
  }) =>
      FakeDeviceSession(
        deviceId: deviceId,
        params: params,
        workspaces: workspaces ?? [workspace(workspacePath)],
        channelHandler: channel,
      );

  List<String> ids(FakeDeviceSession session, [String parent = 'p1']) =>
      [for (final t in session.sideChatTabs(parent)) t.sessionId];

  List<int> ordinals(FakeDeviceSession session, [String parent = 'p1']) =>
      [for (final t in session.sideChatTabs(parent)) t.ordinal];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('manifest lifecycle', () {
    test('register persists the tab; close keeps it; destroy removes it',
        () async {
      final session = newSession();

      final created = session.registerSideChatTab('p1', 's1');
      expect(created.ordinal, 1);
      await session.sideChatTabStore.pendingSave;
      expect(
        session.sideChatTabStore
            .entriesOf(workspacePath, 'p1')
            .single
            .sessionId,
        's1',
      );

      // Close = restorable collapse: the page drops the tab, the desktop
      // runtime stops, the manifest entry survives.
      session.closeSideChatTabRecord('p1', 's1');
      expect(ids(session), isEmpty);
      expect(
        session.sideChatTabStore.entriesOf(workspacePath, 'p1'),
        hasLength(1),
        reason: 'close must keep the recovery entry',
      );

      // Destroy = permanent: the record and the manifest entry both go.
      session.destroySideChatTabRecord('p1', 's1');
      expect(ids(session), isEmpty);
      await session.sideChatTabStore.pendingSave;
      expect(session.sideChatTabStore.entriesOf(workspacePath, 'p1'), isEmpty);
    });

    test('a closed tab is rebuilt on the next page entry', () async {
      final session = newSession(channel: echoCheck(const {}));
      session.registerSideChatTab('p1', 's1');
      session.registerSideChatTab('p1', 's2');
      session.closeSideChatTabRecord('p1', 's1');
      expect(ids(session), ['s2']);

      await session.restoreSideChatTabs('p1');

      expect(ids(session), ['s1', 's2']);
      expect(ordinals(session), [1, 2],
          reason: 'the manifest ordinal comes back with the tab');
    });

    test('a destroyed tab never comes back', () async {
      final session = newSession(channel: echoCheck(const {}));
      session.registerSideChatTab('p1', 's1');
      session.registerSideChatTab('p1', 's2');
      session.destroySideChatTabRecord('p1', 's1');

      await session.restoreSideChatTabs('p1');

      expect(ids(session), ['s2']);
    });

    test(
        'the manifest is keyed per workspace: another workspace\'s bucket '
        'never leaks into this parent', () async {
      final session = newSession(
        workspaces: [workspace(workspacePath), workspace(otherPath)],
      );
      session.registerSideChatTab('p1', 's1');

      expect(
        session.sideChatTabStore.entriesOf(otherPath, 'p1'),
        isEmpty,
        reason: 'the entry landed under the parent\'s own workspace key',
      );
      expect(session.sideChatTabStore.entriesOf(workspacePath, 'p1'),
          hasLength(1));
    });
  });

  group('existence check', () {
    test(
        'live side chats are restored, other kinds and missing ids are '
        'dropped from the manifest', () async {
      final session = newSession(
        channel: (channel, method, args) async => [
          sessionRow('alive'),
          // Same id, but the row names another session kind: it is no longer
          // a side chat, so the tab must not come back.
          sessionRow('forked', kind: 'fork'),
          // 'gone' is absent (soft-deleted rows are filtered server-side).
        ],
      );
      session.registerSideChatTab('p1', 'alive');
      session.registerSideChatTab('p1', 'forked');
      session.registerSideChatTab('p1', 'gone');
      // Clear the page so only the restore can bring anything back.
      for (final id in ['alive', 'forked', 'gone']) {
        session.closeSideChatTabRecord('p1', id);
      }

      await session.restoreSideChatTabs('p1');

      expect(ids(session), ['alive']);
      expect(ordinals(session), [1]);
      await session.sideChatTabStore.pendingSave;
      expect(
        [
          for (final t
              in session.sideChatTabStore.entriesOf(workspacePath, 'p1'))
            t.sessionId
        ],
        ['alive'],
        reason: 'a refuted id leaves the manifest; it cannot resurrect later',
      );
    });

    test('the check call carries workspacePath and the manifest ids', () async {
      final session = newSession(channel: echoCheck(const {}));
      session.registerSideChatTab('p1', 's1');
      session.registerSideChatTab('p1', 's2');
      session.closeSideChatTabRecord('p1', 's1');
      session.closeSideChatTabRecord('p1', 's2');

      await session.restoreSideChatTabs('p1');

      final call = session.channelCalls.last;
      expect(call.$1, Channels.zcodeSession);
      expect(call.$2, 'listSessions');
      final payload = call.$3.single as Map;
      expect(payload['workspacePath'], workspacePath,
          reason: 'the agent-process routing key is mandatory');
      expect(payload['sessionIds'], ['s1', 's2']);
      expect(payload.containsKey('expectedPersistence'), isFalse);
    });

    test(
        'an RPC failure degrades to the raw manifest (over-restore is the '
        'safe direction)', () async {
      final session = newSession(
        channel: (channel, method, args) async => throw ChannelRpcError(
          'ZCode Agent runtime is not running.',
          {'code': 32004},
        ),
      );
      session.registerSideChatTab('p1', 's1');
      session.registerSideChatTab('p1', 's2');
      session.closeSideChatTabRecord('p1', 's1');
      session.closeSideChatTabRecord('p1', 's2');

      await session.restoreSideChatTabs('p1');

      expect(ids(session), ['s1', 's2'],
          reason: 'a check that cannot run must not delete anything');
      expect(session.sideChatTabStore.entriesOf(workspacePath, 'p1'),
          hasLength(2));
    });

    test('a malformed check answer also degrades to the raw manifest',
        () async {
      final session = newSession(
        // The channel layer answers a bare array; a map (the V4 frame
        // shape) is not that contract — unverifiable, never "absent".
        channel: (channel, method, args) async => {
          'sessions': [sessionRow('s1')]
        },
      );
      session.registerSideChatTab('p1', 's1');
      session.closeSideChatTabRecord('p1', 's1');

      await session.restoreSideChatTabs('p1');

      expect(ids(session), ['s1']);
    });

    test('ids are checked in batches of ≤64 (the V4 schema cap)', () async {
      final session = newSession(channel: echoCheck(const {}));
      for (var i = 0; i < 65; i++) {
        session.registerSideChatTab('p1', 's$i');
        session.closeSideChatTabRecord('p1', 's$i');
      }

      await session.restoreSideChatTabs('p1');

      final calls = [
        for (final call in session.channelCalls)
          if (call.$2 == 'listSessions') call,
      ];
      expect(calls, hasLength(2));
      expect(
        [
          for (final call in calls)
            ((call.$3.single as Map)['sessionIds'] as List).length
        ],
        [64, 1],
      );
      expect(ids(session), hasLength(65));
    });
  });

  group('restore contract', () {
    test('a restart restores the manifest of the same device', () async {
      final first = newSession();
      first.registerSideChatTab('p1', 's1');
      first.registerSideChatTab('p1', 's2');
      await first.sideChatTabStore.pendingSave;

      // A new process: fresh session object, same device id, no page memory.
      final second = newSession(channel: echoCheck(const {}));

      await second.restoreSideChatTabs('p1');

      expect(ids(second), ['s1', 's2']);
      expect(ordinals(second), [1, 2]);
    });

    test('restoring twice is idempotent and notifies only on a change',
        () async {
      final session = newSession(channel: echoCheck(const {}));
      session.registerSideChatTab('p1', 's1');
      session.closeSideChatTabRecord('p1', 's1');

      var notified = 0;
      session.addListener(() => notified++);

      await session.restoreSideChatTabs('p1');
      expect(ids(session), ['s1']);
      final afterFirst = notified;
      expect(afterFirst, greaterThan(0),
          reason: 'the page rebuilds from the host notify');

      await session.restoreSideChatTabs('p1');
      expect(ids(session), ['s1']);
      expect(notified, afterFirst,
          reason: 'a no-op entry must not ping-pong with listeners');
    });

    test('an empty manifest notifies nothing and calls no RPC', () async {
      final session = newSession(channel: echoCheck(const {}));
      var notified = 0;
      session.addListener(() => notified++);

      await session.restoreSideChatTabs('p1');

      expect(ids(session), isEmpty);
      expect(notified, 0);
      expect(session.channelCalls, isEmpty);
    });

    test(
        'restored tabs keep their persisted order even when a lower '
        'ordinal was freed in between', () async {
      // Manifest: s1 #1, s3 #3. The live page already holds s2, registered
      // after a close freed 1, so it took #1 — and the manifest write
      // resequenced the stale s1 entry to #2 (a live tab never renumbers).
      final session = newSession(channel: echoCheck(const {}));
      session.sideChatTabStore.put(
        workspacePath,
        'p1',
        const SideChatTab(sessionId: 's1', ordinal: 1),
      );
      session.sideChatTabStore.put(
        workspacePath,
        'p1',
        const SideChatTab(sessionId: 's3', ordinal: 3),
      );
      session.registerSideChatTab('p1', 's2');
      expect(ordinals(session), [1]);
      expect(ids(session), ['s2']);

      await session.restoreSideChatTabs('p1');

      // s2 owns #1; s1's persisted #1 collides and takes the smallest unused
      // (2); s3 keeps #3.
      expect(ids(session), ['s2', 's1', 's3']);
      expect(ordinals(session), [1, 2, 3]);
    });
  });

  group('SideChatTabStore', () {
    test('persists and reloads the ordinal manifest as JSON', () async {
      final store = SideChatTabStore(deviceId: 'd9');
      await store.load();
      store.put(
        workspacePath,
        'p1',
        const SideChatTab(sessionId: 'b', ordinal: 2),
      );
      store.put(
        workspacePath,
        'p1',
        const SideChatTab(sessionId: 'a', ordinal: 1),
      );
      await store.pendingSave;

      final raw =
          (await SharedPreferences.getInstance()).getString('sideChat.tabs.d9');
      expect(raw, isNotNull);

      final reloaded = SideChatTabStore(deviceId: 'd9');
      await reloaded.load();
      expect(
        [for (final t in reloaded.entriesOf(workspacePath, 'p1')) t.sessionId],
        ['a', 'b'],
      );
      expect(
        [for (final t in reloaded.entriesOf(workspacePath, 'p1')) t.ordinal],
        [1, 2],
      );
    });

    test('corrupt storage degrades to an empty manifest', () async {
      SharedPreferences.setMockInitialValues(
        {'sideChat.tabs.d9': '{not json'},
      );
      final store = SideChatTabStore(deviceId: 'd9');
      await store.load();
      expect(store.loaded, isTrue);
      expect(store.entriesOf(workspacePath, 'p1'), isEmpty);
    });

    test(
        'a fresh registration may reuse a closed tab\'s ordinal; the stale '
        'manifest entry is renumbered instead', () async {
      final store = SideChatTabStore(deviceId: 'd9');
      await store.load();
      store.put(
        workspacePath,
        'p1',
        const SideChatTab(sessionId: 'old', ordinal: 1),
      );
      // Live registry closed 'old' (manifest keeps it) and the new tab took
      // the freed #1.
      store.put(
        workspacePath,
        'p1',
        const SideChatTab(sessionId: 'new', ordinal: 1),
      );
      await store.pendingSave;

      final entries = store.entriesOf(workspacePath, 'p1');
      expect(
        {for (final t in entries) t.sessionId: t.ordinal},
        {'new': 1, 'old': 2},
        reason: 'the live tab keeps its visible number; the stale entry '
            'moves to the smallest unused one',
      );
    });

    test('retain prunes refuted ids; remove drops exactly one', () async {
      final store = SideChatTabStore(deviceId: 'd9');
      await store.load();
      for (final (id, ordinal) in [('a', 1), ('b', 2), ('c', 3)]) {
        store.put(
          workspacePath,
          'p1',
          SideChatTab(sessionId: id, ordinal: ordinal),
        );
      }

      store.retain(workspacePath, 'p1', {'a', 'c'});
      expect(
          [for (final t in store.entriesOf(workspacePath, 'p1')) t.sessionId],
          ['a', 'c']);

      store.remove(workspacePath, 'p1', 'a');
      expect(
          [for (final t in store.entriesOf(workspacePath, 'p1')) t.sessionId],
          ['c']);
      await store.pendingSave;
    });
  });
}
