import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/protocol/file_service.dart';

import 'chat_role_fakes.dart';

/// Self-tests of the shared role fakes: the recording stream, the typed
/// programming surfaces and the bundle composition the page tests rely on.
/// (Replaces the historical `RecordingChatGateway` self-test — the fakes
/// now implement the seven role interfaces explicitly, no noSuchMethod
/// forwarding outside the conversation transport.)
void main() {
  test('role fakes record into one shared stream', () async {
    final recording = RecordingCalls();
    final taskMeta = FakeTaskMeta(recording);
    final workspace = FakeWorkspaceContext(recording);

    await taskMeta.deleteTask('s1');
    await workspace.workspaceFilesReachable();

    expect(
      recording.calls.map((c) => c.$1).toList(),
      ['deleteTask', 'workspaceFilesReachable'],
    );
    expect(recording.calls.first.$2, ['s1']);
  });

  test('conversation fake records commands and answers typed results',
      () async {
    final recording = RecordingCalls();
    final conversation = FakeConversation(recording);
    final sessionId = await conversation.conversationCommands
        .createSession('ws-1', firstText: '你好');
    expect(sessionId, 'new-s1');
    final res = await conversation.conversationCommands
        .sendTextOrQueue('s1', '继续', heldQueueDisposition: 'queue');
    expect(res, isA<SendTextSent>());
    expect(recording.calls.length, 2);
    expect(recording.calls[0].$1, 'createSession');
    expect(recording.calls[0].$2, ['ws-1', '你好', null]);
    expect(recording.calls[1].$1, 'sendTextOrQueue');
    expect(recording.calls[1].$2, ['s1', '继续', 'queue']);
  });

  test('subscribe answers from the hand-fed state; close is recorded',
      () async {
    final conversation = FakeConversation(RecordingCalls());
    conversation.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    final handle = await conversation.subscribe('s1');
    expect(handle.state, same(conversation.state));
    expect(handle.state.rows.first['text'], 'hi');
    await handle.close();
    expect(conversation.closedSessions, ['s1']);
    expect(conversation.subscribedSessions, ['s1']);
  });

  test('[strict] unexpected transport members throw instead of answering '
      'accepted', () async {
    final recording = RecordingCalls()..strict = true;
    final conversation = FakeConversation(recording);
    expect(
      () => conversation.conversationCommands.stop('s1'),
      throwsUnimplementedError,
    );
    expect(recording.calls, isEmpty);
  });

  test('the file port records the legacy method names and answers the '
      'programmed read', () async {
    final recording = RecordingCalls();
    final port = RecordingFileServicePort(recording)
      ..fileStatResult = const FileStat(type: 'file', size: 7);
    final workspace = FakeWorkspaceContext(recording)..fileService = port;

    final stat = await workspace.fileService.stat('/w', 'a.txt');
    expect(stat.size, 7);
    expect(recording.calls.single.$1, 'fileStat');
    expect(recording.calls.single.$2, ['/w', 'a.txt']);
  });

  test('the bundle composes the role fakes behind one page host', () async {
    final bundle = FakeChatGateway();
    addTearDown(bundle.dispose);
    bundle.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);

    final handle = await bundle.subscribe('s1');
    expect(handle.state, same(bundle.state));
    expect(await bundle.deleteTask('s1'), {'status': 'accepted'});
    expect(bundle.calls.single.$1, 'deleteTask');
    expect(bundle.quotaResetController, isNotNull);
  });
}
