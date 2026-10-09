import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/connection_params.dart';
import 'package:zgo/protocol/conversation.dart';

import '../helpers/fake_device_session.dart';

/// renameSession dual-write (D3, official renameTask semantics — R2): the
/// task-index rename is authoritative; the V4 `renameSession` is a
/// best-effort twin — sent after task-index success, silently swallowed on
/// V4 failure, and never issued when the task-index write itself failed.
void main() {
  final params = RemoteConnectionParams.parse(
    'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1'
    '&name=songsong&app_version=3.14.0',
  )!;

  test('task-index rename succeeds → V4 renameSession arrives with the '
      'same title (sessionId = taskId)', () async {
    final session = _DualWriteSession(
      deviceId: 'd1',
      params: params,
      channelHandler: (channel, method, args) async => const {'ok': true},
    );

    await session.renameTask('t1', '新标题');

    expect(session.v4.renames.single, (sessionId: 't1', title: '新标题'));
    expect(
      session.channelCalls.where((c) => c.$2 == 'renameTask'),
      hasLength(1),
    );
  });

  test('task-index rename FAILS → no V4 renameSession, error rethrown',
      () async {
    final session = _DualWriteSession(
      deviceId: 'd1',
      params: params,
      channelHandler: (channel, method, args) =>
          throw StateError('task-index down'),
    );

    await expectLater(session.renameTask('t1', '新标题'), throwsA(anything));
    expect(session.v4.renames, isEmpty);
  });

  test('V4 renameSession throws → swallowed, task-index result still wins',
      () async {
    final session = _DualWriteSession(
      deviceId: 'd1',
      params: params,
      v4Error: StateError('bridge closed'),
      channelHandler: (channel, method, args) async => const {'ok': true},
    );

    final res = await session.renameTask('t1', '新标题');

    expect(res, {'ok': true});
    expect(session.v4.renames, hasLength(1));
  });

  test('no conversation transport (cold rename, bridge never opened) → '
      'dual-write skipped silently, task-index rename still lands', () async {
    final session = _DualWriteSession(
      deviceId: 'd1',
      params: params,
      conversationGone: true,
      channelHandler: (channel, method, args) async => const {'ok': true},
    );

    final res = await session.renameTask('t1', '新标题');

    expect(res, {'ok': true});
    expect(session.v4.renames, isEmpty);
  });
}

/// FakeDeviceSession whose `conversationCommands` getter serves a recording
/// fake (the real one throws before the first workspace — that shape is
/// covered by [conversationGone]).
class _DualWriteSession extends FakeDeviceSession {
  _DualWriteSession({
    required super.deviceId,
    required super.params,
    Object? v4Error,
    bool conversationGone = false,
    super.channelHandler,
  }) : _v4 = _RecordingConversation(v4Error),
       _conversationGone = conversationGone;

  final _RecordingConversation _v4;
  final bool _conversationGone;

  _RecordingConversation get v4 => _v4;

  @override
  ConversationTransport get conversationCommands {
    if (_conversationGone) return super.conversationCommands;
    return _v4;
  }
}

class _RecordingConversation implements ConversationTransport {
  _RecordingConversation(this.error);

  final Object? error;
  final List<({String sessionId, String title})> renames = [];

  @override
  Future<dynamic> renameSession(String sessionId, String title) async {
    renames.add((sessionId: sessionId, title: title));
    final err = error;
    if (err != null) throw err;
    return const {'status': 'accepted'};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      Future.value(const {'status': 'accepted'});
}
