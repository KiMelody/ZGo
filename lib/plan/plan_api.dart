import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'plan_models.dart';

/// z.ai billing-plane base URL (same host as the desktop client probes).
const String kPlanBaseUrl = 'https://zcode.z.ai';

/// `app_version` query value the desktop client (3.15.1) sends. The server
/// tolerates drift, so this is frozen instead of following app releases.
const String kPlanAppVersion = '3.15.1';

/// Failure taxonomy of the billing plane.
///
/// Messages carry server text / transport causes only — never the token
/// (red line: no exception path may leak credentials).
sealed class PlanApiException implements Exception {
  final String message;
  const PlanApiException(this.message);

  @override
  String toString() => '$runtimeType: $message';
}

/// 401/403 — the zcode JWT was revoked (token_version bump) or is invalid.
/// The desktop classifies both statuses as auth failure (`rv`), so the
/// client mirrors that. The controller turns this into "login expired,
/// re-authenticate".
class PlanAuthExpired extends PlanApiException {
  const PlanAuthExpired() : super('authorization expired');
}

/// Non-zero envelope code / unusable response (bad JSON, unexpected HTTP
/// status). [code] is the server envelope code, `null` when absent.
class PlanApiError extends PlanApiException {
  final int? code;
  const PlanApiError(this.code, String message) : super(message);
}

/// Transport-level failure (offline, timeout, connection reset).
class PlanNetworkError extends PlanApiException {
  final Object cause;
  const PlanNetworkError(this.cause) : super('network error');

  @override
  String toString() => '$runtimeType: $cause';
}

/// Thin REST client for the two billing endpoints the plan page consumes.
/// Endpoint shapes and constants live here only (private protocol drift
/// containment, mirroring the method-probe discipline of the relay plane).
class PlanApi {
  final http.Client _client;
  final Uri _base;

  static const _timeout = Duration(seconds: 15);

  PlanApi({http.Client? client, Uri? baseUrl})
      : _client = client ?? http.Client(),
        _base = baseUrl ?? Uri.parse(kPlanBaseUrl);

  /// `GET /api/v1/zcode-plan/billing/balance` — plans + balance buckets.
  /// Requires the [deviceMid] header (any UUID; missing → 400 code 3001).
  Future<PlanSnapshot> fetchBalance({
    required String token,
    required String deviceMid,
  }) async {
    final data = await _get(
      _base.replace(
        path: '/api/v1/zcode-plan/billing/balance',
        queryParameters: const {'app_version': kPlanAppVersion},
      ),
      token: token,
      deviceMid: deviceMid,
    );
    return parseBalanceSnapshot(data);
  }

  /// `GET /api/v1/zcode-plan/billing/current` — plan + entitlement
  /// definitions only; the server does not want X-Device-Mid here.
  Future<List<PlanDefinition>> fetchCurrent({required String token}) async {
    final data = await _get(
      _base.replace(
        path: '/api/v1/zcode-plan/billing/current',
        queryParameters: const {'app_version': kPlanAppVersion},
      ),
      token: token,
    );
    return parsePlanDefinitions(data);
  }

  Future<dynamic> _get(
    Uri uri, {
    required String token,
    String? deviceMid,
  }) async {
    http.Response res;
    try {
      res = await _client
          .get(uri, headers: {
            'authorization': 'Bearer $token',
            if (deviceMid != null) 'x-device-mid': deviceMid,
          })
          .timeout(_timeout);
    } on TimeoutException catch (e) {
      throw PlanNetworkError(e);
    } on SocketException catch (e) {
      throw PlanNetworkError(e);
    } on http.ClientException catch (e) {
      throw PlanNetworkError(e);
    }
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw const PlanAuthExpired();
    }

    Map? body;
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is Map) body = decoded;
    } on FormatException {
      // fall through: malformed body handled below
    }

    final code = envelopeCode(body);
    if (code == null) {
      throw PlanApiError(null, 'HTTP ${res.statusCode}: malformed envelope');
    }
    if (code != 0) throw PlanApiError(code, _msg(body));
    return envelopeData(body);
  }

  String _msg(Map? body) => body is Map && body['msg'] is String
      ? body['msg'] as String
      : 'unknown api error';
}
