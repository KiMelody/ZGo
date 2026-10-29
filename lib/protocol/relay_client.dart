// The kernel's test seams are intentionally re-exposed through the V1
// adapter's existing debug* forwarding contract.
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'connection_params.dart';
import 'device_info.dart';
import 'proof.dart';
import 'relay_kernel.dart';
import 'relay_transport.dart';

export 'relay_transport.dart' show RelayState, RelayFailure, relayCloseReason;

/// Reimplementation of the relay terminal socket (`pen` class in the web
/// client). JSON text frames over `wss://<host>/ws`.
///
/// V1 only: the proof handshake (`auth_challenge` → `auth_response`) needs
/// the link's `hash`/`t`. V2 links route to `RelayV2Transport` instead. All
/// connection policy lives in [RelayConnectionKernel]; this adapter is the
/// V1 wire (auth frames, proof, codec) plus its strategy values.
class RelayClient implements RelayTransport {
  final RemoteConnectionParams params;
  final void Function(String line)? onLog;

  static const heartbeatInterval = Duration(seconds: 10);
  static const heartbeatAckTimeout = Duration(seconds: 30);
  static const waitingTimeout = Duration(seconds: 30);
  static const reconnectWaitTimeout = Duration(seconds: 20);

  final RelayConnectionKernel _kernel;

  RelayClient(this.params,
      {this.onLog, RelaySocket Function(Uri uri)? webSocketFactory})
      : _kernel = RelayConnectionKernel(
          wire: _RelayV1Wire(params,
              onLog: onLog,
              socketFactory: webSocketFactory ?? defaultRelaySocketFactory),
          liveness: const RelayV1Liveness(),
          timings: const RelayTimings(
            heartbeatInterval: heartbeatInterval,
            heartbeatAckTimeout: heartbeatAckTimeout,
            waitingTimeout: waitingTimeout,
            reconnectWaitTimeout: reconnectWaitTimeout,
          ),
          errorActions: const RelayV1ErrorActions(),
          pairPolicy: const RelayV1PairPolicy(),
          diagnostics:
              const RelayDiagnostics(logPrefix: '[relay]', legacyEvents: true),
          onLog: onLog,
          now: DateTime.now,
        );

  @override
  ValueListenable<RelayState> get stateListenable => _kernel.stateListenable;
  @override
  RelayState get state => _kernel.state;
  @override
  Stream<Map<String, dynamic>> get payloads => _kernel.payloads;
  @override
  Stream<RelayFailure> get failures => _kernel.failures;

  @override
  Future<void> start() async {
    await _kernel.start();
  }

  @override
  void sendPayload(Map<String, dynamic> payload) =>
      _kernel.sendPayload(payload);

  @override
  void sendMobileDiagnostic(String event, [Map<String, dynamic>? fields]) =>
      _kernel.sendMobileDiagnostic(event, fields);

  @override
  Future<void> dispose() => _kernel.dispose();

  /// Test seam (D3): when set, mobile-diagnostic payloads are delivered here
  /// instead of the socket. Production leaves it null.
  @visibleForTesting
  void Function(Map<String, dynamic> payload)? get debugDiagnosticSink =>
      _kernel.diagnosticSink;

  @visibleForTesting
  set debugDiagnosticSink(void Function(Map<String, dynamic> payload)? sink) =>
      _kernel.diagnosticSink = sink;

  /// Diagnostics: drives the pair state machine directly so tests can pin the
  /// heartbeat dedup without a live wire.
  @visibleForTesting
  void debugApplyPairStatus(String? status) => _kernel.debugApplyPairStatus(status);

  /// Diagnostics: whether the wire gate is open on the current socket.
  @visibleForTesting
  bool get debugDiagGateOpen => _kernel.debugDiagGateOpen;

  /// Diagnostics: replays a relay `error` frame through the real handler.
  @visibleForTesting
  void debugHandleRelayError(String? code, String? message) =>
      _kernel.debugHandleRelayError(code, message);

  /// Diagnostics: forcefully drops the socket to exercise the reconnect /
  /// bridge-recovery path (used by integration probes).
  Future<void> debugDropSocket() => _kernel.debugDropSocket();
}

/// V1 liveness — PERMANENT DIVERGENCE, never widen to "any frame": only a
/// relay pair status proves the pair channel alive.
class RelayV1Liveness implements RelayLiveness {
  const RelayV1Liveness();
  @override
  DateTime initial(DateTime now) => now;
  @override
  bool get resetsOnConnect => false;
  @override
  bool refreshes(InboundFrame frame) => frame.kind == InboundKind.pairStatus;
}

/// V1 pairing: heartbeat on `waiting` only after a prior match; `_wasPaired`
/// survives `start()`.
class RelayV1PairPolicy implements RelayPairPolicy {
  const RelayV1PairPolicy();
  @override
  bool startHeartbeatOnWaiting(bool wasPaired) => wasPaired;
  @override
  bool get resetWasPairedOnStart => false;
}

/// V1 error frames: KICKED is the only recognised code.
class RelayV1ErrorActions implements RelayErrorActions {
  const RelayV1ErrorActions();
  @override
  RelayErrorAction actionFor(String? code, String? message) =>
      code == 'KICKED' ? RelayErrorAction.kicked : RelayErrorAction.ignore;
}

/// V1 wire: `auth_init` → `auth_challenge` → `auth_response`, `client_ts` in
/// milliseconds on every outbound frame.
class _RelayV1Wire implements RelayWire {
  final RemoteConnectionParams _params;
  final void Function(String line)? _onLog;
  final RelaySocket Function(Uri uri) _socketFactory;
  RelaySocket? _socket;

  _RelayV1Wire(this._params,
      {void Function(String line)? onLog,
      required RelaySocket Function(Uri uri) socketFactory})
      : _onLog = onLog,
        _socketFactory = socketFactory;

  void _log(String line) => _onLog?.call(line);

  @override
  Future<void> prepare() async {}

  @override
  Future<RelaySocket> open() async {
    final uri = _params.relayWsUri;
    _log('[relay] connecting $uri');
    try {
      final socket = _socketFactory(uri);
      await socket.ready;
      return socket;
    } catch (e) {
      _log('[relay] connect failed: $e');
      throw RelayWireException('relay-unavailable', '$e');
    }
  }

  @override
  void onConnected(RelaySocket socket) {
    _socket = socket;
    _send({
      'type': 'auth_init',
      'role': 'terminal',
      'device_sid': _params.deviceSid,
      'meta': {
        'platform': remotePlatformName(),
        'version': _params.appVersion ?? 'web',
        'name': remoteAppName,
      },
      'client_ts': DateTime.now().millisecondsSinceEpoch,
    });
  }

  @override
  void onInbound(InboundFrame frame) {
    if (frame.kind != InboundKind.authChallenge) return;
    _send({
      'type': 'auth_response',
      'device_sid': _params.deviceSid,
      'proof': calculateProof(
        passHash: _params.passHash ?? '',
        nonce: frame.raw['nonce'] as String? ?? '',
        role: 'terminal',
        deviceSid: _params.deviceSid,
      ),
      'client_ts': DateTime.now().millisecondsSinceEpoch,
    });
  }

  @override
  String encode(OutboundFrame frame) => switch (frame) {
        RelayDataFrame(:final payload) => jsonEncode({
            'type': 'data',
            'payload': payload,
            'client_ts': DateTime.now().millisecondsSinceEpoch,
          }),
        RelayPairStatusQueryFrame() => jsonEncode({
            'type': 'pair_status_query',
            'device_sid': _params.deviceSid,
            'client_ts': DateTime.now().millisecondsSinceEpoch,
          }),
      };

  @override
  InboundFrame? decode(String raw) =>
      decodeRelayFrame(raw, strictCasts: true);

  void _send(Map<String, dynamic> frame) {
    final socket = _socket;
    if (socket == null) return;
    final line = jsonEncode(frame);
    _log('[relay] >> $line');
    socket.send(line);
  }

  @override
  void dispose() {}

  @override
  bool get terminalCloseThroughHandler => true;
}
