import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/state/device_session.dart';
import 'package:zgo/state/device_store.dart';
import 'package:zgo/state/scheduled_store.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../helpers/fake_device_session.dart';

/// DeviceSession recording the createSession config the scheduler fires
/// with; [prepFails] reproduces the unattended "prep unreachable" branch.
class RecordingSession extends FakeDeviceSession {
  RecordingSession({required super.deviceId, required super.params});

  final configs = <Map<String, dynamic>?>[];
  bool prepFails = false;

  @override
  Future<WorkspacePrep> prepareWorkspace() async {
    if (prepFails) throw StateError('prep unavailable');
    return super.prepareWorkspace();
  }

  @override
  Future<String> createTaskWithMessage(
    String text, {
    Map<String, dynamic>? config,
  }) async {
    configs.add(config);
    return 'session-x';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(ScheduledStore, RecordingSession, MessageScheduler)> setup(
    UiSettings? ui,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final store = ScheduledStore();
    await store.load();
    final devices = DeviceStore();
    await devices.load();
    await devices.addUrl(
        'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1'
        '&name=songsong&app_version=3.8.1');
    final device = devices.devices.single;
    final session =
        RecordingSession(deviceId: device.id, params: device.params!);
    final hub = DeviceSessionHub(nativeListEnabled: () => true)
      ..installForTesting(session);
    final scheduler =
        MessageScheduler(store: store, devices: devices, hub: hub, ui: ui);
    return (store, session, scheduler);
  }

  group('MessageScheduler new-task config (PRD A6/A7)', () {
    test('A6: per-message override wins over global defaults', () async {
      final ui = UiSettings()
        ..newTaskMode = 'edit'
        ..newTaskModel = 'builtin/glm-5.2';
      final (store, session, scheduler) = await setup(ui);
      await store.add(
        deviceId: session.deviceId,
        deviceLabel: 'Desktop',
        text: 'run the sweep',
        fireAt: DateTime.now().subtract(const Duration(minutes: 1))
            .millisecondsSinceEpoch,
        mode: 'plan',
        model: 'kimi/moonshot-v2',
        thought: 'high',
      );
      await scheduler.debugTickForTest();

      expect(session.configs.single, {
        'provider': 'kimi',
        'model': 'moonshot-v2',
        'mode': 'plan',
        'thought': 'high',
      });
      expect(store.items.single.sent, isTrue);
    });

    test('A6: no override → global defaults apply', () async {
      final ui = UiSettings()
        ..newTaskMode = 'edit'
        ..newTaskModel = 'builtin/glm-5.2';
      final (store, session, scheduler) = await setup(ui);
      await store.add(
        deviceId: session.deviceId,
        deviceLabel: 'Desktop',
        text: 'run the sweep',
        fireAt: DateTime.now().subtract(const Duration(minutes: 1))
            .millisecondsSinceEpoch,
      );
      await scheduler.debugTickForTest();

      // Model validated against prep options; thought unset → prep
      // currentValue ('max' in the fake's prep).
      expect(session.configs.single, {
        'provider': 'builtin',
        'model': 'glm-5.2',
        'mode': 'edit',
        'thought': 'max',
      });
      expect(store.items.single.sent, isTrue);
    });

    test('A6/A2: no override, no defaults → thought-only config', () async {
      final (store, session, scheduler) = await setup(null);
      await store.add(
        deviceId: session.deviceId,
        deviceLabel: 'Desktop',
        text: 'run the sweep',
        fireAt: DateTime.now().subtract(const Duration(minutes: 1))
            .millisecondsSinceEpoch,
      );
      await scheduler.debugTickForTest();

      expect(session.configs.single, {'thought': 'max'});
    });

    test('A7: prep unreachable → model dropped, four-tier mode kept, '
        'thought=max', () async {
      final (store, session, scheduler) = await setup(null);
      session.prepFails = true;
      await store.add(
        deviceId: session.deviceId,
        deviceLabel: 'Desktop',
        text: 'run the sweep',
        fireAt: DateTime.now().subtract(const Duration(minutes: 1))
            .millisecondsSinceEpoch,
        mode: 'plan',
        model: 'kimi/moonshot-v2',
        thought: 'high',
      );
      await scheduler.debugTickForTest();

      expect(session.configs.single, {'mode': 'plan', 'thought': 'max'});
      expect(store.items.single.sent, isTrue);
    });

    test('A7: prep unreachable + non-four-tier mode → mode dropped too',
        () async {
      final (store, session, scheduler) = await setup(null);
      session.prepFails = true;
      await store.add(
        deviceId: session.deviceId,
        deviceLabel: 'Desktop',
        text: 'run the sweep',
        fireAt: DateTime.now().subtract(const Duration(minutes: 1))
            .millisecondsSinceEpoch,
        mode: 'agent',
      );
      await scheduler.debugTickForTest();

      expect(session.configs.single, {'thought': 'max'});
    });
  });
}
