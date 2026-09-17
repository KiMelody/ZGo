// Ported verbatim from the reference implementation; newer style lints
// are suppressed so the file stays diffable against it.
// ignore_for_file: use_null_aware_elements, prefer_initializing_formals
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'channel_client.dart';
import 'id.dart';
import 'remote_client.dart';

/// Conversation V4 protocol over the `zcode-agent` channel.
///
/// Flow (mirrors `sk()`/`uk()` in the web client):
/// 1. `helloConversationV4()` + `initializeConversationV4(clientHello)`
/// 2. `subscribeConversationV4(scope + sessionId)` -> ack.subscriptionId
/// 3. frames pushed via dynamic event `onDynamicConversationFrame(scope)`:
///    wire frames `{wireVersion:3, kind:'complete'|'fragment', topic,
///    subscriptionId, frame | fragment*}`; complete frames carry
///    `{topic, subscriptionId, fromSeq, toSeq, sentAt, payload}` where payload
///    is `{kind:'snapshot', snapshot}` or `{kind:'deltas', deltas}`.
/// 4. commands via `sendConversationCommandV4(scope + envelope)` with
///    envelope `{commandId, clientId, sessionId, type, payload, issuedAt}`.
class ConversationTransport {
  static const channel = Channels.zcodeAgent;

  final BridgeSession session;
  final Map<String, dynamic> scope;
  final String appVersion;

  /// Desktop version gate (>=3.12.3, `params.atLeast(3, 12, 3)` at the
  /// RemoteClient): only then does clientHello carry
  /// `capabilities: {workspaceHookReviewUi: true}` — the strict hello
  /// schema of older desktops is untested against unknown fields, so the
  /// key is omitted entirely (not sent as false).
  final bool workspaceHookReviewUi;
  final void Function(String line)? onLog;

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
  }) {
    // A reopened bridge has no handshake state — start over (mirrors the
    // web client's `wD` cache being per service instance).
    session.recovered.addListener(_onBridgeRecovered);
  }

  void _onBridgeRecovered() {
    _handshaken = false;
    _handshakeFuture = null;
    connectionId = null;
    _prep = null;
  }

  ChannelClient get _channels => session.channels;

  void _log(String line) => onLog?.call(line);

  Future<void> handshake() {
    if (_handshaken) return Future.value();
    return _handshakeFuture ??=
        () async {
          final hello = await _channels.call(
            channel,
            'helloConversationV4',
            [],
          );
          _log('[v4] hello: $hello');
          if (hello is Map) {
            connectionId = hello['connectionId'] as String?;
          }
          await _channels.call(channel, 'initializeConversationV4', [
            {
              'kind': 'clientHello',
              'protocolVersion': 3,
              'clientId': clientId,
              'clientKind': 'mobileApp',
              'appVersion': appVersion,
              // 3.12.3+ strict schema: capabilities holds exactly this one
              // key — anything else rejects the whole hello.
              if (workspaceHookReviewUi)
                'capabilities': {'workspaceHookReviewUi': true},
            },
          ]);
          _handshaken = true;
        }().catchError((e) {
          _handshakeFuture = null;
          throw e;
        });
  }

  Future<ConversationSubscription> subscribe(String sessionId) async {
    await handshake();
    final subscription = ConversationSubscription._(this, sessionId);
    await subscription._start();
    _subscriptions[sessionId] = subscription;
    return subscription;
  }

  void _untrackSubscription(String sessionId) {
    _subscriptions.remove(sessionId);
  }

  /// Commands that require `baseRevision` (CAS, mirrors `eAe` in the web
  /// client) and row-target commands that also require `baseLogEpoch`
  /// (mirrors `tAe`).
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
    _log('[v4] command $type');
    var res = await _sendCommandWithRetry(envelope, timeout);
    // Runtime events (turn completion etc.) also bump the revision, so a
    // CAS base can go stale even with ack tracking. The stale ack tells
    // the server's current revision — retry once with it (mirrors the
    // web client's stale-revision retry).
    if (sessionId != null &&
        res is Map &&
        res['status'] == 'stale' &&
        res['revisionAtDecision'] is num) {
      final serverRevision = (res['revisionAtDecision'] as num).toInt();
      _log('[v4] command $type stale, retry at rev $serverRevision');
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
    if (sessionId != null && res is Map && res['revisionAtDecision'] is num) {
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
    return res;
  }

  /// Sends one command envelope; on timeout (likely a relay drop mid-flight)
  /// waits for bridge recovery and retries once with a fresh commandId.
  Future<dynamic> _sendCommandWithRetry(
    Map<String, dynamic> envelope,
    Duration timeout,
  ) async {
    try {
      return await _channels.call(channel, 'sendConversationCommandV4', [
        {...scope, 'envelope': envelope},
      ], timeout: timeout);
    } on TimeoutException {
      // Retry only when the relay dropped mid-flight (bridge degraded): the
      // command then never reached the server. If the bridge is still
      // healthy, rethrow — a retry would double-deliver (e.g. sendText).
      if (session.degraded.value == null) rethrow;
      _log(
        '[v4] command timed out during drop, waiting for recovery and '
        'retrying',
      );
      await session.waitHealthy(timeout: const Duration(seconds: 45));
      final fresh = {
        ...envelope,
        'commandId': generateUuid(),
        'issuedAt': DateTime.now().millisecondsSinceEpoch,
      };
      return _channels.call(channel, 'sendConversationCommandV4', [
        {...scope, 'envelope': fresh},
      ], timeout: timeout);
    }
  }

  /// Creates a new session (mirrors the composer's first-send path):
  /// command `createSession` with `{workspaceId, firstInput:{text}}` and a
  /// null envelope sessionId. Returns the new sessionId on `accepted`.
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
    if (status != 'accepted') {
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
  /// (command `createSelectionSideSession` with an empty payload, mirrors
  /// the web client's "ask in side chat" flow). Returns the new sessionId.
  Future<String> createSelectionSideSession(
    String parentSessionId, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final res = await sendCommand(
      parentSessionId,
      'createSelectionSideSession',
      {},
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
      _log('[v4] switchModelConfig retry with thought=$fallback');
      res = await sendCommand(sessionId, 'switchModelConfig', {
        'provider': provider,
        'model': model,
        'thought': fallback,
      });
    }
    return res;
  }

  /// build / edit / plan / yolo. Mirrors `switchCollaborationMode`.
  Future<dynamic> switchCollaborationMode(String sessionId, String mode) =>
      sendCommand(sessionId, 'switchCollaborationMode', {'mode': mode});

  /// queue / guide followup. Mirrors `setFollowupMode`.
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

  Future<dynamic> editUserQuery(
    String sessionId,
    Map<String, dynamic> target,
    String newText,
  ) => sendCommand(sessionId, 'editUserQuery', {
    'target': target,
    'newText': newText,
  });

  Future<dynamic> applyFileRewind(
    String sessionId,
    Map<String, dynamic> target,
  ) => sendCommand(sessionId, 'applyFileRewind', {'target': target});

  Future<dynamic> plans(String sessionId) async {
    await handshake();
    return _channels.call(channel, 'conversationPlansV4', [
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
    return _channels.call(channel, 'conversationFileChangesV4', [
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
    return _channels.call(channel, 'conversationFileRewindPreviewV4', [
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

  /// Uploads an attachment (begin/chunk/commit, mirrors `rNe()`).
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

    final beginRes = await _channels.call(channel, 'attachmentBeginV4', [
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
      final chunkRes = await _channels.call(channel, 'attachmentChunkV4', [
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
    final commitRes = await _channels.call(channel, 'attachmentCommitV4', [
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
      final res = await _channels.call(channel, 'attachmentReadV4', [
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
    return _channels.call(channel, 'conversationRowsRangeV4', [
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
    final subscription = SessionsIndexSubscription._(this);
    await subscription._start();
    return subscription;
  }

  // ----------------------------------------------- workspace presentation

  WorkspacePrep? _prep;

  /// `zcode-task.prepareWorkspace` — returns configOptions (model/mode/
  /// thought selects) and slashCommands (builtin + custom skills/MCP).
  Future<WorkspacePrep> prepareWorkspace({bool refresh = false}) async {
    final cached = _prep;
    if (cached != null && !refresh) return cached;
    final res = await _channels.call(Channels.zcodeTask, 'prepareWorkspace', [
      scope,
    ]);
    final prep = WorkspacePrep._(res is Map ? res : const {});
    _prep = prep;
    return prep;
  }

  /// `zcode-agent.readWorkspacePresentation` — the 3.12.3+ slash-command
  /// source (builtin + custom), same method the official web remote reads.
  /// One-shot RPC, no subscription lifecycle. Null on non-Map answer or
  /// channel rejection — a presentation miss must not fail the caller
  /// (slashCommands stay empty instead).
  Future<Map<String, dynamic>?> readWorkspacePresentation() async {
    try {
      final res = await _channels.call(
        channel,
        'readWorkspacePresentation',
        [scope],
      );
      return res is Map ? Map<String, dynamic>.from(res) : null;
    } catch (_) {
      return null;
    }
  }

  /// `skills.list` — enabled skills of this workspace (mirrors the web
  /// client's `skillsService.list`). Skills are invoked in the composer as
  /// `$name`. Returns an empty list when the channel rejects or returns no
  /// skill data.
  /// Last successful skills.list result (mention picker reads this
  /// synchronously without a fresh RPC).
  List<SkillEntry> lastSkills = const [];

  Future<List<SkillEntry>> skills() async {
    final res = await _channels.call(Channels.skills, 'list', [
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
        SkillEntry._(item.cast<String, dynamic>()),
    ].where((s) => s.name.isNotEmpty).toList();
  }

  ReplayableCommandQueue? _replayableQueue;

  /// Offline replayable-command queue (`zcode-task.enqueueTaskCommand`
  /// family, desktop 3.12.3). Lazily created on first access — the chat
  /// page touches it only from the send-failure path and the queue bar.
  /// Session lifetime is structural: the queue hangs off this transport
  /// and is dropped with it on workspace/device switch (memory-only 一期).
  ReplayableCommandQueue get replayableQueue =>
      _replayableQueue ??= ReplayableCommandQueue(
        call: _replayableWireCall,
        scope: scope,
        clientId: clientId,
        recovered: session.recovered,
        onLog: _log,
      );

  /// Wire binding for [replayableQueue]: the zcode-task channel, gated on
  /// the same handshake + bridge-health as [sendCommand] so a drain during
  /// a reconnect window waits for recovery instead of hanging on a dead
  /// bridge.
  Future<dynamic> _replayableWireCall(
    String method,
    List<Object?> args,
  ) async {
    await handshake();
    await session.waitHealthy(timeout: const Duration(seconds: 45));
    return _channels.call(Channels.zcodeTask, method, args);
  }
}

/// One locally-queued `send_prompt` of [ReplayableCommandQueue].
enum ReplayableQueueItemState { queued, sending, failed }

class ReplayableQueueItem {
  /// Client-generated uuid — stable across channel-error retries so the
  /// desktop can recognize a replay of the same command.
  final String commandId;
  final String taskId;
  final String content;

  ReplayableQueueItemState state = ReplayableQueueItemState.queued;

  /// Channel-level send attempts consumed (requeue budget — see
  /// [ReplayableCommandQueue.maxRequeues]).
  int attempts = 0;

  /// Failure detail of a [ReplayableQueueItemState.failed] item.
  String? error;

  ReplayableQueueItem({
    required this.commandId,
    required this.taskId,
    required this.content,
  });
}

/// Client-side offline queue for the 3.12.3 replayable command family
/// (`web-remote-replayable`, verified 2026-09-18 — see the task's
/// notes.md): enqueue is a reliable direct-send while the task owner is
/// active, so bridge-degraded sendText failures are held in app memory and
/// replayed via `enqueueTaskCommand` once the bridge recovers.
///
/// Item-level state machine (design.md, 一期 scope = sendText):
/// ```text
/// idle ── sendText fails (channel-level) ──▶ queued   [queueLocal]
/// queued ── user undo ──▶ removed (+ idempotent cancelTaskCommand)
/// queued ── bridge recovered ──▶ sending ── accepted ──▶ removed
/// sending ── enqueue rejected (non-channel) ──▶ failed (retry / undo)
/// sending ── enqueue channel error ──▶ queued (≤ maxRequeues, else failed)
/// ```
/// The queue only ever grows through [queueLocal] and shrinks through
/// accepted sends / user undo; `promoteTaskCommand` is deliberately not
/// called (owner-active enqueue delivers immediately — research finding 1).
/// Dependencies ride the port-call seam ([call] closure + injected
/// [recovered] listenable) so tests drive the whole machine with a
/// hand-written fake, no sockets.
class ReplayableCommandQueue extends ChangeNotifier {
  /// Binds one RPC: the channel (zcode-task) + handshake/health gating are
  /// fixed by the queue owner, method/args vary.
  final Future<dynamic> Function(String method, List<Object?> args) call;

  /// Workspace scope (workspacePath/identity) merged into every enqueue.
  final Map<String, dynamic> scope;

  /// This client's conversation id (the transport's handshake identity).
  final String clientId;

  final void Function(String line)? onLog;

  final Listenable recovered;
  late final void Function() _onRecoveredListener;
  final _items = <ReplayableQueueItem>[];
  bool _draining = false;
  bool _disposed = false;

  /// How many times a channel-level failure may put one item back into the
  /// queue (design: capped so a flapping bridge can't loop forever; the
  /// next failure past the cap surfaces the item as failed).
  static const maxRequeues = 3;

  ReplayableCommandQueue({
    required this.call,
    required this.scope,
    required this.clientId,
    required this.recovered,
    this.onLog,
  }) {
    _onRecoveredListener = () {
      if (!_disposed) unawaited(_drain());
    };
    recovered.addListener(_onRecoveredListener);
  }

  /// Queue snapshot (FIFO, queued first in enqueue order). Failed items
  /// stay in place until retried or undone.
  List<ReplayableQueueItem> get items => List.unmodifiable(_items);

  /// True while a recovered/drain pass is replaying items.
  bool get draining => _draining;

  /// idle ──▶ queued: the composer captured a channel-level sendText
  /// failure. Schedules an immediate drain — the bridge may already be
  /// healthy again (the wire binding then waits for recovery itself).
  ReplayableQueueItem queueLocal({
    required String taskId,
    required String content,
  }) {
    final item = ReplayableQueueItem(
      commandId: generateUuid(),
      taskId: taskId,
      content: content,
    );
    _items.add(item);
    notifyListeners();
    unawaited(_drain());
    return item;
  }

  /// Removes [commandId] locally and fires the idempotent
  /// `cancelTaskCommand` as a safety net (research: not_found still
  /// answers canceled:true — "ensure not queued" semantics, never an
  /// error surface).
  Future<void> cancel(String commandId) async {
    final index = _items.indexWhere((i) => i.commandId == commandId);
    if (index == -1) return;
    final item = _items.removeAt(index);
    notifyListeners();
    try {
      await cancelTaskCommand(item.commandId, item.taskId);
    } catch (e) {
      onLog?.call('[replayable] cancel failed: $e');
    }
  }

  /// User retry on a failed item: back into the queue with a fresh
  /// requeue budget, then an immediate drain attempt.
  void retry(String commandId) {
    final item = _byId(commandId);
    if (item == null || item.state != ReplayableQueueItemState.failed) return;
    item
      ..state = ReplayableQueueItemState.queued
      ..attempts = 0
      ..error = null;
    notifyListeners();
    unawaited(_drain());
  }

  /// `zcode-task.enqueueTaskCommand` — research-confirmed schema; no
  /// clientMode (the mode rides getTaskSnapshot reads only). Answers
  /// `{accepted, command}`.
  Future<dynamic> enqueueTaskCommand({
    required String commandId,
    required String taskId,
    required String content,
  }) => call('enqueueTaskCommand', [
    {
      ...scope,
      'commandId': commandId,
      'taskId': taskId,
      'type': 'send_prompt',
      'content': content,
      'clientId': clientId,
      'clientLabel': 'ZLinker',
    },
  ]);

  /// `zcode-task.cancelTaskCommand` — `{commandId, taskId}`, nothing else.
  Future<dynamic> cancelTaskCommand(String commandId, String taskId) =>
      call('cancelTaskCommand', [
        {'commandId': commandId, 'taskId': taskId},
      ]);

  ReplayableQueueItem? _byId(String commandId) {
    for (final item in _items) {
      if (item.commandId == commandId) return item;
    }
    return null;
  }

  Future<void> _drain() async {
    if (_draining || _disposed) return;
    _draining = true;
    try {
      while (!_disposed) {
        ReplayableQueueItem? next;
        for (final item in _items) {
          if (item.state == ReplayableQueueItemState.queued) {
            next = item;
            break;
          }
        }
        if (next == null) return;
        // Channel-level failure: the whole drain pauses (every further
        // enqueue would fail the same way) until the next recovery.
        if (await _sendItem(next)) return;
      }
    } finally {
      _draining = false;
    }
  }

  /// Replays one item. Returns true when the item went back to queued
  /// (channel-level failure) and the drain should pause.
  Future<bool> _sendItem(ReplayableQueueItem item) async {
    item
      ..state = ReplayableQueueItemState.sending
      ..error = null;
    notifyListeners();
    dynamic res;
    Object? failure;
    try {
      res = await enqueueTaskCommand(
        commandId: item.commandId,
        taskId: item.taskId,
        content: item.content,
      );
    } catch (e) {
      failure = e;
    }
    if (failure == null && res is Map && res['accepted'] == false) {
      // Semantic rejection (validation/permission) — not retryable.
      failure = StateError('enqueueTaskCommand rejected: $res');
    }
    // The session ended while the enqueue was in flight — the queue is
    // gone; never notify or mutate past dispose.
    if (_disposed) return false;
    if (failure == null) {
      // sent — owner-active enqueue delivers immediately (research).
      _items.remove(item);
    } else if (isChannelLevelError(failure)) {
      item.attempts += 1;
      if (item.attempts <= maxRequeues) {
        item.state = ReplayableQueueItemState.queued;
        onLog?.call('[replayable] enqueue channel error, requeued '
            '(attempt ${item.attempts}): $failure');
        notifyListeners();
        return true;
      }
      item
        ..state = ReplayableQueueItemState.failed
        ..error = '$failure';
    } else {
      item
        ..state = ReplayableQueueItemState.failed
        ..error = failure is ChannelRpcError ? failure.message : '$failure';
    }
    notifyListeners();
    return false;
  }

  @override
  void dispose() {
    _disposed = true;
    recovered.removeListener(_onRecoveredListener);
    _items.clear();
    super.dispose();
  }
}

/// Shared base for Conversation/SessionsIndex subscriptions.
/// Extracts the common wire-frame staging, fragment reassembly, bridge
/// recovery, and resubscribe retry logic.
abstract class _SubscriptionBase<T extends ChangeNotifier> {
  final ConversationTransport _transport;
  final String _logTag;

  final T state;

  String? _subscriptionId;
  String? get subscriptionId => _subscriptionId;
  void Function()? _cancelFrameListener;
  bool _disposed = false;
  bool _resyncing = false;
  Timer? _resubscribeTimer;

  /// Monotonic subscribe-attempt generation: `_start()` bumps it on entry.
  /// A late ack (or late failure) whose attempt no longer matches — a
  /// watchdog/bridge-recovery resubscribe raced the pending call — is
  /// dropped instead of overwriting the newer attempt's subscription
  /// (same race family as internal-task).
  int _startAttempt = 0;

  /// Abandon-in-flight guard: fires unless the ack arrives first; a
  /// superseded attempt neither arms nor cancels it.
  Timer? _ackWatchdog;

  final _stagedFrames = <Map<String, dynamic>>[];
  final _fragments = <String, _LogicalFrameAssembly>{};
  Timer? _fragmentCleanup;

  _SubscriptionBase(this._transport, this.state, this._logTag) {
    _transport.session.recovered.addListener(_onBridgeRecovered);
    _fragmentCleanup = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _purgeFragments(),
    );
  }

  // --- abstract: subclasses define channel/protocol specifics

  /// Frame event name (e.g. `onDynamicConversationFrame`).
  String get _frameEventName;

  /// Subscribe method name (e.g. `subscribeConversationV4`).
  String get _subscribeMethod;

  /// Unsubscribe method name (e.g. `unsubscribeConversationV4`).
  String get _unsubscribeMethod;

  /// Resync method name (e.g. `resyncConversationV4`).
  String get _resyncMethod;

  /// Extra subscribe request args (merged with scope).
  Map<String, dynamic> get _subscribeArgs;

  /// Extra unsubscribe request args.
  Map<String, dynamic> get _unsubscribeArgs;

  /// Extra resync request args.
  Map<String, dynamic> get _resyncArgs;

  /// Topic for wire-frame routing.
  String get topic;

  /// Process a logical frame against [state].
  void _acceptLogicalFrame(Map<String, dynamic> frame);

  /// Called with the subscribe ack map — hook for state-specific processing.
  void _onSubscribeAck(Map<String, dynamic> ack) {}

  /// Called after a successful _start() — hook for post-start logic.
  void _onStarted() {}

  /// Called during resubscribe cleanup before re-connect.
  void _onResubscribeCleanup() {}

  /// Called during dispose — extra cleanup.
  Future<void> _onDispose() async {}

  int get _resyncSeq => 0;
  String? get _resyncEpoch => null;

  void _purgeFragments() {
    if (_disposed) return;
    final stale = <String>[];
    final now = DateTime.now();
    _fragments.forEach((id, a) {
      if (now.difference(a.createdAt).inSeconds > 60) stale.add(id);
    });
    for (final id in stale) {
      _fragments.remove(id);
      _transport._log('[$_logTag] purged stale fragment $id');
    }
  }

  Future<void> _start() async {
    final attempt = ++_startAttempt;
    await _transport.handshake();
    _cancelFrameListener = _transport._channels.addEventListener(
      ConversationTransport.channel,
      _frameEventName,
      _handleWireFrame,
      arg: _transport.scope,
    );
    _ackWatchdog?.cancel();
    _ackWatchdog = Timer(_transport.subscribeAckTimeout, () {
      if (_disposed || attempt != _startAttempt) return;
      _transport._log(
        '[$_logTag] subscribe ack stalled '
        '${_transport.subscribeAckTimeout.inSeconds}s, resubscribing',
      );
      _resubscribe();
    });
    Object? res;
    try {
      res = await _transport._channels.call(
        ConversationTransport.channel,
        _subscribeMethod,
        [
          {..._transport.scope, ..._subscribeArgs},
        ],
        // The desktop may need to warm the session runtime before answering —
        // give the subscribe call generous room instead of timing out at the
        // 30s channel default.
        timeout: const Duration(seconds: 60),
      );
    } catch (e) {
      if (attempt != _startAttempt) {
        // Superseded while pending (watchdog / bridge recovery raced us):
        // the replacement attempt owns the outcome, so this failure must
        // not surface as a subscribe error for the newer attempt.
        _transport._log('[$_logTag] abandoned subscribe attempt $attempt: $e');
        return;
      }
      _ackWatchdog?.cancel();
      rethrow;
    }
    if (attempt != _startAttempt) {
      // Late ack of a superseded attempt: do not touch _subscriptionId,
      // staged frames or post-start hooks — a newer attempt owns them.
      _transport._log(
        '[$_logTag] dropped late subscribe ack for attempt $attempt ($topic)',
      );
      return;
    }
    _ackWatchdog?.cancel();
    final ack = (res as Map?)?['ack'] as Map?;
    _subscriptionId = ack?['subscriptionId'] as String?;
    _transport._log('[$_logTag] subscribed $topic id=$_subscriptionId');
    if (_subscriptionId == null) {
      throw StateError('$_subscribeMethod: missing ack.subscriptionId');
    }
    _onSubscribeAck(ack?.cast<String, dynamic>() ?? const {});
    final staged = List<Map<String, dynamic>>.from(_stagedFrames);
    _stagedFrames.clear();
    for (final frame in staged) {
      _acceptLogicalFrame(frame);
    }
    _onStarted();
  }

  void _onBridgeRecovered() {
    if (_disposed) return;
    _transport._log('[$_logTag] bridge recovered, resubscribing $topic');
    _resubscribe();
  }

  Future<void> _resubscribe() async {
    await _transport.handshake();
    _onResubscribeCleanup();
    _cancelFrameListener?.call();
    _cancelFrameListener = null;
    final oldId = _subscriptionId;
    _subscriptionId = null;
    _stagedFrames.clear();
    _fragments.clear();
    if (oldId != null) {
      try {
        await _transport._channels.call(
          ConversationTransport.channel,
          _unsubscribeMethod,
          [
            {..._transport.scope, 'subscriptionId': oldId, ..._unsubscribeArgs},
          ],
        );
      } catch (_) {}
    }
    try {
      await _start();
    } catch (e) {
      _transport._log('[$_logTag] resubscribe failed: $e');
      _resubscribeTimer?.cancel();
      _resubscribeTimer = Timer(const Duration(seconds: 3), () {
        if (!_disposed && _subscriptionId == null) _resubscribe();
      });
    }
  }

  void _handleWireFrame(dynamic data) {
    if (_disposed || data is! Map) return;
    final frame = data.cast<String, dynamic>();
    if (frame['topic'] != topic) return;
    switch (frame['kind']) {
      case 'complete':
        final inner = frame['frame'];
        if (inner is Map) {
          _acceptOrStage(inner.cast<String, dynamic>());
        }
        break;
      case 'fragment':
        _acceptFragment(frame);
        break;
    }
  }

  void _acceptOrStage(Map<String, dynamic> frame) {
    if (_subscriptionId == null) {
      _stagedFrames.add(frame);
      return;
    }
    _acceptLogicalFrame(frame);
  }

  void _acceptFragment(Map<String, dynamic> frame) {
    final id = frame['logicalFrameId'] as String?;
    final index = (frame['fragmentIndex'] as num?)?.toInt();
    final count = (frame['fragmentCount'] as num?)?.toInt();
    final dataBase64 = frame['dataBase64'] as String?;
    if (id == null || index == null || count == null || dataBase64 == null) {
      return;
    }
    final assembly = _fragments.putIfAbsent(
      id,
      () => _LogicalFrameAssembly(count),
    );
    assembly.add(index, base64.decode(dataBase64));
    if (assembly.isComplete) {
      _fragments.remove(id);
      try {
        final decoded = jsonDecode(utf8.decode(assembly.assemble()));
        if (decoded is Map) {
          _acceptOrStage(decoded.cast<String, dynamic>());
        }
      } catch (e) {
        _transport._log('[$_logTag] bad logical frame: $e');
      }
    }
  }

  Future<void> _resync() async {
    final id = _subscriptionId;
    if (id == null || _disposed || _resyncing) return;
    _resyncing = true;
    _transport._log(
      '[$_logTag] resync (gap detected) seq=$_resyncSeq logEpoch=$_resyncEpoch',
    );
    try {
      await _transport._channels.call(
        ConversationTransport.channel,
        _resyncMethod,
        [
          {
            ..._transport.scope,
            'subscriptionId': id,
            ..._resyncArgs,
            if (_resyncEpoch != null)
              'base': {'logEpoch': _resyncEpoch, 'seq': _resyncSeq},
          },
        ],
      );
    } catch (e) {
      _transport._log('[$_logTag] resync failed: $e');
    } finally {
      _resyncing = false;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _resubscribeTimer?.cancel();
    _ackWatchdog?.cancel();
    _fragmentCleanup?.cancel();
    await _onDispose();
    _transport.session.recovered.removeListener(_onBridgeRecovered);
    _cancelFrameListener?.call();
    final id = _subscriptionId;
    if (id != null) {
      try {
        await _transport._channels.call(
          ConversationTransport.channel,
          _unsubscribeMethod,
          [
            {..._transport.scope, 'subscriptionId': id, ..._unsubscribeArgs},
          ],
        );
      } catch (_) {}
    }
    _fragments.clear();
  }
}

class ConversationSubscription extends _SubscriptionBase<ConversationState> {
  final String sessionId;

  DateTime _lastFrameAt = DateTime.now();
  Timer? _watchdog;

  ConversationSubscription._(ConversationTransport transport, this.sessionId)
    : super(transport, ConversationState(), 'v4');

  @override
  String get _frameEventName => 'onDynamicConversationFrame';
  @override
  String get _subscribeMethod => 'subscribeConversationV4';
  @override
  String get _unsubscribeMethod => 'unsubscribeConversationV4';
  @override
  String get _resyncMethod => 'resyncConversationV4';
  @override
  Map<String, dynamic> get _subscribeArgs => {'sessionId': sessionId};
  @override
  Map<String, dynamic> get _unsubscribeArgs => const {};
  @override
  Map<String, dynamic> get _resyncArgs => const {'forceSnapshot': true};
  @override
  String get topic => 'conversation/$sessionId';
  @override
  int get _resyncSeq => state.seq;
  @override
  String? get _resyncEpoch => state.logEpoch;

  @override
  void _onSubscribeAck(Map<String, dynamic> ack) {
    if (ack['logEpoch'] is String) {
      state.logEpoch = ack['logEpoch'] as String;
    }
  }

  @override
  void _onStarted() {
    _startWatchdog();
    _listenTaskStream();
  }

  @override
  void _onResubscribeCleanup() {
    _watchdog?.cancel();
    _cancelTaskStreamListener?.call();
    _cancelTaskStreamListener = null;
  }

  @override
  Future<void> _onDispose() async {
    _watchdog?.cancel();
    _cancelTaskStreamListener?.call();
    _transport._untrackSubscription(sessionId);
    state.deactivateState();
  }

  /// Context/usage numbers ride the desktop's task-stream broadcast
  /// (`bots:task-stream` messages on the `broadcast` channel, official
  /// `broadcastService.onMessage`), not the Conversation V4 delta stream —
  /// the official V4 reducer only handles row/state ops. Filtered to this
  /// session's taskId; everything else is dropped. Live-probed on 3.11.2:
  /// the broadcast stays silent there and the numbers flow through
  /// `state.updated` patches instead, so [ContextUsageView] reads both
  /// shapes and this listener is purely additive.
  void Function()? _cancelTaskStreamListener;

  void _listenTaskStream() {
    _cancelTaskStreamListener?.call();
    _cancelTaskStreamListener = _transport._channels.addEventListener(
      Channels.broadcast,
      'onMessage',
      _handleBroadcastMessage,
    );
  }

  void _handleBroadcastMessage(dynamic data) {
    if (_disposed || data is! Map) return;
    if (data['channel'] != 'bots:task-stream') return;
    final payload = data['payload'];
    if (payload is! Map) return;
    if ('${payload['taskId']}' != sessionId) return;
    final event = payload['event'];
    if (event is! Map || event['type'] != 'usage_update') return;
    state.applyUsageUpdate(event.cast<String, dynamic>());
  }

  @override
  void _acceptLogicalFrame(Map<String, dynamic> frame) {
    final subId = subscriptionId;
    if (subId == null || frame['subscriptionId'] != subId) return;
    _lastFrameAt = DateTime.now();
    state.applyFrame(frame, onGap: _resync);
  }

  void _startWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_disposed) return;
      final quietSeconds = DateTime.now().difference(_lastFrameAt).inSeconds;
      if (quietSeconds < 20) return;
      final streaming = state.rows.any((r) => r['state'] == 'streaming');
      if (state.isRunning || streaming) {
        _transport._log(
          '[v4] watchdog: no frames for ${quietSeconds}s while active, resync',
        );
        _resync();
      } else if (!state.ready) {
        // Never-ready blind spot: the subscribe acked but no snapshot ever
        // arrived. Observed live (2026-09-15): the desktop bridge can die
        // mid-push of a large subagent snapshot, and without a forced
        // resync the subscription idles forever — the detail page would
        // spin indefinitely.
        _transport._log(
          '[v4] watchdog: no snapshot ${quietSeconds}s after subscribe, resync',
        );
        _resync();
      }
    });
  }
}

class WorkspacePrep {
  final List<ConfigOption> configOptions;
  final List<SlashCommand> slashCommands;
  final Map raw;

  WorkspacePrep._(this.raw)
    : configOptions = [
        if (raw['configOptions'] is List)
          for (final o in raw['configOptions'] as List)
            if (o is Map) ConfigOption._(o),
      ],
      slashCommands = [
        if (raw['slashCommands'] is List)
          for (final c in raw['slashCommands'] as List)
            if (c is Map) SlashCommand._(c),
      ];

  /// Public constructor (tests / manual construction).
  factory WorkspacePrep.fromMap(Map raw) => WorkspacePrep._(raw);

  ConfigOption? option(String id) {
    for (final o in configOptions) {
      if (o.id == id) return o;
    }
    return null;
  }
}

/// A desktop skill (`skills.list`), triggered in the composer as `$name`.
class SkillEntry {
  final String id;
  final String name;
  final String path;
  final String scope;
  final String? description;
  final String? argumentHint;
  final bool enabled;

  SkillEntry._(Map raw)
    : id = '${raw['id'] ?? ''}',
      name = '${raw['name'] ?? ''}',
      path = '${raw['path'] ?? ''}',
      scope = '${raw['scope'] ?? 'workspace'}',
      description = raw['description'] as String?,
      argumentHint = raw['argumentHint'] as String?,
      enabled = raw['enabled'] != false;
}

class ConfigOption {
  final String id;
  final String name;
  final String category;
  final String type;
  final Object? currentValue;
  final List<ConfigOptionValue> options;

  ConfigOption._(Map raw)
    : id = '${raw['id'] ?? ''}',
      name = '${raw['name'] ?? ''}',
      category = '${raw['category'] ?? ''}',
      type = '${raw['type'] ?? ''}',
      currentValue = raw['currentValue'],
      options = [
        if (raw['options'] is List)
          for (final v in raw['options'] as List)
            if (v is Map) ConfigOptionValue._(v),
      ];
}

class ConfigOptionValue {
  final String value;
  final String name;
  final String? description;
  final String? modelProviderName;

  ConfigOptionValue._(Map raw)
    : value = '${raw['value'] ?? ''}',
      name = '${raw['name'] ?? raw['value'] ?? ''}',
      description = raw['description'] as String?,
      modelProviderName = raw['modelProviderName'] as String?;

  /// Public constructor: synthesizes sheet-side entries from other
  /// catalogs (the chat config sheet's model-provider fallback, PRD
  /// 09-19) in the same shape the wire parser produces.
  ConfigOptionValue({
    required this.value,
    required this.name,
    this.description,
    this.modelProviderName,
  });
}

class SlashCommand {
  final String name;
  final String description;
  final String? inputHint;
  final String source;

  SlashCommand._(Map raw)
    : name = '${raw['name'] ?? ''}',
      description = '${raw['description'] ?? ''}',
      inputHint = raw['inputHint'] as String?,
      source = '${raw['source'] ?? ''}';
}

class _LogicalFrameAssembly {
  final int count;
  final List<Uint8List?> parts;
  final DateTime createdAt = DateTime.now();
  int received = 0;

  _LogicalFrameAssembly(this.count) : parts = List.filled(count, null);

  void add(int index, Uint8List data) {
    if (index < 0 || index >= count) return;
    if (parts[index] == null) received += 1;
    parts[index] = data;
  }

  bool get isComplete => received == count;

  Uint8List assemble() {
    final builder = BytesBuilder();
    for (final p in parts) {
      if (p != null) builder.add(p);
    }
    return builder.toBytes();
  }
}

/// Live sessions-index state (task list of a workspace), mirrors the
/// sessions-index subscription in the web client (`QAe` delta application).
class SessionEntry {
  final String sessionId;
  final String? parentSessionId;
  final String title;
  final String phase;
  final String? lastAssistantPreview;
  final int lastActivityAt;
  final int createdAt;
  final bool hasBackgroundWork;
  final Map<String, dynamic>? pendingInteraction;
  final Map<String, dynamic> raw;

  SessionEntry(this.raw)
    : sessionId = '${raw['sessionId'] ?? ''}',
      parentSessionId = raw['parentSessionId'] as String?,
      title = '${raw['title'] ?? ''}',
      phase = '${raw['phase'] ?? ''}',
      lastAssistantPreview = raw['lastAssistantPreview'] as String?,
      lastActivityAt = (raw['lastActivityAt'] as num?)?.toInt() ?? 0,
      createdAt = (raw['createdAt'] as num?)?.toInt() ?? 0,
      hasBackgroundWork = raw['hasBackgroundWork'] == true,
      pendingInteraction = (raw['pendingInteraction'] as Map?)
          ?.cast<String, dynamic>();

  /// Adapts a relay task (`Dg` model from bootstrap / workspace-list-updated)
  /// into a row entry so the task list can render non-active workspaces and
  /// the archive view from the relay overview. `displayStatus`
  /// (idle|running|completed|error) maps onto the phase-pill vocabulary.
  factory SessionEntry.fromRelayTask(Map<String, dynamic> task) {
    const statusToPhase = {
      'idle': 'idle',
      'running': 'running',
      'completed': 'completedSuccess',
      'error': 'error',
    };
    final status = '${task['displayStatus'] ?? 'idle'}';
    return SessionEntry({
      'sessionId': task['taskId'],
      'title': task['title'],
      'phase': statusToPhase[status] ?? status,
      'createdAt': task['createdAt'],
      'lastActivityAt': task['updatedAt'],
      'pinned': task['pinned'],
      'unreadAt': task['unreadAt'],
      'workspacePath': task['workspacePath'],
      'workspaceIdentity': task['workspaceIdentity'],
    });
  }
}

class SessionsIndexState extends ChangeNotifier {
  String? workspaceId;
  String? logEpoch;
  int seq = 0;
  final Map<String, SessionEntry> sessions = {};
  bool ready = false;

  bool _deactivated = false;

  /// Same lazy shutdown as [ConversationState.deactivateState]: UI listening
  /// to the sessions index may outlive the subscription, so dispose-time
  /// asserts must not fire while listeners detach.
  void deactivateState() {
    _deactivated = true;
  }

  @override
  void notifyListeners() {
    if (_deactivated) return;
    super.notifyListeners();
  }

  List<SessionEntry> get list {
    final values = sessions.values.toList()
      ..sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));
    return values;
  }

  void applyFrame(
    Map<String, dynamic> frame, {
    required void Function() onGap,
  }) {
    final payload = frame['payload'];
    if (payload is! Map) return;
    final toSeq = (frame['toSeq'] as num?)?.toInt() ?? seq;

    if (payload['kind'] == 'snapshot') {
      final snap = (payload['snapshot'] as Map).cast<String, dynamic>();
      workspaceId = snap['workspaceId'] as String?;
      logEpoch = snap['logEpoch'] as String?;
      sessions.clear();
      final list = snap['sessions'];
      if (list is List) {
        for (final s in list) {
          if (s is Map) {
            final entry = SessionEntry(s.cast<String, dynamic>());
            sessions[entry.sessionId] = entry;
          }
        }
      }
      seq = toSeq;
    } else if (payload['kind'] == 'deltas') {
      final fromSeq = (frame['fromSeq'] as num?)?.toInt() ?? seq;
      if (fromSeq != seq) {
        onGap();
        return;
      }
      final deltas = payload['deltas'];
      if (deltas is List) {
        for (final d in deltas) {
          if (d is! Map) continue;
          if (d['op'] == 'session.upserted' && d['session'] is Map) {
            final entry = SessionEntry(
              (d['session'] as Map).cast<String, dynamic>(),
            );
            sessions[entry.sessionId] = entry;
          } else if (d['op'] == 'session.removed') {
            sessions.remove('${d['sessionId']}');
          }
        }
      }
      seq = toSeq;
    }
    ready = true;
    notifyListeners();
  }
}

class SessionsIndexSubscription extends _SubscriptionBase<SessionsIndexState> {
  SessionsIndexSubscription._(ConversationTransport transport)
    : super(transport, SessionsIndexState(), 'v4-si');

  @override
  String get _frameEventName => 'onDynamicSessionsIndexFrame';
  @override
  String get _subscribeMethod => 'subscribeSessionsIndexV4';
  @override
  String get _unsubscribeMethod => 'unsubscribeSessionsIndexV4';
  @override
  String get _resyncMethod => 'resyncSessionsIndexV4';
  @override
  Map<String, dynamic> get _subscribeArgs => const {
    'runtimePolicy': 'existing-only',
  };
  @override
  Map<String, dynamic> get _unsubscribeArgs => const {
    'runtimePolicy': 'existing-only',
  };
  @override
  Map<String, dynamic> get _resyncArgs => const {
    'runtimePolicy': 'existing-only',
  };
  @override
  String get topic =>
      'sessions-index/${_transport.scope['workspaceIdentity'] ?? _transport.scope['workspacePath']}';
  @override
  int get _resyncSeq => state.seq;
  @override
  String? get _resyncEpoch => state.logEpoch;

  @override
  Future<void> _onDispose() async {
    state.deactivateState();
  }

  @override
  void _acceptLogicalFrame(Map<String, dynamic> frame) {
    final subId = subscriptionId;
    if (subId == null || frame['subscriptionId'] != subId) return;
    state.applyFrame(frame, onGap: _resync);
  }
}

/// Conversation snapshot + row state, mirrors `fke()`/`pke()` delta
/// application in the web client.
class ConversationState extends ChangeNotifier {
  Map<String, dynamic>? snapshot;
  List<Map<String, dynamic>> rows = [];
  int seq = 0;
  String? logEpoch;
  int? firstRowId;
  int totalCount = 0;
  bool ready = false;

  /// Set by [deactivateState]; the notification path below checks it.
  bool _deactivated = false;

  /// Lazy deactivation instead of ChangeNotifier.dispose(): modal routes
  /// (usage sheet) can outlive the subscription that owns this state, and a
  /// hard dispose would trip ChangeNotifier's post-dispose asserts when those
  /// routes detach their listeners (crash: 'used after being disposed' +
  /// '_dependents.isEmpty'). Notifications stop; reads keep working; the
  /// notifier is GC'd together with its last listeners.
  void deactivateState() {
    _deactivated = true;
  }

  @override
  void notifyListeners() {
    if (_deactivated) return;
    super.notifyListeners();
  }

  /// `hasMore` from the latest conversationRowsRangeV4 response — the web
  /// store pages on this flag. Null until the first load-older runs (older
  /// builds fall back to the totalCount heuristic).
  bool? hasMore;

  void applyFrame(
    Map<String, dynamic> frame, {
    required void Function() onGap,
  }) {
    final payload = frame['payload'];
    if (payload is! Map) return;
    final toSeq = (frame['toSeq'] as num?)?.toInt() ?? seq;

    if (payload['kind'] == 'snapshot') {
      final snap = (payload['snapshot'] as Map).cast<String, dynamic>();
      _applySnapshot(snap, toSeq);
    } else if (payload['kind'] == 'deltas') {
      final fromSeq = (frame['fromSeq'] as num?)?.toInt() ?? seq;
      if (fromSeq != seq) {
        onGap();
        return;
      }
      final deltas = payload['deltas'];
      if (deltas is List) {
        for (final d in deltas) {
          if (d is Map) _applyDelta(d.cast<String, dynamic>());
        }
      }
      seq = toSeq;
    }
    ready = true;
    notifyListeners();
  }

  void _applySnapshot(Map<String, dynamic> snap, int toSeq) {
    snapshot = snap;
    _usageEvent = null;
    if (_pendingPatch != null) {
      snapshot = {...snap, ..._pendingPatch!};
      _pendingPatch = null;
    }
    seq = toSeq;
    logEpoch = snap['logEpoch'] as String?;
    final rowsObj = snap['rows'];
    if (rowsObj is Map) {
      final window = rowsObj['window'];
      rows = window is List
          ? window
                .whereType<Map>()
                .map((e) => e.cast<String, dynamic>())
                .toList()
          : [];
      totalCount = (rowsObj['totalCount'] as num?)?.toInt() ?? rows.length;
      firstRowId = (rowsObj['firstRowId'] as num?)?.toInt() ??
          (rows.isNotEmpty ? (rows.first['rowId'] as num?)?.toInt() : null);
    } else {
      rows = [];
      totalCount = 0;
      firstRowId = null;
    }
  }

  void _applyDelta(Map<String, dynamic> delta) {
    switch (delta['op']) {
      case 'row.appended':
        final row = (delta['row'] as Map).cast<String, dynamic>();
        rows.add(row);
        totalCount += 1;
        firstRowId ??= (row['rowId'] as num?)?.toInt();
        break;
      case 'row.upserted':
        final row = (delta['row'] as Map).cast<String, dynamic>();
        final id = (row['rowId'] as num?)?.toInt();
        final index = rows.indexWhere(
          (r) => (r['rowId'] as num?)?.toInt() == id,
        );
        if (index != -1) rows[index] = row;
        break;
      case 'row.removed':
        // Mirrors `fke()` in the web client: KEEP rows with
        // rowId < fromRowId (i.e. remove rows >= fromRowId).
        final fromRowId = (delta['fromRowId'] as num?)?.toInt() ?? 0;
        final kept = rows
            .where((r) => ((r['rowId'] as num?)?.toInt() ?? 0) < fromRowId)
            .toList();
        final removed = rows.length - kept.length;
        rows = kept;
        if (firstRowId != null && fromRowId <= firstRowId!) {
          totalCount = 0;
          firstRowId = null;
        } else {
          totalCount = (totalCount - removed).clamp(0, 1 << 31);
        }
        break;
      case 'row.delta':
        final rowId = (delta['rowId'] as num?)?.toInt();
        final path = delta['path'] as String?;
        final append = delta['append'] as String? ?? '';
        final index = rows.indexWhere(
          (r) => (r['rowId'] as num?)?.toInt() == rowId,
        );
        if (index != -1) {
          rows[index] = _appendToRow(rows[index], path, append);
        }
        break;
      case 'state.updated':
        final patch = delta['patch'];
        if (patch is Map) {
          if (snapshot != null) {
            snapshot = {...snapshot!, ...patch.cast<String, dynamic>()};
          } else {
            // Patch arrived before the initial snapshot — buffer and
            // merge when the snapshot lands (otherwise config/queue/
            // control updates are silently lost).
            _pendingPatch = {
              ...?_pendingPatch,
              ...patch.cast<String, dynamic>(),
            };
          }
        }
        break;
    }
  }

  Map<String, dynamic>? _pendingPatch;

  /// Optimistic local update (command already accepted; the confirming
  /// `state.updated` frame may lag). Merges into snapshot immediately.
  void optimisticPatch(Map<String, dynamic> patch) {
    if (snapshot == null) return;
    snapshot = {...snapshot!, ...patch};
    notifyListeners();
  }

  /// Optimistic row edit (e.g. feedback) — mutates the row in place and
  /// notifies; the server row.upserted will confirm.
  void optimisticRowUpdate(num? rowId, Map<String, dynamic> patch) {
    final index = rows.indexWhere(
      (r) => (r['rowId'] as num?)?.toInt() == rowId?.toInt(),
    );
    if (index == -1) return;
    rows[index] = {...rows[index], ...patch};
    notifyListeners();
  }

  /// Optimistic queue removal (sendQueuedNow / deleteQueueItem accepted).
  void optimisticRemoveQueueItem(String queueItemId) {
    final q = queue;
    if (q == null) return;
    final items = (q['items'] as List?)
        ?.where((i) => i is Map && '${i['queueItemId']}' != queueItemId)
        .toList();
    snapshot = {
      ...snapshot!,
      'queue': {...q, 'items': items ?? []},
    };
    notifyListeners();
  }

  /// Mirrors `dke()`: append streamed text to a row field.
  Map<String, dynamic> _appendToRow(
    Map<String, dynamic> row,
    String? path,
    String append,
  ) {
    switch (path) {
      case 'text':
        if (row['kind'] == 'assistantText' || row['kind'] == 'reasoning') {
          return {...row, 'text': '${row['text'] ?? ''}$append'};
        }
        return row;
      case 'inputText':
        if (row['kind'] == 'toolCall') {
          return {...row, 'inputText': '${row['inputText'] ?? ''}$append'};
        }
        return row;
      case 'output.text':
        if (row['kind'] == 'toolCall' && row['output'] is Map) {
          final output = (row['output'] as Map).cast<String, dynamic>();
          return {
            ...row,
            'output': {...output, 'text': '${output['text'] ?? ''}$append'},
          };
        }
        return row;
      case 'summaryText':
        if (row['kind'] == 'subagent') {
          return {...row, 'summaryText': '${row['summaryText'] ?? ''}$append'};
        }
        return row;
      default:
        return row;
    }
  }

  Map<String, dynamic>? get control =>
      (snapshot?['control'] as Map?)?.cast<String, dynamic>();

  /// Current conversation revision (CAS commands base this on).
  int get revision => (snapshot?['revision'] as num?)?.toInt() ?? 0;

  String get phase => control?['phase'] as String? ?? '';

  bool get canStop => control?['canStop'] == true;

  bool get isRunning => phase == 'running' || phase == 'prewarming';

  /// Session config: {provider, model, thought, thoughtLevels, followupMode,
  /// mode}.
  Map<String, dynamic>? get config =>
      (snapshot?['config'] as Map?)?.cast<String, dynamic>();

  String get currentModel => config?['model'] as String? ?? '';
  String get currentThought => config?['thought'] as String? ?? '';
  String get currentMode => config?['mode'] as String? ?? 'build';
  List<String> get thoughtLevels => config?['thoughtLevels'] is List
      ? (config!['thoughtLevels'] as List).map((e) => '$e').toList()
      : const [];

  /// Held queue: {items: [...], autoDrain}.
  Map<String, dynamic>? get queue =>
      (snapshot?['queue'] as Map?)?.cast<String, dynamic>();

  List<Map<String, dynamic>> get queueItems {
    final items = queue?['items'];
    if (items is! List) return const [];
    return items
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
  }

  bool get autoDrain => queue?['autoDrain'] != false;

  /// Usage pushed by the `usage_update` task-stream event (whitelist
  /// parsed, see [applyUsageUpdate]). Reset on every snapshot re-apply so
  /// a fresh authoritative snapshot is never shadowed by stale merges.
  Map<String, dynamic>? _usageEvent;

  /// Token usage — the single UI exit for context/cumulative numbers.
  /// Two schemas coexist by design: the snapshot's
  /// `{contextWindow: {usedTokens, maxTokens, cache: {hitRate, …},
  /// breakdown: […]}, cumulative: {…}}` (live-updated by state.updated
  /// patches on 3.11.2 desktops) and the event's
  /// `{size, used, cost, cache, breakdown}`. Event fields win, snapshot
  /// fields fill the gaps (research「关系」节 strategy); read the
  /// normalized view from [contextUsage].
  Map<String, dynamic>? get usage {
    final snap = snapshot?['usage'];
    final base = snap is Map ? snap.cast<String, dynamic>() : null;
    final event = _usageEvent;
    if (event == null || event.isEmpty) return base;
    if (base == null) return event;
    return {...base, ...event};
  }

  /// Applies one `usage_update` task-stream event
  /// (`{type: 'usage_update', size, used, cost, cache?, breakdown?}`),
  /// whitelist-parsed and defensively read: any missing/invalid field is
  /// simply absent and falls back to the snapshot in [usage]. Mirrors the
  /// official reducer's guards: an update without a usable `used` never
  /// clobbers current usage, and an update lacking a breakdown keeps the
  /// previous one while used/size are unchanged.
  void applyUsageUpdate(Map<String, dynamic> event) {
    final parsed = _parseUsageUpdate(event);
    if (parsed.isEmpty) return;
    final current = usage;
    final currentUsed = _finiteNum(current?['used']);
    final currentSize = _finiteNum(current?['size']);
    final incomingUsed = _finiteNum(parsed['used']);
    if (currentUsed != null &&
        currentUsed > 0 &&
        currentSize != null &&
        currentSize > 0 &&
        (incomingUsed == null || incomingUsed <= 0)) {
      return; // official s0t: keep the valid current usage intact
    }
    if (!parsed.containsKey('breakdown') && current != null) {
      final prev = current['breakdown'];
      if (prev != null &&
          _finiteNum(current['used']) == parsed['used'] &&
          _finiteNum(current['size']) == parsed['size']) {
        parsed['breakdown'] = prev;
      }
    }
    _usageEvent = parsed;
    notifyListeners();
  }

  /// Whitelist parser for one `usage_update` event. `cost` is parsed but
  /// never rendered (PRD R7); `size`/`used` must be finite and positive
  /// (the official renderer hides usage at <= 0); `cache` reduces to
  /// `{hitRate}`; breakdown entries need a string `source` and finite
  /// `chars` (<= 0 entries are dropped later in [contextUsage]).
  static Map<String, dynamic> _parseUsageUpdate(Map<String, dynamic> event) {
    final out = <String, dynamic>{};
    final size = _finiteNum(event['size']);
    if (size != null && size > 0) out['size'] = size;
    final used = _finiteNum(event['used']);
    if (used != null && used > 0) out['used'] = used;
    final cost = _finiteNum(event['cost']);
    if (cost != null) out['cost'] = cost;
    final cache = event['cache'];
    if (cache is Map) {
      final hitRate = _finiteNum(cache['hitRate']);
      if (hitRate != null) out['cache'] = {'hitRate': hitRate};
    }
    final breakdown = event['breakdown'];
    if (breakdown is List) {
      final items = [
        for (final e in breakdown)
          if (e is Map &&
              e['source'] is String &&
              (_finiteNum(e['chars']) ?? 0) > 0)
            {'chars': _finiteNum(e['chars']), 'source': e['source']},
      ];
      if (items.isNotEmpty) out['breakdown'] = items;
    }
    return out;
  }

  static num? _finiteNum(Object? value) =>
      value is num && value.isFinite ? value : null;

  /// Official breakdown weight order (bundle `AI`): primary sort is chars
  /// descending, ties break by this table; unknown sources trail in
  /// first-seen order.
  static const _breakdownWeights = {
    'messages': 0,
    'system_prompt': 1,
    'meta_user_context': 2,
    'skills': 3,
    'tool_prompt': 4,
    'system_tool_schemas': 5,
    'mcp_tool_schemas': 6,
  };

  /// Normalized context-usage projection for the UI (usage sheet + ring):
  /// used/max from event or snapshot, cache hit rate, and the aggregated
  /// breakdown (per-source chars summed, <= 0 dropped, chars descending
  /// with the official weight tie-break, percent of the retained total).
  ContextUsageView get contextUsage {
    final usage = this.usage;
    final window = usage?['contextWindow'];
    final used = _finiteNum(usage?['used']) ??
        (window is Map ? _finiteNum(window['usedTokens']) : null);
    final max = _finiteNum(usage?['size']) ??
        (window is Map ? _finiteNum(window['maxTokens']) : null);
    // 3.11.2 desktops ship cache/breakdown inside the snapshot's
    // contextWindow (live-merged via state.updated patches); the flat
    // event shape only arrives where the task-stream broadcast exists.
    final cache = usage?['cache'] ?? (window is Map ? window['cache'] : null);
    final hitRate = cache is Map ? _finiteNum(cache['hitRate']) : null;

    final items = <ContextUsageBreakdownItem>[];
    final breakdown =
        usage?['breakdown'] ?? (window is Map ? window['breakdown'] : null);
    if (breakdown is List) {
      // Aggregate per source (official AZe), then rank: known sources by
      // the weight table, unknown ones after them in first-seen order.
      final bySource = <String, num>{};
      for (final e in breakdown) {
        if (e is! Map) continue;
        final source = e['source'];
        final chars = _finiteNum(e['chars']);
        if (source is! String || chars == null || chars <= 0) continue;
        bySource[source] = (bySource[source] ?? 0) + chars;
      }
      final total = bySource.values.fold<num>(0, (a, b) => a + b);
      final ranks = {
        for (final source in bySource.keys)
          source: _breakdownWeights[source] ??
              _breakdownWeights.length + bySource.keys.toList().indexOf(source),
      };
      if (total > 0) {
        final entries = bySource.entries.toList()
          ..sort((a, b) {
            final byChars = b.value.compareTo(a.value);
            if (byChars != 0) return byChars;
            return ranks[a.key]!.compareTo(ranks[b.key]!);
          });
        for (final e in entries) {
          items.add(
            ContextUsageBreakdownItem(
              source: e.key,
              chars: e.value,
              percent: e.value / total,
            ),
          );
        }
      }
    }
    return ContextUsageView(
      used: used?.toInt(),
      max: max?.toInt(),
      hitRate: hitRate?.toDouble().clamp(0.0, double.infinity).toDouble(),
      breakdown: items,
    );
  }

  /// Older history exists beyond the current window. Prefers the server's
  /// `hasMore` (web parity) once known; falls back to the totalCount
  /// heuristic for the initial state.
  bool get canLoadOlder {
    if (firstRowId == null) return false;
    if (hasMore != null) return hasMore! && rows.isNotEmpty;
    return totalCount > rows.length;
  }

  /// Oldest row actually held — the rowsRange paging cursor. Snapshot
  /// `firstRowId` can be a placeholder (live-probed 1), so「加载更早」and
  /// the subagent sheet page back from this value instead.
  int? get oldestRowId {
    int? oldest;
    for (final r in rows) {
      final id = (r['rowId'] as num?)?.toInt();
      if (id != null && (oldest == null || id < oldest)) oldest = id;
    }
    return oldest;
  }

  /// Applies a conversationRowsRangeV4 response envelope: the web store
  /// drops the result when its log epoch no longer matches the live
  /// subscription, and pages on `hasMore`.
  bool rangeEnvelopeMatches(String? atLogEpoch) =>
      atLogEpoch == null || atLogEpoch == logEpoch;

  /// Prepends older rows loaded via rowsRange (deduped by rowId).
  ///
  /// The new cursor is the smallest ACTUALLY prepended rowId. Snapshot and
  /// response `firstRowId` can be a placeholder (live-probed 1 while real
  /// rows start far higher) — trusting it rewound the paging cursor and
  /// broke the second「加载更早」page, so the response value is ignored
  /// here; callers derive the request cursor from the held rows too.
  /// No fresh rows → no cursor write: the response carries no new evidence.
  void prependOlderRows(List<Map<String, dynamic>> older) {
    final existing = rows.map((r) => (r['rowId'] as num?)?.toInt()).toSet();
    final fresh = older
        .where((r) => !existing.contains((r['rowId'] as num?)?.toInt()))
        .toList();
    if (fresh.isEmpty) return;
    int? firstFresh;
    for (final r in fresh) {
      final id = (r['rowId'] as num?)?.toInt();
      if (id != null && (firstFresh == null || id < firstFresh)) {
        firstFresh = id;
      }
    }
    rows = [...fresh, ...rows];
    if (firstFresh != null) firstRowId = firstFresh;
    notifyListeners();
  }

  List<Map<String, dynamic>> get backgroundWorks {
    final list = snapshot?['backgroundWorks'];
    if (list is! List) return const [];
    return list.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  /// `subagents` typed: {revision, childSessionIds, running, endedTotal}.
  /// `running` entries carry childSessionId/agentId/toolCallId/subagentType/
  /// title/status/startedAt (live-probed 2026-09-13, see
  /// tasks/internal-task research).
  Map<String, dynamic>? get subagentsInfo =>
      (snapshot?['subagents'] as Map?)?.cast<String, dynamic>();

  Map<String, dynamic>? get goal =>
      (snapshot?['goal'] as Map?)?.cast<String, dynamic>();

  Map<String, dynamic>? get plan =>
      (snapshot?['plan'] as Map?)?.cast<String, dynamic>();

  /// inputRouting: {mode: startNow|enqueue|guide|reject|choice, reasonCode?}
  String get inputRoutingMode =>
      (snapshot?['inputRouting'] as Map?)?['mode'] as String? ?? 'startNow';

  /// Pending interaction cards, two wire forms:
  /// - full interaction list (online `state.updated` deltas) — the snapshot
  ///   field is a List and is authoritative as-is;
  /// - summary count object `{permissionCount, userInputCount}` — the 3.12.3
  ///   snapshot assembly only projects the summary (session overlay),
  ///   so after a resubscribe the cards are rebuilt from the held rows
  ///   instead ([_rebuildPendingAskUserQuestions]).
  List<Map<String, dynamic>> get pendingInteractions {
    final list = snapshot?['pendingInteractions'];
    if (list is List) {
      return list
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    }
    return _rebuildPendingAskUserQuestions();
  }

  /// Rebuilds pending AskUserQuestion interactions from the held rows.
  ///
  /// Mirrors the agent core `onPermissionRequested`: a tool call row waiting
  /// on the user carries `status:'pendingApproval'` plus
  /// `approvalInteractionId` — the resolveInteraction id, derived
  /// server-side as `requestId ?? 'perm-${toolCallId}'` — and the questions
  /// travel in the row's `input`. The id is cleared (and the interaction
  /// settled) server-side on resolve, so its presence is the pending signal.
  /// Permission-kind interactions are not rebuilt: their option list is
  /// generated outside the row and cannot be recovered.
  List<Map<String, dynamic>> _rebuildPendingAskUserQuestions() {
    final rebuilt = <Map<String, dynamic>>[];
    for (final row in rows) {
      if (row['kind'] != 'toolCall') continue;
      final interactionId = row['approvalInteractionId'];
      if (interactionId is! String || interactionId.isEmpty) continue;
      if ('${row['toolName'] ?? ''}' != 'AskUserQuestion') continue;
      final input = row['input'] is Map
          ? (row['input'] as Map).cast<String, dynamic>()
          : const <String, dynamic>{};
      rebuilt.add({
        'interactionId': interactionId,
        'kind': 'userInput',
        'anchorRowId': row['rowId'],
        'createdAt': row['createdAt'],
        'payload': {
          'kind': 'userInput',
          'freeText': true,
          'toolCallId': '${row['toolCallId'] ?? ''}',
          'toolName': 'AskUserQuestion',
          'input': input,
          'questions': _askUserQuestionsFromInput(input),
        },
      });
    }
    return rebuilt;
  }

  /// Normalizes the tool input's `questions` into the payload form the card
  /// consumes (agent core `oIs`): drop entries without question text or
  /// options, fall back header→question and label↔value, keep the rest
  /// verbatim.
  List<Map<String, dynamic>> _askUserQuestionsFromInput(
    Map<String, dynamic> input,
  ) {
    final raw = input['questions'];
    if (raw is! List) return const [];
    final questions = <Map<String, dynamic>>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final question = '${entry['question'] ?? ''}';
      final options = (entry['options'] as List?)?.whereType<Map>().toList();
      if (question.isEmpty || options == null || options.isEmpty) continue;
      final header = '${entry['header'] ?? ''}';
      questions.add({
        'question': question,
        'header': header.isNotEmpty ? header : question,
        if (entry['multiSelect'] == true) 'multiSelect': true,
        'options': [
          for (final option in options)
            if (_normalizedQuestionOption(option) case final o?) o,
        ],
      });
    }
    return questions;
  }

  /// One option's `value`/`label` fallback pair; null when both are empty.
  Map<String, dynamic>? _normalizedQuestionOption(Map option) {
    final label = '${option['label'] ?? ''}';
    final value = '${option['value'] ?? ''}';
    if (label.isEmpty && value.isEmpty) return null;
    return {
      'value': value.isNotEmpty ? value : label,
      'label': label.isNotEmpty ? label : value,
      if (option['description'] is String) 'description': option['description'],
    };
  }
}

/// Normalized view over [ConversationState.usage] (snapshot + merged
/// `usage_update` events). `used`/`max` are null when absent/invalid; the
/// sheet hides the section unless `hasData`, mirroring the official
/// renderer (usage hidden at used/max <= 0).
class ContextUsageView {
  final int? used;
  final int? max;

  /// 0..1 when readable (clamped at 0 like the official formatter).
  final double? hitRate;
  final List<ContextUsageBreakdownItem> breakdown;

  const ContextUsageView({
    this.used,
    this.max,
    this.hitRate,
    this.breakdown = const [],
  });

  bool get hasData => used != null && max != null && max! > 0;

  double? get ratio {
    if (used == null || max == null || max! <= 0) return null;
    return (used! / max!).clamp(0.0, 1.0);
  }
}

/// One aggregated breakdown row (official AZe output shape).
class ContextUsageBreakdownItem {
  final String source;
  final num chars;

  /// Share of the retained breakdown total, 0..1.
  final double percent;

  const ContextUsageBreakdownItem({
    required this.source,
    required this.chars,
    required this.percent,
  });
}
