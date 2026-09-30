import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/connection_params.dart';
import 'package:zgo/ui/device_usage_page.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../helpers/fake_device_session.dart';

/// The usage page must render the entitlement status phases (design.md
/// table) instead of assuming data exists — the live probe showed the
/// desktop answering `not_configured` with everything null.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(Widget child, {Brightness brightness = Brightness.dark}) =>
      MaterialApp(
        theme: brightness == Brightness.dark
            ? buildDarkTheme()
            : buildLightTheme(),
        builder: (context, child) =>
            UiSettingsProvider(settings: UiSettings(), child: child!),
        home: child,
      );

  RemoteConnectionParams paramsOf() => RemoteConnectionParams.parse(
        'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=123&mid=m&name=test',
      )!;

  FakeDeviceSession sessionWith(
    Future<Object?> Function() entitlementAnswer, {
    Object? Function()? resetStatusAnswer,
  }) {
    return FakeDeviceSession(
      deviceId: 'd1',
      params: paramsOf(),
      channelHandler: (channel, method, args) async {
        if (method == 'getEntitlementSnapshot') {
          return entitlementAnswer();
        }
        if (method == 'getCodingPlanResetStatus') {
          final answer = resetStatusAnswer?.call();
          if (answer is Exception) throw answer;
          return answer;
        }
        if (method == 'useCodingPlanReset') {
          return {'ok': true};
        }
        // getAppUsageSnapshot: empty by default.
        return {'dailyModelUsage': []};
      },
    );
  }

  /// Recorded `not_configured` response (probe 2026-09-13).
  Map<String, dynamic> notConfiguredPayload() => {
        'generatedAt': 1789280250549,
        'authenticated': true,
        'unavailableReason': 'not_configured',
        'context': {'scope': 'personal'},
        'provider': null,
        'remaining': null,
        'subscription': null,
        'quota': null,
      };

  Map<String, dynamic> okPayload() => {
        'authenticated': true,
        'context': {'displayName': '个人版'},
        'provider': {'name': 'BigModel'},
        'remaining': {
          'count': 12,
          'percentage': 40,
          'isShow': true,
          'nextResetTime': 1789300000000,
        },
        'quota': {
          'level': 'pro',
          'limits': [
            {'type': 'requests', 'percentage': 55, 'unit': 'req'},
          ],
        },
        'subscription': null,
      };

  testWidgets('not_configured renders the desktop-status copy with retry',
      (tester) async {
    final session = sessionWith(() async => notConfiguredPayload());
    addTearDown(session.dispose);
    await tester.pumpWidget(wrap(DeviceUsagePage(session: session)));
    await tester.pumpAndSettle();

    expect(find.text('桌面端未配置套餐数据'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    // No misleading data cards.
    expect(find.text('剩余额度'), findsNothing);
  });

  testWidgets('authenticated without provider/remaining renders noPlan',
      (tester) async {
    final session = sessionWith(() async => {'authenticated': true});
    addTearDown(session.dispose);
    await tester.pumpWidget(wrap(DeviceUsagePage(session: session)));
    await tester.pumpAndSettle();

    expect(find.text('当前账号没有可用套餐'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('unauthenticated renders loginRequired', (tester) async {
    final session = sessionWith(() async => {'authenticated': false});
    addTearDown(session.dispose);
    await tester.pumpWidget(wrap(DeviceUsagePage(session: session)));
    await tester.pumpAndSettle();

    expect(find.text('桌面端未登录'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('RPC failure renders the load-failed copy with retry',
      (tester) async {
    final session = sessionWith(() async => throw StateError('rpc down'));
    addTearDown(session.dispose);
    await tester.pumpWidget(wrap(DeviceUsagePage(session: session)));
    await tester.pumpAndSettle();

    expect(find.textContaining('加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('retry after failure re-issues the entitlement RPC',
      (tester) async {
    var fail = true;
    final session = sessionWith(() async {
      if (fail) throw StateError('rpc down');
      return okPayload();
    });
    addTearDown(session.dispose);
    await tester.pumpWidget(wrap(DeviceUsagePage(session: session)));
    await tester.pumpAndSettle();
    expect(find.textContaining('加载失败'), findsOneWidget);

    fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    final entitlementCalls = session.channelCalls
        .where((c) => c.$2 == 'getEntitlementSnapshot')
        .length;
    expect(entitlementCalls, 2);
    expect(find.textContaining('加载失败'), findsNothing);
    expect(find.text('剩余额度'), findsOneWidget);
    expect(find.text('45%'), findsOneWidget); // 100 - 55 (requests limit)
  });

  testWidgets('ok payload renders the existing data cards', (tester) async {
    final session = sessionWith(() async => okPayload());
    addTearDown(session.dispose);
    await tester.pumpWidget(wrap(DeviceUsagePage(session: session)));
    await tester.pumpAndSettle();

    expect(find.text('剩余额度'), findsOneWidget);
    // A2 projection: the requests limit (55% used) drives the summary.
    expect(find.text('45%'), findsOneWidget);
    expect(find.text('其他限额'), findsOneWidget); // unknown type label
    expect(find.text('配额限制'), findsOneWidget); // quota.limits card
    expect(find.text('桌面端未配置套餐数据'), findsNothing);
  });

  testWidgets('first fetch in flight renders the loading spinner',
      (tester) async {
    final gate = Completer<Map<String, dynamic>>();
    final session = sessionWith(() => gate.future);
    addTearDown(session.dispose);
    await tester.pumpWidget(wrap(DeviceUsagePage(session: session)));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    gate.complete(notConfiguredPayload());
    await tester.pumpAndSettle();
    expect(find.text('桌面端未配置套餐数据'), findsOneWidget);
  });

  // ------------------------------------------ semantic limit labels (R3)

  /// Live-probed snapshot shape: both token windows, the monthly built-in
  /// MCP quota (TIME_LIMIT) with per-tool usageDetails, and the
  /// independent server MCP aggregate.
  Map<String, dynamic> limitsPayload() => {
        ...okPayload(),
        'quota': {
          'level': 'lite',
          'limits': [
            {
              'type': 'TOKENS_LIMIT',
              'unit': 3,
              'number': 5,
              'usage': 51,
              'remaining': 49,
              'percentage': 51,
              'nextResetTime': 1789452028646,
            },
            {'type': 'TOKENS_LIMIT', 'unit': 6, 'percentage': 20},
            {
              'type': 'TIME_LIMIT',
              'unit': 5,
              'number': 1,
              'usage': 100,
              'currentValue': 101,
              'remaining': 0,
              'percentage': 100,
              'usageDetails': [
                {'modelCode': 'search-prime', 'usage': 100},
                {'modelCode': 'web-reader', 'usage': 1},
              ],
            },
          ],
        },
        'mcpQuota': {
          'aggregate': {
            'type': 'MCP_USAGE_LIMIT',
            'currentValue': 0,
            'usage': 0,
            'remaining': 1000,
            'percentage': 0,
          },
        },
      };

  testWidgets('limit rows render semantic labels and the server MCP row', (
    tester,
  ) async {
    final session = sessionWith(() async => limitsPayload());
    addTearDown(session.dispose);
    await tester.pumpWidget(wrap(DeviceUsagePage(session: session)));
    await tester.pumpAndSettle();

    expect(find.text('5 小时 token 窗口'), findsOneWidget); // TOKENS_LIMIT 3/5
    expect(find.text('周 token 窗口'), findsOneWidget); // TOKENS_LIMIT unit 6
    expect(find.text('月度内置工具用量'), findsOneWidget); // TIME_LIMIT
    expect(find.text('服务端 MCP 用量'), findsOneWidget); // mcpQuota.aggregate
    // usageDetails detail line survives the label change.
    expect(
      find.textContaining('search-prime: 100'),
      findsOneWidget,
    );
    // Raw enum labels are gone.
    expect(find.textContaining('TOKENS_LIMIT'), findsNothing);
    expect(find.textContaining('TIME_LIMIT'), findsNothing);
  });

  testWidgets('unknown limit types keep the raw enum label', (tester) async {
    final session = sessionWith(() async => okPayload());
    addTearDown(session.dispose);
    await tester.pumpWidget(wrap(DeviceUsagePage(session: session)));
    await tester.pumpAndSettle();

    expect(find.text('requests · unit req'), findsOneWidget);
  });

  // ------------------------------------ summary card A2 projection (R1)
  //
  // The selection rules (most-tense / tie / empty fallback) are asserted
  // against the projection in test/state/entitlement_projection_test.dart;
  // the widget tests below pin the surface semantics on top of it.

  testWidgets('exhausted TIME_LIMIT projects as the tool-calls card with '
      'the remaining count as the main number', (tester) async {
    final session = sessionWith(() async => limitsPayload());
    addTearDown(session.dispose);
    await tester.pumpWidget(wrap(DeviceUsagePage(session: session)));
    await tester.pumpAndSettle();

    // TIME_LIMIT at 100% is the most-tense row → 工具调用 label, and the
    // main number is the remaining count (0), not a percentage.
    expect(find.text('工具调用'), findsOneWidget);
    expect(find.text('0 次'), findsOneWidget);
    expect(find.text('剩余额度'), findsOneWidget);
  });

  testWidgets('the mirror fallback renders when no limit row ranks',
      (tester) async {
    // Same shape as the recorded fixture, but quota.limits carries
    // no usable percentage → primaryLimit is null.
    final session = sessionWith(() async => {
          ...okPayload(),
          'quota': {
            'level': 'pro',
            'limits': [
              {'type': 'requests', 'unit': 'req'},
            ],
          },
        });
    addTearDown(session.dispose);
    await tester.pumpWidget(wrap(DeviceUsagePage(session: session)));
    await tester.pumpAndSettle();

    expect(find.text('12'), findsOneWidget); // mirror count
    expect(find.text('剩余 40%'), findsOneWidget); // mirror caption
    expect(find.text('其他限额'), findsNothing); // no projection label
  });

  testWidgets('light theme: the summary track is the translucent light '
      'token, dark theme keeps the dark overlay (R2)', (tester) async {
    // okPayload's requests limit (55% used) drives the projected bar.
    final light = sessionWith(() async => okPayload());
    addTearDown(light.dispose);
    await tester.pumpWidget(wrap(DeviceUsagePage(session: light),
        brightness: Brightness.light));
    await tester.pumpAndSettle();
    final lightBar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator).first,
    );
    expect(lightBar.backgroundColor, const Color(0x0D0D0D0D)); // 5% black
    expect(lightBar.value, closeTo(0.55, 0.001)); // used percent, not 100%

    final dark = sessionWith(() async => okPayload());
    addTearDown(dark.dispose);
    await tester.pumpWidget(wrap(DeviceUsagePage(session: dark)));
    await tester.pumpAndSettle();
    final darkBar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator).first,
    );
    expect(darkBar.backgroundColor, const Color(0x1AFFFFFF)); // 10% white
  });

  // ------------------------------------------ reset opportunities (R1/R2)
  //
  // The reset-card rules (V1 weekly hiding, untouched-window hiding,
  // summary-time sourcing, scope degradation) are asserted against the
  // projection in test/state/entitlement_projection_test.dart; the smoke
  // below stays as the page-level wiring proof.

  Map<String, dynamic> okPayloadWithProviderId({
    List<Map<String, dynamic>>? limits,
  }) => {
        ...okPayload(),
        'provider': {'id': 'prov-1', 'name': 'BigModel'},
        'quota': {
          'level': 'pro',
          'limits': limits ??
              [
                {
                  'type': 'TOKENS_LIMIT',
                  'unit': 3,
                  'number': 5,
                  'percentage': 40,
                },
              ],
        },
      };

  Map<String, dynamic> resetStatusFixture({
    bool withOpportunity = true,
    Map<String, dynamic>? extra,
  }) =>
      {
        'availableFiveHourResets': [
          if (withOpportunity)
            {
              'expireAt':
                  DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
            },
        ],
        'availableWeekResets': <Map<String, dynamic>>[],
        ...?extra,
      };

  testWidgets('ok state with provider id renders both pool rows read-only '
      '(no reset action on the usage page)', (tester) async {
    final session = sessionWith(
      () async => okPayloadWithProviderId(),
      resetStatusAnswer: () => resetStatusFixture(
        extra: {
          'latestFiveHourResetHistory': {'usedAt': 1789500000000},
        },
      ),
    );
    addTearDown(session.dispose);
    await tester.pumpWidget(wrap(DeviceUsagePage(session: session)));
    await tester.pumpAndSettle();

    expect(find.text('重置机会'), findsOneWidget);
    expect(find.text('5 小时池'), findsOneWidget);
    expect(find.textContaining('1 张'), findsOneWidget);
    expect(find.textContaining('上次使用重置'), findsOneWidget);
    // The weekly pool is empty → its row hides (no per-row copy anymore).
    expect(find.text('每周池'), findsNothing);
    expect(find.text('暂无可用机会'), findsNothing);
    // Read-only: no reset action anywhere.
    expect(find.text('重置'), findsNothing);
  });

  // ------------------------------------------ app usage card (R1/R2/R3)

  Map<String, dynamic> appUsagePayload() => {
        'dailyModelUsage': [
          {
            'date': '2026-09-17',
            'models': [
              {'modelId': 'glm-5.2', 'totalTokens': 1200},
            ],
          },
        ],
      };

  /// Session rendering the full data page (entitlement ok) with a
  /// switchable `getAppUsageSnapshot` answer for the app-usage card.
  FakeDeviceSession appSession({
    required Future<Object?> Function() appUsageAnswer,
  }) {
    return FakeDeviceSession(
      deviceId: 'd1',
      params: paramsOf(),
      channelHandler: (channel, method, args) async {
        if (method == 'getEntitlementSnapshot') return okPayload();
        if (method == 'getCodingPlanResetStatus') return null;
        if (method == 'getAppUsageSnapshot') return appUsageAnswer();
        return null;
      },
    );
  }

  test('ianaEtcTimeZone maps whole-hour offsets with the POSIX inverted '
      'sign and falls back to UTC on fractional ones', () {
    expect(ianaEtcTimeZone(const Duration(hours: 8)), 'Etc/GMT-8');
    expect(ianaEtcTimeZone(const Duration(hours: -6)), 'Etc/GMT+6');
    expect(ianaEtcTimeZone(Duration.zero), 'UTC');
    expect(ianaEtcTimeZone(const Duration(hours: 5, minutes: 30)), 'UTC');
    expect(ianaEtcTimeZone(const Duration(hours: -9, minutes: -30)), 'UTC');
  });

  testWidgets('range tabs align with the official zod enum (no 90d) and '
      'the request carries an IANA timeZone', (tester) async {
    final session = appSession(appUsageAnswer: () async => appUsagePayload());
    addTearDown(session.dispose);
    await tester.pumpWidget(wrap(DeviceUsagePage(session: session)));
    await tester.pumpAndSettle();

    expect(find.text('90d'), findsNothing);
    expect(find.text('7d'), findsOneWidget);
    expect(find.text('30d'), findsOneWidget);
    final call =
        session.channelCalls.firstWhere((c) => c.$2 == 'getAppUsageSnapshot');
    final args = call.$3.first as Map;
    // Only whole-hour Etc/GMT names or the UTC fallback ever go out —
    // never the ambiguous bare abbreviation (Windows "CST").
    expect(args['timeZone'], anyOf(startsWith('Etc/GMT'), 'UTC'));
    expect(args['range'], anyOf('7d', '30d', 'all'));
  });

  testWidgets('app usage first-load failure renders the error state with '
      'retry instead of the empty copy', (tester) async {
    var fail = true;
    final session = appSession(appUsageAnswer: () async {
      if (fail) throw StateError('bridge rebuilding');
      return appUsagePayload();
    });
    addTearDown(session.dispose);
    await tester.pumpWidget(wrap(DeviceUsagePage(session: session)));
    await tester.pumpAndSettle();

    // Failure must not render as「暂无用量」.
    expect(find.text('应用用量加载失败'), findsOneWidget);
    expect(find.text('该时间范围内暂无用量'), findsNothing);

    fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('应用用量加载失败'), findsNothing);
    expect(find.text('2026-09-17'), findsOneWidget);
  });

  testWidgets('app usage failure on a range switch keeps the stale chart '
      'and shows a retryable error line', (tester) async {
    var fail = false;
    final session = appSession(appUsageAnswer: () async {
      if (fail) throw StateError('bridge rebuilding');
      return appUsagePayload();
    });
    addTearDown(session.dispose);
    await tester.pumpWidget(wrap(DeviceUsagePage(session: session)));
    await tester.pumpAndSettle();
    expect(find.text('2026-09-17'), findsOneWidget);

    fail = true;
    await tester.tap(find.text('30d'));
    await tester.pumpAndSettle();

    // Stale chart stays; the failure surfaces as an error line, not the
    // empty copy.
    expect(find.text('2026-09-17'), findsOneWidget);
    expect(find.text('应用用量加载失败'), findsOneWidget);
    expect(find.text('该时间范围内暂无用量'), findsNothing);
  });

  // PRD landscape AC#3: on a 1280-wide tablet the card list converges on
  // the shared content-column cap (zContentMaxWidth, same as the chat
  // message column) instead of stretching edge to edge.
  testWidgets('wide tablet caps the content column at 848 and centers it',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.reset);
    final session = appSession(appUsageAnswer: () async => appUsagePayload());
    addTearDown(session.dispose);
    await tester.pumpWidget(wrap(DeviceUsagePage(session: session)));
    await tester.pumpAndSettle();

    final rect = tester.getRect(find.byType(Card).first);
    expect(rect.width, lessThanOrEqualTo(848));
    expect(rect.center.dx, closeTo(640, 0.5));
  });
}
