import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/protocol/file_service.dart';
import 'package:zgo/protocol/git_service.dart';
import 'package:zgo/state/chat_draft_store.dart';
import 'package:zgo/state/device_session.dart';
import 'package:zgo/state/entitlement_poller.dart';
import 'package:zgo/state/quota_reset.dart';

/// `Symbol("name")` → `name`. noSuchMethod hands out symbols and Flutter
/// has no reflection; the toString shape is the stable SDK contract.
String _symbolName(Symbol s) =>
    RegExp(r'^Symbol\("(.*)"\)$').firstMatch(s.toString())?.group(1) ?? '$s';

/// Shared call recorder: one list per fixture, injected into every role
/// fake — assertions see one ordered stream regardless of which role
/// carried the call (the historical single-gateway shape, preserved).
class RecordingCalls {
  /// Every recorded call as (method, positionalArgs).
  final List<(String, List<Object?>)> calls = [];

  /// Strict mode — see [ChatGatewayBundle]. Do not flip in assertion tests.
  bool strict = false;

  /// Records (method, args) and returns the default `accepted` ack.
  dynamic accept(String method, [List<Object?> args = const []]) {
    calls.add((method, args));
    return const {'status': 'accepted'};
  }
}

/// Records Conversation V4 commands and answers `accepted` — the loose
/// default so tests pay no command-group tax. Shared by
/// [FakeConversation] and the bundle.
///
/// Commands whose recorded shape tests assert on (createSession /
/// sendTextOrQueue / resolveInteraction / forkAssistant /
/// createSelectionSideSession / rowsRange / attachments) are overridden
/// explicitly to keep the historical recording shape; everything else
/// falls through to noSuchMethod (out of scope for this narrowing — the
/// command group itself is a protocol surface, task
/// 10-29-conversation-commands-grouping).
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
  /// plain accepted). The fork-jump tests program the ack union
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
  /// Exception entry is thrown. The recorded call carries
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

/// Workspace-file port fake ([WorkspaceContextPort.fileService]): the four
/// typed programming fields tests drive, recorded under the legacy `file*`
/// method names the historical assertions use. A subtype of the real port
/// (ADR-0008 rule i keeps the port as the role member); tests that need
/// scripted reads subclass this (chat_preview_read / file_entry_dispatch).
class RecordingFileServicePort extends FileServicePort {
  RecordingFileServicePort(this.recording) : super((_, __) async => {});

  final RecordingCalls recording;

  /// Programmed file-service answers; defaults are inert (file stat /
  /// zero bytes / empty text / empty range).
  FileStat fileStatResult = const FileStat(type: 'file', size: 0);
  MediaPreview fileReadMediaResult = MediaPreview(bytes: Uint8List(0));
  TextChunk fileReadTextResult = const TextChunk(text: '');
  FileRange fileReadRangeResult = FileRange(bytes: Uint8List(0));

  @override
  Future<FileStat> stat(String workspacePath, String path) async {
    recording.accept('fileStat', [workspacePath, path]);
    return fileStatResult;
  }

  @override
  Future<MediaPreview> readMedia(
    String workspacePath,
    String path, {
    int? maxBytes,
  }) async {
    recording.accept('fileReadMedia', [workspacePath, path, maxBytes]);
    return fileReadMediaResult;
  }

  @override
  Future<TextChunk> readText(
    String workspacePath,
    String path, {
    int offset = 0,
    required int length,
  }) async {
    recording.accept('fileReadText', [workspacePath, path, offset, length]);
    return fileReadTextResult;
  }

  @override
  Future<FileRange> readFileRange(
    String workspacePath,
    String path, {
    required int offset,
    required int length,
  }) async {
    recording.accept('fileReadRange', [workspacePath, path, offset, length]);
    return fileReadRangeResult;
  }
}

/// [SessionLinkPort] fake: live status flags plus the view-state/reconnect
/// recording. [Listenable] via [ChangeNotifier] (banner tests).
class FakeSessionLink extends ChangeNotifier implements SessionLinkPort {
  FakeSessionLink(this.recording);

  final RecordingCalls recording;

  @override
  DeviceStatus status = DeviceStatus.connected;
  @override
  bool kicked = false;
  @override
  String? error;
  @override
  String? remoteUrl =
      'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1&name=demo';

  @override
  void sendViewState({String? taskId}) =>
      recording.accept('sendViewState', [taskId]);

  @override
  Future<void> reconnect() async => recording.accept('reconnect');
}

/// [ConversationPort] fake: subscribes answer from a real
/// [ConversationState] fed by hand ([feedSnapshot]); commands are recorded
/// through the shared [RecordingConversationTransport]. [Listenable] via
/// [ChangeNotifier] (queue bar / page merge).
class FakeConversation extends ChangeNotifier implements ConversationPort {
  FakeConversation(this.recording);

  final RecordingCalls recording;

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

  /// Injectable replayable-command queue (set for queue-bar / send-failure
  /// tests; null = pre-3.12.3 desktop, the page must not queue).
  @override
  ReplayableCommandQueue? replayableQueue;

  /// Programmed [ensureDraftWorkspace] verdict + every target the chat page
  /// asked to verify (draft send guard, 2026-10-27). Typed since 2026-10-29:
  /// the page maps the result variant to copy directly.
  WorkspaceOpenResult ensureDraftWorkspaceResult =
      const WorkspaceOpenOpened();

  /// When set, [ensureDraftWorkspace] parks on this future — models the
  /// silent-stall window (bridge jitter) the first send must survive with
  /// a visible progress state.
  Completer<void>? ensureDraftWorkspaceGate;
  final List<String?> ensuredDraftWorkspaces = [];

  /// One persistent transport per fake — programmed answers (e.g.
  /// [rowsRangeResults]) must survive across [conversationCommands]
  /// accesses.
  late final RecordingConversationTransport _commands =
      RecordingConversationTransport(recording.accept, () => recording.strict);

  @override
  ConversationTransport get conversationCommands => _commands;

  /// Programmed `conversationRowsRangeV4` answers, dequeued front-first per
  /// call (empty → plain accepted); load-older / management-sheet paging
  /// tests program this on the gateway.
  List<Object?> get rowsRangeResults => _commands.rowsRangeResults;

  /// Programmed [ConversationTransport.sendTextOrQueue] results — send-path
  /// tests program at the result level.
  List<SendTextResult> get sendTextOrQueueResults =>
      _commands.sendTextOrQueueResults;

  /// Programmed [ConversationTransport.forkAssistant] acks — fork-jump
  /// tests program at the ack level.
  List<Object?> get forkAssistantResults => _commands.forkAssistantResults;

  /// Programmed [ConversationTransport.createSelectionSideSession] answers —
  /// side-chat tests program sessionId strings (or Exceptions) here.
  List<Object?> get createSelectionSideSessionResults =>
      _commands.createSelectionSideSessionResults;

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
  Future<WorkspaceOpenResult> ensureDraftWorkspace(
      String? workspacePath) async {
    ensuredDraftWorkspaces.add(workspacePath);
    final gate = ensureDraftWorkspaceGate;
    if (gate != null) await gate.future;
    return ensureDraftWorkspaceResult;
  }
}

/// [TaskMetaPort] fake: records every command and answers accepted (the
/// historical noSuchMethod default, made explicit).
class FakeTaskMeta implements TaskMetaPort {
  FakeTaskMeta(this.recording);

  final RecordingCalls recording;

  /// Programmed [deleteTask] acks, dequeued front-per-call (empty → plain
  /// accepted). An Exception/Error entry is thrown — the registry-resolve
  /// failure arrives as a thrown ChannelRpcError (`matches=0` shape).
  final List<Object?> deleteTaskResults = [];

  /// Programmed [taskDisplayStatus] answers keyed by sessionId
  /// (shell-session error card tests); unlisted ids = lookup miss → null.
  final Map<String, String> taskDisplayStatuses = {};

  @override
  Future<dynamic> renameTask(String sessionId, String title) async =>
      recording.accept('renameTask', [sessionId, title]);

  @override
  Future<dynamic> setTaskPinned(String sessionId, bool pinned) async =>
      recording.accept('setTaskPinned', [sessionId, pinned]);

  @override
  Future<dynamic> setTaskArchived(String sessionId, bool archived) async =>
      recording.accept('setTaskArchived', [sessionId, archived]);

  @override
  Future<dynamic> setTaskUnread(String sessionId, bool unread) async =>
      recording.accept('setTaskUnread', [sessionId, unread]);

  @override
  Future<dynamic> taskNativeSessionLogFile(String sessionId) async =>
      recording.accept('taskNativeSessionLogFile', [sessionId]);

  @override
  Future<dynamic> deleteTask(String sessionId) async {
    recording.accept('deleteTask', [sessionId]);
    if (deleteTaskResults.isNotEmpty) {
      final next = deleteTaskResults.removeAt(0);
      if (next is Exception) throw next;
      if (next is Error) throw next;
      return next;
    }
    return const {'status': 'accepted'};
  }

  @override
  String? taskDisplayStatus(String sessionId) =>
      taskDisplayStatuses[sessionId];
}

/// [WorkspaceContextPort] fake: ids/paths, the draft store, workspace prep,
/// the catalogs and @-mention sources, plus the real
/// [RecordingFileServicePort]. [mentionSkills] is parity-retained.
class FakeWorkspaceContext implements WorkspaceContextPort {
  FakeWorkspaceContext(this.recording);

  final RecordingCalls recording;

  @override
  String? chatWorkspaceId = 'ws-1';
  @override
  String? workspacePath = '/repo/app';

  /// Composer-draft store (design 10-20): default is a detached instance
  /// (no attachment root, SharedPreferences swallowed) — tests that care
  /// assign their own with mock prefs + a temp dir.
  @override
  ChatDraftStore chatDraftStore = ChatDraftStore(deviceId: 'rec');

  /// Programmed [modelProviderCatalog] fallback catalog (the chat config
  /// sheet's model-provider fallback, PRD 09-19); empty default keeps the
  /// sheet's degraded text.
  List<Map<String, dynamic>> modelProviderCatalogResult = const [];
  int modelProviderCatalogCalls = 0;

  /// Programmed [entitledProviderIds] answer. Null (default) = the
  /// provider-settings view is unreachable, so the model sheet shows
  /// every group — the pre-filter behavior all earlier sheet tests assume.
  Set<String>? entitledProviderIdsResult;

  /// Thrown by [entitledProviderIds] when set (the page must degrade to no
  /// filtering, PRD 10-24 §3).
  Object? entitledProviderIdsError;
  int entitledProviderIdsCalls = 0;

  /// Programmed [searchWorkspaceFiles] answer; a non-null
  /// [searchWorkspaceFilesError] is thrown (the unreachable verdict the
  /// add-context panel hides the file section on).
  List<Map<String, dynamic>> searchWorkspaceFilesResult = const [];
  Object? searchWorkspaceFilesError;

  /// Programmed [workspaceFilesReachable] verdict.
  bool workspaceFilesReachableResult = true;

  List<Map<String, dynamic>> mentionSubagentsResult = const [];
  List<Map<String, dynamic>> mentionSkillsResult = const [];
  List<({String id, String title})> mentionSessionsResult = const [];

  @override
  late FileServicePort fileService = RecordingFileServicePort(recording);

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
  Future<List<Map<String, dynamic>>> modelProviderCatalog() async {
    modelProviderCatalogCalls++;
    return modelProviderCatalogResult;
  }

  @override
  Future<Set<String>?> entitledProviderIds() async {
    entitledProviderIdsCalls++;
    final err = entitledProviderIdsError;
    if (err != null) throw err;
    return entitledProviderIdsResult;
  }

  @override
  Future<List<Map<String, dynamic>>> searchWorkspaceFiles(
    String query, {
    int limit = 50,
  }) async {
    recording.accept('searchWorkspaceFiles', [query, limit]);
    final err = searchWorkspaceFilesError;
    if (err != null) throw err;
    return searchWorkspaceFilesResult;
  }

  @override
  Future<bool> workspaceFilesReachable() async {
    recording.accept('workspaceFilesReachable', const []);
    return workspaceFilesReachableResult;
  }

  @override
  Future<List<Map<String, dynamic>>> mentionSkills() async =>
      mentionSkillsResult;

  @override
  Future<List<Map<String, dynamic>>> mentionSubagents() async =>
      mentionSubagentsResult;

  @override
  List<({String id, String title})> mentionSessions() =>
      mentionSessionsResult;
}

/// [SessionTruthPort] fake: the tombstone / missing-session sets the chat
/// page writes and reads. [Listenable] via [ChangeNotifier] (banner
/// rebuilds).
class FakeSessionTruth extends ChangeNotifier implements SessionTruthPort {
  FakeSessionTruth(this.recording);

  final RecordingCalls recording;

  /// Cross-terminal deletion tombstones (10-06).
  final Set<String> deletedSessionIds = {};

  /// Ids handed to [forgetDeletedSession] (the page's dispose recovery).
  final List<String> forgottenSessions = [];

  /// Authoritative subscribe refusals (10-11 sessionNotFound terminal).
  final Set<String> missingSessionIds = {};

  /// Ids handed to [forgetMissingSession] (the page's dispose recovery).
  final List<String> forgottenMissingSessions = [];

  @override
  bool isSessionDeleted(String sessionId) =>
      deletedSessionIds.contains(sessionId);

  @override
  void forgetDeletedSession(String sessionId) {
    forgottenSessions.add(sessionId);
    deletedSessionIds.remove(sessionId);
  }

  @override
  bool isSessionMissing(String sessionId) =>
      missingSessionIds.contains(sessionId);

  @override
  void forgetMissingSession(String sessionId) {
    forgottenMissingSessions.add(sessionId);
    missingSessionIds.remove(sessionId);
  }
}

/// [GitAccessPort] fake: the real [GitPort] over a recording call.
class FakeGitAccess implements GitAccessPort {
  FakeGitAccess(this.recording);

  final RecordingCalls recording;

  /// Optional per-method handler for the git port; null falls back to the
  /// inert defaults below (not-repository verdict → the Git group hides).
  Object? Function(String method, List<Object?> args)? gitCallHandler;

  /// Every (method, args) the git port sent — the Git group tests assert
  /// the probed candidate name and the write calls here.
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
}

/// [QuotaAccessPort] fake: the entitlement snapshot programming plus a real
/// [QuotaResetController] over an internal 3-member [QuotaResetGateway]
/// (same wiring as the historical recording gateway).
class FakeQuotaAccess implements QuotaAccessPort, QuotaResetGateway {
  FakeQuotaAccess(this.recording);

  final RecordingCalls recording;

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

  late final _FakeQuotaResetGateway _resetGateway =
      _FakeQuotaResetGateway(this);

  @override
  late final QuotaResetController quotaResetController =
      QuotaResetController(gateway: _resetGateway);

  @override
  Future<Object?> quotaResetStatus({bool force = false}) =>
      _resetGateway.quotaResetStatus(force: force);

  @override
  Future<void> useQuotaReset(
    String resetType,
    String idempotencyKey, {
    String? preferredProviderId,
  }) =>
      _resetGateway.useQuotaReset(
        resetType,
        idempotencyKey,
        preferredProviderId: preferredProviderId,
      );

  @override
  Future<EntitlementView> entitlementSnapshot({bool force = false}) async {
    entitlementCalls++;
    // Like the real session's entitlementSnapshot: the reset scope rides
    // the snapshot, injected by the gateway itself (design Q2a).
    quotaResetController.updateScope(entitlementResult.resetScopeProviderId);
    return entitlementResult;
  }
}

/// The internal [QuotaResetGateway] behind [FakeQuotaAccess]'s real
/// [QuotaResetController].
class _FakeQuotaResetGateway implements QuotaResetGateway {
  _FakeQuotaResetGateway(this.owner);

  final FakeQuotaAccess owner;

  @override
  Future<EntitlementView> entitlementSnapshot({bool force = false}) =>
      owner.entitlementSnapshot(force: force);

  @override
  Future<Object?> quotaResetStatus({bool force = false}) async {
    owner.quotaStatusCalls++;
    return owner.quotaStatusResult;
  }

  @override
  Future<void> useQuotaReset(
    String resetType,
    String idempotencyKey, {
    String? preferredProviderId,
  }) async {
    owner.useQuotaCalls.add((resetType, preferredProviderId, idempotencyKey));
    final err = owner.useQuotaError;
    if (err != null) throw err;
  }
}

/// Full-page fake: composes the seven role fakes behind the page boundary
/// ([ChatPageHost]) and keeps the historical programming surface (field
/// names + behavior) so existing page tests are unchanged. Extends
/// [ChangeNotifier] so the page's page-level listeners work.
///
/// [strict] flips the default for recorded commands: unexpected command
/// members throw. ONLY for negative assertions ("no command must be sent");
/// opt in explicitly and name the test with a `[strict]` prefix.
class ChatGatewayBundle extends ChangeNotifier
    implements ChatPageHost, QuotaResetGateway {
  ChatGatewayBundle() {
    link = FakeSessionLink(_recording);
    conversation = FakeConversation(_recording);
    taskMeta = FakeTaskMeta(_recording);
    workspaceContext = FakeWorkspaceContext(_recording);
    workspaceContext.fileService = RecordingFileServicePort(_recording);
    truth = FakeSessionTruth(_recording);
    gitAccess = FakeGitAccess(_recording);
    quota = FakeQuotaAccess(_recording);
  }

  final RecordingCalls _recording = RecordingCalls();

  /// The shared recorder — custom ports/transports created in tests splice
  /// into the same call stream.
  RecordingCalls get recording => _recording;

  late final FakeSessionLink link;
  late final FakeConversation conversation;
  late final FakeTaskMeta taskMeta;
  late final FakeWorkspaceContext workspaceContext;
  late final FakeSessionTruth truth;
  late final FakeGitAccess gitAccess;
  late final FakeQuotaAccess quota;

  // ------------------------------------------------------------ recording

  /// Every recorded call as (method, positionalArgs) — one stream across
  /// all roles.
  List<(String, List<Object?>)> get calls => _recording.calls;

  /// Strict mode — see the class doc. Do not flip in assertion tests.
  bool get strict => _recording.strict;
  set strict(bool value) => _recording.strict = value;

  // --------------------------------------------------------- link surface

  @override
  DeviceStatus get status => link.status;
  set status(DeviceStatus value) => link.status = value;

  @override
  bool get kicked => link.kicked;
  set kicked(bool value) => link.kicked = value;

  @override
  String? get error => link.error;
  set error(String? value) => link.error = value;

  @override
  String? get remoteUrl => link.remoteUrl;
  set remoteUrl(String? value) => link.remoteUrl = value;

  @override
  void sendViewState({String? taskId}) => link.sendViewState(taskId: taskId);

  @override
  Future<void> reconnect() => link.reconnect();

  // ------------------------------------------------- conversation surface

  @override
  ConversationCommands get conversationCommands =>
      conversation.conversationCommands;

  @override
  ReplayableCommandQueue? get replayableQueue => conversation.replayableQueue;
  set replayableQueue(ReplayableCommandQueue? value) =>
      conversation.replayableQueue = value;

  @override
  Future<ChatHandle> subscribe(String sessionId) =>
      conversation.subscribe(sessionId);

  @override
  Future<WorkspaceOpenResult> ensureDraftWorkspace(String? workspacePath) =>
      conversation.ensureDraftWorkspace(workspacePath);

  ConversationState get state => conversation.state;

  Map<String, dynamic> get snapshotExtra => conversation.snapshotExtra;
  set snapshotExtra(Map<String, dynamic> value) =>
      conversation.snapshotExtra = value;

  List<String> get subscribedSessions => conversation.subscribedSessions;
  List<String> get closedSessions => conversation.closedSessions;

  Object Function(String method)? get failSubscribeWith =>
      conversation.failSubscribeWith;
  set failSubscribeWith(Object Function(String method)? value) =>
      conversation.failSubscribeWith = value;

  Map<String, ConversationState> get childStates => conversation.childStates;

  void feedSnapshot(
    List<Map<String, dynamic>> rows, {
    int? firstRowId,
    int? totalCount,
  }) =>
      conversation.feedSnapshot(
        rows,
        firstRowId: firstRowId,
        totalCount: totalCount,
      );

  List<Object?> get rowsRangeResults => conversation.rowsRangeResults;
  List<SendTextResult> get sendTextOrQueueResults =>
      conversation.sendTextOrQueueResults;
  List<Object?> get forkAssistantResults => conversation.forkAssistantResults;
  List<Object?> get createSelectionSideSessionResults =>
      conversation.createSelectionSideSessionResults;

  WorkspaceOpenResult get ensureDraftWorkspaceResult =>
      conversation.ensureDraftWorkspaceResult;
  set ensureDraftWorkspaceResult(WorkspaceOpenResult value) =>
      conversation.ensureDraftWorkspaceResult = value;

  Completer<void>? get ensureDraftWorkspaceGate =>
      conversation.ensureDraftWorkspaceGate;
  set ensureDraftWorkspaceGate(Completer<void>? value) =>
      conversation.ensureDraftWorkspaceGate = value;

  List<String?> get ensuredDraftWorkspaces => conversation.ensuredDraftWorkspaces;

  // ----------------------------------------------------- task-meta surface

  @override
  Future<dynamic> renameTask(String sessionId, String title) =>
      taskMeta.renameTask(sessionId, title);

  @override
  Future<dynamic> setTaskPinned(String sessionId, bool pinned) =>
      taskMeta.setTaskPinned(sessionId, pinned);

  @override
  Future<dynamic> setTaskArchived(String sessionId, bool archived) =>
      taskMeta.setTaskArchived(sessionId, archived);

  @override
  Future<dynamic> setTaskUnread(String sessionId, bool unread) =>
      taskMeta.setTaskUnread(sessionId, unread);

  @override
  Future<dynamic> taskNativeSessionLogFile(String sessionId) =>
      taskMeta.taskNativeSessionLogFile(sessionId);

  @override
  Future<dynamic> deleteTask(String sessionId) =>
      taskMeta.deleteTask(sessionId);

  @override
  String? taskDisplayStatus(String sessionId) =>
      taskMeta.taskDisplayStatus(sessionId);

  List<Object?> get deleteTaskResults => taskMeta.deleteTaskResults;
  Map<String, String> get taskDisplayStatuses => taskMeta.taskDisplayStatuses;

  // ------------------------------------------------ workspace-context surface

  @override
  String? get chatWorkspaceId => workspaceContext.chatWorkspaceId;
  set chatWorkspaceId(String? value) => workspaceContext.chatWorkspaceId = value;

  @override
  String? get workspacePath => workspaceContext.workspacePath;
  set workspacePath(String? value) => workspaceContext.workspacePath = value;

  @override
  ChatDraftStore get chatDraftStore => workspaceContext.chatDraftStore;
  set chatDraftStore(ChatDraftStore value) =>
      workspaceContext.chatDraftStore = value;

  @override
  Future<WorkspacePrep> prepareWorkspace() =>
      workspaceContext.prepareWorkspace();

  @override
  Future<List<SkillEntry>> skills() => workspaceContext.skills();

  @override
  Future<List<Map<String, dynamic>>> modelProviderCatalog() =>
      workspaceContext.modelProviderCatalog();

  @override
  Future<Set<String>?> entitledProviderIds() =>
      workspaceContext.entitledProviderIds();

  @override
  Future<List<Map<String, dynamic>>> searchWorkspaceFiles(
    String query, {
    int limit = 50,
  }) =>
      workspaceContext.searchWorkspaceFiles(query, limit: limit);

  @override
  Future<bool> workspaceFilesReachable() =>
      workspaceContext.workspaceFilesReachable();

  @override
  Future<List<Map<String, dynamic>>> mentionSkills() =>
      workspaceContext.mentionSkills();

  @override
  Future<List<Map<String, dynamic>>> mentionSubagents() =>
      workspaceContext.mentionSubagents();

  @override
  List<({String id, String title})> mentionSessions() =>
      workspaceContext.mentionSessions();

  @override
  FileServicePort get fileService => workspaceContext.fileService;

  /// The default workspace file port (typed programming + legacy recorded
  /// method names). Tests that need scripted reads replace [fileService].
  RecordingFileServicePort get filePort =>
      workspaceContext.fileService as RecordingFileServicePort;

  List<Map<String, dynamic>> get modelProviderCatalogResult =>
      workspaceContext.modelProviderCatalogResult;
  set modelProviderCatalogResult(List<Map<String, dynamic>> value) =>
      workspaceContext.modelProviderCatalogResult = value;

  int get modelProviderCatalogCalls => workspaceContext.modelProviderCatalogCalls;

  Set<String>? get entitledProviderIdsResult =>
      workspaceContext.entitledProviderIdsResult;
  set entitledProviderIdsResult(Set<String>? value) =>
      workspaceContext.entitledProviderIdsResult = value;

  Object? get entitledProviderIdsError =>
      workspaceContext.entitledProviderIdsError;
  set entitledProviderIdsError(Object? value) =>
      workspaceContext.entitledProviderIdsError = value;

  int get entitledProviderIdsCalls => workspaceContext.entitledProviderIdsCalls;

  List<Map<String, dynamic>> get searchWorkspaceFilesResult =>
      workspaceContext.searchWorkspaceFilesResult;
  set searchWorkspaceFilesResult(List<Map<String, dynamic>> value) =>
      workspaceContext.searchWorkspaceFilesResult = value;

  Object? get searchWorkspaceFilesError =>
      workspaceContext.searchWorkspaceFilesError;
  set searchWorkspaceFilesError(Object? value) =>
      workspaceContext.searchWorkspaceFilesError = value;

  bool get workspaceFilesReachableResult =>
      workspaceContext.workspaceFilesReachableResult;
  set workspaceFilesReachableResult(bool value) =>
      workspaceContext.workspaceFilesReachableResult = value;

  List<Map<String, dynamic>> get mentionSubagentsResult =>
      workspaceContext.mentionSubagentsResult;
  set mentionSubagentsResult(List<Map<String, dynamic>> value) =>
      workspaceContext.mentionSubagentsResult = value;

  List<Map<String, dynamic>> get mentionSkillsResult =>
      workspaceContext.mentionSkillsResult;
  set mentionSkillsResult(List<Map<String, dynamic>> value) =>
      workspaceContext.mentionSkillsResult = value;

  List<({String id, String title})> get mentionSessionsResult =>
      workspaceContext.mentionSessionsResult;
  set mentionSessionsResult(List<({String id, String title})> value) =>
      workspaceContext.mentionSessionsResult = value;

  FileStat get fileStatResult => filePort.fileStatResult;
  set fileStatResult(FileStat value) => filePort.fileStatResult = value;

  MediaPreview get fileReadMediaResult => filePort.fileReadMediaResult;
  set fileReadMediaResult(MediaPreview value) =>
      filePort.fileReadMediaResult = value;

  TextChunk get fileReadTextResult => filePort.fileReadTextResult;
  set fileReadTextResult(TextChunk value) => filePort.fileReadTextResult = value;

  FileRange get fileReadRangeResult => filePort.fileReadRangeResult;
  set fileReadRangeResult(FileRange value) =>
      filePort.fileReadRangeResult = value;

  // ------------------------------------------------------- session-truth

  @override
  bool isSessionDeleted(String sessionId) =>
      truth.isSessionDeleted(sessionId);

  @override
  void forgetDeletedSession(String sessionId) =>
      truth.forgetDeletedSession(sessionId);

  @override
  bool isSessionMissing(String sessionId) =>
      truth.isSessionMissing(sessionId);

  @override
  void forgetMissingSession(String sessionId) =>
      truth.forgetMissingSession(sessionId);

  Set<String> get deletedSessionIds => truth.deletedSessionIds;
  List<String> get forgottenSessions => truth.forgottenSessions;
  Set<String> get missingSessionIds => truth.missingSessionIds;
  List<String> get forgottenMissingSessions => truth.forgottenMissingSessions;

  // --------------------------------------------------------------- git

  @override
  GitPort get git => gitAccess.git;

  List<(String, List<Object?>)> get gitCalls => gitAccess.gitCalls;

  Object? Function(String method, List<Object?> args)? get gitCallHandler =>
      gitAccess.gitCallHandler;
  set gitCallHandler(Object? Function(String method, List<Object?> args)? value) =>
      gitAccess.gitCallHandler = value;

  // ------------------------------------------------------------- quota

  @override
  Future<EntitlementView> entitlementSnapshot({bool force = false}) =>
      quota.entitlementSnapshot(force: force);

  @override
  QuotaResetController get quotaResetController => quota.quotaResetController;

  @override
  Future<Object?> quotaResetStatus({bool force = false}) =>
      quota.quotaResetStatus(force: force);

  @override
  Future<void> useQuotaReset(
    String resetType,
    String idempotencyKey, {
    String? preferredProviderId,
  }) =>
      quota.useQuotaReset(
        resetType,
        idempotencyKey,
        preferredProviderId: preferredProviderId,
      );

  EntitlementView get entitlementResult => quota.entitlementResult;
  set entitlementResult(EntitlementView value) =>
      quota.entitlementResult = value;

  int get entitlementCalls => quota.entitlementCalls;

  Map<String, dynamic>? get quotaStatusResult => quota.quotaStatusResult;
  set quotaStatusResult(Map<String, dynamic>? value) =>
      quota.quotaStatusResult = value;

  int get quotaStatusCalls => quota.quotaStatusCalls;

  Object? get useQuotaError => quota.useQuotaError;
  set useQuotaError(Object? value) => quota.useQuotaError = value;

  List<(String, String?, String)> get useQuotaCalls => quota.useQuotaCalls;
}

/// Historical name kept for the page-test fixtures (`FakeChatGateway`),
/// now a thin alias over [ChatGatewayBundle].
class FakeChatGateway extends ChatGatewayBundle {}
