import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/protocol/channel_client.dart';
import 'package:zlinker/protocol/conversation.dart';

/// Hand-written wire fake (spec §7: port tests record (method, args) and
/// answer from a programmed table) — the queue's [ReplayableCommandQueue.call]
/// seam needs no sockets.
class _FakeWire {
  final calls = <(String, List<Object?>)>[];

  /// Programmed answers/throws, dequeued front-first (empty →
  /// `{accepted: true}` — the verification answer shape minus the command
  /// echo). An Exception/Error entry is thrown.
  final List<Object?> results = [];

  Future<dynamic> call(String method, List<Object?> args) async {
    calls.add((method, args));
    if (results.isNotEmpty) {
      final next = results.removeAt(0);
      if (next is Exception) throw next;
      if (next is Error) throw next;
      return next;
    }
    return const {'accepted': true, 'command': <String, dynamic>{}};
  }
}

ReplayableCommandQueue _queue(
  _FakeWire wire,
  ValueNotifier<int> recovered, {
  Map<String, dynamic> scope = const {'workspacePath': '/repo/app'},
}) => ReplayableCommandQueue(
  call: wire.call,
  scope: scope,
  clientId: 'client-1',
  recovered: recovered,
);

/// Lets the fire-and-forget drain pass finish (each zero-delay await first
/// flushes the pending microtasks).
Future<void> _settle(ReplayableCommandQueue queue) async {
  for (var i = 0; i < 100 && queue.draining; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  await Future<void>.delayed(Duration.zero);
}

void main() {
  test('enqueueTaskCommand wire matches the verification schema', () async {
    final wire = _FakeWire();
    final recovered = ValueNotifier<int>(0);
    final queue = _queue(
      wire,
      recovered,
      scope: const {'workspacePath': '/repo/app', 'workspaceIdentity': 'wid'},
    );

    queue.queueLocal(taskId: 'sess-1', content: '你好');
    await _settle(queue);

    final call = wire.calls.single;
    expect(call.$1, 'enqueueTaskCommand');
    final payload = call.$2.single as Map;
    expect(payload['type'], 'send_prompt');
    expect(payload['taskId'], 'sess-1');
    expect(payload['content'], '你好');
    expect(payload['clientId'], 'client-1');
    expect(payload['clientLabel'], 'ZLinker');
    expect(payload['workspacePath'], '/repo/app');
    expect(payload['workspaceIdentity'], 'wid');
    expect((payload['commandId'] as String).isNotEmpty, isTrue);
    // Schema lock (verification: no clientMode — the mode rides snapshot
    // reads only), negative assertion per protocol spec §7.
    expect(payload.containsKey('clientMode'), isFalse);
    // Accepted → removed from the queue (owner-active enqueue delivers).
    expect(queue.items, isEmpty);
  });

  test('enqueue payload omits workspaceIdentity when the scope lacks it',
      () async {
    final wire = _FakeWire();
    final recovered = ValueNotifier<int>(0);
    final queue = _queue(wire, recovered);

    queue.queueLocal(taskId: 's1', content: 'a');
    await _settle(queue);

    final payload = wire.calls.single.$2.single as Map;
    expect(payload.containsKey('workspaceIdentity'), isFalse);
  });

  test('channel-level failure requeues; recovered triggers the replay',
      () async {
    final wire = _FakeWire()
      ..results.add(TimeoutException('bridge recovery timed out'));
    final recovered = ValueNotifier<int>(0);
    final queue = _queue(wire, recovered);

    final item = queue.queueLocal(taskId: 's1', content: 'a');
    await _settle(queue);
    // Requeue #1 — waiting for the next recovery, still on the bar.
    expect(item.state, ReplayableQueueItemState.queued);
    expect(item.attempts, 1);
    expect(wire.calls, hasLength(1));

    recovered.value += 1;
    await _settle(queue);
    expect(wire.calls, hasLength(2));
    expect(queue.items, isEmpty);
  });

  test('the desktop channel-missing answer is channel-level too', () async {
    final wire = _FakeWire()
      ..results.add(
        ChannelRpcError(
          "Channel name 'zcode-task' timed out after 1000ms",
          null,
        ),
      );
    final recovered = ValueNotifier<int>(0);
    final queue = _queue(wire, recovered);

    final item = queue.queueLocal(taskId: 's1', content: 'a');
    await _settle(queue);
    expect(item.state, ReplayableQueueItemState.queued);
    expect(item.attempts, 1);
  });

  test('channel errors past the requeue cap surface the item as failed',
      () async {
    final wire = _FakeWire();
    for (var i = 0; i < 4; i++) {
      wire.results.add(TimeoutException('dead'));
    }
    final recovered = ValueNotifier<int>(0);
    final queue = _queue(wire, recovered);

    final item = queue.queueLocal(taskId: 's1', content: 'a');
    await _settle(queue); // attempt 1 → requeue
    expect(item.state, ReplayableQueueItemState.queued);
    expect(item.attempts, 1);

    recovered.value += 1;
    await _settle(queue); // attempt 2 → requeue
    expect(item.state, ReplayableQueueItemState.queued);
    expect(item.attempts, 2);

    recovered.value += 1;
    await _settle(queue); // attempt 3 → requeue #3 (cap reached)
    expect(item.state, ReplayableQueueItemState.queued);
    expect(item.attempts, 3);

    recovered.value += 1;
    await _settle(queue); // attempt 4 → past the cap → failed
    expect(item.state, ReplayableQueueItemState.failed);
    expect(item.attempts, 4);
    expect(wire.calls, hasLength(4));

    // A failed item is inert: recoveries no longer send anything.
    recovered.value += 1;
    await _settle(queue);
    expect(wire.calls, hasLength(4));
  });

  test('non-channel rejection fails the item; the drain moves on',
      () async {
    final wire = _FakeWire()
      ..results.add(ChannelRpcError('Task command not found.', null));
    final recovered = ValueNotifier<int>(0);
    final queue = _queue(wire, recovered);

    queue.queueLocal(taskId: 's1', content: 'bad');
    queue.queueLocal(taskId: 's1', content: 'good');
    await _settle(queue);

    // bad → failed (surfaced, stays on the bar); good → accepted, gone.
    expect(wire.calls, hasLength(2));
    expect(queue.items, hasLength(1));
    expect(queue.items.single.content, 'bad');
    expect(queue.items.single.state, ReplayableQueueItemState.failed);
    expect(queue.items.single.error, 'Task command not found.');
  });

  test('accepted:false answers count as a semantic rejection', () async {
    final wire = _FakeWire()
      ..results.add(const {
        'accepted': false,
        'reason': 'NO_ACTIVE_TASK_OWNER',
      });
    final recovered = ValueNotifier<int>(0);
    final queue = _queue(wire, recovered);

    final item = queue.queueLocal(taskId: 's1', content: 'a');
    await _settle(queue);
    expect(item.state, ReplayableQueueItemState.failed);
    expect(wire.calls, hasLength(1));
  });

  test('retry moves a failed item back with a fresh budget', () async {
    final wire = _FakeWire()
      ..results.add(ChannelRpcError('Task command not found.', null));
    final recovered = ValueNotifier<int>(0);
    final queue = _queue(wire, recovered);

    final item = queue.queueLocal(taskId: 's1', content: 'a');
    await _settle(queue);
    expect(item.state, ReplayableQueueItemState.failed);

    // Retry drains immediately — by the time the test resumes the item is
    // already in flight (default answer → accepted → gone).
    queue.retry(item.commandId);
    await _settle(queue);
    expect(queue.items, isEmpty);
    expect(wire.calls, hasLength(2));
  });

  test('cancel removes locally and fires the idempotent cancel wire',
      () async {
    final wire = _FakeWire()
      ..results.add(TimeoutException('dead'));
    final recovered = ValueNotifier<int>(0);
    final queue = _queue(wire, recovered);

    final item = queue.queueLocal(taskId: 'sess-9', content: 'a');
    await _settle(queue);

    await queue.cancel(item.commandId);
    expect(queue.items, isEmpty);
    final cancelCall = wire.calls.last;
    expect(cancelCall.$1, 'cancelTaskCommand');
    // Schema lock: exactly {commandId, taskId} — nothing else.
    expect(cancelCall.$2.single, {
      'commandId': item.commandId,
      'taskId': 'sess-9',
    });
  });

  test('cancel of an unknown id never touches the wire', () async {
    final wire = _FakeWire();
    final recovered = ValueNotifier<int>(0);
    final queue = _queue(wire, recovered);

    await queue.cancel('nope');
    expect(wire.calls, isEmpty);
  });

  test('dispose drops items and detaches the recovery listener', () async {
    final wire = _FakeWire()
      ..results.add(TimeoutException('dead'));
    final recovered = ValueNotifier<int>(0);
    final queue = _queue(wire, recovered);

    queue.queueLocal(taskId: 's1', content: 'a');
    await _settle(queue);
    expect(wire.calls, hasLength(1));

    queue.dispose();
    expect(queue.items, isEmpty);
    recovered.value += 1;
    await _settle(queue);
    expect(wire.calls, hasLength(1));
  });

  test('items replay in FIFO order', () async {
    final wire = _FakeWire();
    final recovered = ValueNotifier<int>(0);
    final queue = _queue(wire, recovered);

    queue.queueLocal(taskId: 's1', content: 'first');
    queue.queueLocal(taskId: 's1', content: 'second');
    await _settle(queue);

    expect(wire.calls, hasLength(2));
    expect(
      (wire.calls[0].$2.single as Map)['content'],
      'first',
    );
    expect(
      (wire.calls[1].$2.single as Map)['content'],
      'second',
    );
    expect(queue.items, isEmpty);
  });
}
