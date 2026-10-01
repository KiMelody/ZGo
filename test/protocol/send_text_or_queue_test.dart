import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/protocol/ipc_codec.dart';
import 'package:zgo/protocol/remote_client.dart' show BridgeSession;

/// Matrix for [ConversationTransport.sendTextOrQueue] (task 10-01): the
/// queueable-failure decision lives in the transport and only there
/// (ADR-0010); every row freezes one branch of the former chat-page `_send`
/// inline logic.
///
/// DI手法 follows [ReplayableCommandQueue]'s own tests: hand-written fakes,
/// no sockets — the transport rides a fake [BridgeSession] whose channel
/// client answers from a programmed table, and the send itself is driven by
/// a [ConversationTransport] subclass that records the call and throws /
/// returns on cue (a genuine [TimeoutException] cannot be produced from the
/// wire within the 30s channel budget).
void main() {
  test('ack pass answers sent and forwards text + heldQueueDisposition',
      () async {
    final t = _StubTransport(session: _fakeSession());
    final res = await t.sendTextOrQueue(
      's1',
      '你好',
      heldQueueDisposition: 'keepQueueAndSend',
    );

    final sent = res as SendTextSent;
    expect(sent.res, const {'status': 'accepted'});
    final call = t.sendCalls.single;
    expect(call.sessionId, 's1');
    expect(call.text, '你好');
    expect(call.heldQueueDisposition, 'keepQueueAndSend');
    expect(call.attachments, isNull);
  });

  test('ack rejection answers rejected with the ackReason extraction',
      () async {
    final t = _StubTransport(session: _fakeSession())
      ..sendResult = const {'status': 'rejected', 'reasonCode': 'NO_ACTIVE_TURN'};
    final res = await t.sendTextOrQueue('s1', '你好');

    expect(res, isA<SendTextRejected>());
    expect((res as SendTextRejected).reason, 'NO_ACTIVE_TURN');
  });

  test('channel error with every queue condition met answers queued',
      () async {
    final wireCalls = <(String, List<Object?>)>[];
    final channels = _channelClient((channel, method, args) {
      wireCalls.add((method, args));
      if (method == 'enqueueTaskCommand') {
        // Channel-missing shape → the queue requeues and waits for
        // recovery, so the item stays inspectable in queued state.
        throw "Channel name 'zcode-task' timed out after 1000ms";
      }
      return const {'status': 'accepted'}; // handshake
    });
    final t = _StubTransport(
      session: _FakeBridgeSession(channels),
      sendError: TimeoutException('bridge down'),
      workspaceHookReviewUi: true, // version gate open → queue materializes
    );
    final res = await t.sendTextOrQueue('s1', '弱网里的消息');
    await _settle();

    final queued = res as SendTextQueued;
    expect(queued.item.content, '弱网里的消息');
    expect(queued.item.taskId, 's1');
    expect(queued.item.state, ReplayableQueueItemState.queued);
    expect(t.replayableQueue?.items.single.commandId, queued.item.commandId);
    // queueLocal fired the immediate drain replay.
    expect(wireCalls.where((c) => c.$1 == 'enqueueTaskCommand'), hasLength(1));
  });

  test('attachments present answers failed and never queues', () async {
    final wireCalls = <(String, List<Object?>)>[];
    final channels = _channelClient((channel, method, args) {
      wireCalls.add((method, args));
      return const {'status': 'accepted'};
    });
    final t = _StubTransport(
      session: _FakeBridgeSession(channels),
      sendError: TimeoutException('bridge down'),
      workspaceHookReviewUi: true,
    );
    final res = await t.sendTextOrQueue(
      's1',
      '带附件',
      attachments: [
        {'ref': 'r1', 'fileName': 'a.png', 'mime': 'image/png', 'bytes': 3},
      ],
    );
    await _settle();

    // The enqueue schema is text-only: even a channel-level failure with a
    // live queue must NOT park an attachment-carrying message.
    expect(res, isA<SendTextFailed>());
    expect(wireCalls.where((c) => c.$1 == 'enqueueTaskCommand'), isEmpty);
    expect(t.replayableQueue?.items, isEmpty);
    // The descriptor still reached sendText verbatim.
    expect(t.sendCalls.single.attachments, hasLength(1));
  });

  test('null queue (pre-3.12.3 version gate) answers failed', () async {
    final t = _StubTransport(
      session: _fakeSession(),
      sendError: TimeoutException('bridge down'),
    );
    expect(t.replayableQueue, isNull); // gate closed → never created

    final err = TimeoutException('bridge down');
    t.sendError = err;
    final res = await t.sendTextOrQueue('s1', '老桌面的消息');

    expect(res, isA<SendTextFailed>());
    // The original error rides the result for the toast.
    expect((res as SendTextFailed).error, same(err));
  });

  test('non-channel error answers failed and leaves the queue untouched',
      () async {
    final t = _StubTransport(
      session: _fakeSession(),
      sendError: StateError('remote.rpcFrame.fault'),
      workspaceHookReviewUi: true,
    );
    final res = await t.sendTextOrQueue('s1', '普通失败');
    await _settle();

    expect(res, isA<SendTextFailed>());
    expect(t.replayableQueue?.items, isEmpty);
  });

  test('empty text answers failed even on a channel error', () async {
    final t = _StubTransport(
      session: _fakeSession(),
      sendError: TimeoutException('bridge down'),
      workspaceHookReviewUi: true,
    );
    final res = await t.sendTextOrQueue('s1', '');

    expect(res, isA<SendTextFailed>());
  });

  test('ackRejected pass values and missing status', () {
    expect(ackRejected(const {'status': 'accepted'}), isFalse);
    expect(ackRejected(const {'status': 'noop'}), isFalse);
    expect(ackRejected(const {'status': 'duplicate'}), isFalse);
    expect(ackRejected(const {'other': 1}), isFalse); // no status → pass
    expect(ackRejected(const {'status': 'rejected'}), isTrue);
    expect(ackRejected(const {'status': 'stale'}), isTrue);
    expect(ackRejected('not-a-map'), isFalse);
  });

  test('ackReason prefers reasonCode, then message, then status', () {
    expect(
      ackReason(const {'status': 'rejected', 'reasonCode': 'RC', 'message': 'm'}),
      'RC',
    );
    expect(
      ackReason(const {'status': 'rejected', 'message': 'boom'}),
      'boom',
    );
    expect(ackReason(const {'status': 'stale'}), 'stale');
    expect(ackReason('plain'), 'plain');
  });
}

/* ---------- hand-written fakes (no sockets, no mockito/fake_async) ------- */

/// Bridge stand-in: only what the transport's constructor, [sendCommand]'s
/// health gate and the replayable wire call touch; anything else fails loud.
class _FakeBridgeSession implements BridgeSession {
  _FakeBridgeSession(this.channels);

  @override
  final ChannelClient channels;

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
  }) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

_FakeBridgeSession _fakeSession() =>
    _FakeBridgeSession(_channelClient((channel, method, args) => null));

/// Channel client that resolves every call from [respond]; a throw becomes
/// a resPromiseError frame carrying the message (channel rejection shape).
ChannelClient _channelClient(
  Object? Function(String channel, String method, List<Object?> args) respond,
) {
  late final ChannelClient client;
  client = ChannelClient(sendBody: (body) {
    final reader = ValueReader(body);
    final header = decodeValue(reader) as List;
    final arg = decodeValue(reader);
    final id = header[1] as int;
    Object? payload;
    var type = ChannelClient.resPromiseSuccess;
    try {
      payload = respond(
        '${header[2]}',
        '${header[3]}',
        arg is List ? arg : <Object?>[arg],
      );
    } catch (e) {
      type = ChannelClient.resPromiseError;
      payload = {'message': '$e'};
    }
    final w = ValueWriter();
    encodeValue(w, [type, id]);
    encodeValue(w, payload);
    client.handleMessage(w.toBytes());
  });
  final init = ValueWriter();
  encodeValue(init, [ChannelClient.resInitialize, 0]);
  client.handleMessage(init.toBytes());
  return client;
}

/// Transport whose [sendText] records the call and either throws
/// [sendError], returns [sendResult], or answers `accepted` — the
/// programmable failure driver for the matrix.
class _StubTransport extends ConversationTransport {
  _StubTransport({
    required super.session,
    this.sendError,
    super.workspaceHookReviewUi,
  }) : super(scope: const {'workspacePath': '/repo'});

  Object? sendError;
  Object? sendResult;

  final List<
      ({
        String sessionId,
        String text,
        List<Map<String, dynamic>>? attachments,
        String? heldQueueDisposition,
      })> sendCalls = [];

  @override
  Future<dynamic> sendText(
    String sessionId,
    String text, {
    List<Map<String, dynamic>>? attachments,
    String? heldQueueDisposition,
    List<String>? expectedHeldQueueItemIds,
    String? automationId,
    String? offPeakTaskId,
    String? offPeakRunType,
    String? botDeliveryTarget,
    List<String>? toolDisallowlist,
  }) async {
    sendCalls.add((
      sessionId: sessionId,
      text: text,
      attachments: attachments,
      heldQueueDisposition: heldQueueDisposition,
    ));
    final err = sendError;
    if (err != null) throw err;
    final result = sendResult;
    if (result != null) return result;
    return const {'status': 'accepted'};
  }
}

/// Lets the fire-and-forget queue drain pass finish (each zero-delay await
/// first flushes the pending microtasks).
Future<void> _settle() async {
  for (var i = 0; i < 50; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
