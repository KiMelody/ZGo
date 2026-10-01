// Newer style lints are suppressed so this file keeps its protocol
// handling readable as a single, self-contained unit.
// ignore_for_file: use_null_aware_elements, prefer_initializing_formals
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'channel_client.dart';
import 'id.dart';

// Bundle anchor: NATIVE — no counterpart in the official web bundle.
// Split out of the former single-file conversation.dart; the offline
// replayable-command queue (ADR-0010) is a native design, so bundle diffs
// never touch this file. See docs/adr/0013 appendix for the split diff
// procedure.
/// One locally-queued `send_prompt` of [ReplayableCommandQueue].
enum ReplayableQueueItemState { queued, sending, failed }

class ReplayableQueueItem {
  /// Client-generated uuid — stable across channel-error retries so the
  /// desktop can recognize a replay of the same command.
  final String commandId;
  final String taskId;
  final String content;

  ReplayableQueueItemState state = ReplayableQueueItemState.queued;

  /// Channel-level send attempts consumed (requeue budget — see
  /// [ReplayableCommandQueue.maxRequeues]).
  int attempts = 0;

  /// Failure detail of a [ReplayableQueueItemState.failed] item.
  String? error;

  ReplayableQueueItem({
    required this.commandId,
    required this.taskId,
    required this.content,
  });
}

/// Client-side offline queue for the 3.12.3 replayable command family
/// (`web-remote-replayable`, live-verified 2026-09-18): enqueue is a reliable direct-send while the task owner is
/// active, so bridge-degraded sendText failures are held in app memory and
/// replayed via `enqueueTaskCommand` once the bridge recovers.
///
/// Item-level state machine (design.md, 一期 scope = sendText):
/// ```text
/// idle ── sendText fails (channel-level) ──▶ queued   [queueLocal]
/// queued ── user undo ──▶ removed (+ idempotent cancelTaskCommand)
/// queued ── bridge recovered ──▶ sending ── accepted ──▶ removed
/// sending ── enqueue rejected (non-channel) ──▶ failed (retry / undo)
/// sending ── enqueue channel error ──▶ queued (≤ maxRequeues, else failed)
/// ```
/// The queue only ever grows through [queueLocal] and shrinks through
/// accepted sends / user undo; `promoteTaskCommand` is deliberately not
/// called (owner-active enqueue delivers immediately — research finding 1).
/// Dependencies ride the port-call seam ([call] closure + injected
/// [recovered] listenable) so tests drive the whole machine with a
/// hand-written fake, no sockets.
class ReplayableCommandQueue extends ChangeNotifier {
  /// Binds one RPC: the channel (zcode-task) + handshake/health gating are
  /// fixed by the queue owner, method/args vary.
  final Future<dynamic> Function(String method, List<Object?> args) call;

  /// Workspace scope (workspacePath/identity) merged into every enqueue.
  final Map<String, dynamic> scope;

  /// This client's conversation id (the transport's handshake identity).
  final String clientId;

  final void Function(String line)? onLog;

  final Listenable recovered;
  late final void Function() _onRecoveredListener;
  final _items = <ReplayableQueueItem>[];
  bool _draining = false;
  bool _disposed = false;

  /// How many times a channel-level failure may put one item back into the
  /// queue (design: capped so a flapping bridge can't loop forever; the
  /// next failure past the cap surfaces the item as failed).
  static const maxRequeues = 3;

  ReplayableCommandQueue({
    required this.call,
    required this.scope,
    required this.clientId,
    required this.recovered,
    this.onLog,
  }) {
    _onRecoveredListener = () {
      if (!_disposed) unawaited(_drain());
    };
    recovered.addListener(_onRecoveredListener);
  }

  /// Queue snapshot (FIFO, queued first in enqueue order). Failed items
  /// stay in place until retried or undone.
  List<ReplayableQueueItem> get items => List.unmodifiable(_items);

  /// True while a recovered/drain pass is replaying items.
  bool get draining => _draining;

  /// idle ──▶ queued: the composer captured a channel-level sendText
  /// failure. Schedules an immediate drain — the bridge may already be
  /// healthy again (the wire binding then waits for recovery itself).
  ReplayableQueueItem queueLocal({
    required String taskId,
    required String content,
  }) {
    final item = ReplayableQueueItem(
      commandId: generateUuid(),
      taskId: taskId,
      content: content,
    );
    _items.add(item);
    notifyListeners();
    unawaited(_drain());
    return item;
  }

  /// Removes [commandId] locally and fires the idempotent
  /// `cancelTaskCommand` as a safety net (research: not_found still
  /// answers canceled:true — "ensure not queued" semantics, never an
  /// error surface).
  Future<void> cancel(String commandId) async {
    final index = _items.indexWhere((i) => i.commandId == commandId);
    if (index == -1) return;
    final item = _items.removeAt(index);
    notifyListeners();
    try {
      await cancelTaskCommand(item.commandId, item.taskId);
    } catch (e) {
      onLog?.call('[replayable] cancel failed: $e');
    }
  }

  /// User retry on a failed item: back into the queue with a fresh
  /// requeue budget, then an immediate drain attempt.
  void retry(String commandId) {
    final item = _byId(commandId);
    if (item == null || item.state != ReplayableQueueItemState.failed) return;
    item
      ..state = ReplayableQueueItemState.queued
      ..attempts = 0
      ..error = null;
    notifyListeners();
    unawaited(_drain());
  }

  /// `zcode-task.enqueueTaskCommand` — research-confirmed schema; no
  /// clientMode (the mode rides getTaskSnapshot reads only). Answers
  /// `{accepted, command}`.
  Future<dynamic> enqueueTaskCommand({
    required String commandId,
    required String taskId,
    required String content,
  }) => call('enqueueTaskCommand', [
    {
      ...scope,
      'commandId': commandId,
      'taskId': taskId,
      'type': 'send_prompt',
      'content': content,
      'clientId': clientId,
      'clientLabel': 'ZGo',
    },
  ]);

  /// `zcode-task.cancelTaskCommand` — `{commandId, taskId}`, nothing else.
  Future<dynamic> cancelTaskCommand(String commandId, String taskId) =>
      call('cancelTaskCommand', [
        {'commandId': commandId, 'taskId': taskId},
      ]);

  ReplayableQueueItem? _byId(String commandId) {
    for (final item in _items) {
      if (item.commandId == commandId) return item;
    }
    return null;
  }

  Future<void> _drain() async {
    if (_draining || _disposed) return;
    _draining = true;
    try {
      while (!_disposed) {
        ReplayableQueueItem? next;
        for (final item in _items) {
          if (item.state == ReplayableQueueItemState.queued) {
            next = item;
            break;
          }
        }
        if (next == null) return;
        // Channel-level failure: the whole drain pauses (every further
        // enqueue would fail the same way) until the next recovery.
        if (await _sendItem(next)) return;
      }
    } finally {
      _draining = false;
    }
  }

  /// Replays one item. Returns true when the item went back to queued
  /// (channel-level failure) and the drain should pause.
  Future<bool> _sendItem(ReplayableQueueItem item) async {
    item
      ..state = ReplayableQueueItemState.sending
      ..error = null;
    notifyListeners();
    dynamic res;
    Object? failure;
    try {
      res = await enqueueTaskCommand(
        commandId: item.commandId,
        taskId: item.taskId,
        content: item.content,
      );
    } catch (e) {
      failure = e;
    }
    if (failure == null && res is Map && res['accepted'] == false) {
      // Semantic rejection (validation/permission) — not retryable.
      failure = StateError('enqueueTaskCommand rejected: $res');
    }
    // The session ended while the enqueue was in flight — the queue is
    // gone; never notify or mutate past dispose.
    if (_disposed) return false;
    if (failure == null) {
      // sent — owner-active enqueue delivers immediately (research).
      _items.remove(item);
    } else if (isChannelLevelError(failure)) {
      item.attempts += 1;
      if (item.attempts <= maxRequeues) {
        item.state = ReplayableQueueItemState.queued;
        onLog?.call('[replayable] enqueue channel error, requeued '
            '(attempt ${item.attempts}): $failure');
        notifyListeners();
        return true;
      }
      item
        ..state = ReplayableQueueItemState.failed
        ..error = '$failure';
    } else {
      item
        ..state = ReplayableQueueItemState.failed
        ..error = failure is ChannelRpcError ? failure.message : '$failure';
    }
    notifyListeners();
    return false;
  }

  @override
  void dispose() {
    _disposed = true;
    recovered.removeListener(_onRecoveredListener);
    _items.clear();
    super.dispose();
  }
}
