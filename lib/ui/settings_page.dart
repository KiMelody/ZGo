import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../notifications/keepalive_controller.dart';
import '../state/device_store.dart';
import '../state/quota_watch.dart';
import '../update/app_channel.dart';
import '../update/update_service.dart';
import 'about_page.dart';
import 'theme.dart';
import 'ui_settings.dart';
import 'usage_stats_page.dart';

/// App settings: theme, language, native-list switch, plus links to
/// usage stats and about.
class SettingsPage extends StatefulWidget {
  final DeviceStore store;
  final ThemeController theme;
  final UiSettings ui;
  final KeepAliveController keepalive;

  /// Quota-watch controller (Android only): read for the N7 status hint
  /// under the master switch; null on hosts without the feature.
  final QuotaWatchController? quotaWatch;
  const SettingsPage({
    super.key,
    required this.store,
    required this.theme,
    required this.ui,
    required this.keepalive,
    this.quotaWatch,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _checking = false;

  /// Result of the last [KeepAliveController.isRunning] query, refreshed on
  /// every toggle. Asked even while the switch is off, so the status line
  /// still resolves if the persisted setting loads after this page opens.
  Future<bool>? _keepAliveRunning;

  @override
  void initState() {
    super.initState();
    if (!widget.keepalive.supported) return;
    _keepAliveRunning = widget.keepalive.isRunning();
  }

  /// The switch owns the service lifecycle: the persisted setting is the
  /// source of truth for "should it run", the controller reports "does it".
  void _setKeepAlive(bool value) {
    unawaited(widget.ui.setKeepAliveEnabled(value));
    if (value) {
      unawaited(widget.keepalive.start(widget.ui.locale));
    } else {
      unawaited(widget.keepalive.stop());
    }
    setState(() {
      _keepAliveRunning = widget.keepalive.isRunning();
    });
  }

  /// Channel-aware update entry: store builds open their store listing;
  /// the github build checks GitHub releases and offers a browser
  /// download (never an in-app APK install).
  Future<void> _checkForUpdates() async {
    if (_checking) return;
    final storeUrl = storeListingUrl;
    if (storeUrl != null) {
      await launchUrl(storeUrl, mode: LaunchMode.externalApplication);
      return;
    }
    if (appChannel == 'appstore') {
      // appStoreId is not configured yet (pre-submission build).
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr(context, 'update.storePending'))));
      return;
    }
    setState(() => _checking = true);
    try {
      final info = await PackageInfo.fromPlatform();
      final update = await checkForUpdatesFromGithub(info.version);
      if (!mounted) return;
      if (!update.isNewer) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tr(context, 'update.latest'))));
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(
              trP(context, 'update.newVersion', [update.latestVersion])),
          content: (update.body ?? '').trim().isEmpty
              ? Text(tr(context, 'update.availableBody'))
              : SizedBox(
                  width: 420,
                  child: SingleChildScrollView(
                    child: SelectableText(update.body!,
                        style: ZType.sub),
                  ),
                ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c),
                child: Text(tr(context, 'update.later'))),
            FilledButton(
              onPressed: () {
                Navigator.pop(c);
                launchUrl(Uri.parse(update.apkUrl ?? update.releaseUrl),
                    mode: LaunchMode.externalApplication);
              },
              child: Text(tr(context, 'update.download')),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(trP(context, 'update.failed', ['$e']))));
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final ui = widget.ui;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'settings.title'))),
      body: AnimatedBuilder(
        animation: Listenable.merge([theme, ui, widget.quotaWatch]),
        builder: (context, _) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: zContentMaxWidth),
            child: ListView(
              // The 16px content edge lives on the section rows below; the
              // body frame only adds the landscape safe-area inset.
              padding:
                  zScreenPadding(context, top: 8, bottom: 8, horizontal: 0),
              children: [
                _header(context, tr(context, 'settings.appearance')),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Text(tr(context, 'settings.theme')),
                      const Spacer(),
                      SegmentedButton<ThemeMode>(
                        segments: [
                          ButtonSegment(
                            value: ThemeMode.dark,
                            label: Text(tr(context, 'settings.theme.dark')),
                          ),
                          ButtonSegment(
                            value: ThemeMode.light,
                            label: Text(tr(context, 'settings.theme.light')),
                          ),
                          ButtonSegment(
                            value: ThemeMode.system,
                            label: Text(tr(context, 'settings.theme.system')),
                          ),
                        ],
                        selected: {theme.mode},
                        onSelectionChanged: (s) {
                          HapticFeedback.selectionClick();
                          theme.setMode(s.first);
                        },
                        showSelectedIcon: false,
                      ),
                    ],
                  ),
                ),
                _header(context, tr(context, 'settings.general')),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Text(tr(context, 'settings.language')),
                      const Spacer(),
                      SegmentedButton<String>(
                        segments: [
                          ButtonSegment(
                            value: 'zh-CN',
                            label: Text(tr(context, 'settings.language.zh')),
                          ),
                          ButtonSegment(
                            value: 'en-US',
                            label: Text(tr(context, 'settings.language.en')),
                          ),
                        ],
                        selected: {ui.locale},
                        onSelectionChanged: (s) {
                          HapticFeedback.selectionClick();
                          ui.setLocale(s.first);
                        },
                        showSelectedIcon: false,
                      ),
                    ],
                  ),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.list_alt_outlined),
                  title: Text(tr(context, 'settings.nativeList')),
                  subtitle: Text(tr(context, 'settings.nativeListHint')),
                  value: ui.nativeListEnabled,
                  onChanged: (v) => ui.setNativeListEnabled(v),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.account_tree_outlined),
                  title: Text(tr(context, 'settings.gitPanel')),
                  subtitle: Text(tr(context, 'settings.gitPanelHint')),
                  value: ui.gitToolsPanelEnabled,
                  onChanged: (v) => ui.setGitToolsPanelEnabled(v),
                ),
                _header(context, tr(context, 'settings.notifications')),
                SwitchListTile(
                  secondary: const Icon(Icons.notifications_outlined),
                  title: Text(tr(context, 'settings.notifications')),
                  subtitle: Text(tr(context, 'settings.notificationsHint')),
                  value: ui.notificationsEnabled,
                  onChanged: (v) => ui.setNotificationsEnabled(v),
                ),
                if (ui.notificationsEnabled) ...[
                  // Child rows share one indent (parent title +16): the
                  // 24-wide invisible leading slot plus contentPadding
                  // start 32 puts every child title on a single edge.
                  SwitchListTile(
                    secondary: const SizedBox(width: 24),
                    dense: true,
                    contentPadding: const EdgeInsetsDirectional.only(
                        start: 16 + ZSpacing.cardGap, end: 24),
                    title: Text(tr(context, 'settings.notify.tasks')),
                    value: ui.notifyTasksEnabled,
                    onChanged: (v) => ui.setNotifyTasksEnabled(v),
                  ),
                  SwitchListTile(
                    secondary: const SizedBox(width: 24),
                    dense: true,
                    contentPadding: const EdgeInsetsDirectional.only(
                        start: 16 + ZSpacing.cardGap, end: 24),
                    title: Text(tr(context, 'settings.notify.offPeak')),
                    value: ui.notifyOffPeakEnabled,
                    onChanged: (v) => ui.setNotifyOffPeakEnabled(v),
                  ),
                  SwitchListTile(
                    secondary: const SizedBox(width: 24),
                    dense: true,
                    contentPadding: const EdgeInsetsDirectional.only(
                        start: 16 + ZSpacing.cardGap, end: 24),
                    title: Text(tr(context, 'settings.notify.auto')),
                    value: ui.notifyAutoEnabled,
                    onChanged: (v) => ui.setNotifyAutoEnabled(v),
                  ),
                  // Android-only foreground service (see KeepAliveService.kt):
                  // iOS/ohos hosts have no equivalent, so the row is hidden.
                  if (widget.keepalive.supported)
                    SwitchListTile(
                      secondary: const SizedBox(width: 24),
                      dense: true,
                      contentPadding: const EdgeInsetsDirectional.only(
                          start: 16 + ZSpacing.cardGap, end: 24),
                      title: Text(tr(context, 'settings.keepAlive')),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(tr(context, 'settings.keepAliveHint')),
                          if (ui.keepAliveEnabled) ...[
                            const SizedBox(height: 4),
                            _keepAliveStatus(context),
                            const SizedBox(height: 4),
                            Text(
                              tr(context, 'settings.keepAlive.oemHint'),
                              style:
                                  ZType.sub.copyWith(color: ZInk.muted(context)),
                            ),
                          ],
                        ],
                      ),
                      value: ui.keepAliveEnabled,
                      onChanged: _setKeepAlive,
                    ),
                ],
                // Quota watch (Android-only persistent monitoring notice, PRD
                // 09-19): the whole section rides the keep-alive support probe.
                if (widget.keepalive.supported) ...[
                  _header(context, tr(context, 'settings.quotaWatch.section')),
                  SwitchListTile(
                    secondary: const Icon(Icons.monitor_heart_outlined),
                    title: Text(tr(context, 'settings.quotaWatch')),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(tr(context, 'settings.quotaWatchHint')),
                        if (ui.quotaWatchEnabled &&
                            widget.quotaWatch?.snapshot.phase ==
                                QuotaWatchPhase.noPlan) ...[
                          const SizedBox(height: 4),
                          Text(
                            tr(context, 'settings.quotaWatch.noPlan'),
                            style:
                                ZType.sub.copyWith(color: ZInk.muted(context)),
                          ),
                        ],
                      ],
                    ),
                    value: ui.quotaWatchEnabled,
                    onChanged: (v) => ui.setQuotaWatchEnabled(v),
                  ),
                  if (ui.quotaWatchEnabled) ...[
                    // Direct resets ride the foreground service (R3); without
                    // it the notice only updates while the app is foregrounded.
                    if (!ui.keepAliveEnabled)
                      Padding(
                        padding: const EdgeInsets.only(
                            left: 16 + ZSpacing.cardGap),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            onPressed: () => _setKeepAlive(true),
                            child: Text(
                              tr(context, 'settings.quotaWatch.keepAliveGuide'),
                            ),
                          ),
                        ),
                      ),
                    ListTile(
                      leading: const SizedBox(width: 24),
                      dense: true,
                      contentPadding: const EdgeInsetsDirectional.only(
                          start: 16 + ZSpacing.cardGap, end: 24),
                      title: Text(tr(context, 'settings.quotaWatch.threshold')),
                      subtitle: Text(trP(context, 'settings.quotaWatch.thresholdHint',
                          ['${ui.quotaWatchThreshold}'])),
                      trailing: SizedBox(
                        width: 150,
                        child: Slider(
                          value: ui.quotaWatchThreshold.toDouble(),
                          min: 5,
                          max: 50,
                          divisions: 9,
                          label: '${ui.quotaWatchThreshold}%',
                          onChanged: (v) {
                            HapticFeedback.selectionClick();
                            ui.setQuotaWatchThreshold(v.round());
                          },
                        ),
                      ),
                    ),
                    ListTile(
                      leading: const SizedBox(width: 24),
                      dense: true,
                      contentPadding: const EdgeInsetsDirectional.only(
                          start: 16 + ZSpacing.cardGap, end: 24),
                      title: Text(tr(context, 'settings.quotaWatch.interval')),
                      trailing: SegmentedButton<int>(
                        segments: [
                          for (final minutes in const [1, 5, 15])
                            ButtonSegment(
                              value: minutes,
                              label: Text(
                                  trP(context, 'op.minutes', ['$minutes'])),
                            ),
                        ],
                        selected: {ui.quotaWatchIntervalMinutes},
                        onSelectionChanged: (s) {
                          HapticFeedback.selectionClick();
                          ui.setQuotaWatchIntervalMinutes(s.first);
                        },
                        showSelectedIcon: false,
                      ),
                    ),
                    SwitchListTile(
                      secondary: const SizedBox(width: 24),
                      dense: true,
                      contentPadding: const EdgeInsetsDirectional.only(
                          start: 16 + ZSpacing.cardGap, end: 24),
                      title: Text(tr(context, 'settings.quotaWatch.expiryReminder')),
                      subtitle:
                          Text(tr(context, 'settings.quotaWatch.expiryReminderHint')),
                      value: ui.quotaWatchExpiryReminderEnabled,
                      onChanged: (v) => ui.setQuotaWatchExpiryReminderEnabled(v),
                    ),
                    // Per-type N4 leads (2026-09-20): meaningless while the
                    // reminder is off, so they ride its switch.
                    if (ui.quotaWatchExpiryReminderEnabled) ...[
                      ListTile(
                        leading: const SizedBox(width: 24),
                        dense: true,
                        contentPadding: const EdgeInsetsDirectional.only(
                            start: 16 + ZSpacing.cardGap, end: 24),
                        title: Text(tr(context, 'settings.quotaWatch.expiryLead5h')),
                        trailing: SizedBox(
                          width: 150,
                          child: Slider(
                            value: ui.quotaWatchExpiryLeadFiveHourMinutes.toDouble(),
                            min: 5,
                            max: 60,
                            divisions: 11,
                            label: trP(context, 'op.minutes',
                                ['${ui.quotaWatchExpiryLeadFiveHourMinutes}']),
                            onChanged: (v) {
                              HapticFeedback.selectionClick();
                              ui.setQuotaWatchExpiryLeadFiveHourMinutes(v.round());
                            },
                          ),
                        ),
                      ),
                      ListTile(
                        leading: const SizedBox(width: 24),
                        dense: true,
                        contentPadding: const EdgeInsetsDirectional.only(
                            start: 16 + ZSpacing.cardGap, end: 24),
                        title:
                            Text(tr(context, 'settings.quotaWatch.expiryLeadWeek')),
                        trailing: SizedBox(
                          width: 150,
                          child: Slider(
                            value: ui.quotaWatchExpiryLeadWeeklyHours.toDouble(),
                            min: 5,
                            max: 10,
                            divisions: 5,
                            label: trP(context, 'op.hours',
                                ['${ui.quotaWatchExpiryLeadWeeklyHours}']),
                            onChanged: (v) {
                              HapticFeedback.selectionClick();
                              ui.setQuotaWatchExpiryLeadWeeklyHours(v.round());
                            },
                          ),
                        ),
                      ),
                    ],
                  ],
                ],
                _header(context, tr(context, 'settings.data')),
                ListTile(
                  leading: const Icon(Icons.bar_chart_outlined),
                  title: Text(tr(context, 'settings.usageStats')),
                  subtitle: Text(tr(context, 'settings.usageStatsHint')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(zRoute(
                    (_) => UsageStatsPage(store: widget.store, ui: widget.ui),
                  )),
                ),
                ListTile(
                  leading: const Icon(Icons.system_update_outlined),
                  title: Text(tr(context, 'settings.checkUpdate')),
                  trailing: _checking
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.chevron_right),
                  onTap: _checkForUpdates,
                ),
                _header(context, tr(context, 'settings.about')),
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: Text(tr(context, 'settings.about')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(zRoute(
                    (_) => AboutPage(),
                  )),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Status line under the keep-alive switch: the service reports its own
  /// state, so a stale switch value never lies about a running service.
  Widget _keepAliveStatus(BuildContext context) => FutureBuilder<bool>(
        future: _keepAliveRunning,
        builder: (context, snap) => Text(
          tr(
            context,
            snap.data == true
                ? 'settings.keepAlive.running'
                : 'settings.keepAlive.stopped',
          ),
          style: ZType.sub.copyWith(color: ZInk.muted(context)),
        ),
      );

  Widget _header(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
        child: Text(
          text,
          style: ZType.sub.copyWith(
            fontWeight: FontWeight.w600,
            color: ZInk.muted(context),
          ),
        ),
      );
}
