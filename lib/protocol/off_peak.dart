import 'channel_client.dart';
import 'id.dart';
import 'method_probe.dart';

/// Off-peak tasks (闲时任务): free runs in compute-rich windows, submitted
/// into a server-side queue. Coding Plan subscription required with a
/// monthly quota.
///
/// Wire messages (zod-style, from the off-peak protocol family; verified
/// against the live desktop where noted):
/// ```text
/// off-peak-run = {                  // submit a queued run
///   offPeakTaskId: string,
///   workspacePath: string,
///   workspaceIdentity?: string,
///   prompt: string,
///   permissionMode: string,         // e.g. 'build' | 'plan' | 'yolo'
///   model?: string, thoughtLevel?: string,
///   conversationId?: string,        // resume/续投 carries these
///   sessionId?: string,
///   serverTicketId?: string,
/// }
/// off-peak-run-result = {           // pushed/returned when a run finishes
///   ok: boolean,
///   conversationId?: string, sessionId?: string,
///   error?: 'codingPlanOnly' | 'quota' | 'unavailable' | string,
/// }
/// off-peak-scheduler-wake-request = {}  // nudge the scheduler to re-check
/// ```
/// `sendText` accepts `offPeakTaskId` + `offPeakRunType: 'init'|'resume'`
/// for 续投 (already implemented in conversation.dart's sendText).
///
/// Channel: `off-peak-task` (present in the desktop channel registry;
/// confirmed via the zemote channel explorer). Method names below are
/// live-confirmed only where noted (2026-09-17 rounds against 3.12.3:
/// lifecycle positional names, positional `updateTask`, structured
/// createTask errors); everything else probes candidates via [MethodProbe]
/// and remembers the winner; validation/permission errors surface as-is.
///
/// Desktops ≥3.12.3 ([newWire]) take the lifecycle family as a bare
/// positional `[taskId]` (the legacy object form throws a loud SQLite
/// binding error there) and probe the positional `updateTask(taskId, patch)`
/// first; they also answer some ops with a structured failure envelope
/// `{ok:false, failureStage, errorCategory, errorCode}` which maps onto
/// [OffPeakError] kinds. Older desktops keep the legacy wire exactly as
/// before — gated, never double-sent.
///
/// Desktops ≥3.14 ([statusV314]) lose the legacy status family entirely
/// (getStatus/getQuota/status → Method not found); the header comes from
/// two parameter-less probes instead — getCodingPlanSupport and
/// getTakeNumberAvailability (live-confirmed 2026-09-19, both tolerate an
/// empty args list).
class OffPeakPort {
  /// Binds one RPC: the channel is fixed by the port owner, method/args vary.
  final Future<dynamic> Function(String method, List<Object?> args) call;

  /// 3.12.3 wire gate (RemoteConnectionParams.atLeast(3, 12, 3) of the
  /// session's app_version; a desktop never changes version mid-session).
  final bool newWire;

  /// 3.14 status gate (RemoteConnectionParams.atLeast(3, 14, 0)): switches
  /// [status] from the legacy method ladder to the take-a-number probes.
  final bool statusV314;

  OffPeakPort(this.call, {required this.newWire, this.statusV314 = false})
      : _probe = MethodProbe(call);

  final MethodProbe _probe;

  static const _listMethods = [
    'list',
    'listAll',
    'listOffPeakTasks',
    'listTasks',
  ];
  // createTask/updateTask/pauseTask/continueTask/cancelTask/deleteTask/
  // deleteHistory are the desktop service's own names (seen in the desktop
  // UI chunk's offPeak store); the others keep first-shot precedence from
  // earlier probing rounds.
  static const _submitMethods = [
    'run',
    'submit',
    'createTask',
    'submitOffPeakTask',
    'createOffPeakTask',
  ];
  // Lifecycle names live-confirmed on 3.12.3 (2026-09-17): pauseTask/
  // continueTask/cancelTask/deleteTask/deleteHistory with a bare
  // positional `[taskId]`. The legacy flat names stay as fallbacks.
  static const _pauseMethods = ['pause', 'pauseTask', 'pauseOffPeakTask'];
  static const _resumeMethods = [
    'resume',
    'continueTask',
    'resumeOffPeakTask',
  ];
  static const _cancelMethods = ['cancel', 'cancelTask', 'cancelOffPeakTask'];
  static const _deleteMethods = ['delete', 'deleteTask', 'deleteOffPeakTask'];
  static const _historyDeleteMethods = [
    'deleteHistory',
    'delete',
    'deleteTask',
  ];

  /// Candidates that take the positional `[taskId]` on [newWire] desktops
  /// (see the class doc). Any other candidate keeps the legacy object form
  /// `[{offPeakTaskId: taskId}]`.
  static const _positionalLifecycle = {
    'pauseTask',
    'continueTask',
    'cancelTask',
    'deleteTask',
    'deleteHistory',
  };
  static const _updateMethods = [
    'updateTask',
    'editOffPeakTask',
    'updateOffPeakTask',
    'update',
  ];
  static const _statusMethods = ['getStatus', 'getQuota', 'status'];
  static const _wakeMethods = [
    'wake',
    'wakeScheduler',
    'off-peak-scheduler-wake-request',
  ];

  // ------------------------------------------------------------------ list

  /// Lists off-peak tasks (active queue + history).
  Future<List<OffPeakTask>> list() async {
    final res = await _probe.run('list', _listMethods);
    dynamic items = res;
    if (res is Map) {
      items = res['tasks'] ?? res['items'] ?? res['list'] ?? res['history'];
    }
    if (items is! List) return const [];
    return [
      for (final item in items)
        if (item is Map) OffPeakTask(item.cast<String, dynamic>()),
    ];
  }

  // ---------------------------------------------------------------- submit

  /// Submits a queued run. Returns the ack (run-result-shaped when the
  /// server answers inline). Throws [OffPeakError] with a classified kind
  /// for codingPlanOnly / quota / unavailable failures.
  Future<OffPeakRunResult> submit(OffPeakSubmitInput input) async {
    dynamic res;
    try {
      res = await _probe.run('submit', _submitMethods,
          argsOf: (_) => [input.toWire()]);
    } on ChannelRpcError catch (e) {
      throw OffPeakError.fromMessage(e.message, e);
    }
    // 3.12.3 answers some rejections with a structured envelope as a
    // normal ack ({ok:false, errorCategory, ...}) — classify and throw
    // instead of surfacing an opaque ok:false result.
    final structured = OffPeakError.structuredFrom(res);
    if (structured != null) throw structured;
    final ack =
        res is Map ? res.cast<String, dynamic>() : const <String, dynamic>{};
    return OffPeakRunResult.from(ack, echo: input.toWire());
  }

  // ------------------------------------------------------------ lifecycle

  Future<void> pause(String taskId) =>
      _lifecycle('pause', _pauseMethods, taskId);

  Future<void> resume(String taskId) =>
      _lifecycle('resume', _resumeMethods, taskId);

  Future<void> cancel(String taskId) =>
      _lifecycle('cancel', _cancelMethods, taskId);

  /// History removal (desktop separates 删除历史记录 from task delete).
  /// Falls back to the plain delete candidates on older desktops.
  Future<void> remove(String taskId) =>
      _lifecycle('delete', _deleteMethods, taskId);

  Future<void> deleteHistory(String taskId) =>
      _lifecycle('history-delete', _historyDeleteMethods, taskId);

  // ---------------------------------------------------------------- update

  /// Edits an existing queued/paused run. The desktop update call passes
  /// `{title, prompt, permissionMode, model, thoughtLevel}` keyed by the
  /// task id; `model`/`thoughtLevel` arrive as explicit nulls when unset.
  /// Arg shapes: 0 = `[{offPeakTaskId, ...patch}]`,
  /// 1 = `[taskId, {patch}]` — resolved once and remembered.
  ///
  /// Shape order: 3.12.3 takes the positional form (live 2026-09-17:
  /// bogus-id void ack; the object form is rejected with `Unknown named
  /// parameter 'offPeakTaskId'`), so it probes first there. Legacy desktops
  /// keep the object form first — a positional call can silent-void there,
  /// while the object form fails loudly and lets the probe advance.
  Future<void> update(String taskId, OffPeakUpdateInput patch) async {
    final order = newWire ? const [1, 0] : const [0, 1];
    Object? firstError;
    for (final shape in order) {
      final wire = patch.toWire(newWire: newWire);
      final args = switch (shape) {
        0 => <Object?>[
            {'offPeakTaskId': taskId, ...wire}
          ],
        _ => <Object?>[taskId, wire],
      };
      try {
        await _probe.run('update:$shape', _updateMethods, argsOf: (_) => args);
        return;
      } on ChannelRpcError catch (e) {
        if (!MethodProbe.missingMethod(e.message)) rethrow;
        firstError ??= e;
      }
    }
    throw firstError ?? StateError('update: no candidate methods left');
  }

  Future<void> _lifecycle(
      String op, List<String> methods, String taskId) async {
    // Candidate ladder direction (PRD R1): on newWire the positional-
    // confirmed names lead (live hits) and a legacy object-form name stays
    // as the loud-error fallback; on legacy desktops the sequence is kept
    // verbatim and every call takes the object form — a positional
    // `[taskId]` there can silent-void (false positive), so it never leads.
    final candidates = newWire
        ? [
            ...methods.where(_positionalLifecycle.contains),
            ...methods.where((m) => !_positionalLifecycle.contains(m)),
          ]
        : methods;
    try {
      final res = await _probe.run(op, candidates,
          argsOf: (m) => newWire && _positionalLifecycle.contains(m)
              ? <Object?>[taskId]
              : <Object?>[
                  {'offPeakTaskId': taskId}
                ]);
      final failure = OffPeakError.structuredFrom(res);
      if (failure != null) throw failure;
    } on ChannelRpcError catch (e) {
      throw OffPeakError.fromMessage(e.message, e);
    }
  }

  // ---------------------------------------------------------------- status

  /// Entitlement + quota status (订阅门槛、月度额度、最早可用时间).
  /// Returns null when every status method is rejected (older desktop) —
  /// the UI then omits the quota header instead of failing.
  ///
  /// On [statusV314] desktops the legacy ladder is gone (Method not found
  /// on all three candidates); the two take-a-number probes run in
  /// parallel and normalize into an [OffPeakStatus] view. Either RPC
  /// failing yields the `availabilityError` view instead of throwing —
  /// a failed header degrades (S4), it never toasts.
  Future<OffPeakStatus?> status() async {
    if (statusV314) return _statusTakeNumber();
    dynamic res;
    try {
      res = await _probe.run('status', _statusMethods);
    } on ChannelRpcError {
      return null;
    }
    if (res is! Map) return null;
    return OffPeakStatus(res.cast<String, dynamic>());
  }

  /// 3.14: getCodingPlanSupport + getTakeNumberAvailability (both
  /// parameter-less), normalized to
  /// `{supported, canTakeNumber, nextTakeAt?}` — the quota/earliest fields
  /// have no counterpart on this channel anymore.
  Future<OffPeakStatus> _statusTakeNumber() async {
    try {
      final results = await Future.wait<dynamic>([
        call('getCodingPlanSupport', const []),
        call('getTakeNumberAvailability', const []),
      ]);
      final support = results[0];
      final availability = results[1];
      if (support is! Map || availability is! Map) {
        return OffPeakStatus(const {'availabilityError': true});
      }
      return OffPeakStatus({
        'supported': support['supported'],
        'canTakeNumber': availability['canTakeNumber'],
        if (availability['nextTakeAt'] != null)
          'nextTakeAt': availability['nextTakeAt'],
      });
    } on ChannelRpcError {
      return OffPeakStatus(const {'availabilityError': true});
    }
  }

  /// Nudges the desktop scheduler (`off-peak-scheduler-wake-request`
  /// family). Best-effort; failures are ignored by callers.
  Future<void> wake() async {
    try {
      await _probe.run('wake', _wakeMethods);
    } catch (_) {
      // Wake is an optimization, never an error surface.
    }
  }
}

/// Submit form → wire (`off-peak-run`). Exactly the documented fields;
/// [earliestAtMs]/[title] ride along as display hints (beyond the
/// documented schema, ignored by desktops that don't know them).
class OffPeakSubmitInput {
  final String prompt;
  final String workspacePath;
  final String? workspaceIdentity;
  final String permissionMode;
  final String? model;
  final String? thoughtLevel;
  final int? earliestAtMs;
  final String? title;

  /// Client-chosen task id (server may also assign one). Defaults to a
  /// fresh uuid when omitted.
  final String? offPeakTaskId;

  OffPeakSubmitInput({
    required this.prompt,
    required this.workspacePath,
    this.workspaceIdentity,
    this.permissionMode = 'build',
    this.model,
    this.thoughtLevel,
    this.earliestAtMs,
    this.title,
    String? offPeakTaskId,
  }) : offPeakTaskId = offPeakTaskId ?? generateUuid();

  Map<String, dynamic> toWire() => {
        'offPeakTaskId': offPeakTaskId,
        'workspacePath': workspacePath,
        if (workspaceIdentity != null && workspaceIdentity!.isNotEmpty)
          'workspaceIdentity': workspaceIdentity,
        'prompt': prompt.trim(),
        'permissionMode': permissionMode,
        if (model != null && model!.isNotEmpty) 'model': model,
        if (thoughtLevel != null && thoughtLevel!.isNotEmpty)
          'thoughtLevel': thoughtLevel,
        if (earliestAtMs != null) 'earliestAvailableAt': earliestAtMs,
        if (title != null && title!.isNotEmpty) 'title': title,
      };
}

/// Edit-form patch for an existing run (desktop `updateTask` shape).
/// [model]/[thoughtLevel] are emitted explicitly (null included) — the
/// desktop sends `?? null` for them, and they clear overrides when null.
class OffPeakUpdateInput {
  final String title;
  final String prompt;
  final String permissionMode;

  /// Plain model name (allowedModels entries); null = 默认模型.
  final String? model;

  /// Provider id for the 3.12.3 [modelSelection] object. The off-peak
  /// edit form has no provider picker yet — null means the pair is
  /// incomplete and the flat wire keeps the desktop's stored value.
  final String? provider;

  /// Thought level (allowedModelConfigs reasoning levels); null = 默认.
  final String? thoughtLevel;

  const OffPeakUpdateInput({
    required this.title,
    required this.prompt,
    this.permissionMode = 'build',
    this.model,
    this.provider,
    this.thoughtLevel,
  });

  Map<String, dynamic> toWire({bool newWire = false}) {
    final clearModel = model == null || model!.isEmpty;
    final clearThought = thoughtLevel == null || thoughtLevel!.isEmpty;
    if (!newWire) {
      return {
        'title': title.trim(),
        'prompt': prompt.trim(),
        'permissionMode': permissionMode,
        'model': clearModel ? null : model,
        'thoughtLevel': clearThought ? null : thoughtLevel,
      };
    }
    // 3.12.3: model/thoughtLevel ride in a modelSelection object. The
    // automation-port ruling carries over — once emitted, providerId/
    // modelId are required (zod strict), so the object only goes out with
    // the provider+model pair; a lone thoughtLevel has no carrier and is
    // dropped. An explicit null patch (user picked 默认模型) keeps its
    // clear-the-field semantics as `modelSelection: null`.
    final hasPair = !clearModel && provider != null && provider!.isNotEmpty;
    return {
      'title': title.trim(),
      'prompt': prompt.trim(),
      'permissionMode': permissionMode,
      if (hasPair)
        'modelSelection': {
          'providerId': provider,
          'modelId': model,
          if (!clearThought) 'options': {'reasoningLevel': thoughtLevel},
        }
      else if (clearModel)
        'modelSelection': null,
    };
  }
}

/// Parsed `off-peak-run-result`.
class OffPeakRunResult {
  final bool ok;
  final String? conversationId;
  final String? sessionId;
  final String? error;
  final Map<String, dynamic> raw;

  const OffPeakRunResult({
    required this.ok,
    this.conversationId,
    this.sessionId,
    this.error,
    this.raw = const {},
  });

  factory OffPeakRunResult.from(Map<String, dynamic> raw,
      {Map<String, dynamic>? echo}) {
    final error = raw['error'] as String?;
    return OffPeakRunResult(
      // A void ack (no ok, no error) means accepted.
      ok: raw['ok'] != false && error == null,
      conversationId: raw['conversationId'] as String? ??
          echo?['conversationId'] as String?,
      sessionId: raw['sessionId'] as String? ?? echo?['sessionId'] as String?,
      error: error,
      raw: raw,
    );
  }
}

/// Read-side view of one off-peak task. Field names tolerate the common
/// id/status spellings seen across protocol versions.
class OffPeakTask {
  final Map<String, dynamic> raw;
  OffPeakTask(this.raw);

  String get id =>
      '${raw['offPeakTaskId'] ?? raw['taskId'] ?? raw['id'] ?? ''}';

  String get title => '${raw['title'] ?? ''}';
  String get prompt => '${raw['prompt'] ?? raw['instruction'] ?? ''}';

  /// queued | running | paused | completed | failed | cancelled
  /// (tolerant: also 'waitingQueue'/'waiting'/'pending', 'succeeded',
  /// 'error').
  String get status => _norm('${raw['status'] ?? raw['state'] ?? ''}');

  static String _norm(String s) => switch (s.toLowerCase()) {
        'succeeded' => 'completed',
        'error' => 'failed',
        'waiting' || 'pending' || 'waitingqueue' || 'queued' => 'queued',
        _ => s.toLowerCase(),
      };

  bool get queued => status == 'queued';
  bool get running => status == 'running';
  bool get paused => status == 'paused';
  bool get completed => status == 'completed';
  bool get failed => status == 'failed';
  bool get terminal => completed || failed || status == 'cancelled';

  /// Server-provided queue position (排队位置); null when not reported.
  int? get queuePosition => (raw['queuePosition'] as num?)?.toInt();

  String? get permissionMode => raw['permissionMode'] as String?;

  int? get createdAt => (raw['createdAt'] as num?)?.toInt();
  int? get startedAt => (raw['startedAt'] as num?)?.toInt();
  int? get finishedAt => (raw['finishedAt'] as num?)?.toInt();

  /// Run duration when known (finishedAt - startedAt).
  int? get durationMs {
    final start = startedAt;
    final end = finishedAt;
    if (start == null || end == null || end <= start) return null;
    return end - start;
  }

  String? get sessionId => raw['sessionId'] as String?;
  String? get conversationId => raw['conversationId'] as String?;
  String? get error => raw['error'] as String?;
  String? get model => raw['model'] as String?;
}

/// Entitlement + quota snapshot for the page header. Carries two shapes:
/// the legacy desktop payload (quota minutes / earliest window, below) and
/// the 3.14 take-a-number view (getters at the bottom) — each desktop only
/// ever produces one of them.
class OffPeakStatus {
  final Map<String, dynamic> raw;
  OffPeakStatus(this.raw);

  /// codingPlanOnly / quota / unavailable / null (entitled).
  String? get reason {
    final r = raw['reason'] ?? raw['unavailableReason'];
    return r is String ? OffPeakError.normalize(r) : null;
  }

  bool get entitled => reason == null && raw['available'] != false;

  /// Monthly quota remaining, minutes (display: 小时/分钟).
  int? get quotaRemainingMinutes =>
      (raw['quotaRemainingMinutes'] as num?)?.toInt() ??
      (raw['remainingMinutes'] as num?)?.toInt();

  int? get quotaTotalMinutes =>
      (raw['quotaTotalMinutes'] as num?)?.toInt() ??
      (raw['totalMinutes'] as num?)?.toInt();

  /// When idle capacity is next expected (最早可用).
  int? get earliestAvailableAt =>
      (raw['earliestAvailableAt'] as num?)?.toInt() ??
      (raw['nextWindowAt'] as num?)?.toInt();

  /// When the exhausted quota resets, epoch ms (额度耗尽后的剩余等待).
  /// Tolerant: absolute-epoch fields at ms/s scale or an explicit remaining
  /// duration in ms/seconds.
  int? quotaResetRemainingMs(int nowMs) {
    final reset = (raw['quotaResetAt'] as num?)?.toInt() ??
        (raw['limitReachedResetAt'] as num?)?.toInt();
    if (reset != null) {
      final ms = reset < 100000000000 ? reset * 1000 : reset;
      return ms - nowMs;
    }
    final remMs = (raw['quotaResetRemainingMs'] as num?)?.toInt() ??
        (raw['remainingWaitSeconds'] as num?)?.toInt();
    if (remMs == null) return null;
    // Heuristic: seconds-based waits never reach an hour of magnitude.
    return remMs > 1000000 ? remMs : remMs * 1000;
  }

  // ------------------------------------------------ 3.14 take-a-number view

  /// getCodingPlanSupport's subscription gate (≥3.14 take-a-number era).
  /// Absent on legacy payloads → null.
  bool? get supported =>
      raw['supported'] is bool ? raw['supported'] as bool : null;

  /// getTakeNumberAvailability's verdict: may a new run take a number now.
  bool? get canTakeNumber =>
      raw['canTakeNumber'] is bool ? raw['canTakeNumber'] as bool : null;

  /// When taking a number opens up again, epoch ms (only sent while
  /// [canTakeNumber] is false). Tolerates s/ms scales — same convention as
  /// AutomationItem.nextRunAtMs.
  int? get nextTakeAtMs {
    final v = (raw['nextTakeAt'] as num?)?.toInt();
    if (v == null) return null;
    return v < 100000000000 ? v * 1000 : v;
  }

  /// A ≥3.14 status RPC failed — the S4 degraded view.
  bool get availabilityError => raw['availabilityError'] == true;

  /// UI branch: true renders the 3.14 four-state take-a-number header
  /// (S1–S4, see tool/design/offpeak-3-14-header-mock.html); false keeps
  /// the legacy quota/earliest/locked header.
  bool get takeNumberSemantics =>
      supported != null || canTakeNumber != null || availabilityError;
}

/// Classified off-peak failure (门槛/额度/服务不可用), used to pick the
/// exact official error copy in the UI.
class OffPeakError implements Exception {
  /// OffPeakError.codingPlanOnly / .quota / .unavailable / .other
  final String kind;
  final String message;
  final Object? cause;

  const OffPeakError(this.kind, this.message, [this.cause]);

  static const codingPlanOnly = 'codingPlanOnly';
  static const quota = 'quota';
  static const unavailable = 'unavailable';
  static const other = 'other';

  /// Maps a raw RPC failure message onto the official error states.
  /// Feature-absent desktops (every candidate method rejected) count as
  /// 服务暂不可用.
  static String normalize(String raw) {
    final m = raw.toLowerCase();
    if (m.contains('codingplan') ||
        m.contains('coding plan') ||
        m.contains('subscription') ||
        m.contains('订阅') ||
        // 3.12.3 structured errorCategory values also surface inside RPC
        // error text — eligibility_3101 is the coding-plan gate.
        m.contains('eligibility')) {
      return codingPlanOnly;
    }
    if (m.contains('quota') ||
        m.contains('额度') ||
        m.contains('limit') ||
        m.contains('exceeded')) {
      return quota;
    }
    if (m.contains('unavailable') ||
        m.contains('不可用') ||
        m.contains('no such method') ||
        m.contains('unknown method') ||
        m.contains('method not found') ||
        m.contains('unsupported') ||
        m.contains('network') ||
        m.contains('invalid_response')) {
      return unavailable;
    }
    return other;
  }

  /// Classifies a structured failure envelope (bridge-side zod shape,
  /// live-confirmed 2026-09-17):
  /// `{ok:false, failureStage, errorCategory, errorCode}` — answered as a
  /// NORMAL ack (no RPC error) by createTask and the lifecycle family.
  /// Returns null for anything else (void acks, legacy `{ok, error}`
  /// run-results) so callers keep their existing paths. Category mapping:
  /// eligibility_3101→codingPlanOnly, quota_3103→quota,
  /// network|invalid_response→unavailable, rest→other.
  static OffPeakError? structuredFrom(Object? res) {
    if (res is! Map || res['ok'] != false) return null;
    final category = res['errorCategory'];
    if (category is! String || category.isEmpty) return null;
    final code = res['errorCode'];
    return OffPeakError(
      switch (category) {
        'eligibility_3101' => codingPlanOnly,
        'quota_3103' => quota,
        'network' || 'invalid_response' => unavailable,
        _ => other,
      },
      code is String && code.isNotEmpty ? '$category ($code)' : category,
      res,
    );
  }

  factory OffPeakError.fromMessage(String message, [Object? cause]) =>
      OffPeakError(normalize(message), message, cause);

  @override
  String toString() => 'OffPeakError($kind): $message';
}
