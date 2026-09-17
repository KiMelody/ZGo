import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/protocol/connection_params.dart';
import 'package:zlinker/state/entitlement_poller.dart';
import 'package:zlinker/state/quota_reset.dart';

import '../helpers/fake_device_session.dart';

/// The official entitlement / reset semantics live in exactly one place —
/// the [EntitlementView] projection. These tests are the migrated rule
/// assertions of the former per-surface widget tests (usage page reset
/// card / summary line, chat usage sheet, reset dialog); the widget files
/// keep one wiring smoke each.
///
/// Fixtures use only the live-probed snapshot structure
/// (internal notes).
void main() {
  EntitlementView view(Map<String, dynamic> data) =>
      EntitlementView(phase: EntitlementPhase.ok, data: data);

  Map<String, dynamic> payload(List<Object?> limits) => {
        'authenticated': true,
        'provider': {'id': 'prov-1', 'name': 'BigModel'},
        'quota': {'level': 'pro', 'limits': limits},
      };

  /// One entitlement `quota.limits` row (probe shape).
  Map<String, dynamic> limitRow({
    String type = 'TOKENS_LIMIT',
    Object? unit = 3,
    Object? number = 5,
    Object? percentage = 40,
    int? nextResetTime,
  }) =>
      {
        'type': type,
        'unit': unit,
        if (number != null) 'number': number,
        if (percentage != null) 'percentage': percentage,
        if (nextResetTime != null) 'nextResetTime': nextResetTime,
      };

  /// 5-hour window row + weekly window row (a plan with both tiers).
  List<Map<String, dynamic>> bothRows({Object? fiveHourPercentage = 40}) => [
        limitRow(percentage: fiveHourPercentage),
        limitRow(unit: 6, number: null, percentage: 20),
      ];

  QuotaResetPool pool({int count = 1, int? earliestExpireAt}) =>
      QuotaResetPool(count: count, earliestExpireAt: earliestExpireAt);

  // ------------------------------------------------------------- limitFor

  group('limitFor', () {
    test('exact type + unit + number match', () {
      final v = view(payload([
        limitRow(),
        limitRow(type: 'TIME_LIMIT', unit: 5, number: 1),
      ]));
      final limit = v.limitFor('TOKENS_LIMIT', unit: 3, number: 5);
      expect(limit, isNotNull);
      expect(limit!.raw['percentage'], 40);
      // A different window row does not match the 5h query.
      expect(v.limitFor('TIME_LIMIT', unit: 5, number: 1), isNotNull);
      expect(v.limitFor('TIME_LIMIT', unit: 3, number: 5), isNull);
    });

    test('weekly row matches on unit alone (official MF constrains unit)',
        () {
      final v = view(payload([limitRow(unit: 6, number: null)]));
      expect(v.limitFor('TOKENS_LIMIT', unit: 6), isNotNull);
    });

    test('absent / mistyped rows and quotas degrade to null', () {
      expect(
        view(payload([limitRow(number: 1)]))
            .limitFor('TOKENS_LIMIT', unit: 3, number: 5),
        isNull,
      ); // wrong number
      expect(
        view(payload([limitRow(type: 'CREDIT_LIMIT')]))
            .limitFor('TOKENS_LIMIT', unit: 3, number: 5),
        isNull,
      ); // alias counts for poolVisible, not for an exact MF query
      expect(
        const EntitlementView(phase: EntitlementPhase.ok).limitFor(
          'TOKENS_LIMIT',
          unit: 3,
          number: 5,
        ),
        isNull,
      ); // no data at all
      expect(
        view({
          'quota': {'limits': 'not-a-list'},
        }).limitFor('TOKENS_LIMIT'),
        isNull,
      );
      // Garbage entries are skipped, the real row still matches.
      final mixed = view(payload([
        'garbage',
        42,
        limitRow(),
      ]));
      expect(mixed.limitFor('TOKENS_LIMIT', unit: 3, number: 5), isNotNull);
    });
  });

  // ----------------------------------------------------- remainingPercent

  group('remainingPercent', () {
    test('official PF: clamp(100 - percentage)', () {
      final v = view(payload([limitRow(percentage: 40)]));
      final limit = v.limitFor('TOKENS_LIMIT', unit: 3, number: 5);
      expect(v.remainingPercent(limit), 60.0);

      final full = Limit(limitRow(percentage: 150)); // over-driven → 0
      expect(v.remainingPercent(full), 0.0);
    });

    test('null limit or unreadable percentage answers null', () {
      final v = view(payload(const []));
      expect(v.remainingPercent(null), isNull);
      expect(
        v.remainingPercent(Limit(limitRow(percentage: null))),
        isNull,
      );
      expect(
        v.remainingPercent(Limit(limitRow(percentage: 'oops'))),
        isNull,
      );
    });
  });

  // -------------------------------------------------- resetScopeProviderId

  group('resetScopeProviderId', () {
    test('reads provider.id from the ok snapshot', () {
      expect(view(payload(const [])).resetScopeProviderId, 'prov-1');
    });

    test('missing / mistyped / empty ids disable the feature', () {
      expect(
        view({
          'provider': {'name': 'BigModel'},
        }).resetScopeProviderId,
        isNull,
      ); // no id (the degraded usage-page fixture)
      expect(
        view({
          'provider': {'id': ''},
        }).resetScopeProviderId,
        isNull,
      );
      expect(
        view({
          'provider': 'not-a-map',
        }).resetScopeProviderId,
        isNull,
      );
      expect(
        const EntitlementView(phase: EntitlementPhase.ok)
            .resetScopeProviderId,
        isNull,
      );
    });
  });

  // ------------------------------------------------------ resettablePools

  group('resettablePools', () {
    test('credits both pools when the plan exposes both window rows', () {
      final v = view(payload(bothRows()));
      final pools = QuotaResetPools(
        fiveHour: pool(count: 2),
        week: pool(count: 1),
        hasData: true,
      );
      final resettable = v.resettablePools(pools);
      expect(resettable.map((r) => r.type).toSet(),
          {quotaResetTypeFiveHour, quotaResetTypeWeek});
    });

    test('≡ usage page / chat sheet: a V1 plan (no weekly window row) never '
        'credits the weekly coupon the account still holds', () {
      final v = view(payload([limitRow()])); // 5h row only
      final pools = QuotaResetPools(
        fiveHour: pool(count: 1),
        week: pool(count: 1), // the unexpired weekly coupon
        hasData: true,
      );
      final resettable = v.resettablePools(pools);
      expect(resettable.map((r) => r.type), [quotaResetTypeFiveHour]);
    });

    test('≡ both pools invisible → empty: an untouched window (0% used, '
        'official FF "quotaFull") hides even with coupons', () {
      final v = view(payload([limitRow(percentage: 0)]));
      final pools = QuotaResetPools(
        fiveHour: pool(count: 1),
        week: pool(count: 1),
        hasData: true,
      );
      expect(v.resettablePools(pools), isEmpty);
    });

    test('an exhausted window (100% used) stays resettable', () {
      final v = view(payload([limitRow(percentage: 100)]));
      final pools = QuotaResetPools(fiveHour: pool(count: 1), hasData: true);
      expect(
        v.resettablePools(pools).map((r) => r.type),
        [quotaResetTypeFiveHour],
      );
    });

    test('CREDIT_LIMIT counts as the token-class row (official alias set)',
        () {
      final v = view(payload([limitRow(type: 'CREDIT_LIMIT')]));
      final pools = QuotaResetPools(fiveHour: pool(count: 1), hasData: true);
      expect(v.resettablePools(pools), isNotEmpty);
    });

    test('processing pools survive (official optimistic exception)', () {
      final v = view(payload([limitRow(percentage: 0)]));
      final pools = QuotaResetPools(
        fiveHour: pool(count: 0).withProcessing(true),
        week: pool(count: 0),
        hasData: true,
      );
      expect(
        v.resettablePools(pools).map((r) => r.type),
        [quotaResetTypeFiveHour],
      );
    });

    test('null pools / absent quota credit nothing', () {
      final v = view(payload(bothRows()));
      expect(v.resettablePools(null), isEmpty);
      expect(
        const EntitlementView(phase: EntitlementPhase.ok)
            .resettablePools(QuotaResetPools(fiveHour: pool(), week: pool())),
        isEmpty,
      );
    });
  });

  // -------------------------------------------------- earliestResetExpiry

  group('earliestResetExpiry', () {
    final in1h = clock.now().millisecondsSinceEpoch + 3600000;
    final in10m = clock.now().millisecondsSinceEpoch + 600000;

    test('≡ summary reset time: weekly-only coupons never drive it', () {
      // The 5h pool is empty and the weekly coupon — invisible on this
      // V1 plan — expires sooner: nothing usable → null.
      final v = view(payload([limitRow()]));
      final pools = QuotaResetPools(
        fiveHour: pool(count: 0),
        week: pool(count: 1, earliestExpireAt: in10m),
        hasData: true,
      );
      expect(v.earliestResetExpiry(pools), isNull);
    });

    test('≡ the visible 5h card wins over a sooner-but-invisible weekly '
        'coupon', () {
      final v = view(payload([limitRow()]));
      final pools = QuotaResetPools(
        fiveHour: pool(count: 1, earliestExpireAt: in1h),
        week: pool(count: 1, earliestExpireAt: in10m), // sooner, invisible
        hasData: true,
      );
      expect(
        v.earliestResetExpiry(pools),
        DateTime.fromMillisecondsSinceEpoch(in1h),
      );
    });

    test('both visible → the earliest of the two wins', () {
      final v = view(payload(bothRows()));
      final pools = QuotaResetPools(
        fiveHour: pool(count: 1, earliestExpireAt: in1h),
        week: pool(count: 1, earliestExpireAt: in10m),
        hasData: true,
      );
      expect(
        v.earliestResetExpiry(pools),
        DateTime.fromMillisecondsSinceEpoch(in10m),
      );
    });

    test('null pools / no opportunities → null', () {
      final v = view(payload(bothRows()));
      expect(v.earliestResetExpiry(null), isNull);
      expect(
        v.earliestResetExpiry(
          QuotaResetPools(fiveHour: pool(count: 0), week: pool(count: 0)),
        ),
        isNull,
      );
    });
  });

  // --------------------------------------------------------- fmtResetClock

  group('fmtResetClock', () {
    test('within 24h renders HH:mm', () {
      final at = DateTime.now().add(const Duration(hours: 2));
      final expected =
          '${at.hour.toString().padLeft(2, '0')}:'
          '${at.minute.toString().padLeft(2, '0')}';
      expect(EntitlementView.fmtResetClock(at), expected);
    });

    test('beyond 24h renders MM-dd HH:mm', () {
      final at = DateTime.now().subtract(const Duration(days: 3));
      final expected =
          '${at.month.toString().padLeft(2, '0')}-'
          '${at.day.toString().padLeft(2, '0')} '
          '${at.hour.toString().padLeft(2, '0')}:'
          '${at.minute.toString().padLeft(2, '0')}';
      expect(EntitlementView.fmtResetClock(at), expected);
    });
  });

  // --------------------------------------------------- session scope sink

  /// Session with a programmable entitlement / status answer routed
  /// through the real forwarding; every call lands in [channelCalls].
  FakeDeviceSession sessionOf(
    Map<String, dynamic> entitlement, {
    Object? statusAnswer,
  }) =>
      FakeDeviceSession(
        deviceId: 'd1',
        params: RemoteConnectionParams.parse(
          'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=123&mid=m&name=test',
        )!,
        channelHandler: (channel, method, args) async {
          switch (method) {
            case 'getEntitlementSnapshot':
              return entitlement;
            case 'getCodingPlanResetStatus':
              if (statusAnswer is Exception) throw statusAnswer;
              return statusAnswer;
          }
          return null;
        },
      );

  Map<String, dynamic> entitledPayload() => {
        'authenticated': true,
        'provider': {'id': 'prov-1', 'name': 'BigModel'},
        'quota': {
          'limits': [
            {'type': 'TOKENS_LIMIT', 'unit': 3, 'number': 5, 'percentage': 40},
          ],
        },
      };

  testWidgets('entitlementSnapshot injects the reset scope into the session '
      'controller (≡ the former per-surface UI injection)', (tester) async {
    final session = sessionOf(
      entitledPayload(),
      statusAnswer: {
        'availableFiveHourResets': [
          {'expireAt': clock.now().millisecondsSinceEpoch + 3600000},
        ],
        'availableWeekResets': <Map<String, dynamic>>[],
      },
    );
    addTearDown(session.dispose);

    await session.entitlementSnapshot();
    expect(session.quotaResetController.scopeProviderId, 'prov-1');

    // Non-null pools path: a plain refresh now fetches with the scope.
    await session.quotaResetController.refresh();
    expect(session.quotaResetController.pools?.fiveHour.count, 1);
    // The scope rides the forwarded RPC args.
    final statusCall = session.channelCalls
        .firstWhere((c) => c.$2 == 'getCodingPlanResetStatus');
    expect(statusCall.$3.single, {'preferredProviderId': 'prov-1'});
  });

  testWidgets('a snapshot without a usable provider id leaves the scope '
      'disabled (refresh issues nothing, pools stay null)', (tester) async {
    // Provider carries no id (the degraded usage-page fixture).
    final session = sessionOf({
      'authenticated': true,
      'provider': {'name': 'BigModel'},
    });
    addTearDown(session.dispose);

    await session.entitlementSnapshot();
    expect(session.quotaResetController.scopeProviderId, isNull);

    await session.quotaResetController.refresh();
    expect(session.quotaResetController.pools, isNull);
    expect(
      session.channelCalls.where((c) => c.$2 == 'getCodingPlanResetStatus'),
      isEmpty,
    );
  });
}
