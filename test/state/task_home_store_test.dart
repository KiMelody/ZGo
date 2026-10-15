import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zgo/state/task_home_store.dart';

/// TaskHomeStore（design 10-15 §1.1/§1.2，check P1-1 裁决后）：锚与本地
/// 墓碑的持久化——写入-读取、重启（重建实例）恢复、>2000 上限按最后确认
/// 时间修剪、7 天缺席修剪、墓碑 add-only + 7 天 TTL（复现移除已删）、旧
/// List 格式迁移、加载与磁盘状态并集。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('anchor write → read, refresh keeps the key and bumps the timestamp',
      () {
    final now = DateTime.fromMillisecondsSinceEpoch(1000000);
    final store = TaskHomeStore(deviceId: 'd1')
      ..anchorHome('t1', 'alpha', now: now);
    expect(store.homeKeys, {'t1': 'alpha'});
    expect(store.confirmedAtOf('t1'), now.millisecondsSinceEpoch);

    final later = now.add(const Duration(minutes: 5));
    store.refreshHome('t1', now: later);
    expect(store.homeKeys['t1'], 'alpha',
        reason: 'source ③ consistent refresh never flips the key');
    expect(store.confirmedAtOf('t1'), later.millisecondsSinceEpoch);
  });

  test('restart: a rebuilt instance restores anchors and tombstones from disk',
      () async {
    final before = TaskHomeStore(deviceId: 'd1')
      ..anchorHome('t1', 'alpha')
      ..anchorHome('t2', 'beta')
      ..addLocalDelete('t3');
    expect(before.loaded, isFalse);
    await before.load();
    // anchorHome before load must survive the (later, merging) load too.
    expect(before.homeKeys, {'t1': 'alpha', 't2': 'beta'});
    expect(before.locallyDeletedTaskIds, {'t3'});

    final after = TaskHomeStore(deviceId: 'd1');
    await after.load();
    expect(after.loaded, isTrue);
    expect(after.homeKeys, {'t1': 'alpha', 't2': 'beta'},
        reason: 'anchors survive restarts (R1)');
    expect(after.locallyDeletedTaskIds, {'t3'},
        reason: 'tombstones survive restarts (R1)');

    // Per-device keys: another device reads nothing.
    final other = TaskHomeStore(deviceId: 'd2');
    await other.load();
    expect(other.homeKeys, isEmpty);
    expect(other.locallyDeletedTaskIds, isEmpty);
  });

  test('a write racing the load is not clobbered by the disk merge', () async {
    // The session constructor confirms live homes before the async load
    // settles — the merge must treat the in-memory write as newer.
    final store = TaskHomeStore(deviceId: 'd1');
    unawaited(store.load());
    store.anchorHome('race', 'live-key');
    await store.load();
    expect(store.homeKeys['race'], 'live-key');
  });

  test('anchor cap: past 2000 entries the least recently confirmed go first',
      () {
    final store = TaskHomeStore(deviceId: 'd1');
    for (var i = 0; i < TaskHomeStore.maxEntries; i++) {
      store.anchorHome('t$i', 'w$i',
          now: DateTime.fromMillisecondsSinceEpoch(i));
    }
    expect(store.homeKeys.length, TaskHomeStore.maxEntries);
    // One more evicts the OLDEST confirmed anchor (t0), not a fresh one.
    store.anchorHome('new', 'w-new');
    expect(store.homeKeys.length, TaskHomeStore.maxEntries);
    expect(store.homeKeys.containsKey('t0'), isFalse);
    expect(store.homeKeys.containsKey('new'), isTrue);
    expect(store.homeKeys.containsKey('t${TaskHomeStore.maxEntries - 1}'),
        isTrue);
  });

  test('absence prune: ids absent from relay∪live for 7 days drop, present '
      'or recently confirmed stay', () {
    final now = DateTime.fromMillisecondsSinceEpoch(10000000);
    final store = TaskHomeStore(deviceId: 'd1')
      ..anchorHome('gone-long', 'w',
          now: now.subtract(const Duration(days: 8)))
      ..anchorHome('gone-recent', 'w',
          now: now.subtract(const Duration(days: 2)))
      ..anchorHome('present', 'w', now: now.subtract(const Duration(days: 8)));
    store.pruneAbsent({'present'}, now: now);
    expect(store.homeKeys.keys.toSet(), {'gone-recent', 'present'},
        reason: '7-day absence prune (design §1.1) — presence in relay∪live '
            'or a confirmation within the window keeps the anchor');
  });

  test('tombstones are add-only — expiry (7-day TTL) is the only removal',
      () {
    final now = clock.now();
    final store = TaskHomeStore(deviceId: 'd1')
      ..addLocalDelete('t1', now: now)
      ..addLocalDelete('t1', now: now); // duplicate write is a no-op
    expect(store.locallyDeletedTaskIds, {'t1'});
    // Within the TTL window the tombstone still hides the id, whatever the
    // overview re-lists (check P1-1: no reappearance removal exists).
    expect(
      store.locallyDeletedTaskIds,
      {'t1'},
      reason: 'add-only: nothing but the TTL can lift a tombstone',
    );
  });

  test('TTL expiry: the view drops expired ids; prune removes them from '
      'storage (survives a restart)', () async {
    final now = clock.now();
    final store = TaskHomeStore(deviceId: 'd1')
      ..addLocalDelete('fresh', now: now)
      ..addLocalDelete('stale', now: now.subtract(const Duration(days: 8)))
      ..addLocalDelete(
        'boundary',
        now: now.subtract(TaskHomeStore.tombstoneTtl),
      );
    expect(store.locallyDeletedTaskIds, {'fresh'},
        reason: 'the view holds unexpired ids only — 8-day-old and '
            'exact-TTL-boundary entries count as expired');

    store.pruneExpiredTombstones(now: now);
    await store.load(); // flush: pending save lands before the restart read

    final restarted = TaskHomeStore(deviceId: 'd1');
    await restarted.load();
    expect(restarted.locallyDeletedTaskIds, {'fresh'},
        reason: 'pruned entries are gone from disk (TTL 自清), the fresh '
            'one survives');
  });

  test('legacy List-format tombstones migrate to the TTL map at load time',
      () async {
    SharedPreferences.setMockInitialValues({
      'task.locallyDeletedTaskIds.d1': '["t-old"]',
    });
    final store = TaskHomeStore(deviceId: 'd1');
    await store.load();
    expect(store.locallyDeletedTaskIds, {'t-old'},
        reason: 'old-format ids are adopted with the current timestamp — '
            'the TTL clock starts at migration, never hides forever');

    // The migration round-trips into the new map format on the next save.
    store.addLocalDelete('t-new');
    await store.load(); // flush
    final restarted = TaskHomeStore(deviceId: 'd1');
    await restarted.load();
    expect(restarted.locallyDeletedTaskIds, containsAll(['t-old', 't-new']));
  });

  test('corrupt disk JSON degrades to the in-memory state', () async {
    SharedPreferences.setMockInitialValues({
      'task.homeAnchors.d1': '{not json',
      'task.locallyDeletedTaskIds.d1': '["t-kept",',
    });
    final store = TaskHomeStore(deviceId: 'd1')..anchorHome('t-mem', 'w');
    await store.load();
    expect(store.homeKeys, {'t-mem': 'w'});
    expect(store.locallyDeletedTaskIds, isEmpty,
        reason: 'a corrupt tombstone list degrades to empty, never throws');
  });
}
