import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'connection_params.dart';
import 'device_info.dart';
import 'relay_kernel.dart';
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

/// Test alias: the V2 fake sockets implement the shared kernel socket.
typedef RelayV2Socket = RelaySocket;

/// Desktop 3.16.2 relay V2: account-JWT terminal auth over
/// `wss://<host>/api/v1/remote/ws2?token=&mid=`.
///
/// The socket lifecycle, queue, pair state machine, heartbeat and reconnect
/// policy live in [RelayConnectionKernel]; this adapter is the V2 wire (token
/// per (re)connect, auth_init/encoded frames) plus the V2 strategy values.
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

  late final RelayConnectionKernel _kernel;

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
  })  : _http = httpClient ?? http.Client(),
        webSocketFactory = webSocketFactory ?? defaultRelaySocketFactory,
        now = now ?? DateTime.now {
    _kernel = RelayConnectionKernel(
      wire: _RelayV2Wire(params,
          jwtProvider: jwtProvider,
          onLog: onLog,
          http: _http,
          now: this.now,
          socketFactory: this.webSocketFactory),
      liveness: const RelayV2Liveness(),
      timings: RelayTimings(
        heartbeatInterval: heartbeatInterval,
        heartbeatAckTimeout: heartbeatTimeout,
        authAckTimeout: authAckTimeout,
        reconnectWaitTimeout: reconnectWaitTimeout,
        longBackoffAfterFails: 8,
      ),
      errorActions: const RelayV2ErrorActions(),
      pairPolicy: const RelayV2PairPolicy(),
      diagnostics: const RelayDiagnostics(
          logPrefix: '[relay-v2]', logUnhandledPairStatus: true),
      onLog: onLog,
      now: this.now,
      connectFailurePolicy: RelayConnectFailurePolicy.publishFailure,
    );
  }

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
    final outcome = await _kernel.start();
    if (outcome is ConnectOpened) return;
    final reason = switch (outcome) {
      ConnectAuthRequired() => 'auth-required',
      ConnectFailed(:final reason) => reason,
      ConnectOpened() => 'relay-unavailable',
    };
    final message = switch (outcome) {
      ConnectAuthRequired(:final message) => message,
      ConnectFailed(:final message) => message,
      ConnectOpened() => null,
    };
    throw RelayV2StartException(reason, message);
  }

  @override
  void sendPayload(Map<String, dynamic> payload) =>
      _kernel.sendPayload(payload);

  @override
  void sendMobileDiagnostic(String event, [Map<String, dynamic>? fields]) =>
      _kernel.sendMobileDiagnostic(event, fields);

  @override
  Future<void> dispose() => _kernel.dispose();

  /// Reconnect backoff (test seam): the shared pure function with V2's
  /// 8-attempt long-backoff tier.
  @visibleForTesting
  static Duration reconnectDelay(int attempt) =>
      relayReconnectDelay(attempt, longBackoffAfterFails: 8);
}

/// V2 liveness: every decoded frame renews the 15s window; the stamp resets
/// per connect (epoch seed before the first dial).
class RelayV2Liveness implements RelayLiveness {
  const RelayV2Liveness();
  @override
  DateTime initial(DateTime now) => DateTime.fromMillisecondsSinceEpoch(0);
  @override
  bool get resetsOnConnect => true;
  @override
  bool refreshes(InboundFrame frame) => true;
}

/// V2 pairing: heartbeat on every `waiting`; `_wasPaired` resets on start().
class RelayV2PairPolicy implements RelayPairPolicy {
  const RelayV2PairPolicy();
  @override
  bool startHeartbeatOnWaiting(bool wasPaired) => true;
  @override
  bool get resetWasPairedOnStart => true;
}

/// V2 error-frame mapping: AUTH_FAILED terminal auth-required, KICKED
/// terminal kicked, DEVICE_OFFLINE non-fatal waiting, everything else
/// unexpected-error.
class RelayV2ErrorActions implements RelayErrorActions {
  const RelayV2ErrorActions();
  @override
  RelayErrorAction actionFor(String? code, String? message) => switch (code) {
        'AUTH_FAILED' => RelayErrorAction.terminal,
        'KICKED' => RelayErrorAction.kicked,
        'DEVICE_OFFLINE' => RelayErrorAction.nonFatalWaiting,
        _ => RelayErrorAction.defaultTerminal,
      };
}

/// V2 wire: JWT → 60s terminal token on every (re)connect, `auth_init` with
/// seconds `client_ts`, data frames without `client_ts`. Bearer credentials
/// must never reach logs or failure text.
class _RelayV2Wire implements RelayWire {
  final RemoteConnectionParams _params;
  final Future<String?> Function()? _jwtProvider;
  final void Function(String line)? _onLog;
  final http.Client _http;
  final DateTime Function() _now;
  final RelaySocket Function(Uri uri) _socketFactory;
  RelaySocket? _socket;
  String? _token;

  /// Consecutive token-endpoint responses that carried no token and were not
  /// server errors. Three in a row is enough to call the credential dead:
  /// the live server's expired-JWT shape has never been observed (the probe
  /// only ever produced HTTP 401), so a 200 + non-zero business code must not
  /// keep the link in the 15s relay-unavailable retry loop forever.
  int _tokenRejectStreak = 0;
  static const _tokenRejectLimit = 3;
  static final RegExp _tokenParam = RegExp(r'token=[^&\s]+');

  _RelayV2Wire(this._params,
      {required Future<String?> Function()? jwtProvider,
      required void Function(String line)? onLog,
      required http.Client http,
      required DateTime Function() now,
      required RelaySocket Function(Uri uri) socketFactory})
      : _jwtProvider = jwtProvider,
        _onLog = onLog,
        _http = http,
        _now = now,
        _socketFactory = socketFactory;

  static String _redact(Object e) =>
      '$e'.replaceAll(_tokenParam, 'token=redacted');

  void _log(String line) => _onLog?.call(line.replaceAll(_tokenParam, 'token=redacted'));

  @override
  Future<void> prepare() async {
    String? jwt;
    try {
      jwt = _jwtProvider == null ? null : await _jwtProvider();
    } catch (e) {
      // A failing token store read is the same user-facing state as being
      // signed out.
      throw RelayWireException('auth-required', _redact(e));
    }
    if (jwt == null || jwt.trim().isEmpty) {
      throw const RelayWireException('auth-required',
          'Sign in to your ZCode account to use this remote link.');
    }
    try {
      _token = await _fetchToken(jwt.trim());
    } on _TokenFailure catch (e) {
      throw RelayWireException(e.reason, e.message);
    } catch (e) {
      throw RelayWireException('relay-unavailable', _redact(e));
    }
  }

  @override
  Future<RelaySocket> open() async {
    final uri = _wsUri(_token!);
    // The token is a bearer credential — never log the URI verbatim.
    _log('[relay-v2] connecting ${uri.scheme}://${uri.host}${uri.path} '
        '(mid=${_params.deviceMid ?? ''}, token=redacted)');
    try {
      final socket = _socketFactory(uri);
      await socket.ready;
      return socket;
    } catch (e) {
      _log('[relay-v2] connect failed: ${_redact(e)}');
      throw RelayWireException('relay-unavailable', _redact(e));
    }
  }

  @override
  void onConnected(RelaySocket socket) {
    _socket = socket;
    _send({
      'type': 'auth_init',
      'device_sid': _params.deviceSid,
      'meta': {
        'platform': remotePlatformName(),
        'version': _params.appVersion ?? 'web',
        'name': remoteAppName,
      },
      // Live probe used seconds on this wire.
      'client_ts': _now().millisecondsSinceEpoch ~/ 1000,
    });
  }

  @override
  void onInbound(InboundFrame frame) {}

  @override
  String encode(OutboundFrame frame) => switch (frame) {
        RelayDataFrame(:final payload) =>
          jsonEncode({'type': 'data', 'payload': payload}),
        RelayPairStatusQueryFrame() =>
          jsonEncode({'type': 'pair_status_query'}),
      };

  @override
  InboundFrame? decode(String raw) =>
      decodeRelayFrame(raw, strictCasts: false);

  Future<String> _fetchToken(String jwt) async {
    final uri = _params.relayTokenUri;
    _log('[relay-v2] POST $uri');
    final res = await _http
        .post(uri,
            headers: {
              'authorization': 'Bearer $jwt',
              'content-type': 'application/json',
            },
            body: jsonEncode({'role': 'terminal'}))
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
    if (token is String && token.isNotEmpty && (code == null || code == 0)) {
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
    final rejected =
        res.statusCode == 401 || res.statusCode == 403 || code == 401 || code == 403;
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
    final base = _params.relayWsUri;
    return base.replace(
        queryParameters: {...base.queryParameters, 'token': token});
  }

  void _send(Map<String, dynamic> frame) {
    final socket = _socket;
    if (socket == null) return;
    _log('[relay-v2] >> ${jsonEncode(frame)}');
    socket.send(jsonEncode(frame));
  }

  @override
  void dispose() => _http.close();

  @override
  bool get terminalCloseThroughHandler => false;
}
