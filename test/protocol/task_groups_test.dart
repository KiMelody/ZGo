import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/task_groups.dart';
import 'package:zgo/state/device_store.dart';

import '../helpers/fake_device_session.dart';

/// 3.12.3 task-list additions: grouped-view parsing/ordering rules and the
/// exact wire shapes of the two zcode-task reads (live-probed shapes,
/// task internal-task/notes.md).

Future<FakeDeviceSession> fakeSession({
  Future<dynamic> Function(String channel, String method, List<Object?> args)?
  channelHandler,
}) async {
  SharedPreferences.setMockInitialValues({});
  final store = DeviceStore();
  await store.load();
  await store.addUrl(
      'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1&name=s'
      'ongsong&app_version=3.12.3');
  return FakeDeviceSession(
    deviceId: store.devices.single.id,
    params: store.devices.single.params!,
    workspaces: [
      {'workspacePath': '/repo/app', 'workspaceIdentity': 'app-id'},
    ],
    channelHandler: channelHandler,
  );
}

void main() {
  test('GroupedTaskView parses groups, members and the manual top order',
      () {
    final view = GroupedTaskView.fromMap({
      'groups': [
        {'id': 'g1', 'title': '重点', 'color': 'purple', 'createdAt': 10},
        {'id': 'g2', 'title': '杂项', 'color': 'blue', 'createdAt': 30},
      ],
      'members': [
        {
          'groupId': 'g1',
          'taskId': 't1',
          'workspaceKey': 'k',
          'sortOrder': null,
          'addedAt': 5,
        },
        {'groupId': 'g1', 'taskId': 't2', 'workspaceKey': 'k', 'sortOrder': 2},
        {'groupId': 'g2', 'taskId': 't3', 'workspaceKey': 'k', 'sortOrder': 1},
      ],
      'topLevelOrders': [
        {'type': 'group', 'groupId': 'g1', 'sortOrder': 9},
        // type:'task' rows are ignored for group ordering.
        {'type': 'task', 'workspaceKey': 'k', 'taskId': 't9', 'sortOrder': 8},
      ],
    });
    expect(view, isNotNull);
    // g1 carries the manual order 9 → first; g2 (no entry) falls back to
    // its own createdAt (30).
    expect([for (final g in view!.orderedGroups()) g.id], ['g1', 'g2']);
    // Members: manual sortOrder first (desc), never-sorted members by
    // addedAt desc.
    expect([for (final m in view.membersOf('g1')) m.taskId], ['t2', 't1']);
  });

  test('malformed payloads parse to null, empty groups stay a view', () {
    expect(GroupedTaskView.fromMap(null), isNull);
    expect(GroupedTaskView.fromMap('nope'), isNull);
    expect(GroupedTaskView.fromMap(const {}), isNull); // no groups list
    final empty = GroupedTaskView.fromMap({
      'groups': <dynamic>[],
      'members': <dynamic>[],
      'topLevelOrders': <dynamic>[],
    });
    expect(empty, isNotNull);
    expect(empty!.groups, isEmpty);
    expect(empty.orderedGroups(), isEmpty);
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

  test('session RPCs send the live-probed payload shapes (no extra fields)',
      () async {
    final session = await fakeSession(channelHandler: (c, m, args) async {
      if (m == 'listGroupedTaskViewStructure') {
        return {
          'groups': [
            {'id': 'g1', 'title': 'g', 'createdAt': 1},
          ],
          'members': <dynamic>[],
          'topLevelOrders': <dynamic>[],
        };
      }
      if (m == 'getTaskTokenUsage') {
        return {'totalTokens': 1234, 'modelRequestCount': 7};
      }
      return null;
    });

    expect(await session.groupedTaskView(), isNotNull);
    final (channel, method, args) = session.channelCalls.single;
    expect(channel, 'zcode-task');
    expect(method, 'listGroupedTaskViewStructure');
    expect(args, [
      {
        'workspaceScopes': [
          {'workspacePath': '/repo/app', 'workspaceIdentity': 'app-id'},
        ],
      },
    ]);

    session.channelCalls.clear();
    expect(await session.taskTokenUsage('t1'), isNotNull);
    final (channel2, method2, args2) = session.channelCalls.single;
    expect(channel2, 'zcode-task');
    expect(method2, 'getTaskTokenUsage');
    expect(args2, [
      {
        'taskId': 't1',
        'workspacePath': '/repo/app',
        'workspaceIdentity': 'app-id',
      },
    ]);
  });

  test('a desktop rejecting the methods degrades to null (R4)', () async {
    final session = await fakeSession(channelHandler: (c, m, args) async {
      if (c == 'zcode-task') {
        throw ChannelRpcError('Method not found: $m', null);
      }
      return null;
    });
    expect(await session.groupedTaskView(), isNull);
    expect(await session.taskTokenUsage('t1'), isNull);
  });
}
