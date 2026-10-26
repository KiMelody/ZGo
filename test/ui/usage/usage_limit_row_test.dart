import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/ui/usage/usage_limit_row.dart';

/// `usage_limit_row` surfaces: the token-count abbreviation ([fmtTokenCount],
/// 10-24 acceptance fix — raw 9-digit counts were unreadable) and the row
/// caption it feeds.
void main() {
  test('fmtTokenCount abbreviates at 1e4 / 1e6 / 1e9 with one decimal', () {
    expect(fmtTokenCount(9999), '9999');
    expect(fmtTokenCount(10000), '10.0k');
    expect(fmtTokenCount(15202), '15.2k');
    expect(fmtTokenCount(1520246), '1.5M');
    expect(fmtTokenCount(284797538), '284.8M');
    expect(fmtTokenCount(2000000000), '2.0B');
  });

  test('fmtTokenCount keeps the sign on negative values', () {
    expect(fmtTokenCount(-9999), '-9999');
    expect(fmtTokenCount(-15202462), '-15.2M');
    expect(fmtTokenCount(-2000000000), '-2.0B');
  });

  testWidgets('UsageLimitRow shows remaining copy and bar (used wire value '
      'flipped)', (tester) async {
    // The live Start bucket values of the acceptance report: flash bucket
    // 15.2M used / 284.8M left. The wire percentage (already normalized by
    // the poller) is 5.07 USED → the row renders 94.9% LEFT.
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: UsageLimitRow(limit: const {
          'type': 'ent-zcode-v3-start-plan-1024-1',
          'usage': 15202462,
          'remaining': 284797538,
          'percentage': 5.07,
        }),
      ),
    ));

    expect(find.text('用量 15.2M · 剩余 284.8M · 94.9%'), findsOneWidget);
    // The bar is remaining fullness: 100 - 5.07 ≈ 94.9% filled.
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, closeTo(0.9493, 0.001));
    // Usage-page bar height is the shared 6dp token (2026-10-25).
    expect(
      tester.getSize(find.byType(LinearProgressIndicator)).height,
      6,
    );
  });
}
