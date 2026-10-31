import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/task_group_resolver.dart';
import 'package:zgo/protocol/task_groups.dart';
import 'package:zgo/state/device_store.dart';

import '../helpers/fake_device_session.dart';

/// Task-group wiring (desktop 3.17.1): the grouped view is answered by the
/// direct-read [TaskGroupResolver] — the `listGroupedTaskViewStructure` RPC
/// is gone. TaskTokenUsage keeps its 3.12.3 wire read.

/// A resolver answering a fixed view — the device-session factory seam.
class _StubGroupResolver extends TaskGroupResolver {
  _StubGroupResolver(this.view)
      : super(
          homeOf: () => null,
          readRange: (path, offset, length) async => Uint8List(0),
        );

  final GroupedTaskView? view;

  @override
  Future<GroupedTaskView?> load() async => view;
}

Future<FakeDeviceSession> fakeSession({
  Future<dynamic> Function(String channel, String method, List<Object?> args)?
  channelHandler,
  TaskGroupResolver Function(String? Function() homeOf)?
  taskGroupResolverFactory,
}) async {
  SharedPreferences.setMockInitialValues({});
  final store = DeviceStore();
  await store.load();
  await store.addUrl(
      'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1&name=s'
      'ongsong&app_version=3.17.1');
  return FakeDeviceSession(
    deviceId: store.devices.single.id,
    params: store.devices.single.params!,
    workspaces: [
      {'workspacePath': '/repo/app', 'workspaceIdentity': 'app-id'},
    ],
    channelHandler: channelHandler,
    taskGroupResolverFactory: taskGroupResolverFactory,
  );
}

void main() {
  TaskGroupInfo group(String id, int createdAt) => TaskGroupInfo(
        id: id,
        title: id,
        color: 'gray',
        createdAt: createdAt,
      );

  TaskGroupMember member(
    String taskId,
    int effectiveSort, {
    String groupId = 'g',
    String workspaceKey = 'w',
  }) =>
      TaskGroupMember(
        groupId: groupId,
        workspaceKey: workspaceKey,
        taskId: taskId,
        effectiveSort: effectiveSort,
      );

  test('orderedGroups ascends on order rows and appends the rest by '
      '(createdAt, id)', () {
    final view = GroupedTaskView(
      groups: [
        group('g2', 40),
        group('g1', 30),
        group('g4', 10),
        group('g3', 20),
      ],
      membersByGroup: const {},
      groupSortOrder: {
        'g2': 3,
        'g1': 1,
        // An order row naming a deleted group is ignored.
        'gone': 2,
      },
    );

    expect(
      [for (final g in view.orderedGroups()) g.id],
      ['g1', 'g2', 'g4', 'g3'],
      reason: 'ordered groups first (ascending sort_order), the unordered '
          'ones appended by created_at ascending; the dangling order row '
          'is ignored',
    );
  });

  test('equal sort_order ties break on the group id (desktop SQL order)', () {
    final view = GroupedTaskView(
      groups: [group('b', 10), group('a', 20)],
      membersByGroup: const {},
      groupSortOrder: {'b': 5, 'a': 5},
    );

    expect([for (final g in view.orderedGroups()) g.id], ['a', 'b']);
  });

  test('membersOf ascends by effectiveSort with (workspaceKey, taskId) '
      'tie-breaks', () {
    final view = GroupedTaskView(
      groups: const [],
      membersByGroup: {
        'g': [
          member('t1', 2),
          member('t2', -500),
          member('t3', -100),
          member('t4', 0, workspaceKey: 'w2'),
          member('t5', 0, workspaceKey: 'w1'),
        ],
      },
    );

    expect(
      [for (final m in view.membersOf('g')) m.taskId],
      ['t2', 't3', 't5', 't4', 't1'],
      reason: 'negative coalesce values (newest addedAt) lead, then manual '
          'sort_order ascending, ties by workspace_key then task_id',
    );
    expect(view.membersOf('missing'), isEmpty);
  });

  test('members keep the desktop workspace_key for cross-workspace rows', () {
    final view = GroupedTaskView(
      groups: const [],
      membersByGroup: {
        'g': [
          member('same-task', 1, workspaceKey: r'F:\repo'),
          member('same-task', 2, workspaceKey: r'D:\other'),
        ],
      },
    );

    expect(
      [for (final m in view.membersOf('g')) m.workspaceKey],
      [r'F:\repo', r'D:\other'],
      reason: 'the same task may be a member in two workspaces; both rows '
          'survive',
    );
  });

  test('groupedTaskView answers from the resolver, never the channel',
      () async {
    final view = GroupedTaskView(
      groups: const [
        TaskGroupInfo(id: 'g1', title: '重点', color: 'purple', createdAt: 10),
      ],
      membersByGroup: const {
        'g1': [
          TaskGroupMember(
            groupId: 'g1',
            workspaceKey: '/repo/app',
            taskId: 't1',
            effectiveSort: 0,
          ),
        ],
      },
      groupSortOrder: const {'g1': 9},
    );
    final session = await fakeSession(
      channelHandler: (c, m, args) async => fail('no channel RPC expected'),
      taskGroupResolverFactory: (_) => _StubGroupResolver(view),
    );

    expect(await session.groupedTaskView(), same(view));
    expect(session.channelCalls, isEmpty,
        reason: 'the 3.17.1 path is a sqlite read, not a zcode-task RPC');
  });

  test('groupedTaskView degrades to null when the resolver has no answer',
      () async {
    final session = await fakeSession(
      taskGroupResolverFactory: (_) => _StubGroupResolver(null),
    );

    expect(await session.groupedTaskView(), isNull);
    expect(session.channelCalls, isEmpty);
  });

  test('TaskTokenUsage parses the shown fields and tolerates extra ones', () {
    final usage = TaskTokenUsage.fromMap({
      'sessionId': 't1',
      'totalTokens': 1234,
      'modelRequestCount': 7,
      'inputTokens': 1000,
      'inputBaselineBySource': <String, dynamic>{'main_turn': 900},
    });
    expect(usage.totalTokens, 1234);
    expect(usage.modelRequestCount, 7);
  });

  test('taskTokenUsage sends the live-probed payload shape (no extra fields)',
      () async {
    final session = await fakeSession(channelHandler: (c, m, args) async {
      if (m == 'getTaskTokenUsage') {
        return {'totalTokens': 1234, 'modelRequestCount': 7};
      }
      return null;
    });

    expect(await session.taskTokenUsage('t1'), isNotNull);
    final (channel, method, args) = session.channelCalls.single;
    expect(channel, 'zcode-task');
    expect(method, 'getTaskTokenUsage');
    expect(args, [
      {
        'taskId': 't1',
        'workspacePath': '/repo/app',
        'workspaceIdentity': 'app-id',
      },
    ]);
  });

  test('a desktop rejecting getTaskTokenUsage degrades to null (R4)',
      () async {
    final session = await fakeSession(channelHandler: (c, m, args) async {
      if (c == 'zcode-task') {
        throw ChannelRpcError('Method not found: $m', null);
      }
      return null;
    });
    expect(await session.taskTokenUsage('t1'), isNull);
  });
}
