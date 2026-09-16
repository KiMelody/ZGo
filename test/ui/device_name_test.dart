import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/state/device_store.dart';
import 'package:zlinker/ui/ui_settings.dart';
import 'package:zlinker/ui/widgets/device_name.dart';

void main() {
  Widget host(String locale) => UiSettingsProvider(
        settings: UiSettings()..locale = locale,
        child: const MaterialApp(home: SizedBox()),
      );

  testWidgets('empty label falls back to the localized "unnamed device"',
      (tester) async {
    await tester.pumpWidget(host('zh-CN'));
    final zh = tester.element(find.byType(SizedBox));
    expect(deviceDisplayName(zh, ''), '未命名设备');
    expect(deviceDisplayName(zh, 'MacBook'), 'MacBook');

    await tester.pumpWidget(host('en-US'));
    final en = tester.element(find.byType(SizedBox));
    expect(deviceDisplayName(en, ''), 'Unnamed device');
    expect(deviceDisplayName(en, 'MacBook'), 'MacBook');
  });

  test('storage stays language-neutral: a missing label loads as empty', () {
    final device = Device.fromJson({
      'id': 'd1',
      'url': 'https://example.test/remote',
      'addedAt': 0,
    });
    expect(device.label, isEmpty);
  });
}
