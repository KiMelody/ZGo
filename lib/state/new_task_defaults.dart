import '../protocol/conversation.dart';

/// New-task default config assembly: merges the global UiSettings defaults
/// (and per-message overrides from local scheduled messages) into a
/// sanitized createSession `config` payload. Pure functions, shared by the
/// ChatPage draft path and the MessageScheduler fire path so both ship
/// identical configs (draft sheet display == payload, PRD A1).
///
/// Validation vocabularies come from prepareWorkspace ([WorkspacePrep]):
/// mode/thought option lists drift between desktop versions (protocol drift
/// 3.12.3), and an invalid model hard-fails session creation (same failure
/// class as the 09-25 "Reasoning level is required" cold-start fix), so a
/// default that does not apply to the current device is silently dropped —
/// no toast, "follow the desktop" semantics (PRD A3/A4/A5).

/// 合并优先级：perMessage（定时消息自带）> persisted（全局默认）> 无。
/// 空串 = 该项未设置（跟随桌面）。
Map<String, String> mergeNewTaskConfig(
  Map<String, String>? perMessage,
  Map<String, String> persisted,
) {
  String pick(String key) {
    final a = perMessage?[key];
    if (a != null && a.isNotEmpty) return a;
    final b = persisted[key];
    if (b != null && b.isNotEmpty) return b;
    return '';
  }

  return {
    'mode': pick('mode'),
    'model': pick('model'),
    'thought': pick('thought'),
  };
}

/// [perMessage] 里用户当场设置的键（非空值）——定时消息编辑器的选择，
/// 与 persisted（UiSettings 全局默认）的「跟随桌面」语义相对。
/// 传给 [sanitizeNewTaskConfig] 的 `explicitKeys`：这些值即使在
/// prepareWorkspace 失败或选项漂移后也恒发送（PRD model-value-split §3）。
Set<String> explicitNewTaskKeys(Map<String, String>? perMessage) => {
  for (final key in const ['mode', 'model', 'thought'])
    if ((perMessage?[key] ?? '').isNotEmpty) key,
};

/// 校验并清洗为 createSession config 载荷（provider/model 拆分在此完成）：
/// - model：prep 有模型选项时须 ∈ options，否则丢弃；prep 无模型选项时不校验
///   （与用户手选同语义，走 provider 目录兜底路径）；prep 为 null（无人值守
///   定时发送且 prepareWorkspace 失败）时不带，防失效默认打挂创建（PRD A7）。
/// - mode：∈ prep mode 选项 ∪ {build,edit,guarded,plan,yolo} 五档兜底词表
///   （guarded=桌面 3.15.1「自主模式」，edit=历史存储值，引擎层仍合法），否则丢弃。
/// - thought：恒含合法值（见 [effectiveNewTaskThought]）——缺 thought 会让
///   冷启动的 createSession 直接失败。
///
/// [explicitKeys] 里的键跳过上述「跟随桌面」校验恒发送（用户当场选择：
/// draft sheet 的 onDraftChange 或定时消息 perMessage 命中）——值来自用户
/// 刚看到的列表，prep 缺失/选项漂移不构成丢弃理由。种子默认值（UiSettings
/// 全局默认）不在集合内，保持静默降级（PRD model-value-split §3）。
///
/// 复合值按**首个** `/` 拆分（桌面 `FC` 语义）：provider=首段，model=余下
/// 全部——model id 本身可含 `/`（如 Command Code 的
/// `deepseek/deepseek-v4.1-flash`），尾斜杠拆分会把 provider 拼错。
Map<String, dynamic> sanitizeNewTaskConfig(
  Map<String, String> merged,
  WorkspacePrep? prep, {
  Set<String> explicitKeys = const {},
}) {
  final config = <String, dynamic>{};

  final model = merged['model'] ?? '';
  final modelOptions = prep?.option('model')?.options;
  final modelAllowed = (explicitKeys.contains('model') && model.isNotEmpty) ||
      (prep != null &&
          model.isNotEmpty &&
          (modelOptions == null ||
              modelOptions.isEmpty ||
              modelOptions.any((v) => v.value == model)));
  if (modelAllowed) {
    final idx = model.indexOf('/');
    if (idx > 0) {
      config['provider'] = model.substring(0, idx);
      config['model'] = model.substring(idx + 1);
    }
  }

  final mode = merged['mode'] ?? '';
  final modeOption = prep?.option('mode');
  const fallbackModes = {'build', 'edit', 'guarded', 'plan', 'yolo'};
  final modeAllowed = mode.isNotEmpty &&
      (explicitKeys.contains('mode') ||
          fallbackModes.contains(mode) ||
          (modeOption?.options.any((v) => v.value == mode) ?? false));
  if (modeAllowed) {
    config['mode'] = mode;
  }

  final thought = merged['thought'] ?? '';
  config['thought'] =
      explicitKeys.contains('thought') && thought.isNotEmpty
      ? thought
      : effectiveNewTaskThought(merged, prep);
  return config;
}

/// Effective thought level for a new-task config — the value createSession's
/// `config.thought` ships AND the config sheet's draft-state display (both
/// consumers must agree, no "displays unselected / sends max" divergence):
/// the explicit pick wins when it is one of the prep's `thought_level`
/// options, then prepareWorkspace's currentValue, then 'max'. The desktop
/// only merges its current level on a warm runtime; without a legal thought
/// a cold runtime fails model creation ("Reasoning level is required",
/// 09-25 diagnosis) — the web facade always carries thought.
/// Migrated from chat_page's `_effectiveDraftThought`.
String effectiveNewTaskThought(
  Map<String, String>? config,
  WorkspacePrep? prep,
) {
  final explicit = config?['thought'];
  final thoughtOption = prep?.option('thought_level');
  if (explicit != null &&
      explicit.isNotEmpty &&
      (thoughtOption?.options.any((v) => v.value == explicit) ?? false)) {
    return explicit;
  }
  final current = thoughtOption?.currentValue;
  if (current != null && '$current'.isNotEmpty) return '$current';
  return 'max';
}
