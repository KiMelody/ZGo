import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/connection_params.dart';

import '../helpers/fake_device_session.dart';

/// Task mutations address the OWNING workspace (desktop `resolveTaskAddress`
/// matches the taskId+workspacePath+workspaceIdentity triple exactly once —
/// the cross-workspace list's delete/archive/rename all failed with
/// matches=0 when they rode the active workspace scope).
void main() {
  final params = RemoteConnectionParams.parse(
    'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1'
    '&name=songsong&app_version=3.14.0',
  )!;

  const wsA = {
    'workspacePath': '/repo/a',
    'workspaceIdentity': 'a-id',
  };

  FakeDeviceSession sessionWith(List<Map<String, dynamic>> relayTasks) =>
      FakeDeviceSession(
        deviceId: 'd1',
        params: params,
        workspaces: [wsA],
        relayTasks: relayTasks,
      );

  /// The single `zcode-task` mutation payload recorded by [sessionWith].
  Map<String, dynamic> singleMutation(FakeDeviceSession session) =>
      session.channelCalls.singleWhere((c) => c.$1 == 'zcode-task').$3.single
          as Map<String, dynamic>;

  test('relay row owning workspace B → rename/delete payloads carry B, '
      'not the active workspace A', () async {
    final session = sessionWith([
      {'taskId': 't-b', 'workspacePath': '/repo/b', 'workspaceIdentity': 'b-id'},
    ]);

    await session.taskCommands.rename('t-b', '新标题');
    await session.taskCommands.delete('t-b');

    final mutations = session.channelCalls
        .where((c) => c.$1 == 'zcode-task')
        .toList();
    expect(mutations.map((c) => c.$2).toList(), ['renameTask', 'deleteTask']);
    expect(mutations[0].$3.single, {
      'taskId': 't-b',
      'workspacePath': '/repo/b',
      'workspaceIdentity': 'b-id',
      'title': '新标题',
    });
    expect(mutations[1].$3.single, {
      'taskId': 't-b',
      'workspacePath': '/repo/b',
      'workspaceIdentity': 'b-id',
    });
  });

  test('same-workspace task (relay row = active workspace A) still carries A '
      '(regression: behavior frozen)', () async {
    final session = sessionWith([
      {'taskId': 't-a', 'workspacePath': '/repo/a', 'workspaceIdentity': 'a-id'},
    ]);

    await session.taskCommands.rename('t-a', 'x');

    expect(singleMutation(session), {
      'taskId': 't-a',
      'workspacePath': '/repo/a',
      'workspaceIdentity': 'a-id',
      'title': 'x',
    });
  });

  test('no relay row for the taskId → falls back to the active workspace A '
      '(pre-fix behavior)', () async {
    final session = sessionWith(const []);

    await session.taskCommands.rename('t-unknown', 'x');

    expect(singleMutation(session), {
      'taskId': 't-unknown',
      'workspacePath': '/repo/a',
      'workspaceIdentity': 'a-id',
      'title': 'x',
    });
  });

  test('relay row without workspaceIdentity → the key is omitted, path only',
      () async {
    final session = sessionWith([
      {'taskId': 't-p', 'workspacePath': '/repo/b'},
    ]);

    await session.taskCommands.setPinned('t-p', true);

    expect(singleMutation(session), {
      'taskId': 't-p',
      'workspacePath': '/repo/b',
      'pinned': true,
    });
  });
}
