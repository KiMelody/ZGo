import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/usage_stats.dart';

/// D1 parse contracts (task 10-08-parity-usage): the 3.14.4 zod shapes
/// from research/design-inputs.md §3/§4 parse into typed carriers; shape
/// drift degrades to zero values without throwing.
void main() {
  /// Full-shape fixture (schema §3).
  Map<String, dynamic> appFixture({String source = 'agent-db'}) => {
        'range': '7d',
        'generatedAt': 1789500000000,
        'timeZone': 'Etc/GMT-8',
        'source': source,
        'summary': {
          'totalTokens': 6240000000,
          'inputTokens': 1000,
          'outputTokens': 2000,
          'reasoningTokens': 300,
          'cacheCreationTokens': 400,
          'cacheReadTokens': 500,
          'cacheHitRate': 0.962,
          'totalSessions': 12,
          'totalTurns': 140,
          'toolCallCount': 33,
          'toolErrorRate': 0.01,
          'modelErrorRate': 0.02,
          'avgTimeToFirstTokenMs': 812,
          'avgTurnDurationMs': 5400,
          'activeDays': 31,
          'currentStreakDays': 31,
          'longestSessionMs': 65200000,
          'longestStreakDays': 31,
          'peakDayTokens': 560000000,
          'favoriteModel': {
            'modelId': 'glm-5.2',
            'totalTokens': 900,
            'share': 0.4,
          },
        },
        'heatmap': {
          'startDate': '2026-08-19',
          'endDate': '2026-10-09',
          'maxTokens': 5000,
          'weeks': [
            {
              'weekIndex': 1,
              'days': [
                null,
                {
                  'date': '2026-10-06',
                  'level': 3,
                  'totalTokens': 4200,
                  'turnCount': 12,
                  'toolCallCount': 5,
                },
              ],
            },
          ],
        },
        'dailyModelUsage': [
          {
            'date': '2026-10-08',
            'models': [
              {'modelId': 'glm-5.2', 'totalTokens': 1200},
              {'modelId': null, 'totalTokens': 30},
            ],
          },
        ],
        'models': [
          {
            'modelId': 'glm-5.2',
            'totalTokens': 1000,
            'inputTokens': 600,
            'outputTokens': 400,
            'requestCount': 20,
            'share': 0.77,
          },
        ],
        'tools': [
          {
            'toolName': 'search-prime',
            'callCount': 10,
            'errorCount': 1,
            'errorRate': 0.1,
            'avgDurationMs': 900,
          },
        ],
      };

  test('full fixture parses into typed carriers', () {
    final s = parseAppUsageSnapshot(appFixture());
    expect(s.range, '7d');
    expect(s.timeZone, 'Etc/GMT-8');
    expect(s.source, 'agent-db');
    expect(s.isMonitorSource, isFalse);

    final summary = s.summary!;
    expect(summary.totalTokens, 6240000000);
    expect(summary.inputTokens, 1000);
    expect(summary.outputTokens, 2000);
    expect(summary.reasoningTokens, 300);
    expect(summary.cacheCreationTokens, 400);
    expect(summary.cacheReadTokens, 500);
    expect(summary.cacheHitRate, 0.962);
    expect(summary.totalSessions, 12);
    expect(summary.totalTurns, 140);
    expect(summary.toolCallCount, 33);
    expect(summary.toolErrorRate, 0.01);
    expect(summary.modelErrorRate, 0.02);
    expect(summary.avgTimeToFirstTokenMs, 812);
    expect(summary.avgTurnDurationMs, 5400);
    expect(summary.activeDays, 31);
    expect(summary.currentStreakDays, 31);
    expect(summary.longestSessionMs, 65200000);
    expect(summary.longestStreakDays, 31);
    expect(summary.peakDayTokens, 560000000);
    expect(summary.favoriteModel?.modelId, 'glm-5.2');
    expect(summary.favoriteModel?.share, 0.4);

    expect(s.heatmap.maxTokens, 5000);
    expect(s.heatmap.weeks, hasLength(1));
    expect(s.heatmap.weeks.first.days.first, isNull);
    final cell = s.heatmap.weeks.first.days[1]!;
    expect(cell.date, '2026-10-06');
    expect(cell.level, 3);
    expect(cell.totalTokens, 4200);
    expect(cell.turnCount, 12);
    expect(cell.toolCallCount, 5);

    expect(s.dailyModelUsage.single.date, '2026-10-08');
    expect(s.dailyModelUsage.single.models, hasLength(2));
    expect(s.dailyModelUsage.single.models.last.modelId, isNull);

    expect(s.models.single.modelId, 'glm-5.2');
    expect(s.models.single.share, 0.77);

    expect(s.tools.single.toolName, 'search-prime');
    expect(s.tools.single.avgDurationMs, 900);
  });

  test('out-of-range heatmap levels clamp into the 0-4 ladder', () {
    final fixture = appFixture()
      ..['heatmap'] = {
        'weeks': [
          {
            'weekIndex': 0,
            'days': [
              {'date': '2026-10-06', 'level': 9, 'totalTokens': 1},
              {'date': '2026-10-07', 'level': -2, 'totalTokens': 1},
            ],
          },
        ],
      };
    final days = parseAppUsageSnapshot(fixture).heatmap.weeks.single.days;
    expect(days[0]!.level, 4);
    expect(days[1]!.level, 0);
  });

  test('shape drift never throws — zero carriers come back', () {
    for (final raw in [null, 'nope', 42, <String, dynamic>{}]) {
      final s = parseAppUsageSnapshot(raw);
      expect(s.summary, isNull);
      expect(s.heatmap.weeks, isEmpty);
      expect(s.dailyModelUsage, isEmpty);
      expect(s.models, isEmpty);
      expect(s.tools, isEmpty);
    }
    // Right blocks with wrong shapes degrade block-by-block.
    final s = parseAppUsageSnapshot({
      'summary': 'nope',
      'heatmap': {'weeks': 'nope'},
      'dailyModelUsage': [42, {'date': 'd'}],
      'models': ['nope'],
      'tools': null,
    });
    expect(s.summary, isNull);
    expect(s.heatmap.weeks, isEmpty);
    expect(s.dailyModelUsage.single.date, 'd');
    expect(s.dailyModelUsage.single.models, isEmpty);
    expect(s.models, isEmpty);
  });

  test('backup source (bigmodel-monitor) keeps zeros and an empty heatmap '
      'visible to the empty-state surfaces', () {
    final s = parseAppUsageSnapshot(
      appFixture(source: 'bigmodel-monitor'),
    );
    expect(s.isMonitorSource, isTrue);
    // The monitor backup pins these to 0 / empty (design-inputs §3):
    // surfaces render the empty state instead of a broken chart.
    final fixture = appFixture(source: 'bigmodel-monitor')
      ..['summary'] = {
        'totalTokens': 1234,
        'longestSessionMs': 0,
        'longestStreakDays': 0,
        'currentStreakDays': 0,
      }
      ..['heatmap'] = {
        'weeks': <dynamic>[],
      };
    final monitor = parseAppUsageSnapshot(fixture);
    expect(monitor.summary!.longestSessionMs, 0);
    expect(monitor.summary!.currentStreakDays, 0);
    expect(monitor.heatmap.weeks, isEmpty);
  });

  test('nullable averages stay null when the desktop omits them', () {
    final s = parseAppUsageSnapshot({
      'summary': {'totalTokens': 5},
    });
    expect(s.summary!.avgTimeToFirstTokenMs, isNull);
    expect(s.summary!.avgTurnDurationMs, isNull);
    expect(s.summary!.favoriteModel, isNull);
  });

  // -------------------------------------------------- coding plan snapshot

  Map<String, dynamic> planFixture() => {
        'range': '7d',
        'rangeStartDate': '2026-10-03',
        'rangeEndDate': '2026-10-09',
        'generatedAt': 1789500000000,
        'sourceProvider': 'bigmodel',
        'quota': {
          'level': 'pro',
          'limits': [
            {
              'type': 'TOKENS_LIMIT',
              'unit': 3,
              'number': 5,
              'percentage': 40,
              'nextResetTime': 1789452028646,
            },
            {'type': 'TOKENS_LIMIT', 'unit': 6, 'percentage': 20},
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
          'granularity': 'day',
          'totalModelCallCount': 40,
          'totalTokensUsage': 900,
          'modelDataList': [
            {
              'modelName': 'GLM-5.2',
              'tokensUsage': [100, 200],
            },
            {
              'modelName': 'GLM-5-Air',
              'tokensUsage': [50, 0],
            },
          ],
        },
      };

  test('coding plan fixture parses quota/activity/modelUsage', () {
    final s = parseCodingPlanUsageSnapshot(planFixture());
    expect(s.range, '7d');
    expect(s.sourceProvider, 'bigmodel');
    expect(s.quota?['level'], 'pro');
    expect(s.quota?['limits'], isA<List>());

    final activity = s.activity!;
    expect(activity.totalTokens, 624000000);
    expect(activity.peakDailyTokens, 56000000);
    expect(activity.peakDailyTokensDate, '2026-10-07');
    expect(activity.totalUsageDurationMs, 65200000);
    expect(activity.currentStreakDays, 31);
    expect(activity.longestStreakDays, 31);
    expect(activity.favoriteModelName, 'GLM-5.2');

    final modelUsage = s.modelUsage!;
    expect(modelUsage.totalTokensUsage, 900);
    expect(modelUsage.xLabels, ['10-03', '10-04']);
    expect(modelUsage.series, hasLength(2));
    expect(modelUsage.series.first.modelName, 'GLM-5.2');
    expect(modelUsage.series.first.tokensUsage, [100.0, 200.0]);
    expect(modelUsage.series.first.total, 300);
  });

  test('coding plan shape drift degrades to null blocks without throwing',
      () {
    for (final raw in [null, <String, dynamic>{}]) {
      final s = parseCodingPlanUsageSnapshot(raw);
      expect(s.quota, isNull);
      expect(s.activity, isNull);
      expect(s.modelUsage, isNull);
    }
    final s = parseCodingPlanUsageSnapshot({
      'quota': 'nope',
      'activity': {'summary': 3},
      'modelUsage': {'modelDataList': 'nope'},
    });
    expect(s.quota, isNull);
    expect(s.activity, isNull);
    expect(s.modelUsage, isNotNull);
    expect(s.modelUsage!.series, isEmpty);
  });
}
