import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../ui/ui_settings.dart';

/// Dart side of the Android foreground service that keeps the relay
/// connection (and therefore background task notifications) alive.
///
/// Mirrors `KeepAliveService.kt` over the `zlinker/keepalive` channel. The
/// persistent notice's copy is localized here (`trLocale`, same pattern as
/// `notify.channel.*`) because the native side has no translation table.
class KeepAliveController {
  static const _channel = MethodChannel('zlinker/keepalive');

  /// Android only — iOS has no foreground-service equivalent and the
  /// ohos/test hosts have no channel.
  bool get supported => Platform.isAndroid;

  /// Starts the service with the persistent notice in [locale]. The app is
  /// in the foreground whenever this is called (settings toggle / app start).
  Future<void> start(String locale) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<bool>('start', {
        'title': trLocale(locale, 'keepalive.notify.title'),
        'body': trLocale(locale, 'keepalive.notify.body'),
        'channelName': trLocale(locale, 'keepalive.channel.name'),
      });
    } catch (e) {
      debugPrint('[keepalive] start failed: $e');
    }
  }

  Future<void> stop() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<bool>('stop');
    } catch (e) {
      debugPrint('[keepalive] stop failed: $e');
    }
  }

  /// Whether the service is running right now (settings status line).
  Future<bool> isRunning() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('isRunning') ?? false;
    } catch (e) {
      debugPrint('[keepalive] isRunning failed: $e');
      return false;
    }
  }
}
