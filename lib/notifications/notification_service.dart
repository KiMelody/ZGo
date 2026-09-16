import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../ui/ui_settings.dart';

/// Notification channels (each can be silenced separately, in-app and by
/// the OS): 任务事件 / 闲时事件 / 自动化结果.
enum NotifyChannel { tasks, offPeak, automations }

/// Thin wrapper over flutter_local_notifications. Not initialized on
/// test hosts — every method then no-ops, so callers never gate.
class NotificationService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  bool _permissionAsked = false;

  /// Locale used for the channel name/description. Android fixes those at
  /// channel-creation time, so a later language switch does NOT retitle an
  /// existing channel (accepted limitation — no channel-id versioning).
  String _locale = 'zh-CN';

  /// Set by main: routes a tapped notification to its conversation.
  Future<void> Function(Map<String, dynamic> payload)? onTap;

  /// Android channel ids — stable across releases (a changed id would create
  /// a duplicate channel and orphan the user's per-channel silencing).
  static const _channelIds = {
    NotifyChannel.tasks: 'zlinker_tasks',
    NotifyChannel.offPeak: 'zlinker_offpeak',
    NotifyChannel.automations: 'zlinker_automations',
  };

  /// Table key prefix per channel (`<prefix>.name` / `<prefix>.desc`).
  static const _channelKeys = {
    NotifyChannel.tasks: 'notify.channel.tasks',
    NotifyChannel.offPeak: 'notify.channel.offPeak',
    NotifyChannel.automations: 'notify.channel.automations',
  };

  String _channelName(NotifyChannel channel) =>
      trLocale(_locale, '${_channelKeys[channel]}.name');

  String _channelDescription(NotifyChannel channel) =>
      trLocale(_locale, '${_channelKeys[channel]}.desc');

  bool get isReady => _initialized;

  /// Android 13+ / iOS runtime permission (asked once, lazily before the
  /// first notification).
  Future<void> requestPermission() async {
    if (_permissionAsked || !_initialized) return;
    _permissionAsked = true;
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android != null) {
        await android.requestNotificationsPermission();
      }
      final ios = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      if (ios != null) {
        await ios.requestPermissions(alert: true, badge: true, sound: true);
      }
    } catch (e) {
      debugPrint('[notify] permission request failed: $e');
    }
  }

  Future<void> init({String locale = 'zh-CN'}) async {
    if (_initialized) return;
    _locale = locale;
    try {
      // Register the three Android channels up front so per-channel
      // silencing works from the first notification.
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android != null) {
        for (final channel in NotifyChannel.values) {
          await android.createNotificationChannel(AndroidNotificationChannel(
            _channelIds[channel]!,
            _channelName(channel),
            description: _channelDescription(channel),
            importance: Importance.defaultImportance,
          ));
        }
      }
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      );
      await _plugin.initialize(
        settings: settings,
        onDidReceiveNotificationResponse: (response) {
          final raw = response.payload;
          if (raw == null || raw.isEmpty) return;
          try {
            final decoded = jsonDecode(raw);
            if (decoded is Map) {
              onTap?.call(decoded.cast<String, dynamic>());
            }
          } catch (_) {}
        },
      );
      _initialized = true;
      debugPrint('[notify] initialized');
    } catch (e) {
      // Notification is an enhancement, never a crash path.
      debugPrint('[notify] init failed: $e');
    }
  }

  /// Shows a notification on [channel]. [id] should be stable per topic so
  /// newer events replace older ones (e.g. one per task).
  Future<void> show(
    NotifyChannel channel,
    int id,
    String title,
    String body,
    Map<String, dynamic> payload,
  ) async {
    if (!_initialized) return;
    await requestPermission();
    try {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channelIds[channel]!,
            _channelName(channel),
            channelDescription: _channelDescription(channel),
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
          ),
          // v22: DarwinNotificationDetails has no payload — the tap
          // payload rides the show() call below.
          iOS: const DarwinNotificationDetails(),
        ),
        payload: jsonEncode(payload),
      );
    } catch (e) {
      debugPrint('[notify] show failed: $e');
    }
  }

  /// Stable per-topic notification id (same task replaces its own notice).
  static int stableId(String seed) => seed.hashCode & 0x7fffffff;
}
