import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:zgo/plan/plan_api.dart';
import 'package:zgo/plan/remote_device_api.dart';

/// Live-shaped directory row (probe 2026-10-22: `meta` carries the desktop
/// display name / platform / app version).
Map<String, dynamic> row({
  String sid = 'sid-1',
  String mid = 'mid-1',
  Object? online = true,
  Object? meta = const {
    'name': 'Melody',
    'platform': 'win32',
    'version': '3.16.2',
  },
}) =>
    {
      'device_sid': sid,
      'device_mid': mid,
      'online': online,
      'created_at': 1758000000,
      'meta': meta,
    };

http.Response jsonRes(Object body, {int status = 200}) =>
    http.Response(jsonEncode(body), status, headers: {
      'content-type': 'application/json',
    });

void main() {
  group('parseRemoteDevices', () {
    test('parses the live-shaped rows including meta', () {
      final entries = parseRemoteDevices([
        row(),
        row(
          sid: 'sid-2',
          mid: 'mid-2',
          online: false,
          meta: {'name': 'Studio', 'platform': 'darwin', 'version': '3.15.3'},
        ),
      ]);

      expect(entries, hasLength(2));
      expect(entries.first.deviceSid, 'sid-1');
      expect(entries.first.deviceMid, 'mid-1');
      expect(entries.first.online, isTrue);
      expect(entries.first.name, 'Melody');
      expect(entries.first.platform, 'win32');
      expect(entries.first.version, '3.16.2');
      expect(entries.first.createdAt,
          DateTime.fromMillisecondsSinceEpoch(1758000000 * 1000));
      expect(entries.last.online, isFalse);
      expect(entries.last.name, 'Studio');
    });

    test('empty list parses to empty', () {
      expect(parseRemoteDevices([]), isEmpty);
    });

    test('non-list payload is a hard shape failure', () {
      expect(() => parseRemoteDevices({'devices': const []}),
          throwsA(isA<PlanApiError>()));
      expect(() => parseRemoteDevices(null), throwsA(isA<PlanApiError>()));
    });

    test('skips rows without a usable sid/mid and non-map rows', () {
      final entries = parseRemoteDevices([
        row(mid: ''),
        row(sid: ''),
        'junk',
        row(sid: 'sid-ok', mid: 'mid-ok'),
      ]);
      expect(entries.map((e) => e.deviceMid), ['mid-ok']);
    });

    test('meta shape drift degrades to empty strings, online to false', () {
      final entries = parseRemoteDevices([
        row(online: 'yes', meta: 'bad'),
      ]);
      expect(entries.single.online, isFalse);
      expect(entries.single.name, '');
      expect(entries.single.platform, '');
      expect(entries.single.version, '');
    });
  });

  group('RemoteDeviceApi.list', () {
    test('sends bearer to the directory endpoint and parses entries',
        () async {
      http.Request? captured;
      final api = RemoteDeviceApi(client: MockClient((req) async {
        captured = req;
        return jsonRes({
          'code': 0,
          'msg': '',
          'data': [row()],
        });
      }));

      final entries = await api.list(token: 'tok');

      expect(captured, isNotNull);
      expect(captured!.method, 'GET');
      expect(captured!.url.toString(), '$kPlanBaseUrl/api/v1/remote/device');
      expect(captured!.headers['authorization'], 'Bearer tok');
      expect(captured!.headers.containsKey('x-device-mid'), isFalse);
      expect(entries.single.deviceMid, 'mid-1');
    });

    test('empty data list is valid (account with no devices)', () async {
      final api = RemoteDeviceApi(
        client: MockClient((req) async => jsonRes({'code': 0, 'data': []})),
      );
      expect(await api.list(token: 'tok'), isEmpty);
    });

    test('401 maps to PlanAuthExpired', () async {
      final api = RemoteDeviceApi(
          client: MockClient((req) async => jsonRes({'code': 401}, status: 401)));
      await expectLater(
        api.list(token: 'tok'),
        throwsA(isA<PlanAuthExpired>()),
      );
    });

    test('403 maps to PlanAuthExpired', () async {
      final api = RemoteDeviceApi(
          client: MockClient((req) async => jsonRes({'code': 403}, status: 403)));
      await expectLater(
        api.list(token: 'tok'),
        throwsA(isA<PlanAuthExpired>()),
      );
    });

    test('non-zero envelope code maps to PlanApiError', () async {
      final api = RemoteDeviceApi(
        client: MockClient((req) async => jsonRes({
          'code': 5,
          'msg': 'server busy',
          'data': null,
        })),
      );
      await expectLater(
        api.list(token: 'tok'),
        throwsA(isA<PlanApiError>()
            .having((e) => e.code, 'code', 5)
            .having((e) => e.message, 'message', 'server busy')),
      );
    });

    test('unusable data shape throws PlanApiError', () async {
      final api = RemoteDeviceApi(
        client: MockClient((req) async => jsonRes({
          'code': 0,
          'data': {'devices': []},
        })),
      );
      await expectLater(
        api.list(token: 'tok'),
        throwsA(isA<PlanApiError>()),
      );
    });

    test('non-JSON body maps to PlanApiError, not a crash', () async {
      final api = RemoteDeviceApi(
          client: MockClient((req) async => http.Response('not-json', 200)));
      await expectLater(
        api.list(token: 'tok'),
        throwsA(isA<PlanApiError>()),
      );
    });

    test('transport failures map to PlanNetworkError', () async {
      final api = RemoteDeviceApi(client: MockClient((req) async {
        throw http.ClientException('offline');
      }));
      await expectLater(
        api.list(token: 'tok'),
        throwsA(isA<PlanNetworkError>()),
      );
    });

    test('timeouts map to PlanNetworkError', () async {
      final api = RemoteDeviceApi(client: MockClient((req) async {
        throw TimeoutException('slow');
      }));
      await expectLater(
        api.list(token: 'tok'),
        throwsA(isA<PlanNetworkError>()),
      );
    });

    test('error messages never embed the token', () async {
      const token = 'secret-jwt-value';
      final api = RemoteDeviceApi(
        client: MockClient((req) async => jsonRes({
          'code': 5,
          'msg': 'server busy',
        })),
      );
      try {
        await api.list(token: token);
        fail('expected PlanApiError');
      } on PlanApiException catch (e) {
        expect(e.toString(), isNot(contains(token)));
      }
    });
  });

  test('remoteUrl carries the V2 share-link params from the entry', () {
    final url = parseRemoteDevices([row()]).single.remoteUrl;
    final uri = Uri.parse(url.toString());

    expect(uri.scheme, 'https');
    expect(uri.host, 'zcode.z.ai');
    expect(uri.path, '/remote/v4');
    expect(uri.queryParameters, {
      'sid': 'sid-1',
      'mid': 'mid-1',
      'name': 'Melody',
      'app_version': '3.16.2',
    });
  });
}
