import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/protocol/connection_params.dart';
import 'package:zlinker/ui/device_usage_page.dart';
import 'package:zlinker/ui/theme.dart';
import 'package:zlinker/ui/ui_settings.dart';

import '../helpers/fake_device_session.dart';

/// The usage page must render the entitlement status phases (design.md
/// table) instead of assuming data exists — the live probe showed the
/// desktop answering `not_configured` with everything null.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(Widget child) => MaterialApp(
        theme: buildDarkTheme(),
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

  /// Recorded `not_configured` response
  /// (internal notes).
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
    expect(find.text('12'), findsOneWidget);
  });

  testWidgets('ok payload renders the existing data cards', (tester) async {
    final session = sessionWith(() async => okPayload());
    addTearDown(session.dispose);
    await tester.pumpWidget(wrap(DeviceUsagePage(session: session)));
    await tester.pumpAndSettle();

    expect(find.text('剩余额度'), findsOneWidget);
    expect(find.text('12'), findsOneWidget); // remaining count
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

  // ------------------------------------------ reset opportunities (R1/R2)

  Map<String, dynamic> okPayloadWithProviderId() => {
        ...okPayload(),
        'provider': {'id': 'prov-1', 'name': 'BigModel'},
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
    expect(find.text('每周池'), findsOneWidget);
    expect(find.textContaining('1 张'), findsOneWidget);
    expect(find.text('暂无可用机会'), findsOneWidget); // week pool is empty
    // 「上次使用重置」line renders for the pool with a history.
    expect(find.textContaining('上次使用重置'), findsOneWidget);
    // Read-only: no reset action anywhere.
    expect(find.text('重置'), findsNothing);
  });

  testWidgets('provider without an id renders the degraded copy', (tester) async {
    final session = sessionWith(
      () async => okPayload(), // provider has no id
      resetStatusAnswer: () => resetStatusFixture(),
    );
    addTearDown(session.dispose);
    await tester.pumpWidget(wrap(DeviceUsagePage(session: session)));
    await tester.pumpAndSettle();

    expect(find.text('重置机会需桌面端套餐数据可用'), findsOneWidget);
    expect(find.text('重置'), findsNothing);
  });

  testWidgets('the read-only card never issues a use RPC, and a failing '
      'status fetch keeps the card', (tester) async {
    var fail = false;
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: paramsOf(),
      channelHandler: (channel, method, args) async {
        switch (method) {
          case 'getEntitlementSnapshot':
            return okPayloadWithProviderId();
          case 'getCodingPlanResetStatus':
            if (fail) throw StateError('no_bigmodel_api_key');
            return resetStatusFixture();
          case 'useCodingPlanReset':
            return {'ok': true};
        }
        return {'dailyModelUsage': []};
      },
    );
    addTearDown(session.dispose);
    await tester.pumpWidget(wrap(DeviceUsagePage(session: session)));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('重置机会'));
    await tester.pumpAndSettle();
    // Tapping the card area consumes nothing — the page is read-only.
    await tester.tap(find.text('5 小时池'));
    await tester.pumpAndSettle();
    expect(
      session.channelCalls.where((c) => c.$2 == 'useCodingPlanReset'),
      isEmpty,
    );

    // A later failing status fetch keeps the card but flags the error —
    // the page must not crash on the degraded path.
    fail = true;
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();
    expect(find.text('重置机会'), findsOneWidget);
  });
}
