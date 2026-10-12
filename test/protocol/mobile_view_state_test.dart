import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/connection_params.dart';
import 'package:zgo/protocol/remote_client.dart' show mobileViewStatePayload;

/// mobile-view-state-update wire shape (external-relay union, desktop
/// zod): `viewState` is required; `deviceInfo` is optional as a whole
/// but — once present — `deviceInfo.updatedAt` is REQUIRED
/// (`e.number().finite()`, no `.optional()`). A deviceInfo without it
/// fails the union and the desktop drops the WHOLE payload (`invalid
/// external relay payload dropped` — 447 drops over 10-09..10-11 before
/// the fix; task 10-11 view-state-drop-investigation §2/§5).
RemoteConnectionParams paramsOf() => RemoteConnectionParams.parse(
      'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=123&mid=m&name=test'
      '&app_version=3.15.1',
    )!;

void main() {
  test('deviceInfo carries the schema-required updatedAt', () {
    final payload = mobileViewStatePayload(
      workspaceKey: '/repo',
      taskId: 'task-1',
      appVersion: paramsOf().appVersion,
    );
    expect(payload['zcode_type'], 'mobile-view-state-update');

    final viewState = payload['viewState'] as Map;
    expect(viewState['activeWorkspaceKey'], '/repo');
    expect(viewState['activeTaskId'], 'task-1');
    expect(viewState['updatedAt'], isA<int>());

    final deviceInfo = payload['deviceInfo'] as Map;
    expect(deviceInfo['platform'], isNotEmpty);
    expect(deviceInfo['version'], '3.15.1');
    expect(deviceInfo['name'], isNotEmpty);
    // The fix: schema-required on the desktop's MD deviceInfo.
    expect(deviceInfo['updatedAt'], isA<int>());
    expect(deviceInfo['updatedAt'] as int, greaterThan(0));
  });

  test('activeTaskId is omitted when null (official client parity)', () {
    final payload = mobileViewStatePayload(
      workspaceKey: '/repo',
      appVersion: paramsOf().appVersion,
    );
    expect(
      (payload['viewState'] as Map).containsKey('activeTaskId'),
      isFalse,
    );
  });
}
