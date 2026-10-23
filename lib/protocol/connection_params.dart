import 'package:flutter/foundation.dart';

/// Parses a ZCode web-remote connection URL.
///
/// Two link generations exist (desktop 3.16.2, 2026-10-19):
/// - V1: `https://zcode.z.ai/remote/v4?sid=...&hash=...&t=...&mid=...`
///   (proof-of-knowledge auth over `wss://<host>/ws`);
/// - V2: `https://zcode.z.ai/remote/v4?sid=...&mid=...&name=...&app_version=...`
///   (account-JWT auth over `wss://<host>/api/v1/remote/ws2`). The link is
///   pure routing — the token is fetched at connect time.
///
/// Parses the connection URL. The URL also derives the relay
/// websocket endpoint; if the URL shape changes, the raw URL is still stored
/// verbatim by the device store and stays openable in the WebView.
class RemoteConnectionParams {
  final String deviceSid;

  /// V1 only: password hash + timestamp pair. Both null on a V2 link.
  final String? passHash;
  final int? timestamp;
  final String? deviceMid;
  final String? deviceName;
  final String? appVersion;
  final String? theme;
  final Uri source;

  const RemoteConnectionParams({
    required this.deviceSid,
    required this.passHash,
    required this.timestamp,
    required this.source,
    this.deviceMid,
    this.deviceName,
    this.appVersion,
    this.theme,
  });

  static String? _get(Uri uri, String key) {
    final v = uri.queryParameters[key]?.trim();
    return v == null || v.isEmpty ? null : v;
  }

  static RemoteConnectionParams? parse(String raw) {
    Uri uri;
    try {
      uri = Uri.parse(raw.trim());
    } catch (_) {
      return null;
    }
    final sid = _get(uri, 'sid');
    if (sid == null) return null;
    final hash = _get(uri, 'hash');
    final rawTimestamp = _get(uri, 't');
    final timestamp = rawTimestamp == null ? null : int.tryParse(rawTimestamp);
    // V1 needs BOTH hash and t. A half-carrying link is still a V2 link
    // (the desktop 3.16 V2 shape never carries either); the partial
    // credential is dropped so `v2` cannot be fooled by a stray `hash`.
    final v1 = hash != null && timestamp != null;
    if (!v1 && (hash != null || rawTimestamp != null)) {
      debugPrint(
        '[connection] incomplete V1 credentials (hash=${hash != null}, '
        't=$rawTimestamp) — treating the link as V2',
      );
    }
    return RemoteConnectionParams(
      deviceSid: sid,
      passHash: v1 ? hash : null,
      timestamp: v1 ? timestamp : null,
      deviceMid: _get(uri, 'mid'),
      deviceName: _get(uri, 'name'),
      appVersion: _get(uri, 'app_version'),
      theme: _get(uri, 'theme'),
      source: uri,
    );
  }

  /// V2 relay link: no legacy proof credentials. `hash + t` present means
  /// the V1 relay (`/ws` + challenge/proof); otherwise the account-JWT V2
  /// relay (`/api/v1/remote/ws2`).
  bool get v2 => passHash == null;

  /// Relay websocket base URL (the V2 transport appends `token` when it
  /// connects — the 60s token is fetched per (re)connect and never stored):
  /// - V1: `ws(s)://<host>/ws` plus `?mid=` when present;
  /// - V2: `ws(s)://<host>/api/v1/remote/ws2` plus `?mid=` when present.
  Uri get relayWsUri {
    final scheme = uriSchemeIsSecure ? 'wss' : 'ws';
    final base = Uri(
      scheme: scheme,
      host: source.host,
      port: source.hasPort ? source.port : null,
      path: v2 ? '/api/v1/remote/ws2' : '/ws',
    );
    if (deviceMid == null) return base;
    return base.replace(queryParameters: {'mid': deviceMid});
  }

  /// V2 terminal-token endpoint (`POST {"role":"terminal"}`, Bearer = the
  /// ZCode account JWT). Same host as the link.
  Uri get relayTokenUri => Uri(
    scheme: uriSchemeIsSecure ? 'https' : 'http',
    host: source.host,
    port: source.hasPort ? source.port : null,
    path: '/api/v1/remote/token',
  );

  bool get uriSchemeIsSecure =>
      source.scheme == 'https' || source.scheme == 'wss';

  /// Parsed [appVersion] as up to three numeric segments; null when absent
  /// or any segment is non-numeric (e.g. a `-beta` suffix) — callers must
  /// treat null as "unknown", never as "new".
  List<int>? get _versionTriple {
    final parts = appVersion?.split('.');
    if (parts == null) return null;
    final triple = <int>[];
    for (var i = 0; i < 3; i++) {
      final n = i < parts.length ? int.tryParse(parts[i]) : 0;
      if (n == null) return null;
      triple.add(n);
    }
    return triple;
  }

  /// Whether [appVersion] parsed into a comparable numeric triple — false
  /// when the parameter is absent or malformed. Version-gated callers use
  /// this to tell "known old" (safe to use legacy wire shapes) from
  /// "unknown" (fall back to runtime channel probing).
  bool get hasKnownVersion => _versionTriple != null;

  /// Whether the desktop's `app_version` is at least [major].[minor].[patch]
  /// — the first-level gate for 3.12.3 wire shapes (quota `accountAccess`,
  /// automation `scheduleRule`, off-peak positional args). Unknown, absent
  /// or malformed versions answer false so legacy shapes stay the default.
  bool atLeast(int major, int minor, int patch) {
    final t = _versionTriple;
    if (t == null) return false;
    if (t[0] != major) return t[0] > major;
    if (t[1] != minor) return t[1] > minor;
    return t[2] >= patch;
  }
}
