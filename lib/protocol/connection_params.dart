/// Parses a ZCode web-remote connection URL, e.g.
/// https://zcode.z.ai/remote/v4?sid=...&hash=...&t=...&mid=...&name=...&app_version=...
///
/// Mirrors `zC()` in the web client bundle. The URL also derives the relay
/// websocket endpoint; if the URL shape changes, the raw URL is still stored
/// verbatim by the device store and stays openable in the WebView.
class RemoteConnectionParams {
  final String deviceSid;
  final String passHash;
  final int timestamp;
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
    final hash = _get(uri, 'hash');
    final t = int.tryParse(_get(uri, 't') ?? '');
    if (sid == null || hash == null || t == null) return null;
    return RemoteConnectionParams(
      deviceSid: sid,
      passHash: hash,
      timestamp: t,
      deviceMid: _get(uri, 'mid'),
      deviceName: _get(uri, 'name'),
      appVersion: _get(uri, 'app_version'),
      theme: _get(uri, 'theme'),
      source: uri,
    );
  }

  /// Relay websocket URL. Mirrors `Jc()` / `pen.connect()` in the web client:
  /// `ws(s)://<host>/ws` plus `?mid=` when present.
  Uri get relayWsUri {
    final scheme = uriSchemeIsSecure ? 'wss' : 'ws';
    final base = Uri(
      scheme: scheme,
      host: source.host,
      port: source.hasPort ? source.port : null,
      path: '/ws',
    );
    if (deviceMid == null) return base;
    return base.replace(queryParameters: {'mid': deviceMid});
  }

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
