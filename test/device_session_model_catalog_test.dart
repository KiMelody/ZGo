import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/connection_params.dart';

import 'helpers/fake_device_session.dart';

FakeDeviceSession sessionWithVersion(
  String appVersion,
  Future<dynamic> Function(String channel, String method, List<Object?> args)
      channelHandler,
) {
  final params = RemoteConnectionParams.parse(
    'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1'
    '&name=songsong&app_version=$appVersion',
  )!;
  return FakeDeviceSession(
    deviceId: 'd1',
    params: params,
    channelHandler: channelHandler,
  );
}

void main() {
  group('DeviceSession.modelProviderCatalog desktop-version source gate', () {
    test('≥3.14 pulls the catalog from model-selection.getView', () async {
      final getViewCalls = <List<Object?>>[];
      final getAllCalls = <String>[];
      final session = sessionWithVersion('3.14.0',
          (channel, method, args) async {
        if (channel == 'model-selection' && method == 'getView') {
          getViewCalls.add(args);
          return {
            'revision': 3,
            'providers': [
              {
                'providerId': 'account:zai',
                'providerName': 'Z.ai',
                'models': [
                  {
                    'modelId': 'GLM-5.3',
                    'config': {'enabled': true},
                  },
                ],
              },
            ],
          };
        }
        getAllCalls.add('$channel.$method');
        return null;
      });

      final catalog = await session.modelProviderCatalog();

      // Mapped through to the legacy catalog shape the sheet consumes.
      expect(catalog.single['id'], 'account:zai');
      expect(catalog.single['name'], 'Z.ai');
      expect(catalog.single['models'], [
        {'id': 'GLM-5.3'},
      ]);
      expect(getViewCalls, hasLength(1));
      expect(getViewCalls.single, isEmpty); // parameter-less
      expect(getAllCalls, isEmpty); // the removed channel is never touched

      // Session-lifetime cache: the second open reuses the verdict.
      await session.modelProviderCatalog();
      expect(getViewCalls, hasLength(1));
    });

    test('<3.14 keeps the legacy model-provider.getAll source', () async {
      final getAllCalls = <String>[];
      final selectionCalls = <String>[];
      final session = sessionWithVersion('3.12.3',
          (channel, method, args) async {
        if (channel == Channels.modelSelection) {
          selectionCalls.add(method);
          return null;
        }
        if (channel == Channels.modelProvider && method == 'getAll') {
          getAllCalls.add(method);
          return [
            {'id': 'builtin:zai', 'name': 'BigModel', 'enabled': true},
            {'id': 'custom:x', 'name': 'Off', 'enabled': false},
          ];
        }
        return null;
      });

      final catalog = await session.modelProviderCatalog();

      // Legacy branch untouched: raw provider maps, enabled!=false filter.
      expect(catalog, hasLength(1));
      expect(catalog.single['id'], 'builtin:zai');
      expect(getAllCalls, hasLength(1));
      expect(selectionCalls, isEmpty); // the 3.14 channel is never probed
    });

    test('getView channel failure → empty catalog, uncached (retry next open)',
        () async {
      var getViewCalls = 0;
      var fail = true;
      final session = sessionWithVersion('3.14.0',
          (channel, method, args) async {
        if (channel == 'model-selection' && method == 'getView') {
          getViewCalls += 1;
          if (fail) {
            throw ChannelRpcError(
                "Channel name '$channel' timed out after 1000ms", null);
          }
          return {
            'providers': [
              {'providerId': 'p1', 'models': []},
            ],
          };
        }
        return null;
      });

      expect(await session.modelProviderCatalog(), isEmpty);
      expect(getViewCalls, 1);

      // Failure stays uncached: the next sheet open retries the RPC.
      fail = false;
      final catalog = await session.modelProviderCatalog();
      expect(catalog.single['id'], 'p1');
      expect(getViewCalls, 2);
    });
  });
}
