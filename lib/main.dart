import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:home_widget/home_widget.dart';

import 'notifications/keepalive_controller.dart';
import 'notifications/notification_service.dart';
import 'notifications/quota_watch_presenter.dart';
import 'state/device_session.dart';
import 'state/device_store.dart';
import 'state/notification_hub.dart';
import 'state/quota_watch.dart';
import 'state/scheduled_store.dart';
import 'ui/chat/chat_page.dart';
import 'ui/device_usage_page.dart';
import 'ui/devices_page.dart';
import 'ui/quota_reset_dialog.dart';
import 'ui/remote_page.dart';
import 'ui/task_list_page.dart';
import 'ui/theme.dart';
import 'ui/ui_settings.dart';
import 'ui/widgets/device_name.dart';
import 'widgets/home_widget_bridge.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  _registerBundledFontLicenses();
  runApp(const ZGoApp());
}

/// The bundled font subsets live under assets/fonts/ with no package root,
/// so the build-time NOTICES collector never sees their licenses. Feed them
/// into the licenses page by hand — addLicense is lazy, the asset loads only
/// run when a licenses page is actually opened.
void _registerBundledFontLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      ['Noto Sans SC'],
      await rootBundle.loadString('assets/fonts/OFL-NotoSansSC.txt'),
    );
    yield LicenseEntryWithLineBreaks(
      ['Material Symbols Rounded'],
      await rootBundle
          .loadString('assets/fonts/LICENSE-MaterialSymbolsRounded.txt'),
    );
  });
}

class ZGoApp extends StatefulWidget {
  const ZGoApp({super.key});

  @override
  State<ZGoApp> createState() => _ZGoAppState();
}

class _ZGoAppState extends State<ZGoApp>
    with WidgetsBindingObserver {
  final DeviceStore _store = DeviceStore();
  final ThemeController _theme = ThemeController();
  final UiSettings _ui = UiSettings();
  final ScheduledStore _scheduled = ScheduledStore();
  final NotificationService _notifications = NotificationService();
  final KeepAliveController _keepAlive = KeepAliveController();
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  late final DeviceSessionHub _hub = DeviceSessionHub(
    nativeListEnabled: () => _ui.nativeListEnabled,
  );
  late final MessageScheduler _scheduler = MessageScheduler(
    store: _scheduled,
    devices: _store,
    hub: _hub,
    ui: _ui,
  );
  late final NotificationHub _notifyHub = NotificationHub(
    service: _notifications,
    ui: _ui,
    deviceLabelOf: (id) =>
        _store.devices.where((d) => d.id == id).firstOrNull?.label ?? id,
  );
  // Quota watch (PRD 09-19): the presenter owns all copy/notice surfaces,
  // the controller owns polling + the edge rules; the deep links below
  // (usage page / reset dialog) live here in the composition root.
  late final QuotaWatchPresenter _quotaPresenter = QuotaWatchPresenter(
    service: _notifications,
    localeOf: () => _ui.locale,
    onReset: (kind) async {
      if (kind == null) {
        await _openQuotaResetDialog();
      } else {
        await _quotaWatch.performReset(kind);
      }
    },
    onOpenUsage: _openQuotaUsagePage,
        onRefresh: () => _quotaWatch.pollNow(force: true),
  );
  late final QuotaWatchController _quotaWatch = QuotaWatchController(
    sessionsOf: () => _hub.activeSessions,
    onEvent: _quotaPresenter.onEvent,
  );
  static const _quotaWatchChannel = MethodChannel('zgo/quota_watch');
  StreamSubscription? _widgetClickSub;
  StreamSubscription? _appLinkSub;
  final _appLinks = AppLinks();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _theme.load();
    final uiLoaded = _ui.load();
    _scheduled.load();
    unawaited(_store.load().then((_) {
      HomeWidgetBridge.syncDevices(_store.devices);
    }));
    // Fire due scheduled messages while the app is alive.
    _scheduler.start();
    // Local notifications: task events ride the sessions stream; off-peak
    // and automation results poll. Tapping deep-links to the conversation.
    _notifications.onTap = _handleNotificationTap;
    _notifications.onAction = (payload, actionId) {
      if (actionId == QuotaWatchPresenter.resetActionId) {
        unawaited(_quotaPresenter.handleResetPress());
      }
    };
    // Quota watch: push settings in (now and on every change), render the
    // persistent notice from each judged snapshot, and serve the native
    // reset tap (warm push + cold-start pull).
    unawaited(uiLoaded.then((_) => _applyQuotaWatchSettings()));
    _ui.addListener(_applyQuotaWatchSettings);
    _quotaWatch
        .addListener(() => _quotaPresenter.onSnapshot(_quotaWatch.snapshot));
    _quotaWatchChannel.setMethodCallHandler((call) async {
      if (call.method == 'resetPressed') {
        unawaited(_quotaPresenter.handleResetPress());
        return true;
      }
      // The notice's refresh icon (native push; a dead engine is served by
      // the next app open, whose resumed lifecycle re-polls instead).
      if (call.method == 'refreshPressed') {
        debugPrint('[quota-watch] manual refresh pressed');
        unawaited(_quotaPresenter.handleRefreshPress());
        return true;
      }
      return null;
    });
    unawaited(_quotaWatchChannel
        .invokeMethod<bool>('takePendingReset')
        .then((pending) {
      if (pending == true) unawaited(_quotaPresenter.handleResetPress());
    }).catchError((_) {}));
    // Channel names are fixed the first time the channel is created, so wait
    // for the stored locale before registering them.
    unawaited(uiLoaded.then((_) => _notifications.init(locale: _ui.locale)));
    // The foreground service dies with the process, so re-arm it on start
    // when the switch was left on — same batch as the channel registration,
    // for the same locale reason.
    unawaited(uiLoaded.then((_) {
      if (_ui.keepAliveEnabled) unawaited(_keepAlive.start(_ui.locale));
    }));
    _hub.addListener(_syncNotifyHub);
    _syncNotifyHub();
    _notifyHub.start();
    unawaited(HomeWidgetBridge.init());
    _listenHomeWidget();
    _listenAppLinks();
  }

  void _listenAppLinks() {
    _appLinks.getInitialLink().then(_openFromWidgetUri);
    _appLinkSub = _appLinks.uriLinkStream.listen(_openFromWidgetUri);
  }

  void _listenHomeWidget() {
    HomeWidget.initiallyLaunchedFromHomeWidget().then((uri) {
      if (uri != null) _openFromWidgetUri(uri);
    });
    _widgetClickSub = HomeWidget.widgetClicked.listen(_openFromWidgetUri);
  }

  Future<void> _openFromWidgetUri(Uri? uri) async {
    if (uri == null) return;
    // zgo://device/<id>  or  /device/<id>
    final id = uri.host == 'device'
        ? (uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null)
        : (uri.pathSegments.length >= 2 && uri.pathSegments.first == 'device'
            ? uri.pathSegments[1]
            : null);
    if (id == null || id.isEmpty) return;
    if (!_store.loaded) await _store.load();
    final device = _store.devices.where((d) => d.id == id).firstOrNull;
    if (device == null) return;
    await _store.touch(device.id);
    final session = _hub.ensure(device);
    final context = _navigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    if (_ui.nativeListEnabled && session != null) {
      await Navigator.of(context).push(zRoute(
        (_) => TaskListPage(
          store: _store,
          hub: _hub,
          device: device,
          theme: _theme,
        ),
      ));
      return;
    }
    await _hub.suspend(device.id);
    if (!context.mounted) return;
    await Navigator.of(context).push(zRoute(
      (_) => RemotePage(device: device),
    ));
    _hub.scheduleResume(device);
  }

  void _syncNotifyHub() {
    if (mounted) _notifyHub.syncWith(_hub.activeSessions);
  }

  /// Pushes the settings节 values into the watch (no-op when unchanged).
  void _applyQuotaWatchSettings() {
    _quotaWatch.configure(
      enabled: _ui.quotaWatchEnabled,
      thresholdPercent: _ui.quotaWatchThreshold,
      interval: Duration(minutes: _ui.quotaWatchIntervalMinutes),
      expiryReminderEnabled: _ui.quotaWatchExpiryReminderEnabled,
      fiveHourExpiryLeadMinutes: _ui.quotaWatchExpiryLeadFiveHourMinutes,
      weeklyExpiryLeadHours: _ui.quotaWatchExpiryLeadWeeklyHours,
    );
  }

  /// Deep link target of the quota-watch notices: the monitored device's
  /// usage page (the reset area lives there). No monitored session →
  /// nothing to open.
  Future<void> _openQuotaUsagePage() async {
    final deviceId = _quotaWatch.monitoredDeviceId;
    if (deviceId == null) return;
    if (!_store.loaded) await _store.load();
    final device = _store.devices.where((d) => d.id == deviceId).firstOrNull;
    if (device == null) return;
    final session = _hub.ensure(device);
    final context = _navigatorKey.currentContext;
    if (session == null || context == null || !context.mounted) return;
    await Navigator.of(context).push(zRoute(
      (_) => DeviceUsagePage(session: session),
    ));
  }

  /// N3b degrade: open the existing reset dialog over the current page for
  /// the monitored session (the pools come off the session-wide
  /// controllers, so the dialog lists exactly the resettable windows).
  Future<void> _openQuotaResetDialog() async {
    final deviceId = _quotaWatch.monitoredDeviceId;
    if (deviceId == null) return;
    if (!_store.loaded) await _store.load();
    final device = _store.devices.where((d) => d.id == deviceId).firstOrNull;
    if (device == null) return;
    final session = _hub.ensure(device);
    if (session == null) return;
    final view = await session.entitlementSnapshot();
    await session.quotaResetController.refresh();
    final context = _navigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    await showQuotaResetDialog(
      context,
      controller: session.quotaResetController,
      resettable: {
        for (final r in view.resettablePools(session.quotaResetController.pools))
          r.type,
      },
    );
  }

  /// Notification tap → the producing conversation: native chat page when
  /// the protocol link is up (no WebView suspend), WebView deep link as
  /// fallback for devices without a native session. Quota-watch notices
  /// deep-link to the monitored device's usage page instead.
  Future<void> _handleNotificationTap(Map<String, dynamic> payload) async {
    if (payload['type'] == 'quotaWatch') {
      await _openQuotaUsagePage();
      return;
    }
    final deviceId = payload['deviceId'] as String?;
    if (deviceId == null) return;
    final device = _store.devices.where((d) => d.id == deviceId).firstOrNull;
    if (device == null) return;
    final sessionId = payload['sessionId'] as String?;
    final title = payload['title'] as String?;
    await _store.touch(device.id);
    final session = _hub.ensure(device);
    if (!mounted) return;
    final context = _navigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    if (session != null) {
      await Navigator.of(context).push(zRoute(
        (_) => ChatPage(
          gateway: session,
          sessionId: sessionId,
          title: title ?? deviceDisplayName(context, device.label),
          theme: _theme,
        ),
      ));
      return;
    }
    await _hub.suspend(device.id);
    if (!context.mounted) return;
    await Navigator.of(context).push(zRoute(
      (_) => RemotePage(
        device: device,
        targetSessionId: sessionId,
        targetTitle: title,
      ),
    ));
    _hub.scheduleResume(device);
  }

  /// Quota watch cadence (2026-09-20 真机诊断): doze stalls the RPCs, so
  /// going to the background (paused — home screen, app switch, screen
  /// off) drops to the slow 5-minute cadence, and a resume refreshes at
  /// once instead of waiting out the next periodic tick. `inactive` /
  /// `hidden` (dialogs, system sheets) leave the cadence alone.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _quotaWatch.foregrounded();
    } else if (state == AppLifecycleState.paused) {
      _quotaWatch.backgrounded();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _widgetClickSub?.cancel();
    _appLinkSub?.cancel();
    _notifyHub.dispose();
    _ui.removeListener(_applyQuotaWatchSettings);
    _quotaWatch.dispose();
    _hub.removeListener(_syncNotifyHub);
    _scheduler.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_theme, _ui]),
      builder: (context, _) {
        return MaterialApp(
          navigatorKey: _navigatorKey,
          title: 'ZGo',
          debugShowCheckedModeBanner: false,
          theme: buildLightTheme(),
          darkTheme: buildDarkTheme(),
          themeMode: _theme.mode,
          // Wraps the whole navigator so dialogs/overlays see tr() too.
          // CardTheme/DialogTheme ride the builder (widget form is stable
          // across SDKs; the ThemeData param type is not).
          builder: (context, child) => CardTheme(
                data: zCardTheme(Theme.of(context).brightness),
                child: DialogTheme(
                  data: zDialogTheme(Theme.of(context).brightness),
                  child: UiSettingsProvider(settings: _ui, child: child!),
                ),
              ),
          home: DevicesPage(
            store: _store,
            theme: _theme,
            ui: _ui,
            hub: _hub,
            scheduled: _scheduled,
            keepalive: _keepAlive,
            quotaWatch: _quotaWatch,
          ),
        );
      },
    );
  }
}
