import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/protocol/conversation.dart';
import 'package:zlinker/state/device_session.dart';
import 'package:zlinker/state/entitlement_poller.dart';
import 'package:zlinker/state/quota_reset.dart';

/// `Symbol("name")` → `name`. noSuchMethod hands out symbols and Flutter
/// has no mirrors; the toString shape is the stable SDK contract.
String _symbolName(Symbol s) =>
    RegExp(r'^Symbol\("(.*)"\)$').firstMatch(s.toString())?.group(1) ?? '$s';

/// Records Conversation V4 commands and answers `accepted` — the loose
/// default so tests pay no interface-width tax. [RecordingChatGateway]'s
/// [ChatGateway.conversationCommands]; every call lands in the same
/// `calls` list the gateway records into.
///
/// Commands whose recorded shape tests assert on (createSession /
/// sendText / resolveInteraction) are overridden explicitly to keep the
/// historical FakeChatGateway recording shape; everything else falls
/// through to noSuchMethod.
class RecordingConversationTransport implements ConversationTransport {
  RecordingConversationTransport(this._accept, this._strictIsOn);

  /// Records (method, args) and returns the default `accepted` ack.
  final dynamic Function(String method, List<Object?> args) _accept;
  final bool Function() _strictIsOn;

  @override
  Future<String> createSession(
    String workspaceId, {
    String? firstText,
    List<Map<String, dynamic>>? attachments,
    Map<String, dynamic>? config,
    String? runtimeModel,
    List<String>? mcpServers,
    Duration timeout = const Duration(seconds: 90),
  }) async {
    _accept('createSession', [workspaceId, firstText, config]);
    return 'new-s1';
  }

  @override
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
  }) async {
    _accept('sendText', [sessionId, text, heldQueueDisposition]);
    // Dequeued front-first: an Exception/Error is thrown (replayable-queue
    // capture tests), anything else is returned.
    if (sendTextResults.isNotEmpty) {
      final next = sendTextResults.removeAt(0);
      if (next is Exception) throw next;
      if (next is Error) throw next;
      return next;
    }
    return const {'status': 'accepted'};
  }

  /// Programmed `sendText` answers, dequeued front-first (empty → accepted
  /// ack; an Exception/Error entry is thrown — bridge-level failure tests).
  final List<Object?> sendTextResults = [];

  @override
  Future<dynamic> resolveInteraction(
    String sessionId,
    String interactionId, {
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  }) async =>
      _accept('resolveInteraction', [
        sessionId,
        interactionId,
        optionId,
        content,
      ]);

  @override
  Future<Map<String, dynamic>> attachmentPut(
    String sessionId, {
    required String fileName,
    required String mime,
    required Uint8List bytes,
    void Function(double progress)? onProgress,
  }) async => {'ref': 'r1', 'fileName': fileName, 'mime': mime, 'bytes': 1};

  @override
  Future<({Uint8List bytes, String? mediaType})> attachmentRead(
    String sessionId, {
    required String ref,
  }) async => (bytes: Uint8List(0), mediaType: 'application/octet-stream');

  /// Programmed `rowsRange` answers, dequeued front-first per call
  /// (empty → plain accepted); load-older / management-sheet paging tests.
  final List<Object?> rowsRangeResults = [];

  @override
  Future<dynamic> rowsRange(
    String sessionId, {
    int? beforeRowId,
    int limit = 60,
  }) async {
    _accept('rowsRange', [sessionId, beforeRowId, limit]);
    if (rowsRangeResults.isEmpty) return {'status': 'accepted'};
    return rowsRangeResults.removeAt(0);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (_strictIsOn()) {
      throw UnimplementedError('unexpected ${invocation.memberName}');
    }
    return Future<Map<String, dynamic>>.value(
      Map<String, dynamic>.from(
        _accept(_symbolName(invocation.memberName),
            [...invocation.positionalArguments]) as Map,
      ),
    );
  }
}

/// Shared loose-default chat gateway fake: subscribes answer from a real
/// [ConversationState] fed by hand ([feedSnapshot]); every command is
/// recorded into [calls] and answered `accepted` via noSuchMethod — tests
/// configure fields and assert on [calls] instead of overriding methods.
///
/// [strict] flips the default: unexpected members throw. ONLY for
/// negative assertions ("no command must be sent"); opt in explicitly and
/// name the test with a `[strict]` prefix.
class RecordingChatGateway extends ChangeNotifier implements ChatGateway {
  @override
  DeviceStatus status = DeviceStatus.connected;
  @override
  bool kicked = false;
  @override
  String? error;

  /// Every recorded call as (method, positionalArgs).
  final List<(String, List<Object?>)> calls = [];

  /// Strict mode — see the class doc. Do not flip in assertion tests.
  bool strict = false;

  final ConversationState state = ConversationState();

  /// Session ids handed out by [subscribe] / whose handle was closed
  /// (SubagentFeed refcount checks).
  final List<String> subscribedSessions = [];
  final List<String> closedSessions = [];

  /// When set, [subscribe] throws with it (retry-banner tests).
  Object Function(String method)? failSubscribeWith;

  /// Per-child-session states handed out by [subscribe]; unlisted ids fall
  /// back to the parent [state].
  final Map<String, ConversationState> childStates = {};

  /// Extra snapshot fields merged into every feed (queue, interactions...).
  Map<String, dynamic> snapshotExtra = const {};

  /// Plan-quota snapshot programming. Default hides quota data
  /// (notConfigured → no data in the chat).
  EntitlementView entitlementResult =
      const EntitlementView(phase: EntitlementPhase.notConfigured);
  int entitlementCalls = 0;

  /// Raw `getCodingPlanResetStatus` answer (null → no usable data); use
  /// failures throw [useQuotaError].
  Map<String, dynamic>? quotaStatusResult;
  int quotaStatusCalls = 0;
  Object? useQuotaError;
  final List<(String, String?, String)> useQuotaCalls = [];

  QuotaResetController? _quotaReset;

  @override
  QuotaResetController get quotaResetController =>
      _quotaReset ??= QuotaResetController(gateway: this);

  @override
  ConversationTransport get conversationCommands => _commands;

  /// Injectable replayable-command queue (set for queue-bar / send-failure
  /// tests; null = pre-3.12.3 desktop, the page must not queue).
  @override
  ReplayableCommandQueue? replayableQueue;

  /// One persistent transport per gateway — programmed answers (e.g.
  /// [rowsRangeResults]) must survive across [conversationCommands] accesses.
  late final RecordingConversationTransport _commands =
      RecordingConversationTransport(_accept, () => strict);

  /// Programmed `conversationRowsRangeV4` answers, dequeued front-first per
  /// call (empty → plain accepted); load-older / management-sheet paging
  /// tests program this on the gateway.
  List<Object?> get rowsRangeResults => _commands.rowsRangeResults;

  /// Programmed `sendText` answers (see the transport's field): an
  /// Exception/Error entry is thrown — replayable-queue capture tests.
  List<Object?> get sendTextResults => _commands.sendTextResults;

  /// Records (method, args) and returns the default `accepted` ack.
  dynamic _accept(String method, [List<Object?> args = const []]) {
    calls.add((method, args));
    return const {'status': 'accepted'};
  }

  /// Feeds a snapshot frame into [state] — the real ConversationState
  /// frame-injection mechanism (through-the-interface test quality).
  void feedSnapshot(
    List<Map<String, dynamic>> rows, {
    int? firstRowId,
    int? totalCount,
  }) {
    state.applyFrame({
      'toSeq': state.seq + 1,
      'payload': {
        'kind': 'snapshot',
        'snapshot': {
          'sessionId': 's1',
          'logEpoch': 'e1',
          'revision': 3,
          'rows': {
            'window': rows,
            'totalCount': totalCount ?? rows.length,
            'firstRowId': firstRowId,
          },
          ...snapshotExtra,
        },
      },
    }, onGap: () => fail('unexpected gap'));
  }

  @override
  Future<ChatHandle> subscribe(String sessionId) async {
    subscribedSessions.add(sessionId);
    final fail = failSubscribeWith;
    if (fail != null) throw fail('subscribe');
    return ChatHandle(
      state: childStates[sessionId] ?? state,
      close: () async => closedSessions.add(sessionId),
    );
  }

  @override
  Future<WorkspacePrep> prepareWorkspace() async =>
      WorkspacePrep.fromMap(const {
        'configOptions': [
          {
            'id': 'model',
            'name': '模型',
            'currentValue': 'builtin/glm-5.2',
            'options': [
              {'value': 'builtin/glm-5.2', 'name': 'GLM-5.2'},
              {'value': 'builtin/glm-5.2-air', 'name': 'GLM-5.2 Air'},
            ],
          },
          {
            'id': 'thought_level',
            'name': '思考等级',
            'currentValue': 'enabled',
            'options': [
              {'value': 'enabled', 'name': '开启'},
              {'value': 'off', 'name': '关闭'},
            ],
          },
        ],
        'slashCommands': [
          {'name': 'compact', 'description': '压缩上下文'},
        ],
      });

  @override
  Future<List<SkillEntry>> skills() async => const [];

  @override
  String? chatWorkspaceId = 'ws-1';
  @override
  String? workspacePath = '/repo/app';
  @override
  String? remoteUrl =
      'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1&name=demo';

  @override
  Future<void> reconnect() async => _accept('reconnect');

  @override
  Future<EntitlementView> entitlementSnapshot({bool force = false}) async {
    entitlementCalls++;
    // Mirrors the real session's entitlementSnapshot: the reset scope
    // rides the snapshot, injected by the gateway itself (design Q2a).
    quotaResetController.updateScope(entitlementResult.resetScopeProviderId);
    return entitlementResult;
  }

  @override
  Future<Object?> quotaResetStatus({bool force = false}) async {
    quotaStatusCalls++;
    return quotaStatusResult;
  }

  @override
  Future<void> useQuotaReset(
    String resetType,
    String idempotencyKey, {
    String? preferredProviderId,
  }) async {
    useQuotaCalls.add((resetType, preferredProviderId, idempotencyKey));
    final err = useQuotaError;
    if (err != null) throw err;
  }

  List<Map<String, dynamic>> mentionFilesResult = const [];
  List<Map<String, dynamic>> mentionSubagentsResult = const [];
  List<Map<String, dynamic>> mentionSkillsResult = const [];
  List<({String id, String title})> mentionSessionsResult = const [];

  @override
  Future<List<Map<String, dynamic>>> mentionFiles() async =>
      mentionFilesResult;

  @override
  Future<List<Map<String, dynamic>>> mentionSkills() async =>
      mentionSkillsResult;

  @override
  Future<List<Map<String, dynamic>>> mentionSubagents() async =>
      mentionSubagentsResult;

  @override
  List<({String id, String title})> mentionSessions() =>
      mentionSessionsResult;

  @override
  List<Map<String, dynamic>> mentionSkillsSync() => mentionSkillsResult;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (strict) {
      throw UnimplementedError('unexpected ${invocation.memberName}');
    }
    return Future<Map<String, dynamic>>.value(
      Map<String, dynamic>.from(
        _accept(_symbolName(invocation.memberName),
            [...invocation.positionalArguments]) as Map,
      ),
    );
  }
}
