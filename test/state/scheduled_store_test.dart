import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zgo/state/scheduled_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('ScheduledMessage new-task config fields', () {
    test('add stores the optional mode/model/thought overrides', () async {
      final store = ScheduledStore();
      await store.load();
      await store.add(
        deviceId: 'dev-1',
        deviceLabel: 'Desktop',
        text: 'hello',
        fireAt: 123,
        mode: 'plan',
        model: 'builtin:zai/GLM-5.2',
        thought: 'high',
      );
      final m = store.items.single;
      expect(m.mode, 'plan');
      expect(m.model, 'builtin:zai/GLM-5.2');
      expect(m.thought, 'high');
    });

    test('add without overrides leaves the config fields null', () async {
      final store = ScheduledStore();
      await store.load();
      await store.add(
        deviceId: 'dev-1',
        deviceLabel: 'Desktop',
        text: 'hello',
        fireAt: 123,
      );
      final m = store.items.single;
      expect(m.mode, isNull);
      expect(m.model, isNull);
      expect(m.thought, isNull);
    });

    test('round-trip through persistence keeps the overrides', () async {
      final store = ScheduledStore();
      await store.load();
      await store.add(
        deviceId: 'dev-1',
        deviceLabel: 'Desktop',
        text: 'hello',
        fireAt: 123,
        mode: 'yolo',
        model: 'p/m',
        thought: 'max',
      );

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('zgo_scheduled_v1');
      expect(raw, isNotNull);

      final reloaded = ScheduledStore();
      await reloaded.load();
      final m = reloaded.items.single;
      expect(m.mode, 'yolo');
      expect(m.model, 'p/m');
      expect(m.thought, 'max');
    });

    test('old JSON without the fields stays compatible (null)', () {
      final m = ScheduledMessage.fromJson({
        'id': 'legacy',
        'deviceId': 'dev-1',
        'deviceLabel': 'Desktop',
        'text': 'hello',
        'fireAt': 123,
        'attempts': 1,
        'lastError': 'boom',
        // no mode/model/thought keys
      });
      expect(m.mode, isNull);
      expect(m.model, isNull);
      expect(m.thought, isNull);
      // markSent-style copyWith must not lose or invent config fields.
      final copy = m.copyWith(sent: true, clearError: true);
      expect(copy.mode, isNull);
      expect(copy.model, isNull);
      expect(copy.thought, isNull);
      expect(copy.sent, isTrue);
    });

    test('toJson omits unset fields, writes set ones', () {
      final bare = ScheduledMessage(
        id: 'a',
        deviceId: 'd',
        deviceLabel: 'l',
        text: 't',
        fireAt: 1,
      ).toJson();
      expect(bare.containsKey('mode'), isFalse);
      expect(bare.containsKey('model'), isFalse);
      expect(bare.containsKey('thought'), isFalse);

      final full = ScheduledMessage(
        id: 'a',
        deviceId: 'd',
        deviceLabel: 'l',
        text: 't',
        fireAt: 1,
        mode: 'edit',
        model: 'p/m',
        thought: 'low',
      ).toJson();
      expect(full['mode'], 'edit');
      expect(full['model'], 'p/m');
      expect(full['thought'], 'low');
    });
  });
}
