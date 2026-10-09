import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/protocol/file_service.dart';
import 'package:zgo/protocol/git_service.dart';
import 'package:zgo/state/device_session.dart';
import 'package:zgo/state/entitlement_poller.dart';
import 'package:zgo/state/quota_reset.dart';

/// `Symbol("name")` → `name`. noSuchMethod hands out symbols and Flutter
/// has no reflection; the toString shape is the stable SDK contract.
String _symbolName(Symbol s) =>
    RegExp(r'^Symbol\("(.*)"\)$').firstMatch(s.toString())?.group(1) ?? '$s';

/// Records Conversation V4 commands and answers `accepted` — the loose
/// default so tests pay no interface-width tax. [RecordingChatGateway]'s
/// [ChatGateway.conversationCommands]; every call lands in the same
/// `calls` list the gateway records into.
///
/// Commands whose recorded shape tests assert on (createSession /
/// sendTextOrQueue / resolveInteraction) are overridden explicitly to keep
/// the historical FakeChatGateway recording shape; everything else falls
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

  /// Programmed [sendTextOrQueue] results, dequeued front-first (empty →
  /// `SendTextResult.sent` with the default accepted ack). The chat page
  /// consumes typed results, so send-path tests program at the result
  /// level — e.g. `SendTextResult.queued(item)` with an item from the
  /// gateway's injected replayable queue (queue-bar smoke).
  final List<SendTextResult> sendTextOrQueueResults = [];

  @override
  Future<SendTextResult> sendTextOrQueue(
    String sessionId,
    String text, {
    List<Map<String, dynamic>>? attachments,
    String? heldQueueDisposition,
  }) async {
    _accept('sendTextOrQueue', [sessionId, text, heldQueueDisposition]);
    if (sendTextOrQueueResults.isNotEmpty) {
      return sendTextOrQueueResults.removeAt(0);
    }
    return SendTextResult.sent(const {'status': 'accepted'});
  }

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
        // Questions-submit path asserts the explicit accept action.
        action,
      ]);

  /// Programmed `forkAssistant` acks, dequeued front-per-call (empty →
  /// plain accepted). The fork-jump tests (10-05 C1) program the ack union
  /// `{status, result:{type:'forkAssistant', sessionId}}`; an Exception
  /// entry is thrown (the busy rejection arrives as a thrown
  /// ChannelRpcError, research-emulator.md「busy 之谜」).
  final List<Object?> forkAssistantResults = [];

  @override
  Future<dynamic> forkAssistant(
    String sessionId,
    Map<String, dynamic> target,
  ) async {
    _accept('forkAssistant', [sessionId, target]);
    if (forkAssistantResults.isNotEmpty) {
      final next = forkAssistantResults.removeAt(0);
      if (next is Exception) throw next;
      return next;
    }
    return const {'status': 'accepted'};
  }

  /// Programmed `createSelectionSideSession` answers, dequeued front-per-call
  /// (empty → the default `sess_side`). Entries are sessionId strings; an
  /// Exception entry is thrown (the rejected/guard shape arrives as a thrown
  /// StateError). The recorded call carries
  /// `[parentSessionId, firstText, modelSelection]` — the side-chat UI tests
  /// assert the direct-ask wire shape here.
  final List<Object?> createSelectionSideSessionResults = [];

  @override
  Future<String> createSelectionSideSession(
    String parentSessionId, {
    String? firstText,
    Map<String, dynamic>? modelSelection,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    _accept('createSelectionSideSession', [
      parentSessionId,
      firstText,
      modelSelection,
    ]);
    if (createSelectionSideSessionResults.isNotEmpty) {
      final next = createSelectionSideSessionResults.removeAt(0);
      if (next is String) return next;
      // Anything non-String is the failure cue (a thrown StateError — an
      // Error, not an Exception — or any other object).
      throw next ?? StateError('createSelectionSideSession: null answer');
    }
    return 'sess_side';
  }

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

  /// Cross-terminal deletion tombstones (10-06): the page reads this set
  /// through [isSessionDeleted]. Explicit overrides — the loose
  /// noSuchMethod fallback returns a Future, which a bool member cannot be.
  final Set<String> deletedSessionIds = {};

  /// Ids handed to [forgetDeletedSession] (the page's dispose recovery).
  final List<String> forgottenSessions = [];

  @override
  bool isSessionDeleted(String sessionId) =>
      deletedSessionIds.contains(sessionId);

  @override
  void forgetDeletedSession(String sessionId) {
    forgottenSessions.add(sessionId);
    deletedSessionIds.remove(sessionId);
  }

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

  /// Programmed [ConversationTransport.sendTextOrQueue] results (see the
  /// transport's field) — send-path tests program at the result level.
  List<SendTextResult> get sendTextOrQueueResults =>
      _commands.sendTextOrQueueResults;

  /// Programmed [ConversationTransport.forkAssistant] acks (see the
  /// transport's field) — fork-jump tests program at the ack level.
  List<Object?> get forkAssistantResults => _commands.forkAssistantResults;

  /// Programmed [ConversationTransport.createSelectionSideSession] answers
  /// (see the transport's field) — side-chat tests program sessionId strings
  /// (or Exceptions) here.
  List<Object?> get createSelectionSideSessionResults =>
      _commands.createSelectionSideSessionResults;

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

  /// Programmed [ChatGateway.modelProviderCatalog] fallback catalog (the
  /// chat config sheet's model-provider fallback, PRD 09-19); empty
  /// default keeps the sheet's degraded text.
  List<Map<String, dynamic>> modelProviderCatalogResult = const [];
  int modelProviderCatalogCalls = 0;

  @override
  Future<List<Map<String, dynamic>>> modelProviderCatalog() async {
    modelProviderCatalogCalls++;
    return modelProviderCatalogResult;
  }

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
    // Like the real session's entitlementSnapshot: the reset scope
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

  List<Map<String, dynamic>> mentionSubagentsResult = const [];
  List<Map<String, dynamic>> mentionSkillsResult = const [];
  List<({String id, String title})> mentionSessionsResult = const [];

  @override
  Future<List<Map<String, dynamic>>> mentionSkills() async =>
      mentionSkillsResult;

  @override
  Future<List<Map<String, dynamic>>> mentionSubagents() async =>
      mentionSubagentsResult;

  @override
  List<({String id, String title})> mentionSessions() =>
      mentionSessionsResult;

  /// Programmed [ChatGateway.searchWorkspaceFiles] answer; a non-null
  /// [searchWorkspaceFilesError] is thrown (the unreachable verdict the
  /// add-context panel hides the file section on).
  List<Map<String, dynamic>> searchWorkspaceFilesResult = const [];
  Object? searchWorkspaceFilesError;

  @override
  Future<List<Map<String, dynamic>>> searchWorkspaceFiles(
    String query, {
    int limit = 50,
  }) async {
    _accept('searchWorkspaceFiles', [query, limit]);
    final err = searchWorkspaceFilesError;
    if (err != null) throw err;
    return searchWorkspaceFilesResult;
  }

  /// Programmed [ChatGateway.workspaceFilesReachable] verdict.
  bool workspaceFilesReachableResult = true;

  @override
  Future<bool> workspaceFilesReachable() async {
    _accept('workspaceFilesReachable', const []);
    return workspaceFilesReachableResult;
  }

  /// Programmed file-service answers (file-preview tests); defaults are
  /// inert (file stat / zero bytes / empty text).
  FileStat fileStatResult = const FileStat(type: 'file', size: 0);
  MediaPreview fileReadMediaResult = MediaPreview(bytes: Uint8List(0));
  TextChunk fileReadTextResult = const TextChunk(text: '');

  @override
  Future<FileStat> fileStat(String workspacePath, String path) async {
    _accept('fileStat', [workspacePath, path]);
    return fileStatResult;
  }

  @override
  Future<MediaPreview> fileReadMedia(String workspacePath, String path,
      {int? maxBytes}) async {
    _accept('fileReadMedia', [workspacePath, path, maxBytes]);
    return fileReadMediaResult;
  }

  @override
  Future<TextChunk> fileReadText(String workspacePath, String path,
      {int offset = 0, required int length}) async {
    _accept('fileReadText', [workspacePath, path, offset, length]);
    return fileReadTextResult;
  }

  /// Optional per-method handler for the git port; null falls back to the
  /// inert defaults below (not-repository verdict → the Git group hides).
  Object? Function(String method, List<Object?> args)? gitCallHandler;

  /// Every (method, args) the git port sent — the Git group tests assert the
  /// probed candidate name and the write calls here.
  final List<(String, List<Object?>)> gitCalls = [];

  @override
  late final GitPort git = GitPort((method, args) async {
    gitCalls.add((method, args));
    final handler = gitCallHandler;
    if (handler != null) return handler(method, args);
    return switch (method) {
      'getRepositorySummary' ||
      'getWorkspaceRepositoryInfo' =>
        <String, Object?>{'kind': 'not-repository', 'isGitAvailable': true},
      'getChanges' || 'getStatus' => <Object?>[],
      'getLocalBranches' || 'listLocalBranches' => <String, Object?>{
          'branches': <Object?>[],
          'currentBranchName': null,
        },
      'refresh' => <String, Object?>{'summary': null},
      'getIdentity' => <String, Object?>{'userName': null, 'userEmail': null},
      _ => <String, Object?>{},
    };
  });

  /// Programmed [ChatGateway.taskDisplayStatus] answers keyed by sessionId
  /// (shell-session error card tests); unlisted ids = lookup miss → null.
  final Map<String, String> taskDisplayStatuses = {};

  @override
  String? taskDisplayStatus(String sessionId) =>
      taskDisplayStatuses[sessionId];

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
