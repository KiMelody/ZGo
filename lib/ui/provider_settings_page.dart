import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../protocol/channel_client.dart';
import '../protocol/endpoint_models.dart';
import '../protocol/provider_settings.dart';
import '../state/device_session.dart';
import 'theme.dart';
import 'ui_settings.dart';

/// API format choices of the provider form — labels over the
/// certified provider-settings wire values (notes.md 附录 item 1).
const _apiFormats = [
  ('anthropic-messages', 'providers.formatAnthropic'),
  ('openai-chat-completions', 'providers.formatChatCompletions'),
  ('openai-responses', 'providers.formatResponses'),
];

/// Desktop ≥3.14 provider management (provider-settings channel): the
/// mobile two-step layout — grouped list page → provider detail
/// page. Reads/writes go through [ProviderSettingsPort]; every response
/// carries the full refreshed view, which replaces the local state behind
/// a monotonic revision guard (onDidChange payloads race write replies).
class ProviderSettingsPage extends StatefulWidget {
  final DeviceSession session;
  const ProviderSettingsPage({super.key, required this.session});

  @override
  State<ProviderSettingsPage> createState() => _ProviderSettingsPageState();
}

class _ProviderSettingsPageState extends State<ProviderSettingsPage> {
  ProviderSettingsView? _view;
  bool _loading = true;
  String? _error;
  void Function()? _cancelListener;
  final _guard = ProviderRevisionGuard();

  ProviderSettingsPort get _port =>
      ProviderSettingsPort(widget.session.callChannel);

  @override
  void initState() {
    super.initState();
    _load();
    _listen();
  }

  /// `provider-settings.onDidChange` pushes the full view
  /// after every desktop-side change — reload the list from it (≤2s after
  /// the desktop commits, per acceptance).
  void _listen() {
    final bridge = widget.session.bridge;
    if (bridge == null) return;
    _cancelListener = bridge.channels.addEventListener(
      Channels.providerSettings,
      'onDidChange',
      (data) => _apply(ProviderSettingsView.parse(data)),
    );
  }

  void _apply(ProviderSettingsView view) {
    if (!mounted) return;
    if (!_guard.accepts(view.revision)) return;
    _guard.note(view.revision);
    setState(() {
      _view = view;
      _loading = false;
      _error = null;
    });
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final res = await _port.getView();
      _apply(ProviderSettingsView.parse(res));
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  /// The detail page pops `true` when it deleted its provider (its own
  /// write-reply `_apply` dies with it, and the desktop does not push
  /// onDidChange for a remote link's own writes — live-certified 09-28).
  Future<void> _openDetail(ProviderEntry entry) async {
    final deleted = await Navigator.of(context).push(zRoute(
          (_) => _ProviderDetailPage(
              session: widget.session, providerId: entry.providerId),
        )) ??
        false;
    if (deleted) await _load();
  }

  @override
  void dispose() {
    _cancelListener?.call();
    super.dispose();
  }

  void _toast(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// Custom-group reorder: send the full adjusted personal id sequence —
  /// the view's providerOrder is the baseline (notes.md 附录 5); the
  /// 智谱 account group never participates.
  Future<void> _reorderProviders(int oldIndex, int newIndex) async {
    final view = _view;
    if (view == null) return;
    final ids = [for (final p in view.customProviders) p.providerId];
    if (oldIndex < 0 || oldIndex >= ids.length) return;
    if (newIndex > ids.length) newIndex = ids.length;
    final moved = ids.removeAt(oldIndex);
    ids.insert(newIndex, moved);
    try {
      final res = await _port.reorderPersonalProviders(ids);
      _apply(ProviderSettingsView.parse(res));
    } catch (e) {
      if (mounted) _toast(trP(context, 'providers.reorderFailed', ['$e']));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'providers.title')),
        actions: [
          IconButton(icon: const Icon(Icons.add), tooltip: tr(context, 'providers.addProvider'), onPressed: _openAdd),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(ZSpacing.emptyState),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.cloud_off,
                            size: 44, color: ZInk.ghost(context)),
                        const SizedBox(height: 16),
                        Text(
                            trP(context, 'providers.loadFailed', [_error!]),
                            textAlign: TextAlign.center,
                            style: ZType.body
                                .copyWith(color: ZInk.faint(context))),
                        const SizedBox(height: 20),
                        FilledButton(
                          onPressed: _load,
                          child: Text(tr(context, 'tasks.retry')),
                        ),
                      ],
                    ),
                  ),
                )
              : Center(
                  child: ConstrainedBox(
                    constraints:
                        const BoxConstraints(maxWidth: zContentMaxWidth),
                    child: RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(
                        padding:
                            zScreenPadding(context, bottom: ZSpacing.screen),
                        children: [
                          if (_view!.accountProviders.isNotEmpty) ...[
                            _sectionLabel(context, 'providers.sectionZhipu'),
                            Card(
                              clipBehavior: Clip.antiAlias,
                              child: Column(
                                children: [
                                  for (final (i, p)
                                      in _view!.accountProviders.indexed) ...[
                                    if (i > 0)
                                      Divider(
                                          height: 1,
                                          indent: ZListRow.padding.horizontal,
                                          color: ZInk.hairline(context)),
                                    _providerRow(context, p),
                                  ],
                                ],
                              ),
                            ),
                          ],
                          _sectionLabel(context, 'providers.sectionCustom'),
                          Card(
                            clipBehavior: Clip.antiAlias,
                            child: _view!.customProviders.isEmpty
                                ? Padding(
                                    padding: ZListRow.padding,
                                    child: Text(tr(context, 'providers.empty'),
                                        style: ZType.sub
                                            .copyWith(color: ZInk.faint(context))),
                                  )
                                : ReorderableListView.builder(
                                    shrinkWrap: true,
                                    buildDefaultDragHandles: false,
                                    physics: const NeverScrollableScrollPhysics(),
                                    onReorderItem: _reorderProviders,
                                    itemCount: _view!.customProviders.length,
                                    itemBuilder: (context, index) =>
                                        _providerTile(
                                            context,
                                            _view!.customProviders[index],
                                            index),
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
    );
  }

  Future<void> _openAdd() async {
    await Navigator.of(context).push(zRoute(
      (_) => _AddProviderPage(session: widget.session),
    ));
    await _load();
  }

  Widget _sectionLabel(BuildContext context, String key) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, ZSpacing.cardGap, 4, 8),
      child: Text(tr(context, key),
          style: ZType.sub.copyWith(color: ZInk.muted(context))),
    );
  }

  /// Reorderable custom-provider row: drag handle + the shared provider
  /// row (divider rides inside the tile so it moves with the row).
  Widget _providerTile(BuildContext context, ProviderEntry p, int index) {
    return Column(
      key: ValueKey('provider-${p.providerId}'),
      children: [
        if (index > 0)
          Divider(
              height: 1,
              indent: ZListRow.padding.horizontal,
              color: ZInk.hairline(context)),
        Row(
          children: [
            ReorderableDragStartListener(
              index: index,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 4, vertical: ZListRow.gap),
                child: Icon(Icons.drag_indicator,
                    size: 18,
                    color: ZInk.ghost(context),
                    semanticLabel:
                        tr(context, 'providers.reorderProviders')),
              ),
            ),
            Expanded(child: _providerRow(context, p)),
          ],
        ),
      ],
    );
  }

  Widget _providerRow(BuildContext context, ProviderEntry p) {
    final usable = p.executable;
    final ink = usable ? ZInk.solid(context) : ZInk.faint(context);
    return InkWell(
      onTap: () => _openDetail(p),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: ZListRow.twoLineHeight),
        child: Padding(
          padding: ZListRow.padding,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      p.providerName,
                      style: ZType.body.copyWith(color: ink),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (!usable)
                      Text(tr(context, 'providers.notExecutable'),
                          style: ZType.caption
                              .copyWith(color: ZInk.faint(context))),
                  ],
                ),
              ),
              if (p.isAccount && !p.entitled)
                Text(tr(context, 'providers.notEntitled'),
                    style: ZType.caption.copyWith(color: ZInk.muted(context))),
              Icon(Icons.chevron_right, size: 18, color: ZInk.ghost(context)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Add-provider page (form): template groups 智谱 / 其他 plus the
/// free-form custom entry. Tapping a template CREATES the provider
/// immediately (disabled, seeded with the template's endpoint/access
/// presets) and opens its detail page — no interim form.
class _AddProviderPage extends StatefulWidget {
  final DeviceSession session;
  const _AddProviderPage({required this.session});

  @override
  State<_AddProviderPage> createState() => _AddProviderPageState();
}

class _AddProviderPageState extends State<_AddProviderPage> {
  List<ProviderTemplateEntry> _templates = const [];
  bool _loading = true;
  String? _error;
  String? _busyTemplate;

  ProviderSettingsPort get _port =>
      ProviderSettingsPort(widget.session.callChannel);

  String get _locale => UiSettingsProvider.of(context)?.locale ?? 'zh-CN';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await _port.getView();
      final view = ProviderSettingsView.parse(res);
      if (mounted) {
        setState(() {
          _templates = view.templates;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  Future<void> _createFromTemplate(ProviderTemplateEntry template) async {
    if (_busyTemplate != null) return;
    setState(() => _busyTemplate = template.templateId);
    try {
      final pid = await _port.createPersonalProvider(
          templateId: template.templateId);
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(zRoute(
        (_) => _ProviderDetailPage(session: widget.session, providerId: pid),
      ));
    } catch (e) {
      if (mounted) _toast(trP(context, 'providers.addFailed', ['$e']));
    } finally {
      if (mounted) setState(() => _busyTemplate = null);
    }
  }

  Future<void> _createCustom() async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _NamePromptDialog(
        title: tr(context, 'providers.addCustom'),
        label: tr(context, 'providers.providerName'),
      ),
    );
    if (name == null) return;
    try {
      final pid =
          await _port.createPersonalProvider(providerName: name);
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(zRoute(
        (_) => _ProviderDetailPage(session: widget.session, providerId: pid),
      ));
    } catch (e) {
      if (mounted) _toast(trP(context, 'providers.addFailed', ['$e']));
    }
  }

  void _toast(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final zhipu = [
      for (final t in _templates)
        if (t.isZhipuFamily) t,
    ];
    final others = [
      for (final t in _templates)
        if (!t.isZhipuFamily) t,
    ];
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'providers.addProvider'))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(trP(context, 'providers.loadFailed', [_error!]),
                          textAlign: TextAlign.center,
                          style: ZType.body
                              .copyWith(color: ZInk.faint(context))),
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: _load,
                        child: Text(tr(context, 'tasks.retry')),
                      ),
                    ],
                  ),
                )
              : Center(
                  child: ConstrainedBox(
                    constraints:
                        const BoxConstraints(maxWidth: zContentMaxWidth),
                    child: ListView(
                      padding:
                          zScreenPadding(context, bottom: ZSpacing.screen),
                      children: [
                        if (zhipu.isNotEmpty) ...[
                          _label(context, 'providers.sectionZhipu'),
                          _templateCard(zhipu),
                        ],
                        _label(context, 'providers.sectionOther'),
                        _templateCard(others),
                        Card(
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: _createCustom,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                  minHeight: ZListRow.singleLineHeight),
                              child: Padding(
                                padding: ZListRow.padding,
                                child: Row(
                                  children: [
                                    Icon(Icons.add,
                                        size: 18, color: ZColors.sky500),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                          tr(context, 'providers.addCustom'),
                                          style: ZType.body.copyWith(
                                              color: ZColors.sky500)),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
    );
  }

  Widget _label(BuildContext context, String key) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, ZSpacing.cardGap, 4, 8),
      child: Text(tr(context, key),
          style: ZType.sub.copyWith(color: ZInk.muted(context))),
    );
  }

  Widget _templateCard(List<ProviderTemplateEntry> templates) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (final (i, t) in templates.indexed) ...[
            if (i > 0)
              Divider(
                  height: 1,
                  indent: ZListRow.padding.horizontal,
                  color: ZInk.hairline(context)),
            InkWell(
              onTap: () => _createFromTemplate(t),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                    minHeight: ZListRow.singleLineHeight),
                child: Padding(
                  padding: ZListRow.padding,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(t.name(_locale),
                            style: ZType.body
                                .copyWith(color: ZInk.solid(context))),
                      ),
                      if (_busyTemplate == t.templateId)
                        const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2))
                      else
                        Icon(Icons.chevron_right,
                            size: 18, color: ZInk.ghost(context)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Provider detail (inline-edit form). Personal entries carry the
/// full form (enable / baseUrl / api format / api key / models); account
/// entries show the plan state and the model management area only.
class _ProviderDetailPage extends StatefulWidget {
  final DeviceSession session;
  final String providerId;
  const _ProviderDetailPage({required this.session, required this.providerId});

  @override
  State<_ProviderDetailPage> createState() => _ProviderDetailPageState();
}

class _ProviderDetailPageState extends State<_ProviderDetailPage> {
  ProviderSettingsView? _view;
  bool _loading = true;
  String? _error;
  void Function()? _cancelListener;
  final _guard = ProviderRevisionGuard();

  final _baseUrlController = TextEditingController();
  final _apiKeyController = TextEditingController();
  String _apiType = 'anthropic-messages';
  bool _obscureApiKey = true;
  bool _seeded = false;
  bool _saving = false;

  ProviderSettingsPort get _port =>
      ProviderSettingsPort(widget.session.callChannel);

  ProviderEntry? get _entry {
    final view = _view;
    if (view == null) return null;
    for (final p in view.providers) {
      if (p.providerId == widget.providerId) return p;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _load();
    _listen();
  }

  void _listen() {
    final bridge = widget.session.bridge;
    if (bridge == null) return;
    _cancelListener = bridge.channels.addEventListener(
      Channels.providerSettings,
      'onDidChange',
      (data) => _apply(ProviderSettingsView.parse(data)),
    );
  }

  void _apply(ProviderSettingsView view) {
    if (!mounted) return;
    if (!_guard.accepts(view.revision)) return;
    _guard.note(view.revision);
    setState(() {
      _view = view;
      _loading = false;
      _error = null;
    });
    final entry = _entry;
    if (!_seeded && entry != null && !entry.isAccount) _seed(entry);
  }

  /// Seed the form once from the first view; later frames (desktop-side
  /// or own writes) must never clobber in-progress edits.
  void _seed(ProviderEntry entry) {
    final api = entry.api;
    _baseUrlController.text = '${api['baseUrl'] ?? ''}';
    final type = api['type'];
    if (type is String && _apiFormats.any((f) => f.$1 == type)) {
      _apiType = type;
    }
    _apiKeyController.text = entry.apiKey ?? '';
    _seeded = true;
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final res = await _port.getView();
      _apply(ProviderSettingsView.parse(res));
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _cancelListener?.call();
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  void _toast(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  // --- personal-provider writes -------------------------------------------

  Future<void> _toggleEnabled(bool enabled) async {
    try {
      // Every write replies with the full refreshed view — apply it
      // directly instead of waiting for onDidChange to arrive.
      final res =
          await _port.setPersonalProviderEnabled(widget.providerId, enabled);
      _apply(ProviderSettingsView.parse(res));
    } catch (e) {
      if (!mounted) return;
      _toast(trP(context, 'providers.toggleFailed', ['$e']));
    }
  }

  Future<void> _saveForm() async {
    final entry = _entry;
    if (entry == null || _saving) return;
    final baseUrl = _baseUrlController.text.trim();
    setState(() => _saving = true);
    try {
      final res = await _port.savePersonalProviderOverlay(widget.providerId, {
        if (baseUrl.isNotEmpty)
          'api': {'type': _apiType, 'baseUrl': baseUrl},
        'access': {
          'type': entry.accessType,
          if (_apiKeyController.text.trim().isNotEmpty)
            'apiKey': _apiKeyController.text.trim(),
        },
      }, null);
      _apply(ProviderSettingsView.parse(res));
      if (mounted) _toast(tr(context, 'providers.saved'));
    } catch (e) {
      if (mounted) _toast(trP(context, 'providers.saveFailed', ['$e']));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _rename() async {
    final entry = _entry;
    if (entry == null) return;
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _NamePromptDialog(
        title: tr(context, 'providers.renameProvider'),
        label: tr(context, 'providers.providerName'),
        initial: entry.providerName,
      ),
    );
    if (name == null || name.trim().isEmpty || name.trim() == entry.providerName) {
      return;
    }
    try {
      final res =
          await _port.renamePersonalProvider(widget.providerId, name.trim());
      _apply(ProviderSettingsView.parse(res));
    } catch (e) {
      if (mounted) _toast(trP(context, 'providers.renameFailed', ['$e']));
    }
  }

  Future<void> _delete() async {
    final entry = _entry;
    if (entry == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(trP(
            context, 'providers.deleteProviderTitle', [entry.providerName])),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr(context, 'devices.add.cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: ZInk.dangerTone(context),
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr(context, 'providers.confirmDelete')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _port.deletePersonalProvider(widget.providerId);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) _toast(trP(context, 'providers.deleteFailed', ['$e']));
    }
  }

  // --- model writes --------------------------------------------------------

  Future<void> _reorderModels(int oldIndex, int newIndex) async {
    final entry = _entry;
    if (entry == null) return;
    final ids = [for (final m in entry.models) m.modelId];
    if (oldIndex < 0 || oldIndex >= ids.length) return;
    if (newIndex > ids.length) newIndex = ids.length;
    final moved = ids.removeAt(oldIndex);
    ids.insert(newIndex, moved);
    // Only personal models participate in the wire order (builtin rows
    // keep their resolved positions).
    final builtinBy = {for (final m in entry.models) m.modelId: m.builtin};
    final personalOrder = [
      for (final id in ids)
        if (builtinBy[id] == false) id,
    ];
    if (personalOrder.length < 2) return;
    try {
      final res =
          await _port.reorderPersonalModels(widget.providerId, personalOrder);
      _apply(ProviderSettingsView.parse(res));
    } catch (e) {
      if (mounted) _toast(trP(context, 'providers.reorderFailed', ['$e']));
    }
  }

  Future<void> _showModelDialog(ProviderModelEntry? existing) async {
    final entry = _entry;
    if (entry == null) return;
    final limits =
        existing == null ? null : modelNumericLimits(existing);
    final result = await showDialog<_ModelDialogResult>(
      context: context,
      builder: (context) => _ModelDialog(
        title: tr(context,
            existing == null ? 'providers.addModel' : 'providers.editModel'),
        initialModelId: existing?.modelId,
        initialSmart: existing?.useRecommendedConfig ?? true,
        initialContextWindow: limits?.contextWindow,
        initialMaxOutput: limits?.maxOutputTokens,
        initialVision: existing?.effSupportsImage ?? false,
        initialJsonSchema: existing?.effSupportsJsonSchemaOutput ?? false,
        initialWebSearch: existing?.effSupportsNativeWebSearch ?? false,
        initialMidSystem: existing?.effSupportsMidConversationSystem ?? false,
        // Values come from the effective config; a fresh model
        // shows the recommended low/high/max trio.
        reasoningLevels:
            existing?.effReasoningLevels ?? const ['low', 'high', 'max'],
        isEdit: existing != null,
        fetchIds: entry.isAccount ? null : _fetchEndpointIds,
      ),
    );
    if (result == null) return;
    final smart = result.smart;
    // Manual-save whitelist (extractManualModelConfig): context
    // window + the three capability booleans (always written, true or
    // false) + inputFormat as the three-key pick
    // {supportsImage, supportsVideo, supportsPdf} (video/pdf have no UI
    // switches and stay false). The reasoning level stays unwritten — the
    // overlay merge falls back to the template's recommended levels, so we
    // never pin them down.
    final config = <String, Object?>{
      if (!smart)
        'properties': {
          if (result.contextWindow != null)
            'contextWindow': result.contextWindow,
          'supportsJsonSchemaOutput': result.jsonSchema,
          'supportsNativeWebSearch': result.webSearch,
          'supportsMidConversationSystem': result.midSystem,
          'inputFormat': {
            'supportsImage': result.vision,
            'supportsVideo': false,
            'supportsPdf': false,
          },
        },
      if (!smart && result.maxOutput != null)
        'optionSpecs': {'maxOutputTokens': result.maxOutput},
    };
    try {
      if (existing == null) {
        final res = await _port.addPersonalModel(widget.providerId, result.modelId,
            modelConfig: config, useRecommendedConfig: smart);
        _apply(ProviderSettingsView.parse(res));
      } else {
        if (result.modelId != existing.modelId) {
          final res = await _port.renamePersonalModel(
              widget.providerId, existing.modelId, result.modelId);
          // Applying the rename reply refreshes the revision the draft
          // below CASes on — never reuse the pre-rename one.
          _apply(ProviderSettingsView.parse(res));
        }
        final configChanged = smart != existing.useRecommendedConfig ||
            (!smart &&
                (result.contextWindow != limits?.contextWindow ||
                    result.maxOutput != limits?.maxOutputTokens ||
                    result.vision != existing.effSupportsImage ||
                    result.jsonSchema != existing.effSupportsJsonSchemaOutput ||
                    result.webSearch != existing.effSupportsNativeWebSearch ||
                    result.midSystem !=
                        existing.effSupportsMidConversationSystem));
        if (configChanged) {
          final res = await _port.savePersonalModelDraft(
            providerId: widget.providerId,
            modelId: result.modelId,
            newModelId: result.modelId,
            personalConfig: config,
            basedOnRevision: _view?.revision ?? '',
            useRecommendedConfig: smart,
          );
          _apply(ProviderSettingsView.parse(res));
        }
      }
    } catch (e) {
      if (mounted) _toast(trP(context, 'providers.modelSaveFailed', ['$e']));
    }
  }

  Future<void> _deleteModel(ProviderModelEntry model) async {
    try {
      final res =
          await _port.deletePersonalModel(widget.providerId, model.modelId);
      _apply(ProviderSettingsView.parse(res));
    } catch (e) {
      if (mounted) _toast(trP(context, 'providers.modelDeleteFailed', ['$e']));
    }
  }

  Future<void> _toggleModel(ProviderModelEntry model, bool enabled) async {
    try {
      final res = await _port.setPersonalModelEnabled(
          widget.providerId, model.modelId, enabled);
      _apply(ProviderSettingsView.parse(res));
    } catch (e) {
      if (mounted) _toast(trP(context, 'providers.toggleFailed', ['$e']));
    }
  }

  Future<void> _testModel(ProviderModelEntry model) async {
    try {
      final res =
          await _port.testModelConnectivity(widget.providerId, model.modelId);
      final ok = res is Map && res['success'] == true;
      if (!mounted) return;
      _toast(ok
          ? trP(context, 'providers.testOk', [model.modelId])
          : trP(context, 'providers.testFailed', [
              '${res is Map && res['error'] is Map ? (res['error'] as Map)['message'] ?? res['error'] : res}'
            ]));
    } catch (e) {
      if (mounted) {
        _toast(trP(context, 'providers.testFailed', ['$e']));
      }
    }
  }

  /// Fetches the endpoint's model ids with the form's CURRENT (unsaved)
  /// values — both /models entries read these first, per the design.
  Future<List<String>?> _fetchEndpointIds() async {
    try {
      return await fetchEndpointModels(
        baseUrl: _baseUrlController.text.trim(),
        apiType: _apiType,
        apiKey: _apiKeyController.text.trim().isEmpty
            ? null
            : _apiKeyController.text.trim(),
      );
    } on EndpointModelsException catch (e) {
      if (mounted) {
        _toast(switch (e.kind) {
          EndpointModelsErrorKind.network =>
            trP(context, 'providers.fetchFailed.network', [e.detail]),
          EndpointModelsErrorKind.unauthorized =>
            tr(context, 'providers.fetchFailed.unauthorized'),
          EndpointModelsErrorKind.parse =>
            trP(context, 'providers.fetchFailed.parse', [e.detail]),
        });
      }
      return null;
    } catch (e) {
      if (mounted) {
        _toast(trP(context, 'providers.fetchFailed.network', ['$e']));
      }
      return null;
    }
  }

  Future<void> _fetchEndpointModels() async {
    final existing = _entry?.models.map((m) => m.modelId).toSet() ?? {};
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _FetchModelsSheet(
        baseUrl: _baseUrlController.text.trim(),
        apiKey: _apiKeyController.text.trim(),
        apiType: _apiType,
        existing: existing,
        onAdd: (ids) async {
          for (final id in ids) {
            final res = await _port.addPersonalModel(widget.providerId, id);
            _apply(ProviderSettingsView.parse(res));
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final entry = _entry;
    final name = entry?.providerName ?? widget.providerId;
    return Scaffold(
      appBar: AppBar(
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (entry != null && !entry.isAccount)
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'rename') _rename();
                if (v == 'delete') _delete();
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'rename',
                  child: Text(tr(context, 'providers.renameProvider')),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: Text(tr(context, 'providers.deleteProvider')),
                ),
              ],
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : entry == null
              ? Center(
                  child: Text(trP(context, 'providers.loadFailed',
                      [_error ?? tr(context, 'providers.gone')]),
                      textAlign: TextAlign.center,
                      style:
                          ZType.body.copyWith(color: ZInk.faint(context))))
              : Center(
                  child: ConstrainedBox(
                    constraints:
                        const BoxConstraints(maxWidth: zContentMaxWidth),
                    child: RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(
                        padding:
                            zScreenPadding(context, bottom: ZSpacing.screen),
                        children: [
                          if (entry.isAccount)
                            _accountCard(context, entry)
                          else ...[
                            _personalFormCard(context, entry),
                            const SizedBox(height: ZSpacing.cardGap),
                          ],
                          _modelsCard(context, entry),
                        ],
                      ),
                    ),
                  ),
                ),
    );
  }

  // --- cards ---------------------------------------------------------------

  Widget _accountCard(BuildContext context, ProviderEntry entry) {
    final access = entry.effectiveConfig['access'];
    final mode = access is Map ? '${access['mode'] ?? ''}' : '';
    return Card(
      child: Padding(
        padding: ZListRow.padding,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.providerName, style: ZType.bodyStrong),
                  if (mode.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(_accountModeLabel(mode),
                          style: ZType.caption
                              .copyWith(color: ZInk.muted(context))),
                    ),
                ],
              ),
            ),
            Text(
              tr(context, entry.entitled
                  ? 'providers.entitled'
                  : 'providers.notEntitled'),
              style: ZType.caption.copyWith(
                  color: entry.entitled
                      ? ZInk.successTone(context)
                      : ZInk.muted(context)),
            ),
          ],
        ),
      ),
    );
  }

  String _accountModeLabel(String mode) => switch (mode) {
        'start-plan' => tr(context, 'providers.mode.startPlan'),
        'individual-coding-plan' =>
          tr(context, 'providers.mode.individualCodingPlan'),
        'team-coding-plan' => tr(context, 'providers.mode.teamCodingPlan'),
        'off-peak' => tr(context, 'providers.mode.offPeak'),
        _ => mode,
      };

  Widget _personalFormCard(BuildContext context, ProviderEntry entry) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(ZSpacing.card),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(tr(context, 'providers.enableProvider'),
                      style: ZType.bodyStrong),
                ),
                Switch(
                  value: entry.enabled,
                  onChanged: _toggleEnabled,
                ),
              ],
            ),
            const SizedBox(height: ZSpacing.card),
            TextField(
              controller: _baseUrlController,
              decoration: InputDecoration(
                labelText: tr(context, 'providers.baseUrl'),
                hintText: 'https://api.example.com/v1',
              ),
            ),
            const SizedBox(height: 10),
            _ApiFormatField(
              value: _apiType,
              onChanged: (v) => setState(() => _apiType = v),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _apiKeyController,
              obscureText: _obscureApiKey,
              decoration: InputDecoration(
                labelText: tr(context, 'providers.apiKeyField'),
                suffixIcon: IconButton(
                  icon: Icon(_obscureApiKey
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined),
                  onPressed: () =>
                      setState(() => _obscureApiKey = !_obscureApiKey),
                ),
              ),
            ),
            if (_templateApiKeyUrl(entry) != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => _openApiKeyUrl(_templateApiKeyUrl(entry)!),
                  child: Text(tr(context, 'providers.getApiKey'),
                      style: ZType.sub
                          .copyWith(color: ZColors.sky500)),
                ),
              ),
            for (final issue in entry.issues)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(issue.message,
                    style: ZType.caption
                        .copyWith(color: ZInk.warningTone(context))),
              ),
            const SizedBox(height: ZSpacing.card),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _saving ? null : _saveForm,
                child: Text(tr(context, 'devices.rename.save')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 模板预设的「获取 API Key」外链（access.apiKeyManagementUrl）。
  String? _templateApiKeyUrl(ProviderEntry entry) {
    final t = entry.templateId;
    // The view entry's templateConfig is the authoritative source when the
    // desktop pairs it; the add-page templates are the fallback lookup.
    final view = _view;
    if (view != null) {
      for (final template in view.templates) {
        if (template.templateId == t) return template.apiKeyManagementUrl;
      }
    }
    return null;
  }

  Future<void> _openApiKeyUrl(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (e) {
      if (mounted) _toast('$e');
    }
  }

  Widget _modelsCard(BuildContext context, ProviderEntry entry) {
    final models = entry.models;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(tr(context, 'providers.modelList'),
                        style: ZType.bodyStrong),
                  ),
                  if (!entry.isAccount)
                    TextButton(
                      onPressed: _fetchEndpointModels,
                      child: Text(tr(context, 'providers.fetchFromEndpoint'),
                          style: ZType.sub
                              .copyWith(color: ZColors.sky500)),
                    ),
                  TextButton(
                    onPressed: () => _showModelDialog(null),
                    child: Text(tr(context, 'providers.addModel'),
                        style:
                            ZType.sub.copyWith(color: ZColors.sky500)),
                  ),
                ],
              ),
            ),
            if (models.isEmpty)
              Padding(
                padding: ZListRow.padding,
                child: Text(tr(context, 'providers.noModels'),
                    style:
                        ZType.sub.copyWith(color: ZInk.faint(context))),
              )
            else
              ReorderableListView.builder(
                shrinkWrap: true,
                buildDefaultDragHandles: false,
                physics: const NeverScrollableScrollPhysics(),
                onReorderItem: _reorderModels,
                itemCount: models.length,
                itemBuilder: (context, index) =>
                    _modelRow(context, models[index], index),
              ),
          ],
        ),
      ),
    );
  }

  Widget _modelRow(BuildContext context, ProviderModelEntry model, int index) {
    final entry = _entry;
    final providerEnabled = entry?.enabled == true;
    final editable = !model.builtin;
    return Container(
      key: ValueKey('model-${model.modelId}'),
      padding: ZListRow.padding,
      child: Row(
        children: [
          // Drag handle only — wrapping the whole row would fight the
          // row's buttons and the switch for the pointer.
          ReorderableDragStartListener(
            index: index,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 4, vertical: ZListRow.gap),
              child: Icon(Icons.drag_indicator,
                  size: 18, color: ZInk.ghost(context)),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(model.modelId,
                          style: ZType.body.copyWith(
                              color: model.enabled
                                  ? ZInk.solid(context)
                                  : ZInk.faint(context)),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ),
                    // Vision pill (mock panel ④): sky outline on a light
                    // wash, caption size — matches the badge.
                    if (model.effSupportsImage) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 1),
                        decoration: BoxDecoration(
                          color: ZColors.sky500.withValues(alpha: 0.10),
                          borderRadius:
                              BorderRadius.circular(ZRadius.pill),
                          border: Border.all(
                              color:
                                  ZColors.sky500.withValues(alpha: 0.45)),
                        ),
                        child: Text(tr(context, 'providers.capVision'),
                            style: ZType.caption
                                .copyWith(color: ZColors.sky500)),
                      ),
                    ],
                  ],
                ),
                if (model.issues.isNotEmpty)
                  Text(model.issues.first.message,
                      style: ZType.caption
                          .copyWith(color: ZInk.warningTone(context))),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.network_check,
                size: 18,
                color: providerEnabled
                    ? ZInk.muted(context)
                    : ZInk.ghost(context)),
            tooltip: providerEnabled
                ? tr(context, 'providers.testModel')
                : tr(context, 'providers.testModelDisabled'),
            onPressed:
                providerEnabled ? () => _testModel(model) : null,
          ),
          if (editable)
            IconButton(
              icon: Icon(Icons.edit_outlined,
                  size: 18, color: ZInk.muted(context)),
              tooltip: tr(context, 'providers.editModel'),
              onPressed: () => _showModelDialog(model),
            ),
          if (editable)
            IconButton(
              icon: Icon(Icons.delete_outline,
                  size: 18, color: ZInk.dangerTone(context)),
              tooltip: tr(context, 'providers.deleteModel'),
              onPressed: () => _deleteModel(model),
            ),
          Switch(
            value: model.enabled,
            onChanged: (v) => _toggleModel(model, v),
          ),
        ],
      ),
    );
  }
}

/// API format picker — the ModelOptionField idiom (InputDecorator + bottom
/// sheet single-select), themed like the rest of the form.
class _ApiFormatField extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _ApiFormatField({required this.value, required this.onChanged});

  Future<void> _pick(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetCtx) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetCtx).height * 0.85,
        ),
        child: SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Text(tr(sheetCtx, 'providers.apiFormat'),
                    style: ZType.heading),
              ),
              for (final (id, key) in _apiFormats)
                ListTile(
                  dense: true,
                  leading: Icon(
                    value == id
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: 18,
                    color: value == id
                        ? ZColors.sky500
                        : ZInk.ghost(sheetCtx),
                  ),
                  title: Text(tr(sheetCtx, key),
                      style: ZType.body
                          .copyWith(color: ZInk.solid(sheetCtx))),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    onChanged(id);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final label = _apiFormats
        .where((f) => f.$1 == value)
        .map((f) => tr(context, f.$2))
        .firstOrNull;
    return InkWell(
      borderRadius: BorderRadius.circular(ZRadius.field),
      onTap: () => _pick(context),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: tr(context, 'providers.apiFormat'),
          suffixIcon:
              const Icon(Icons.arrow_drop_down, size: 20),
        ),
        child: Text(
          label ?? value,
          style: ZType.body.copyWith(color: ZInk.soft(context)),
        ),
      ),
    );
  }
}

/// Dialog's payload — the four capability booleans ride along so the
/// manual-save whitelist (extractManualModelConfig) can compose
/// `properties` on the caller side.
class _ModelDialogResult {
  final String modelId;
  final bool smart;
  final int? contextWindow;
  final int? maxOutput;
  final bool vision;
  final bool jsonSchema;
  final bool webSearch;
  final bool midSystem;
  const _ModelDialogResult({
    required this.modelId,
    required this.smart,
    required this.contextWindow,
    required this.maxOutput,
    required this.vision,
    required this.jsonSchema,
    required this.webSearch,
    required this.midSystem,
  });
}

/// 添加模型 / 编辑模型配置 dialog (form): smart-config switch +
/// model id (add mode carries the /models fetch entry — pick one id to
/// fill the field) + context window + max output (disabled while smart) +
/// the advanced section (manual mode only: vision input, three capability
/// switches, read-only reasoning chips).
class _ModelDialog extends StatefulWidget {
  final String title;
  final String? initialModelId;
  final bool initialSmart;
  final int? initialContextWindow;
  final int? initialMaxOutput;
  final bool initialVision;
  final bool initialJsonSchema;
  final bool initialWebSearch;
  final bool initialMidSystem;

  /// Read-only reasoning chips; empty hides the section (T5
  /// backfill). A fresh model shows the recommended low/high/max trio.
  final List<String> reasoningLevels;
  final bool isEdit;

  /// /models fetch seam (detail page's current form values); null hides
  /// the entry (account providers).
  final Future<List<String>?> Function()? fetchIds;
  const _ModelDialog({
    required this.title,
    required this.initialSmart,
    required this.isEdit,
    required this.reasoningLevels,
    this.initialModelId,
    this.initialContextWindow,
    this.initialMaxOutput,
    this.initialVision = false,
    this.initialJsonSchema = false,
    this.initialWebSearch = false,
    this.initialMidSystem = false,
    this.fetchIds,
  });

  @override
  State<_ModelDialog> createState() => _ModelDialogState();
}

class _ModelDialogState extends State<_ModelDialog> {
  late final TextEditingController _id =
      TextEditingController(text: widget.initialModelId ?? '');
  late final TextEditingController _context = TextEditingController(
      text: widget.initialContextWindow?.toString() ?? '');
  late final TextEditingController _max = TextEditingController(
      text: widget.initialMaxOutput?.toString() ?? '');
  late bool _smart = widget.initialSmart;
  late bool _vision = widget.initialVision;
  late bool _jsonSchema = widget.initialJsonSchema;
  late bool _webSearch = widget.initialWebSearch;
  late bool _midSystem = widget.initialMidSystem;
  bool _advOpen = false;
  bool _fetching = false;

  @override
  void initState() {
    super.initState();
    _id.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _id.dispose();
    _context.dispose();
    _max.dispose();
    super.dispose();
  }

  /// 从 /models 端点拉取（第二入口）：拉取成功后以单选列表回填模型 ID。
  Future<void> _pickFromEndpoint() async {
    final fetchIds = widget.fetchIds;
    if (fetchIds == null || _fetching) return;
    setState(() => _fetching = true);
    final ids = await fetchIds();
    if (!mounted) return;
    setState(() => _fetching = false);
    if (ids == null) return; // error already surfaced by the caller
    if (ids.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr(context, 'providers.fetchNone'))));
      return;
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetCtx) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetCtx).height * 0.85,
        ),
        child: SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Text(tr(sheetCtx, 'providers.fetchFromEndpoint'),
                    style: ZType.heading),
              ),
              for (final id in ids)
                ListTile(
                  dense: true,
                  leading: Icon(
                    _id.text.trim() == id
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: 18,
                    color: _id.text.trim() == id
                        ? ZColors.sky500
                        : ZInk.ghost(sheetCtx),
                  ),
                  title: Text(id,
                      style: ZType.body
                          .copyWith(color: ZInk.solid(sheetCtx))),
                  onTap: () => Navigator.pop(sheetCtx, id),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null && mounted) setState(() => _id.text = picked);
  }

  void _submit(BuildContext context) {
    final id = _id.text.trim();
    if (id.isEmpty) return;
    int? parse(TextEditingController c) => int.tryParse(c.text.trim());
    Navigator.pop(
      context,
      _ModelDialogResult(
        modelId: id,
        smart: _smart,
        contextWindow: parse(_context),
        maxOutput: parse(_max),
        vision: _vision,
        jsonSchema: _jsonSchema,
        webSearch: _webSearch,
        midSystem: _midSystem,
      ),
    );
  }

  void _reset() {
    setState(() {
      _id.text = widget.initialModelId ?? '';
      _context.text = widget.initialContextWindow?.toString() ?? '';
      _max.text = widget.initialMaxOutput?.toString() ?? '';
      _smart = widget.initialSmart;
      _vision = widget.initialVision;
      _jsonSchema = widget.initialJsonSchema;
      _webSearch = widget.initialWebSearch;
      _midSystem = widget.initialMidSystem;
    });
  }

  /// Compact action button (mock panel ②: 36dp visual, radius 8) — the
  /// global `MaterialTapTargetSize.padded` keeps the hit area ≥48dp.
  ButtonStyle get _actionStyle => TextButton.styleFrom(
        minimumSize: const Size(64, 36),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ZRadius.field)),
      );

  /// Field text matches the dialog's body copy (default M3 bodyLarge 16
  /// reads oversized next to the 13dp labels/switch rows).
  TextStyle get _fieldStyle =>
      ZType.body.copyWith(color: ZInk.solid(context));

  /// Shared field decoration: empty-state placeholder at body 13 (M3
  /// default 16 reads oversized), floated label stays caption 12.
  InputDecoration _fieldDecoration(String label) => InputDecoration(
        labelText: label,
        isDense: true,
        labelStyle: ZType.body.copyWith(color: ZInk.muted(context)),
        floatingLabelStyle:
            ZType.caption.copyWith(color: ZInk.muted(context)),
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      // Mock panel ②: screen width 392 → dialog 360 (inset 16), not the
      // M3 default 280.
      insetPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: Text(widget.title, style: ZType.heading),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(tr(context, 'providers.smartConfig'),
                      style: ZType.body),
                ),
                Switch(value: _smart, onChanged: (v) => setState(() => _smart = v)),
              ],
            ),
            TextField(
              controller: _id,
              style: _fieldStyle,
              decoration:
                  _fieldDecoration(tr(context, 'providers.modelId')),
            ),
            if (!widget.isEdit && widget.fetchIds != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: _pickFromEndpoint,
                  child: _fetching
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child:
                              CircularProgressIndicator(strokeWidth: 2))
                      : Text(tr(context, 'providers.fetchFromEndpoint'),
                          style: ZType.sub
                              .copyWith(color: ZColors.sky500)),
                ),
              ),
            const SizedBox(height: 10),
            TextField(
              controller: _context,
              enabled: !_smart,
              style: _fieldStyle,
              keyboardType: TextInputType.number,
              decoration:
                  _fieldDecoration(tr(context, 'providers.contextWindow')),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _max,
              enabled: !_smart,
              style: _fieldStyle,
              keyboardType: TextInputType.number,
              decoration:
                  _fieldDecoration(tr(context, 'providers.maxOutput')),
            ),
            // Advanced section — manual mode only (smart config lets the
            // desktop fill in the recommended values, via
            // addPersonalModel useRecommendedConfig=true).
            if (!_smart) ...[
              InkWell(
                borderRadius: BorderRadius.circular(ZRadius.mini),
                onTap: () => setState(() => _advOpen = !_advOpen),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      vertical: 6, horizontal: 4),
                  child: Row(
                    children: [
                      Text(tr(context, 'providers.advanced'),
                          style: ZType.body
                              .copyWith(color: ZInk.muted(context))),
                      const SizedBox(width: 6),
                      AnimatedRotation(
                        turns: _advOpen ? 0.25 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: Icon(Icons.chevron_right,
                            size: 16, color: ZInk.faint(context)),
                      ),
                    ],
                  ),
                ),
              ),
              AnimatedCrossFade(
                firstChild: const SizedBox(width: double.infinity),
                secondChild: _advancedBody(context),
                crossFadeState: _advOpen
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
                duration: const Duration(milliseconds: 200),
                sizeCurve: Curves.easeOutCubic,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          style: _actionStyle,
          onPressed: _reset,
          child: Text(tr(context, 'providers.resetForm')),
        ),
        TextButton(
          style: _actionStyle,
          onPressed: () => Navigator.pop(context),
          child: Text(tr(context, 'devices.add.cancel')),
        ),
        FilledButton(
          style: _actionStyle,
          onPressed: _id.text.trim().isEmpty
              ? null
              : () => _submit(context),
          child: Text(tr(context, 'devices.rename.save')),
        ),
      ],
    );
  }

  /// Advanced section body (mock panel ③): input types / capabilities /
  /// reasoning chips — plain hairline partitions,素色 like the mock.
  Widget _advancedBody(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        const SizedBox(height: 8),
        Text(tr(context, 'providers.sectionInput'),
            style: ZType.sub.copyWith(color: ZInk.faint(context))),
        _capabilityRow(
          context,
          label: tr(context, 'providers.capVision'),
          desc: tr(context, 'providers.capVisionDesc'),
          value: _vision,
          onChanged: (v) => setState(() => _vision = v),
        ),
        const SizedBox(height: 10),
        Text(tr(context, 'providers.sectionCapabilities'),
            style: ZType.sub.copyWith(color: ZInk.faint(context))),
        _capabilityRow(
          context,
          label: tr(context, 'providers.capJsonSchema'),
          value: _jsonSchema,
          onChanged: (v) => setState(() => _jsonSchema = v),
        ),
        _capabilityRow(
          context,
          label: tr(context, 'providers.capWebSearch'),
          value: _webSearch,
          onChanged: (v) => setState(() => _webSearch = v),
        ),
        _capabilityRow(
          context,
          label: tr(context, 'providers.capMidSystem'),
          value: _midSystem,
          onChanged: (v) => setState(() => _midSystem = v),
        ),
        if (widget.reasoningLevels.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(tr(context, 'providers.sectionReasoning'),
              style: ZType.sub.copyWith(color: ZInk.faint(context))),
          Text(tr(context, 'providers.sectionReasoningHint'),
              style: ZType.caption.copyWith(color: ZInk.faint(context))),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              for (final level in widget.reasoningLevels)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 5),
                  decoration: BoxDecoration(
                    color: ZInk.tile(context),
                    borderRadius:
                        BorderRadius.circular(ZRadius.field),
                    border: Border.all(color: ZInk.hairline(context)),
                  ),
                  child: Text(level,
                      style: ZType.body
                          .copyWith(color: ZInk.soft(context))),
                ),
            ],
          ),
        ],
      ],
    );
  }

  /// One tap-switch row of the advanced section (name + optional desc,
  /// switch right).
  Widget _capabilityRow(
    BuildContext context, {
    required String label,
    String? desc,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: ZType.body.copyWith(color: ZInk.solid(context))),
              if (desc != null)
                Text(desc,
                    style: ZType.caption
                        .copyWith(color: ZInk.faint(context))),
            ],
          ),
        ),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }
}

/// 从 /models 端点拉取模型 sheet: fetch → multi-select list (existing ids
/// pre-checked and disabled) → batch add. Errors surface with the mapped
/// copy — network / auth / parse never stay silent.
class _FetchModelsSheet extends StatefulWidget {
  final String baseUrl;
  final String apiKey;
  final String apiType;
  final Set<String> existing;
  final Future<void> Function(List<String> ids) onAdd;
  const _FetchModelsSheet({
    required this.baseUrl,
    required this.apiKey,
    required this.apiType,
    required this.existing,
    required this.onAdd,
  });

  @override
  State<_FetchModelsSheet> createState() => _FetchModelsSheetState();
}

class _FetchModelsSheetState extends State<_FetchModelsSheet> {
  List<String>? _models;
  String? _error;
  final _selected = <String>{};
  bool _adding = false;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() {
      _error = null;
      _models = null;
    });
    try {
      final ids = await fetchEndpointModels(
        baseUrl: widget.baseUrl,
        apiType: widget.apiType,
        apiKey: widget.apiKey.isEmpty ? null : widget.apiKey,
      );
      if (!mounted) return;
      setState(() => _models = ids);
    } on EndpointModelsException catch (e) {
      if (!mounted) return;
      setState(() => _error = switch (e.kind) {
            EndpointModelsErrorKind.network =>
              trP(context, 'providers.fetchFailed.network', [e.detail]),
            EndpointModelsErrorKind.unauthorized =>
              tr(context, 'providers.fetchFailed.unauthorized'),
            EndpointModelsErrorKind.parse =>
              trP(context, 'providers.fetchFailed.parse', [e.detail]),
          });
    } catch (e) {
      if (!mounted) return;
      setState(
          () => _error = trP(context, 'providers.fetchFailed.network', ['$e']));
    }
  }

  Future<void> _addSelected() async {
    // The checked rows are the batch — not every fetched id (the count
    // label promises exactly the selection).
    final ids = [
      for (final id in _selected)
        if (!widget.existing.contains(id)) id
    ];
    if (ids.isEmpty) return;
    setState(() => _adding = true);
    try {
      await widget.onAdd(ids);
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _adding = false;
        _error = trP(context, 'providers.addFailed', ['$e']);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final models = _models;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(tr(context, 'providers.fetchFromEndpoint'),
                        style: ZType.heading),
                  ),
                  IconButton(
                      onPressed: _fetch, icon: const Icon(Icons.refresh)),
                ],
              ),
            ),
            if (widget.baseUrl.isEmpty)
              Padding(
                padding: ZListRow.padding,
                child: Text(tr(context, 'providers.fetchNeedBaseUrl'),
                    style: ZType.sub.copyWith(color: ZInk.muted(context))),
              )
            else if (_error != null)
              Padding(
                padding: ZListRow.padding,
                child: Text(_error!,
                    style: ZType.sub.copyWith(color: ZInk.dangerTone(context))),
              )
            else if (models == null)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(
                    child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else if (models.isEmpty)
              Padding(
                padding: ZListRow.padding,
                child: Text(tr(context, 'providers.fetchNone'),
                    style: ZType.sub.copyWith(color: ZInk.faint(context))),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final id in models)
                      CheckboxListTile(
                        dense: true,
                        value: widget.existing.contains(id)
                            ? true
                            : _selected.contains(id),
                        onChanged: widget.existing.contains(id)
                            ? null
                            : (v) => setState(() {
                                  if (v == true) {
                                    _selected.add(id);
                                  } else {
                                    _selected.remove(id);
                                  }
                                }),
                        title: Text(id,
                            style: ZType.body.copyWith(
                                color: widget.existing.contains(id)
                                    ? ZInk.faint(context)
                                    : ZInk.solid(context))),
                        subtitle: widget.existing.contains(id)
                            ? Text(tr(context, 'providers.modelExists'),
                                style: ZType.caption
                                    .copyWith(color: ZInk.faint(context)))
                            : null,
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(ZSpacing.screen),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _adding || _selected.isEmpty
                      ? null
                      : _addSelected,
                  child: Text(_selected.isEmpty
                      ? tr(context, 'providers.fetchAdd')
                      : trP(context, 'providers.fetchAddSelected',
                          ['${_selected.length}'])),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 名称输入 prompt（创建自定义供应商 / 重命名）.
class _NamePromptDialog extends StatefulWidget {
  final String title;
  final String label;
  final String? initial;
  const _NamePromptDialog({
    required this.title,
    required this.label,
    this.initial,
  });

  @override
  State<_NamePromptDialog> createState() => _NamePromptDialogState();
}

class _NamePromptDialogState extends State<_NamePromptDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial ?? '');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title, style: ZType.heading),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(labelText: widget.label),
        onSubmitted: (v) =>
            Navigator.pop(context, v.trim().isEmpty ? null : v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr(context, 'devices.add.cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
              context, _controller.text.trim().isEmpty
                  ? null
                  : _controller.text.trim()),
          child: Text(tr(context, 'devices.add.confirm')),
        ),
      ],
    );
  }
}
