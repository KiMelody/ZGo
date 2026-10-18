// Standalone live probe for the fileService `readFileRange` port (task
// 10-18-file-preview-formats, S1). NOT part of the suite (`tool/**` is
// outside `flutter test` and `flutter analyze` scopes).
//
// Purpose: pin the ACTUAL IPC serialization form of the answer before the
// pdf range transport relies on it.
//
// CERTIFIED 2026-10-18 (research/readfile-range-probe.md): the desktop's
// Uint8Array arrives as a `List<int>` (`_Uint8ArrayView`) straight off the
// IPC decode — never a base64 string, never a `{dataBase64}` map. The port
// parses strictly to that form now; this probe is kept as the reproducible
// harness (rerun it if a desktop version drift is ever suspected).
//
// Run (fresh desktop web-remote link; the first argument may be the URL
// itself or the NAME of an env var holding it):
//
//   dart run tool/file_range_probe.dart <pairing-url|ENV_NAME> <abs-file-path>
//   dart run tool/file_range_probe.dart 'https://zcode.z.ai/remote/v4?sid=…' 'C:\repo\a.pdf'
//   ZLINKER_PROBE_URL='…' ZLINKER_PROBE_PATH='…' dart run tool/file_range_probe.dart
//
// What it does: relay handshake → wait paired → bootstrap → open the first
// workspace bridge → `file` channel call `readFileRange {path, offset: 0,
// length: 4096}` through the REAL [FileServicePort] (a recording wrapper
// dumps the raw decoded answer before the port parses it), then prints the
// parsed FileRange.
//
// Handshake note (why the relay layer is reproduced here instead of
// imported): `dart run` runs on the standalone VM, which cannot load
// `package:flutter` (dart:ui is unavailable) — and relay_client.dart /
// remote_client.dart import package:flutter/foundation. So the relay
// handshake below is a MINIMAL REPLICA (auth_init / auth_challenge /
// auth_ack / pair status / bridge open; no heartbeat, no reconnect, no
// recovery). Everything BELOW the relay — rpc-frame fragmentation,
// ChannelClient, the IPC codec and [FileServicePort] itself — is imported
// verbatim from lib/protocol, so the answer-shape reading comes from the
// production decode path, not a re-implementation. The app-side flow this
// mirrors: device_session.dart connect() + RemoteClient.openBridge.
//
// Attention: the desktop allows ONE terminal per device — running this
// probe kicks any live ZGo/WebView session on that device (and vice versa).
//
// The probe never runs its own retries: a failed step exits non-zero with
// the error printed.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/connection_params.dart';
import 'package:zgo/protocol/file_service.dart';
import 'package:zgo/protocol/id.dart';
import 'package:zgo/protocol/proof.dart';
import 'package:zgo/protocol/rpc_transport.dart';

Future<void> main(List<String> args) async {
  final urlArg = args.isNotEmpty ? args[0] : 'ZLINKER_PROBE_URL';
  final url = urlArg.startsWith('http') || urlArg.startsWith('ws')
      ? urlArg
      : Platform.environment[urlArg] ?? '';
  final path = args.length > 1
      ? args[1]
      : Platform.environment['ZLINKER_PROBE_PATH'] ?? '';
  if (url.isEmpty || path.isEmpty) {
    stderr.writeln('usage: dart run tool/file_range_probe.dart '
        '<pairing-url|ENV_NAME> <abs-file-path>');
    stderr.writeln('  (env fallback: ZLINKER_PROBE_URL / ZLINKER_PROBE_PATH)');
    exit(2);
  }
  final params = RemoteConnectionParams.parse(url);
  if (params == null) {
    stderr.writeln('probe: not a pairing URL (needs sid/hash/t): $url');
    exit(2);
  }

  final probe = _Probe(params);
  try {
    await probe
        .run(path)
        .timeout(const Duration(seconds: 120),
            onTimeout: () => throw TimeoutException('probe deadline (120s)'));
    await probe.close();
    exit(0);
  } catch (e, st) {
    stderr.writeln('probe FAILED: $e');
    stderr.writeln('$st');
    await probe.close();
    exit(1);
  }
}

/// Minimal relay + bridge client (see the handshake note in the header).
class _Probe {
  _Probe(this.params) {
    // Every relay `data` payload goes through the controller: bridge routing
    // rides this listener, request matchers subscribe transiently.
    _payloadRouter = _payloads.stream.listen(_routePayload);
  }

  final RemoteConnectionParams params;
  WebSocket? _socket;
  final _payloads = StreamController<Map<String, dynamic>>.broadcast();
  final _paired = Completer<void>();
  RpcFrameTransport? _transport;
  final _pendingBridgeFrames = <Map<String, dynamic>>[];
  int _bridgeGeneration = 0;
  late final StreamSubscription<Map<String, dynamic>> _payloadRouter;

  void _log(String line) => stdout.writeln(line);

  Future<void> run(String path) async {
    await _connect();
    await _paired.future.timeout(const Duration(seconds: 60),
        onTimeout: () => throw TimeoutException(
            'pairing timeout (60s) — desktop connected? URL fresh?'));
    final workspaces = await _bootstrap();
    if (workspaces.isEmpty) {
      throw StateError('bootstrap returned no workspaces');
    }
    _log('probe: workspaces: ${workspaces.map(_keyOf).toList()}');
    final workspace = workspaces.first;
    final key = _keyOf(workspace);
    if (key == null || key.isEmpty) {
      throw StateError('first workspace has no key: $workspace');
    }
    final workspacePath = workspace['workspacePath'] is String
        ? workspace['workspacePath'] as String
        : key;
    final channels = await _openBridge(key);

    stdout.writeln('');
    stdout.writeln('probe: file.readFileRange '
        '{path: $path, offset: 0, length: 4096}');
    // The recording wrapper prints the RAW decoded answer, then hands it to
    // the production parse — a rejection is printed, not thrown away.
    final port = FileServicePort((method, args) async {
      final raw = await channels.call(Channels.file, method, args);
      _dumpRaw(method, args, raw);
      return raw;
    });
    try {
      final range = await port
          .readFileRange(workspacePath, path, offset: 0, length: 4096);
      stdout.writeln('probe: FileServicePort parse OK — FileRange.length='
          '${range.length}');
      stdout.writeln('probe: parsed head: ${_hex(range.bytes)}');
    } on StateError catch (e) {
      stdout.writeln('probe: FileServicePort parse REJECTED the answer — $e');
      stdout.writeln('probe: the raw dump above is authoritative for S1');
    }
  }

  // ------------------------------------------------------------- relay --
  Future<void> _connect() async {
    final uri = params.relayWsUri;
    _log('probe: connecting $uri');
    final socket = await WebSocket.connect(uri.toString());
    _socket = socket;
    socket.listen(
      _handleRaw,
      onDone: () {
        _log('probe: relay socket closed');
        if (!_paired.isCompleted) {
          _paired.completeError(StateError('relay closed before pairing'));
        }
      },
      onError: (Object e) => _log('probe: relay socket error: $e'),
    );
    // Shape mirrors RelayClient._connect (relay_client.dart:158-168).
    _send({
      'type': 'auth_init',
      'role': 'terminal',
      'device_sid': params.deviceSid,
      'meta': {
        'platform': Platform.operatingSystem,
        'version': params.appVersion ?? 'web',
        'name': 'zgo-file-range-probe',
      },
      'client_ts': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> _handleRaw(dynamic data) async {
    Map<String, dynamic>? frame;
    try {
      final text = data is String ? data : utf8.decode((data as List).cast());
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic> && decoded.containsKey('type')) {
        frame = decoded;
      }
    } catch (_) {
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
        final status = frame['pair_status'] as String?;
        _log('probe: pair_status=$status');
        if (status == 'matched' && !_paired.isCompleted) _paired.complete();
        break;
      case 'data':
        final payload = frame['payload'];
        if (payload is Map<String, dynamic>) _payloads.add(payload);
        break;
      case 'error':
        _log('probe: relay error frame '
            'code=${frame['code']} message=${frame['message']}');
        break;
    }
  }

  /// Routes relay payloads into the bridge transport; rpc-frames that race
  /// ahead of the transport are buffered (the deskop pushes Initialize right
  /// after `workspace-bridge-ready` — same race RemoteClient._attachStack
  /// buffers).
  void _routePayload(Map<String, dynamic> payload) {
    final transport = _transport;
    if (transport != null && transport.acceptPayload(payload)) return;
    if (payload['zcode_type'] == 'rpc-frame') {
      _pendingBridgeFrames.add(payload);
    }
  }

  void _send(Map<String, dynamic> frame) => _socket?.add(jsonEncode(frame));

  /// Data-envelope replica of RelayClient.sendPayload.
  void sendPayload(Map<String, dynamic> payload) {
    _send({
      'type': 'data',
      'payload': payload,
      'client_ts': DateTime.now().millisecondsSinceEpoch,
    });
  }

  // ---------------------------------------------------------- bridge -----
  Future<Map<String, dynamic>> _request(
    Map<String, dynamic> payload,
    bool Function(Map<String, dynamic>) match, {
    Duration timeout = const Duration(seconds: 20),
  }) {
    final completer = Completer<Map<String, dynamic>>();
    final sub = _payloads.stream.listen((p) {
      if (!completer.isCompleted && match(p)) completer.complete(p);
    });
    sendPayload(payload);
    return completer.future
        .timeout(timeout,
            onTimeout: () => throw TimeoutException(
                '${payload['requestId']} timed out — desktop foreground?'))
        .whenComplete(() => sub.cancel());
  }

  Future<List<Map<String, dynamic>>> _bootstrap() async {
    final id = generateRequestId('bootstrap');
    final res = await _request(
      {'zcode_type': 'bootstrap-request', 'requestId': id},
      (p) => p['zcode_type'] == 'bootstrap-response' && p['requestId'] == id,
    );
    final result = (res['result'] as Map?)?.cast<String, dynamic>() ?? res;
    final list = result['workspaces'];
    return [
      if (list is List)
        for (final w in list)
          if (w is Map) w.cast<String, dynamic>(),
    ];
  }

  Future<ChannelClient> _openBridge(String workspaceKey) async {
    final bridgeSessionId = generateRequestId('bridge');
    final requestId = generateRequestId('workspace-bridge');
    final res = await _request(
      {
        'zcode_type': 'workspace-bridge-open',
        'requestId': requestId,
        'bridgeSessionId': bridgeSessionId,
        'bridgeGeneration': ++_bridgeGeneration,
        'workspaceKey': workspaceKey,
      },
      (p) =>
          (p['zcode_type'] == 'workspace-bridge-ready' ||
              p['zcode_type'] == 'workspace-bridge-error') &&
          p['bridgeSessionId'] == bridgeSessionId,
    );
    if (res['zcode_type'] == 'workspace-bridge-error') {
      throw StateError('workspace-bridge-error: ${res['error'] ?? res}');
    }
    final bridge =
        (res['bridge'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    _log('probe: bridge ready: $bridge');
    final transport = RpcFrameTransport(
      bridgeSessionId:
          (bridge['bridgeSessionId'] as String?) ?? bridgeSessionId,
      bridgeGeneration: (bridge['bridgeGeneration'] as num?)?.toInt(),
      recoveryId: bridge['recoveryId'] as String?,
      sendPayload: sendPayload,
      onLog: _log,
    );
    _transport = transport;
    final pending = List<Map<String, dynamic>>.from(_pendingBridgeFrames);
    _pendingBridgeFrames.clear();
    for (final p in pending) {
      transport.acceptPayload(p);
    }
    final channels =
        ChannelClient(sendBody: transport.sendMessage, onLog: _log);
    transport.messages.listen(channels.handleMessage);
    return channels;
  }

  // ------------------------------------------------------------ report ---
  /// Raw-answer dump: runtimeType + top-level structure + head bytes. Any
  /// byte interpretation printed here is a PREVIEW only — the authoritative
  /// reading is the production [FileServicePort] parse result.
  void _dumpRaw(String method, List<Object?> args, dynamic raw) {
    stdout.writeln('raw: $method args=${jsonEncode(args)}');
    stdout.writeln('raw: runtimeType=${raw.runtimeType}');
    if (raw is String) {
      stdout.writeln('raw: String length=${raw.length}');
      stdout.writeln('raw: head=${jsonEncode(raw.substring(0, math.min(160, raw.length)))}');
    } else if (raw is List) {
      stdout.writeln('raw: List length=${raw.length}');
      stdout.writeln('raw: elementTypes(first 8)='
          '${raw.take(8).map((e) => e.runtimeType).toList()}');
      stdout.writeln('raw: head=${raw.take(8).toList()}');
    } else if (raw is Map) {
      stdout.writeln('raw: Map keys=${raw.keys.toList()}');
      raw.forEach((k, v) =>
          stdout.writeln('raw: [$k] ${v.runtimeType} = ${_preview(v)}'));
    } else {
      stdout.writeln('raw: value=$raw');
    }
    final bytes = _tryBytes(raw);
    if (bytes != null) {
      stdout.writeln('raw: byte interpretation preview: ${bytes.length} bytes, '
          'head=${_hex(bytes)}');
    } else {
      stdout.writeln('raw: no byte interpretation of this shape');
    }
  }

  static String _preview(dynamic v) {
    if (v is String) {
      return v.length > 120
          ? '${jsonEncode(v.substring(0, 120))}…(${v.length} chars)'
          : jsonEncode(v);
    }
    return '$v';
  }

  /// The live-certified form only: a byte list off the IPC decode. Any other
  /// shape is reported as such (the probe's point is to surface drift).
  static Uint8List? _tryBytes(dynamic raw) {
    if (raw is List && raw.every((e) => e is int)) {
      return Uint8List.fromList(raw.cast<int>());
    }
    return null;
  }

  static String _hex(Uint8List bytes, {int max = 32}) {
    final head = bytes
        .take(max)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(' ');
    return bytes.length > max ? '$head …' : head;
  }

  /// Same key rule as the app (state/task_directory.dart `workspaceKeyOf`).
  static String? _keyOf(Map<String, dynamic> w) {
    final identity = w['workspaceIdentity'];
    if (identity is String && identity.trim().isNotEmpty) {
      return identity.trim();
    }
    final path = w['workspacePath'];
    if (path is String && path.isNotEmpty) return path;
    for (final key in const ['workspaceKey', 'key', 'id']) {
      final v = w[key];
      if (v is String && v.isNotEmpty) return v;
    }
    return null;
  }

  Future<void> close() async {
    await _payloadRouter.cancel();
    await _transport?.dispose();
    await _socket?.close();
    await _payloads.close();
  }
}
