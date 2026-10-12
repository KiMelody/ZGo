import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:zgo/plan/plan_api.dart';

/// Minimal 200 body carrying the live-shaped balance data.
Map<String, dynamic> okBody() => {
      'code': 0,
      'msg': '',
      'data': {
        'balances': [
          {
            'entitlement_id': 'ent-1',
            'show_name': 'GLM-5.3-Flash',
            'total_units': 300000000,
            'used_units': 85095369,
            'remaining_units': 214904631,
          },
        ],
      },
    };

http.Response jsonRes(Object body, {int status = 200}) =>
    http.Response(jsonEncode(body), status, headers: {
      'content-type': 'application/json',
    });

void main() {
  group('fetchBalance', () {
    test('sends bearer + device-mid headers and app_version, parses buckets',
        () async {
      http.Request? captured;
      final api = PlanApi(client: MockClient((req) async {
        captured = req;
        return jsonRes(okBody());
      }));

      final snap = await api.fetchBalance(token: 'tok', deviceMid: 'mid-1');

      expect(captured, isNotNull);
      expect(captured!.method, 'GET');
      expect(
        captured!.url.toString(),
        '$kPlanBaseUrl/api/v1/zcode-plan/billing/balance?app_version=$kPlanAppVersion',
      );
      expect(captured!.headers['authorization'], 'Bearer tok');
      expect(captured!.headers['x-device-mid'], 'mid-1');
      expect(snap.buckets, hasLength(1));
      expect(snap.buckets.single.remaining, 214904631);
    });

    test('401 maps to PlanAuthExpired', () async {
      final api = PlanApi(
          client: MockClient((req) async => jsonRes({'code': 401}, status: 401)));
      await expectLater(
        api.fetchBalance(token: 'tok', deviceMid: 'mid'),
        throwsA(isA<PlanAuthExpired>()),
      );
    });

    test('403 maps to PlanAuthExpired (desktop rv classifies both)', () async {
      final api = PlanApi(
          client: MockClient((req) async => jsonRes({'code': 403}, status: 403)));
      await expectLater(
        api.fetchBalance(token: 'tok', deviceMid: 'mid'),
        throwsA(isA<PlanAuthExpired>()),
      );
    });

    test('400 envelope error (missing device header) maps to PlanApiError',
        () async {
      final api = PlanApi(
          client: MockClient((req) async => jsonRes({
                'code': 3001,
                'msg': 'parameter error',
              }, status: 400)));
      await expectLater(
        api.fetchBalance(token: 'tok', deviceMid: 'mid'),
        throwsA(isA<PlanApiError>()
            .having((e) => e.code, 'code', 3001)
            .having((e) => e.message, 'message', 'parameter error')),
      );
    });

    test('200 with non-zero envelope code maps to PlanApiError', () async {
      final api = PlanApi(
          client: MockClient((req) async => jsonRes({
                'code': 5,
                'msg': 'server busy',
              })));
      await expectLater(
        api.fetchBalance(token: 'tok', deviceMid: 'mid'),
        throwsA(isA<PlanApiError>()
            .having((e) => e.code, 'code', 5)
            .having((e) => e.message, 'message', 'server busy')),
      );
    });

    test('non-JSON body maps to PlanApiError, not a crash', () async {
      final api = PlanApi(
          client: MockClient((req) async => http.Response('not-json', 200)));
      await expectLater(
        api.fetchBalance(token: 'tok', deviceMid: 'mid'),
        throwsA(isA<PlanApiError>()),
      );
    });

    test('HTTP 500 without envelope maps to PlanApiError', () async {
      final api = PlanApi(client: MockClient((req) async =>
          http.Response('internal', 500)));
      await expectLater(
        api.fetchBalance(token: 'tok', deviceMid: 'mid'),
        throwsA(isA<PlanApiError>().having((e) => e.code, 'code', isNull)),
      );
    });

    test('transport failures map to PlanNetworkError', () async {
      final api = PlanApi(client: MockClient((req) async {
        throw http.ClientException('offline');
      }));
      await expectLater(
        api.fetchBalance(token: 'tok', deviceMid: 'mid'),
        throwsA(isA<PlanNetworkError>()),
      );
    });

    test('timeouts map to PlanNetworkError', () async {
      final api = PlanApi(client: MockClient((req) async {
        throw TimeoutException('slow');
      }));
      await expectLater(
        api.fetchBalance(token: 'tok', deviceMid: 'mid'),
        throwsA(isA<PlanNetworkError>()),
      );
    });
  });

  group('fetchCurrent', () {
    test('omits x-device-mid, sends bearer, parses plan definitions',
        () async {
      http.Request? captured;
      final api = PlanApi(client: MockClient((req) async {
        captured = req;
        return jsonRes({
          'code': 0,
          'msg': '',
          'data': {
            'plans': [
              {
                'plan_id': 'weekend-build',
                'name': 'ZCode Weekend Build',
                'status': 'active',
              },
            ],
          },
        });
      }));

      final plans = await api.fetchCurrent(token: 'tok');

      expect(captured!.url.path,
          '/api/v1/zcode-plan/billing/current');
      expect(captured!.url.queryParameters['app_version'], kPlanAppVersion);
      expect(captured!.headers['authorization'], 'Bearer tok');
      expect(captured!.headers.containsKey('x-device-mid'), isFalse);
      expect(plans.single.name, 'ZCode Weekend Build');
    });

    test('401 maps to PlanAuthExpired', () async {
      final api = PlanApi(client:
          MockClient((req) async => jsonRes({'code': 401}, status: 401)));
      await expectLater(
        api.fetchCurrent(token: 'tok'),
        throwsA(isA<PlanAuthExpired>()),
      );
    });
  });

  test('error messages never embed the token', () async {
    const token = 'secret-jwt-value';
    final api = PlanApi(
        client: MockClient((req) async =>
            jsonRes({'code': 3001, 'msg': 'parameter error'}, status: 400)));
    try {
      await api.fetchBalance(token: token, deviceMid: 'mid');
      fail('expected PlanApiError');
    } on PlanApiException catch (e) {
      expect(e.toString(), isNot(contains(token)));
    }
  });
}
