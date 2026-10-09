// Newer style lints are suppressed so this file keeps its protocol
// handling readable as a single, self-contained unit.
// ignore_for_file: use_null_aware_elements, prefer_initializing_formals
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'channel_client.dart';
import 'conversation_state.dart';
import 'conversation_subscription.dart';
import 'id.dart';
import 'remote_client.dart';
import 'replayable_queue.dart';

// Bundle anchor: the official web bundle's ConversationTransport class —
// the V4 wire commands, hello/initialize handshake, attachment chunking,
// plus the native blocks kept distinguishable per ADR-0013 (sendTextOrQueue
// / SendTextResult, ack predicates, rowsRange response parsing). Split out
// of the former single-file conversation.dart; bundle diffs for these
// functions land here (see docs/adr/0013 appendix for the grep procedure).
class ConversationTransport {
  static const channel = Channels.zcodeAgent;

  final BridgeSession session;
  final Map<String, dynamic> scope;
  final String appVersion;

  /// Desktop version gate (>=3.12.3, `params.atLeast(3, 12, 3)` at the
  /// RemoteClient) that also decides whether clientHello carries a
  /// `capabilities` map at all. The strict hello schema of older desktops
  /// is untested against unknown fields, so pre-3.12.3 desktops receive no
  /// `capabilities` key (never `false` values). For 3.12.3+ the official
  /// schema actually accepts TWO keys —
  /// `{workspaceHookReviewUi, workflowRunDeltas}` (`e.object({…}).strict()
  /// .optional()`, renderer @270331886); the old note claiming "exactly one
  /// key" is obsolete. The same gate also decides replayable-queue
  /// availability ([replayableQueue]).
  final bool workspaceHookReviewUi;

  /// Sticky downgrade latch: a 3.12.3+ desktop that rejects the
  /// `workflowRunDeltas` capability ([handshake] retries the clientHello
  /// once without it) disables the key for the transport's lifetime —
  /// connections always win over the feature (never brick the link).
  bool _workflowRunDeltasDegraded = false;

  /// Whether the wire carries the `workflowRunDeltas` capability: true on
  /// desktops that accept clientHello capabilities (>=[workspaceHookReviewUi]
  /// gate) and not yet downgraded. Read by [ConversationSubscription] to
  /// decide the conversationSubscribe body key (official @270820092).
  bool get workflowRunDeltas =>
      workspaceHookReviewUi && !_workflowRunDeltasDegraded;

  final void Function(String line)? onLog;

  /// Link-failure ledger hooks for the send paths ([sendCommand] /
  /// [_replayableWireCall]), injected by the host so chat sends feed the
  /// same failure ledger its callChannel path uses. Null = report nothing
  /// (pre-ledger behavior). The transport only reports wire facts — a
  /// success, or a TimeoutException / channel-missing rejection — the
  /// failure-TIER classification (bridge gate expiry vs per-channel
  /// failure) stays on the receiving side; this layer never imports the
  /// ledger type.
  final void Function(String channel, Object error)? onLinkLevelFailure;
  final void Function(String channel)? onChannelSuccess;

  /// Subscribe-ack watchdog bound for the subscriptions this transport
  /// creates ([subscribe] / [subscribeSessionsIndex]): a subscribe call
  /// silent this long is abandoned and resubscribed. The desktop can park a
  /// subscribe in session hydration for minutes (2026-09-19 live evidence:
  /// 47s+ conversation acks vs <1s sessions-index) while the 60s channel
  /// timeout merely waits — the watchdog detects the stall earlier.
  /// Injectable so tests can shrink it (protocol tests are fake_async-free).
  final Duration subscribeAckTimeout;

  final String clientId = generateUuid();
  bool _handshaken = false;
  Future<void>? _handshakeFuture;

  /// From the server hello — required for attachment uploads.
  String? connectionId;

  ConversationTransport({
    required this.session,
    required this.scope,
    this.appVersion = '3.6.5',
    this.workspaceHookReviewUi = false,
    this.subscribeAckTimeout = const Duration(seconds: 10),
    this.onLog,
    this.onLinkLevelFailure,
    this.onChannelSuccess,
  }) {
    // A reopened bridge has no handshake state — start over (the cache is
    // per service instance).
    session.recovered.addListener(_onBridgeRecovered);
  }

  void _onBridgeRecovered() {
    _handshaken = false;
    _handshakeFuture = null;
    connectionId = null;
    _prep = null;
    // The rebuilt bridge re-negotiates capabilities from scratch: a downgrade
    // attributed to the dead bridge's desktop must not stick for the
    // transport's lifetime (the hello retry is one-shot, so re-arming the key
    // cannot loop).
    _workflowRunDeltasDegraded = false;
  }

  /// Internal: exposed for the subscription files split out of this
  /// library; not public API.
  ChannelClient get channels => session.channels;

  /// Internal: exposed for the subscription files split out of this
  /// library; not public API.
  void log(String line) => onLog?.call(line);

  Future<void> handshake() {
    if (_handshaken) return Future.value();
    return _handshakeFuture ??=
        () async {
          final hello = await channels.call(
            channel,
            'helloConversationV4',
            [],
          );
          log('[v4] hello: $hello');
          if (hello is Map) {
            connectionId = hello['connectionId'] as String?;
          }
          final clientHello = <String, dynamic>{
            'kind': 'clientHello',
            'protocolVersion': 3,
            'clientId': clientId,
            'clientKind': 'mobileApp',
            'appVersion': appVersion,
          };
          // 3.12.3+ strict schema: the capabilities map accepts
          // workspaceHookReviewUi + workflowRunDeltas (two keys). Pre-3.12.3
          // desktops get no capabilities key at all.
          Map<String, dynamic> capabilities() => {
            if (workspaceHookReviewUi) 'workspaceHookReviewUi': true,
            if (workflowRunDeltas) 'workflowRunDeltas': true,
          };
          var caps = capabilities();
          if (caps.isNotEmpty) clientHello['capabilities'] = caps;
          try {
            await channels.call(channel, 'initializeConversationV4', [
              clientHello,
            ]);
          } on ChannelRpcError catch (e) {
            // The desktop rejected the clientHello. When the
            // workflowRunDeltas capability was aboard, attribute the
            // rejection to it and retry ONCE without the key — the
            // connection is worth more than the feature (never brick the
            // link). Anything else propagates unchanged.
            if (!workflowRunDeltas) rethrow;
            _workflowRunDeltasDegraded = true;
            log('[v4] hello rejected (${e.message}); retrying without '
                'workflowRunDeltas');
            caps = capabilities();
            if (caps.isEmpty) {
              clientHello.remove('capabilities');
            } else {
              clientHello['capabilities'] = caps;
            }
            await channels.call(channel, 'initializeConversationV4', [
              clientHello,
            ]);
          }
          _handshaken = true;
        }().catchError((e) {
          _handshakeFuture = null;
          throw e;
        });
  }

  Future<ConversationSubscription> subscribe(String sessionId) async {
    await handshake();
    final subscription = ConversationSubscription(this, sessionId);
    await subscription.start();
    _subscriptions[sessionId] = subscription;
    return subscription;
  }

  /// Internal: exposed for the subscription files split out of this
  /// library; not public API.
  void untrackSubscription(String sessionId) {
    _subscriptions.remove(sessionId);
  }

  /// Commands that require `baseRevision` (CAS) plus row-target commands
  /// that also require `baseLogEpoch` (revision-guarded).
  /// All of them are compare-and-swap sends.
  static const _casCommands = {
    'applyFileRewind',
    'forkAssistant',
    'editUserQuery',
    'retryTurn',
    'setAssistantFeedback',
    'sendQueuedNow',
    'editQueueItem',
    'reorderQueueItem',
    'deleteQueueItem',
    'setAutoDrain',
    'switchModelConfig',
    'switchCollaborationMode',
    'setFollowupMode',
    'pauseGoal',
    'resumeGoal',
  };
  static const _rowTargetCommands = {
    'applyFileRewind',
    'forkAssistant',
    'editUserQuery',
    'retryTurn',
    'setAssistantFeedback',
  };

  /// Live subscriptions by sessionId — source of the current
  /// revision/logEpoch for CAS commands.
  final _subscriptions = <String, ConversationSubscription>{};

  /// Highest revision seen from command acks (`revisionAtDecision`) —
  /// acks land before the follow-up `state.updated` frame, and the next
  /// CAS command must not go stale.
  final _ackedRevisions = <String, int>{};

  Future<dynamic> sendCommand(
    String? sessionId,
    String type,
    Map<String, dynamic> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    // The ledger hooks bracket the whole path (handshake + health gate +
    // wire call): a TimeoutException or channel-missing rejection anywhere
    // on it is a link fact for the host's failure ledger (ADR-0009), while
    // deterministic RPC errors are normal answers and report nothing.
    try {
      await handshake();
      // Gate on a healthy bridge: during a relay drop/recovery the old bridge
      // is dead and requests would otherwise hang until timeout. Once the
      // bridge recovers, the send goes through on the fresh transport.
      await session.waitHealthy(timeout: const Duration(seconds: 45));
      final sub = sessionId == null ? null : _subscriptions[sessionId];
      final baseRevision = sessionId == null
          ? null
          : [
              sub?.state.revision ?? 0,
              _ackedRevisions[sessionId] ?? 0,
            ].reduce((a, b) => a > b ? a : b);
      final envelope = {
        'commandId': generateUuid(),
        'clientId': clientId,
        'sessionId': sessionId,
        if (_casCommands.contains(type)) 'baseRevision': baseRevision,
        if (_rowTargetCommands.contains(type) && sub?.state.logEpoch != null)
          'baseLogEpoch': sub!.state.logEpoch,
        'type': type,
        'payload': payload,
        'issuedAt': DateTime.now().millisecondsSinceEpoch,
      };
      log('[v4] command $type');
      var res = await _sendCommandWithRetry(envelope, timeout);
      // Runtime events (turn completion etc.) also bump the revision, so a
      // CAS base can go stale even with ack tracking. The stale ack tells
      // the server's current revision — retry once with it (stale-revision
      // retry).
      if (sessionId != null &&
          res is Map &&
          res['status'] == 'stale' &&
          res['revisionAtDecision'] is num) {
        final serverRevision = (res['revisionAtDecision'] as num).toInt();
        log('[v4] command $type stale, retry at rev $serverRevision');
        if (serverRevision > (_ackedRevisions[sessionId] ?? 0)) {
          _ackedRevisions[sessionId] = serverRevision;
        }
        final retryEnvelope = {
          ...envelope,
          'commandId': generateUuid(),
          'baseRevision': serverRevision,
          'issuedAt': DateTime.now().millisecondsSinceEpoch,
        };
        res = await _sendCommandWithRetry(retryEnvelope, timeout);
      }
      if (sessionId != null &&
          res is Map &&
          res['revisionAtDecision'] is num) {
        final rev = (res['revisionAtDecision'] as num).toInt();
        final status = res['status'];
        // revisionAtDecision is the base at decision time; an accepted
        // command bumps the revision by one, so the next CAS base is +1.
      final floor =
          (status == 'accepted' || status == 'noop' || status == 'duplicate')
          ? rev + 1
          : rev;
        if (floor > (_ackedRevisions[sessionId] ?? 0)) {
          _ackedRevisions[sessionId] = floor;
        }
      }
      // The wire answered the command — proof enough of a live channel for
      // the ledger (a rejected ack is still a healthy link).
      onChannelSuccess?.call(channel);
      return res;
    } catch (e) {
      if (e is TimeoutException || isChannelMissingError(e)) {
        onLinkLevelFailure?.call(channel, e);
      }
      rethrow;
    }
  }

  /// Session-creating commands (no sessionId of their own yet): the
  /// desktop dedupes them by commandId (`retryAck` answers `duplicate`
  /// carrying the original result), so a timed-out send can safely replay
  /// with the SAME commandId. Everything else (sendText...) is not
  /// idempotent — those keep the fresh-commandId conservative retry.
  static const _idempotentCommands = {
    'createSession',
    'createSelectionSideSession',
  };

  /// Sends one command envelope; on timeout (likely a relay drop
  /// mid-flight) waits for bridge recovery and retries. Session-creating
  /// commands replay with their original commandId (server-side dedupe),
  /// everything else with a fresh one.
  Future<dynamic> _sendCommandWithRetry(
    Map<String, dynamic> envelope,
    Duration timeout,
  ) async {
    final sendStart = DateTime.now();
    try {
      return await channels.call(channel, 'sendConversationCommandV4', [
        {...scope, 'envelope': envelope},
      ], timeout: timeout);
    } on TimeoutException {
      // Retry only when a relay drop plausibly ate the response: the bridge
      // is degraded right now, OR it degraded during this command's flight
      // and already recovered. The second case is the desktop's ~45.3s
      // pendulum: the response dies with the old bridge while the degraded
      // flag clears within 1-2s, so by the time a 90s command times out the
      // flag is always null — the timestamp is what catches it. If the
      // bridge stayed healthy the whole flight, rethrow (a retry would
      // double-deliver, e.g. sendText).
      final degradedAt = session.lastDegradedAt;
      final degradedInFlight = session.degraded.value != null ||
          (degradedAt != null && !degradedAt.isBefore(sendStart));
      if (!degradedInFlight) rethrow;
      log(
        '[v4] command timed out during drop, waiting for recovery and '
        'retrying',
      );
      await session.waitHealthy(timeout: const Duration(seconds: 45));
      final fresh = _idempotentCommands.contains('${envelope['type']}')
          ? envelope
          : {
              ...envelope,
              'commandId': generateUuid(),
              'issuedAt': DateTime.now().millisecondsSinceEpoch,
            };
      return channels.call(channel, 'sendConversationCommandV4', [
        {...scope, 'envelope': fresh},
      ], timeout: timeout);
    }
  }

  /// Creates a new session (the composer's first-send path):
  /// command `createSession` with `{workspaceId, firstInput:{text}}` and a
  /// null envelope sessionId. Returns the new sessionId on `accepted` —
  /// or on `duplicate`, the retryAck replay of a command that reached the
  /// server but lost its response (same commandId retry), which carries
  /// the original result.
  Future<String> createSession(
    String workspaceId, {
    String? firstText,
    List<Map<String, dynamic>>? attachments,
    Map<String, dynamic>? config,
    String? runtimeModel,
    List<String>? mcpServers,
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final res = await sendCommand(null, 'createSession', {
      'workspaceId': workspaceId,
      if (firstText != null)
        'firstInput': {
          'text': firstText,
          if (attachments != null && attachments.isNotEmpty)
            'attachments': attachments,
        },
      if (config != null) 'config': config,
      if (runtimeModel != null) 'runtimeModel': runtimeModel,
      if (mcpServers != null && mcpServers.isNotEmpty) 'mcpServers': mcpServers,
    }, timeout: timeout);
    final map = res is Map ? res.cast<String, dynamic>() : null;
    final status = map?['status'];
    if (status != 'accepted' && status != 'duplicate') {
      throw StateError(
        'createSession rejected: ${map?['reasonCode'] ?? status} ${map?['message'] ?? ''}',
      );
    }
    final result = map?['result'];
    final sessionId = result is Map ? result['sessionId'] : null;
    if (sessionId is! String || sessionId.isEmpty) {
      throw StateError('createSession: missing sessionId in result');
    }
    return sessionId;
  }

  /// Creates a selection-side (auxiliary) chat attached to [parentSessionId]
  /// (command `createSelectionSideSession` — "ask in side chat"). Returns the
  /// new sessionId.
  ///
  /// The payload schema is `{firstInput?: {text, modelSelection?}}` (one
  /// optional direct-ask input — runtime @1440615 neighbouring schema; the
  /// side chat's selection history is derived server-side from the current
  /// turn, never sent). [firstText] null/blank omits `firstInput` entirely
  /// (the official "create empty, wait for the user" shape); a non-blank
  /// [firstText] sends it, optionally with [modelSelection]. The schema's
  /// `text` is `trim().min(1)`, so a blank text is never sent as a payload.
  Future<String> createSelectionSideSession(
    String parentSessionId, {
    String? firstText,
    Map<String, dynamic>? modelSelection,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final text = firstText?.trim();
    final res = await sendCommand(
      parentSessionId,
      'createSelectionSideSession',
      {
        if (text != null && text.isNotEmpty)
          'firstInput': {
            'text': text,
            if (modelSelection != null) 'modelSelection': modelSelection,
          },
      },
      timeout: timeout,
    );
    final map = res is Map ? res.cast<String, dynamic>() : null;
    final status = map?['status'];
    if (status != 'accepted' && status != 'duplicate') {
      throw StateError(
        'createSelectionSideSession rejected: ${map?['reasonCode'] ?? status} ${map?['message'] ?? ''}',
      );
    }
    final result = map?['result'];
    final sessionId = result is Map ? result['sessionId'] : null;
    if (sessionId is! String || sessionId.isEmpty) {
      throw StateError(
        'createSelectionSideSession: missing sessionId in result',
      );
    }
    return sessionId;
  }

  Future<dynamic> sendText(
    String sessionId,
    String text, {
    List<Map<String, dynamic>>? attachments,
    String? heldQueueDisposition,
    List<String>? expectedHeldQueueItemIds,
    String? automationId,
    String? offPeakTaskId,
    String? offPeakRunType,
    String? botDeliveryTarget,
    List<String>? toolDisallowlist,
  }) => sendCommand(sessionId, 'sendText', {
    'text': text,
    if (attachments != null && attachments.isNotEmpty)
      'attachments': attachments,
    if (heldQueueDisposition != null)
      'heldQueueDisposition': heldQueueDisposition,
    if (expectedHeldQueueItemIds != null && expectedHeldQueueItemIds.isNotEmpty)
      'expectedHeldQueueItemIds': expectedHeldQueueItemIds,
    if (automationId != null) 'automationId': automationId,
    if (offPeakTaskId != null) 'offPeakTaskId': offPeakTaskId,
    if (offPeakRunType != null) 'offPeakRunType': offPeakRunType,
    if (botDeliveryTarget != null) 'botDeliveryTarget': botDeliveryTarget,
    if (toolDisallowlist != null && toolDisallowlist.isNotEmpty)
      'toolDisallowlist': toolDisallowlist,
  });

  Future<dynamic> sendGoalCommand(
    String sessionId,
    String text, {
    String? displayText,
    String? heldQueueDisposition,
    List<String>? expectedHeldQueueItemIds,
  }) => sendCommand(sessionId, 'sendGoalCommand', {
    'text': text,
    if (displayText != null) 'displayText': displayText,
    if (heldQueueDisposition != null)
      'heldQueueDisposition': heldQueueDisposition,
    if (expectedHeldQueueItemIds != null && expectedHeldQueueItemIds.isNotEmpty)
      'expectedHeldQueueItemIds': expectedHeldQueueItemIds,
  });

  Future<dynamic> pauseGoal(String sessionId) =>
      sendCommand(sessionId, 'pauseGoal', {});

  Future<dynamic> resumeGoal(String sessionId) =>
      sendCommand(sessionId, 'resumeGoal', {});

  Future<dynamic> stop(String sessionId) => sendCommand(sessionId, 'stop', {});

  Future<dynamic> compact(String sessionId) =>
      sendCommand(sessionId, 'compact', {});

  /// Switch model config. All of provider/model/thought are required by the
  /// protocol schema — pass current values for the ones not changing.
  /// Thought levels differ per model family (GLM-5.2: max/high/nothink;
  /// Turbo: enabled/off), so on `Unsupported reasoning effort` we retry
  /// with the other family's default.
  Future<dynamic> switchModelConfig(
    String sessionId, {
    required String provider,
    required String model,
    required String thought,
  }) async {
    var res = await sendCommand(sessionId, 'switchModelConfig', {
      'provider': provider,
      'model': model,
      'thought': thought,
    });
    final message = res is Map ? '${res['message'] ?? ''}' : '';
    if (message.contains('Unsupported reasoning effort')) {
      final fallback = (thought == 'enabled' || thought == 'off')
          ? 'max'
          : 'enabled';
      log('[v4] switchModelConfig retry with thought=$fallback');
      res = await sendCommand(sessionId, 'switchModelConfig', {
        'provider': provider,
        'model': model,
        'thought': fallback,
      });
    }
    return res;
  }

  /// build / edit / plan / yolo.
  Future<dynamic> switchCollaborationMode(String sessionId, String mode) =>
      sendCommand(sessionId, 'switchCollaborationMode', {'mode': mode});

  /// queue / guide followup.
  Future<dynamic> setFollowupMode(String sessionId, String mode) =>
      sendCommand(sessionId, 'setFollowupMode', {'mode': mode});

  /// like / dislike / null on an assistant row. Target is
  /// `{rowId, entityId}` (entityId optional for some row kinds).
  Future<dynamic> setAssistantFeedback(
    String sessionId,
    Map<String, dynamic> target,
    String? feedback,
  ) => sendCommand(sessionId, 'setAssistantFeedback', {
    'target': target,
    'feedback': feedback,
  });

  Future<dynamic> retryTurn(String sessionId, Map<String, dynamic> target) =>
      sendCommand(sessionId, 'retryTurn', {'target': target});

  Future<dynamic> sendQueuedNow(String sessionId, String queueItemId) =>
      sendCommand(sessionId, 'sendQueuedNow', {'queueItemId': queueItemId});

  Future<dynamic> editQueueItem(
    String sessionId,
    String queueItemId,
    String newText,
  ) => sendCommand(sessionId, 'editQueueItem', {
    'queueItemId': queueItemId,
    'newText': newText,
  });

  Future<dynamic> deleteQueueItem(String sessionId, String queueItemId) =>
      sendCommand(sessionId, 'deleteQueueItem', {'queueItemId': queueItemId});

  Future<dynamic> setAutoDrain(String sessionId, bool autoDrain) =>
      sendCommand(sessionId, 'setAutoDrain', {'autoDrain': autoDrain});

  /// Moves [queueItemId] directly before [beforeQueueItemId] in the held
  /// queue (`null` = move to the end). CAS command per the web schema.
  Future<dynamic> reorderQueueItem(
    String sessionId,
    String queueItemId,
    String? beforeQueueItemId,
  ) => sendCommand(sessionId, 'reorderQueueItem', {
    'queueItemId': queueItemId,
    'beforeQueueItemId': beforeQueueItemId,
  });

  /// Defers the interaction auto-resolution timer (desktop setting
  /// 「提问自动继续」≈ 5 minutes). No CAS fields in the web schema.
  Future<dynamic> snoozeInteractionAutoResolution(
          String sessionId, String interactionId) =>
      sendCommand(sessionId, 'snoozeInteractionAutoResolution', {
        'interactionId': interactionId,
      });

  /// Cancels a background work item (terminal / subagent banner ✕).
  Future<dynamic> cancelBackgroundWork(String sessionId, String workId) =>
      sendCommand(sessionId, 'cancelBackgroundWork', {'workId': workId});

  /// Deletes the whole session (chat「更多」menu, confirm first).
  Future<dynamic> deleteSession(String sessionId) =>
      sendCommand(sessionId, 'deleteSession', {});

  /// Renames the session via the envelope (zcode-task.renameTask is the
  /// task-list twin of the same operation).
  Future<dynamic> renameSession(String sessionId, String title) =>
      sendCommand(sessionId, 'renameSession', {'title': title});

  /// sendText delivery semantics: 'startNow' | 'queue' | 'guide' (web
  /// composer ⌘+Enter behavior, driven by zcodeInteractionBehavior).
  Future<dynamic> sendTextWithDelivery(
    String sessionId,
    String text, {
    required String requestedDelivery,
    String? heldQueueDisposition,
    List<String>? expectedHeldQueueItemIds,
  }) => sendCommand(sessionId, 'sendText', {
    'text': text,
    'requestedDelivery': requestedDelivery,
    if (heldQueueDisposition != null)
      'heldQueueDisposition': heldQueueDisposition,
    if (expectedHeldQueueItemIds != null &&
        expectedHeldQueueItemIds.isNotEmpty)
      'expectedHeldQueueItemIds': expectedHeldQueueItemIds,
  });

  Future<dynamic> forkAssistant(
    String sessionId,
    Map<String, dynamic> target,
  ) => sendCommand(sessionId, 'forkAssistant', {'target': target});

  /// `workspaceMode` is the 3.14+ edit-rewind switch (F1: wire enum
  /// `["preserve","rewind"]`, desktop执行侧 `workspaceMode ?? "preserve"`):
  /// **preserve is the wire default — omit the field** so old desktops see
  /// the exact legacy payload; only 'rewind' goes on the wire.
  Future<dynamic> editUserQuery(
    String sessionId,
    Map<String, dynamic> target,
    String newText, {
    String? workspaceMode,
  }) => sendCommand(sessionId, 'editUserQuery', {
    'target': target,
    'newText': newText,
    if (workspaceMode != null && workspaceMode != 'preserve')
      'workspaceMode': workspaceMode,
  });

  Future<dynamic> applyFileRewind(
    String sessionId,
    Map<String, dynamic> target,
  ) => sendCommand(sessionId, 'applyFileRewind', {'target': target});

  Future<dynamic> plans(String sessionId) async {
    await handshake();
    return channels.call(channel, 'conversationPlansV4', [
      {...scope, 'sessionId': sessionId},
    ]);
  }

  Future<dynamic> fileChanges(
    String sessionId, {
    required Map<String, dynamic> target,
    int? baseRevision,
    String? baseLogEpoch,
  }) async {
    await handshake();
    return channels.call(channel, 'conversationFileChangesV4', [
      {
        ...scope,
        'sessionId': sessionId,
        'target': target,
        if (baseRevision != null) 'baseRevision': baseRevision,
        if (baseLogEpoch != null) 'baseLogEpoch': baseLogEpoch,
      },
    ]);
  }

  Future<dynamic> fileRewindPreview(
    String sessionId, {
    required Map<String, dynamic> target,
    int? baseRevision,
    String? baseLogEpoch,
  }) async {
    await handshake();
    return channels.call(channel, 'conversationFileRewindPreviewV4', [
      {
        ...scope,
        'sessionId': sessionId,
        'target': target,
        if (baseRevision != null) 'baseRevision': baseRevision,
        if (baseLogEpoch != null) 'baseLogEpoch': baseLogEpoch,
      },
    ]);
  }

  // ------------------------------------------------------------ attachments

  static const _attachmentChunkBytes = 384 * 1024;

  /// Uploads an attachment (begin/chunk/commit).
  /// Returns the attachment descriptor `{ref, fileName, mime, bytes}` to be
  /// passed to sendText/createSession.
  Future<Map<String, dynamic>> attachmentPut(
    String sessionId, {
    required String fileName,
    required String mime,
    required Uint8List bytes,
    void Function(double progress)? onProgress,
  }) async {
    await handshake();
    final connId = connectionId;
    if (connId == null) {
      throw StateError('attachmentPut: missing connectionId');
    }
    final uploadId = 'upload-${generateUuid()}';
    final base = {
      'connectionId': connId,
      'uploadId': uploadId,
      'sessionId': sessionId,
    };
    final totalChunks =
        (bytes.length + _attachmentChunkBytes - 1) ~/ _attachmentChunkBytes;
    final checksum = 'sha256:${sha256.convert(bytes).toString()}';

    final beginRes = await channels.call(channel, 'attachmentBeginV4', [
      {
        ...scope,
        ...base,
        'fileName': fileName,
        'mime': mime,
        'totalBytes': bytes.length,
        'totalChunks': totalChunks,
        'checksum': checksum,
      },
    ]);
    if (beginRes is Map && beginRes['state'] == 'committed') {
      onProgress?.call(1);
      return {
        'ref': beginRes['ref'],
        'fileName': fileName,
        'mime': mime,
        'bytes': bytes.length,
      };
    }
    var nextChunk = beginRes is Map
        ? (beginRes['nextChunkIndex'] as num?)?.toInt() ?? 0
        : 0;
    for (var n = nextChunk; n < totalChunks; n++) {
      final start = n * _attachmentChunkBytes;
      final end = start + _attachmentChunkBytes > bytes.length
          ? bytes.length
          : start + _attachmentChunkBytes;
      final chunkRes = await channels.call(channel, 'attachmentChunkV4', [
        {
          ...scope,
          ...base,
          'chunkIndex': n,
          'dataBase64': base64.encode(Uint8List.sublistView(bytes, start, end)),
        },
      ]);
      nextChunk = chunkRes is Map
          ? (chunkRes['nextChunkIndex'] as num?)?.toInt() ?? n + 1
          : n + 1;
      if (nextChunk != n + 1) {
        throw StateError('fault.attachment.invalidServerProgress');
      }
      onProgress?.call(nextChunk / totalChunks);
    }
    onProgress?.call(1);
    final commitRes = await channels.call(channel, 'attachmentCommitV4', [
      {...scope, ...base},
    ]);
    final ref = commitRes is Map ? commitRes['ref'] : null;
    return {
      'ref': ref,
      'fileName': fileName,
      'mime': mime,
      'bytes': bytes.length,
    };
  }

  /// Reads an attachment (for previews). Returns `{bytes, mediaType}`.
  Future<({Uint8List bytes, String? mediaType})> attachmentRead(
    String sessionId, {
    required String ref,
  }) async {
    await handshake();
    final chunks = <int>[];
    var offset = 0;
    String? mediaType;
    for (var round = 0; round < 1024; round++) {
      final res = await channels.call(channel, 'attachmentReadV4', [
        {
          ...scope,
          'sessionId': sessionId,
          'ref': ref,
          'offset': offset,
          'limit': _attachmentChunkBytes,
        },
      ]);
      if (res is! Map) break;
      mediaType ??= res['mediaType'] as String?;
      final data = res['dataBase64'] as String?;
      if (data != null && data.isNotEmpty) {
        chunks.addAll(base64.decode(data));
      }
      final next = (res['nextOffset'] as num?)?.toInt();
      final total = (res['totalBytes'] as num?)?.toInt();
      if (next == null || next <= offset) break;
      offset = next;
      if (total != null && offset >= total) break;
    }
    return (bytes: Uint8List.fromList(chunks), mediaType: mediaType);
  }

  Future<dynamic> resolveInteraction(
    String sessionId,
    String interactionId, {
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  }) => sendCommand(sessionId, 'resolveInteraction', {
    'interactionId': interactionId,
    'answer': {
      if (optionId != null) 'optionId': optionId,
      if (freeText != null) 'freeText': freeText,
      if (action != null) 'action': action,
      if (content != null) 'content': content,
    },
  });

  /// Answers the `workspaceHookReview` interaction (3.12.3 workspace
  /// hooks). [frame] is the interaction payload — identity fields are
  /// passed back verbatim into the strict payload; [reviewItemIds] carries
  /// the checked hooks. The decision schema has exactly one action
  /// (`trust_selected`, >=1 deduped ids); declining means not answering
  /// and letting the interaction time out server-side.
  Future<dynamic> respondWorkspaceHookReview(
    String sessionId,
    Map<String, dynamic> frame,
    List<String> reviewItemIds,
  ) => sendCommand(sessionId, 'respondWorkspaceHookReview', {
    'sessionId': '${frame['sessionId'] ?? sessionId}',
    'taskId': '${frame['taskId'] ?? ''}',
    'runId': '${frame['runId'] ?? ''}',
    if (frame['remoteSessionId'] is String &&
        (frame['remoteSessionId'] as String).isNotEmpty)
      'remoteSessionId': frame['remoteSessionId'],
    'workspaceIdentity': '${frame['workspaceIdentity'] ?? ''}',
    'bundleDigest': '${frame['bundleDigest'] ?? ''}',
    'reviewFlowId': '${frame['reviewFlowId'] ?? ''}',
    'generation': (frame['generation'] as num?)?.toInt() ?? 0,
    'interactionId': '${frame['interactionId'] ?? ''}',
    'decision': {
      'action': 'trust_selected',
      'reviewItemIds': reviewItemIds.toSet().toList(),
    },
  });

  Future<dynamic> rowsRange(
    String sessionId, {
    int? beforeRowId,
    int limit = 60,
  }) async {
    await handshake();
    return channels.call(channel, 'conversationRowsRangeV4', [
      {
        ...scope,
        'sessionId': sessionId,
        if (beforeRowId != null) 'beforeRowId': beforeRowId,
        'limit': limit,
      },
    ]);
  }

  // ------------------------------------------------------ sessions-index

  /// Subscribes the sessions-index of this workspace
  /// (`subscribeSessionsIndexV4` + `onDynamicSessionsIndexFrame`).
  /// Provides the live session list with title/phase/lastAssistantPreview.
  Future<SessionsIndexSubscription> subscribeSessionsIndex() async {
    await handshake();
    final subscription = SessionsIndexSubscription(this);
    await subscription.start();
    return subscription;
  }

  // ----------------------------------------------- workspace presentation

  WorkspacePrep? _prep;

  /// `zcode-task.prepareWorkspace` — returns configOptions (model/mode/
  /// thought selects) and slashCommands (builtin + custom skills/MCP).
  Future<WorkspacePrep> prepareWorkspace({bool refresh = false}) async {
    final cached = _prep;
    if (cached != null && !refresh) return cached;
    final res = await channels.call(Channels.zcodeTask, 'prepareWorkspace', [
      scope,
    ]);
    final prep = WorkspacePrep(res is Map ? res : const {});
    _prep = prep;
    return prep;
  }

  /// `zcode-agent.readWorkspacePresentation` — the 3.12.3+ slash-command
  /// source (builtin + custom).
  /// One-shot RPC, no subscription lifecycle. Null on non-Map answer or
  /// channel rejection — a presentation miss must not fail the caller
  /// (slashCommands stay empty instead).
  Future<Map<String, dynamic>?> readWorkspacePresentation() async {
    try {
      final res = await channels.call(
        channel,
        'readWorkspacePresentation',
        [scope],
      );
      return res is Map ? Map<String, dynamic>.from(res) : null;
    } catch (_) {
      return null;
    }
  }

  /// `skills.list` — enabled skills of this workspace.
  /// Skills are invoked in the composer as
  /// `$name`. Returns an empty list when the channel rejects or returns no
  /// skill data.
  /// Last successful skills.list result (mention picker reads this
  /// synchronously without a fresh RPC).
  List<SkillEntry> lastSkills = const [];

  Future<List<SkillEntry>> skills() async {
    final res = await channels.call(Channels.skills, 'list', [
      {
        'workspacePath': scope['workspacePath'],
        if (scope['workspaceIdentity'] != null)
          'workspaceIdentity': scope['workspaceIdentity'],
        'provider': 'glm',
      },
    ], timeout: const Duration(seconds: 20));
    final raw = res is List ? res : (res is Map ? res['skills'] : null);
    if (raw is! List) return const [];
    return lastSkills = [
      for (final item in raw.whereType<Map>())
        SkillEntry(item.cast<String, dynamic>()),
    ].where((s) => s.name.isNotEmpty).toList();
  }

  ReplayableCommandQueue? _replayableQueue;

  /// Offline replayable-command queue (`zcode-task.enqueueTaskCommand`
  /// family, desktop 3.12.3). Lazily created on first access — the send
  /// path ([sendTextOrQueue]) and the chat queue bar touch it only on the
  /// send-failure path. Null on pre-3.12.3 desktops: the gate rides
  /// [workspaceHookReviewUi], the same `params.atLeast(3, 12, 3)` version
  /// flag the RemoteClient stamps on the bridge (DeviceSession re-checks
  /// it live for its ChatGateway getter) — older desktops never queue,
  /// zero behavior change (ADR-0010).
  ReplayableCommandQueue? get replayableQueue => workspaceHookReviewUi
      ? (_replayableQueue ??= ReplayableCommandQueue(
          call: _replayableWireCall,
          scope: scope,
          clientId: clientId,
          recovered: session.recovered,
          onLog: log,
        ))
      : null;

  /// Wire binding for [replayableQueue]: the zcode-task channel, gated on
  /// the same handshake + bridge-health as [sendCommand] so a drain during
  /// a reconnect window waits for recovery instead of hanging on a dead
  /// bridge. Reports the same link facts to the host's ledger hooks as
  /// [sendCommand] does for the zcode-agent channel.
  Future<dynamic> _replayableWireCall(
    String method,
    List<Object?> args,
  ) async {
    try {
      await handshake();
      await session.waitHealthy(timeout: const Duration(seconds: 45));
      final res = await channels.call(Channels.zcodeTask, method, args);
      onChannelSuccess?.call(Channels.zcodeTask);
      return res;
    } catch (e) {
      if (e is TimeoutException || isChannelMissingError(e)) {
        onLinkLevelFailure?.call(Channels.zcodeTask, e);
      }
      rethrow;
    }
  }

  // ---------------------------------------- send + replayable queue (native)
  //
  // Native addition, NOT line-by-line ported code — keep this block
  // distinguishable from the ported body above (ADR-0013). ADR-0010: the
  // queueable-failure decision lives in [sendTextOrQueue] and only there;
  // UI layers must not inline channel-error enqueue judgments.

  /// Sends one `sendText` and classifies the outcome as a sealed
  /// [SendTextResult] — the chat composer's plain-send path.
  ///
  /// Design B boundary (ADR-0010): only THIS call is queueable.
  /// createSession / slash / goal / attachment-upload paths surface their
  /// errors themselves and never queue.
  ///
  /// A thrown error parks the message in [replayableQueue] (returns
  /// [SendTextQueued] after [ReplayableCommandQueue.queueLocal]) exactly
  /// when ALL of these hold:
  /// - the error came from the [sendText] call itself — this method's body
  ///   is that call's scope, replacing the former UI `sendTextInFlight`
  ///   flag;
  /// - [replayableQueue] != null (the 3.12.3 version gate — null on older
  ///   desktops, which then never queue);
  /// - [text] is non-empty;
  /// - [attachments] is null/empty (the enqueue schema is text-only);
  /// - `isChannelLevelError(e)` holds.
  /// Any other thrown error surfaces as [SendTextFailed] carrying the
  /// original error; a wire-shaped ack rejection becomes
  /// [SendTextRejected] via [ackRejected] / [ackReason].
  Future<SendTextResult> sendTextOrQueue(
    String sessionId,
    String text, {
    List<Map<String, dynamic>>? attachments,
    String? heldQueueDisposition,
  }) async {
    dynamic res;
    try {
      res = await sendText(
        sessionId,
        text,
        attachments: attachments,
        heldQueueDisposition: heldQueueDisposition,
      );
    } catch (e) {
      final queue = replayableQueue;
      if (queue != null &&
          text.isNotEmpty &&
          (attachments == null || attachments.isEmpty) &&
          isChannelLevelError(e)) {
        return SendTextResult.queued(
          queue.queueLocal(taskId: sessionId, content: text),
        );
      }
      return SendTextResult.failed(e);
    }
    if (ackRejected(res)) return SendTextResult.rejected(ackReason(res));
    return SendTextResult.sent(res);
  }
}


/// Outcome of [ConversationTransport.sendTextOrQueue], switched over by the
/// chat composer — one variant per former `_send` handling branch, so the
/// UI maps them 1:1. Native addition, distinct from the line-by-line ported
/// body of this file (ADR-0013); the queueable-failure decision behind
/// [SendTextQueued] is single-sourced in sendTextOrQueue (ADR-0010).
sealed class SendTextResult {
  const SendTextResult._();

  /// ack passed (`accepted` / `noop` / `duplicate`); [res] is the raw
  /// command ack.
  const factory SendTextResult.sent(dynamic res) = SendTextSent;

  /// Wire-shaped ack rejection ([ackRejected]); [reason] is the [ackReason]
  /// extraction for the toast.
  const factory SendTextResult.rejected(String reason) = SendTextRejected;

  /// Channel-level sendText failure parked in the replayable queue;
  /// [item] is already enqueued ([ReplayableCommandQueue.queueLocal]).
  const factory SendTextResult.queued(ReplayableQueueItem item) =
      SendTextQueued;

  /// Not queueable — non-channel error, attachments present, empty text,
  /// or null queue on pre-3.12.3 desktops. [error] is the original failure
  /// for the toast.
  const factory SendTextResult.failed(Object error) = SendTextFailed;
}

class SendTextSent extends SendTextResult {
  final dynamic res;
  const SendTextSent(this.res) : super._();
}

class SendTextRejected extends SendTextResult {
  final String reason;
  const SendTextRejected(this.reason) : super._();
}

class SendTextQueued extends SendTextResult {
  final ReplayableQueueItem item;
  const SendTextQueued(this.item) : super._();
}

class SendTextFailed extends SendTextResult {
  final Object error;
  const SendTextFailed(this.error) : super._();
}

/// Wire-shaped command-ack rejection: a `status` that is present and none
/// of the pass values. Moved verbatim from the former chat-page
/// `_ackRejected` (behavior frozen; the /goal path shares it).
bool ackRejected(dynamic res) =>
    res is Map &&
    res['status'] != null &&
    res['status'] != 'accepted' &&
    res['status'] != 'noop' &&
    res['status'] != 'duplicate';

/// Human-readable reason of a command ack: `reasonCode` → `message` →
/// `status`; non-Map answers stringify verbatim. Former chat-page
/// `_ackReason`, moved with [ackRejected].
String ackReason(dynamic res) {
  if (res is! Map) return '$res';
  return '${res['reasonCode'] ?? res['message'] ?? res['status']}';
}

/// New-session id carried by a `forkAssistant` command ack — null on any
/// other shape. Native helper (ADR-0013): the desktop's command ack union
/// is `{status, result:{type, sessionId}}` and both `accepted` and
/// `duplicate` carry the result (`duplicate` = the commandId dedupe
/// replaying the original result, same as createSession) — evidence: asar
/// command ack union + fork bundle ack part, task research.md R1.
/// Defensive by design: the ack is dynamic wire data, nothing is cast.
String? forkSessionIdOf(dynamic ack) {
  if (ack is! Map) return null;
  final status = ack['status'];
  if (status != 'accepted' && status != 'duplicate') return null;
  final result = ack['result'];
  if (result is! Map || result['type'] != 'forkAssistant') return null;
  final sessionId = result['sessionId'];
  if (sessionId is! String || sessionId.isEmpty) return null;
  return sessionId;
}

// ---------------------------------------- rowsRange paging (native)
//
// Native addition, NOT line-by-line ported code — keep this block
// distinguishable from the ported body below (ADR-0013). Single home for
// the conversationRowsRangeV4 response fallback chain that used to live
// as three private copies (chat `_loadOlderSettled` / subagent-sheet
// `_loadEarlier` / subagent-detail `_loadOlder`). Pure parsing only:
// each caller runs its own identity guard (state replaced by a
// resubscribe → drop the page silently) and applies epoch-drifted pages
// anyway behind a `chat.loadOlder.stale` toast (round 23 generalized
// 2026-10-07), plus its own cursor decisions.

/// Parsed [parseRowsRangeResponse] outcome. `rows` is already cast to
/// `Map<String, dynamic>` (non-Map elements dropped); null means the
/// response carried no recognizable row list. `epochMatches` folds the
/// envelope-missing case (`atLogEpoch == null`) into a match — the web
/// store's lenient [ConversationState.rangeEnvelopeMatches] semantics.
typedef RowsRangePage = ({
  List<Map<String, dynamic>>? rows,
  bool? hasMore,
  dynamic atLogEpoch,
  bool epochMatches,
});

/// Parses one conversationRowsRangeV4 response: the frozen fallback chain
/// `rows.window ?? rows.rows` → bare `rows` List → top-level
/// `items ?? window` → `res is List` → unrecognizable (null), plus cast
/// and an optional rowId-ascending sort ([sortOldestFirst]; the subagent
/// sheet pages in response order and passes false). The epoch verdict is
/// computed against the [state] the fetch was made on; reporting drift is
/// this function's job — acting on it stays with the caller.
RowsRangePage parseRowsRangeResponse(
  dynamic res, {
  required ConversationState state,
  bool sortOldestFirst = true,
}) {
  List? rows;
  bool? hasMore;
  dynamic atLogEpoch;
  if (res is Map) {
    hasMore = res['hasMore'] as bool?;
    atLogEpoch = res['atLogEpoch'];
    final rowsObj = res['rows'];
    if (rowsObj is Map) {
      rows = rowsObj['window'] as List? ?? rowsObj['rows'] as List?;
    } else if (rowsObj is List) {
      rows = rowsObj;
    }
    rows ??= res['items'] as List? ?? res['window'] as List?;
  } else if (res is List) {
    rows = res;
  }
  List<Map<String, dynamic>>? cast;
  if (rows != null) {
    cast = rows.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    if (sortOldestFirst) {
      cast.sort(
        (a, b) => ((a['rowId'] as num?) ?? 0).compareTo(
          (b['rowId'] as num?) ?? 0,
        ),
      );
    }
  }
  return (
    rows: cast,
    hasMore: hasMore,
    atLogEpoch: atLogEpoch,
    epochMatches: atLogEpoch == null || atLogEpoch == state.logEpoch,
  );
}
