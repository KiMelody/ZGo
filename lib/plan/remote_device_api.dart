import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'plan_api.dart';
import 'plan_models.dart';

/// One entry of the account's cloud device directory
/// (`GET /api/v1/remote/device` → `data[]`).
///
/// Live probe (2026-10-22) returned
/// `{device_sid, device_mid, online, created_at, meta:{name, platform,
/// version}}`. The sid/mid pair is the same pair the V2 share link carries,
/// so an entry is enough to build a connection without asking the desktop
/// to share a link by hand.
class RemoteDeviceEntry {
  final String deviceSid;
  final String deviceMid;

  /// Whether the desktop currently holds a relay connection. Unknown shape
  /// degrades to false (no connect offer) instead of guessing.
  final bool online;
  final DateTime? createdAt;
  final String name;
  final String platform;
  final String version;

  const RemoteDeviceEntry({
    required this.deviceSid,
    required this.deviceMid,
    required this.online,
    this.createdAt,
    this.name = '',
    this.platform = '',
    this.version = '',
  });

  /// The V2 share-link URL for this entry — the same shape the desktop's
  /// share action produces (`sid/mid/name/app_version`), so adding it goes
  /// through the existing [DeviceStore.addUrl] + open path unchanged.
  Uri get remoteUrl => Uri.parse(kPlanBaseUrl).replace(
        path: '/remote/v4',
        queryParameters: {
          'sid': deviceSid,
          'mid': deviceMid,
          if (name.isNotEmpty) 'name': name,
          if (version.isNotEmpty) 'app_version': version,
        },
      );
}

/// Pure parser for the directory's `data` payload.
///
/// A payload that is not a list is a hard shape failure (throws — the page
/// folds the section away silently). Individual malformed rows are skipped:
/// without a sid/mid there is no link to build, so hiding the row beats
/// guessing (the lenient-reader discipline of plan_models).
List<RemoteDeviceEntry> parseRemoteDevices(dynamic data) {
  if (data is! List) {
    throw const PlanApiError(null, 'malformed device list');
  }
  final out = <RemoteDeviceEntry>[];
  for (final row in data) {
    if (row is! Map) continue;
    final sid = _asString(row['device_sid']);
    final mid = _asString(row['device_mid']);
    if (sid.isEmpty || mid.isEmpty) continue;
    final meta = row['meta'];
    out.add(RemoteDeviceEntry(
      deviceSid: sid,
      deviceMid: mid,
      online: row['online'] == true,
      createdAt: _asDate(row['created_at']),
      name: meta is Map ? _asString(meta['name']) : '',
      platform: meta is Map ? _asString(meta['platform']) : '',
      version: meta is Map ? _asString(meta['version']) : '',
    ));
  }
  return out;
}

/// Read-only client for the account's cloud device directory. Shares the
/// billing plane's host and failure taxonomy (the same zcode JWT); the
/// error shapes mirror [PlanApi] so callers classify failures identically.
class RemoteDeviceApi {
  final http.Client _client;
  final Uri _base;

  static const _timeout = Duration(seconds: 15);

  RemoteDeviceApi({http.Client? client, Uri? baseUrl})
      : _client = client ?? http.Client(),
        _base = baseUrl ?? Uri.parse(kPlanBaseUrl);

  /// `GET /api/v1/remote/device` — devices registered to the account.
  /// Requires `Authorization: Bearer <zcode JWT>` and nothing else.
  Future<List<RemoteDeviceEntry>> list({required String token}) async {
    final data = await _get(
      _base.replace(path: '/api/v1/remote/device'),
      token: token,
    );
    return parseRemoteDevices(data);
  }

  Future<dynamic> _get(Uri uri, {required String token}) async {
    http.Response res;
    try {
      res = await _client
          .get(uri, headers: {'authorization': 'Bearer $token'})
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

String _asString(dynamic v) => v is String ? v : '';

/// Epoch reader accepting seconds and milliseconds (the wire mixes both
/// across fields; magnitudes are unambiguous above 1e11); ISO strings pass
/// through `DateTime.tryParse`.
DateTime? _asDate(dynamic v) {
  if (v is num) {
    final n = v.toInt();
    if (n <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      n > 100000000000 ? n : n * 1000,
    );
  }
  if (v is String) return DateTime.tryParse(v);
  return null;
}
