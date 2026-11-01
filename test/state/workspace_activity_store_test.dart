import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zgo/state/workspace_activity_store.dart';

/// WorkspaceActivityStore（design 11-01 §4）：工作区活动键的持久化——写入-
/// 读取、重启恢复、加载与内存写入并集（内存更新）、按键单调不回退、上限
/// 修剪、损坏 JSON 降级。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('record → activityOf; unknown keys answer null', () {
    final store = WorkspaceActivityStore(deviceId: 'd1');
    expect(store.activityOf('alpha'), isNull);
    store.record('alpha', 1000);
    expect(store.activityOf('alpha'), 1000);
    expect(store.hasPersistedState, isTrue);
  });

  test('writes are monotonic per key: a stale frame never rewinds the key', () {
    final store = WorkspaceActivityStore(deviceId: 'd1');
    store.record('alpha', 2000);
    store.record('alpha', 1000);
    expect(store.activityOf('alpha'), 2000,
        reason: 'an out-of-order landing must not move the card backwards');
    store.record('alpha', 3000);
    expect(store.activityOf('alpha'), 3000);
  });

  test('restart: a rebuilt instance restores the map from disk', () async {
    final before = WorkspaceActivityStore(deviceId: 'd1')
      ..record('alpha', 2000)
      ..record('beta', 1000);
    await before.load();
    expect(before.loaded, isTrue);

    final after = WorkspaceActivityStore(deviceId: 'd1');
    await after.load();
    expect(after.activityOf('alpha'), 2000);
    expect(after.activityOf('beta'), 1000);

    // Per-device keys: another device reads nothing.
    final other = WorkspaceActivityStore(deviceId: 'd2');
    await other.load();
    expect(other.hasPersistedState, isFalse);
  });

  test('a write racing the load is not clobbered by the disk merge', () async {
    SharedPreferences.setMockInitialValues({
      'task.workspaceActivity.d1': jsonEncode({'alpha': 1000}),
    });
    final store = WorkspaceActivityStore(deviceId: 'd1');
    final loading = store.load();
    store.record('alpha', 5000);
    await loading;
    expect(store.activityOf('alpha'), 5000,
        reason: 'the in-memory landing is the newer fact');
  });

  test('the cap prunes the oldest activity keys', () async {
    final store = WorkspaceActivityStore(deviceId: 'd1');
    for (var i = 0; i < WorkspaceActivityStore.maxEntries + 5; i++) {
      store.record('ws$i', i + 1);
    }
    expect(store.activityOf('ws0'), isNull,
        reason: 'the oldest key goes first');
    expect(
      store.activityOf('ws${WorkspaceActivityStore.maxEntries + 4}'),
      WorkspaceActivityStore.maxEntries + 5,
    );
  });

  test('corrupt disk JSON degrades to the in-memory state', () async {
    SharedPreferences.setMockInitialValues({
      'task.workspaceActivity.d1': 'not-json',
    });
    final store = WorkspaceActivityStore(deviceId: 'd1')..record('alpha', 42);
    await store.load();
    expect(store.loaded, isTrue);
    expect(store.activityOf('alpha'), 42);
    expect(store.activityOf('beta'), isNull);
  });

  test('non-positive values are ignored (no bogus epoch keys)', () {
    final store = WorkspaceActivityStore(deviceId: 'd1');
    store.record('alpha', 0);
    store.record('beta', -1);
    store.record('', 10);
    expect(store.hasPersistedState, isFalse);
  });

  test('unawaited saves keep working after a load settle', () async {
    final store = WorkspaceActivityStore(deviceId: 'd1');
    await store.load();
    store.record('gamma', 7);
    // Fire-and-forget persistence: give the mock store a turn to settle.
    await Future<void>.delayed(Duration.zero);
    final restored = WorkspaceActivityStore(deviceId: 'd1');
    await restored.load();
    expect(restored.activityOf('gamma'), 7);
  });
}
