import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/protocol/device_info.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('maps the current target platform to its handshake name', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    expect(remotePlatformName(), 'android');
  });

  test('non-android platforms map too (macOS desk check)', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    expect(remotePlatformName(), 'macos');
  });
}
