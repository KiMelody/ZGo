import 'dart:async';
import 'dart:typed_data';

import 'ipc_codec.dart';

/// Channel RPC client over the relay channel.
///
/// Request header array: [reqType, reqId, channelName, name] followed by the
/// argument value (an args list for calls, free-form for event listens).
/// Response: [respType, reqId] + data value.
class ChannelClient {
  static const reqPromise = 100;
  static const reqPromiseCancel = 101;
  static const reqEventListen = 102;
  static const reqEventDispose = 103;

  static const resInitialize = 200;
  static const resPromiseSuccess = 201;
  static const resPromiseError = 202;
  static const resPromiseErrorObj = 203;
  static const resEventFire = 204;

  final void Function(Uint8List ipcBody) sendBody;
  final void Function(String line)? onLog;

  int _lastRequestId = 0;
  final _initialized = Completer<void>();
  final _handlers = <int, void Function(int type, Object? data)>{};

  ChannelClient({required this.sendBody, this.onLog});

  Future<void> get ready => _initialized.future;

  void handleMessage(Uint8List body) {
    final reader = ValueReader(body);
    final header = decodeValue(reader);
    if (header is! List || header.isEmpty) return;
    final type = (header[0] as num).toInt();
    if (type == resInitialize) {
      onLog?.call('[ipc] initialized');
      if (!_initialized.isCompleted) _initialized.complete();
      return;
    }
    final id = (header[1] as num).toInt();
    final data = decodeValue(reader);
    _handlers[id]?.call(type, data);
  }

  void _sendRequest(int reqType, int id, String channel, String name,
      Object? arg) {
    final writer = ValueWriter();
    encodeValue(writer, [reqType, id, channel, name]);
    encodeValue(writer, arg);
    sendBody(writer.toBytes());
  }

  Future<dynamic> call(
    String channel,
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    return Future.wait([
      ready.timeout(const Duration(seconds: 30), onTimeout: () {
        throw TimeoutException(
            'channel init timeout (no Initialize frame from desktop)');
      }),
    ]).then((_) {
      final id = _lastRequestId++;
      final completer = Completer<dynamic>();
      _handlers[id] = (type, data) {
        switch (type) {
          case resPromiseSuccess:
            _handlers.remove(id);
            completer.complete(data);
            break;
          case resPromiseError:
            _handlers.remove(id);
            final message =
                data is Map ? (data['message'] ?? data).toString() : '$data';
            completer.completeError(ChannelRpcError(message, data));
            break;
          case resPromiseErrorObj:
            _handlers.remove(id);
            completer.completeError(ChannelRpcError('$data', data));
            break;
        }
      };
      onLog?.call('[ipc] call $channel.$method id=$id');
      _sendRequest(reqPromise, id, channel, method, args);
      return completer.future.timeout(timeout, onTimeout: () {
        _handlers.remove(id);
        throw TimeoutException('$channel.$method timed out', timeout);
      });
    });
  }

  /// Subscribe to a channel event. Returns a cancel function which sends
  /// EventDispose. Backs `requestEvent` / `sendCancelOrDispose`.
  void Function() addEventListener(
    String channel,
    String event,
    void Function(dynamic event) onEvent, {
    Object? arg,
  }) {
    final id = _lastRequestId++;
    _handlers[id] = (type, data) {
      if (type == resEventFire) onEvent(data);
    };
    ready.then((_) {
      onLog?.call('[ipc] listen $channel.$event id=$id');
      _sendRequest(reqEventListen, id, channel, event, arg);
    });
    return () {
      _handlers.remove(id);
      _sendRequest(reqEventDispose, id, channel, event, null);
    };
  }

  void dispose() => _handlers.clear();
}

class ChannelRpcError implements Exception {
  final String message;
  final Object? data;
  ChannelRpcError(this.message, this.data);

  @override
  String toString() => 'ChannelRpcError: $message';
}

/// True for the desktop's "channel does not resolve" RPC error: the remote
/// bridge answers channels that are not registered with
/// `Channel name '…' timed out after 1000ms` (identical to probing a bogus
/// channel name). The 2026-09 model-provider outage became permanent in
/// desktop 3.12.3, which removed the channel outright — the providers page
/// entry is now capability-gated on a probe
/// (DeviceSession.probeModelProvider).
bool isChannelMissingError(Object error) =>
    error is ChannelRpcError &&
    error.message.contains('Channel name') &&
    error.message.contains('timed out');

/// Channel-level failure: the RPC timed out or the channel is missing on
/// the desktop. Unlike a bridge-health failure this does not by itself mean
/// the whole link is wedged, so callers count per-channel failures instead
/// of tearing the link down on first sight.
bool isChannelLevelError(Object error) =>
    error is TimeoutException || isChannelMissingError(error);

/// The bridge-health gate expiring ([BridgeSession.waitHealthy] timing
/// out): the link itself is degraded, so — unlike the per-channel counting
/// of [isChannelLevelError] — its FIRST occurrence escalates into a rebuild
/// (ADR-0009 bridge-level tier). Matches the deliberate, language-neutral
/// diagnostic text waitHealthy throws; that text is the cross-layer
/// contract this predicate rides.
bool isBridgeGateTimeoutError(Object error) =>
    error is TimeoutException &&
    (error.message ?? '').startsWith('bridge recovery timed out');

/// The task mutation's registry-resolve failure (design C1 10-05 D4): the
/// desktop's resolveTaskAddress matched zero rows for the
/// (taskId, workspacePath, identity) triple — the live shape is
/// 「列表 mutation 无法解析唯一 source, taskId=…」(research-emulator.md
/// A-1), the numeric `matches=0` form covers other desktop wordings. A
/// registry-external row (fork draft) or a row vanished between listing
/// and confirming can never resolve; delete routing falls back to the V4
/// session command through this predicate.
///
/// The desktop markers are shared constants so the string-level
/// [isTaskResolveFailureText] (used by the error-copy mapping, which only
/// sees the stringified error) and this predicate stay one source of truth.
const String taskResolveSourceMarker = '无法解析唯一 source';
const String taskResolveMatchesMarker = 'matches=0';

/// String-level form of [isTaskResolveFailure] for callers that hold the
/// error only as text (`'$e'` in a SnackBar path).
bool isTaskResolveFailureText(String text) =>
    text.contains(taskResolveSourceMarker) ||
    text.contains(taskResolveMatchesMarker);

bool isTaskResolveFailure(Object error) =>
    error is ChannelRpcError && isTaskResolveFailureText(error.message);

/// The desktop's session-busy refusal (design C1 10-05 D1): session-scoped
/// commands (fork, …) are rejected with 「会话正在进行中，稍后再试」 while
/// the session is mid-turn (research-emulator.md「busy 之谜」, four
/// consecutive live hits). Matches the stable core phrase — the trailing
/// 「稍后再试」 is desktop copy, not contract. User intent stays a manual
/// retry; the app maps this to plain-language copy, never auto-resends.
const String sessionBusyMarker = '会话正在进行中';

/// String-level form of [isSessionBusyError] for callers that hold the
/// error only as text (`'$e'` in a SnackBar path).
bool isSessionBusyErrorText(String text) => text.contains(sessionBusyMarker);

bool isSessionBusyError(Object error) =>
    error is ChannelRpcError && isSessionBusyErrorText(error.message);

/// Well-known channel names (`Wb` enum in the web client).
class Channels {
  static const file = 'file';
  static const system = 'system';
  static const terminal = 'terminal';
  static const git = 'git';
  static const gitCheckpoint = 'git-checkpoint';
  static const setting = 'setting';
  static const credential = 'credential';
  static const broadcast = 'broadcast';
  static const zcodeTask = 'zcode-task';
  static const zcodeAgent = 'zcode-agent';
  static const zcodeSession = 'zcode-session';
  static const fileWatcher = 'file-watcher';
  static const oauth = 'oauth';
  static const modelProvider = 'model-provider';
  static const usageStats = 'usage-stats';
  static const codingPlanSubscription = 'coding-plan-subscription';
  static const skills = 'skills';
  static const skillSync = 'skill-sync';
  static const mcpSync = 'mcp-sync';
  static const pluginSync = 'plugin-sync';
  static const plugins = 'plugins';
  static const pluginManagement = 'plugin-management';
  static const subagents = 'subagents';
  static const commands = 'commands';
  static const hooks = 'hooks';
  static const memory = 'memory';
  static const outputStyle = 'output-style';
  static const settingsSync = 'settings-sync';
  static const bots = 'bots';
  static const feedback = 'feedback';
  static const repoWiki = 'repo-wiki';
  static const promptAttachmentTransfer = 'prompt-attachment-transfer';
  static const offPeakTask = 'off-peak-task';

  /// Desktop ≥3.14 read-only model registry (getView). Replaces the removed
  /// `model-provider` channel as the chat model sheet's fallback catalog
  /// source — the CRUD family (save/delete) has no counterpart here.
  static const modelSelection = 'model-selection';

  /// Desktop ≥3.14 provider settings (getView CRUD + onDidChange). The full
  /// management replacement for the removed `model-provider` channel —
  /// templates, personal provider CRUD, model management and live refresh.
  static const providerSettings = 'provider-settings';
}
