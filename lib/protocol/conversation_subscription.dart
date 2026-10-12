// Newer style lints are suppressed so this file keeps its protocol
// handling readable as a single, self-contained unit.
// ignore_for_file: use_null_aware_elements, prefer_initializing_formals
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'channel_client.dart';
import 'conversation_state.dart';
import 'conversation_transport.dart';

// Bundle anchor: the official web bundle's subscription/store region —
// the shared wire-frame staging, fragment reassembly and resubscribe
// retry base ([_SubscriptionBase]) plus the Conversation/SessionsIndex
// subscriptions. Split out of the former single-file conversation.dart;
// bundle diffs for these functions land here (see docs/adr/0013
// appendix for the grep procedure).

/// Shared base for Conversation/SessionsIndex subscriptions.
/// Extracts the common wire-frame staging, fragment reassembly, bridge
/// recovery, and resubscribe retry logic.
abstract class _SubscriptionBase<T extends ChangeNotifier> {
  final ConversationTransport _transport;
  final String _logTag;

  final T state;

  String? _subscriptionId;
  String? get subscriptionId => _subscriptionId;
  void Function()? _cancelFrameListener;
  bool _disposed = false;
  bool _resyncing = false;
  Timer? _resubscribeTimer;

  /// Consecutive resubscribe failures — drives the exponential backoff
  /// ([ConversationTransport.resubscribeBackoff]: 3s → 6s → 12s capped).
  /// Cleared the moment a subscribe ack arrives, so the next failure
  /// episode starts from the base delay again. Scope: ONLY the
  /// failure-retry queue in [_resubscribe] — the bridge recovery wave and
  /// the initial `start()` do not consult it (see the transport method's
  /// boundary note).
  int _resubscribeAttempts = 0;

  /// Terminal subscribe failure (10-11): the desktop AUTHORITATIVELY
  /// refused the subscription with sessionNotFound — the session is
  /// neither active nor persisted, so every retry is guaranteed to fail.
  /// One-way: no retry timer is armed and [_onBridgeRecovered] must not
  /// resurrect the subscription either (the refusal is a fact about the
  /// SESSION, not the link — a rebuilt bridge cannot make a dead session
  /// exist). Semantic boundary vs the sessions-index tombstone
  /// (DeviceSession.recordVanishedSessions): the tombstone INFERS a
  /// cross-terminal deletion from index diffs (can be a false positive by
  /// construction); this is the subscribe channel's AUTHORITATIVE
  /// rejection. When both hold for one id, the UI presents this one.
  bool _terminalFailed = false;

  final _terminalFailures = StreamController<Object?>.broadcast();

  /// Emits the subscribe error once when a resubscribe attempt classifies
  /// as the authoritative sessionNotFound refusal ([_terminalFailed] goes
  /// true). Upper layers (DeviceSession → ChatPage) listen to render the
  ///「会话不存在」terminal state. Broadcast: nobody listening (initial-open
  /// path surfaces through the start() exception instead) just drops it.
  Stream<Object?> get terminalFailures => _terminalFailures.stream;

  /// Monotonic subscribe-attempt generation: `start()` bumps it on entry.
  /// A late ack (or late failure) whose attempt no longer matches — a
  /// watchdog/bridge-recovery resubscribe raced the pending call — is
  /// dropped instead of overwriting the newer attempt's subscription
  /// (same race family as the 09-18 ask-q snapshot loss).
  int _startAttempt = 0;

  /// Abandon-in-flight guard: fires unless the ack arrives first; a
  /// superseded attempt neither arms nor cancels it.
  Timer? _ackWatchdog;

  final _stagedFrames = <Map<String, dynamic>>[];
  final _fragments = <String, _LogicalFrameAssembly>{};
  Timer? _fragmentCleanup;

  _SubscriptionBase(this._transport, this.state, this._logTag) {
    _transport.session.recovered.addListener(_onBridgeRecovered);
    _fragmentCleanup = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _purgeFragments(),
    );
  }

  // --- abstract: subclasses define channel/protocol specifics

  /// Frame event name (e.g. `onDynamicConversationFrame`).
  String get _frameEventName;

  /// Subscribe method name (e.g. `subscribeConversationV4`).
  String get _subscribeMethod;

  /// Unsubscribe method name (e.g. `unsubscribeConversationV4`).
  String get _unsubscribeMethod;

  /// Resync method name (e.g. `resyncConversationV4`).
  String get _resyncMethod;

  /// Extra subscribe request args (merged with scope).
  Map<String, dynamic> get _subscribeArgs;

  /// Extra unsubscribe request args.
  Map<String, dynamic> get _unsubscribeArgs;

  /// Extra resync request args.
  Map<String, dynamic> get _resyncArgs;

  /// Topic for wire-frame routing.
  String get topic;

  /// Process a logical frame against [state].
  void _acceptLogicalFrame(Map<String, dynamic> frame);

  /// Called with the subscribe ack map — hook for state-specific processing.
  void _onSubscribeAck(Map<String, dynamic> ack) {}

  /// Called after a successful start() — hook for post-start logic.
  void _onStarted() {}

  /// Called during resubscribe cleanup before re-connect.
  void _onResubscribeCleanup() {}

  /// Called during dispose — extra cleanup.
  Future<void> _onDispose() async {}

  int get _resyncSeq => 0;
  String? get _resyncEpoch => null;

  Map<String, dynamic> _requestScope() => _transport.scope;

  void _purgeFragments() {
    if (_disposed) return;
    final stale = <String>[];
    final now = DateTime.now();
    _fragments.forEach((id, a) {
      if (now.difference(a.createdAt).inSeconds > 60) stale.add(id);
    });
    for (final id in stale) {
      _fragments.remove(id);
      _transport.log('[$_logTag] purged stale fragment $id');
    }
  }

  /// Internal: called by the transport that owns this subscription;
  /// not public API.
  Future<void> start() async {
    final attempt = ++_startAttempt;
    await _transport.handshake();
    _cancelFrameListener = _transport.channels.addEventListener(
      ConversationTransport.channel,
      _frameEventName,
      _handleWireFrame,
      arg: _transport.scope,
    );
    _ackWatchdog?.cancel();
    _ackWatchdog = Timer(_transport.subscribeAckTimeout, () {
      if (_disposed || attempt != _startAttempt) return;
      _transport.log(
        '[$_logTag] subscribe ack stalled '
        '${_transport.subscribeAckTimeout.inSeconds}s, resubscribing',
      );
      _resubscribe();
    });
    Object? res;
    try {
      res = await _transport.channels.call(
        ConversationTransport.channel,
        _subscribeMethod,
        [
          {..._requestScope(), ..._subscribeArgs},
        ],
        // The desktop may need to warm the session runtime before answering —
        // give the subscribe call generous room instead of timing out at the
        // 30s channel default.
        timeout: const Duration(seconds: 60),
      );
    } catch (e) {
      if (attempt != _startAttempt) {
        // Superseded while pending (watchdog / bridge recovery raced us):
        // the replacement attempt owns the outcome, so this failure must
        // not surface as a subscribe error for the newer attempt.
        _transport.log('[$_logTag] abandoned subscribe attempt $attempt: $e');
        return;
      }
      _ackWatchdog?.cancel();
      rethrow;
    }
    if (attempt != _startAttempt) {
      // Late ack of a superseded attempt: do not touch _subscriptionId,
      // staged frames or post-start hooks — a newer attempt owns them.
      _transport.log(
        '[$_logTag] dropped late subscribe ack for attempt $attempt ($topic)',
      );
      return;
    }
    _ackWatchdog?.cancel();
    final ack = (res as Map?)?['ack'] as Map?;
    _subscriptionId = ack?['subscriptionId'] as String?;
    _transport.log('[$_logTag] subscribed $topic id=$_subscriptionId');
    if (_subscriptionId == null) {
      throw StateError('$_subscribeMethod: missing ack.subscriptionId');
    }
    // Successful subscribe (ack in hand): the backoff episode is over —
    // the next failure starts from the base delay again.
    _resubscribeAttempts = 0;
    _onSubscribeAck(ack?.cast<String, dynamic>() ?? const {});
    final staged = List<Map<String, dynamic>>.from(_stagedFrames);
    _stagedFrames.clear();
    for (final frame in staged) {
      _acceptLogicalFrame(frame);
    }
    _onStarted();
  }

  void _onBridgeRecovered() {
    if (_disposed || _terminalFailed) return;
    _transport.log('[$_logTag] bridge recovered, resubscribing $topic');
    _resubscribe();
  }

  Future<void> _resubscribe() async {
    // One-way terminal guard at the entry too: a sibling resubscribe may
    // still be mid-flight (awaiting handshake) when the latest attempt
    // classifies sessionNotFound — without this guard it would issue one
    // more subscribe on a terminally-failed subscription.
    if (_disposed || _terminalFailed) return;
    await _transport.handshake();
    _onResubscribeCleanup();
    _cancelFrameListener?.call();
    _cancelFrameListener = null;
    final oldId = _subscriptionId;
    _subscriptionId = null;
    _stagedFrames.clear();
    _fragments.clear();
    if (oldId != null) {
      try {
        await _transport.channels.call(
          ConversationTransport.channel,
          _unsubscribeMethod,
          [
            {..._requestScope(), 'subscriptionId': oldId, ..._unsubscribeArgs},
          ],
        );
      } catch (_) {}
    }
    try {
      await start();
    } catch (e) {
      if (isSessionNotFoundError(e)) {
        // Authoritative refusal (sessionNotFound): the session does not
        // exist and never will on this link — retries are guaranteed to
        // fail (10-10 storm: each dead session churned 3-9 pointless
        // retries). Enter the terminal failure: no retry timer, and the
        // bridge recovery wave will not resurrect it (see the
        // [_terminalFailed] contract, incl. the tombstone distinction).
        _terminalFailed = true;
        _transport.log('[$_logTag] subscribe refused (session not found), '
            'terminal: $e');
        // dispose() may have raced this in-flight attempt (page closed
        // mid-resubscribe) and closed the stream — add-after-close throws,
        // which would escape this fire-and-forget call unhandled.
        if (!_terminalFailures.isClosed) _terminalFailures.add(e);
        return;
      }
      _transport.log('[$_logTag] resubscribe failed: $e');
      _resubscribeTimer?.cancel();
      // Exponential backoff (10-11 R2): 3s → 6s → 12s capped — the fixed
      // 3s hammer amplified the KICK storm's subscribe pressure (1308
      // desktop subscribe calls that day). Backoff applies ONLY to this
      // failure-retry queue; `_onBridgeRecovered` and the initial
      // `start()` bypass it (transport method's boundary note).
      final delay = _transport.resubscribeBackoff(_resubscribeAttempts++);
      _resubscribeTimer = Timer(delay, () {
        if (!_disposed && !_terminalFailed && _subscriptionId == null) {
          _resubscribe();
        }
      });
    }
  }

  void _handleWireFrame(dynamic data) {
    if (_disposed || data is! Map) return;
    final frame = data.cast<String, dynamic>();
    if (frame['topic'] != topic) return;
    switch (frame['kind']) {
      case 'complete':
        final inner = frame['frame'];
        if (inner is Map) {
          _acceptOrStage(inner.cast<String, dynamic>());
        }
        break;
      case 'fragment':
        _acceptFragment(frame);
        break;
    }
  }

  void _acceptOrStage(Map<String, dynamic> frame) {
    if (_subscriptionId == null) {
      _stagedFrames.add(frame);
      return;
    }
    _acceptLogicalFrame(frame);
  }

  void _acceptFragment(Map<String, dynamic> frame) {
    final id = frame['logicalFrameId'] as String?;
    final index = (frame['fragmentIndex'] as num?)?.toInt();
    final count = (frame['fragmentCount'] as num?)?.toInt();
    final dataBase64 = frame['dataBase64'] as String?;
    if (id == null || index == null || count == null || dataBase64 == null) {
      return;
    }
    final assembly = _fragments.putIfAbsent(
      id,
      () => _LogicalFrameAssembly(count),
    );
    assembly.add(index, base64.decode(dataBase64));
    if (assembly.isComplete) {
      _fragments.remove(id);
      try {
        final decoded = jsonDecode(utf8.decode(assembly.assemble()));
        if (decoded is Map) {
          _acceptOrStage(decoded.cast<String, dynamic>());
        }
      } catch (e) {
        _transport.log('[$_logTag] bad logical frame: $e');
      }
    }
  }

  Future<void> _resync() async {
    final id = _subscriptionId;
    if (id == null || _disposed || _resyncing) return;
    _resyncing = true;
    _transport.log(
      '[$_logTag] resync (gap detected) seq=$_resyncSeq logEpoch=$_resyncEpoch',
    );
    try {
      await _transport.channels.call(
        ConversationTransport.channel,
        _resyncMethod,
        [
          {
            ..._requestScope(),
            'subscriptionId': id,
            ..._resyncArgs,
            if (_resyncEpoch != null)
              'base': {'logEpoch': _resyncEpoch, 'seq': _resyncSeq},
          },
        ],
      );
    } catch (e) {
      _transport.log('[$_logTag] resync failed: $e');
    } finally {
      _resyncing = false;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _resubscribeTimer?.cancel();
    _ackWatchdog?.cancel();
    _fragmentCleanup?.cancel();
    _terminalFailures.close();
    await _onDispose();
    _transport.session.recovered.removeListener(_onBridgeRecovered);
    _cancelFrameListener?.call();
    final id = _subscriptionId;
    if (id != null) {
      try {
        await _transport.channels.call(
          ConversationTransport.channel,
          _unsubscribeMethod,
          [
            {..._requestScope(), 'subscriptionId': id, ..._unsubscribeArgs},
          ],
        );
      } catch (_) {}
    }
    _fragments.clear();
  }
}

class ConversationSubscription extends _SubscriptionBase<ConversationState> {
  final String sessionId;

  DateTime _lastFrameAt = DateTime.now();
  Timer? _watchdog;

  /// Internal: created by [ConversationTransport.subscribe]; not public API.
  ConversationSubscription(ConversationTransport transport, this.sessionId)
    : super(transport, ConversationState(), 'v4');

  @override
  String get _frameEventName => 'onDynamicConversationFrame';
  @override
  String get _subscribeMethod => 'subscribeConversationV4';
  @override
  String get _unsubscribeMethod => 'unsubscribeConversationV4';
  @override
  String get _resyncMethod => 'resyncConversationV4';
  @override
  Map<String, dynamic> get _subscribeArgs => {
    'sessionId': sessionId,
    // Official conversationSubscribe body (renderer @270820092) carries the
    // key only when the client declared the capability in clientHello.
    if (_transport.workflowRunDeltas) 'workflowRunDeltas': true,
  };
  @override
  Map<String, dynamic> get _unsubscribeArgs => const {};
  @override
  Map<String, dynamic> get _resyncArgs => const {'forceSnapshot': true};
  @override
  String get topic => 'conversation/$sessionId';
  @override
  int get _resyncSeq => state.seq;
  @override
  String? get _resyncEpoch => state.logEpoch;

  @override
  void _onSubscribeAck(Map<String, dynamic> ack) {
    if (ack['logEpoch'] is String) {
      state.logEpoch = ack['logEpoch'] as String;
    }
  }

  @override
  void _onStarted() {
    _startWatchdog();
    _listenTaskStream();
  }

  @override
  void _onResubscribeCleanup() {
    _watchdog?.cancel();
    _cancelTaskStreamListener?.call();
    _cancelTaskStreamListener = null;
  }

  @override
  Future<void> _onDispose() async {
    _watchdog?.cancel();
    _cancelTaskStreamListener?.call();
    _transport.untrackSubscription(sessionId);
    state.deactivateState();
  }

  /// Context/usage numbers ride the desktop's task-stream broadcast
  /// (`bots:task-stream` messages on the `broadcast` channel,
  /// `broadcastService.onMessage`), not the Conversation V4 delta stream —
  /// the V4 reducer only handles row/state ops. Filtered to this
  /// session's taskId; everything else is dropped. Live-probed on 3.11.2:
  /// the broadcast stays silent there and the numbers flow through
  /// `state.updated` patches instead, so [ContextUsageView] reads both
  /// shapes and this listener is purely additive.
  void Function()? _cancelTaskStreamListener;

  void _listenTaskStream() {
    _cancelTaskStreamListener?.call();
    _cancelTaskStreamListener = _transport.channels.addEventListener(
      Channels.broadcast,
      'onMessage',
      _handleBroadcastMessage,
    );
  }

  void _handleBroadcastMessage(dynamic data) {
    if (_disposed || data is! Map) return;
    if (data['channel'] != 'bots:task-stream') return;
    final payload = data['payload'];
    if (payload is! Map) return;
    if ('${payload['taskId']}' != sessionId) return;
    final event = payload['event'];
    if (event is! Map || event['type'] != 'usage_update') return;
    state.applyUsageUpdate(event.cast<String, dynamic>());
  }

  @override
  void _acceptLogicalFrame(Map<String, dynamic> frame) {
    final subId = subscriptionId;
    if (subId == null || frame['subscriptionId'] != subId) return;
    _lastFrameAt = DateTime.now();
    state.applyFrame(frame, onGap: _resync);
  }

  void _startWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_disposed) return;
      final quietSeconds = DateTime.now().difference(_lastFrameAt).inSeconds;
      if (quietSeconds < 20) return;
      final streaming = state.rows.any((r) => r['state'] == 'streaming');
      if (state.isRunning || streaming) {
        _transport.log(
          '[v4] watchdog: no frames for ${quietSeconds}s while active, resync',
        );
        _resync();
      } else if (!state.ready) {
        // Never-ready blind spot: the subscribe acked but no snapshot ever
        // arrived. Observed live (2026-09-15): the desktop bridge can die
        // mid-push of a large subagent snapshot, and without a forced
        // resync the subscription idles forever — the detail page would
        // spin indefinitely.
        _transport.log(
          '[v4] watchdog: no snapshot ${quietSeconds}s after subscribe, resync',
        );
        _resync();
      }
    });
  }
}

class _LogicalFrameAssembly {
  final int count;
  final List<Uint8List?> parts;
  final DateTime createdAt = DateTime.now();
  int received = 0;

  _LogicalFrameAssembly(this.count) : parts = List.filled(count, null);

  void add(int index, Uint8List data) {
    if (index < 0 || index >= count) return;
    if (parts[index] == null) received += 1;
    parts[index] = data;
  }

  bool get isComplete => received == count;

  Uint8List assemble() {
    final builder = BytesBuilder();
    for (final p in parts) {
      if (p != null) builder.add(p);
    }
    return builder.toBytes();
  }
}

class SessionsIndexSubscription extends _SubscriptionBase<SessionsIndexState> {
  /// Internal: created by [ConversationTransport.subscribeSessionsIndex];
  /// not public API.
  SessionsIndexSubscription(ConversationTransport transport)
    : super(transport, SessionsIndexState(), 'v4-si');

  /// Monotonic subscription generation: bumped on every successful
  /// (re)subscribe — `start()` covers both the initial open and a bridge
  /// swing's `_resubscribe` (the ~45s replayGraceExceeded pendulum).
  /// DeviceSession keys its tombstone diff baseline to this value (read
  /// at diff time): a new generation's frames may only ESTABLISH a fresh
  /// baseline, never diff against the previous generation's ids (10-11
  /// tombstone false positive, findings §4-A).
  int _generation = 0;

  /// See [_generation].
  int get generation => _generation;

  /// Kind of the logical frame currently being applied to [state]
  /// (`payload.kind`: 'snapshot' | 'deltas'); null outside a frame.
  /// Published just before `applyFrame` so synchronous state listeners
  /// (the tombstone producer) can tell frame kinds apart — cross-kind
  /// "missing means deleted" diffing is what produced the 10-11 false
  /// positives (findings §4-B).
  String? _applyingFrameKind;

  /// See [_applyingFrameKind].
  String? get applyingFrameKind => _applyingFrameKind;

  @override
  String get _frameEventName => 'onDynamicSessionsIndexFrame';
  @override
  String get _subscribeMethod => 'subscribeSessionsIndexV4';
  @override
  String get _unsubscribeMethod => 'unsubscribeSessionsIndexV4';
  @override
  String get _resyncMethod => 'resyncSessionsIndexV4';
  @override
  Map<String, dynamic> get _subscribeArgs => const {
    'runtimePolicy': 'existing-only',
  };
  @override
  Map<String, dynamic> get _unsubscribeArgs => const {
    'runtimePolicy': 'existing-only',
  };
  @override
  Map<String, dynamic> get _resyncArgs => const {
    'runtimePolicy': 'existing-only',
  };
  @override
  String get topic =>
      'sessions-index/${_transport.scope['workspaceIdentity'] ?? _transport.scope['workspacePath']}';
  @override
  int get _resyncSeq => state.seq;
  @override
  String? get _resyncEpoch => state.logEpoch;

  @override
  Future<void> _onDispose() async {
    state.deactivateState();
  }

  @override
  void _onSubscribeAck(Map<String, dynamic> ack) {
    // Bumped BEFORE start() replays the staged frames (they apply right
    // after this hook), so the new generation's first frame — staged or
    // pushed — can only establish a fresh tombstone baseline.
    _generation++;
  }

  @override
  void _acceptLogicalFrame(Map<String, dynamic> frame) {
    final subId = subscriptionId;
    if (subId == null || frame['subscriptionId'] != subId) return;
    _applyingFrameKind = (frame['payload'] as Map?)?['kind'] as String?;
    state.applyFrame(frame, onGap: _resync);
    _applyingFrameKind = null;
  }
}
