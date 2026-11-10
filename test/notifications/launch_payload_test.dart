import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/notifications/notification_service.dart';

/// Cold-start tap delivery (design 11-07 D6/R5):
/// `NotificationService.takeLaunchPayload` reads `getNotificationAppLaunch
/// Details` once, decodes the JSON payload, and answers null everywhere the
/// delivery must be skipped. The plugin channel does not exist on a test
/// host, so the launch-details seam is injected.
NotificationAppLaunchDetails launch(String? payload) =>
    NotificationAppLaunchDetails(
      true,
      notificationResponse: payload == null
          ? null
          : NotificationResponse(
              notificationResponseType:
                  NotificationResponseType.selectedNotification,
              payload: payload,
            ),
    );

void main() {
  test('a notification launch answers the decoded payload exactly once', () async {
    var calls = 0;
    final service = NotificationService(
      launchDetailsOf: () async {
        calls += 1;
        return launch(jsonEncode({
          'type': 'task',
          'deviceId': 'd1',
          'sessionId': 's1',
          'workspacePath': '/repo/beta',
        }));
      },
    )..debugMarkInitialized();

    expect(await service.takeLaunchPayload(), {
      'type': 'task',
      'deviceId': 'd1',
      'sessionId': 's1',
      'workspacePath': '/repo/beta',
    });
    // didNotificationLaunchApp is constant per process: a second read must
    // not re-deliver (a resumed app would otherwise reopen the task).
    expect(await service.takeLaunchPayload(), isNull);
    expect(calls, 1, reason: 'the consumed latch skips the plugin read');
  });

  test('an uninitialized service never reads the plugin', () async {
    var calls = 0;
    final service = NotificationService(
      launchDetailsOf: () async {
        calls += 1;
        return launch(jsonEncode({'type': 'task'}));
      },
    );

    expect(await service.takeLaunchPayload(), isNull);
    expect(calls, 0, reason: 'same no-op contract as show()');
  });

  test('a cold start that was not a notification answers null', () async {
    final service = NotificationService(
      launchDetailsOf: () async => const NotificationAppLaunchDetails(false),
    )..debugMarkInitialized();

    expect(await service.takeLaunchPayload(), isNull);
  });

  test('a launch without a response payload answers null', () async {
    final service = NotificationService(
      launchDetailsOf: () async => launch(null),
    )..debugMarkInitialized();

    expect(await service.takeLaunchPayload(), isNull);
  });

  test('an undecodable payload answers null and is not consumed', () async {
    var calls = 0;
    final service = NotificationService(
      launchDetailsOf: () async {
        calls += 1;
        return launch('not json');
      },
    )..debugMarkInitialized();

    expect(await service.takeLaunchPayload(), isNull);
    expect(await service.takeLaunchPayload(), isNull);
    expect(calls, 2, reason: 'a bad payload is not a successful delivery');
  });

  test('a throwing host never crashes the launch path', () async {
    final service = NotificationService(
      launchDetailsOf: () async => throw StateError('no platform'),
    )..debugMarkInitialized();

    expect(await service.takeLaunchPayload(), isNull);
  });
}
