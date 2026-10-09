import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../i18n/lexicon.dart';

/// UI preferences: locale (zh-CN / en-US), the native task-list switch and
/// the notification switches (master + per channel).
class UiSettings extends ChangeNotifier {
  static const _localeKey = 'zgo_ui_locale';
  static const _nativeListKey = 'zgo_native_list';
  static const _notifyKey = 'zgo_notify';
  static const _notifyTasksKey = 'zgo_notify_tasks';
  static const _notifyOffPeakKey = 'zgo_notify_offpeak';
  static const _notifyAutoKey = 'zgo_notify_auto';
  static const _keepAliveKey = 'zgo_keepalive';
  static const _quotaWatchKey = 'zgo_quota_watch';
  static const _quotaWatchThresholdKey = 'zgo_quota_watch_threshold';
  static const _quotaWatchIntervalKey = 'zgo_quota_watch_interval';
  static const _quotaWatchExpiryKey = 'zgo_quota_watch_expiry';
  static const _quotaWatchExpiryLead5hKey =
      'zgo_quota_watch_expiry_lead_5h_min';
  static const _quotaWatchExpiryLeadWeekKey =
      'zgo_quota_watch_expiry_lead_week_h';
  static const _newTaskModeKey = 'zgo_new_task_mode';
  static const _newTaskModelKey = 'zgo_new_task_model';
  static const _newTaskThoughtKey = 'zgo_new_task_thought';

  String locale = 'zh-CN';
  bool nativeListEnabled = true;
  bool notificationsEnabled = true;
  bool notifyTasksEnabled = true;
  bool notifyOffPeakEnabled = true;
  bool notifyAutoEnabled = true;
  bool keepAliveEnabled = false;

  /// Quota watch (Android persistent monitoring notice, PRD
  /// internal-task): master switch, low-quota threshold
  /// (remaining %, 5–50 step 5), poll cadence in minutes (1/5/15), the
  /// coupon-expiry reminder and its per-type lead times (2026-09-20:
  /// five-hour coupons 5–60 min, weekly coupons 5–10 h).
  bool quotaWatchEnabled = false;
  int quotaWatchThreshold = 20;
  int quotaWatchIntervalMinutes = 5;
  bool quotaWatchExpiryReminderEnabled = true;
  int quotaWatchExpiryLeadFiveHourMinutes = 60;
  int quotaWatchExpiryLeadWeeklyHours = 6;

  /// New-task defaults (mode / model / thought): applied to new
  /// conversations and local scheduled sends. Empty = follow the desktop's
  /// current runtime selection; invalid values are silently dropped at
  /// assembly time (sanitizeNewTaskConfig).
  String newTaskMode = '';
  String newTaskModel = '';
  String newTaskThought = '';

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    locale = prefs.getString(_localeKey) ?? 'zh-CN';
    nativeListEnabled = prefs.getBool(_nativeListKey) ?? true;
    notificationsEnabled = prefs.getBool(_notifyKey) ?? true;
    notifyTasksEnabled = prefs.getBool(_notifyTasksKey) ?? true;
    notifyOffPeakEnabled = prefs.getBool(_notifyOffPeakKey) ?? true;
    notifyAutoEnabled = prefs.getBool(_notifyAutoKey) ?? true;
    keepAliveEnabled = prefs.getBool(_keepAliveKey) ?? false;
    quotaWatchEnabled = prefs.getBool(_quotaWatchKey) ?? false;
    quotaWatchThreshold = prefs.getInt(_quotaWatchThresholdKey) ?? 20;
    quotaWatchIntervalMinutes = prefs.getInt(_quotaWatchIntervalKey) ?? 5;
    quotaWatchExpiryReminderEnabled =
        prefs.getBool(_quotaWatchExpiryKey) ?? true;
    quotaWatchExpiryLeadFiveHourMinutes =
        (prefs.getInt(_quotaWatchExpiryLead5hKey) ?? 60).clamp(5, 60);
    quotaWatchExpiryLeadWeeklyHours =
        (prefs.getInt(_quotaWatchExpiryLeadWeekKey) ?? 6).clamp(5, 10);
    newTaskMode = prefs.getString(_newTaskModeKey) ?? '';
    newTaskModel = prefs.getString(_newTaskModelKey) ?? '';
    newTaskThought = prefs.getString(_newTaskThoughtKey) ?? '';
    notifyListeners();
  }

  Future<void> setLocale(String value) async {
    locale = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_localeKey, value);
  }

  Future<void> setNativeListEnabled(bool value) async {
    nativeListEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_nativeListKey, value);
  }

  Future<void> setNotificationsEnabled(bool value) async {
    notificationsEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_notifyKey, value);
  }

  Future<void> setNotifyTasksEnabled(bool value) async {
    notifyTasksEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_notifyTasksKey, value);
  }

  Future<void> setNotifyOffPeakEnabled(bool value) async {
    notifyOffPeakEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_notifyOffPeakKey, value);
  }

  Future<void> setNotifyAutoEnabled(bool value) async {
    notifyAutoEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_notifyAutoKey, value);
  }

  /// Background keep-alive is off by default: it trades a persistent
  /// (silent on most devices) notice for the process not being frozen.
  Future<void> setKeepAliveEnabled(bool value) async {
    keepAliveEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keepAliveKey, value);
  }

  Future<void> setQuotaWatchEnabled(bool value) async {
    quotaWatchEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_quotaWatchKey, value);
  }

  Future<void> setQuotaWatchThreshold(int value) async {
    quotaWatchThreshold = value.clamp(5, 50);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_quotaWatchThresholdKey, quotaWatchThreshold);
  }

  Future<void> setQuotaWatchIntervalMinutes(int value) async {
    quotaWatchIntervalMinutes = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_quotaWatchIntervalKey, value);
  }

  Future<void> setQuotaWatchExpiryReminderEnabled(bool value) async {
    quotaWatchExpiryReminderEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_quotaWatchExpiryKey, value);
  }

  Future<void> setQuotaWatchExpiryLeadFiveHourMinutes(int value) async {
    quotaWatchExpiryLeadFiveHourMinutes = value.clamp(5, 60);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
        _quotaWatchExpiryLead5hKey, quotaWatchExpiryLeadFiveHourMinutes);
  }

  Future<void> setQuotaWatchExpiryLeadWeeklyHours(int value) async {
    quotaWatchExpiryLeadWeeklyHours = value.clamp(5, 10);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
        _quotaWatchExpiryLeadWeekKey, quotaWatchExpiryLeadWeeklyHours);
  }

  Future<void> setNewTaskMode(String value) async {
    newTaskMode = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_newTaskModeKey, value);
  }

  Future<void> setNewTaskModel(String value) async {
    newTaskModel = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_newTaskModelKey, value);
  }

  Future<void> setNewTaskThought(String value) async {
    newTaskThought = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_newTaskThoughtKey, value);
  }
}

class UiSettingsProvider extends InheritedWidget {
  final UiSettings settings;

  const UiSettingsProvider({
    super.key,
    required this.settings,
    required super.child,
  });

  static UiSettings? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<UiSettingsProvider>()
      ?.settings;

  @override
  bool updateShouldNotify(UiSettingsProvider oldWidget) =>
      settings != oldWidget.settings;
}

/// Lightweight i18n lookup (single-file table scheme).
String tr(BuildContext context, String key) =>
    trLocale(UiSettingsProvider.of(context)?.locale ?? 'zh-CN', key);

/// [tr] with positional substitution: `$0`, `$1`, ... in the template are
/// replaced by [args] in order.
String trP(BuildContext context, String key, List<String> args) =>
    trByKeyP(UiSettingsProvider.of(context)?.locale ?? 'zh-CN', key, args);

/// Relative-time formatting using the 'time.*' table keys.
String relativeTime(BuildContext context, int ms) {
  final diff = DateTime.now().difference(
    DateTime.fromMillisecondsSinceEpoch(ms),
  );
  // Future timestamps (an automation's 下次运行) read as "in n …".
  if (diff.isNegative) {
    final future = -diff;
    if (future.inMinutes < 60) {
      return trP(context, 'time.minutesLater', ['${future.inMinutes}']);
    }
    if (future.inHours < 24) {
      return trP(context, 'time.hoursLater', ['${future.inHours}']);
    }
    if (future.inDays < 30) {
      return trP(context, 'time.daysLater', ['${future.inDays}']);
    }
    return DateTime.fromMillisecondsSinceEpoch(
      ms,
    ).toLocal().toString().substring(0, 10);
  }
  if (diff.inMinutes < 1) return tr(context, 'time.justNow');
  if (diff.inHours < 1) {
    return trP(context, 'time.minutesAgo', ['${diff.inMinutes}']);
  }
  if (diff.inDays < 1) {
    return trP(context, 'time.hoursAgo', ['${diff.inHours}']);
  }
  if (diff.inDays < 30) {
    return trP(context, 'time.daysAgo', ['${diff.inDays}']);
  }
  return DateTime.fromMillisecondsSinceEpoch(
    ms,
  ).toLocal().toString().substring(0, 10);
}

/// List/sidebar compact relative time: `27分` / `1小时` / `13天`.
String relativeTimeShort(BuildContext context, int ms) {
  final diff = DateTime.now().difference(
    DateTime.fromMillisecondsSinceEpoch(ms),
  );
  if (diff.inMinutes < 1) return tr(context, 'time.short.justNow');
  if (diff.inHours < 1) {
    return trP(context, 'time.short.minutes', ['${diff.inMinutes}']);
  }
  if (diff.inDays < 1) {
    return trP(context, 'time.short.hours', ['${diff.inHours}']);
  }
  if (diff.inDays < 30) {
    return trP(context, 'time.short.days', ['${diff.inDays}']);
  }
  return DateTime.fromMillisecondsSinceEpoch(
    ms,
  ).toLocal().toString().substring(0, 10);
}

/// Compact token count (chat capacity line, task token row): zh renders
/// 万 with one decimal (19.4万) — 亿 above 1e8, plain below 1e4 (matching
/// the official compact formatter's 62.4 亿 / 0 plain forms); en the k/M
/// scale (194k); trailing `.0` is dropped on both.
String compactTokens(BuildContext context, int n) {
  final english =
      (UiSettingsProvider.of(context)?.locale ?? 'zh-CN').startsWith('en');
  if (!english) {
    if (n >= 100000000) return '${_trimZero(n / 100000000)}亿';
    if (n >= 10000) return '${_trimZero(n / 10000)}万';
    return '$n';
  }
  if (n >= 1000000) return '${_trimZero(n / 1000000)}M';
  if (n >= 1000) return '${_trimZero(n / 1000)}k';
  return '$n';
}

/// One decimal with a trailing `.0` removed (30万, not 30.0万).
String _trimZero(double v) {
  final s = v.toStringAsFixed(1);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

/// Usage-duration breakdown (official `Own(ms)`): total minutes read as
/// (days, hours, minutes) — never seconds. Pure, unit-tested.
(int days, int hours, int minutes) usageDurationParts(int ms) {
  final totalMinutes = Duration(milliseconds: ms).inMinutes;
  return (
    totalMinutes ~/ 1440,
    (totalMinutes % 1440) ~/ 60,
    totalMinutes % 60,
  );
}

/// Usage-duration text (`N 天 N 小时 N 分钟`, zero parts dropped;
/// all-zero renders 0 分钟 like the official formatter).
String usageDuration(BuildContext context, int ms) {
  final (days, hours, minutes) = usageDurationParts(ms);
  final parts = [
    if (days > 0) trP(context, 'usage.duration.days', ['$days']),
    if (hours > 0) trP(context, 'usage.duration.hours', ['$hours']),
    if (minutes > 0) trP(context, 'usage.duration.minutes', ['$minutes']),
  ];
  if (parts.isEmpty) return trP(context, 'usage.duration.minutes', ['0']);
  return parts.join(' ');
}
