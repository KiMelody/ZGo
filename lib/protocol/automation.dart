import 'channel_client.dart';
import 'method_probe.dart';

/// Server-side automations (定时任务, the `zcode-cron-scheduler` subsystem
/// on the desktop). CRUD follows the remote's automation surface.
///
/// Method-name status (2026-08, confirmed against a live desktop where noted):
/// - `listAllAutomations` []  → CONFIRMED via the zemote channel explorer
///   probing (zcode-agent channel returns a list of automation objects).
/// - `createAutomation` / `updateAutomation` / `deleteAutomation` → best
///   effort per the web client's naming convention; NOT yet live-confirmed.
///   Each operation tries candidates in order (see [MethodProbe]) and
///   remembers the first method the desktop accepts; if every candidate is
///   rejected the FIRST error is rethrown so validation/permission failures
///   surface verbatim.
///
/// Wire schema of one automation item (zod-style, for protocol upgrades):
/// ```text
/// automationItem = {
///   automationId: string,            // stable id (also accepted: id)
///   title: string,
///   prompt: string,                  // instruction sent on each trigger
///   cronExpr?: string,               // 5-field cron, cron trigger
///   interval?: number(1..200),       // with intervalUnit, interval trigger
///   intervalUnit?: 'minute'|'hour'|'day'|'week'|'month'|'year',
///   recurring?: boolean,             // true = repeat forever
///   maxRuns?: number,                // finite cap when recurring=false
///   relativeDelayMinutes?: number,   // one-shot delay, max 1 year
///   model?: string, provider?: string, mode?: string, thoughtLevel?: string,
///   targetTaskId?: string,           // bind to an existing task/session
///   enabled?: boolean,               // list results carry 启用/停用
///   // 3.12.3 additions (gated by the port's `newWire` flag):
///   scheduleRule?: {                 // replaces interval+intervalUnit
///     unit: 'minute'|'hourly'|'daily'|'weekly'|'monthly'|'yearly',
///     interval: number, hour: 0-23, minute: 0-59, anchorAt?: ...,
///   },
///   modelSelection?: {               // replaces model/provider/thoughtLevel
///     providerId?: string, modelId?: string,
///     options?: {reasoningLevel?: string},
///   },
///   lifecycleStatus?: 'active'|'completed'|'failed'|'paused',
///   // run bookkeeping (present once the scheduler has fired):
///   lastRunAt?: number, lastResult?: 'success'|'error'|string,
/// }
/// ```
/// Trigger kinds are mutually exclusive: cronExpr (cron) / interval+intervalUnit
/// (repeat, optionally capped by maxRuns when recurring=false) /
/// relativeDelayMinutes (one-shot, mutually exclusive with an existing
/// automationId on create).
///
/// Desktops ≥3.12.3 ([newWire]) encode the interval trigger as a dual
/// `cronExpr` (mandatory ticket, locally compiled approximation) +
/// `scheduleRule` (the schedule the desktop actually follows) pair, switch
/// the model section to `modelSelection`, and take the dedicated
/// `setAutomationEnabled` method for 启停 (live-confirmed 2026-09-17); older
/// desktops keep the flat wire exactly as before — gated, never double-sent.
class AutomationPort {
  /// Binds one RPC: the channel is fixed by the port owner, method/args vary.
  final Future<dynamic> Function(String method, List<Object?> args) call;

  /// 3.12.3 wire gate (RemoteConnectionParams.atLeast(3, 12, 3) of the
  /// session's app_version; a desktop never changes version mid-session).
  final bool newWire;

  AutomationPort(this.call, {required this.newWire})
      : _probe = MethodProbe(call);

  static const _listMethods = ['listAllAutomations', 'listAutomations'];
  static const _createMethods = [
    'createAutomation',
    'upsertAutomation',
    'automationCreate',
  ];
  static const _updateMethods = [
    'updateAutomation',
    'upsertAutomation',
    'automationUpdate',
  ];
  static const _deleteMethods = [
    'deleteAutomation',
    'automationDelete',
    'removeAutomation',
  ];

  /// Run-now (立即运行). The desktop's own port method is
  /// `runAutomationNow({workspacePath, workspaceIdentity?, automationId})`;
  /// the others keep MethodProbe-style fallbacks for older builds.
  static const _runNowMethods = [
    'runAutomationNow',
    'triggerAutomation',
    'automationRunNow',
    'runNow',
  ];

  /// 启停专用方法 (3.12.3+, live-confirmed shape
  /// `[{...scope, automationId, enabled}]`). Single candidate: the gate that
  /// selects it also proves the method exists (probed on the live 3.12.3).
  static const _setEnabledMethods = ['setAutomationEnabled'];

  /// `updateAutomation` arg shapes: 0 = `[{automationId, ...fields}]`,
  /// 1 = `[automationId, fields]`.
  static const _updateShapes = 2;

  final MethodProbe _probe;
  int _updateShape = 0;

  // ------------------------------------------------------------------ list

  /// Lists every automation of the connected desktop.
  Future<List<AutomationItem>> list() async {
    final res = await _probe.run('list', _listMethods);
    dynamic items = res;
    if (res is Map) {
      // Some ports wrap the list: {automations: [...]} / {items: [...]}.
      items = res['automations'] ?? res['items'] ?? res['list'];
    }
    if (items is! List) return const [];
    return [
      for (final item in items)
        if (item is Map) AutomationItem(item.cast<String, dynamic>()),
    ];
  }

  // ---------------------------------------------------------------- create

  Future<AutomationItem> create(
      AutomationInput input, Map<String, dynamic> scope) async {
    final res = await _probe.run('create', _createMethods, argsOf: (_) => [
          // web 端自 3.12.1 时代就带 workspace scope
          // （createAutomation({workspacePath, workspaceIdentity?, ...form})），
          // 两版本都收——缺它报 SQLite parameter 8 绑定错。scope 前置，
          // 表单字段后展开不反被覆盖。
          {...scope, ...input.toWire(newWire: newWire)},
        ]);
    if (res is Map) return AutomationItem(res.cast<String, dynamic>());
    // Void-ish ack: echo the input back so the UI can refresh from list().
    return AutomationItem(input.toWire(newWire: newWire));
  }

  // ---------------------------------------------------------------- update

  /// Full update. Shape probing matches the create probing but also tries
  /// the positional `(id, fields)` form for update-family methods. The
  /// resolved method+shape go first on subsequent calls.
  Future<void> update(
      String id, AutomationInput input, Map<String, dynamic> scope) async {
    Object? firstError;
    for (var shape = _updateShape; shape < _updateShapes; shape++) {
      final wire = input.toWire(newWire: newWire);
      final args = switch (shape) {
        // Preferred update shape: updateAutomation({scope, automationId, ...form})
        // Shape 1 is the legacy positional fallback —
        // kept scope-less (only pre-3.12.3 desktops reach it; the SQLite
        // parameter error is itself a probe signal there).
        0 => <Object?>[
            {'automationId': id, ...scope, ...wire},
          ],
        _ => <Object?>[id, wire],
      };
      try {
        await _probe.run('update:$shape', _updateMethods, argsOf: (_) => args);
        _updateShape = shape;
        return;
      } on ChannelRpcError catch (e) {
        if (!MethodProbe.missingMethod(e.message)) rethrow;
        firstError ??= e;
      }
    }
    throw firstError ?? StateError('update: no candidate methods left');
  }

  /// Enable/disable (启停开关). New-wire desktops take the dedicated
  /// `setAutomationEnabled` with the workspace scope; older ones only
  /// accept a flag-only update ([update] probing sequence unchanged — the
  /// scope rides along there too, the web has always sent it).
  Future<void> setEnabled(
      String id, bool enabled, Map<String, dynamic> scope) async {
    if (newWire) {
      await _probe.run('setEnabled', _setEnabledMethods,
          argsOf: (_) => [
                {...scope, 'automationId': id, 'enabled': enabled},
              ]);
      return;
    }
    await update(id, AutomationInput(enabledOnly: enabled, existingId: id),
        scope);
  }

  // ---------------------------------------------------------------- delete

  Future<void> remove(String id) async {
    await _probe.run('delete', _deleteMethods, argsOf: (method) {
      // deleteAutomation([automationId]) vs automationDelete([id])
      return [
        if (method.startsWith('automation')) id else {'automationId': id},
      ];
    });
    // deleteAutomation 在手机桥上可能假成功
    // （void ack 但条目不消失，web 端的远程工作区桥无此问题）——回读
    // 验证，残留则抛错让用户感知删除失败，而非静默丢。
    final items = await list();
    if (items.any((item) => item.id == id)) {
      throw StateError('automation delete not confirmed, still listed: $id');
    }
  }

  // --------------------------------------------------------------- run now

  /// Triggers one immediate run (立即运行). [scope] carries
  /// `{workspacePath, workspaceIdentity?}` of the active workspace — the
  /// desktop requires it server-side. Returns 'queued' on acceptance or
  /// 'duplicate' when a run is already in flight; any rejection throws.
  Future<String> runNow(String id, Map<String, dynamic> scope) async {
    final res = await _probe.run('runNow', _runNowMethods,
        argsOf: (_) => [
              {
                ...scope,
                'automationId': id,
              },
            ]);
    final status = res is Map ? '${res['status'] ?? ''}' : '';
    return status == 'duplicate' ? 'duplicate' : 'queued';
  }
}

/// Form-side input for create/update. Exactly one trigger kind is set;
/// [toWire] emits only the fields belonging to that kind.
class AutomationInput {
  final String title;
  final String prompt;

  /// AutomationInput.triggerCron / triggerInterval / triggerOneShot.
  final String trigger;
  final String? cronExpr;
  final int? interval;
  final String? intervalUnit;
  final bool? recurring;
  final int? maxRuns;
  final int? relativeDelayMinutes;

  /// Interval-trigger anchor time (3.12.3 `scheduleRule.hour/minute` — pins
  /// when the interval actually flips). The form always prefills the current
  /// minute-truncated time so this is never null in practice; legacy
  /// inputs constructed without it fall back to "now" in [toWire].
  final int? anchorHour;
  final int? anchorMinute;

  final String? model;
  final String? provider;
  final String? mode;
  final String? thoughtLevel;
  final String? targetTaskId;

  /// Flag-only update (启停开关): [toWire] emits `{enabled}` alone.
  final bool? enabledOnly;

  /// Set on update so flag-only updates can round-trip the id.
  final String? existingId;

  const AutomationInput({
    this.title = '',
    this.prompt = '',
    this.trigger = triggerCron,
    this.cronExpr,
    this.interval,
    this.intervalUnit,
    this.anchorHour,
    this.anchorMinute,
    this.recurring,
    this.maxRuns,
    this.relativeDelayMinutes,
    this.model,
    this.provider,
    this.mode,
    this.thoughtLevel,
    this.targetTaskId,
    this.enabledOnly,
    this.existingId,
  });

  static const triggerCron = 'cron';
  static const triggerInterval = 'interval';
  static const triggerOneShot = 'oneShot';
  static const intervalUnits = [
    'minute',
    'hour',
    'day',
    'week',
    'month',
    'year',
  ];

  bool get isFlagOnly => enabledOnly != null;

  /// Validation used by the form before submit; returns an i18n key or null.
  String? validate() {
    if (isFlagOnly) return null;
    if (title.trim().isEmpty) return 'auto.err.title';
    if (prompt.trim().isEmpty) return 'auto.err.prompt';
    switch (trigger) {
      case triggerCron:
        if ((cronExpr ?? '').trim().isEmpty) return 'auto.err.cron';
      case triggerInterval:
        if (interval == null || interval! < 1) return 'auto.err.interval';
      case triggerOneShot:
        final d = relativeDelayMinutes ?? 0;
        if (d < 1 || d > 60 * 24 * 365) return 'auto.err.delay';
    }
    return null;
  }

  Map<String, dynamic> toWire({bool newWire = false}) {
    if (isFlagOnly) {
      // 启停由专用方法承接（newWire 端口不进这里），保持旧形态。
      return {
        if (existingId != null) 'automationId': existingId,
        'enabled': enabledOnly,
      };
    }
    return {
      'title': title.trim(),
      'prompt': prompt.trim(),
      ..._triggerWire(newWire: newWire),
    };
  }

  Map<String, dynamic> _triggerWire({required bool newWire}) {
    final optional = _modelWire(newWire: newWire);
    // 双字段 interval 编码：now 由 cron 编译与
    // scheduleRule 共享，锚点兜底不会跨分钟边界错位。
    final now = DateTime.now();
    final compiledCron = intervalCronExpr(
        intervalUnit, interval, anchorHour, anchorMinute,
        now: now);
    return switch (trigger) {
      triggerCron => {'cronExpr': cronExpr!.trim(), ...optional},
      triggerInterval => {
          if (newWire) ...{
            // cronExpr 是必填载体（无它一律报「非法的 cron 表达式：
            // undefined」）；scheduleRule 是可选附加，桌面接受存储并**以它
            // 计算调度**——本地编译的 cron 作门票+回退，rule 作真实调度。
            if (compiledCron != null) 'cronExpr': compiledCron,
            'scheduleRule': _scheduleRuleWire(now),
          } else ...{
            'interval': interval,
            if (intervalUnit != null) 'intervalUnit': intervalUnit,
          },
          'recurring': recurring ?? true,
          if (recurring == false && maxRuns != null) 'maxRuns': maxRuns,
          ...optional,
        },
      _ => {
          'relativeDelayMinutes': relativeDelayMinutes,
          // One-shot: non-recurring with a single run.
          'recurring': false,
          'maxRuns': 1,
          ...optional,
        },
    };
  }

  /// Model section: flat `model/provider/thoughtLevel` on the legacy wire,
  /// the `modelSelection` object on 3.12.3+ (`mode`/`targetTaskId` stay flat
  /// in both — no removal evidence).
  ///
  /// modelSelection 一旦发出，providerId/modelId
  /// 必填（zod strict："expected string, received undefined"）——provider 与
  /// model **齐备才发整个对象**；thoughtLevel 仅在该条件下进 options，
  /// 单独存在时无载体直接丢弃（3.12.3 平铺 thoughtLevel 被静默忽略；
  /// 表单中 thought 本就依附于模型选择）。
  Map<String, dynamic> _modelWire({required bool newWire}) {
    if (!newWire) {
      return {
        if (model != null && model!.isNotEmpty) 'model': model,
        if (provider != null && provider!.isNotEmpty) 'provider': provider,
        if (mode != null && mode!.isNotEmpty) 'mode': mode,
        if (thoughtLevel != null && thoughtLevel!.isNotEmpty)
          'thoughtLevel': thoughtLevel,
        if (targetTaskId != null && targetTaskId!.isNotEmpty)
          'targetTaskId': targetTaskId,
      };
    }
    final hasPair = provider != null &&
        provider!.isNotEmpty &&
        model != null &&
        model!.isNotEmpty;
    return {
      if (hasPair)
        'modelSelection': {
          'providerId': provider,
          'modelId': model,
          if (thoughtLevel != null && thoughtLevel!.isNotEmpty)
            'options': {'reasoningLevel': thoughtLevel},
        },
      if (mode != null && mode!.isNotEmpty) 'mode': mode,
      if (targetTaskId != null && targetTaskId!.isNotEmpty)
        'targetTaskId': targetTaskId,
    };
  }

  /// Interval trigger as the 3.12.3 `scheduleRule` object. `anchorAt` is
  /// NOT sent (桌面自动补，缺省=当前时刻)；missing anchors
  /// fall back to [now] (minute-truncated) so legacy inputs stay valid.
  Map<String, dynamic> _scheduleRuleWire(DateTime now) {
    return {
      // Unknown unit lands on 'daily' — the form default ('day') and the
      // read-side fallback agree on it, so round-trips stay stable.
      'unit': _ruleUnitByLegacyUnit[intervalUnit] ?? 'daily',
      'interval': interval,
      'hour': anchorHour ?? now.hour,
      'minute': anchorMinute ?? now.minute,
    };
  }

  /// Compiles the local cron for an interval trigger
  /// （cronExpr 是 create/update 触发器的必填载体，桌面在无它时报
  /// 「非法的 cron 表达式：undefined」；有 scheduleRule 时桌面优先用它计算
  /// 调度，此 cron 只是门票与 rule 缺失时的回退，取**合法且最接近的近似**）。
  ///
  /// 词表：minute×N→`*/N * * * *`；hour×N→`${m} */N * * *`；
  /// day×N→`${m} ${h} */${min(N,28)} * *`（钳 28 避开短月缺失日）；
  /// week×N→`${m} ${h} * * */N`；month×N→`${m} ${h} 1-28/${N} * *`；
  /// year×N→`${m} ${h} ${d} ${mo} *`。
  ///
  /// year 的锚点日/月没有 input 字段，取 [now] 的 day/month（N=1 精确、
  /// N>1 近似）——cron 只是回退载体，桌面优先按 scheduleRule 调度，近似
  /// 可接受。锚点 null 兜底 [now] 的时/分。interval 非法或 unit 未知时
  /// 返回 null（调用方省略该键，与旧行为的防御姿态一致）。
  static String? intervalCronExpr(
      String? unit, int? interval, int? anchorHour, int? anchorMinute,
      {DateTime? now}) {
    if (interval == null || interval < 1) return null;
    final t = now ?? DateTime.now();
    final h = anchorHour ?? t.hour;
    final m = anchorMinute ?? t.minute;
    return switch (unit) {
      'minute' => '*/$interval * * * *',
      'hour' => '$m */$interval * * *',
      'day' => '$m $h */${interval > 28 ? 28 : interval} * *',
      'week' => '$m $h * * */$interval',
      'month' => '$m $h 1-28/$interval * *',
      'year' => '$m $h ${t.day} ${t.month} *',
      _ => null,
    };
  }
}

/// Legacy intervalUnit → 3.12.3 scheduleRule unit vocabulary
/// (minute|hourly|daily|weekly|monthly|yearly); reversed for read-side
/// parsing below.
const _ruleUnitByLegacyUnit = {
  'minute': 'minute',
  'hour': 'hourly',
  'day': 'daily',
  'week': 'weekly',
  'month': 'monthly',
  'year': 'yearly',
};

final _legacyUnitByRuleUnit = {
  for (final e in _ruleUnitByLegacyUnit.entries) e.value: e.key,
};

/// Read-side view of one automation. Field names tolerate both
/// `automationId` and `id` shapes seen across protocol versions.
class AutomationItem {
  final Map<String, dynamic> raw;
  AutomationItem(this.raw);

  String get id => '${raw['automationId'] ?? raw['id'] ?? raw['taskId'] ?? ''}';

  String get title => '${raw['title'] ?? raw['name'] ?? ''}';
  String get prompt => '${raw['prompt'] ?? raw['instruction'] ?? ''}';
  String get cronExpr => '${raw['cronExpr'] ?? raw['cron'] ?? ''}';
  bool get enabled => raw['enabled'] != false && raw['paused'] != true;

  /// 3.12.3 scheduleRule object (interval-class trigger); null on legacy
  /// items whose interval fields stay flat.
  Map<String, dynamic>? get scheduleRule =>
      raw['scheduleRule'] is Map
          ? Map<String, dynamic>.from(raw['scheduleRule'] as Map)
          : null;

  /// 3.12.3 lifecycle marker: active|completed|failed|paused (null on
  /// legacy desktops).
  String? get lifecycleStatus => raw['lifecycleStatus'] as String?;

  int? get interval =>
      (raw['interval'] as num?)?.toInt() ??
      (scheduleRule?['interval'] as num?)?.toInt();
  String? get intervalUnit =>
      raw['intervalUnit'] as String? ??
      (scheduleRule == null
          ? null
          : _legacyUnitByRuleUnit['${scheduleRule!['unit']}']);

  /// Anchor time backfilled from scheduleRule (编辑表单回显).
  int? get anchorHour => (scheduleRule?['hour'] as num?)?.toInt();
  int? get anchorMinute => (scheduleRule?['minute'] as num?)?.toInt();

  bool get recurring => raw['recurring'] != false;
  int? get maxRuns => (raw['maxRuns'] as num?)?.toInt();
  int? get relativeDelayMinutes =>
      (raw['relativeDelayMinutes'] as num?)?.toInt();

  String? get model => raw['model'] as String?;
  String? get provider => raw['provider'] as String?;
  String? get mode => raw['mode'] as String?;
  String? get thoughtLevel => raw['thoughtLevel'] as String?;
  String? get targetTaskId => raw['targetTaskId'] as String?;

  /// Trigger kind derived from which fields are present. A 3.12.3
  /// scheduleRule marks the interval kind even when `interval` itself
  /// moved inside the rule object.
  String get trigger {
    if (cronExpr.isNotEmpty) return AutomationInput.triggerCron;
    if (relativeDelayMinutes != null) {
      return AutomationInput.triggerOneShot;
    }
    if (scheduleRule != null || interval != null) {
      return AutomationInput.triggerInterval;
    }
    return AutomationInput.triggerCron;
  }

  int? get lastRunAt => (raw['lastRunAt'] as num?)?.toInt();
  String? get lastResult => raw['lastResult'] as String?;

  /// Next scheduled fire, epoch ms (下次运行). Tolerates s/ms scales.
  int? get nextRunAtMs {
    final v = (raw['nextRunAt'] as num?)?.toInt() ??
        (raw['nextRunAtMs'] as num?)?.toInt();
    if (v == null) return null;
    return v < 100000000000 ? v * 1000 : v;
  }

  /// Completed-run counter shown as 已运行 n[/max] 次.
  int? get runCount =>
      (raw['runCount'] as num?)?.toInt() ??
      (raw['executedCount'] as num?)?.toInt();

  /// Prefills an edit form from this item.
  AutomationInput toInput() => AutomationInput(
        title: title,
        prompt: prompt,
        trigger: trigger,
        cronExpr: cronExpr.isEmpty ? null : cronExpr,
        interval: interval,
        intervalUnit: intervalUnit,
        anchorHour: anchorHour,
        anchorMinute: anchorMinute,
        recurring: recurring,
        maxRuns: maxRuns,
        relativeDelayMinutes: relativeDelayMinutes,
        model: model,
        provider: provider,
        mode: mode,
        thoughtLevel: thoughtLevel,
        targetTaskId: targetTaskId,
      );
}
