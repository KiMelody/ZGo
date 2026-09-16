import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/protocol/connection_params.dart';
import 'package:zlinker/state/quota_reset.dart';

import '../helpers/fake_device_session.dart';

/// Fixtures use only the research whitelist structure
/// (internal notes
/// quota-reset-bundle-analysis.md): pool entries carry `expireAt`.
void main() {
  RemoteConnectionParams paramsOf() => RemoteConnectionParams.parse(
        'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=123&mid=m&name=test',
      )!;

  // ------------------------------------------------------------- parsing

  group('parseQuotaResetPools', () {
    final now = DateTime(2026, 9, 14, 12);

    test('projects counts and the earliest expiry, excluding expired', () {
      final pools = parseQuotaResetPools(
        {
          'availableFiveHourResets': [
            {'expireAt': now.millisecondsSinceEpoch + 3600000},
            {'expireAt': now.millisecondsSinceEpoch + 60000},
            {'expireAt': now.millisecondsSinceEpoch - 60000}, // expired
            {'expireAt': 'oops'}, // mistyped entry skipped
            'garbage', // non-map entry skipped
          ],
          'availableWeekResets': [
            {'expireAt': now.millisecondsSinceEpoch + 7 * 24 * 3600000},
          ],
        },
        now: now,
      );
      expect(pools.hasData, isTrue);
      expect(pools.fiveHour.count, 2);
      expect(
        pools.fiveHour.earliestExpireAt,
        now.millisecondsSinceEpoch + 60000,
      );
      expect(pools.week.count, 1);
      expect(pools.hasAnyOpportunity, isTrue);
    });

    test('missing / mistyped fields degrade to count=0 without throwing',
        () {
      expect(parseQuotaResetPools(null, now: now).hasData, isFalse);
      expect(parseQuotaResetPools({}, now: now).hasData, isFalse);
      final broken = parseQuotaResetPools(
        {
          'availableFiveHourResets': 'not-a-list',
          'availableWeekResets': [
            {'noExpireAt': true},
          ],
        },
        now: now,
      );
      expect(broken.hasData, isTrue); // week field was a List
      expect(broken.fiveHour.count, 0);
      expect(broken.week.count, 0);
      expect(broken.week.earliestExpireAt, isNull);
      expect(broken.hasAnyOpportunity, isFalse);
    });

    test('lastUsedAt reads the pool histories with null tolerance', () {
      final pools = parseQuotaResetPools(
        {
          'availableFiveHourResets': [
            {'expireAt': now.millisecondsSinceEpoch + 60000},
          ],
          'availableWeekResets': [
            {'expireAt': now.millisecondsSinceEpoch + 60000},
          ],
          'latestFiveHourResetHistory': {'usedAt': 1789500000000},
          'latestWeekResetHistory': {'usedAt': 'oops'}, // mistyped → null
        },
        now: now,
      );
      expect(pools.fiveHour.lastUsedAt, 1789500000000);
      expect(pools.week.lastUsedAt, isNull);
      // withProcessing keeps the value transparently (optimistic flow).
      final processing = pools.withProcessing({quotaResetTypeFiveHour});
      expect(processing.fiveHour.lastUsedAt, 1789500000000);
      expect(processing.fiveHour.processing, isTrue);
    });

    test('missing / null histories leave lastUsedAt null without throwing',
        () {
      final pools = parseQuotaResetPools(
        {
          'availableWeekResets': [],
          'latestWeekResetHistory': null,
          // five-hour side fully absent
        },
        now: now,
      );
      expect(pools.fiveHour.lastUsedAt, isNull);
      expect(pools.week.lastUsedAt, isNull);
      expect(pools.week.count, 0);
    });
  });

  // ---------------------------------------------------------- controller

  /// Session with programmable status / use answers routed through the
  /// real ChatGateway forwarding; every call is recorded in
  /// [FakeDeviceSession.channelCalls].
  ({
    FakeDeviceSession session,
    QuotaResetController controller,
    void Function(Object? answer) setStatusAnswer,
    void Function(Object? error) setUseError,
    List<int> statusCalls,
  }) build() {
    Object? statusAnswer;
    Object? useError;
    final statusCalls = <int>[];
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: paramsOf(),
      channelHandler: (channel, method, args) async {
        switch (method) {
          case 'getCodingPlanResetStatus':
            statusCalls.add(statusCalls.length);
            if (statusAnswer is Exception) throw statusAnswer!;
            return statusAnswer;
          case 'useCodingPlanReset':
            if (useError != null) throw useError!;
            return {'ok': true};
          case 'getEntitlementSnapshot':
            return {
              'authenticated': true,
              'provider': {'id': 'prov-1', 'name': 'BigModel'},
              'remaining': {'count': 12, 'percentage': 40, 'isShow': true},
            };
        }
        return null;
      },
    );
    final controller = session.quotaResetController;
    return (
      session: session,
      controller: controller,
      setStatusAnswer: (a) => statusAnswer = a,
      setUseError: (e) => useError = e,
      statusCalls: statusCalls,
    );
  }

  Map<String, dynamic> statusFixture() => {
        'availableFiveHourResets': [
          // Relative to the active clock (mocked or real): the fixture must
          // stay unexpired forever, unlike a hardcoded 2026-09-14 timestamp.
          {'expireAt': clock.now().millisecondsSinceEpoch + 3600000},
        ],
        'availableWeekResets': [],
      };

  testWidgets('refresh parses the snapshot; scope missing disables it', (
    tester,
  ) async {
    final env = build();
    addTearDown(env.session.dispose);
    env.setStatusAnswer(statusFixture());

    // No scope injected yet: no request is issued, pools stay null.
    await env.controller.refresh();
    expect(env.statusCalls, isEmpty);
    expect(env.controller.pools, isNull);
    expect(env.session.channelCalls, isEmpty);

    env.controller.updateScope('prov-1');
    await tester.pumpAndSettle();
    await env.controller.refresh();

    expect(env.statusCalls.length, 1);
    expect(env.controller.pools?.fiveHour.count, 1);
    expect(env.controller.pools?.week.count, 0);
    expect(env.controller.scopeProviderId, 'prov-1');
    // The scope rides the forwarded RPC args.
    expect(env.session.channelCalls.first.$1, 'usage-stats');
    expect(env.session.channelCalls.first.$2, 'getCodingPlanResetStatus');
    expect(
      env.session.channelCalls.first.$3.single,
      {'preferredProviderId': 'prov-1'},
    );
  });

  testWidgets('refresh caches within the staleness window; force bypasses',
      (tester) async {
    var now = DateTime(2026, 9, 14, 12);
    final env = build();
    addTearDown(env.session.dispose);
    env.setStatusAnswer(statusFixture());
    env.controller.updateScope('prov-1');
    await tester.pumpAndSettle();

    await withClock(Clock(() => now), () async {
      await env.controller.refresh();
      await env.controller.refresh(); // within 10s → cached
      expect(env.statusCalls.length, 1);

      now = now.add(const Duration(seconds: 11));
      await env.controller.refresh(); // stale → re-fetch
      expect(env.statusCalls.length, 2);

      await env.controller.refresh(force: true); // force → re-fetch
      expect(env.statusCalls.length, 3);
    });
  });

  testWidgets('status failure keeps previous pools, clears the cache, and '
      'is retried on the next plain refresh', (tester) async {
    var now = DateTime(2026, 9, 14, 12);
    final env = build();
    addTearDown(env.session.dispose);
    env.setStatusAnswer(statusFixture());
    env.controller.updateScope('prov-1');
    await tester.pumpAndSettle();

    await withClock(Clock(() => now), () async {
      await env.controller.refresh();
      expect(env.controller.pools?.fiveHour.count, 1);

      // Past the staleness window the failing fetch actually runs.
      now = now.add(const Duration(seconds: 11));
      env.setStatusAnswer(Exception('no_bigmodel_api_key'));
      await env.controller.refresh();
      expect(env.controller.error, contains('no_bigmodel_api_key'));
      expect(env.controller.pools?.fiveHour.count, 1); // previous kept

      env.setStatusAnswer({'availableFiveHourResets': []});
      await env.controller.refresh(); // failure was not cached
      expect(env.statusCalls.length, 3);
      expect(env.controller.error, isNull);
    });
  });

  testWidgets('use success chain: optimistic processing, idempotency key, '
      'force status re-fetch and forced entitlement refresh', (tester) async {
    final env = build();
    addTearDown(env.session.dispose);
    env.setStatusAnswer(statusFixture());
    env.controller.updateScope('prov-1');
    await tester.pumpAndSettle();
    await env.controller.refresh();

    var notifyCount = 0;
    env.controller.addListener(() => notifyCount++);

    final done = env.controller.use(quotaResetTypeFiveHour);
    // Optimistic: processing flag flips before the RPC resolves.
    expect(env.controller.pools?.fiveHour.processing, isTrue);
    expect(await done, isTrue);

    expect(env.controller.pools?.fiveHour.processing, isFalse);
    expect(env.controller.error, isNull);
    expect(notifyCount, greaterThan(0));

    final useCall =
        env.session.channelCalls.firstWhere((c) => c.$2 == 'useCodingPlanReset');
    expect(useCall.$1, 'usage-stats');
    final body = useCall.$3.single as Map;
    expect(body['preferredProviderId'], 'prov-1');
    expect(body['resetType'], 'FIVE_HOUR');
    expect(body['idempotencyKey'], isNotEmpty);

    // Status confirmed with a force re-fetch after the reset.
    expect(env.statusCalls.length, 2);
    // Entitlement force-refreshed so the pill/banner flip immediately.
    final entitlementSnapshots = env.session.channelCalls
        .where((c) => c.$2 == 'getEntitlementSnapshot')
        .length;
    expect(entitlementSnapshots, 1);
  });

  testWidgets('use failure rolls processing back and reports the error',
      (tester) async {
    final env = build();
    addTearDown(env.session.dispose);
    env.setStatusAnswer(statusFixture());
    env.controller.updateScope('prov-1');
    await tester.pumpAndSettle();
    await env.controller.refresh();

    env.setUseError(Exception('boom'));
    expect(await env.controller.use(quotaResetTypeFiveHour), isFalse);

    expect(env.controller.pools?.fiveHour.processing, isFalse); // rolled back
    expect(env.controller.pools?.fiveHour.count, 1); // snapshot untouched
    expect(env.controller.error, contains('boom'));
    // No confirmation refresh after a failed use.
    expect(env.statusCalls.length, 1);
  });

  testWidgets('use is refused without scope, opportunities or an unknown '
      'pool', (tester) async {
    final env = build();
    addTearDown(env.session.dispose);
    env.setStatusAnswer(statusFixture());

    // No scope → refused, no RPC at all.
    expect(await env.controller.use(quotaResetTypeFiveHour), isFalse);
    expect(env.session.channelCalls, isEmpty);

    env.controller.updateScope('prov-1');
    await tester.pumpAndSettle();
    await env.controller.refresh();

    // Unknown pool type → refused.
    expect(await env.controller.use('NOPE'), isFalse);
    expect(
      env.session.channelCalls.where((c) => c.$2 == 'useCodingPlanReset'),
      isEmpty,
    );

    // Empty week pool → refused.
    expect(await env.controller.use(quotaResetTypeWeek), isFalse);
  });
}
