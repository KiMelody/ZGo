// READ-ONLY live probe for the S6 pdf range semantics (task
// 10-18-file-preview-formats, S6 device gate). NOT part of the suite
// (`tool/**` is outside `flutter test` / `flutter analyze` scopes).
//
// Scope discipline (user directive 2026-10-18): this probe issues ONLY
// `stat` + `readFileRange` calls, ONLY on the file paths handed to it on
// the command line — no writes, no other files, nothing else.
//
// What it certifies live (asar-certified claims from
// research/official-pdf-integration.md §6 + the wire form from
// research/readfile-range-probe.md, now against REAL pdf payloads):
//  1. stat answers size/type (the three-state fork's input);
//  2. the eager 256 KiB loop (the app's size<=2MiB leg) reassembles the
//     file byte-identically through the production port;
//  3. an oversized length request (1.5 MiB) clamps to exactly 1 MiB;
//  4. a tail read past-EOF-in-length returns exactly the remaining bytes;
//  5. an offset beyond EOF answers an EMPTY payload, not an error;
//  6. an arbitrary mid-file range matches the local bytes.
//
// The desktop IS local to this machine, so the local file is read for the
// byte-exact reference (not an md5 — full comparison).
//
// Run (URL must ride an env var — dart.bat's cmd layer splits `&` args):
//   ZLINKER_PROBE_URL='https://zcode.z.ai/remote/v4?…' \
//     dart run tool/pdf_s6_probe.dart 'F:\tmp\s6_small.pdf' 'F:\tmp\s6_big.pdf'
//
// Everything below the relay handshake (rpc-frame, ChannelClient, IPC
// codec, FileServicePort) is imported verbatim from lib/protocol — see
// tool/file_range_probe.dart for the handshake-replica rationale. The
// probe kicks any live terminal on the device (one-terminal rule) and
// never retries: a failed step exits non-zero.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/connection_params.dart';
import 'package:zgo/protocol/file_service.dart';
import 'package:zgo/protocol/id.dart';
import 'package:zgo/protocol/proof.dart';
import 'package:zgo/protocol/rpc_transport.dart';

Future<void> main(List<String> args) async {
  final url = Platform.environment['ZLINKER_PROBE_URL'] ?? '';
  if (url.isEmpty || args.isEmpty) {
    stderr.writeln('usage: ZLINKER_PROBE_URL=<pairing-url> '
        'dart run tool/pdf_s6_probe.dart <abs-file> [<abs-file> …]');
    exit(2);
  }
  final params = RemoteConnectionParams.parse(url);
  if (params == null) {
    stderr.writeln('probe: not a pairing URL (needs sid/hash/t)');
    exit(2);
  }

  final probe = _Probe(params);
  try {
    await probe
        .run(args)
        .timeout(const Duration(seconds: 180),
            onTimeout: () => throw TimeoutException('probe deadline (180s)'));
    await probe.close();
    exit(0);
  } catch (e, st) {
    stderr.writeln('probe FAILED: $e');
    stderr.writeln('$st');
    await probe.close();
    exit(1);
  }
}

const _step = 256 * 1024;
const _clampBytes = 1024 * 1024;

bool _check(String label, bool pass) {
  stdout.writeln('  ${pass ? 'PASS' : 'FAIL'}  $label');
  return pass;
}

bool _bytesEqual(Uint8List a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Uint8List _concat(List<Uint8List> parts, int total) {
  final out = Uint8List(total);
  var at = 0;
  for (final p in parts) {
    out.setAll(at, p);
    at += p.length;
  }
  return out;
}

Future<bool> _sweepOne(
  FileServicePort port,
  String workspacePath,
  String path,
) async {
  stdout.writeln('');
  stdout.writeln('=== $path ===');
  final local = Uint8List.fromList(await File(path).readAsBytes());
  final size = local.length;
  var ok = true;

  final stat = await port.stat(workspacePath, path);
  stdout.writeln('stat: type=${stat.type} size=${stat.size} local=$size');
  ok = _check('stat.size present and equals local size', stat.size == size);

  // 2. the eager 256 KiB loop — the app's size<=2MiB leg, byte-exact.
  final parts = <Uint8List>[];
  var offset = 0;
  var calls = 0;
  var emptyTermination = false;
  while (offset < size) {
    final r =
        await port.readFileRange(workspacePath, path, offset: offset, length: _step);
    calls++;
    if (r.length == 0) {
      emptyTermination = true;
      break;
    }
    parts.add(r.bytes);
    offset += r.length;
  }
  final assembled = _concat(parts, offset);
  stdout.writeln('eager loop: $calls calls -> ${assembled.length}B'
      '${emptyTermination ? ' (empty-payload termination)' : ''}');
  ok = _check('eager loop covers the whole file (offset stopped at $offset)',
          offset == size) &&
      ok;
  ok = _check('eager loop is byte-identical to the local file',
          _bytesEqual(assembled, local)) &&
      ok;

  // 3. oversized length -> server clamps to 1 MiB.
  final clamped =
      await port.readFileRange(workspacePath, path, offset: 0, length: 1536 * 1024);
  final clampExpect = size < _clampBytes ? size : _clampBytes;
  ok = _check(
      'oversize ask (1536KiB) clamps to ${clampExpect}B (got ${clamped.length}B)',
      clamped.length == clampExpect) &&
      ok;
  ok = _check('clamped head is byte-identical',
          _bytesEqual(clamped.bytes, local.sublist(0, clamped.length))) &&
      ok;

  // 4. tail: length runs past EOF -> exactly the remaining bytes.
  const tailLen = 1000;
  final tail = await port.readFileRange(workspacePath, path,
      offset: size - tailLen, length: _step);
  ok = _check('tail read answers exactly $tailLen B (got ${tail.length}B)',
          tail.length == tailLen) &&
      ok;
  ok = _check('tail bytes match the local tail',
          _bytesEqual(tail.bytes, local.sublist(size - tailLen))) &&
      ok;

  // 5. offset beyond EOF -> EMPTY payload, never an error.
  Object? beyondError;
  var beyondLen = -1;
  try {
    final beyond = await port.readFileRange(workspacePath, path,
        offset: size + 4096, length: 4096);
    beyondLen = beyond.length;
  } catch (e) {
    beyondError = e;
  }
  ok = _check(
      'beyond-EOF answers EMPTY payload (len=$beyondLen err=${beyondError ?? 'none'})',
      beyondError == null && beyondLen == 0) &&
      ok;

  // 6. arbitrary mid-file range integrity (256KiB-aligned below midpoint).
  final mid = (size ~/ 2 ~/ _step) * _step;
  final midr =
      await port.readFileRange(workspacePath, path, offset: mid, length: _step);
  final midExpect = mid + _step <= size ? _step : size - mid;
  ok = _check(
      'mid range @$mid answers ${midExpect}B (got ${midr.length}B) and matches',
      midr.length == midExpect &&
          _bytesEqual(midr.bytes, local.sublist(mid, mid + midExpect))) &&
      ok;

  return ok;
}

/// Minimal relay + bridge client — verbatim replica of the certified
/// handshake in tool/file_range_probe.dart (see its header comment).
class _Probe {
  _Probe(this.params) {
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

  Future<void> run(List<String> paths) async {
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

    final port = FileServicePort(
        (method, args) => channels.call(Channels.file, method, args));
    var ok = true;
    for (final path in paths) {
      ok = await _sweepOne(port, workspacePath, path) && ok;
    }
    stdout.writeln('');
    if (!ok) throw StateError('SWEEP FAILED — see the FAIL lines above');
    stdout.writeln('probe: ALL CHECKS PASSED');
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
    _send({
      'type': 'auth_init',
      'role': 'terminal',
      'device_sid': params.deviceSid,
      'meta': {
        'platform': Platform.operatingSystem,
        'version': params.appVersion ?? 'web',
        'name': 'zgo-pdf-s6-probe',
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

  void _routePayload(Map<String, dynamic> payload) {
    final transport = _transport;
    if (transport != null && transport.acceptPayload(payload)) return;
    if (payload['zcode_type'] == 'rpc-frame') {
      _pendingBridgeFrames.add(payload);
    }
  }

  void _send(Map<String, dynamic> frame) => _socket?.add(jsonEncode(frame));

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
