import 'package:flutter_test/flutter_test.dart';

import 'recording_chat_gateway.dart';

void main() {
  test('loose default: unknown members record the call and answer accepted',
      () async {
    final gateway = RecordingChatGateway();
    final res = await (gateway as dynamic).deleteSession('s1');
    expect(res, {'status': 'accepted'});
    expect(gateway.calls.single.$1, 'deleteSession');
    expect(gateway.calls.single.$2, ['s1']);
  });

  test('conversationCommands records into the same calls list', () async {
    final gateway = RecordingChatGateway();
    final sessionId = await gateway.conversationCommands
        .createSession('ws-1', firstText: '你好');
    expect(sessionId, 'new-s1');
    final res = await gateway.conversationCommands.sendText('s1', '继续',
        heldQueueDisposition: 'queue');
    expect(res, {'status': 'accepted'});
    expect(gateway.calls.length, 2);
    expect(gateway.calls[0].$1, 'createSession');
    expect(gateway.calls[0].$2, ['ws-1', '你好', null]);
    expect(gateway.calls[1].$1, 'sendText');
    expect(gateway.calls[1].$2, ['s1', '继续', 'queue']);
  });

  test('default surfaces: subscribe answers from the hand-fed state',
      () async {
    final gateway = RecordingChatGateway();
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    final handle = await gateway.subscribe('s1');
    expect(handle.state, same(gateway.state));
    expect(handle.state.rows.first['text'], 'hi');
    await handle.close();
    expect(gateway.closedSessions, ['s1']);
  });

  test('[strict] unexpected members throw instead of answering accepted',
      () async {
    final gateway = RecordingChatGateway()..strict = true;
    expect(
      () => (gateway as dynamic).deleteSession('s1'),
      throwsUnimplementedError,
    );
    expect(
      () => gateway.conversationCommands.stop('s1'),
      throwsUnimplementedError,
    );
    expect(gateway.calls, isEmpty);
  });
}
