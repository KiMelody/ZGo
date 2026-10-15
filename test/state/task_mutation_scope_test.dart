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

  test('multi-home twins → the stable pick row wins, BOTH frame orders '
      '(scope pick = TaskDirectory.byId, never frame order)', () async {
    // 2026-10-15 stable-anchor rule: updatedAt exited the pick keys
    // (design §2.1) — no createdAt on either row (equal) and equal
    // terminal class, so the lexicographically smaller key
    // ('/repo/new' < '/repo/old') decides. The frame-order independence
    // assertion tradition is kept.
    final older = {
      'taskId': 't-dual',
      'workspacePath': '/repo/old',
      'workspaceIdentity': 'old-id',
      'updatedAt': 100,
    };
    final newer = {
      'taskId': 't-dual',
      'workspacePath': '/repo/new',
      'workspaceIdentity': 'new-id',
      'updatedAt': 200,
    };
    for (final frame in [
      [older, newer],
      [newer, older],
    ]) {
      final session = sessionWith(frame);
      await session.taskCommands.delete('t-dual');
      expect(
        singleMutation(session),
        {
          'taskId': 't-dual',
          'workspacePath': '/repo/new',
          'workspaceIdentity': 'new-id',
        },
        reason: 'frame order ${frame[0]['workspacePath']} first',
      );
    }
  });

  test('an anchored twin is the mutation target, ahead of the stable pick '
      '(design 10-15: scope follows the synthesized home)', () async {
    // The anchor selects the home copy FIRST (design §2.1 layer 1) — the
    // cold pick (and any updatedAt/lex order) must not displace it: the
    // visible row IS the anchored copy, so the delete must address it.
    final copy = {
      'taskId': 't-dual',
      'workspacePath': '/repo/copy',
      'workspaceIdentity': 'copy-id',
      'updatedAt': 999,
    };
    final real = {
      'taskId': 't-dual',
      'workspacePath': '/repo/real',
      'workspaceIdentity': 'real-id',
      'updatedAt': 1,
    };
    for (final frame in [
      [copy, real],
      [real, copy],
    ]) {
      final session = sessionWith(frame);
      session.taskHomeStore.anchorHome('t-dual', 'real-id');
      await session.taskCommands.delete('t-dual');
      expect(
        singleMutation(session),
        {
          'taskId': 't-dual',
          'workspacePath': '/repo/real',
          'workspaceIdentity': 'real-id',
        },
        reason: 'the anchored copy is the home the user sees '
            '(frame order ${frame[0]['workspacePath']} first)',
      );
    }
  });

  test('multi-home twins with equal stable fields → lexicographically '
      'smaller workspace key wins, BOTH frame orders', () async {
    final keyB = {
      'taskId': 't-dual',
      'workspacePath': '/repo/b',
      'workspaceIdentity': 'b-id',
      'updatedAt': 100,
    };
    final keyA = {
      'taskId': 't-dual',
      'workspacePath': '/repo/a',
      'workspaceIdentity': 'a-id',
      'updatedAt': 100,
    };
    for (final frame in [
      [keyB, keyA],
      [keyA, keyB],
    ]) {
      final session = sessionWith(frame);
      await session.taskCommands.rename('t-dual', 'x');
      expect(
        singleMutation(session),
        {
          'taskId': 't-dual',
          'workspacePath': '/repo/a',
          'workspaceIdentity': 'a-id',
          'title': 'x',
        },
        reason: 'frame order ${frame[0]['workspacePath']} first',
      );
    }
  });
}
