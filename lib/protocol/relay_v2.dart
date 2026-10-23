import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'connection_params.dart';
import 'device_info.dart';
import 'relay_transport.dart';

/// Emitted by [RelayV2Transport.start] when the link cannot even be opened:
/// no account token, the token endpoint refused it, or the socket is
/// unreachable. The transport has already published a [RelayFailure] by the
/// time this is thrown, so the state layer sees the reason either way.
class RelayV2StartException implements Exception {
  final String reason;
  final String? message;
  const RelayV2StartException(this.reason, [this.message]);

  @override
  String toString() => message == null ? reason : '$reason: $message';
}

class _TokenFailure implements Exception {
  final String reason;
  final String? message;
  const _TokenFailure(this.reason, [this.message]);
}

/// Minimal socket view the V2 transport drives. Production wraps a
/// [WebSocketChannel]; tests provide a fake without the whole
/// `web_socket_channel` interface surface.
abstract interface class RelayV2Socket {
  Future<void> get ready;
  Stream<dynamic> get stream;
  int? get closeCode;
  String? get closeReason;
  void send(String data);
  Future<void> close([int? code, String? reason]);
}

class _ChannelSocket implements RelayV2Socket {
  final WebSocketChannel _channel;
  _ChannelSocket(this._channel);

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

RelayV2Socket _defaultSocketFactory(Uri uri) =>
    _ChannelSocket(WebSocketChannel.connect(uri));

/// Desktop 3.16.2 relay V2: account-JWT terminal auth over
/// `wss://<host>/api/v1/remote/ws2?token=&mid=`.
///
/// Flow (live-probed 2026-10-21, two rounds):
/// 1. `POST /api/v1/remote/token {"role":"terminal"}` with
///    `Authorization: Bearer <zcode account JWT>` → `{token, expires_in:60}`.
///    The token is fetched on EVERY (re)connect — 60s TTL, never persisted.
/// 2. WS open → `auth_init {device_sid, meta, client_ts}` (no proof).
/// 3. `auth_ack {pair_status: waiting|matched, terminal_sid?}`:
///    `waiting` = the desktop is offline but the relay accepted us — stay
///    connected and keep polling; `matched` = paired.
/// 4. Heartbeat `{type:"pair_status_query"}` every ~10s; no inbound frame
///    for 15s means the link is dead → reconnect (V1 backoff).
/// 5. `data` frames carry the exact V1 payload layer — the bootstrap /
///    bridge / rpc-frame stack above is unchanged.
///
/// Error frame codes: `AUTH_FAILED` (terminal, auth-required), `KICKED`
/// (terminal, kicked — no reconnect), `DEVICE_OFFLINE` (non-fatal: keep the
/// connection waiting), `WRONG_PARAM` / `INTERNAL` (terminal, unexpected).
class RelayV2Transport implements RelayTransport {
  final RemoteConnectionParams params;
  final Future<String?> Function()? jwtProvider;
  final void Function(String line)? onLog;

  /// Test seams: HTTP client, websocket factory and clock.
  final http.Client _http;
  final RelayV2Socket Function(Uri uri) webSocketFactory;
  final DateTime Function() now;

  /// Tunable timings (tests shrink them; production keeps the live-probed
  /// defaults). V1's constant names are mirrored on purpose.
  final Duration heartbeatInterval;
  final Duration heartbeatTimeout;
  final Duration authAckTimeout;
  final Duration reconnectWaitTimeout;

  RelayV2Socket? _socket;
  StreamSubscription? _socketSub;

  final _state = ValueNotifier<RelayState>(RelayState.idle);
  @override
  ValueListenable<RelayState> get stateListenable => _state;
  @override
  RelayState get state => _state.value;

  final _payloadController =
      StreamController<Map<String, dynamic>>.broadcast();
  @override
  Stream<Map<String, dynamic>> get payloads => _payloadController.stream;

  final _failureController = StreamController<RelayFailure>.broadcast();
  @override
  Stream<RelayFailure> get failures => _failureController.stream;

  bool _wasPaired = false;
  bool _intentionallyClosed = false;
  bool _disposed = false;
  int _reconnectAttempt = 0;

  /// Consecutive token-endpoint responses that carried no token and were not
  /// server errors. Three in a row is enough to call the credential dead:
  /// the live server's expired-JWT shape has never been observed (the probe
  /// only ever produced HTTP 401), so a 200 + non-zero business code must
  /// not keep the link in the 15s relay-unavailable retry loop forever.
  int _tokenRejectStreak = 0;
  static const _tokenRejectLimit = 3;
  DateTime _lastInboundAt = DateTime.fromMillisecondsSinceEpoch(0);
  String? _lastFailureReason;
  String? _lastFailureMessage;

  /// Per-socket diagnostic gate: the relay hard-fails any data frame sent
  /// before auth (V1 live-verified 2026-10-09; V2 keeps the same gate until
  /// the first auth_ack).
  bool _diagAuthOk = false;

  Timer? _heartbeatTimer;
  Timer? _authAckTimer;
  Timer? _rewaitTimer;
  Timer? _reconnectTimer;

  RelayV2Transport(
    this.params, {
    this.jwtProvider,
    this.onLog,
    http.Client? httpClient,
    RelayV2Socket Function(Uri uri)? webSocketFactory,
    DateTime Function()? now,
    this.heartbeatInterval = const Duration(seconds: 10),
    this.heartbeatTimeout = const Duration(seconds: 15),
    this.authAckTimeout = const Duration(seconds: 15),
    this.reconnectWaitTimeout = const Duration(seconds: 20),
  }) : _http = httpClient ?? http.Client(),
       webSocketFactory = webSocketFactory ?? _defaultSocketFactory,
       now = now ?? DateTime.now;

  /// Bearer credentials must never reach logs or failure text: a failed
  /// WebSocket upgrade echoes the full URI (`...&token=<token>&mid=...`).
  static final RegExp _tokenParam = RegExp(r'token=[^&\s]+');

  static String _redact(Object e) =>
      '$e'.replaceAll(_tokenParam, 'token=redacted');

  void _log(String line) =>
      onLog?.call(line.replaceAll(_tokenParam, 'token=redacted'));

  void _setState(RelayState s) {
    final previous = _state.value;
    _state.value = s;
    _log('[relay-v2] state -> $s');
    if (s == previous) return;
    sendMobileDiagnostic('state-transition', {
      'state': s.name,
      'previousState': previous.name,
    });
  }

  @override
  Future<void> start() async {
    _disposed = false;
    _intentionallyClosed = false;
    _reconnectAttempt = 0;
    _wasPaired = false;
    _setState(RelayState.connecting);
    final ok = await _connect();
    if (!ok) {
      throw RelayV2StartException(
        _lastFailureReason ?? 'relay-unavailable',
        _lastFailureMessage,
      );
    }
  }

  /// Opens one socket. Returns false when the initial step failed (token or
  /// dial); [start] turns that into a thrown [RelayV2StartException] while
  /// the reconnect path backs off instead.
  Future<bool> _connect() async {
    await _socketSub?.cancel();
    _socketSub = null;
    final previous = _socket;
    _socket = null;
    _authAckTimer?.cancel();
    _stopHeartbeat();
    try {
      await previous?.close();
    } catch (_) {
      // best effort
    }
    _diagAuthOk = false;
    _lastFailureReason = null;
    _lastFailureMessage = null;

    final provider = jwtProvider;
    String? jwt;
    try {
      jwt = provider == null ? null : await provider();
    } catch (e) {
      // A failing token store read is the same user-facing state as being
      // signed out.
      _lastFailureReason = 'auth-required';
      _lastFailureMessage = _redact(e);
      _publishStartFailure();
      return false;
    }
    if (jwt == null || jwt.trim().isEmpty) {
      _lastFailureReason = 'auth-required';
      _lastFailureMessage =
          'Sign in to your ZCode account to use this remote link.';
      _publishStartFailure();
      return false;
    }
    if (_disposed) return false;

    // 60s TTL: a fresh token on every dial, never reused.
    String token;
    try {
      token = await _fetchToken(jwt.trim());
    } on _TokenFailure catch (e) {
      _lastFailureReason = e.reason;
      _lastFailureMessage = e.message;
      _publishStartFailure();
      return false;
    } catch (e) {
      _lastFailureReason = 'relay-unavailable';
      _lastFailureMessage = _redact(e);
      _publishStartFailure();
      return false;
    }
    if (_disposed) return false;

    final uri = _wsUri(token);
    // The token is a bearer credential — never log the URI verbatim.
    _log('[relay-v2] connecting ${uri.scheme}://${uri.host}${uri.path} '
        '(mid=${params.deviceMid ?? ''}, token=redacted)');
    RelayV2Socket socket;
    try {
      socket = webSocketFactory(uri);
      await socket.ready;
    } catch (e) {
      _log('[relay-v2] connect failed: ${_redact(e)}');
      _lastFailureReason = 'relay-unavailable';
      _lastFailureMessage = _redact(e);
      _publishStartFailure();
      return false;
    }
    if (_disposed) {
      try {
        await socket.close();
      } catch (_) {}
      return false;
    }
    _socket = socket;
    _lastInboundAt = now();
    _socketSub = socket.stream.listen(
      _handleRawMessage,
      onError: (e) => _log('[relay-v2] socket error: $e'),
      onDone: () => _handleSocketClosed(
        socket.closeCode ?? 1006,
        socket.closeReason,
      ),
    );
    _setState(RelayState.authenticating);
    _send({
      'type': 'auth_init',
      'device_sid': params.deviceSid,
      'meta': {
        'platform': remotePlatformName(),
        'version': params.appVersion ?? 'web',
        'name': remoteAppName,
      },
      // Live probe used seconds on this wire.
      'client_ts': now().millisecondsSinceEpoch ~/ 1000,
    });
    _authAckTimer?.cancel();
    _authAckTimer = Timer(authAckTimeout, () {
      if (state == RelayState.authenticating && !_disposed) {
        _log('[relay-v2] auth_ack timeout');
        _dropSocketAndHandle(1006, 'auth_ack timeout');
      }
    });
    return true;
  }

  Future<String> _fetchToken(String jwt) async {
    final uri = params.relayTokenUri;
    _log('[relay-v2] POST $uri');
    final res = await _http
        .post(
          uri,
          headers: {
            'authorization': 'Bearer $jwt',
            'content-type': 'application/json',
          },
          body: jsonEncode({'role': 'terminal'}),
        )
        .timeout(const Duration(seconds: 15));
    Map<String, dynamic>? body;
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is Map<String, dynamic>) body = decoded;
    } catch (_) {
      // fall through to the status-based error below
    }
    final data = body?['data'];
    final token = data is Map ? data['token'] : body?['token'];
    final code = body?['code'];
    if (token is String &&
        token.isNotEmpty &&
        (code == null || code == 0)) {
      _tokenRejectStreak = 0;
      return token;
    }
    final message = body?['message'] ?? body?['msg'];
    final text = message is String && message.isNotEmpty
        ? message
        : 'token request failed (HTTP ${res.statusCode})';
    // Failure-shape evidence: the expired-JWT form this server actually
    // emits is unobserved, and the next occurrence must be pinned down
    // without the credential ever reaching the log (see [_redact]).
    _log('[relay-v2] token rejected: HTTP ${res.statusCode} code=$code '
        'msg=${_excerpt(text)}');
    final rejected = res.statusCode == 401 ||
        res.statusCode == 403 ||
        code == 401 ||
        code == 403;
    // Timeouts/transport errors never get an HTTP response and therefore
    // never reach this counter (R4: they stay relay-unavailable).
    if (res.statusCode < 500) _tokenRejectStreak += 1;
    if (rejected || _tokenRejectStreak >= _tokenRejectLimit) {
      throw _TokenFailure('auth-required', text);
    }
    throw _TokenFailure('relay-unavailable', text);
  }

  static String _excerpt(String text, [int max = 160]) =>
      text.length <= max ? text : '${text.substring(0, max)}…';

  Uri _wsUri(String token) {
    final base = params.relayWsUri;
    return base.replace(
      queryParameters: {...base.queryParameters, 'token': token},
    );
  }

  void _publishStartFailure() {
    if (_disposed || _failureController.isClosed) return;
    _setState(RelayState.error);
    final reason = _lastFailureReason ?? 'relay-unavailable';
    _failureController.add(RelayFailure(reason, _lastFailureMessage));
  }

  void _send(Map<String, dynamic> frame) {
    final socket = _socket;
    if (socket == null) return;
    _log('[relay-v2] >> ${jsonEncode(frame)}');
    socket.send(jsonEncode(frame));
  }

  /// Outbound payloads are queued while unpaired (reconnecting / waiting for
  /// the desktop) and flushed once the relay reports `matched` — the V1
  /// semantics, unchanged.
  final _outboundQueue = <Map<String, dynamic>>[];

  @override
  void sendPayload(Map<String, dynamic> payload) {
    if (state != RelayState.paired || _socket == null) {
      if (_outboundQueue.length < 100) {
        _log('[relay-v2] queued (state=$state): ${payload['zcode_type']}');
        _outboundQueue.add(payload);
      }
      return;
    }
    _send({'type': 'data', 'payload': payload});
  }

  void _flushOutboundQueue() {
    if (_outboundQueue.isEmpty) return;
    _log('[relay-v2] flushing ${_outboundQueue.length} queued payload(s)');
    final queued = List<Map<String, dynamic>>.from(_outboundQueue);
    _outboundQueue.clear();
    for (final payload in queued) {
      _send({'type': 'data', 'payload': payload});
    }
  }

  @override
  void sendMobileDiagnostic(String event, [Map<String, dynamic>? fields]) {
    try {
      final payload = <String, dynamic>{
        'zcode_type': 'mobile-diagnostic',
        'event': event,
        'timestamp': now().millisecondsSinceEpoch,
        ...?fields,
      };
      if (_disposed || _socket == null || !_diagAuthOk) return;
      _send({'type': 'data', 'payload': payload});
    } catch (_) {
      // Best-effort: encoding/send failures never surface.
    }
  }

  void _handleRawMessage(dynamic data) {
    Map<String, dynamic>? frame;
    try {
      final text = data is String ? data : utf8.decode(data as List<int>);
      _log('[relay-v2] << $text');
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic> && decoded.containsKey('type')) {
        frame = decoded;
      }
    } catch (e) {
      _log('[relay-v2] bad frame: $e');
      return;
    }
    if (frame == null) return;
    // Any inbound frame renews the 15s liveness window.
    _lastInboundAt = now();
    switch (frame['type']) {
      case 'auth_ack':
      case 'pair_status_ack':
        final status =
            frame['pair_status'] is String ? frame['pair_status'] as String : null;
        // Only a recognised pair status settles auth: an ack WITHOUT one
        // would otherwise park the link at `authenticating` with no
        // fallback. Keep the 15s timer so its timeout still recovers.
        if (status == 'waiting' || status == 'matched') {
          _authAckTimer?.cancel();
        }
        _applyPairStatus(status);
        break;
      case 'data':
        final payload = frame['payload'];
        if (payload is Map<String, dynamic>) {
          _payloadController.add(payload);
        }
        break;
      case 'error':
        _handleRelayError(
          frame['code'] is String ? frame['code'] as String : null,
          frame['message'] is String ? frame['message'] as String : null,
        );
        break;
    }
  }

  void _applyPairStatus(String? status) {
    _diagAuthOk = true;
    if (status == 'waiting') {
      // Desktop offline: the relay accepted our auth and holds the socket.
      // Stay connected and let the heartbeat poll until `matched`.
      _setState(RelayState.waiting);
      _startHeartbeat();
      if (_wasPaired) {
        // A previously paired mobile should be matched immediately; if the
        // server keeps saying waiting, force a reconnect instead of hanging
        // forever (V1 `_rewaitTimer` semantics).
        _rewaitTimer?.cancel();
        _rewaitTimer = Timer(reconnectWaitTimeout, () {
          if (_wasPaired && state == RelayState.waiting && !_disposed) {
            _log('[relay-v2] re-pair stuck in waiting, reconnecting');
            unawaited(_reconnect());
          }
        });
      }
      return;
    }
    if (status == 'matched') {
      _rewaitTimer?.cancel();
      _reconnectAttempt = 0;
      _setState(RelayState.paired);
      _wasPaired = true;
      _startHeartbeat();
      _flushOutboundQueue();
      return;
    }
    _log('[relay-v2] unhandled pair_status=$status');
  }

  void _handleRelayError(String? code, String? message) {
    _log('[relay-v2] error frame: $code $message');
    switch (code) {
      case 'AUTH_FAILED':
        _failTerminal(RelayState.error, 'auth-required', message);
        break;
      case 'KICKED':
        _failTerminal(RelayState.kicked, 'kicked', message);
        break;
      case 'DEVICE_OFFLINE':
        // Not fatal: the desktop went offline while the relay keeps our
        // terminal slot. Applies in EVERY stage — 3.16.2 can send it before
        // auth_ack; leaving the auth timer armed would turn that into a
        // 15s timeout error. Go waiting and let the heartbeat poll until
        // the relay reports `matched` again.
        _log('[relay-v2] desktop offline; waiting for it to come back');
        _authAckTimer?.cancel();
        _setState(RelayState.waiting);
        _startHeartbeat();
        break;
      default:
        _failTerminal(
          RelayState.error,
          'unexpected-error',
          message ?? 'relay error $code',
        );
    }
  }

  void _failTerminal(RelayState terminalState, String reason, String? message) {
    if (_disposed) return;
    _setState(terminalState);
    _intentionallyClosed = true;
    if (!_failureController.isClosed) {
      _failureController.add(RelayFailure(reason, message));
    }
    _dropSocketAndHandle(
      terminalState == RelayState.kicked ? 4009 : 1006,
      reason,
      handleClose: false,
    );
  }

  /// Cancels the stream subscription, closes the socket and (unless
  /// [handleClose] is false) routes the synthetic close through the normal
  /// reconnect/error policy.
  void _dropSocketAndHandle(
    int code,
    String? reason, {
    bool handleClose = true,
  }) {
    _stopHeartbeat();
    _authAckTimer?.cancel();
    _socketSub?.cancel();
    _socketSub = null;
    final socket = _socket;
    _socket = null;
    try {
      socket?.close();
    } catch (_) {}
    if (handleClose) _handleSocketClosed(code, reason);
  }

  void _handleSocketClosed(int code, String? reason) {
    if (_disposed) return;
    _stopHeartbeat();
    _authAckTimer?.cancel();
    final mapped = relayCloseReason(code);
    _log('[relay-v2] closed code=$code reason=$reason mapped=$mapped');
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
      if (now().difference(_lastInboundAt) > heartbeatTimeout) {
        _log('[relay-v2] heartbeat ack timeout, reconnecting');
        unawaited(_reconnect());
        return;
      }
      _send({'type': 'pair_status_query'});
    });
  }

  void _stopHeartbeat() => _heartbeatTimer?.cancel();

  /// Reconnect backoff: 1s doubling to the 15s cap, and once a link keeps
  /// failing (8 attempts in a row) each retry drops to a fixed 60s. The
  /// link still self-heals when the network returns — it just stops the
  /// 15s-endless-retry noise/ battery drain observed over an hour.
  @visibleForTesting
  static Duration reconnectDelay(int attempt) {
    if (attempt >= 8) return const Duration(milliseconds: 60000);
    return Duration(
      milliseconds: (1000 * (1 << attempt.clamp(0, 4))).clamp(1000, 15000),
    );
  }

  void _scheduleReconnect() {
    if (_disposed || _intentionallyClosed) return;
    _setState(RelayState.reconnecting);
    final delay = reconnectDelay(_reconnectAttempt);
    _reconnectAttempt += 1;
    _log('[relay-v2] reconnect in ${delay.inMilliseconds}ms '
        '(attempt $_reconnectAttempt)');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      if (!_disposed) unawaited(_reconnect());
    });
  }

  Future<void> _reconnect() async {
    _reconnectTimer?.cancel();
    _setState(RelayState.reconnecting);
    bool ok;
    try {
      ok = await _connect();
    } catch (e) {
      _log('[relay-v2] reconnect failed: $e');
      ok = false;
    }
    if (ok || _disposed) return;
    // auth-required needs the user; everything else backs off and retries.
    if (_lastFailureReason == 'auth-required') return;
    if (!_intentionallyClosed) _scheduleReconnect();
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _intentionallyClosed = true;
    _stopHeartbeat();
    _authAckTimer?.cancel();
    _rewaitTimer?.cancel();
    _reconnectTimer?.cancel();
    await _socketSub?.cancel();
    _socketSub = null;
    final socket = _socket;
    _socket = null;
    try {
      await socket?.close();
    } catch (_) {}
    _setState(RelayState.closed);
    _http.close();
    await _payloadController.close();
    await _failureController.close();
  }
}
