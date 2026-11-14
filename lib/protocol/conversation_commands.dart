// The named conversation-command surface of a ConversationTransport
// (native addition, task 10-29-conversation-commands-grouping). The wire
// body stays bundle-ported in conversation_transport.dart (ADR-0013); this
// interface only narrows what UI code can reach — the infrastructure
// surface (sendCommand raw envelope, session/channels, subscription
// bookkeeping) is intentionally NOT on it.
import 'package:flutter/foundation.dart';

import 'command_ledger.dart';
import 'conversation_transport.dart';

/// Conversation V4 commands of the active workspace, as consumed by the
/// chat UI: sends, lifecycle, model/config switches, queue/interaction
/// operations, files/plans, attachments and row edits.
///
/// Implemented by [ConversationTransport]; every signature (including
/// parameter defaults) mirrors the implementation verbatim, and the wire
/// payloads are unchanged. Callers holding this type cannot reach the bare
/// [ConversationTransport.sendCommand] envelope or the underlying bridge
/// session — only [degraded] of the session state is exposed, because the
/// loading placeholder listens to it.
abstract interface class ConversationCommands {
  // ------------------------------------------------- sending & control

  /// Sends a plain message (`sendText`) with optional attachments and
  /// automation/off-peak routing fields.
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
  });

  /// `sendText` with explicit delivery semantics:
  /// 'startNow' | 'queue' | 'guide' (web composer behavior).
  Future<dynamic> sendTextWithDelivery(
    String sessionId,
    String text, {
    required String requestedDelivery,
    String? heldQueueDisposition,
    List<String>? expectedHeldQueueItemIds,
  });

  /// Sends one `sendText` and classifies the outcome (sent / rejected /
  /// queued / failed) — the chat composer's plain-send path. Only THIS
  /// call parks the message in the offline replayable queue (ADR-0010).
  Future<SendTextResult> sendTextOrQueue(
    String sessionId,
    String text, {
    List<Map<String, dynamic>>? attachments,
    String? heldQueueDisposition,
  });

  Future<dynamic> sendGoalCommand(
    String sessionId,
    String text, {
    String? displayText,
    String? heldQueueDisposition,
    List<String>? expectedHeldQueueItemIds,
  });

  Future<dynamic> pauseGoal(String sessionId);

  Future<dynamic> resumeGoal(String sessionId);

  Future<dynamic> stop(String sessionId);

  Future<dynamic> compact(String sessionId);

  Future<dynamic> retryTurn(String sessionId, Map<String, dynamic> target);

  // ------------------------------------------------------ session lifecycle

  /// Creates a session in [workspaceId]; returns the new sessionId.
  Future<String> createSession(
    String workspaceId, {
    String? firstText,
    List<Map<String, dynamic>>? attachments,
    Map<String, dynamic>? config,
    String? runtimeModel,
    List<String>? mcpServers,
    Duration timeout = const Duration(seconds: 90),
  });

  /// Creates a selection-side (auxiliary) chat attached to
  /// [parentSessionId] ("ask in side chat"); returns the new sessionId.
  Future<String> createSelectionSideSession(
    String parentSessionId, {
    String? firstText,
    Map<String, dynamic>? modelSelection,
    Duration timeout = const Duration(seconds: 60),
  });

  Future<dynamic> deleteSession(String sessionId);

  Future<dynamic> renameSession(String sessionId, String title);

  Future<dynamic> forkAssistant(
    String sessionId,
    Map<String, dynamic> target,
  );

  // ------------------------------------------------------ model & config

  /// Switches model config. provider/model/thought are all required by the
  /// protocol schema — pass current values for the ones not changing.
  Future<dynamic> switchModelConfig(
    String sessionId, {
    required String provider,
    required String model,
    required String thought,
  });

  /// build / edit / plan / yolo.
  Future<dynamic> switchCollaborationMode(String sessionId, String mode);

  /// queue / guide followup.
  Future<dynamic> setFollowupMode(String sessionId, String mode);

  // -------------------------------------------------- queue & interactions

  Future<dynamic> sendQueuedNow(String sessionId, String queueItemId);

  Future<dynamic> editQueueItem(
    String sessionId,
    String queueItemId,
    String newText,
  );

  Future<dynamic> deleteQueueItem(String sessionId, String queueItemId);

  Future<dynamic> setAutoDrain(String sessionId, bool autoDrain);

  /// Moves [queueItemId] directly before [beforeQueueItemId] in the held
  /// queue (`null` = move to the end). CAS command per the web schema.
  Future<dynamic> reorderQueueItem(
    String sessionId,
    String queueItemId,
    String? beforeQueueItemId,
  );

  /// Defers the interaction auto-resolution timer (desktop setting
  /// 「提问自动继续」≈ 5 minutes). No CAS fields in the web schema.
  Future<dynamic> snoozeInteractionAutoResolution(
    String sessionId,
    String interactionId,
  );

  Future<dynamic> resolveInteraction(
    String sessionId,
    String interactionId, {
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  });

  // --------------------------------------------------------- files & plans

  Future<dynamic> applyFileRewind(
    String sessionId,
    Map<String, dynamic> target,
  );

  Future<dynamic> plans(String sessionId);

  Future<dynamic> fileChanges(
    String sessionId, {
    required Map<String, dynamic> target,
    int? baseRevision,
    String? baseLogEpoch,
  });

  Future<dynamic> fileRewindPreview(
    String sessionId, {
    required Map<String, dynamic> target,
    int? baseRevision,
    String? baseLogEpoch,
  });

  /// Cancels a background work item (terminal / subagent banner ✕).
  Future<dynamic> cancelBackgroundWork(String sessionId, String workId);

  /// Answers the `workspaceHookReview` interaction (3.12.3 workspace
  /// hooks); [reviewItemIds] carries the checked hooks.
  Future<dynamic> respondWorkspaceHookReview(
    String sessionId,
    Map<String, dynamic> frame,
    List<String> reviewItemIds,
  );

  /// Backwards history page (`conversationRowsRangeV4`); the cursor
  /// contract lives in the protocol guidelines (rowsRange 翻页游标契约).
  Future<dynamic> rowsRange(
    String sessionId, {
    int? beforeRowId,
    int limit = 60,
  });

  // ---------------------------------------------------- attachments & rows

  /// Uploads an attachment (begin/chunk/commit). Returns the attachment
  /// descriptor `{ref, fileName, mime, bytes}` to be passed to sendText /
  /// createSession.
  Future<Map<String, dynamic>> attachmentPut(
    String sessionId, {
    required String fileName,
    required String mime,
    required Uint8List bytes,
    void Function(double progress)? onProgress,
  });

  /// Reads an attachment (for previews). Returns `{bytes, mediaType}`.
  Future<({Uint8List bytes, String? mediaType})> attachmentRead(
    String sessionId, {
    required String ref,
  });

  /// Edits a sent user query. `workspaceMode` is the 3.14+ edit-rewind
  /// switch ('preserve' is the wire default — only 'rewind' goes on the
  /// wire).
  Future<dynamic> editUserQuery(
    String sessionId,
    Map<String, dynamic> target,
    String newText, {
    String? workspaceMode,
  });

  /// like / dislike / null on an assistant row. Target is
  /// `{rowId, entityId}` (entityId optional for some row kinds).
  Future<dynamic> setAssistantFeedback(
    String sessionId,
    Map<String, dynamic> target,
    String? feedback,
  );

  // ------------------------------------------------------------- degraded

  /// Bridge degradation flag of the underlying bridge session: non-null
  /// while the native bridge is down/rebuilding. Same state source as the
  /// send path's queue decision; the loading placeholder listens to it.
  ValueListenable<String?> get degraded;

  /// Terminal settlements of suspended commands (task 11-13): delivered /
  /// rejected / failed / timedOut, with [CommandLedgerOutcome.rootCommandId]
  /// binding a chain's resend back to the chip that waits on it. Internal
  /// transitions and `switchModelConfig` are never emitted.
  Stream<CommandLedgerOutcome> get commandOutcomes;
}
