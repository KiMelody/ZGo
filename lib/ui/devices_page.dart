import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../notifications/keepalive_controller.dart';
import '../plan/plan_account.dart';
import '../plan/remote_device_api.dart';
import '../protocol/connection_params.dart';
import '../state/device_session.dart';
import '../state/device_store.dart';
import '../state/quota_watch.dart';
import '../state/scheduled_store.dart';
import '../widgets/home_widget_bridge.dart';
import 'qr_scan_page.dart';
import 'remote_page.dart';
import 'scheduled_page.dart';
import 'settings_page.dart';
import 'task_list_page.dart';
import 'theme.dart';
import 'ui_settings.dart';
import 'widgets/device_name.dart';
import 'widgets/sheet_scaffold.dart';

/// Home: the device list with live native status. Tap a card to open the
/// native task list (or WebView fallback), long-term management via the
/// overflow menu. Supports clipboard offer-to-add, drag-reorder and pin.
class DevicesPage extends StatefulWidget {
  final DeviceStore store;
  final ThemeController theme;
  final UiSettings ui;
  final DeviceSessionHub hub;
  final ScheduledStore scheduled;
  final KeepAliveController keepalive;

  /// Quota-watch controller handed to the settings section (null on hosts
  /// without the feature).
  final QuotaWatchController? quotaWatch;

  /// Plan-account controller handed to the settings section (null when
  /// the feature is not wired).
  final PlanController? plan;

  /// Cloud device-directory client (task 10-22). Null on hosts without the
  /// feature — the cloud section is then never rendered.
  final RemoteDeviceApi? cloudApi;
  const DevicesPage({
    super.key,
    required this.store,
    required this.theme,
    required this.ui,
    required this.hub,
    required this.scheduled,
    required this.keepalive,
    this.quotaWatch,
    this.plan,
    this.cloudApi,
  });

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage>
    with WidgetsBindingObserver {
  /// Last clipboard URL we already offered (or the user dismissed) so we
  /// don't spam the snackbar on every resume.
  String? _clipboardHandled;

  /// Cloud device directory (R2). Null = not fetched / failed / signed
  /// out — the section stays hidden. [_cloudToken] is the account the
  /// cached list belongs to: one fetch per identity, no polling.
  List<RemoteDeviceEntry>? _cloudDevices;
  String? _cloudToken;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.store.load().then((_) {
      _syncConnections();
      _syncHomeWidget();
      _checkClipboard();
    });
    widget.store.addListener(_onStoreChanged);
    widget.ui.addListener(_syncConnections);
    widget.plan?.addListener(_onPlanChanged);
    // Boot may still be reading the persisted identity — the listener above
    // fetches as soon as sign-in is known.
    _maybeLoadCloudDevices();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.store.removeListener(_onStoreChanged);
    widget.ui.removeListener(_syncConnections);
    widget.plan?.removeListener(_onPlanChanged);
    super.dispose();
  }

  void _onStoreChanged() {
    _syncConnections();
    _syncHomeWidget();
  }

  /// Sign-in/out and token refreshes drive the directory: the cloud list
  /// belongs to the account, so signing out drops it and a later sign-in
  /// fetches again. Same-identity notifications are no-ops.
  void _onPlanChanged() {
    if (!mounted) return;
    if (widget.plan?.signedIn != true) {
      _cloudToken = null;
      if (_cloudDevices != null) setState(() => _cloudDevices = null);
      return;
    }
    _maybeLoadCloudDevices();
  }

  /// R2: fetch the cloud directory once per account (no polling); failures
  /// collapse silently. The account token rides the plan controller — the
  /// same `zgo_plan_token` the relay V2 handshake uses.
  Future<void> _maybeLoadCloudDevices() async {
    final plan = widget.plan;
    final api = widget.cloudApi;
    final token = plan?.token;
    if (api == null ||
        plan == null ||
        !plan.signedIn ||
        token == null ||
        token.isEmpty) {
      return;
    }
    // A new account's fetch must not be swallowed by an in-flight one for a
    // stale token — last writer wins (sign-in switch without sign-out).
    if (_cloudToken == token) return;
    _cloudToken = token;
    try {
      final entries = await api.list(token: token);
      // A concurrent token change replaced this fetch; its response belongs
      // to the previous account and must not render here.
      if (!mounted || _cloudToken != token) return;
      setState(() => _cloudDevices = entries);
    } catch (_) {
      // Silent collapse: no snackbar, and the cached token keeps a failed
      // attempt from turning into a retry loop.
    }
  }

  /// Account-directory entries not yet in the local list (R1): the section
  /// is discovery-only, so mid-matched rows never render.
  List<RemoteDeviceEntry> get _cloudUnadded {
    final devices = _cloudDevices;
    if (devices == null) return const [];
    return [
      for (final entry in devices)
        if (!_isCloudEntryAdded(entry)) entry,
    ];
  }

  bool get _cloudVisible =>
      (widget.plan?.signedIn ?? false) && _cloudUnadded.isNotEmpty;

  /// Adds the entry's V2 link and opens it through the existing card tap
  /// path (native task list when the link is healthy, WebView otherwise).
  Future<void> _connectCloud(RemoteDeviceEntry entry) async {
    final device = await widget.store.addUrl(entry.remoteUrl.toString());
    if (!mounted) return;
    await _open(device);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkClipboard();
      _syncHomeWidget();
    }
  }

  void _syncHomeWidget() {
    HomeWidgetBridge.syncDevices(widget.store.devices);
  }

  /// Keeps native connections in step with the device list and the
  /// native-list switch (see [DeviceSessionHub.syncWith]).
  void _syncConnections() {
    if (!widget.store.loaded || !mounted) return;
    widget.hub.syncWith(widget.store.devices);
  }

  /// On resume / first load: if the clipboard holds a remote URL that is
  /// not already saved, offer to add it.
  Future<void> _checkClipboard() async {
    if (!mounted) return;
    // Widget tests have no clipboard channel — skip to avoid pending timers.
    final bindingName = WidgetsBinding.instance.runtimeType.toString();
    if (bindingName.contains('TestWidgetsFlutterBinding') ||
        bindingName.contains('AutomatedTest')) {
      return;
    }
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? '';
      if (text.isEmpty || text == _clipboardHandled) return;
      if (RemoteConnectionParams.parse(text) == null) return;
      if (widget.store.devices.any((d) => d.url == text)) {
        _clipboardHandled = text;
        return;
      }
      _clipboardHandled = text;
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 8),
          content: Text(tr(context, 'devices.clipboard.offer')),
          action: SnackBarAction(
            label: tr(context, 'devices.clipboard.add'),
            onPressed: () async {
              await widget.store.addUrl(text);
            },
          ),
        ),
      );
    } catch (_) {
      // Clipboard access can fail on some platforms / permissions / tests.
    }
  }

  /// Card tap: native task list when the protocol link is healthy, the
  /// WebView remote page otherwise.
  Future<void> _open(Device device) async {
    final session = widget.hub.sessionOf(device.id);
    // V2 links need the ZCode account: a signed-out device can neither
    // connect natively nor usefully fall back to the WebView, so tap shows
    // the login guidance instead of silently failing (A2).
    if (session?.failureReason == 'auth-required') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr(context, 'remote.failure.auth-required')),
          action: SnackBarAction(
            label: tr(context, 'common.retry'),
            // Signing in happens in Settings; without this the tap always
            // hits the same failure branch and there is no way back.
            onPressed: () {
              if (!mounted) return;
              widget.hub.ensure(device);
            },
          ),
        ),
      );
      return;
    }
    if (widget.ui.nativeListEnabled &&
        session != null &&
        session.status != DeviceStatus.error) {
      if (!mounted) return;
      await Navigator.of(context).push(zRoute(
        (_) => _deviceThemeWrap(
          device,
          TaskListPage(
            store: widget.store,
            hub: widget.hub,
            device: device,
            theme: widget.theme,
          ),
        ),
      ));
      return;
    }
    await _openRemote(device);
  }

  /// Applies the device URL's `theme=dark|light` for the opened route.
  Widget _deviceThemeWrap(Device device, Widget child) {
    final hint = device.themeHint;
    if (hint == null) return child;
    final data = hint == ThemeModeHint.dark
        ? buildDarkTheme()
        : buildLightTheme();
    return Theme(data: data, child: child);
  }

  /// Opens the in-app WebView remote page. The native connection is
  /// suspended first (one terminal per device) and resumes ~1s after the
  /// page pops. Injects `theme=` from the URL when present.
  Future<void> _openRemote(Device device) async {
    await widget.store.touch(device.id);
    await widget.hub.suspend(device.id);
    if (!mounted) return;
    await Navigator.of(context).push(zRoute(
      (_) => _deviceThemeWrap(
        device,
        RemotePage(device: device),
      ),
    ));
    widget.hub.scheduleResume(device);
  }

  Future<void> _addByUrl() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr(context, 'devices.add.pasteTitle')),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          minLines: 2,
          keyboardType: TextInputType.url,
          style: ZType.body.copyWith(fontFamily: 'monospace'),
          decoration: InputDecoration(
            hintText: tr(context, 'devices.add.pasteHint2'),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c),
              child: Text(tr(context, 'devices.add.cancel'))),
          FilledButton(
            onPressed: () => Navigator.pop(c, controller.text),
            child: Text(tr(context, 'devices.add.confirm')),
          ),
        ],
      ),
    );
    if (url == null || url.trim().isEmpty) return;
    final device = await widget.store.addUrl(url);
    if (!mounted) return;
    if (device.params == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr(context, 'devices.add.savedUnparsed'))),
      );
    }
  }

  Future<void> _addByScan() async {
    final url = await Navigator.of(context).push<String>(
      zRoute((_) => const QrScanPage()),
    );
    if (url == null || url.trim().isEmpty) return;
    final device = await widget.store.addUrl(url);
    if (!mounted) return;
    if (device.params == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr(context, 'devices.add.savedUnparsed'))),
      );
    }
  }

  void _showAddSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => zSheetScaffold(
        c,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.qr_code_scanner),
              title: Text(tr(context, 'devices.add.scan')),
              subtitle: Text(tr(context, 'devices.add.scanHint')),
              onTap: () {
                Navigator.pop(c);
                _addByScan();
              },
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: Text(tr(context, 'devices.add.paste')),
              subtitle: Text(tr(context, 'devices.add.pasteHint')),
              onTap: () {
                Navigator.pop(c);
                _addByUrl();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _rename(Device device) async {
    final controller = TextEditingController(text: device.label);
    final label = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr(context, 'devices.rename.title')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: tr(context, 'devices.rename.hint')),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c),
              child: Text(tr(context, 'devices.add.cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(c, controller.text),
              child: Text(tr(context, 'devices.rename.save'))),
        ],
      ),
    );
    if (label != null) await widget.store.rename(device.id, label);
  }

  Future<void> _delete(Device device) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr(context, 'devices.delete.title')),
        content: Text(trP(context, 'devices.delete.body', [
          deviceDisplayName(context, device.label),
        ])),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(tr(context, 'devices.add.cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(c).colorScheme.error,
                foregroundColor: Theme.of(c).colorScheme.onError),
            onPressed: () => Navigator.pop(c, true),
            child: Text(tr(context, 'devices.delete.confirm')),
          ),
        ],
      ),
    );
    if (confirm == true) await widget.store.remove(device.id);
  }

  Future<void> _copyUrl(Device device) async {
    await Clipboard.setData(ClipboardData(text: device.url));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr(context, 'devices.copy.done'))));
  }

  Future<void> _openInBrowser(Device device) async {
    await launchUrl(Uri.parse(device.url),
        mode: LaunchMode.externalApplication);
  }

  void _showExport() async {
    await Clipboard.setData(ClipboardData(text: widget.store.exportJson()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr(context, 'devices.export.done'))),
    );
  }

  void _showScheduled() {
    Navigator.of(context).push(zRoute(
      (_) => ScheduledPage(
        devices: widget.store,
        hub: widget.hub,
        store: widget.scheduled,
      ),
    ));
  }

  Future<void> _showImport() async {
    final controller = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr(context, 'devices.import.title')),
        content: TextField(
          controller: controller,
          maxLines: 5,
          minLines: 3,
          style: ZType.sub.copyWith(fontFamily: 'monospace'),
          decoration: InputDecoration(hintText: tr(context, 'devices.import.hint')),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c),
              child: Text(tr(context, 'devices.add.cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(c, controller.text),
              child: Text(tr(context, 'devices.import.confirm'))),
        ],
      ),
    );
    if (raw == null || raw.trim().isEmpty) return;
    try {
      final n = await widget.store.importJson(raw);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(trP(context, 'devices.import.done', ['$n']))));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr(context, 'devices.import.invalid'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'app.title')),
        actions: [
          IconButton(
            tooltip: tr(context, 'settings.title'),
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(zRoute(
              (_) => SettingsPage(
                store: widget.store,
                theme: widget.theme,
                ui: widget.ui,
                keepalive: widget.keepalive,
                quotaWatch: widget.quotaWatch,
                plan: widget.plan,
              ),
            )),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'export') _showExport();
              if (v == 'import') _showImport();
              if (v == 'sched') _showScheduled();
            },
            itemBuilder: (c) => [
              PopupMenuItem(
                  value: 'export', child: Text(tr(context, 'devices.menu.export'))),
              PopupMenuItem(
                  value: 'import', child: Text(tr(context, 'devices.menu.import'))),
              PopupMenuItem(
                  value: 'sched', child: Text(tr(context, 'sched.menu'))),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddSheet,
        icon: const Icon(Icons.add),
        label: Text(tr(context, 'devices.add')),
      ),
      body: AnimatedBuilder(
        animation: Listenable.merge([widget.store, widget.hub, widget.ui]),
        builder: (context, _) {
          final devices = widget.store.devices;
          if (!widget.store.loaded) {
            return const Center(child: CircularProgressIndicator());
          }
          if (devices.isEmpty) return _emptyState(context);
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ReorderableListView.builder(
              // Always scrollable: a one-device list must still accept the
              // pull gesture for the refresh indicator.
              physics: const AlwaysScrollableScrollPhysics(),
              padding: zScreenPadding(context, bottom: 96),
              // 账号设备 rides below the local cards (R2), inside the same
              // scroll view so pull-to-refresh keeps working.
              footer: _cloudSection(context),
              itemCount: devices.length,
              // The row keeps no permanent drag handle (R8): reordering is a
              // long press anywhere on the card, on every platform.
              buildDefaultDragHandles: false,
              proxyDecorator: (child, index, animation) {
                return AnimatedBuilder(
                  animation: animation,
                  builder: (context, _) => Material(
                    elevation: 2 + animation.value * 4,
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(ZRadius.tile),
                    child: child,
                  ),
                );
              },
              onReorderItem: (oldIndex, newIndex) {
                widget.store.reorder(oldIndex, newIndex);
              },
              itemBuilder: (context, i) {
                final d = devices[i];
                return ReorderableDelayedDragStartListener(
                  key: ValueKey(d.id),
                  index: i,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _deviceCard(d),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }

  /// Pull-to-refresh: re-read the stored device list, then re-sync the native
  /// connections and the home widget with it.
  Future<void> _refresh() async {
    await widget.store.load();
    if (!mounted) return;
    _syncConnections();
    _syncHomeWidget();
  }

  /// Empty state, kept inside a scrollable so the pull gesture still reaches
  /// the refresh indicator when there is no device yet.
  Widget _emptyState(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _refresh,
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Column(
            // Stretch so the cloud card spans the row width instead of
            // shrink-wrapping to its text.
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConstrainedBox(
                // With cloud devices present the hint shrinks to its own
                // height instead of centering over a full page — the
                // account directory must not start below the fold.
                constraints: BoxConstraints(
                  minHeight: _cloudVisible ? 0 : constraints.maxHeight,
                ),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(ZSpacing.emptyState),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            color: ZColors.sky500.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(ZRadius.field),
                          ),
                          child: const Icon(Icons.devices,
                              size: 36, color: ZColors.sky500),
                        ),
                        const SizedBox(height: 20),
                        Text(tr(context, 'devices.empty.title'),
                            style: ZType.title
                                .copyWith(color: ZInk.solid(context))),
                        const SizedBox(height: 8),
                        Text(
                          tr(context, 'devices.empty.body'),
                          textAlign: TextAlign.center,
                          style:
                              ZType.body.copyWith(color: ZInk.faint(context)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (_cloudVisible)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      ZSpacing.screen, 0, ZSpacing.screen, 96),
                  child: _cloudSection(context),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 账号设备分区 (R2/R3): a faint section title over one card of account
  /// devices. Discovery-only — already-added entries never render, so each
  /// row is either online (connect) or offline (disabled).
  Widget _cloudSection(BuildContext context) {
    if (!_cloudVisible) return const SizedBox.shrink();
    final entries = _cloudUnadded;
    return Padding(
      padding: const EdgeInsets.only(top: ZSpacing.cardGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Row(
              children: [
                Icon(Icons.cloud_outlined,
                    size: ZTile.iconSize, color: ZInk.ghost(context)),
                const SizedBox(width: 6),
                Text(
                  tr(context, 'devices.cloud.title'),
                  style: ZType.body.copyWith(
                    color: ZInk.ghost(context),
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  '·',
                  style: ZType.caption.copyWith(color: ZInk.ghost(context)),
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    tr(context, 'devices.cloud.subtitle'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ZType.caption.copyWith(color: ZInk.ghost(context)),
                  ),
                ),
              ],
            ),
          ),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < entries.length; i++) ...[
                  if (i > 0)
                    Divider(height: 1, color: ZInk.hairline(context)),
                  _cloudRow(context, entries[i]),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// R4: dedupe against the local list on `device_mid` — the same value the
  /// V2 link carries as `mid`. V1 links have no mid, so they never match.
  bool _isCloudEntryAdded(RemoteDeviceEntry entry) => widget.store.devices
      .any((d) => d.params?.deviceMid == entry.deviceMid);

  Widget _cloudRow(BuildContext context, RemoteDeviceEntry entry) {
    final metaLine = [
      if (entry.platform.isNotEmpty) entry.platform,
      if (entry.version.isNotEmpty) entry.version,
    ].join(' · ');
    return Padding(
      padding: ZListRow.padding,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: ZListRow.twoLineHeight),
        child: Row(
          children: [
            // The same status-dot language as the local cards.
            Container(
              width: ZListRow.dot,
              height: ZListRow.dot,
              decoration: BoxDecoration(
                color: entry.online
                    ? ZInk.successTone(context)
                    : ZInk.ghost(context),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    entry.name.isEmpty
                        ? tr(context, 'devices.unnamed')
                        : entry.name,
                    style:
                        ZType.bodyStrong.copyWith(color: ZInk.solid(context)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (metaLine.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      metaLine,
                      style: ZType.caption.copyWith(color: ZInk.faint(context)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              // Offline entries keep the button but disable it (R3).
              onPressed: entry.online ? () => _connectCloud(entry) : null,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                visualDensity: VisualDensity.compact,
              ),
              child: Text(
                tr(
                  context,
                  entry.online
                      ? 'devices.cloud.connect'
                      : 'devices.cloud.offline',
                ),
                style: ZType.sub,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _deviceCard(Device device) {
    final session = widget.hub.sessionOf(device.id);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(device),
        child: Padding(
          padding: ZListRow.padding,
          child: ConstrainedBox(
            constraints:
                const BoxConstraints(minHeight: ZListRow.twoLineHeight),
            child: Row(
              children: [
                _deviceLeading(context, session, device.pinned),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        deviceDisplayName(context, device.label),
                        style: ZType.heading,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      _deviceMeta(context, session, device),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: tr(context, 'chat.more'),
                  icon: Icon(Icons.more_vert,
                      size: ZListRow.leadingIcon, color: ZInk.muted(context)),
                  onPressed: () => _deviceActions(device),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Per-device actions, behind 「更多」: the row keeps no permanent
  /// drag-handle/menu placeholder (R8) — reordering is the list's long-press
  /// drag, the actions live here.
  Future<void> _deviceActions(Device device) async {
    final host = device.params?.source.host ?? '';
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    ZSpacing.screen, 0, ZSpacing.screen, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(deviceDisplayName(context, device.label),
                        style: ZType.heading),
                    // The row no longer carries the host (R5): it lives in the
                    // device's own detail surface.
                    if (host.isNotEmpty)
                      Text(
                        host,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ZType.caption.copyWith(
                          color: ZInk.faint(context),
                          fontFamily: 'monospace',
                        ),
                      ),
                  ],
                ),
              ),
              for (final (value, key) in [
                ('pin',
                    device.pinned ? 'devices.menu.unpin' : 'devices.menu.pin'),
                ('rename', 'devices.menu.rename'),
                ('web', 'devices.menu.web'),
                ('browser', 'devices.menu.browser'),
                ('copy', 'devices.menu.copy'),
                ('delete', 'devices.menu.delete'),
              ])
                ListTile(
                  leading: Icon(_deviceActionIcon(value), size: 20),
                  title: Text(
                    tr(context, key),
                    style: value == 'delete'
                        ? ZType.body.copyWith(color: ZInk.dangerTone(context))
                        : ZType.body,
                  ),
                  onTap: () {
                    Navigator.pop(c);
                    switch (value) {
                      case 'pin':
                        widget.store.setPinned(device.id, !device.pinned);
                      case 'rename':
                        _rename(device);
                      case 'web':
                        _openRemote(device);
                      case 'browser':
                        _openInBrowser(device);
                      case 'copy':
                        _copyUrl(device);
                      case 'delete':
                        _delete(device);
                    }
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  static IconData _deviceActionIcon(String action) => switch (action) {
        'pin' => Icons.push_pin_outlined,
        'rename' => Icons.edit_outlined,
        'web' => Icons.smartphone,
        'browser' => Icons.open_in_browser,
        'copy' => Icons.link,
        _ => Icons.delete_outline,
      };

  /// Device avatar with a live status dot and a running-task badge.
  Widget _deviceLeading(
      BuildContext context, DeviceSession? session, bool pinned) {
    final running = session?.runningTaskCount ?? 0;
    final dotColor = switch (session?.status) {
      DeviceStatus.connected => ZInk.successTone(context),
      DeviceStatus.connecting => ZColors.sky500,
      DeviceStatus.error => ZInk.dangerTone(context),
      _ => ZColors.neutral400,
    };
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: ZListRow.leadingSize,
          height: ZListRow.leadingSize,
          decoration: BoxDecoration(
            color: ZColors.sky500.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(ZRadius.field),
          ),
          child: Icon(
            pinned ? Icons.push_pin_outlined : Icons.desktop_windows_outlined,
            size: ZListRow.leadingIcon,
            color: ZColors.sky500,
          ),
        ),
        Positioned(
          right: -1,
          bottom: -1,
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: dotColor,
              shape: BoxShape.circle,
              border: Border.all(
                  color: Theme.of(context).colorScheme.surface, width: 2.5),
            ),
          ),
        ),
        if (running > 0)
          Positioned(
            right: -8,
            top: -8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: ZColors.sky500,
                borderRadius: BorderRadius.circular(ZRadius.field),
                border: Border.all(
                    color: Theme.of(context).colorScheme.surface, width: 2),
              ),
              child: Text(
                running > 9 ? '9+' : '$running',
                style: ZType.caption.copyWith(
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// One meta line: `状态 · 上次使用…` (the host moved to the detail sheet).
  Widget _deviceMeta(
      BuildContext context, DeviceSession? session, Device device) {
    final (status, color) = switch (session?.status) {
      DeviceStatus.connected => session != null && session.runningTaskCount > 0
          ? (trP(context, 'status.tasksRunning',
                ['${session.runningTaskCount}']),
              ZInk.successTone(context))
          : (tr(context, 'status.online'), ZInk.successTone(context)),
      DeviceStatus.connecting =>
        (tr(context, 'status.connecting'), ZColors.sky500),
      DeviceStatus.error => session?.failureReason == 'auth-required'
          ? (tr(context, 'status.authRequired'), ZInk.dangerTone(context))
          : session?.kicked == true
              ? (tr(context, 'status.kicked'), ZInk.dangerTone(context))
              : (tr(context, 'status.error'), ZInk.dangerTone(context)),
      _ => (tr(context, 'status.offline'), ZInk.ghost(context)),
    };
    // B14: while connected, the live status segment (在线 / 任务进行中 N)
    // already answers "is it alive" — '上次使用' is the moment the app last
    // OPENED the device (local stat, not session activity), so showing it
    // mid-session reads as stale. It rides only the disconnected states.
    final connected = session?.status == DeviceStatus.connected;
    final lastUsed = connected
        ? null
        : (device.lastUsedAt != null
            ? trP(context, 'devices.lastUsed',
                [relativeTime(context, device.lastUsedAt!)])
            : tr(context, 'devices.neverUsed'));
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
              text: status, style: ZType.caption.copyWith(color: color)),
          if (lastUsed != null)
            TextSpan(
              text: ' · $lastUsed',
              style: ZType.caption.copyWith(color: ZInk.ghost(context)),
            ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
