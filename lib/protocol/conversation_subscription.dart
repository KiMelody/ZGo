// Newer style lints are suppressed so this file keeps its protocol
// handling readable as a single, self-contained unit.
// ignore_for_file: use_null_aware_elements, prefer_initializing_formals
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:clock/clock.dart';
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

  /// Recently applied logical-frame ids (insertion-ordered, bounded by
  /// [_seenLogicalFrameIdsLimit]). Only consulted when
  /// [_dedupeLogicalFrames] is on.
  final _seenLogicalFrameIds = <String>{};

  /// Replay window of [_seenLogicalFrameIds]. A sibling index subscription
  /// attaching to the same channel replays the frames already delivered in
  /// the last few seconds (probe R4, 2026-10-28); a couple of dozen ids
  /// covers that window with headroom.
  static const int _seenLogicalFrameIdsLimit = 64;

  /// Whether a complete logical frame whose `logicalFrameId` was already
  /// applied is dropped at the wire ingress (replay guard). On for the
  /// sessions-index subscription only: several index subscriptions share
  /// one channel event stream (design 10-28), and a replayed `deltas` frame
  /// would trip the `fromSeq != seq` gap guard and resync-storm. Off keeps
  /// the pre-10-28 conversation subscription byte-identical.
  bool get _dedupeLogicalFrames => false;

  /// Returns false when [id] was already applied (the caller must drop the
  /// frame); records it otherwise, evicting the oldest id past the bound.
  bool _markLogicalFrameSeen(String id) {
    if (!_seenLogicalFrameIds.add(id)) return false;
    if (_seenLogicalFrameIds.length > _seenLogicalFrameIdsLimit) {
      _seenLogicalFrameIds.remove(_seenLogicalFrameIds.first);
    }
    return true;
  }

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

  /// Called when an automatic resubscribe attempt fails ([start] rethrows to
  /// its caller instead of retrying). Default no-op; the sessions-index
  /// sidecar manager uses it to classify a benign cold-runtime refusal and
  /// cool the workspace down instead of hammering the retry queue.
  void _onSubscribeFailure(Object error) {}

  int get _resyncSeq => 0;
  String? get _resyncEpoch => null;

  Map<String, dynamic> _requestScope() => _transport.scope;

  void _purgeFragments() {
    if (_disposed) return;
    final stale = <String>[];
    final now = clock.now();
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
      arg: _requestScope(),
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
      _onSubscribeFailure(e);
      // The failure hook may have disposed this subscription (a benign
      // cold-runtime sidecar refusal does) — never arm a retry then.
      if (_disposed) return;
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
          // Replay guard (design 10-28): a sibling index subscription
          // attaching to the same channel re-delivers frames already
          // applied here (probe R4: one snapshot, same logicalFrameId,
          // received twice). Fragments keep their own id-keyed assembly —
          // every fragment of one logical frame shares the id — so their
          // guard runs on the assembled frame in [_acceptFragment].
          final logicalId = frame['logicalFrameId'];
          if (_dedupeLogicalFrames &&
              logicalId is String &&
              !_markLogicalFrameSeen(logicalId)) {
            _transport.log('[$_logTag] dropped replayed frame $logicalId');
            return;
          }
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
          // The replay guard runs on the ASSEMBLED frame (check P2-3): the
          // per-fragment ingress must not dedupe (all fragments of one
          // logical frame share its id), but a replayed assembly is the
          // same replay a complete frame sees.
          if (_dedupeLogicalFrames && !_markLogicalFrameSeen(id)) {
            _transport.log('[$_logTag] dropped replayed frame $id');
            return;
          }
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

  DateTime _lastFrameAt = clock.now();
  Timer? _watchdog;

  /// Consecutive no-content resyncs with the content still frozen — drives
  /// [ConversationTransport.contentSilenceBackoff] (20→40→80→120s). Reset by
  /// any [ConversationState.contentChangeSeq] movement and by a fresh
  /// subscribe generation.
  int _contentSilenceStreak = 0;

  /// `contentChangeSeq` observed at the previous watchdog tick — the
  /// no-content criterion's "did content move since last look" comparator;
  /// [_lastContentChangeAt] is the last tick that saw movement.
  int _contentChangeMark = 0;
  DateTime _lastContentChangeAt = clock.now();

  /// Words already drained into the drift log — one line per op/path per
  /// subscription lifetime (R3).
  final _loggedUnknownDeltaOps = <String>{};
  final _loggedUnknownDeltaPaths = <String>{};

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
    // The FRAME clock restarts here: the old timestamps belong to the dead
    // subscription id, and a fresh subscribe is a fresh wire generation.
    _lastFrameAt = clock.now();
    // The CONTENT clock must NOT restart. Content is a property of the
    // conversation, not of the wire generation: a bridge that keeps
    // flapping faster than the silence window (live: degraded→reopened
    // every 30–120s) would otherwise reset the window on every resubscribe
    // and leave the no-content criterion permanently unreachable — the
    // exact drift it exists to catch. If the resubscribe lands a snapshot,
    // _applySnapshot advances contentChangeSeq and the next tick resets the
    // window through the normal content-movement path.
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
    _lastFrameAt = clock.now();
    state.applyFrame(frame, onGap: _resync);
    _drainUnknownDeltaWords();
  }

  /// Drift observability (11-04 R3): after each applied frame, log any
  /// unknown delta op / row.delta path the state recorded — once per word
  /// per subscription lifetime, on the frame that carried it (no extra
  /// timer, no seq/notify side effects).
  void _drainUnknownDeltaWords() {
    for (final op in state.unknownDeltaOps) {
      if (_loggedUnknownDeltaOps.add(op)) {
        _transport.log('[$_logTag] unknown delta op: $op');
      }
    }
    for (final path in state.unknownDeltaPaths) {
      if (_loggedUnknownDeltaPaths.add(path)) {
        _transport.log('[$_logTag] unknown row.delta path: $path');
      }
    }
  }

  /// Watchdog (design §3.2): three OR-ed self-heal criteria, each logging
  /// its own reason. Runs on the transport's injectable cadence with
  /// [clock.now] as the single time source.
  ///
  /// Window vocabulary: the frame-silence window IS the base
  /// [ConversationTransport.contentSilenceThreshold] (stock 20s, the value
  /// the timeout table already records) — one seam, no second magic
  /// number. Only the content criterion escalates; no-frames and never-ready
  /// keep the base window (each has its own reconnect chain behind it).
  void _startWatchdog() {
    _watchdog?.cancel();
    final tick = _transport.watchdogTickInterval;
    final frameSilenceWindow = _transport.contentSilenceThreshold;
    _watchdog = Timer.periodic(tick, (_) {
      if (_disposed) return;
      final now = clock.now();
      final frameSilent = now.difference(_lastFrameAt) >= frameSilenceWindow;

      // Criterion 1 — no frames (existing): the wire itself went silent
      // while the turn should be producing. Claims the reason first so the
      // two quiet criteria never double-fire on one tick.
      if (frameSilent && (state.isRunning || state.anyStreaming)) {
        _transport.log(
          '[$_logTag] watchdog: no frames for '
          '${now.difference(_lastFrameAt).inSeconds}s while active, resync',
        );
        _resync();
        return;
      }

      // Criterion 2 — no content (new): frames arrive, but every one of
      // them is a no-op (a dropped wire face, a content-freezing drift).
      // `activeStrict` excludes the parked-queue case by construction. The
      // window escalates 20→40→80→120s while the content stays frozen and
      // drops back to the base on any content movement.
      if (state.ready) {
        if (state.contentChangeSeq != _contentChangeMark) {
          _contentChangeMark = state.contentChangeSeq;
          _lastContentChangeAt = now;
          _contentSilenceStreak = 0;
        } else {
          final window = _transport.contentSilenceBackoff(
            _contentSilenceStreak,
          );
          final silent = now.difference(_lastContentChangeAt);
          if (silent >= window && state.activeStrict) {
            _contentSilenceStreak += 1;
            _transport.log(
              '[$_logTag] watchdog: no content for ${silent.inSeconds}s '
              'while active, resync (window ${window.inSeconds}s)',
            );
            _resync();
            return;
          }
        }
      }

      // Criterion 3 — never-ready (existing): the subscribe acked but no
      // snapshot ever arrived (desktop bridge died mid-push of a large
      // subagent snapshot, 2026-09-15), so the page would spin forever.
      if (!state.ready && frameSilent) {
        _transport.log(
          '[$_logTag] watchdog: no snapshot '
          '${now.difference(_lastFrameAt).inSeconds}s after subscribe, resync',
        );
        _resync();
      }
    });
  }
}

class _LogicalFrameAssembly {
  final int count;
  final List<Uint8List?> parts;
  final DateTime createdAt = clock.now();
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
  /// Sidecar scope override (design 10-28): when set, this subscription
  /// targets [scope] — `{workspacePath, workspaceIdentity?}` — on the
  /// transport's channel, i.e. a DIFFERENT workspace over the SAME bridge
  /// (live-probed: the subscribe self-addresses by scope and answers with
  /// its own subscriptionId + `sessions-index/<key>` topic). Null keeps the
  /// pre-10-28 single-subscription shape byte-identical.
  final Map<String, dynamic>? scope;

  /// Automatic-resubscribe failure hook (design 10-28). The state layer
  /// classifies a benign cold-runtime refusal from it and cools the
  /// workspace down; every other failure keeps the built-in retry.
  final void Function(Object error)? onSubscribeFailure;

  /// Omits `runtimePolicy` from THIS subscription's subscribe frame, which
  /// the desktop reads as the default `start-if-needed` policy
  /// (spec/protocol/wire-3-18-2.md §1): the fallback leg for desktops that
  /// do not serve `initializeWorkspace`. False keeps the long-standing
  /// `existing-only` frame byte-identical. Unsubscribe/resync frames are
  /// never affected — they cannot start a runtime.
  final bool omitRuntimePolicy;

  /// Internal: created by [ConversationTransport.subscribeSessionsIndex];
  /// not public API.
  SessionsIndexSubscription(
    ConversationTransport transport, {
    this.scope,
    this.onSubscribeFailure,
    this.omitRuntimePolicy = false,
  }) : super(transport, SessionsIndexState(), 'v4-si');

  @override
  Map<String, dynamic> _requestScope() => scope ?? super._requestScope();

  @override
  void _onSubscribeFailure(Object error) => onSubscribeFailure?.call(error);

  /// Index subscriptions share one channel event stream with their
  /// siblings — replayed logical frames must not re-enter the state
  /// machine (see [_dedupeLogicalFrames]).
  @override
  bool get _dedupeLogicalFrames => true;

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
  Map<String, dynamic> get _subscribeArgs => omitRuntimePolicy
      ? const {}
      : const {'runtimePolicy': 'existing-only'};
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
      'sessions-index/${_requestScope()['workspaceIdentity'] ?? _requestScope()['workspacePath']}';
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
    // A new subscription generation may restart the desktop's
    // logicalFrameId sequence (unverified — the probe never recorded the
    // id shape); a kept replay window could silently drop the new
    // generation's first frame and freeze the index (check P2-4). The
    // sibling-fanout replay this guard exists for is re-recorded as the
    // new generation's frames arrive.
    _seenLogicalFrameIds.clear();
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
