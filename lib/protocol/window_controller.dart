import 'channel_client.dart';
import 'method_probe.dart';

/// Thrown when the desktop does not serve the archived-deletion pair
/// (`window-controller.previewArchivedTaskDeletion` /
/// `.permanentlyDeleteArchivedTask`). The methods only exist on desktop
/// ≥3.18.0 (3.17.1 answers `Method not found: <name>`); the state layer
/// caches that verdict and this type is the degrade signal the UI falls
/// back on.
class ArchivalPreviewUnavailable implements Exception {
  /// Raw desktop message when the port translated an unknown-method reply.
  final String? message;

  const ArchivalPreviewUnavailable([this.message]);

  @override
  String toString() =>
      'ArchivalPreviewUnavailable${message == null ? '' : ': $message'}';
}

/// Tightened unknown-method verdict for the archived-deletion pair.
///
/// Deliberately NOT `MethodProbe.missingMethod`: that vocabulary includes a
/// bare `not found`, and a false positive here would disable the permanent
/// delete for the whole session. The desktop's wording for a missing
/// controller method is `Method not found: <name>`; the method-name check
/// pins the verdict to our two methods. `contains` (not `startsWith`)
/// because relay / wrapper layers may prefix the text.
bool isArchivalDeletionMethodMissing(Object error) =>
    error is ChannelRpcError &&
    error.message.contains('Method not found:') &&
    (error.message.contains('previewArchivedTaskDeletion') ||
        error.message.contains('permanentlyDeleteArchivedTask'));

/// The controller's "source unavailable" refusal
/// (`session-data.unavailable`, desktop 3.18.0). NOT a downgrade trigger:
/// the old `deleteArchived*` path would only hide the row from lists instead
/// of deleting it for real, so callers surface the official
/// `archives.reason.unavailable` copy instead of falling back.
bool isArchiveDeletionUnavailableError(Object error) =>
    error is ChannelRpcError &&
    error.message.contains('session-data.unavailable');

/// `window-controller` archived-deletion facade (desktop 3.18.0).
///
/// Wire evidence: research/asar-3.18.0.md. Both calls address one task as
/// `{address: {workspacePath, workspaceIdentity?, taskId}}` — the address is
/// `.strict()` desktop-side, so the port sends exactly those keys and
/// nothing else. Preview returns the revision an execute must echo back;
/// execute returns ONE per-task status object (not the batch buckets of
/// `purgeSessionData`).
class WindowControllerPort {
  /// Binds the channel RPC: the port owns the fixed `window-controller`
  /// channel name, method/args vary per call (`Channels.windowController`).
  final Future<dynamic> Function(
    String channel,
    String method,
    List<Object?> args,
  )
  call;

  /// Workspace scope (workspacePath/identity) of the target taskId —
  /// same seam as [TaskCommandsPort]'s `scopeOf`, wired to
  /// `TaskHomeService.taskScopeFor`.
  final Map<String, dynamic> Function(String taskId) scopeOf;

  WindowControllerPort(
    this.call, {
    Map<String, dynamic> Function(String taskId)? scope,
  }) : scopeOf = scope ?? ((_) => const {});

  late final MethodProbe _probe = MethodProbe(
    (method, args) => call(Channels.windowController, method, args),
  );

  // Official 3.18.0 names, single candidates (source-confirmed; see
  // research/asar-3.18.0.md). Unknown-method replies become
  // [ArchivalPreviewUnavailable] instead of being probed further — there is
  // no older alias to try.
  static const _previewMethods = ['previewArchivedTaskDeletion'];
  static const _executeMethods = ['permanentlyDeleteArchivedTask'];

  /// Strict `address` object: exactly workspacePath/workspaceIdentity/taskId
  /// (the desktop schema rejects extra keys — sourceServerId/remoteSessionId
  /// addresses are not modelled by ZGo).
  Map<String, dynamic> _address(String taskId, Map<String, dynamic>? scope) {
    final s = scope ?? scopeOf(taskId);
    return {
      'workspacePath': s['workspacePath'],
      if (s['workspaceIdentity'] != null)
        'workspaceIdentity': s['workspaceIdentity'],
      'taskId': taskId,
    };
  }

  /// Checks deletion scope and returns the revision an execute must carry.
  /// Throws [ArchivalPreviewUnavailable] on an unknown-method reply; every
  /// other failure (validation, timeout, `session-data.unavailable`)
  /// rethrows untouched.
  Future<ArchivalDeletionPreview> previewArchivedDeletion(
    String taskId, {
    Map<String, dynamic>? scope,
  }) async {
    try {
      final res = await _probe.run(
        'previewArchivedDeletion',
        _previewMethods,
        argsOf: (_) => <Object?>[
          {'address': _address(taskId, scope)},
        ],
      );
      if (res is! Map) {
        throw StateError('windowController.previewArchivedDeletion: '
            'unexpected answer ${res.runtimeType}');
      }
      return ArchivalDeletionPreview.fromMap(res);
    } on ChannelRpcError catch (e) {
      if (isArchivalDeletionMethodMissing(e)) {
        throw ArchivalPreviewUnavailable(e.message);
      }
      rethrow;
    }
  }

  /// Permanently deletes one archived task (with its fork cascade) using the
  /// revision from [previewArchivedDeletion]. `operationId` makes the call
  /// idempotent desktop-side; ZGo does not auto-retry, so it is generated
  /// per attempt. Throws [ArchivalPreviewUnavailable] on an unknown-method
  /// reply, every other failure rethrows untouched.
  Future<ArchivalDeletionResult> permanentlyDeleteArchived(
    String taskId, {
    required String revision,
    required String operationId,
    Map<String, dynamic>? scope,
  }) async {
    try {
      final res = await _probe.run(
        'permanentlyDeleteArchived',
        _executeMethods,
        argsOf: (_) => <Object?>[
          {
            'address': _address(taskId, scope),
            'revision': revision,
            'operationId': operationId,
          },
        ],
      );
      if (res is! Map) {
        throw StateError('windowController.permanentlyDeleteArchived: '
            'unexpected answer ${res.runtimeType}');
      }
      return ArchivalDeletionResult.fromMap(res);
    } on ChannelRpcError catch (e) {
      if (isArchivalDeletionMethodMissing(e)) {
        throw ArchivalPreviewUnavailable(e.message);
      }
      rethrow;
    }
  }
}

/// Preview answer of `previewArchivedTaskDeletion`:
/// `{sessionId, revision, sessionIds[], forks[], retainedArtifacts[],
/// deletedFiles, blockedReason?, incomplete, completed}`.
///
/// Tolerant parse: unknown fields are ignored; `forks[]` /
/// `retainedArtifacts[]` are not modelled (lightweight scope), `deletedFiles`
/// defaults to 0 when absent. `completed` is not modelled — the state layer
/// only needs the blocked/incomplete verdicts the desktop already folded
/// into `blockedReason`.
class ArchivalDeletionPreview {
  /// Opaque revision the matching execute must echo back.
  final String revision;

  /// Sessions this delete covers, including the fork cascade. The first is
  /// the task itself; `length - 1` is the official "owned child sessions"
  /// count.
  final List<String> sessionIds;

  /// `running | in-use | not-found | not-archived | unavailable | changed`
  /// when the delete is blocked; null otherwise.
  final String? blockedReason;

  /// Official semantics: the previous permanent delete was not confirmed
  /// complete — retryable, not a data-integrity veto.
  final bool incomplete;

  /// Official `archives.deleteItem` third placeholder (private attachment /
  /// execution-record files).
  final int deletedFiles;

  const ArchivalDeletionPreview({
    required this.revision,
    required this.sessionIds,
    required this.blockedReason,
    required this.incomplete,
    required this.deletedFiles,
  });

  factory ArchivalDeletionPreview.fromMap(Map<dynamic, dynamic> raw) =>
      ArchivalDeletionPreview(
        revision: '${raw['revision'] ?? ''}',
        sessionIds: _stringList(raw['sessionIds']),
        blockedReason: raw['blockedReason'] is String &&
                (raw['blockedReason'] as String).isNotEmpty
            ? raw['blockedReason'] as String
            : null,
        incomplete: raw['incomplete'] == true,
        deletedFiles:
            raw['deletedFiles'] is num ? (raw['deletedFiles'] as num).toInt() : 0,
      );
}

/// Execute answer of `permanentlyDeleteArchivedTask` — ONE task object:
/// `{sessionId, status: deleted|blocked|incomplete, sessionIds[],
/// retainedArtifacts, reason?}` (the `{deleted[], kept[], failed[]}` buckets
/// belong to `purgeSessionData`, not this surface).
class ArchivalDeletionResult {
  /// `deleted | blocked | incomplete`.
  final String status;

  /// Sessions actually removed when [status] is `deleted` (fork cascade
  /// included) — the tombstone list; empty for blocked/incomplete answers
  /// the desktop did not detail.
  final List<String> sessionIds;

  /// Free-form desktop reason for blocked/incomplete (NOT the six-value
  /// preview enum).
  final String? reason;

  const ArchivalDeletionResult({
    required this.status,
    required this.sessionIds,
    required this.reason,
  });

  factory ArchivalDeletionResult.fromMap(Map<dynamic, dynamic> raw) =>
      ArchivalDeletionResult(
        status: '${raw['status'] ?? ''}',
        sessionIds: _stringList(raw['sessionIds']),
        reason: raw['reason'] is String && (raw['reason'] as String).isNotEmpty
            ? raw['reason'] as String
            : null,
      );
}

List<String> _stringList(dynamic value) => [
  if (value is List)
    for (final item in value)
      if (item is String && item.isNotEmpty) item,
];