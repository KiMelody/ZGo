import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/state/device_session.dart';

void main() {
  group('taskConfigOptionsArgs', () {
    const scope = {'workspacePath': '/home/ws', 'workspaceIdentity': 'ws-id'};

    test('relay task with taskId → taskId + task workspace scope', () {
      final args = DeviceSession.taskConfigOptionsArgs({
        'taskId': 'task-1',
        'workspacePath': '/home/ws',
        'workspaceIdentity': 'ws-id',
        'title': 'unrelated fields are dropped',
      }, scope);

      // Shape locked against the live-probed 3.12.3 call (2026-09-17):
      // {taskId, workspacePath, workspaceIdentity?} — nothing else.
      expect(args, {
        'taskId': 'task-1',
        'workspacePath': '/home/ws',
        'workspaceIdentity': 'ws-id',
      });
    });

    test('relay task without workspaceIdentity omits the key', () {
      final args = DeviceSession.taskConfigOptionsArgs({
        'taskId': 42,
        'workspacePath': '/home/ws',
      }, scope);

      expect(args.containsKey('workspaceIdentity'), isFalse);
      expect(args, {'taskId': '42', 'workspacePath': '/home/ws'});
    });

    test('null relay task → bare workspace scope', () {
      expect(
        DeviceSession.taskConfigOptionsArgs(null, scope),
        {'workspacePath': '/home/ws', 'workspaceIdentity': 'ws-id'},
      );
    });

    test('relay task without a taskId → bare workspace scope', () {
      expect(
        DeviceSession.taskConfigOptionsArgs({'title': 'no id'}, scope),
        {'workspacePath': '/home/ws', 'workspaceIdentity': 'ws-id'},
      );
    });
  });
}
