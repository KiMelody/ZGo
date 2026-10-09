import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';
import 'package:zgo/ui/usage/usage_stat_grid.dart';

/// D2 stat-grid contracts (task 10-08-parity-usage): value/label cells with
/// the responsive column count (2 on phones, 3 on wide surfaces).
void main() {
  Widget wrap(Widget child, {required double width}) => MaterialApp(
        theme: buildDarkTheme(),
        builder: (context, child) =>
            UiSettingsProvider(settings: UiSettings(), child: child!),
        home: Scaffold(
          body: Center(child: SizedBox(width: width, child: child)),
        ),
      );

  const items = [
    ('62.4亿', '累计 Token 数'),
    ('5.6亿', '峰值 Token 数'),
    ('18 小时 6 分钟', '最长聊天时长'),
    ('31 天', '当前连续天数'),
    ('31 天', '最长连续天数'),
  ];

  testWidgets('renders value/label pairs in 2 columns on a phone width',
      (tester) async {
    await tester.pumpWidget(wrap(const UsageStatGrid(items: items), width: 400));
    await tester.pumpAndSettle();

    expect(find.text('62.4亿'), findsOneWidget);
    expect(find.text('累计 Token 数'), findsOneWidget);

    // 2 columns: the first two cells share a row; the third wraps.
    final dy0 = tester.getTopLeft(find.text('62.4亿')).dy;
    final dy1 = tester.getTopLeft(find.text('5.6亿')).dy;
    final dy2 = tester.getTopLeft(find.text('18 小时 6 分钟')).dy;
    expect(dy1, dy0);
    expect(dy2, greaterThan(dy0));
  });

  testWidgets('lays out 3 columns on a wide surface', (tester) async {
    await tester.pumpWidget(wrap(
      const UsageStatGrid(items: [('a', 'A'), ('b', 'B'), ('c', 'C'), ('d', 'D')]),
      width: 700,
    ));
    await tester.pumpAndSettle();

    final dyA = tester.getTopLeft(find.text('a')).dy;
    expect(tester.getTopLeft(find.text('b')).dy, dyA);
    expect(tester.getTopLeft(find.text('c')).dy, dyA);
    expect(tester.getTopLeft(find.text('d')).dy, greaterThan(dyA));
  });
}
