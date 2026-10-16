import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/usage_stats.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';
import 'package:zgo/ui/usage/coding_plan_usage_card.dart';
import 'package:zgo/ui/usage/usage_heatmap.dart';
import 'package:zgo/ui/usage/usage_limit_row.dart';
import 'package:zgo/ui/usage/usage_model_ring.dart';
import 'package:zgo/ui/usage/usage_stat_grid.dart';
import 'package:zgo/ui/usage/usage_trend_chart.dart';

/// 窄屏防溢出冒烟矩阵（task 10-16-narrow-screen-overflow R3）。
///
/// 三档宽度 [kOverflowSmokeWidths]（逻辑 dp）逐档渲染已登记页面的公开组件：
/// 窄档（320/360）断言零 RenderFlex 溢出 —— 溢出走 FlutterError，显式
/// `takeException()` 兜底让静默通过不可能；384 档再用同一 fixture 断言核心
/// 内容完整渲染（无 ellipsis 激活），守住「双向」：防窄屏爆版的修复不能把
/// 宽屏也截了。
///
/// 维护约定：**新页面 / 新组件手动登记进 [kOverflowSmokeWidths] 与
/// [_usageSurfaces]** —— 不做自动发现、不做 golden。fixture 一律用真实量级
/// 长文案（窄屏溢出只发生在长文案上，短文案测不出来），构造方式参考各组件
/// test/ui/usage/*_test.dart。
///
/// 字体：默认测试字体每个字符都是 1em 方块，宽度约是真机的两倍 —— 384 档
/// 「不截断」断言只有在仓库内 NotoSansSC 的真实字形度量下才成立（顺带避免
/// 用方块字测出真机不存在的溢出），故本文件 [setUpAll] 显式加载它。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(loadBundledFonts);

  for (final width in kOverflowSmokeWidths) {
    group('${width.toInt()}dp', () {
      for (final (name, build) in _usageSurfaces) {
        testWidgets('$name lays out with zero overflow', (tester) async {
          await pumpAt(tester, width, build());
          expect(tester.takeException(), isNull);
        });
      }
    });
  }

  // ------------------------------------------- 384dp 完整渲染（修剪过头闸）

  testWidgets(
      '384dp: the real-magnitude quota row renders whole — title, clock and '
      'right caption all untruncated', (tester) async {
    // Natural reference: the same row at a width where both 50% flex caps
    // exceed every run, so each Text renders at its unconstrained width.
    //
    // Component-context width (bare Card, margin 8 → 344dp inner). On the
    // real page insets (384 screen → 320 inner) the half-width flex cap
    // trims one title glyph even though the row would fit — the sanctioned
    // first sacrifice (user decision A, task 10-16 check P1-1): accepted,
    // a measured two-pass allocation was ruled out as over-engineering.
    await pumpAt(tester, 800, _quotaRow());
    final natural = _quotaRowWidths(tester);

    await pumpAt(tester, 384, _quotaRow());
    expect(tester.takeException(), isNull);
    final rendered = _quotaRowWidths(tester);
    for (var i = 0; i < kQuotaRowCopy.length; i++) {
      expect(
        rendered[i],
        closeTo(natural[i], 0.01),
        reason: '「${kQuotaRowCopy[i]}」@384dp 被截断：'
            '渲染 ${rendered[i]} < 自然 ${natural[i]}',
      );
    }
  });

  testWidgets('320dp: the sacrifice order holds — title tail first, clock '
      'and right caption stay whole', (tester) async {
    await pumpAt(tester, 800, _quotaRow());
    final natural = _quotaRowWidths(tester);

    await pumpAt(tester, 320, _quotaRow());
    expect(tester.takeException(), isNull);
    final rendered = _quotaRowWidths(tester);
    // The fixture is genuinely too wide for 320dp — the title ellipsizes
    // hard (this also proves the fixture still exercises the narrow path)…
    expect(rendered[0], lessThan(natural[0] - 20));
    // …the clock caption never truncates, and the right value may only
    // lose ellipsis-glyph pixels (「45.0%」→「45.…」on device), never a
    // whole run — the quantified sacrifice order (check P1-1 decision A).
    expect(rendered[1], closeTo(natural[1], 0.01));
    expect(natural[2] - rendered[2], lessThan(8));
  });
}

/// Width tiers every registered surface must survive (logical dp, physical
/// size + dpr 1 recipe). 320 = smallest phone, 360 = PMA110 (the device that
/// reported the overflow), 384 = xuanyuan (the width the fix must not trim).
const List<double> kOverflowSmokeWidths = [320, 360, 384];

/// Loads the bundled app family (regular/medium/semi-bold) so fixture widths
/// match the device instead of the 1em-box test font.
Future<void> loadBundledFonts() async {
  final loader = FontLoader(zFontFamily);
  for (final weight in ['Regular', 'Medium', 'SemiBold']) {
    final bytes =
        File('assets/fonts/NotoSansSC-$weight.ttf').readAsBytesSync();
    loader.addFont(Future.value(ByteData.sublistView(bytes)));
  }
  await loader.load();
}

/// Pumps [child] at [width] logical dp in the app theme — the
/// `physicalSize` + `devicePixelRatio = 1.0` + reset recipe this repo's
/// other narrow-width tests use.
Future<void> pumpAt(WidgetTester tester, double width, Widget child) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: buildDarkTheme(),
    builder: (context, child) =>
        UiSettingsProvider(settings: UiSettings(), child: child!),
    home: Scaffold(body: child),
  ));
  await tester.pumpAndSettle();
}

/// The card context the page gives a bare surface (`_statsCard` /
/// `_trendCard` / `_ringCard`): `Card > Padding(16)` — reproduced so the
/// component sees the same inner width it gets on the page.
Widget usageCard(Widget child) => Card(
      child: Padding(
        padding: const EdgeInsets.all(ZSpacing.card),
        child: child,
      ),
    );

/// Registered usage-page surfaces (R3): one builder per public component the
/// page renders. Register new surfaces here — see the file header.
final List<(String, Widget Function())> _usageSurfaces = [
  // D2 summary grid — app-usage magnitudes from the recorded fixture.
  (
    'UsageStatGrid',
    () => usageCard(const UsageStatGrid(items: [
          ('62.4亿', '累计 Token 数'),
          ('5.6亿', '峰值 Token 数'),
          ('18 小时 6 分钟', '最长聊天时长'),
          ('31 天', '当前连续天数'),
          ('31 天', '最长连续天数'),
        ])),
  ),
  // 配额限制 rows — the reported copy + the saturating-value fallback.
  ('UsageLimitRow (reported copy)', () => _quotaRow()),
  ('UsageLimitRow (saturating values)', () => _quotaRow(saturated: true)),
  // …and the reported geometry itself: the row at the page's real inner
  // width (screen padding + card padding), which is where the 360dp
  // overflow was measured — the component-level tiers miss it at 360.
  ('UsageLimitRow (page insets)', () => _quotaRowInPage()),
  // Bilingual longest copy: the en locale's longer title (「Monthly
  // built-in tool usage」) is this row's widest legitimate left segment.
  (
    'UsageLimitRow (en copy)',
    () => UiSettingsProvider(
          settings: UiSettings()..locale = 'en-US',
          child: _quotaRow(),
        ),
  ),
  // D3 heatmap (carries its own Card).
  ('UsageHeatmapCard', () => UsageHeatmapCard(heatmap: _heatmap())),
  // D4 trend chart — a long model name rides the legend's Wrap.
  (
    'UsageLineChart',
    () => usageCard(const UsageLineChart(
          xLabels: ['2026-10-01', '2026-10-02', '2026-10-03'],
          series: [
            (
              modelId: 'GLM-4.6-AirX-Enterprise-Edition',
              values: [10.0, 0.0, 7.0],
            ),
            (modelId: null, values: [15.0, 5.0, 0.0]),
          ],
        )),
  ),
  // D5 model ring.
  (
    'UsageModelRing',
    () => usageCard(const UsageModelRing(models: [
          AppModelUsage(modelId: 'GLM-5.2', totalTokens: 300),
          AppModelUsage(
            modelId: 'GLM-4.6-AirX-Enterprise-Edition',
            totalTokens: 100,
          ),
          AppModelUsage(modelId: 'glm-4-plus', totalTokens: 50),
        ])),
  ),
  // D6 codingPlan card (carries its own Card).
  ('CodingPlanUsageCard', () => CodingPlanUsageCard(snapshot: _codingPlan())),
];

/// The narrow-screen report's own quota row (PRD 背景证据):
/// 「月度内置工具用量 10-31 00:04 用量 100 · 剩余 55 · 0%」. The reset
/// clock is pinned far in the future so [EntitlementView.fmtResetClock]
/// deterministically renders the `MM-dd HH:mm` form.
final Map<String, dynamic> _monthlyTools = {
  'type': 'TIME_LIMIT',
  'unit': 5,
  'number': 1,
  'usage': 100,
  'remaining': 55,
  'percentage': 0,
  'nextResetTime': DateTime(2035, 10, 31, 0, 4).millisecondsSinceEpoch,
};

/// The row copy the width assertions watch, in title / clock / right order —
/// the same three runs the reported overflow banner measured.
final List<String> kQuotaRowCopy = [
  '月度内置工具用量',
  '10-31 00:04',
  // The component's own formatting: trP padding + `'$percentage%'`, and
  // native Dart prints integral doubles with one decimal (0 → 0.0) — the
  // report's 「0%」 is shorthand for this caption.
  '用量 100 · 剩余 55 · 0.0%',
];

/// The reported row inside the page's 配额限制 card context. With
/// [saturated] the value strings take the full-width form (「用量 1,234,567
/// · 剩余 9,999,999 · 100.0%」) the right caption's ellipsis fallback exists
/// for.
Widget _quotaRow({bool saturated = false}) => usageCard(UsageLimitRow(
      limit: saturated
          ? {
              ..._monthlyTools,
              'usage': '1,234,567',
              'remaining': '9,999,999',
              'percentage': 100.0,
            }
          : _monthlyTools,
    ));

/// Rendered widths of the reported row's three watched Texts.
List<double> _quotaRowWidths(WidgetTester tester) => [
      for (final copy in kQuotaRowCopy) tester.getSize(find.text(copy)).width,
    ];

/// The reported row at the page's real inner width: the page adds
/// `zScreenPadding` (portrait value [ZSpacing.screen]; safe-area insets are
/// 0 in tests) around the card, so the row sees 64dp less than the tier.
Widget _quotaRowInPage() => Padding(
      padding: const EdgeInsets.symmetric(horizontal: ZSpacing.screen),
      child: _quotaRow(),
    );

/// Two real weeks of the recorded heatmap shape.
UsageHeatmap _heatmap() => UsageHeatmap(weeks: [
      UsageHeatmapWeek(weekIndex: 0, days: [
        UsageHeatmapCell(
          date: '2026-10-06',
          level: 2,
          totalTokens: 12000,
          turnCount: 4,
          toolCallCount: 2,
        ),
      ]),
      UsageHeatmapWeek(weekIndex: 1, days: [
        UsageHeatmapCell(
          date: '2026-10-13',
          level: 3,
          totalTokens: 8000,
          turnCount: 2,
          toolCallCount: 1,
        ),
      ]),
    ]);

/// Recorded codingPlan snapshot shape (test/ui/usage/coding_plan_usage_card
/// _test.dart), with a long favorite-model name in the activity grid.
CodingPlanUsageSnapshot _codingPlan() => parseCodingPlanUsageSnapshot({
      'range': '7d',
      'sourceProvider': 'zai',
      'quota': {
        'level': 'pro',
        'limits': [
          {
            'type': 'TOKENS_LIMIT',
            'unit': 3,
            'number': 5,
            'percentage': 10,
            'nextResetTime': _monthlyTools['nextResetTime'],
          },
          {
            'type': 'TOKENS_LIMIT',
            'unit': 6,
            'percentage': 30,
            'nextResetTime': _monthlyTools['nextResetTime'],
          },
          {
            'type': 'TIME_LIMIT',
            'unit': 5,
            'number': 1,
            'percentage': 100,
            'nextResetTime': _monthlyTools['nextResetTime'],
          },
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
          'favoriteModelName': 'GLM-4.6-AirX-Enterprise-Edition',
        },
      },
      'modelUsage': {
        'xTime': ['10-03', '10-04'],
        'modelDataList': [
          {
            'modelName': 'GLM-4.6-AirX-Enterprise-Edition',
            'tokensUsage': [100, 200],
          },
        ],
      },
    });
