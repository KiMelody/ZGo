import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'connection_params.dart';
import 'device_info.dart';
import 'proof.dart';

enum RelayState {
  idle,
  connecting,
  authenticating,
  waiting,
  paired,
  reconnecting,
  error,
  kicked,
  closed,
}

class RelayFailure {
  final String reason;
  final String? message;
  const RelayFailure(this.reason, [this.message]);

  @override
  String toString() => message == null ? reason : '$reason: $message';
}

/// Close-code mapping.
String? relayCloseReason(int code) {
  switch (code) {
    case 4004:
      return 'session-not-found';
    case 4009:
      return 'session-conflict';
    case 4010:
      return 'desktop-disconnected';
    case 4011:
      return 'session-expired';
    case 4012:
      return 'workspace-closed';
    case 4013:
      return 'invalid-mobile-connection';
    default:
      return null;
  }
}

/// Reimplementation of the relay terminal socket (`pen` class in the web
/// client). JSON text frames over `wss://<host>/ws`.
class RelayClient {
  final RemoteConnectionParams params;
  final void Function(String line)? onLog;

  static const heartbeatInterval = Duration(seconds: 10);
  static const heartbeatAckTimeout = Duration(seconds: 30);
  static const waitingTimeout = Duration(seconds: 30);
  static const reconnectWaitTimeout = Duration(seconds: 20);

  WebSocketChannel? _socket;
  StreamSubscription? _socketSub;

  final _state = ValueNotifier<RelayState>(RelayState.idle);
  ValueListenable<RelayState> get stateListenable => _state;
  RelayState get state => _state.value;

  final _payloadController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get payloads => _payloadController.stream;

  final _failureController = StreamController<RelayFailure>.broadcast();
  Stream<RelayFailure> get failures => _failureController.stream;

  bool _wasPaired = false;
  bool _intentionallyClosed = false;
  bool _disposed = false;
  int _reconnectAttempt = 0;
  DateTime _lastPairStatusAckAt = DateTime.now();

  /// Last pair status already reported via mobile-diagnostic. The heartbeat
  /// re-enters [_applyPairStatus] on every `pair_status_ack` (every 10s in
  /// steady state), so the diagnostic is transition-driven: report on change
  /// only.
  bool _pairStatusReported = false;
  String? _lastReportedPairStatus;

  /// Per-socket diagnostic gate. The relay hard-fails the auth handshake when
  /// any data frame precedes it (live-verified 2026-10-09: a pre-auth
  /// mobile-diagnostic turns the flow into `AUTH_FAILED` / hard close), so
  /// diagnostics stay offline until this socket has seen its first pair
  /// status. Reset on every [_connect].
  bool _diagAuthOk = false;

  Timer? _heartbeatTimer;
  Timer? _waitingTimer;
  Timer? _reconnectTimer;
  Timer? _rewaitTimer;

  RelayClient(this.params, {this.onLog});

  void _log(String line) => onLog?.call(line);

  void _setState(RelayState s) {
    final previous = _state.value;
    _state.value = s;
    _log('[relay] state -> $s');
    // Transition-driven: a re-assert of the current state (e.g. `waiting`
    // re-applied on every pair-status ack) is not a transition and must not
    // re-report.
    if (s == previous) return;
    sendMobileDiagnostic('state-transition', {
      'state': s.name,
      'previousState': previous.name,
    });
  }

  Future<void> start() async {
    _disposed = false;
    _intentionallyClosed = false;
    _reconnectAttempt = 0;
    _setState(RelayState.connecting);
    await _connect();
  }

  Future<void> _connect() async {
    _socketSub?.cancel();
    _socket?.sink.close();
    final uri = params.relayWsUri;
    _log('[relay] connecting $uri');
    WebSocketChannel socket;
    try {
      socket = WebSocketChannel.connect(uri);
      await socket.ready;
    } catch (e) {
      _log('[relay] connect failed: $e');
      _handleSocketClosed(1006, e.toString());
      return;
    }
    if (_disposed) {
      socket.sink.close();
      return;
    }
    _socket = socket;
    _diagAuthOk = false;
    _socketSub = socket.stream.listen(
      _handleRawMessage,
      onError: (e) {
        _log('[relay] socket error: $e');
        sendMobileDiagnostic('socket-error', {'failureMessage': '$e'});
      },
      onDone: () =>
          _handleSocketClosed(socket.closeCode ?? 1006, socket.closeReason),
    );
    _setState(RelayState.authenticating);
    _send({
      'type': 'auth_init',
      'role': 'terminal',
      'device_sid': params.deviceSid,
      'meta': {
        'platform': remotePlatformName(),
        'version': params.appVersion ?? 'web',
        'name': remoteAppName,
      },
      'client_ts': DateTime.now().millisecondsSinceEpoch,
    });
  }

  void _send(Map<String, dynamic> frame) {
    final socket = _socket;
    if (socket == null) return;
    _log('[relay] >> ${jsonEncode(frame)}');
    socket.sink.add(jsonEncode(frame));
  }

  /// Outbound data payloads are queued while unpaired (reconnecting /
  /// waiting) and flushed once the relay reports `matched` — otherwise
  /// requests sent during a reconnect vanish into a dead socket and the
  /// caller hangs until timeout.
  final _outboundQueue = <Map<String, dynamic>>[];

  void sendPayload(Map<String, dynamic> payload) {
    if (state != RelayState.paired || _socket == null) {
      if (_outboundQueue.length < 100) {
        _log('[relay] queued (state=$state): ${payload['zcode_type']}');
        _outboundQueue.add(payload);
      }
      return;
    }
    _send({
      'type': 'data',
      'payload': payload,
      'client_ts': DateTime.now().millisecondsSinceEpoch,
    });
  }

  void _flushOutboundQueue() {
    if (_outboundQueue.isEmpty) return;
    _log('[relay] flushing ${_outboundQueue.length} queued payload(s)');
    final queued = List<Map<String, dynamic>>.from(_outboundQueue);
    _outboundQueue.clear();
    for (final payload in queued) {
      _send({
        'type': 'data',
        'payload': payload,
        'client_ts': DateTime.now().millisecondsSinceEpoch,
      });
    }
  }

  /// Test seam (D3): when set, mobile-diagnostic payloads are delivered here
  /// instead of the socket — lets tests pin the seven event shapes without a
  /// live wire. Production leaves it null.
  @visibleForTesting
  void Function(Map<String, dynamic> payload)? debugDiagnosticSink;

  /// mobile-diagnostic (G7): fire-and-forget telemetry to the desktop's
  /// `logMobileDiagnostic` (pure log, no ack — renderer @273595704). It must
  /// never ride [sendPayload]: that path queues while unpaired and would
  /// replay a batch of stale transitions after a reconnect (design OQ3).
  /// Dropped whenever the relay is not connected (no socket / disposed);
  /// the web-environment fields (visibilityState / online /
  /// hiddenDurationMs) are omitted — ZGo is a native client (OQ4). Any
  /// failure is swallowed so diagnostics never perturb the main link.
  void sendMobileDiagnostic(String event, [Map<String, dynamic>? fields]) {
    try {
      final payload = <String, dynamic>{
        'zcode_type': 'mobile-diagnostic',
        'event': event,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        ...?fields,
      };
      final sink = debugDiagnosticSink;
      if (sink != null) {
        sink(payload);
        return;
      }
      if (_disposed || _socket == null || !_diagAuthOk) return;
      _send({
        'type': 'data',
        'payload': payload,
        'client_ts': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (_) {
      // Best-effort: encoding/send failures never surface.
    }
  }

  void _handleRawMessage(dynamic data) {
    Map<String, dynamic>? frame;
    try {
      final text = data is String ? data : utf8.decode(data as List<int>);
      _log('[relay] << $text');
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic> && decoded.containsKey('type')) {
        frame = decoded;
      }
    } catch (e) {
      _log('[relay] bad frame: $e');
      return;
    }
    if (frame == null) return;
    switch (frame['type']) {
      case 'auth_challenge':
        _send({
          'type': 'auth_response',
          'device_sid': params.deviceSid,
          'proof': calculateProof(
            passHash: params.passHash,
            nonce: frame['nonce'] as String? ?? '',
            role: 'terminal',
            deviceSid: params.deviceSid,
          ),
          'client_ts': DateTime.now().millisecondsSinceEpoch,
        });
        break;
      case 'auth_ack':
      case 'pair_status_ack':
        _applyPairStatus(frame['pair_status'] as String?);
        break;
      case 'data':
        final payload = frame['payload'];
        if (payload is Map<String, dynamic>) {
          _payloadController.add(payload);
        }
        break;
      case 'error':
        _handleRelayError(
            frame['code'] as String?, frame['message'] as String?);
        break;
    }
  }

  void _applyPairStatus(String? status) {
    _lastPairStatusAckAt = DateTime.now();
    // First pair status on this socket = auth handshake accepted by the
    // relay; diagnostics may go on the wire from here on.
    _diagAuthOk = true;
    if (!_pairStatusReported || status != _lastReportedPairStatus) {
      _pairStatusReported = true;
      _lastReportedPairStatus = status;
      sendMobileDiagnostic('pair-status', {
        if (status != null) 'pairStatus': status,
        'state': state.name,
      });
    }
    if (status == 'waiting') {
      if (_wasPaired) {
        _clearWaitingTimer();
        _setState(RelayState.waiting);
        _startHeartbeat();
        // A reconnecting mobile that was already paired should be matched
        // immediately; if the server keeps saying "waiting", force another
        // reconnect instead of hanging forever.
        _rewaitTimer?.cancel();
        _rewaitTimer = Timer(reconnectWaitTimeout, () {
          if (_wasPaired && state == RelayState.waiting && !_disposed) {
            _log('[relay] re-pair stuck in waiting, reconnecting');
            _reconnect();
          }
        });
        sendMobileDiagnostic('recover-scheduled', {'state': state.name});
      } else {
        _setState(RelayState.waiting);
        _startWaitingTimer();
      }
      return;
    }
    if (status == 'matched') {
      _rewaitTimer?.cancel();
      _reconnectAttempt = 0;
      _clearWaitingTimer();
      _setState(RelayState.paired);
      _wasPaired = true;
      _startHeartbeat();
      _flushOutboundQueue();
    }
  }

  void _handleRelayError(String? code, String? message) {
    _log('[relay] error frame: $code $message');
    if (code == 'KICKED') {
      _setState(RelayState.kicked);
      _intentionallyClosed = true;
      _failureController.add(RelayFailure('kicked', message));
      _socket?.sink.close();
    }
  }

  void _handleSocketClosed(int code, String? reason) {
    if (_disposed) return;
    _stopHeartbeat();
    _clearWaitingTimer();
    final mapped = relayCloseReason(code);
    _log('[relay] closed code=$code reason=$reason mapped=$mapped');
    sendMobileDiagnostic('socket-close', {
      'closeCode': code,
      if (reason != null) 'closeReason': reason,
      'wasClean': code == 1000,
      'wasPaired': _wasPaired,
    });
    if (_intentionallyClosed) return;
    if (_wasPaired || mapped == 'desktop-disconnected') {
      _scheduleReconnect();
      return;
    }
    _setState(RelayState.error);
    _failureController.add(RelayFailure(
      mapped ?? 'relay-unavailable',
      reason ?? 'connection closed ($code)',
    ));
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) {
      if (state != RelayState.paired && state != RelayState.waiting) return;
      if (DateTime.now().difference(_lastPairStatusAckAt) >
          heartbeatAckTimeout) {
        _log('[relay] heartbeat ack timeout, reconnecting');
        _reconnect();
        return;
      }
      _send({
        'type': 'pair_status_query',
        'device_sid': params.deviceSid,
        'client_ts': DateTime.now().millisecondsSinceEpoch,
      });
    });
  }

  void _stopHeartbeat() => _heartbeatTimer?.cancel();

  void _startWaitingTimer() {
    _clearWaitingTimer();
    _waitingTimer = Timer(waitingTimeout, () {
      if (state == RelayState.waiting && !_wasPaired) {
        _setState(RelayState.error);
        _failureController.add(const RelayFailure(
          'invalid-mobile-connection',
          'Desktop did not match this mobile connection before the waiting timeout.',
        ));
      }
    });
  }

  void _clearWaitingTimer() {
    _waitingTimer?.cancel();
    _rewaitTimer?.cancel();
  }

  void _scheduleReconnect() {
    if (_disposed || _intentionallyClosed) return;
    _setState(RelayState.reconnecting);
    final delayMs =
        (1000 * (1 << _reconnectAttempt.clamp(0, 4))).clamp(1000, 15000);
    _reconnectAttempt += 1;
    _log('[relay] reconnect in ${delayMs}ms (attempt $_reconnectAttempt)');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      if (!_disposed) _connect();
    });
  }

  Future<void> _reconnect() async {
    _reconnectTimer?.cancel();
    sendMobileDiagnostic('recover-start', {'state': state.name});
    // Go through `reconnecting` so listeners (bridge recovery) know the
    // connection dropped — the heartbeat-timeout path used to skip this and
    // bridges were never recovered after re-pairing.
    _setState(RelayState.reconnecting);
    await _connect();
  }

  /// Diagnostics: forcefully drops the socket to exercise the
  /// reconnect/bridge-recovery path (used by integration probes).
  Future<void> debugDropSocket() async {
    _intentionallyClosed = false;
    await _socketSub?.cancel();
    _socketSub = null;
    final socket = _socket;
    _socket = null;
    try {
      await socket?.sink.close(3000, 'debug-drop');
    } catch (_) {}
    _handleSocketClosed(1006, 'debug-drop');
  }

  /// Diagnostics: drives [_applyPairStatus] directly so tests can pin the
  /// heartbeat dedup (repeated acks of the same status) without a live wire.
  @visibleForTesting
  void debugApplyPairStatus(String? status) => _applyPairStatus(status);

  /// Diagnostics: whether the wire gate is open on the current socket.
  @visibleForTesting
  bool get debugDiagGateOpen => _diagAuthOk;

  Future<void> dispose() async {
    _disposed = true;
    _intentionallyClosed = true;
    _stopHeartbeat();
    _clearWaitingTimer();
    _reconnectTimer?.cancel();
    _rewaitTimer?.cancel();
    await _socketSub?.cancel();
    _socket?.sink.close();
    _setState(RelayState.closed);
    await _payloadController.close();
    await _failureController.close();
  }
}
