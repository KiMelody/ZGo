/// OAuth device flow for the z.ai plan account (the v1 sign-in path).
///
/// Pure Dart state machine — injectable http client, clock and delay, no
/// UI. The caller opens the authorize URL in a browser and renders
/// progress; the machine itself drives init + the poll loop to one
/// terminal outcome per instance.
///
/// Wire contract is probe-certified (2026-10-11 live login, task
/// `10-11-plan-quota-query/research/oauth-cli-flow-probe.md`):
/// - `POST /api/v1/oauth/cli/init` with `Authorization: Bearer` set to 32
///   random bytes as hex, body `{"provider":"zai"}` → `data` is snake_case:
///   `{flow_id, poll_token, authorize_url, expires_at, poll_interval_sec}`
///   (probe: interval = 2s; `authorize_url` is server-built — the client
///   assembles zero OAuth parameters).
/// - `GET /api/v1/oauth/cli/poll/<flow_id>` with `Authorization: Bearer`
///   set to the poll token: pending = `{data:{status:"pending"}}` (32 frames
///   observed); terminal = `{data:{status:"ready", token, user:{user_id,
///   email, name, avatar}, zai:{access_token}}}` — the token set is
///   inlined, there is no separate code-exchange step. Only `data.token`
///   (the zcode JWT for the billing plane) is surfaced; `zai.access_token`
///   is deliberately not captured.
/// - Retryable poll hiccups: 408 / 429 / 5xx / transport errors → keep
///   polling. Any other 4xx / non-zero envelope → the flow is rejected.
///   Still pending at `expires_at` → timed out.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'plan_api.dart';
import 'plan_models.dart';

/// Account identity from the terminal frame's `data.user`. Empty string =
/// absent or wrong-typed on the wire (lenient, never throws).
class PlanOAuthUser {
  final String userId;
  final String email;
  final String name;
  final String avatar;

  const PlanOAuthUser({
    required this.userId,
    required this.email,
    required this.name,
    required this.avatar,
  });
}

/// Why a device flow ended without a token.
enum PlanOAuthFailureReason {
  /// The user (or the host screen) requested cancellation.
  userCancelled,

  /// Still pending when `expires_at` passed.
  timeout,

  /// The server rejected the flow: any poll 4xx other than 408/429,
  /// a non-zero envelope, or an unexpected terminal shape.
  flowRejected,

  /// Transport failure on the init call (poll transport errors keep
  /// polling instead of failing).
  network,
}

/// Terminal state of one device flow.
sealed class PlanOAuthOutcome {
  const PlanOAuthOutcome();
}

/// `data.status:"ready"` — [token] is the zcode JWT consumed by the
/// billing plane (written into the token store; see PlanTokenStore).
class PlanOAuthSuccess extends PlanOAuthOutcome {
  final String token;
  final PlanOAuthUser user;

  const PlanOAuthSuccess({required this.token, required this.user});
}

class PlanOAuthFailed extends PlanOAuthOutcome {
  final PlanOAuthFailureReason reason;

  const PlanOAuthFailed(this.reason);

  @override
  String toString() => 'PlanOAuthFailed(${reason.name})';
}

/// Injectable poll-interval wait (tests pass an immediate no-op).
typedef PlanOAuthDelay = Future<void> Function(Duration interval);

/// Internal control-flow failure; never escapes [PlanOAuth.start] (it is
/// converted to a [PlanOAuthFailed] outcome) and carries no wire text, so
/// no credential can leak through it.
class _FlowFailure implements Exception {
  final PlanOAuthFailureReason reason;
  const _FlowFailure(this.reason);
}

/// One init session as returned by `cli/init`.
class _FlowSession {
  final String flowId;
  final String pollToken;
  final String authorizeUrl;
  final DateTime? expiresAt;
  final Duration interval;

  const _FlowSession({
    required this.flowId,
    required this.pollToken,
    required this.authorizeUrl,
    required this.expiresAt,
    required this.interval,
  });
}

/// Single-use OAuth device flow machine.
///
/// Create a fresh instance per sign-in attempt; exceptions from [start]
/// are reserved for misuse (double start) — every wire-level ending is a
/// [PlanOAuthOutcome]. No method ever logs or embeds tokens.
class PlanOAuth {
  final http.Client _client;
  final bool _ownsClient;
  final Uri _base;
  final PlanOAuthDelay _delay;
  final DateTime Function() _now;
  final Random _random;

  static const _pathInit = '/api/v1/oauth/cli/init';
  static const _pathPoll = '/api/v1/oauth/cli/poll';
  static const _requestTimeout = Duration(seconds: 15);

  /// Probe-certified `poll_interval_sec` (also the fallback when the
  /// field is absent or nonsense).
  static const _defaultInterval = Duration(seconds: 2);

  PlanOAuth({
    http.Client? client,
    Uri? baseUrl,
    PlanOAuthDelay? delay,
    DateTime Function()? now,
    Random? random,
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null,
        _base = baseUrl ?? Uri.parse(kPlanBaseUrl),
        _delay = delay ?? _wallDelay,
        _now = now ?? DateTime.now,
        _random = random ?? Random.secure();

  bool _started = false;
  bool _cancelled = false;
  final Completer<void> _cancelSignal = Completer<void>();

  /// Runs the flow: `cli/init`, hands the server-built URL to
  /// [onAuthorizeUrl] (exactly once, before polling), then polls to the
  /// terminal outcome. Cancellation goes through [cancel].
  Future<PlanOAuthOutcome> start({
    required void Function(String authorizeUrl) onAuthorizeUrl,
  }) async {
    if (_started) {
      throw StateError('PlanOAuth is single-use; create a new instance');
    }
    _started = true;
    try {
      final session = await _init();
      onAuthorizeUrl(session.authorizeUrl);
      return await _poll(session);
    } on _FlowFailure catch (failure) {
      return PlanOAuthFailed(failure.reason);
    } finally {
      if (_ownsClient) _client.close();
    }
  }

  /// Requests cancellation; the loop exits with
  /// [PlanOAuthFailureReason.userCancelled] at the next checkpoint,
  /// including mid-wait. No-op after the flow has ended.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    if (!_cancelSignal.isCompleted) _cancelSignal.complete();
  }

  Future<_FlowSession> _init() async {
    if (_cancelled) {
      throw const _FlowFailure(PlanOAuthFailureReason.userCancelled);
    }
    http.Response res;
    try {
      res = await _client
          .post(
            _base.replace(path: _pathInit),
            headers: {
              'content-type': 'application/json',
              'authorization': 'Bearer ${_randomHex(32)}',
            },
            body: jsonEncode({'provider': 'zai'}),
          )
          .timeout(_requestTimeout);
    } on TimeoutException {
      throw const _FlowFailure(PlanOAuthFailureReason.network);
    } on SocketException {
      throw const _FlowFailure(PlanOAuthFailureReason.network);
    } on http.ClientException {
      throw const _FlowFailure(PlanOAuthFailureReason.network);
    }
    if (res.statusCode != 200) {
      throw const _FlowFailure(PlanOAuthFailureReason.flowRejected);
    }
    final body = _tryDecode(res.body);
    if (body == null || envelopeCode(body) != 0) {
      throw const _FlowFailure(PlanOAuthFailureReason.flowRejected);
    }
    final data = envelopeData(body);
    if (data is! Map) {
      throw const _FlowFailure(PlanOAuthFailureReason.flowRejected);
    }
    final flowId = data['flow_id'];
    final pollToken = data['poll_token'];
    final authorizeUrl = data['authorize_url'];
    if (flowId is! String ||
        flowId.isEmpty ||
        pollToken is! String ||
        pollToken.isEmpty ||
        authorizeUrl is! String ||
        authorizeUrl.isEmpty) {
      throw const _FlowFailure(PlanOAuthFailureReason.flowRejected);
    }
    return _FlowSession(
      flowId: flowId,
      pollToken: pollToken,
      authorizeUrl: authorizeUrl,
      expiresAt: _asEpoch(data['expires_at']),
      interval: _readInterval(data['poll_interval_sec']),
    );
  }

  Future<PlanOAuthOutcome> _poll(_FlowSession session) async {
    while (true) {
      if (_cancelled) {
        throw const _FlowFailure(PlanOAuthFailureReason.userCancelled);
      }
      final expiresAt = session.expiresAt;
      if (expiresAt != null && !_now().isBefore(expiresAt)) {
        throw const _FlowFailure(PlanOAuthFailureReason.timeout);
      }
      http.Response res;
      try {
        res = await _client
            .get(
              _base.replace(path: '$_pathPoll/${session.flowId}'),
              headers: {'authorization': 'Bearer ${session.pollToken}'},
            )
            .timeout(_requestTimeout);
      } on TimeoutException {
        await _sleep(session.interval);
        continue;
      } on SocketException {
        await _sleep(session.interval);
        continue;
      } on http.ClientException {
        await _sleep(session.interval);
        continue;
      }
      // Probe/desktop semantics: 408/429/5xx and transport errors are
      // retryable hiccups; any other 4xx rejects the flow.
      if (res.statusCode == 408 ||
          res.statusCode == 429 ||
          res.statusCode >= 500) {
        await _sleep(session.interval);
        continue;
      }
      if (res.statusCode >= 400) {
        throw const _FlowFailure(PlanOAuthFailureReason.flowRejected);
      }
      final body = _tryDecode(res.body);
      if (body == null || envelopeCode(body) != 0) {
        throw const _FlowFailure(PlanOAuthFailureReason.flowRejected);
      }
      final data = envelopeData(body);
      if (data is! Map) {
        throw const _FlowFailure(PlanOAuthFailureReason.flowRejected);
      }
      final status = data['status'];
      if (status == 'pending') {
        await _sleep(session.interval);
        continue;
      }
      if (status != 'ready') {
        throw const _FlowFailure(PlanOAuthFailureReason.flowRejected);
      }
      final token = data['token'];
      if (token is! String || token.isEmpty) {
        throw const _FlowFailure(PlanOAuthFailureReason.flowRejected);
      }
      return PlanOAuthSuccess(token: token, user: _parseUser(data['user']));
    }
  }

  /// One interval wait; the cancel signal cuts it short and the next
  /// loop-head check exits with userCancelled.
  Future<void> _sleep(Duration interval) async {
    if (_cancelled) return;
    await Future.any<void>([_delay(interval), _cancelSignal.future]);
  }

  static PlanOAuthUser _parseUser(dynamic value) {
    final map = value is Map ? value : const <dynamic, dynamic>{};
    String str(dynamic v) => v is String ? v : '';
    return PlanOAuthUser(
      userId: str(map['user_id']),
      email: str(map['email']),
      name: str(map['name']),
      avatar: str(map['avatar']),
    );
  }

  static Duration _readInterval(dynamic value) {
    final sec = value is int ? value : null;
    if (sec == null || sec < 1) return _defaultInterval;
    return Duration(seconds: sec);
  }

  /// `expires_at` epoch reader (seconds; magnitudes above 1e11 are
  /// milliseconds — this API family mixes both). Null when absent/broken,
  /// which simply disables the timeout guard.
  static DateTime? _asEpoch(dynamic value) {
    final n = value is int ? value : (value is num ? value.toInt() : null);
    if (n == null || n <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(n > 100000000000 ? n : n * 1000);
  }

  static Map? _tryDecode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  /// The init bearer credential: 32 random bytes from a secure source,
  /// hex-encoded (probe-certified shape).
  String _randomHex(int byteCount) {
    final bytes = List<int>.generate(byteCount, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static Future<void> _wallDelay(Duration interval) =>
      Future<void>.delayed(interval);
}
