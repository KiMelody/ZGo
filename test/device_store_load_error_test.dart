// Device store — load() surfaces plugin-channel failures (empty-shell builds)
// as `loadError` instead of staying unloaded forever.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zgo/state/device_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('a throwing prefs provider reports loadError and still marks loaded',
      () async {
    final store = DeviceStore(
      prefsProvider: () async => throw PlatformException(
        code: 'channel-error',
        message: 'Unable to establish connection on channel',
      ),
    );

    await store.load();

    expect(store.loaded, isTrue);
    expect(store.loadError, isNotNull);
    expect(store.loadError, contains('channel-error'));
    expect(store.devices, isEmpty);
  });

  test('a successful retry clears loadError and restores devices', () async {
    // Seed through a healthy store first; the mock preferences backend is
    // shared across instances.
    final seed = DeviceStore();
    await seed.load();
    await seed.addUrl(
        'https://zcode.z.ai/remote/v4?sid=a&hash=h&t=1&name=Desk');

    var calls = 0;
    final store = DeviceStore(prefsProvider: () async {
      calls++;
      if (calls == 1) {
        throw PlatformException(
          code: 'channel-error',
          message: 'Unable to establish connection on channel',
        );
      }
      return SharedPreferences.getInstance();
    });

    await store.load();
    expect(store.loaded, isTrue);
    expect(store.loadError, isNotNull);
    expect(store.devices, isEmpty);

    await store.load();
    expect(store.loaded, isTrue);
    expect(store.loadError, isNull);
    expect(store.devices.single.label, 'Desk');
  });
}
