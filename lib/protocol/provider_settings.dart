/// Desktop 3.14 `provider-settings` channel — the full provider management
/// surface that replaced the removed `model-provider` channel (gap window
/// 3.12.3–3.13, closed in 3.14).
///
/// Wire shapes below are probe-certified 2026-09-28 (notes.md
/// 「实现期前置定证」 + research-static.md; live probes
/// live_ps_crud2/step1/step1b_probe_test.dart):
///
/// - `getView` / `refresh` / every write return the full resolved view:
///   `{revision, providerTemplates[], providerOrder[], providers[]}`.
///   `revision` is the combined string `JSON.stringify([builtinRev,
///   personalRev])`. `providers[]` carries account (`account:*`) and
///   personal entries only — template-instance builtins do not appear.
/// - provider entry: `{providerId, providerName, enabled, accountState?,
///   executable, effectiveBuiltinConfig?, personalConfig?, effectiveConfig,
///   issues[{code, path, message}], models[]}`.
/// - model entry: `{modelId, builtin, personalExactConfig?,
///   useRecommendedConfig?, effectiveConfig, enabled, executable,
///   selectable, issues[]}`.
/// - `onDidChange` payload = the full view (facade `#i` refreshes first).
/// - Write shapes: `createPersonalProvider({templateId?|providerName?})` →
///   `{providerId, view}`; `savePersonalProviderOverlay(pid, overlay,
///   rulePatch?)` (overlay is `.strict()` patch semantics — keys not listed
///   are untouched); `deletePersonalProvider(pid)`;
///   `reorderPersonalProviders([pid…])`; `addPersonalModel(pid, modelId,
///   modelConfig, useRecommendedConfig)`; `renamePersonalModel(pid, old,
///   new)`; `deletePersonalModel(pid, modelId)`; `setPersonalModelEnabled(
///   pid, modelId, bool)`; `savePersonalModelDraft({providerId,
///   originalModelId, nextModelId, personalConfig, basedOnRevision,
///   useRecommendedConfig})`.
///
/// Desktop-side write guard quirk (probe round 4): two back-to-back writes
/// can fail with `Provider Settings snapshot revision conflict` — the
/// desktop guard asserts snapshot *identity* and a pending refresh swaps
/// the snapshot between the calls. The conflict is thrown BEFORE the write
/// lands, so [ProviderSettingsPort] retries once after a getView resync.
library;

/// Defensive list extraction — a shape drift degrades to an empty list
/// instead of throwing through the parse.
List<dynamic> _listOf(Object? v) => v is List ? v : const [];

/// Parses `revision` (`"[30,4]"`-style combined string) into a comparable
/// pair; null when the format drifts (callers must then accept the frame —
/// a parse failure must never wedge live refresh).
(int, int)? providerRevisionPair(String? revision) {
  if (revision == null || revision.length < 2) return null;
  final body = revision.substring(1, revision.length - 1);
  final parts = body.split(',');
  if (parts.length != 2) return null;
  final a = int.tryParse(parts[0].trim());
  final b = int.tryParse(parts[1].trim());
  if (a == null || b == null) return null;
  return (a, b);
}

/// Monotonic-application guard for view frames (writes responses and
/// onDidChange payloads race each other): a frame applies only when its
/// revision pair is strictly newer than the last applied one. Unknown
/// formats always apply.
class ProviderRevisionGuard {
  (int, int)? _last;

  static bool _newerThan((int, int) a, (int, int) b) =>
      a.$1 > b.$1 || (a.$1 == b.$1 && a.$2 > b.$2);

  bool accepts(String? revision) {
    final pair = providerRevisionPair(revision);
    if (pair == null) return true;
    final last = _last;
    if (last != null && !_newerThan(pair, last)) return false;
    return true;
  }

  void note(String? revision) {
    final pair = providerRevisionPair(revision);
    if (pair != null && (_last == null || _newerThan(pair, _last!))) {
      _last = pair;
    }
  }
}

/// Template name resolution (desktop `resolveProviderTemplateName`):
/// `templateNameMap[locale]` → `templateNameMap['en-US']` → `templateId`.
String resolveProviderTemplateName(
    Map<dynamic, dynamic>? nameMap, String templateId, String locale) {
  String? of(String key) {
    final v = nameMap?[key];
    return v is String && v.isNotEmpty ? v : null;
  }

  return of(locale) ?? of('en-US') ?? of('zh-CN') ?? templateId;
}

/// One issue of a provider or model view entry (`validateConfigSchema`).
class ProviderIssue {
  final String code;
  final String message;
  const ProviderIssue(this.code, this.message);

  static ProviderIssue? tryOf(Object? raw) {
    if (raw is! Map || raw['code'] == null) return null;
    return ProviderIssue('${raw['code']}', '${raw['message'] ?? raw['code']}');
  }
}

/// One model row of a provider view entry.
class ProviderModelEntry {
  final String modelId;
  final bool enabled;
  final bool executable;
  final bool builtin;

  /// Personal override config (`personalExactConfig`) — carries the
  /// user-set `properties.contextWindow` / `optionSpecs.maxOutputTokens`
  /// when the model is not on the recommended config.
  final Map<dynamic, dynamic>? personalExactConfig;

  /// Resolved config — prefill source for the edit dialog.
  final Map<dynamic, dynamic> effectiveConfig;
  final bool useRecommendedConfig;
  final List<ProviderIssue> issues;

  const ProviderModelEntry({
    required this.modelId,
    required this.enabled,
    required this.executable,
    required this.builtin,
    required this.personalExactConfig,
    required this.effectiveConfig,
    required this.useRecommendedConfig,
    required this.issues,
  });

  static ProviderModelEntry? tryOf(Object? raw) {
    if (raw is! Map || raw['modelId'] == null) return null;
    return ProviderModelEntry(
      modelId: '${raw['modelId']}',
      enabled: raw['enabled'] != false,
      executable: raw['executable'] == true,
      builtin: raw['builtin'] == true,
      personalExactConfig: raw['personalExactConfig'] is Map
          ? raw['personalExactConfig'] as Map<dynamic, dynamic>
          : null,
      effectiveConfig:
          raw['effectiveConfig'] is Map ? raw['effectiveConfig'] : const {},
      useRecommendedConfig: raw['useRecommendedConfig'] != false,
      issues: [
        for (final i in _listOf(raw['issues']))
          if (ProviderIssue.tryOf(i) case final issue?) issue,
      ],
    );
  }

  /// `effectiveConfig.properties.<key>` — manual-capability booleans.
  /// Missing keys read false (official T5 backfill: `?? false`).
  bool _propsBool(String key) =>
      effectiveConfig['properties'] is Map &&
      (effectiveConfig['properties'] as Map)[key] == true;

  bool get effSupportsJsonSchemaOutput =>
      _propsBool('supportsJsonSchemaOutput');

  bool get effSupportsNativeWebSearch => _propsBool('supportsNativeWebSearch');

  bool get effSupportsMidConversationSystem =>
      _propsBool('supportsMidConversationSystem');

  /// `effectiveConfig.properties.inputFormat.supportsImage` — the edit
  /// dialog's vision prefill and the model row's vision badge source.
  bool get effSupportsImage {
    final props = effectiveConfig['properties'];
    final fmt = props is Map ? props['inputFormat'] : null;
    return fmt is Map && fmt['supportsImage'] == true;
  }

  /// `effectiveConfig.optionSpecs.reasoningLevel.values` — the read-only
  /// reasoning chips source; empty hides the section (official T5).
  List<String> get effReasoningLevels {
    final specs = effectiveConfig['optionSpecs'];
    final rl = specs is Map ? specs['reasoningLevel'] : null;
    final values = rl is Map ? rl['values'] : null;
    return [for (final v in values is List ? values : const []) '$v'];
  }
}

/// One provider row of the view (account `account:*` or personal).
class ProviderEntry {
  final String providerId;
  final String providerName;
  final bool enabled;
  final bool executable;

  /// Account providers (`account:*`, 智谱 group) carry a non-null
  /// accountState; personal entries (自定义供应商 group) carry
  /// `personalConfig` instead.
  final Map<dynamic, dynamic>? accountState;
  final Map<dynamic, dynamic>? personalConfig;
  final Map<dynamic, dynamic> effectiveConfig;

  /// Template id when the entry was created from a providerTemplates row.
  final String? templateId;
  final List<ProviderIssue> issues;
  final List<ProviderModelEntry> models;

  const ProviderEntry({
    required this.providerId,
    required this.providerName,
    required this.enabled,
    required this.executable,
    required this.accountState,
    required this.personalConfig,
    required this.effectiveConfig,
    required this.templateId,
    required this.issues,
    required this.models,
  });

  bool get isAccount => accountState != null;

  /// Entitlement for account entries
  /// (`effectiveConfig.access.entitled`, zhipu-account access).
  bool get entitled =>
      _accessOf(effectiveConfig)?['entitled'] == true ||
      _accessOf(accountState)?['entitled'] == true;

  static Map<dynamic, dynamic>? _accessOf(Map<dynamic, dynamic>? cfg) {
    final access = cfg?['access'];
    return access is Map ? access : null;
  }

  /// Plaintext API key for personal entries (probe-certified: the view
  /// carries it on the wire) — the edit form's prefill.
  String? get apiKey {
    final acc = _accessOf(personalConfig) ?? _accessOf(effectiveConfig);
    final v = acc?['apiKey'];
    return v is String && v.isNotEmpty ? v : null;
  }

  /// `access.type` the overlay save must preserve (api-key |
  /// zhipu-coding-plan-api-key); personal default is `api-key`.
  String get accessType {
    final t = _accessOf(personalConfig)?['type'];
    return t is String && t.isNotEmpty ? t : 'api-key';
  }

  /// Resolved `api` block (`{type, baseUrl}`) — personal override first,
  /// then the effective (template-seeded) config.
  Map<dynamic, dynamic> get api {
    final pcApi = personalConfig?['api'];
    if (pcApi is Map && pcApi.isNotEmpty) return pcApi;
    final effApi = effectiveConfig['api'];
    if (effApi is Map) return effApi;
    return const {};
  }

  static ProviderEntry? tryOf(Object? raw) {
    if (raw is! Map || raw['providerId'] == null) return null;
    return ProviderEntry(
      providerId: '${raw['providerId']}',
      providerName: '${raw['providerName'] ?? raw['providerId']}',
      enabled: raw['enabled'] == true,
      executable: raw['executable'] == true,
      accountState:
          raw['accountState'] is Map ? raw['accountState'] : null,
      personalConfig:
          raw['personalConfig'] is Map ? raw['personalConfig'] : null,
      effectiveConfig:
          raw['effectiveConfig'] is Map ? raw['effectiveConfig'] : const {},
      templateId:
          raw['templateId'] is String ? raw['templateId'] as String : null,
      issues: [
        for (final i in _listOf(raw['issues']))
          if (ProviderIssue.tryOf(i) case final issue?) issue,
      ],
      models: [
        for (final m in _listOf(raw['models']))
          if (ProviderModelEntry.tryOf(m) case final entry?) entry,
      ],
    );
  }
}

/// One providerTemplates row (add-provider page); the config carries the
/// endpoint/access presets (`config.api.{type, baseUrl}`,
/// `config.access.apiKeyManagementUrl` — no apiKey on templates).
class ProviderTemplateEntry {
  final String templateId;
  final Map<dynamic, dynamic> nameMap;
  final Map<dynamic, dynamic> config;

  const ProviderTemplateEntry({
    required this.templateId,
    required this.nameMap,
    required this.config,
  });

  String name(String locale) =>
      resolveProviderTemplateName(nameMap, templateId, locale);

  String? get apiType {
    final v = _api['type'];
    return v is String && v.isNotEmpty ? v : null;
  }

  String? get baseUrl {
    final v = _api['baseUrl'];
    return v is String && v.isNotEmpty ? v : null;
  }

  String? get apiKeyManagementUrl {
    final access = config['access'];
    final v = access is Map ? access['apiKeyManagementUrl'] : null;
    return v is String && v.isNotEmpty ? v : null;
  }

  Map<dynamic, dynamic> get _api =>
      config['api'] is Map ? config['api'] as Map<dynamic, dynamic> : const {};

  /// 智谱-family templates (zai / bigmodel) group separately from 其他.
  bool get isZhipuFamily =>
      templateId.startsWith('zai-') || templateId.startsWith('bigmodel-');

  static ProviderTemplateEntry? tryOf(Object? raw) {
    if (raw is! Map || raw['templateId'] == null) return null;
    return ProviderTemplateEntry(
      templateId: '${raw['templateId']}',
      nameMap: raw['templateNameMap'] is Map
          ? raw['templateNameMap'] as Map<dynamic, dynamic>
          : const {},
      config: raw['config'] is Map ? raw['config'] : const {},
    );
  }
}

/// The parsed `provider-settings` view. Malformed parts degrade
/// field-by-field (a shape drift must degrade the page, not crash it).
class ProviderSettingsView {
  final String revision;
  final List<ProviderTemplateEntry> templates;
  final List<String> providerOrder;
  final List<ProviderEntry> providers;

  const ProviderSettingsView({
    required this.revision,
    required this.templates,
    required this.providerOrder,
    required this.providers,
  });

  static ProviderSettingsView parse(Object? res) {
    final map = res is Map ? res : const {};
    return ProviderSettingsView(
      revision: res is Map ? '${res['revision'] ?? ''}' : '',
      templates: [
        for (final t in _listOf(map['providerTemplates']))
          if (ProviderTemplateEntry.tryOf(t) case final entry?) entry,
      ],
      providerOrder: [
        for (final id in _listOf(map['providerOrder']))
          if (id is String || id is num) '$id',
      ],
      providers: [
        for (final p in _listOf(map['providers']))
          if (ProviderEntry.tryOf(p) case final entry?) entry,
      ],
    );
  }

  /// Personal providers in display order: `providerOrder` first (it only
  /// holds personal ids), then any personal entry missing from the order
  /// (fresh writes between two getView frames).
  List<ProviderEntry> get customProviders {
    final ordered = <ProviderEntry>[];
    final seen = <String>{};
    for (final id in providerOrder) {
      for (final p in providers) {
        if (!p.isAccount && p.providerId == id && seen.add(id)) {
          ordered.add(p);
        }
      }
    }
    for (final p in providers) {
      if (!p.isAccount && !seen.contains(p.providerId)) ordered.add(p);
    }
    return ordered;
  }

  /// Account entries in view order — the 智谱 group.
  List<ProviderEntry> get accountProviders =>
      [for (final p in providers) if (p.isAccount) p];
}

/// Effective context-window / max-output values for the model edit dialog
/// prefill: personal exact config first, then the resolved config.
({int? contextWindow, int? maxOutputTokens}) modelNumericLimits(
    ProviderModelEntry model) {
  int? read(Map<dynamic, dynamic>? cfg, String section, String key) {
    final sectionCfg = cfg?[section];
    final v = sectionCfg is Map ? sectionCfg[key] : null;
    return v is num ? v.toInt() : null;
  }

  return (
    contextWindow: read(model.personalExactConfig, 'properties',
            'contextWindow') ??
        read(model.effectiveConfig, 'properties', 'contextWindow'),
    maxOutputTokens: read(model.personalExactConfig, 'optionSpecs',
            'maxOutputTokens') ??
        read(model.effectiveConfig, 'optionSpecs', 'maxOutputTokens'),
  );
}

/// Channel-RPC surface of the provider-settings channel. The port takes the
/// session's [call] seam so tests can answer from local tables; every write
/// returns the refreshed full view (parse it with
/// [ProviderSettingsView.parse]).
class ProviderSettingsPort {
  final Future<dynamic> Function(String channel, String method,
      List<Object?> args) _call;

  /// One automatic retry for the desktop's snapshot-identity guard
  /// (`Provider Settings snapshot revision conflict` — thrown BEFORE the
  /// write lands, so the retry cannot double-apply). The resync getView
  /// lets the desktop's facade cache catch up with the previous write.
  static const _conflictMarker = 'revision conflict';

  const ProviderSettingsPort(this._call);

  Future<dynamic> _raw(String method, List<Object?> args) =>
      _call('provider-settings', method, args);

  /// Issue one write; on the snapshot-conflict error resync once via
  /// getView and retry the identical write (round-4 probe contract).
  Future<dynamic> _write(String method, List<Object?> args) async {
    try {
      return await _raw(method, args);
    } catch (e) {
      if ('$e'.contains(_conflictMarker)) {
        await getView();
        return _raw(method, args);
      }
      rethrow;
    }
  }

  Future<Object?> getView() => _raw('getView', const []);

  /// Returns the created provider's id; the refreshed view the desktop
  /// pairs with it is re-fetched by the caller's post-write reload.
  Future<String> createPersonalProvider(
      {String? templateId, String? providerName}) async {
    final res = await _write('createPersonalProvider', [
      {
        if (templateId != null) 'templateId': templateId,
        if (providerName != null) 'providerName': providerName,
      },
    ]);
    if (res is Map) {
      final id = res['providerId'];
      if (id != null) return '$id';
    }
    throw StateError('createPersonalProvider: no providerId in response');
  }

  Future<Object?> savePersonalProviderOverlay(String providerId,
      Map<String, Object?> overlay, Map<String, Object?>? rulePatch) =>
      _write('savePersonalProviderOverlay', [
        providerId,
        overlay,
        if (rulePatch != null) rulePatch,
      ]);

  Future<Object?> deletePersonalProvider(String providerId) =>
      _write('deletePersonalProvider', [providerId]);

  Future<Object?> renamePersonalProvider(String providerId, String name) =>
      savePersonalProviderOverlay(
          providerId, const {}, {'providerName': name});

  Future<Object?> setPersonalProviderEnabled(
          String providerId, bool enabled) =>
      savePersonalProviderOverlay(providerId, const {}, {'enabled': enabled});

  Future<Object?> reorderPersonalProviders(List<String> order) =>
      _write('reorderPersonalProviders', [order]);

  Future<Object?> reorderPersonalModels(String providerId,
          List<String> order) =>
      _write('reorderPersonalModels', [providerId, order]);

  Future<Object?> addPersonalModel(String providerId, String modelId,
          {Map<String, Object?> modelConfig = const {},
          bool useRecommendedConfig = true}) =>
      _write('addPersonalModel', [
        providerId,
        modelId,
        modelConfig,
        useRecommendedConfig,
      ]);

  Future<Object?> renamePersonalModel(
          String providerId, String modelId, String newModelId) =>
      _write('renamePersonalModel', [providerId, modelId, newModelId]);

  Future<Object?> deletePersonalModel(String providerId, String modelId) =>
      _write('deletePersonalModel', [providerId, modelId]);

  Future<Object?> setPersonalModelEnabled(
          String providerId, String modelId, bool enabled) =>
      _write('setPersonalModelEnabled', [providerId, modelId, enabled]);

  /// Manual (smart-config-off) model config save. `basedOnRevision` is the
  /// view revision string the dialog was rendered from (desktop-side CAS).
  Future<Object?> savePersonalModelDraft({
    required String providerId,
    required String modelId,
    required String newModelId,
    required Map<String, Object?> personalConfig,
    required String basedOnRevision,
    required bool useRecommendedConfig,
  }) =>
      _write('savePersonalModelDraft', [
        {
          'providerId': providerId,
          'originalModelId': modelId,
          'nextModelId': newModelId,
          'personalConfig': personalConfig,
          'basedOnRevision': basedOnRevision,
          'useRecommendedConfig': useRecommendedConfig,
        },
      ]);

  Future<Object?> testModelConnectivity(String providerId, String modelId) =>
      _raw('testModelConnectivity', [
        {'providerId': providerId, 'modelId': modelId},
      ]);
}
