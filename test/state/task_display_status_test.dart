import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/connection_params.dart';

import '../helpers/fake_device_session.dart';

/// taskDisplayStatus 的多行择优（task 10-11）：桌面注册表把同一 task_id
/// 镜像写入 2-4 个工作区（桌面脏数据，只能读端缓解），各行 displayStatus
/// 互不同步（15 个活例，含一行 running 一行 completed 的 sess_3e50d44f）。
/// 旧实现首行命中即返回——bootstrap 帧序随快照变化（spec
/// task-registry-semantics §3.1 同证），死会话被读成 running。新规则是
/// 行集合的纯函数：终态（completed/error）压运行态，同类取 updatedAt
/// 大者，updatedAt 缺失/相等按 workspacePath 字典序、再按状态串兜底；
/// 未识别值（含缺失字段）按运行态类处理。
///
/// 同类内若两行状态串相同，返回值无法区分胜者——所以「同类取新」用同类
/// 异串对（completed/error、running/idle）编码断言；每组用例都做双向
/// 帧序断言（spec §3.1 的既有约定）。
void main() {
  final params = RemoteConnectionParams.parse(
    'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1'
    '&name=songsong&app_version=3.14.0',
  )!;

  Map<String, dynamic> relayRow(
    String status, {
    int? updatedAt,
    String workspacePath = '/repo/a',
  }) =>
      {
        'taskId': 't1',
        'title': 'relay-t1',
        'workspacePath': workspacePath,
        'displayStatus': status,
        if (updatedAt != null) 'updatedAt': updatedAt,
      };

  /// Same row set, both bootstrap frame orders — the pick must not move.
  void expectPickStable(String? expected, List<Map<String, dynamic>> rows) {
    for (final order in [
      rows,
      rows.reversed.toList(),
    ]) {
      final session = FakeDeviceSession(
        deviceId: 'd1',
        params: params,
        relayTasks: order,
      );
      expect(session.taskDisplayStatus('t1'), expected,
          reason: 'the pick is a pure function of the row set — bootstrap '
              'frame order must never decide');
    }
  }

  test('terminal beats running-class even when the running row is fresher '
      '(R1.1: sending into a dead session is the worse direction)', () {
    expectPickStable('completed', [
      relayRow('running', updatedAt: 200, workspacePath: '/repo/a'),
      relayRow('completed', updatedAt: 100, workspacePath: '/repo/b'),
    ]);
  });

  test('same terminal class: the fresher row wins (R1.2)', () {
    expectPickStable('error', [
      relayRow('completed', updatedAt: 100, workspacePath: '/repo/a'),
      relayRow('error', updatedAt: 200, workspacePath: '/repo/b'),
    ]);
  });

  test('same running class: the fresher row wins (R1.2)', () {
    expectPickStable('idle', [
      relayRow('running', updatedAt: 100, workspacePath: '/repo/a'),
      relayRow('idle', updatedAt: 200, workspacePath: '/repo/b'),
    ]);
  });

  test('missing updatedAt on both rows: workspace-path tie-break, '
      'order-independent (R1.3)', () {
    expectPickStable('error', [
      relayRow('completed', workspacePath: '/repo/b'),
      relayRow('error', workspacePath: '/repo/a'),
    ]);
  });

  test('same class, same updatedAt, same workspace: status-string total '
      'order (R1.3 backstop)', () {
    expectPickStable('completed', [
      relayRow('error', workspacePath: '/repo/a'),
      relayRow('completed', workspacePath: '/repo/a'),
    ]);
  });

  test('unrecognized displayStatus counts as running-class (R1.4)', () {
    expectPickStable('completed', [
      relayRow('queued', updatedAt: 999, workspacePath: '/repo/a'),
      relayRow('completed', updatedAt: 1, workspacePath: '/repo/b'),
    ]);
  });

  test('missing displayStatus counts as running-class (R1.4)', () {
    expectPickStable('error', [
      {
        'taskId': 't1',
        'title': 'relay-t1',
        'workspacePath': '/repo/a',
        'updatedAt': 999,
      },
      relayRow('error', updatedAt: 1, workspacePath: '/repo/b'),
    ]);
  });

  test('no matching row → null (unchanged contract)', () {
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: params,
      relayTasks: [relayRow('running')],
    );
    expect(session.taskDisplayStatus('t2'), isNull);
    expect(
      FakeDeviceSession(deviceId: 'd1', params: params).taskDisplayStatus('t1'),
      isNull,
      reason: 'an empty relay view stays null',
    );
  });
}
