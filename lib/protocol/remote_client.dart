// Newer style lints are suppressed so this file keeps its transport
// handling readable as a single, self-contained unit.
// ignore_for_file: use_null_aware_elements, prefer_initializing_formals
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'channel_client.dart';
import 'connection_params.dart';
import 'conversation.dart';
import 'device_info.dart';
import 'id.dart';
import 'relay_client.dart';
import 'relay_transport.dart';
import 'relay_v2.dart';
import 'rpc_transport.dart';

String _reqId(String prefix) => generateRequestId(prefix);

/// Builds the `mobile-view-state-update` payload (external-relay union,
/// desktop zod: `deviceInfo` is optional as a whole but — once present —
/// requires `updatedAt`: a finite number, NOT `.optional()`. A
/// deviceInfo without it fails the union and the desktop drops the whole
/// payload, `invalid external relay payload dropped`; see task 10-11
/// view-state-drop-investigation §2/§5). Top-level so tests can pin the
/// wire shape without a socket.
Map<String, dynamic> mobileViewStatePayload({
  required String workspaceKey,
  String? taskId,
  String? appVersion,
}) =>
    {
      'zcode_type': 'mobile-view-state-update',
      'viewState': {
        'activeWorkspaceKey': workspaceKey,
        if (taskId != null) 'activeTaskId': taskId,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      },
      'deviceInfo': {
        'platform': remotePlatformName(),
        'version': appVersion ?? 'web',
        'name': remoteAppName,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      },
    };

/// High-level facade replicating the web client's `otn()` flow:
/// relay connect -> pair -> bootstrap -> workspace bridge -> channel RPC.
class RemoteClient {
  final RemoteConnectionParams params;
  final void Function(String line)? onLog;

  /// ZCode account JWT seam for the V2 relay. The protocol layer never
  /// imports the plan layer — the state layer injects this callback.
  final Future<String?> Function()? jwtProvider;

  /// Test seam: overrides the transport construction (a fake
  /// [RelayTransport] drives the payload layer without a socket).
  @visibleForTesting
  final RelayTransport Function(RemoteConnectionParams params)? transportFactory;

  /// V1 (`RelayClient`, proof handshake) or V2 (`RelayV2Transport`,
  /// account-JWT auth), picked from the link shape. Everything above the
  /// transport is shared: the payload layer is identical on both relays.
  late final RelayTransport relay;
  final _pendingMatchers = <String, bool Function(Map<String, dynamic>)>{};
  final _pendingCompleters = <String, Completer<Map<String, dynamic>>>{};

  StreamSubscription? _payloadSub;

  final _workspaceListUpdatedController = StreamController<dynamic>.broadcast();
  Stream<dynamic> get workspaceListUpdated =>
      _workspaceListUpdatedController.stream;

  /// `app-error` payloads (relay-level request failures carrying a reason
  /// from the `Og` enum). Surface to the session layer for failure-state
  /// mapping; also fails the matching pending request fast instead of
  /// letting it ride to its timeout.
  final _appErrorController = StreamController<RemoteAppError>.broadcast();
  Stream<RemoteAppError> get appErrors => _appErrorController.stream;

  RemoteClient(
    this.params, {
    this.onLog,
    this.jwtProvider,
    this.transportFactory,
  }) {
    relay = transportFactory?.call(params) ??
        (params.v2
            ? RelayV2Transport(params, jwtProvider: jwtProvider, onLog: onLog)
            : RelayClient(params, onLog: onLog));
    _payloadSub = relay.payloads.listen(_dispatchPayload);
    relay.stateListenable.addListener(_onRelayState);
  }

  /// `app-error {requestId?, bridgeSessionId?, reason, error?}` — reason
  /// enum collects the relay close codes plus the bootstrap-timeout /
  /// recovery-timeout / unsupported-action family. Fails the pending
  /// request (if the error answers one) and republishes on [appErrors].
  void _handleAppError(Map<String, dynamic> payload) {
    final error = RemoteAppError(
      '${payload['reason'] ?? 'unexpected-error'}',
      payload['error'] is String ? payload['error'] as String : null,
    );
    _log('[relay] app-error: ${error.reason} ${error.message ?? ''}');
    final requestId = payload['requestId'] as String?;
    if (requestId != null) {
      final completer = _pendingCompleters[requestId];
      if (completer != null && !completer.isCompleted) {
        _pendingMatchers.remove(requestId);
        _pendingCompleters.remove(requestId);
        completer.completeError(error);
      }
    }
    if (!_appErrorController.isClosed) _appErrorController.add(error);
  }

  void _log(String line) => onLog?.call(line);

  Future<void> connect() => relay.start();

  bool _needsBridgeRecovery = false;

  /// Relay reconnects happen silently (heartbeat timeout, network switch,
  /// laptop sleep). After re-pairing, every active bridge must be
  /// recovered — the connection-recovery path.
  void _onRelayState() {
    final state = relay.state;
    if (state == RelayState.reconnecting || state == RelayState.error) {
      if (_activeBridges.isNotEmpty) {
        _needsBridgeRecovery = true;
        // Mark bridges degraded immediately so in-flight commands gate on
        // recovery instead of timing out on the now-dead socket/bridge.
        for (final s in _activeBridges) {
          if (s.degraded.value == null) s.markDegraded('reconnecting');
        }
      }
      return;
    }
    if (state == RelayState.paired && _needsBridgeRecovery) {
      _needsBridgeRecovery = false;
      _recoverActiveBridges();
    }
  }

  Future<void> _recoverActiveBridges() async {
    _log('[bridge] recovering ${_activeBridges.length} bridge(s)');
    for (final session in List<BridgeSession>.from(_activeBridges)) {
      if (_recoveringBridges.contains(session)) continue;
      _recoveringBridges.add(session);
      unawaited(_recoverBridgeWithRetry(session));
    }
  }

  final Set<BridgeSession> _recoveringBridges = {};

  /// Workspaces the desktop answered `success:false` + "不在当前窗口" for.
  /// That reply is deterministic: a reconnect-request can never succeed for
  /// these keys, so later recoveries go straight to the reopen path. Kept
  /// for the process lifetime — reopen succeeds even after the window is
  /// switched back, so there is no cheaper state to return to.
  final Set<String> _windowMissedWorkspaces = {};

  /// Retries bridge recovery until it succeeds, so a degraded bridge never
  /// strands commands ("can't send after reconnect"). A relay re-drop during
  /// the retries just prolongs the loop.
  Future<void> _recoverBridgeWithRetry(BridgeSession session) async {
    try {
      for (var attempt = 1; attempt <= 15; attempt++) {
        if (session._disposed) return;
        if (await _recoverBridgeOnce(session)) return;
        if (session._disposed) return;
        _log('[bridge] recovery attempt $attempt failed, retrying');
        await Future.delayed(const Duration(seconds: 3));
      }
    } finally {
      _recoveringBridges.remove(session);
    }
  }

  /// Returns true when the bridge is healthy again.
  Future<bool> _recoverBridgeOnce(BridgeSession session) async {
    final workspaceKey = session.bridge['workspaceKey'] as String?;
    if (workspaceKey == null) {
      // Nothing to reconnect; clear the degraded flag so commands unblock.
      session.degraded.value = null;
      return true;
    }
    session.markDegraded('recovering');
    // 1) cheap path: workspace-reconnect-request. Skipped once the desktop
    // has told us this workspace is not in its current window.
    if (_windowMissedWorkspaces.contains(workspaceKey)) {
      _log('[bridge] skip reconnect (window-missed remembered): $workspaceKey');
    } else {
      try {
        final res = await reconnectWorkspace(
          workspaceKey,
        ).timeout(const Duration(seconds: 15));
        if (res['success'] == true) {
          _log('[bridge] reconnected $workspaceKey');
          session.degraded.value = null;
          session.recovered.value += 1;
          return true;
        }
        final error = res['error'];
        if (res['success'] == false &&
            error is String &&
            error.contains('不在当前窗口')) {
          _windowMissedWorkspaces.add(workspaceKey);
        }
      } catch (e) {
        _log('[bridge] reconnect-request failed: $e');
      }
    }
    // 2) full reopen: new workspace-bridge-open, swap the transport stack
    // into the SAME BridgeSession so open pages keep working.
    try {
      await _reopenBridge(session, workspaceKey);
      session.degraded.value = null;
      session.recovered.value += 1;
      return true;
    } catch (e) {
      _log('[bridge] reopen failed: $e');
      session.markDegraded('reopen-failed: $e');
      return false;
    }
  }

  /// Waits until the relay reports `matched` (paired with the desktop).
  Future<void> waitPaired({Duration timeout = const Duration(seconds: 60)}) {
    if (relay.state == RelayState.paired) return Future.value();
    final completer = Completer<void>();
    Timer? timer;
    void listener() {
      if (relay.state == RelayState.paired && !completer.isCompleted) {
        timer?.cancel();
        completer.complete();
      }
    }

    relay.stateListenable.addListener(listener);
    timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.completeError(TimeoutException('pairing timeout'));
      }
    });
    return completer.future.whenComplete(() {
      timer?.cancel();
      relay.stateListenable.removeListener(listener);
    });
  }

  void _dispatchPayload(Map<String, dynamic> payload) {
    final type = payload['zcode_type'];
    if (type == 'workspace-list-updated') {
      _workspaceListUpdatedController.add(payload['result']);
      return;
    }
    if (type == 'app-error') {
      _handleAppError(payload);
      return;
    }
    if (type == 'bridge-degraded') {
      _handleBridgeDegraded(payload);
      return;
    }
    if (type == 'rpc-frame' || type == 'rpc-frame-ack') {
      // Race: the desktop may push frames (e.g. IPC Initialize) before
      // openBridge's await continuation attaches the transport. Buffer
      // unknown-bridge frames and flush on registration.
      final id = payload['bridgeSessionId'] as String?;
      final router = id == null ? null : _frameRouters[id];
      if (router != null) {
        router(payload);
      } else if (id != null) {
        (_pendingBridgePayloads[id] ??= []).add(payload);
      }
      return;
    }
    // Request matching: every pending matcher is
    // tested against every payload; responses are NOT guaranteed to echo
    // our requestId.
    final done = <String>[];
    _pendingMatchers.forEach((requestId, matcher) {
      final completer = _pendingCompleters[requestId];
      if (completer != null && !completer.isCompleted && matcher(payload)) {
        done.add(requestId);
        completer.complete(payload);
      }
    });
    for (final id in done) {
      _pendingMatchers.remove(id);
      _pendingCompleters.remove(id);
    }
  }

  /// Request/response over relay payloads.
  Future<Map<String, dynamic>> request(
    Map<String, dynamic> payload,
    bool Function(Map<String, dynamic>) match, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    final requestId = payload['requestId'] as String;
    final completer = Completer<Map<String, dynamic>>();
    _pendingMatchers[requestId] = match;
    _pendingCompleters[requestId] = completer;
    relay.sendPayload(payload);
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pendingMatchers.remove(requestId);
        _pendingCompleters.remove(requestId);
        throw TimeoutException('request $requestId timed out');
      },
    );
  }

  /// bootstrap-request -> bootstrap-response (workspaces overview).
  ///
  /// The desktop's live app version rides the FRAME top level as
  /// `desktopAppVersion` (live-probed 3.16.3), outside `result`. It is
  /// preserved on the returned map for version gates: the paired link's
  /// `app_version` is a generation-time snapshot and can lag the running
  /// desktop (a 3.16.3 desktop behind a 3.16.2 link, live acceptance
  /// 2026-10-26).
  Future<Map<String, dynamic>> bootstrap() async {
    final id = _reqId('bootstrap');
    final res = await request({
      'zcode_type': 'bootstrap-request',
      'requestId': id,
    }, (p) => p['zcode_type'] == 'bootstrap-response' && p['requestId'] == id);
    final result = (res['result'] as Map?)?.cast<String, dynamic>() ?? res;
    final version = res['desktopAppVersion'];
    if (version is String && version.trim().isNotEmpty) {
      return {...result, 'desktopAppVersion': version.trim()};
    }
    return result;
  }

  /// workspace-list-request -> workspace-list-response.
  Future<dynamic> listWorkspaces() async {
    final id = _reqId('workspace-list');
    final res = await request(
      {'zcode_type': 'workspace-list-request', 'requestId': id},
      (p) =>
          p['zcode_type'] == 'workspace-list-response' && p['requestId'] == id,
    );
    return res['result'];
  }

  int _bridgeGeneration = 0;
  final _activeBridges = <BridgeSession>[];
  final _frameRouters = <String, void Function(Map<String, dynamic>)>{};
  final _pendingBridgePayloads = <String, List<Map<String, dynamic>>>{};

  /// bridge-degraded (e.g. `rpc-transport-fault`): the desktop stopped the
  /// bridge transport. Mark it degraded and kick off the retrying recovery
  /// loop (the connection-recovery path) so it never stays stuck.
  Future<void> _handleBridgeDegraded(Map<String, dynamic> payload) async {
    final bridgeSessionId = payload['bridgeSessionId'] as String?;
    final reason = payload['reason'] as String?;
    _log('[bridge] degraded: $bridgeSessionId reason=$reason');
    var found = false;
    for (final session in _activeBridges) {
      if (session.bridge['bridgeSessionId'] == bridgeSessionId) {
        session.markDegraded(reason ?? 'unknown');
        found = true;
      }
    }
    if (found) _recoverActiveBridges();
  }

  /// workspace-bridge-open -> workspace-bridge-ready, then builds the
  /// rpc-frame transport + IPC channel client for the workspace.
  ///
  /// [project] and [taskHostId] are the 3.16.3+ desktop addressing fields:
  /// when [workspaceKey] misses the bound window's registry, the desktop
  /// uses them to `prepareProjectWorkspace` first (project draft addressing
  /// for a new chat, task host addressing for an existing task). Both are
  /// omitted unless passed explicitly, so pre-3.16.3 frames stay
  /// byte-identical to the pre-addressing shape. `project` is mutually
  /// exclusive with `taskId` server-side.
  Future<BridgeSession> openBridge(
    String workspaceKey, {
    String? taskId,
    Map<String, dynamic>? project,
    String? taskHostId,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final bridgeSessionId = _reqId('bridge');
    final generation = ++_bridgeGeneration;
    final requestId = _reqId('workspace-bridge');
    final res = await request(
      {
        'zcode_type': 'workspace-bridge-open',
        'requestId': requestId,
        'bridgeSessionId': bridgeSessionId,
        'bridgeGeneration': generation,
        'workspaceKey': workspaceKey,
        if (taskId != null) 'taskId': taskId,
        if (taskHostId != null) 'taskHostId': taskHostId,
        if (project != null) 'project': project,
      },
      (p) =>
          (p['zcode_type'] == 'workspace-bridge-ready' ||
              p['zcode_type'] == 'workspace-bridge-error') &&
          p['bridgeSessionId'] == bridgeSessionId,
      timeout: timeout,
    );
    if (res['zcode_type'] == 'workspace-bridge-error') {
      throw StateError('workspace-bridge-error: ${res['error'] ?? res}');
    }
    final bridge =
        (res['bridge'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    _log('[bridge] ready: $bridge');

    final session = BridgeSession._(
      bridge: bridge,
      // Only the 3.16.3+ window-gate fallback leg passes taskHostId; that
      // pair is what made the desktop prepare the workspace into its bound
      // window, so recovery must replay it. A first-leg open (workspaceKey,
      // or workspaceKey+taskId) needs no re-addressing: its workspace is
      // already inside the window. A project (draft formB) leg is
      // deliberately not recorded either: replaying it would prepare a
      // FRESH draft workspace on every recovery, and the reply's drifted
      // workspaceKey is not followed by _reopenBridge.
      recoveryTaskId: taskHostId == null || taskId == null ? null : taskId,
      recoveryTaskHostId:
          taskHostId == null || taskId == null ? null : taskHostId,
      onDispose: (s) {
        _activeBridges.remove(s);
        _frameRouters.remove(s.bridge['bridgeSessionId']);
      },
      workspaceHookReviewUi: params.atLeast(3, 12, 3),
    );
    _attachStack(session, bridgeSessionId, bridge);
    _activeBridges.add(session);

    await sendMobileViewState(
      workspaceKey: (bridge['workspaceKey'] as String?) ?? workspaceKey,
      taskId: (bridge['initialTaskId'] as String?) ?? taskId,
    );
    return session;
  }

  /// Builds the rpc-frame transport + IPC channel stack for a bridge and
  /// attaches it to [session] (fresh or swapped-in after a reopen).
  void _attachStack(
    BridgeSession session,
    String requestedBridgeSessionId,
    Map<String, dynamic> bridge,
  ) {
    session._transport.dispose();
    // Server-side bridge rebuild: routing (bridgeSessionId) survives but
    // the new instance forgets our subscriptions/handshakes. Ride the same
    // `recovered` wave the relay-reconnect path uses — every listener that
    // re-establishes state (handshake reset, queue drain, resubscribe)
    // then runs without new plumbing.
    final transport = RpcFrameTransport(
      bridgeSessionId:
          (bridge['bridgeSessionId'] as String?) ?? requestedBridgeSessionId,
      bridgeGeneration: (bridge['bridgeGeneration'] as num?)?.toInt(),
      recoveryId: bridge['recoveryId'] as String?,
      sendPayload: relay.sendPayload,
      onServerBridgeRebuilt: () => session.recovered.value += 1,
      onLog: onLog,
    );
    // Over the workspace bridge each rpc-frame message IS one ChannelClient
    // body (value-stream) — no 13-byte IPC framing on this path.
    final channels = ChannelClient(
      sendBody: transport.sendMessage,
      onLog: onLog,
    );
    transport.messages.listen(channels.handleMessage);
    session._swap(bridge, transport, channels);

    // Register at the single dispatch point and flush any frames that
    // arrived before the transport existed (Initialize race).
    final id = transport.bridgeSessionId;
    final oldId = session._bridge['bridgeSessionId'];
    if (oldId != id) _frameRouters.remove(oldId);
    _frameRouters[id] = transport.acceptPayload;
    final pending = _pendingBridgePayloads.remove(id);
    if (pending != null) {
      for (final payload in pending) {
        transport.acceptPayload(payload);
      }
    }
  }

  /// Reopens a degraded/dead bridge: new `workspace-bridge-open` (fresh
  /// bridgeSessionId, bumped generation, carries recoveryId), then swaps
  /// the stack into the existing [BridgeSession].
  ///
  /// When the bridge was established through the task-host addressing leg,
  /// the reopen replays that pair: the desktop's bounded-window registry
  /// still misses the prepared workspace, so a bare workspaceKey would be
  /// refused by the window gate on every retry (live 3.16.3, 2026-10-27).
  /// Plain-workspaceKey bridges add no field — their frame stays
  /// byte-identical to the pre-addressing shape (R5).
  Future<void> _reopenBridge(BridgeSession session, String workspaceKey) async {
    final oldBridge = session.bridge;
    final bridgeSessionId = _reqId('bridge');
    final generation = ++_bridgeGeneration;
    final requestId = _reqId('workspace-bridge');
    _log('[bridge] reopen $workspaceKey (gen $generation)');
    final res = await request(
      {
        'zcode_type': 'workspace-bridge-open',
        'requestId': requestId,
        'bridgeSessionId': bridgeSessionId,
        'bridgeGeneration': generation,
        if (oldBridge['recoveryId'] != null)
          'recoveryId': oldBridge['recoveryId'],
        'workspaceKey': workspaceKey,
        if (session.recoveryTaskId != null) 'taskId': session.recoveryTaskId,
        if (session.recoveryTaskHostId != null)
          'taskHostId': session.recoveryTaskHostId,
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
    _attachStack(session, bridgeSessionId, bridge);
    _log('[bridge] reopened: $bridge');
  }

  /// mobile-view-state-update.
  Future<void> sendMobileViewState({
    required String workspaceKey,
    String? taskId,
  }) async {
    relay.sendPayload(mobileViewStatePayload(
      workspaceKey: workspaceKey,
      taskId: taskId,
      appVersion: params.appVersion,
    ));
  }

  /// mobile-diagnostic (G7): fire-and-forget telemetry for the session
  /// state machine. Delegates to [RelayClient.sendMobileDiagnostic] — the
  /// relay owns the connected/unpaired gate, so this is a no-op when the
  /// link is down. Never queued, never awaited, never surfaces an error.
  void sendMobileDiagnostic(String event, [Map<String, dynamic>? fields]) =>
      relay.sendMobileDiagnostic(event, fields);

  /// workspace-reconnect-request.
  Future<Map<String, dynamic>> reconnectWorkspace(String workspaceKey) async {
    final id = _reqId('workspace-reconnect');
    return request(
      {
        'zcode_type': 'workspace-reconnect-request',
        'requestId': id,
        'workspaceKey': workspaceKey,
      },
      (p) =>
          p['zcode_type'] == 'workspace-reconnect-response' &&
          p['requestId'] == id &&
          p['workspaceKey'] == workspaceKey,
    );
  }

  Future<void> dispose() async {
    relay.stateListenable.removeListener(_onRelayState);
    await _payloadSub?.cancel();
    for (final s in List<BridgeSession>.from(_activeBridges)) {
      s.dispose();
    }
    await relay.dispose();
    await _workspaceListUpdatedController.close();
    await _appErrorController.close();
  }
}

/// A relay-level `app-error`: the desktop/relay refused a request with a
/// well-known reason. Reasons come from the close-code family (`relayCloseReason`)
/// plus the timeout/unsupported family that never becomes a close.
class RemoteAppError implements Exception {
  final String reason;
  final String? message;
  const RemoteAppError(this.reason, [this.message]);

  @override
  String toString() => message == null ? reason : '$reason: $message';
}

class BridgeSession {
  Map<String, dynamic> _bridge;
  RpcFrameTransport _transport;
  ChannelClient _channels;
  final void Function(BridgeSession) _onDispose;
  bool _disposed = false;

  /// Desktop version gate (`params.atLeast(3, 12, 3)`, fixed at bridge
  /// creation): whether the V4 clientHello declares the workspace hook
  /// review UI capability.
  final bool workspaceHookReviewUi;

  /// Non-null while the bridge is degraded (rpc-transport-fault etc.).
  final ValueNotifier<String?> degraded = ValueNotifier(null);

  /// When the most recent degradation happened. Never cleared on recovery:
  /// the command timeout gate asks "did a degradation happen during this
  /// command's flight", and the desktop's ~45.3s pendulum recovers the
  /// bridge within 1-2s — by the time a 90s command times out the live
  /// [degraded] flag is always null again, so the timestamp is what catches
  /// the mid-flight loss.
  DateTime? lastDegradedAt;

  /// Marks the bridge degraded and stamps [lastDegradedAt]. The single
  /// entry point for every degraded transition (bridge-degraded push,
  /// relay reconnect, recovery attempts) so the stamp cannot drift from
  /// the flag.
  void markDegraded(String reason) {
    lastDegradedAt = DateTime.now();
    degraded.value = reason;
  }

  /// Bumped when the bridge recovers/reopens — subscriptions must
  /// resubscribe (server-side subscription state died with the old bridge).
  final ValueNotifier<int> recovered = ValueNotifier(0);

  /// Resolves once the bridge is healthy again (degraded cleared), or throws
  /// [TimeoutException]. Commands gate on this so a send during a
  /// reconnect/recovery window doesn't hang on a dead bridge.
  Future<void> waitHealthy({Duration timeout = const Duration(seconds: 45)}) {
    if (_disposed || degraded.value == null) return Future.value();
    final completer = Completer<void>();
    void check() {
      if (degraded.value == null && !completer.isCompleted) {
        completer.complete();
      }
    }

    degraded.addListener(check);
    check();
    return completer.future
        .timeout(
          timeout,
          onTimeout: () {
            degraded.removeListener(check);
            // Diagnostic text: generic error paths may surface it verbatim
            // (e.g. "operation failed: $e"), so it stays language-neutral
            // English instead of table copy.
            throw TimeoutException(
                'bridge recovery timed out: ${degraded.value}');
          },
        )
        .whenComplete(() => degraded.removeListener(check));
  }

  /// The `taskId`/`taskHostId` pair the desktop accepted when this bridge
  /// was opened through the 3.16.3+ window-gate task-host fallback leg.
  /// Null for first-leg bridges (workspaceKey alone or workspaceKey+taskId:
  /// the workspace was already in the bound window). [_reopenBridge] replays
  /// the pair so the desktop re-prepares the task's workspace after a
  /// transport fault; null keeps the reopen frame byte-identical.
  final String? recoveryTaskId;
  final String? recoveryTaskHostId;

  BridgeSession._({
    required Map<String, dynamic> bridge,
    required void Function(BridgeSession) onDispose,
    required this.workspaceHookReviewUi,
    this.recoveryTaskId,
    this.recoveryTaskHostId,
  }) : _bridge = bridge,
       _transport = _placeholderTransport(bridge),
       _channels = ChannelClient(sendBody: (_) {}),
       _onDispose = onDispose;

  static RpcFrameTransport _placeholderTransport(Map<String, dynamic> bridge) =>
      RpcFrameTransport(
        bridgeSessionId: '${bridge['bridgeSessionId'] ?? ''}',
        sendPayload: (_) {},
      );

  Map<String, dynamic> get bridge => _bridge;
  RpcFrameTransport get transport => _transport;
  ChannelClient get channels => _channels;

  void _swap(
    Map<String, dynamic> bridge,
    RpcFrameTransport transport,
    ChannelClient channels,
  ) {
    _bridge = bridge;
    _transport = transport;
    _channels = channels;
  }

  String? get workspaceKey => _bridge['workspaceKey'] as String?;
  String? get initialTaskId => _bridge['initialTaskId'] as String?;

  /// The web client performs the conversation handshake ONCE per service
  /// (cached via `wD`). The transport is keyed by scope and cleared on
  /// stack swap so the new bridge handshakes again.
  final Map<String, ConversationTransport> _conversations = {};

  ConversationTransport conversation(
    Map<String, dynamic> scope, {
    void Function(String line)? onLog,
    void Function(String channel, Object error)? onLinkLevelFailure,
    void Function(String channel)? onChannelSuccess,
    Future<String?> Function(String workspacePath)? projectIdFor,
  }) {
    final key = '${scope['workspaceIdentity'] ?? scope['workspacePath']}';
    return _conversations.putIfAbsent(
      key,
      () => ConversationTransport(
        session: this,
        scope: scope,
        onLog: onLog,
        workspaceHookReviewUi: workspaceHookReviewUi,
        onLinkLevelFailure: onLinkLevelFailure,
        onChannelSuccess: onChannelSuccess,
        projectIdFor: projectIdFor,
      ),
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    degraded.dispose();
    recovered.dispose();
    _transport.dispose();
    _onDispose(this);
  }
}
