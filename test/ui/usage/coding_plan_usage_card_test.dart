import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/usage_stats.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';
import 'package:zgo/ui/usage/coding_plan_usage_card.dart';

/// D6 codingPlan-card contracts (task 10-08-parity-usage): the quota-card
/// projection (exact type+unit+number matching, remaining = clamp(100 -
/// percentage)) and the card's section rendering. The conditional
/// show/hide on the two credential error shapes is a page concern and is
/// asserted in device_usage_page_test.dart.
void main() {
  Widget wrap(Widget child) => MaterialApp(
        theme: buildDarkTheme(),
        builder: (context, child) =>
            UiSettingsProvider(settings: UiSettings(), child: child!),
        home: Scaffold(body: child),
      );

  group('buildPlanQuotaCards', () {
    test('matches limits by type+unit+number and projects remaining', () {
      final cards = buildPlanQuotaCards({
        'limits': [
          {
            'type': 'TOKENS_LIMIT',
            'unit': 3,
            'number': 5,
            'percentage': 40,
            'nextResetTime': 123,
          },
          {'type': 'TOKENS_LIMIT', 'unit': 6, 'percentage': 20},
          {'type': 'TIME_LIMIT', 'unit': 5, 'number': 1, 'percentage': 100},
        ],
      });
      expect(cards, hasLength(3));
      // Remaining semantics (entitlement-quota-semantics.md §1).
      expect(cards[0].remainingPercent, 60);
      expect(cards[0].nextResetTime, 123);
      expect(cards[0].colorIndex, 0);
      expect(cards[1].remainingPercent, 80);
      expect(cards[2].remainingPercent, 0);
    });

    test('missing quota/limits degrades to no cards or null remaining', () {
      expect(buildPlanQuotaCards(null), isEmpty);
      expect(buildPlanQuotaCards(const {'limits': 'nope'}), isEmpty);
      final cards = buildPlanQuotaCards(const {
        'limits': [
          {'type': 'requests', 'unit': 'req'},
        ],
      });
      expect(cards, hasLength(3));
      expect(cards.every((c) => c.remainingPercent == null), isTrue);
    });

    test('clamps remaining into 0..100', () {
      final cards = buildPlanQuotaCards(const {
        'limits': [
          {'type': 'TOKENS_LIMIT', 'unit': 3, 'number': 5, 'percentage': 120},
        ],
      });
      expect(cards[0].remainingPercent, 0);
    });
  });

  testWidgets('renders the plan form from a snapshot', (tester) async {
    final snapshot = parseCodingPlanUsageSnapshot({
      'range': '7d',
      'sourceProvider': 'zai',
      'quota': {
        'level': 'pro',
        'limits': [
          {'type': 'TOKENS_LIMIT', 'unit': 3, 'number': 5, 'percentage': 10},
          {'type': 'TOKENS_LIMIT', 'unit': 6, 'percentage': 30},
          {'type': 'TIME_LIMIT', 'unit': 5, 'number': 1, 'percentage': 100},
        ],
      },
      'activity': {
        'summary': {
          'totalTokens': 624000000,
          'peakDailyTokens': 56000000,
          'peakDailyTokensDate': '2026-10-07',
          'totalUsageDurationMs': 65200000,
          'currentStreakDays': 31,
          'longestStreakDays': 31,
          'favoriteModelName': 'GLM-5.2',
        },
      },
      'modelUsage': {
        'xTime': ['10-03', '10-04'],
        'modelDataList': [
          {'modelName': 'GLM-5.2', 'tokensUsage': [100, 200]},
        ],
      },
    });

    await tester.pumpWidget(wrap(CodingPlanUsageCard(snapshot: snapshot)));
    await tester.pumpAndSettle();

    expect(find.text('个人套餐'), findsOneWidget);
    expect(find.text('90%'), findsOneWidget); // 100 - 10
    expect(find.text('70%'), findsOneWidget); // 100 - 30
    expect(find.text('0%'), findsOneWidget); // 100 - 100
    expect(find.text('累计使用时长'), findsOneWidget);
    expect(find.text('常用模型'), findsOneWidget);
    expect(find.text('用量趋势'), findsOneWidget);
  });

  testWidgets('quota bars use the shared 6dp usage-page height',
      (tester) async {
    final snapshot = parseCodingPlanUsageSnapshot(const {
      'quota': {
        'limits': [
          {'type': 'TOKENS_LIMIT', 'unit': 3, 'number': 5, 'percentage': 10},
          {'type': 'TOKENS_LIMIT', 'unit': 6, 'percentage': 30},
          {'type': 'TIME_LIMIT', 'unit': 5, 'number': 1, 'percentage': 100},
        ],
      },
    });
    await tester.pumpWidget(wrap(CodingPlanUsageCard(snapshot: snapshot)));
    await tester.pumpAndSettle();

    final bars = find.byType(LinearProgressIndicator);
    expect(bars, findsNWidgets(3));
    for (var i = 0; i < 3; i++) {
      expect(tester.getSize(bars.at(i)).height, 6);
    }
  });

  testWidgets('a quota window without a reset clock keeps its bar level',
      (tester) async {
    // 「每周」(unit 6) is absent from the projection: its remaining is null
    // and it has no reset clock. The caption placeholder must leave all
    // three bars on one line (2026-10-25 real-device bug).
    final snapshot = parseCodingPlanUsageSnapshot(const {
      'quota': {
        'limits': [
          {
            'type': 'TOKENS_LIMIT',
            'unit': 3,
            'number': 5,
            'percentage': 10,
            'nextResetTime': 1793000000000,
          },
          {
            'type': 'TIME_LIMIT',
            'unit': 5,
            'number': 1,
            'percentage': 40,
            'nextResetTime': 1793000000000,
          },
        ],
      },
    });
    await tester.pumpWidget(wrap(CodingPlanUsageCard(snapshot: snapshot)));
    await tester.pumpAndSettle();

    expect(find.text('--'), findsOneWidget); // weekly column, no value
    final bars = find.byType(LinearProgressIndicator);
    expect(bars, findsNWidgets(3));
    // Order: 5h, weekly, tools — weekly is the middle (no clock) column.
    final top = tester.getTopLeft(bars.at(0)).dy;
    expect(tester.getTopLeft(bars.at(1)).dy, top);
    expect(tester.getTopLeft(bars.at(2)).dy, top);
  });
}
