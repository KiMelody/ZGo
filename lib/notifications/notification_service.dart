import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../i18n/lexicon.dart';

/// Notification channels (each can be silenced separately, in-app and by
/// the OS): 任务事件 / 闲时事件 / 自动化结果 / 额度监控.
enum NotifyChannel { tasks, offPeak, automations, quota }

/// Thin wrapper over flutter_local_notifications. Not initialized on
/// test hosts — every method then no-ops, so callers never gate.
class NotificationService {
  NotificationService({
    @visibleForTesting this.launchDetailsOf,
  });

  /// Test seam: answers the cold-start launch details without the plugin's
  /// platform channel (unavailable on a test host). Production leaves it
  /// null and reads [FlutterLocalNotificationsPlugin].
  @visibleForTesting
  final Future<NotificationAppLaunchDetails?> Function()? launchDetailsOf;

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

  /// Set by main: routes a tapped ACTION button (not the body) — the
  /// payload rides along with the action id declared on
  /// [AndroidNotificationAction].
  void Function(Map<String, dynamic> payload, String actionId)? onAction;

  /// One-shot latch for the cold-start delivery ([takeLaunchPayload]):
  /// `didNotificationLaunchApp` stays true for the whole process lifetime,
  /// so the payload must be consumed exactly once (design 11-07 D6).
  bool _launchConsumed = false;

  /// Android channel ids — stable across releases (a changed id would create
  /// a duplicate channel and orphan the user's per-channel silencing).
  static const _channelIds = {
    NotifyChannel.tasks: 'zgo_tasks',
    NotifyChannel.offPeak: 'zgo_offpeak',
    NotifyChannel.automations: 'zgo_automations',
    NotifyChannel.quota: 'zgo_quota',
  };

  /// Table key prefix per channel (`<prefix>.name` / `<prefix>.desc`).
  static const _channelKeys = {
    NotifyChannel.tasks: 'notify.channel.tasks',
    NotifyChannel.offPeak: 'notify.channel.offPeak',
    NotifyChannel.automations: 'notify.channel.automations',
    NotifyChannel.quota: 'notify.channel.quota',
  };

  String _channelName(NotifyChannel channel) =>
      trLocale(_locale, '${_channelKeys[channel]}.name');

  String _channelDescription(NotifyChannel channel) =>
      trLocale(_locale, '${_channelKeys[channel]}.desc');

  bool get isReady => _initialized;

  /// Test seam: flips the initialized latch without touching the plugin
  /// channels (a test host has none — [init] would fail and stay unready).
  @visibleForTesting
  void debugMarkInitialized() => _initialized = true;

  /// Android 13+ / iOS runtime permission (asked once, lazily before the
  /// first notification).
  ///
  /// Returns whether notifications are allowed — `null` when this host has
  /// no platform implementation to ask (tests, unsupported platforms), the
  /// ask threw, or the one-shot ask already ran. Callers therefore nudge
  /// only on an explicit `false`.
  ///
  /// [force] re-asks despite that one-shot latch: the settings switch needs a
  /// real answer every time it is turned on, not just on the first launch
  /// that happened to fire a notification.
  Future<bool?> requestPermission({bool force = false}) async {
    if (!_initialized) return null;
    if (_permissionAsked && !force) return null;
    _permissionAsked = true;
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android != null) {
        return await android.requestNotificationsPermission();
      }
      final ios = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      if (ios != null) {
        return await ios.requestPermissions(
            alert: true, badge: true, sound: true);
      }
    } catch (e) {
      debugPrint('[notify] permission request failed: $e');
    }
    return null;
  }

  /// Opens the OS notification settings for this app. Android/iOS answer via
  /// the plugin's `openAppNotificationSettings`; unsupported platforms throw
  /// and are reported as `false` (never a crash path).
  Future<bool> openAppNotificationSettings() async {
    try {
      return await _plugin.openAppNotificationSettings() ?? false;
    } catch (e) {
      debugPrint('[notify] openAppNotificationSettings failed: $e');
      return false;
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
          final decoded = tryDecodePayload(raw);
          if (decoded == null) return;
          final actionId = response.actionId;
          if (response.notificationResponseType ==
                  NotificationResponseType.selectedNotificationAction &&
              actionId != null &&
              actionId.isNotEmpty) {
            onAction?.call(decoded, actionId);
          } else {
            onTap?.call(decoded);
          }
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
  ///
  /// Blank copy falls back to the channel name — the OS would otherwise
  /// render a ghost notification (an off-peak task can carry neither
  /// title nor prompt, and future tr gaps must never blank a notice).
  static (String, String) ensureCopy(
    String locale,
    NotifyChannel channel,
    String title,
    String body,
  ) {
    final name = trLocale(locale, '${_channelKeys[channel]}.name');
    final t = title.trim().isEmpty ? name : title;
    return (t, body.trim().isEmpty ? t : body);
  }

  /// Decoded payload shared by the tap and action routes; null when the
  /// payload is not a JSON map (never the case for our own notices).
  static Map<String, dynamic>? tryDecodePayload(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? decoded.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  /// Cold-start tap delivery (design 11-07 D6/R5): the payload of the
  /// notification that launched the process, or null.
  ///
  /// Null whenever nothing should be delivered: the service never
  /// initialized on this host (tests / unsupported platforms — the same
  /// no-op contract as [show]), the launch was not caused by a
  /// notification, the payload does not decode, or it was already taken.
  /// `didNotificationLaunchApp` is constant for the process lifetime, so
  /// the payload is consumed at most ONCE per process — callers may poll
  /// this freely.
  ///
  /// Navigation stays with the caller (this layer holds no route stack,
  /// matching the [onTap] injection pattern) — main decides when the
  /// navigator and the device list are ready.
  Future<Map<String, dynamic>?> takeLaunchPayload() async {
    if (!_initialized || _launchConsumed) return null;
    try {
      final details = await (launchDetailsOf?.call() ??
          _plugin.getNotificationAppLaunchDetails());
      if (!_launchConsumed &&
          details != null &&
          details.didNotificationLaunchApp) {
        final raw = details.notificationResponse?.payload;
        if (raw == null || raw.isEmpty) return null;
        final decoded = tryDecodePayload(raw);
        if (decoded == null) return null;
        _launchConsumed = true;
        return decoded;
      }
      return null;
    } catch (e) {
      // Cold-start delivery is an enhancement — never a crash path.
      debugPrint('[notify] launch details failed: $e');
      return null;
    }
  }

  Future<void> show(
    NotifyChannel channel,
    int id,
    String title,
    String body,
    Map<String, dynamic> payload, {
    List<AndroidNotificationAction>? actions,
  }) async {
    if (!_initialized) return;
    await requestPermission();
    final (copyTitle, copyBody) = ensureCopy(_locale, channel, title, body);
    try {
      await _plugin.show(
        id: id,
        title: copyTitle,
        body: copyBody,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channelIds[channel]!,
            _channelName(channel),
            channelDescription: _channelDescription(channel),
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            actions: actions,
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
