import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/plan/plan_models.dart';

/// Wire-shaped fixture from the 2026-10-11 live probe of
/// `billing/balance` (research/billing-api-wire-facts.md), sanitized.
/// Numbers: the 300,000,000-token bucket measured that day.
Map<String, dynamic> balanceFixture() => {
      'code': 0,
      'msg': '',
      'data': {
        'server_time': 1791763200000,
        'plans': [
          {
            'user_plan_id': 'up-1',
            'plan_id': 'weekend-build',
            'name': 'ZCode Weekend Build',
            'description': '',
            'priority': 1,
            'status': 'active',
            'starts_at': 1757836800,
            'ends_at': 1791849600,
            'entitlements': [
              {
                'entitlement_id': 'ent-1',
                'show_name': 'GLM-5.3-Flash',
                'meter': 'token',
                'unit_type': 'token',
                'capabilities': ['model:glm-5.3-flash'],
                'grant_units': 300000000,
                'period': 'one_time',
                'priority': 1,
                'effective_at': 1757836800,
              },
            ],
          },
        ],
        'balances': [
          {
            'bucket_id': 'bk-1',
            'user_plan_id': 'up-1',
            'plan_id': 'weekend-build',
            'entitlement_id': 'ent-1',
            'show_name': 'GLM-5.3-Flash',
            'meter': 'token',
            'unit_type': 'token',
            'capabilities': ['model:glm-5.3-flash'],
            'priority': 1,
            'plan_priority': 1,
            'entitlement_priority': 1,
            'total_units': 300000000,
            'used_units': 85095369,
            'remaining_units': 214904631,
            'available_units': 214904631,
            'period_start': 1757836800,
            'period_end': 1791849600,
            // Seconds epoch → 2026-10-12 UTC.
            'expires_at': 1791763200,
          },
          {
            // Minimal bucket: values as numeric strings, ms epoch.
            'entitlement_id': 'ent-2',
            'show_name': 'GLM Coding Plan',
            'capabilities': ['model:glm-5.3', 'tool:web-search'],
            'total_units': '1000000000',
            'used_units': 123,
            'remaining_units': '999999877',
            'expires_at': 1791763200000,
          },
        ],
      },
    };

void main() {
  group('envelope', () {
    test('code and data are read from a well-formed envelope', () {
      final body = balanceFixture();
      expect(envelopeCode(body), 0);
      expect(envelopeData(body), isA<Map>());
    });

    test('non-zero code surfaces (API layer classifies it)', () {
      expect(
          envelopeCode({
            'code': 3001,
            'msg': 'parameter error',
          }),
          3001);
    });

    test('malformed envelopes yield a null code, never throw', () {
      expect(envelopeCode(null), isNull);
      expect(envelopeCode('nope'), isNull);
      expect(envelopeCode({
        'code': '0',
      }), isNull);
      expect(envelopeCode({
        'msg': 'no code',
      }), isNull);
      expect(envelopeData(null), isNull);
      expect(envelopeData({
        'code': 0,
      }), isNull);
    });
  });

  group('parseBalanceSnapshot (300M-bucket live values)', () {
    final fetched = DateTime.utc(2026, 10, 11, 8);
    late PlanSnapshot snap;

    setUp(() {
      snap = parseBalanceSnapshot(
        envelopeData(balanceFixture()),
        fetchedAt: fetched,
      );
    });

    test('fetchedAt is carried through', () {
      expect(snap.fetchedAt, fetched);
    });

    test('both buckets are parsed in wire order', () {
      expect(snap.buckets, hasLength(2));
      expect(snap.buckets[0].showName, 'GLM-5.3-Flash');
      expect(snap.buckets[1].showName, 'GLM Coding Plan');
    });

    test('the measured 300M bucket parses exactly', () {
      final b = snap.buckets[0];
      expect(b.entitlementId, 'ent-1');
      expect(b.total, 300000000);
      expect(b.used, 85095369);
      expect(b.remaining, 214904631);
      expect(b.available, 214904631);
      // ~71.6% remaining on the day of the probe.
      expect(b.remaining! / b.total!, closeTo(0.7163, 0.001));
    });

    test('seconds and milliseconds epochs land on the same date', () {
      final expected = DateTime.fromMillisecondsSinceEpoch(
        1791763200 * 1000,
      );
      expect(snap.buckets[0].periodEnd, expected);
      expect(snap.buckets[1].periodEnd, expected);
    });

    test('capabilities keep model:-prefixed items, stripped', () {
      expect(snap.buckets[0].modelCapabilities, ['glm-5.3-flash']);
      // Non-model capabilities are dropped.
      expect(snap.buckets[1].modelCapabilities, ['glm-5.3']);
    });

    test('numeric strings are accepted, absent fields default sanely', () {
      final b = snap.buckets[1];
      expect(b.entitlementId, 'ent-2');
      expect(b.total, 1000000000);
      expect(b.used, 123);
      expect(b.remaining, 999999877);
      expect(b.available, isNull); // absent in the minimal bucket
    });
  });

  group('parseBalanceSnapshot defensive shapes', () {
    PlanSnapshot parse(dynamic data) =>
        parseBalanceSnapshot(data, fetchedAt: DateTime.utc(2026));

    test('null / wrong-type data → empty snapshot, no throw', () {
      expect(parse(null).buckets, isEmpty);
      expect(parse('nope').buckets, isEmpty);
      expect(parse(42).buckets, isEmpty);
    });

    test('missing / wrong-type balances → empty snapshot', () {
      expect(parse({
        'plans': [],
      }).buckets, isEmpty);
      expect(parse({
        'balances': 'gone',
      }).buckets, isEmpty);
      expect(parse({
        'balances': [null, 1, 'x'],
      }).buckets, isEmpty);
    });

    test('non-map buckets are skipped, siblings kept', () {
      final snap = parse({
        'balances': [
          'garbage',
          {
            'show_name': 'kept',
            'remaining_units': 5,
          },
        ],
      });
      expect(snap.buckets, hasLength(1));
      expect(snap.buckets[0].showName, 'kept');
    });

    test('wrong-typed numerics become null, not guesses', () {
      final snap = parse({
        'balances': [
          {
            'total_units': true,
            'used_units': [1],
            'remaining_units': {'n': 1},
            'expires_at': 'soon',
          },
        ],
      });
      final b = snap.buckets.single;
      expect(b.total, isNull);
      expect(b.used, isNull);
      expect(b.remaining, isNull);
      expect(b.available, isNull);
      expect(b.periodEnd, isNull);
      expect(b.modelCapabilities, isEmpty);
    });

    test('period_end backs expires_at up', () {
      final snap = parse({
        'balances': [
          {
            'period_end': 1791763200,
          },
        ],
      });
      expect(snap.buckets.single.periodEnd, isNotNull);
    });
  });

  group('parsePlanDefinitions', () {
    test('parses id / name / status', () {
      final plans = parsePlanDefinitions(envelopeData(balanceFixture()));
      expect(plans, hasLength(1));
      expect(plans.single.id, 'weekend-build');
      expect(plans.single.name, 'ZCode Weekend Build');
      expect(plans.single.status, 'active');
    });

    test('bad shapes degrade to an empty list', () {
      expect(parsePlanDefinitions(null), isEmpty);
      expect(parsePlanDefinitions({
        'plans': null,
      }), isEmpty);
      expect(parsePlanDefinitions({
        'plans': [7, 'x', null],
      }), isEmpty);
      expect(parsePlanDefinitions({
        'plans': [
          {'name': 9},
        ],
      }).single.name, isEmpty);
    });
  });
}
