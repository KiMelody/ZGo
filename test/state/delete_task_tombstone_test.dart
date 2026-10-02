import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/connection_params.dart';

import '../helpers/fake_device_session.dart';

/// deleteTask 的本地墓碑（design 10-02 Step 3 / AC7）：RPC **明确成功**后
/// taskId 并入 `_locallyDeletedTaskIds` 并触发既有目录通知，行从合并目录
/// 立即消失（relay 陈旧行与 live 行两条残留路径都滤——桌面 live 索引没有
/// 已删除概念，reloadTasks 响应被桥吞时内存 relay 概览也仍是旧行）；超时 /
/// 抛错时结果未知，行必须保留（误滤比残留更糟）。
void main() {
  final params = RemoteConnectionParams.parse(
    'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1'
    '&name=songsong&app_version=3.14.0',
  )!;

  Map<String, dynamic> relayRow(String id) => {
    'taskId': id,
    'title': 'relay-$id',
    'workspacePath': '/repo/a',
    'displayStatus': 'idle',
  };

  test('delete success → the stale relay row vanishes from the merged '
      'directory and the directory notifies', () async {
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: params,
      relayTasks: [relayRow('t1'), relayRow('t2')],
    );
    expect(
      [for (final (e, _) in session.taskDirectory.allEntries()) e.sessionId],
      ['t1', 't2'],
    );

    var notified = 0;
    session.addListener(() => notified++);

    await session.deleteTask('t1'); // default handler answers (success)

    expect(
      [for (final (e, _) in session.taskDirectory.allEntries()) e.sessionId],
      ['t2'],
      reason: 'the desktop push may be swallowed — the local tombstone '
          'must hide the row immediately',
    );
    expect(notified, 1, reason: 'consumers re-read the directory on notify');
  });

  test('delete success → the live row vanishes too (the resurrection path)',
      () async {
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: params,
      relayTasks: [relayRow('t1')],
      entries: [
        {
          'sessionId': 't1',
          'title': 'live-t1',
          'phase': 'running',
          'pinned': true,
        },
      ],
    );
    expect(session.taskDirectory.allEntries(), hasLength(1));

    await session.deleteTask('t1');

    expect(session.taskDirectory.allEntries(), isEmpty);
    expect(session.taskDirectory.pinnedEntries(), isEmpty);
    expect(session.taskDirectory.notificationRows(), isEmpty);
  });

  test('delete timeout → unknown outcome, the row stays', () async {
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: params,
      relayTasks: [relayRow('t1')],
      channelHandler: (channel, method, args) async =>
          throw TimeoutException('bridge swing'),
    );

    await expectLater(session.deleteTask('t1'), throwsA(isA<TimeoutException>()));

    expect(session.taskDirectory.allEntries(), hasLength(1),
        reason: 'hiding a task the user believes deleted but isn\'t is '
            'worse than a stale row');
  });

  test('delete RPC error → unknown outcome, the row stays', () async {
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: params,
      relayTasks: [relayRow('t1')],
      channelHandler: (channel, method, args) async =>
          throw StateError('desktop exploded'),
    );

    await expectLater(session.deleteTask('t1'), throwsA(isA<StateError>()));

    expect(session.taskDirectory.allEntries(), hasLength(1));
  });
}
