import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zlinker/state/device_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Device.useCount', () {
    test('touch increments useCount and sets lastUsedAt', () async {
      final store = DeviceStore();
      await store.load();
      final d = await store.addUrl('https://zcode.z.ai/remote/v4?sid=a&hash=b&t=1');
      expect(store.devices.first.useCount, 0);

      await store.touch(d.id);
      await store.touch(d.id);
      expect(store.devices.first.useCount, 2);
      expect(store.devices.first.lastUsedAt, isNotNull);
    });

    test('old JSON without useCount defaults to 0', () {
      final d = Device.fromJson({
        'id': 'x',
        'label': 'legacy',
        'url': 'https://zcode.z.ai/remote/v4?sid=a&hash=b&t=1',
        'addedAt': 123,
        'lastUsedAt': 456,
        // no useCount key
      });
      expect(d.useCount, 0);
      expect(d.lastUsedAt, 456);
    });

    test('useCount survives export/import round-trip', () async {
      final a = DeviceStore();
      await a.load();
      final d = await a.addUrl('https://zcode.z.ai/remote/v4?sid=a&hash=b&t=1&name=x');
      await a.touch(d.id);
      await a.touch(d.id);
      await a.touch(d.id);
      final backup = a.exportJson();

      SharedPreferences.setMockInitialValues({});
      final b = DeviceStore();
      await b.load();
      await b.importJson(backup);
      expect(b.devices.first.useCount, 3);
    });
  });
}
