import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'relay_transport.dart';

/// One live relay socket (production wraps a [WebSocketChannel]; tests fake it).
abstract interface class RelaySocket {
  Future<void> get ready;
  Stream<dynamic> get stream;
  int? get closeCode;
  String? get closeReason;
  void send(String data);
  Future<void> close([int? code, String? reason]);
}

class WebSocketRelaySocket implements RelaySocket {
  final WebSocketChannel _channel;
  WebSocketRelaySocket(this._channel);
  @override
  Future<void> get ready => _channel.ready;
  @override
  Stream<dynamic> get stream => _channel.stream;
  @override
  int? get closeCode => _channel.closeCode;
  @override
  String? get closeReason => _channel.closeReason;
  @override
  void send(String data) => _channel.sink.add(data);
  @override
  Future<void> close([int? code, String? reason]) =>
      _channel.sink.close(code, reason);
}

RelaySocket defaultRelaySocketFactory(Uri uri) =>
    WebSocketRelaySocket(WebSocketChannel.connect(uri));

enum InboundKind { authChallenge, pairStatus, data, error, unknown }

/// Classified inbound frame; the wire decides [kind] (V1 casts strictly, V2
/// accepts only strings), the kernel only reacts to the class.
class InboundFrame {
  final InboundKind kind;
  final Map<String, dynamic> raw;
  final String? pairStatus, errorCode, errorMessage;
  final Map<String, dynamic>? payload;
  const InboundFrame(this.kind, this.raw,
      {this.pairStatus, this.payload, this.errorCode, this.errorMessage});
}

/// Shared JSON frame classifier. [strictCasts] is V1's original behaviour
/// (`as String?`, throws on a non-string); V2 accepts only strings.
InboundFrame? decodeRelayFrame(String raw, {required bool strictCasts}) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic> || !decoded.containsKey('type')) {
    return null;
  }
  switch (decoded['type']) {
    case 'auth_challenge':
      return InboundFrame(InboundKind.authChallenge, decoded);
    case 'auth_ack':
    case 'pair_status_ack':
      final status = strictCasts
          ? decoded['pair_status'] as String?
          : decoded['pair_status'] is String
              ? decoded['pair_status'] as String
              : null;
      return InboundFrame(InboundKind.pairStatus, decoded, pairStatus: status);
    case 'data':
      final payload = decoded['payload'];
      return InboundFrame(InboundKind.data, decoded,
          payload: payload is Map<String, dynamic> ? payload : null);
    case 'error':
      return InboundFrame(InboundKind.error, decoded,
          errorCode: strictCasts
              ? decoded['code'] as String?
              : decoded['code'] is String
                  ? decoded['code'] as String
                  : null,
          errorMessage: strictCasts
              ? decoded['message'] as String?
              : decoded['message'] is String
                  ? decoded['message'] as String
                  : null);
    default:
      return InboundFrame(InboundKind.unknown, decoded);
  }
}

/// Kernel-authored frames; the wire owns each generation's field set.
sealed class OutboundFrame {
  const OutboundFrame();
}

final class RelayDataFrame extends OutboundFrame {
  final Map<String, dynamic> payload;
  const RelayDataFrame(this.payload);
}

final class RelayPairStatusQueryFrame extends OutboundFrame {
  const RelayPairStatusQueryFrame();
}

/// Generation adapter for auth + codec + socket quirks. All frame shapes stay
/// here, so the merged kernel cannot drift the wire.
abstract interface class RelayWire {
  /// Credentials before a dial: V2 fetches a fresh 60s token on every
  /// (re)connect; V1 no-op. Throws [RelayWireException] on failure.
  Future<void> prepare();

  /// Dials one socket (the kernel attaches the listener). Throws on failure.
  Future<RelaySocket> open();

  /// Owns the socket and sends `auth_init`; the kernel calls this after it
  /// attaches the subscription, before `authenticating`.
  void onConnected(RelaySocket socket);

  /// Frame-level auth reaction (V1 `auth_challenge` → `auth_response`;
  /// V2 no-op — the token was fetched in [prepare]).
  void onInbound(InboundFrame frame);
  String encode(OutboundFrame frame);
  InboundFrame? decode(String raw);
  void dispose();

  /// V1 leaves the subscription attached so a terminal error close flows
  /// through the close policy; V2 drops the socket silently.
  bool get terminalCloseThroughHandler;
}

/// Liveness — PERMANENT DIVERGENCE, never unify: V1 only refreshes on a pair
/// status (widening to "any frame" lets unrelated traffic mask a dead pair
/// channel); V2 refreshes on any decoded frame and resets the stamp per
/// connect.
abstract interface class RelayLiveness {
  DateTime initial(DateTime now);
  bool get resetsOnConnect;
  bool refreshes(InboundFrame frame);
}

/// Pairing policy (divergence #9/#11).
abstract interface class RelayPairPolicy {
  bool startHeartbeatOnWaiting(bool wasPaired);
  bool get resetWasPairedOnStart;
}

/// Action mapping for `error` frames (not a bare code table).
enum RelayErrorAction {
  ignore,
  kicked,
  nonFatalWaiting,
  terminal,
  defaultTerminal,
}

abstract interface class RelayErrorActions {
  RelayErrorAction actionFor(String? code, String? message);
}

/// Connect-failure routing (divergence #8): V1 routes dial failures through
/// the close policy and never throws from start; V2 publishes the failure and
/// reports it through [ConnectOutcome].
enum RelayConnectFailurePolicy { closeHandler, publishFailure }

/// Timing table. Nulls are meaningful: V1 has no auth-ack timeout, V2 has no
/// waiting timeout; only V2 has the long-backoff tier.
class RelayTimings {
  final Duration heartbeatInterval, heartbeatAckTimeout, reconnectWaitTimeout;
  final Duration backoffBase, backoffCap, longBackoff;
  final Duration? authAckTimeout, waitingTimeout;
  final int? longBackoffAfterFails;
  const RelayTimings(
      {required this.heartbeatInterval,
      required this.heartbeatAckTimeout,
      required this.reconnectWaitTimeout,
      this.authAckTimeout,
      this.waitingTimeout,
      this.backoffBase = const Duration(seconds: 1),
      this.backoffCap = const Duration(seconds: 15),
      this.longBackoffAfterFails,
      this.longBackoff = const Duration(seconds: 60)});
}

/// Reconnect backoff pure function (both curves; table-tested). Without
/// [longBackoffAfterFails] this is the V1 curve
/// (`1000 * (1 << attempt.clamp(0,4))` clamped 1-15s, constant forever); V2
/// drops to a fixed [longBackoff] once `attempt >= longBackoffAfterFails`.
Duration relayReconnectDelay(int attempt,
    {Duration base = const Duration(seconds: 1),
    Duration cap = const Duration(seconds: 15),
    int? longBackoffAfterFails,
    Duration longBackoff = const Duration(seconds: 60)}) {
  if (longBackoffAfterFails != null && attempt >= longBackoffAfterFails) {
    return longBackoff;
  }
  final ms = base.inMilliseconds * (1 << attempt.clamp(0, 4));
  return Duration(
      milliseconds: ms.clamp(base.inMilliseconds, cap.inMilliseconds));
}

/// Non-strategy infrastructure knobs: log prefix, legacy telemetry set and
/// the V2 `unhandled pair_status` line. New V2 telemetry is exempt from the
/// zero-wire-change gate.
class RelayDiagnostics {
  final String logPrefix;
  final bool legacyEvents, logUnhandledPairStatus;
  const RelayDiagnostics(
      {required this.logPrefix,
      this.legacyEvents = false,
      this.logUnhandledPairStatus = false});
}

/// Wire failure raised by [RelayWire.prepare]/[RelayWire.open].
class RelayWireException implements Exception {
  final String reason;
  final String? message;
  const RelayWireException(this.reason, [this.message]);
  @override
  String toString() => message == null ? reason : '$reason: $message';
}

/// One kernel `start()`/connect attempt. V1 ignores it; the V2 adapter maps
/// anything but [ConnectOpened] to a `RelayV2StartException`.
sealed class ConnectOutcome {
  const ConnectOutcome();
}

final class ConnectOpened extends ConnectOutcome {
  const ConnectOpened();
}

final class ConnectAuthRequired extends ConnectOutcome {
  final String? message;
  const ConnectAuthRequired(this.message);
}

final class ConnectFailed extends ConnectOutcome {
  final String reason;
  final String? message;
  const ConnectFailed(this.reason, this.message);
}

/// Shared connection kernel: socket lifecycle, inbound dispatch, outbound
/// queue, pair state machine, heartbeat, reconnect backoff and diagnostics.
/// Policy enters through [RelayWire], [RelayLiveness], [RelayTimings],
/// [RelayErrorActions] and [RelayPairPolicy]; clock/log are infrastructure.
/// The kernel never imports an adapter. [RelayLiveness] is a permanent fork.
class RelayConnectionKernel {
  final RelayWire wire;
  final RelayLiveness liveness;
  final RelayTimings timings;
  final RelayErrorActions errorActions;
  final RelayPairPolicy pairPolicy;
  final RelayDiagnostics diagnostics;
  final RelayConnectFailurePolicy connectFailurePolicy;
  final void Function(String line)? onLog;
  final DateTime Function() _now;
  late DateTime _lastAliveAt;

  RelayConnectionKernel(
      {required this.wire,
      required this.liveness,
      required this.timings,
      required this.errorActions,
      required this.pairPolicy,
      required this.diagnostics,
      required this.onLog,
      required DateTime Function() now,
      this.connectFailurePolicy = RelayConnectFailurePolicy.closeHandler})
      : _now = now {
    _lastAliveAt = liveness.initial(now());
  }

  final _state = ValueNotifier<RelayState>(RelayState.idle);
  final _payloadController = StreamController<Map<String, dynamic>>.broadcast();
  final _failureController = StreamController<RelayFailure>.broadcast();
  ValueListenable<RelayState> get stateListenable => _state;
  RelayState get state => _state.value;
  Stream<Map<String, dynamic>> get payloads => _payloadController.stream;
  Stream<RelayFailure> get failures => _failureController.stream;

  RelaySocket? _socket;
  StreamSubscription? _socketSub;
  bool _wasPaired = false, _intentionallyClosed = false, _disposed = false;
  int _reconnectAttempt = 0;
  bool _pairStatusReported = false; // V1: transition-driven, across reconnects
  String? _lastReportedPairStatus;

  /// Per-socket diagnostic gate: the relay hard-fails auth when a data frame
  /// precedes it, so diagnostics stay offline until this socket has seen its
  /// first pair status. Closed at every connect.
  bool _diagAuthOk = false;
  Timer? _heartbeatTimer, _waitingTimer, _authAckTimer;
  Timer? _reconnectTimer, _rewaitTimer;

  /// Test seam: diagnostic payloads go here instead of the socket when set.
  @visibleForTesting
  void Function(Map<String, dynamic> payload)? diagnosticSink;

  void _log(String line) => onLog?.call('${diagnostics.logPrefix} $line');

  void _setState(RelayState s) {
    final previous = _state.value;
    _state.value = s;
    _log('state -> $s');
    if (s == previous) return;
    sendMobileDiagnostic('state-transition',
        {'state': s.name, 'previousState': previous.name});
  }

  /// V2 maps a non-[ConnectOpened] outcome to its typed exception; V1
  /// ignores it (start never throws).
  Future<ConnectOutcome> start() async {
    _disposed = false;
    _intentionallyClosed = false;
    _reconnectAttempt = 0;
    if (pairPolicy.resetWasPairedOnStart) _wasPaired = false;
    _setState(RelayState.connecting);
    return _connect();
  }

  Future<ConnectOutcome> _connect() async {
    await _socketSub?.cancel();
    _socketSub = null;
    final previous = _socket;
    _socket = null;
    _authAckTimer?.cancel();
    _stopHeartbeat();
    try {
      await previous?.close();
    } catch (_) {}
    _diagAuthOk = false;
    try {
      await wire.prepare();
    } on RelayWireException catch (e) {
      return _connectFailure(e.reason, e.message);
    } catch (e) {
      return _connectFailure('relay-unavailable', '$e');
    }
    if (_disposed) return const ConnectFailed('relay-unavailable', null);
    RelaySocket socket;
    try {
      socket = await wire.open();
    } on RelayWireException catch (e) {
      return _connectFailure(e.reason, e.message);
    } catch (e) {
      return _connectFailure('relay-unavailable', '$e');
    }
    if (_disposed) {
      try {
        await socket.close();
      } catch (_) {}
      return const ConnectFailed('relay-unavailable', null);
    }
    _socket = socket;
    _socketSub = socket.stream.listen(_onRawMessage, onError: (Object e) {
      _log('socket error: $e');
      if (diagnostics.legacyEvents) {
        sendMobileDiagnostic('socket-error', {'failureMessage': '$e'});
      }
    }, onDone: () {
      _handleSocketClosed(socket.closeCode ?? 1006, socket.closeReason);
    });
    if (liveness.resetsOnConnect) _lastAliveAt = _now();
    _setState(RelayState.authenticating);
    wire.onConnected(socket);
    final authAckTimeout = timings.authAckTimeout;
    if (authAckTimeout != null) {
      _authAckTimer?.cancel();
      _authAckTimer = Timer(authAckTimeout, () {
        if (state == RelayState.authenticating && !_disposed) {
          _log('auth_ack timeout');
          _dropSocketAndHandle(1006, 'auth_ack timeout');
        }
      });
    }
    return const ConnectOpened();
  }

  ConnectOutcome _connectFailure(String reason, String? message) {
    if (connectFailurePolicy == RelayConnectFailurePolicy.closeHandler) {
      _handleSocketClosed(1006, message ?? reason);
      return ConnectFailed('relay-unavailable', message);
    }
    _publishStartFailure(reason, message);
    return reason == 'auth-required'
        ? ConnectAuthRequired(message)
        : ConnectFailed(reason, message);
  }

  void _publishStartFailure(String reason, String? message) {
    if (_disposed || _failureController.isClosed) return;
    _setState(RelayState.error);
    _failureController.add(RelayFailure(reason, message));
  }

  void _onRawMessage(dynamic data) {
    InboundFrame? frame;
    try {
      final text = data is String ? data : utf8.decode(data as List<int>);
      _log('<< $text');
      frame = wire.decode(text);
    } catch (e) {
      _log('bad frame: $e');
      return;
    }
    if (frame == null) return;
    if (liveness.refreshes(frame)) _lastAliveAt = _now();
    wire.onInbound(frame);
    switch (frame.kind) {
      case InboundKind.authChallenge:
        break;
      case InboundKind.pairStatus:
        if (frame.pairStatus == 'waiting' || frame.pairStatus == 'matched') {
          _authAckTimer?.cancel();
        }
        _applyPairStatus(frame.pairStatus);
        break;
      case InboundKind.data:
        final payload = frame.payload;
        if (payload != null && !_payloadController.isClosed) {
          _payloadController.add(payload);
        }
        break;
      case InboundKind.error:
        _handleRelayError(frame.errorCode, frame.errorMessage);
        break;
      case InboundKind.unknown:
        break;
    }
  }

  void _applyPairStatus(String? status) {
    final wasPaired = _wasPaired;
    _diagAuthOk = true; // auth accepted; diagnostics may flow from here
    if (diagnostics.legacyEvents &&
        (!_pairStatusReported || status != _lastReportedPairStatus)) {
      _pairStatusReported = true;
      _lastReportedPairStatus = status;
      sendMobileDiagnostic('pair-status',
          {if (status != null) 'pairStatus': status, 'state': state.name});
    }
    if (status == 'waiting') {
      _setState(RelayState.waiting);
      if (wasPaired) {
        _clearWaitingTimers();
        if (pairPolicy.startHeartbeatOnWaiting(wasPaired)) _startHeartbeat();
        _armRewaitTimer();
        if (diagnostics.legacyEvents) {
          sendMobileDiagnostic('recover-scheduled', {'state': state.name});
        }
      } else {
        if (pairPolicy.startHeartbeatOnWaiting(wasPaired)) _startHeartbeat();
        if (timings.waitingTimeout != null) _startWaitingTimer();
      }
      return;
    }
    if (status == 'matched') {
      _rewaitTimer?.cancel();
      _reconnectAttempt = 0;
      _clearWaitingTimers();
      _setState(RelayState.paired);
      _wasPaired = true;
      _startHeartbeat();
      _flushOutboundQueue();
      return;
    }
    if (diagnostics.logUnhandledPairStatus) _log('unhandled pair_status=$status');
  }

  void _handleRelayError(String? code, String? message) {
    _log('error frame: $code $message');
    switch (errorActions.actionFor(code, message)) {
      case RelayErrorAction.ignore:
        break;
      case RelayErrorAction.nonFatalWaiting:
        _log('desktop offline; waiting for it to come back');
        _authAckTimer?.cancel();
        _setState(RelayState.waiting);
        _startHeartbeat();
        break;
      case RelayErrorAction.kicked:
        _failTerminal(RelayState.kicked, 'kicked', message,
            throughHandler: wire.terminalCloseThroughHandler);
        break;
      case RelayErrorAction.terminal:
        _failTerminal(RelayState.error, 'auth-required', message,
            throughHandler: false);
        break;
      case RelayErrorAction.defaultTerminal:
        _failTerminal(RelayState.error, 'unexpected-error',
            message ?? 'relay error $code', throughHandler: false);
        break;
    }
  }

  void _failTerminal(RelayState terminalState, String reason, String? message,
      {required bool throughHandler}) {
    if (_disposed) return;
    _setState(terminalState);
    _intentionallyClosed = true;
    if (!_failureController.isClosed) {
      _failureController.add(RelayFailure(reason, message));
    }
    if (throughHandler) {
      try {
        unawaited(_socket?.close());
      } catch (_) {}
    } else {
      _dropSocketAndHandle(
          terminalState == RelayState.kicked ? 4009 : 1006, reason,
          handleClose: false);
    }
  }

  void _dropSocketAndHandle(int code, String? reason,
      {bool handleClose = true}) {
    _stopHeartbeat();
    _authAckTimer?.cancel();
    unawaited(_socketSub?.cancel());
    _socketSub = null;
    final socket = _socket;
    _socket = null;
    try {
      unawaited(socket?.close());
    } catch (_) {}
    if (handleClose) _handleSocketClosed(code, reason);
  }

  void _handleSocketClosed(int code, String? reason) {
    if (_disposed) return;
    _stopHeartbeat();
    _clearWaitingTimers();
    _authAckTimer?.cancel();
    final mapped = relayCloseReason(code);
    _log('closed code=$code reason=$reason mapped=$mapped');
    if (diagnostics.legacyEvents) {
      sendMobileDiagnostic('socket-close', {
        'closeCode': code,
        if (reason != null) 'closeReason': reason,
        'wasClean': code == 1000,
        'wasPaired': _wasPaired,
      });
    }
    if (_intentionallyClosed) return;
    if (_wasPaired || mapped == 'desktop-disconnected') {
      _scheduleReconnect();
      return;
    }
    _setState(RelayState.error);
    if (!_failureController.isClosed) {
      _failureController.add(RelayFailure(
          mapped ?? 'relay-unavailable', reason ?? 'connection closed ($code)'));
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(timings.heartbeatInterval, (_) {
      if (state != RelayState.paired && state != RelayState.waiting) return;
      if (_now().difference(_lastAliveAt) > timings.heartbeatAckTimeout) {
        _log('heartbeat ack timeout, reconnecting');
        unawaited(_reconnect());
        return;
      }
      _sendFrame(const RelayPairStatusQueryFrame());
    });
  }

  void _stopHeartbeat() => _heartbeatTimer?.cancel();

  void _startWaitingTimer() {
    _waitingTimer?.cancel();
    _waitingTimer = Timer(timings.waitingTimeout!, () {
      if (state == RelayState.waiting && !_wasPaired) {
        _setState(RelayState.error);
        if (!_failureController.isClosed) {
          _failureController.add(const RelayFailure(
              'invalid-mobile-connection',
              'Desktop did not match this mobile connection before the waiting timeout.'));
        }
      }
    });
  }

  void _armRewaitTimer() {
    _rewaitTimer?.cancel();
    _rewaitTimer = Timer(timings.reconnectWaitTimeout, () {
      if (_wasPaired && state == RelayState.waiting && !_disposed) {
        _log('re-pair stuck in waiting, reconnecting');
        unawaited(_reconnect());
      }
    });
  }

  void _clearWaitingTimers() {
    _waitingTimer?.cancel();
    _rewaitTimer?.cancel();
  }

  void _scheduleReconnect() {
    if (_disposed || _intentionallyClosed) return;
    _setState(RelayState.reconnecting);
    final delay = relayReconnectDelay(_reconnectAttempt,
        base: timings.backoffBase,
        cap: timings.backoffCap,
        longBackoffAfterFails: timings.longBackoffAfterFails,
        longBackoff: timings.longBackoff);
    _reconnectAttempt += 1;
    _log('reconnect in ${delay.inMilliseconds}ms (attempt $_reconnectAttempt)');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      if (!_disposed) unawaited(_reconnect());
    });
  }

  Future<void> _reconnect() async {
    _reconnectTimer?.cancel();
    // The scheduled-backoff path already sits in reconnecting and never
    // emitted recover-start; heartbeat/rewait reconnects do.
    if (diagnostics.legacyEvents && state != RelayState.reconnecting) {
      sendMobileDiagnostic('recover-start', {'state': state.name});
    }
    _setState(RelayState.reconnecting);
    ConnectOutcome outcome;
    try {
      outcome = await _connect();
    } catch (e) {
      _log('reconnect failed: $e');
      outcome = ConnectFailed('relay-unavailable', '$e');
    }
    if (outcome is ConnectOpened || _disposed) return;
    if (outcome is ConnectAuthRequired) return;
    if (connectFailurePolicy == RelayConnectFailurePolicy.closeHandler) return;
    if (!_intentionallyClosed) _scheduleReconnect();
  }

  /// Only payloads queue (controls are dropped without a socket); stored as
  /// payload, not encoded frame — V1 regenerates `client_ts` on flush, V2
  /// adds none. Flushed in order on `matched`.
  final _outboundQueue = <Map<String, dynamic>>[];

  void sendPayload(Map<String, dynamic> payload) {
    if (state != RelayState.paired || _socket == null) {
      if (_outboundQueue.length < 100) {
        _log('queued (state=$state): ${payload['zcode_type']}');
        _outboundQueue.add(payload);
      }
      return;
    }
    _sendFrame(RelayDataFrame(payload));
  }

  void _flushOutboundQueue() {
    if (_outboundQueue.isEmpty) return;
    _log('flushing ${_outboundQueue.length} queued payload(s)');
    final queued = List<Map<String, dynamic>>.from(_outboundQueue);
    _outboundQueue.clear();
    for (final payload in queued) {
      _sendFrame(RelayDataFrame(payload));
    }
  }

  /// mobile-diagnostic (G7): fire-and-forget telemetry, never queued/replayed
  /// and never a failure surface; dropped while the socket is gone or not
  /// authenticated.
  void sendMobileDiagnostic(String event, [Map<String, dynamic>? fields]) {
    try {
      final payload = <String, dynamic>{
        'zcode_type': 'mobile-diagnostic',
        'event': event,
        'timestamp': _now().millisecondsSinceEpoch,
        ...?fields,
      };
      final sink = diagnosticSink;
      if (sink != null) {
        sink(payload);
        return;
      }
      if (_disposed || _socket == null || !_diagAuthOk) return;
      _sendFrame(RelayDataFrame(payload));
    } catch (_) {
      // Best-effort: encoding/send failures never surface.
    }
  }

  void _sendFrame(OutboundFrame frame) {
    final socket = _socket;
    if (socket == null) return;
    final line = wire.encode(frame);
    _log('>> $line');
    socket.send(line);
  }

  @visibleForTesting
  bool get debugDiagGateOpen => _diagAuthOk;

  @visibleForTesting
  void debugApplyPairStatus(String? status) => _applyPairStatus(status);

  @visibleForTesting
  void debugHandleRelayError(String? code, String? message) =>
      _handleRelayError(code, message);

  @visibleForTesting
  Future<void> debugDropSocket() async {
    _intentionallyClosed = false;
    await _socketSub?.cancel();
    _socketSub = null;
    final socket = _socket;
    _socket = null;
    try {
      await socket?.close(3000, 'debug-drop');
    } catch (_) {}
    _handleSocketClosed(1006, 'debug-drop');
  }

  Future<void> dispose() async {
    _disposed = true;
    _intentionallyClosed = true;
    _stopHeartbeat();
    _clearWaitingTimers();
    _authAckTimer?.cancel();
    _reconnectTimer?.cancel();
    await _socketSub?.cancel();
    _socketSub = null;
    final socket = _socket;
    _socket = null;
    try {
      await socket?.close();
    } catch (_) {}
    _setState(RelayState.closed);
    await _payloadController.close();
    await _failureController.close();
    wire.dispose();
  }
}
