import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/state/device_session.dart';
import 'package:zgo/state/device_store.dart';
import 'package:zgo/ui/task_list_page.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../helpers/fake_device_session.dart';

/// Three-phase archived delete (design 11-11): preview copy (fork count /
/// files / incomplete), blocked toasts, the in-place checking→confirm dialog,
/// the all-delete per-status aggregation, a mid-run stop on exceptions, and
/// the two degrade fallbacks (single + batch) against a desktop whose
/// controller methods answer `Method not found:`.
void main() {
  Future<(DeviceStore, Device)> setupDevice() async {
    SharedPreferences.setMockInitialValues({});
    final store = DeviceStore();
    await store.load();
    await store.addUrl(
        'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1&name=songsong&app_version=3.18.0');
    return (store, store.devices.single);
  }

  Widget wrap(Widget child) => MaterialApp(
        theme: buildDarkTheme(),
        darkTheme: buildDarkTheme(),
        builder: (context, child) =>
            UiSettingsProvider(settings: UiSettings(), child: child!),
        home: child,
      );

  void usePhone(WidgetTester tester) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
  }

  /// One archived relay row ('归档任务一' / a1); opens the archive view.
  Future<FakeDeviceSession> setupArchiveSession(
    WidgetTester tester, {
    String? desktopVersion = '3.18.0',
    required Future<dynamic> Function(
            String channel, String method, List<Object?> args)
        channelHandler,
  }) async {
    usePhone(tester);
    final (store, device) = await setupDevice();
    final now = DateTime.now().millisecondsSinceEpoch;
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
      desktopVersionOverride: desktopVersion,
      entries: const [],
      workspaces: [
        {'workspacePath': '/repo/app', 'workspaceIdentity': 'app-id'},
      ],
      relayTasks: [
        {
          'taskId': 'a1',
          'title': '归档任务一',
          'workspacePath': '/repo/app',
          'workspaceIdentity': 'app-id',
          'displayStatus': 'idle',
          'updatedAt': now - 5,
          'archived': true,
        },
      ],
      channelHandler: channelHandler,
    );
    await tester.pumpWidget(wrap(TaskListPage(
      store: store,
      hub: DeviceSessionHub(nativeListEnabled: () => false),
      device: device,
      sessionOverride: session,
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看归档'));
    await tester.pumpAndSettle();
    return session;
  }

  /// Preview answer for a1 with a fork and two files.
  Map<String, dynamic> previewWithForks() => {
        'sessionId': 'a1',
        'revision': 'rev-a1',
        'sessionIds': ['a1', 'a1-fork'],
        'forks': [
          {'sessionId': 'a1-fork', 'title': 'fork'},
        ],
        'retainedArtifacts': <Object?>[],
        'deletedFiles': 2,
        'incomplete': false,
        'completed': true,
      };

  /// Long-press → sheet → 删除; stops right after the sheet action (the
  /// dialog's own state is what the case asserts).
  Future<void> openDeleteDialog(WidgetTester tester) async {
    await tester.longPress(find.text('归档任务一'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '删除'));
    await tester.pumpAndSettle();
  }

  group('single archived delete (3.18.0 preview → execute)', () {
    testWidgets('dialog shows while checking, then the fork count + files',
        (tester) async {
      final completer = Completer<dynamic>();
      final calls = <String>[];
      await setupArchiveSession(
        tester,
        channelHandler: (channel, method, args) async {
          calls.add(method);
          switch (method) {
            case 'previewArchivedTaskDeletion':
              return completer.future;
            case 'listTaskList':
              return const {
                'items': <dynamic>[],
                'total': 0,
                'hasMore': false,
              };
            case 'listPinnedTaskIds':
            case 'listArchivedTasks':
              return const <dynamic>[];
          }
          return null;
        },
      );

      await tester.longPress(find.text('归档任务一'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, '删除'));
      await tester.pump();

      // Checking state: the delete action is disabled.
      final confirmButton =
          tester.widget<FilledButton>(find.widgetWithText(FilledButton, '删除'));
      expect(confirmButton.onPressed, isNull);

      completer.complete(previewWithForks());
      await tester.pumpAndSettle();

      // Confirmation state: official deleteItem triple (title / children /
      // files), children = sessionIds.length - 1 = 1.
      expect(
        find.textContaining('“归档任务一”：对话、1 个所属子会话'),
        findsOneWidget,
      );
      expect(find.textContaining('2 个私有附件'), findsOneWidget);
      expect(find.text('删除尚未确认完成，请重试；已删除的内容无法恢复。'), findsNothing);
      expect(calls, contains('previewArchivedTaskDeletion'));
    });

    testWidgets('confirming executes with the preview revision; the row '
        'vanishes on status=deleted', (tester) async {
      final executed = <Map<String, dynamic>>[];
      await setupArchiveSession(
        tester,
        channelHandler: (channel, method, args) async {
          switch (method) {
            case 'previewArchivedTaskDeletion':
              return previewWithForks();
            case 'permanentlyDeleteArchivedTask':
              executed.add((args.single as Map).cast<String, dynamic>());
              return const {
                'sessionId': 'a1',
                'status': 'deleted',
                'sessionIds': ['a1', 'a1-fork'],
                'retainedArtifacts': 0,
              };
            case 'listTaskList':
              return const {
                'items': <dynamic>[],
                'total': 0,
                'hasMore': false,
              };
            case 'listPinnedTaskIds':
            case 'listArchivedTasks':
              return const <dynamic>[];
          }
          return null;
        },
      );

      await openDeleteDialog(tester);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();

      expect(executed.single['revision'], 'rev-a1');
      expect(executed.single['operationId'], isA<String>());
      expect(find.text('归档任务一'), findsNothing);
    });

    testWidgets('a blocked preview never opens the confirmation — the '
        'official reason toast shows instead', (tester) async {
      var executed = 0;
      await setupArchiveSession(
        tester,
        channelHandler: (channel, method, args) async {
          switch (method) {
            case 'previewArchivedTaskDeletion':
              return {
                ...previewWithForks(),
                'blockedReason': 'running',
                'incomplete': false,
                'completed': false,
              };
            case 'permanentlyDeleteArchivedTask':
              executed++;
              return null;
            case 'listTaskList':
              return const {
                'items': <dynamic>[],
                'total': 0,
                'hasMore': false,
              };
            case 'listPinnedTaskIds':
            case 'listArchivedTasks':
              return const <dynamic>[];
          }
          return null;
        },
      );

      await openDeleteDialog(tester);
      expect(
        find.text('任务仍在运行或有待处理输入，请先停止任务并处理队列。'),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, '删除'), findsNothing);
      expect(executed, 0);
    });

    testWidgets('an incomplete preview adds the official retry line and '
        'still allows confirming', (tester) async {
      await setupArchiveSession(
        tester,
        channelHandler: (channel, method, args) async {
          switch (method) {
            case 'previewArchivedTaskDeletion':
              return {
                ...previewWithForks(),
                'incomplete': true,
                'completed': false,
              };
            case 'listTaskList':
              return const {
                'items': <dynamic>[],
                'total': 0,
                'hasMore': false,
              };
            case 'listPinnedTaskIds':
            case 'listArchivedTasks':
              return const <dynamic>[];
          }
          return null;
        },
      );

      await openDeleteDialog(tester);
      expect(
        find.text('删除尚未确认完成，请重试；已删除的内容无法恢复。'),
        findsOneWidget,
      );
      final confirmButton =
          tester.widget<FilledButton>(find.widgetWithText(FilledButton, '删除'));
      expect(confirmButton.onPressed, isNotNull);
    });

    testWidgets('unknown method degrades to deleteArchivedTask (single)',
        (tester) async {
      final methods = <String>[];
      await setupArchiveSession(
        tester,
        channelHandler: (channel, method, args) async {
          methods.add(method);
          switch (method) {
            case 'previewArchivedTaskDeletion':
            case 'permanentlyDeleteArchivedTask':
              throw ChannelRpcError('Method not found: $method', null);
            case 'deleteArchivedTask':
              return const {'taskId': 'a1'};
            case 'listTaskList':
              return const {
                'items': <dynamic>[],
                'total': 0,
                'hasMore': false,
              };
            case 'listPinnedTaskIds':
            case 'listArchivedTasks':
              return const <dynamic>[];
          }
          return null;
        },
      );

      await openDeleteDialog(tester);
      // Legacy dialog copy (unchanged) and the 3.17.1 method.
      expect(find.text('删除这个任务？'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();

      expect(methods, contains('previewArchivedTaskDeletion'));
      expect(methods, contains('deleteArchivedTask'));
      expect(methods, isNot(contains('permanentlyDeleteArchivedTask')));
      expect(find.text('归档任务一'), findsNothing);
    });

    testWidgets('a session-data.unavailable preview refusal shows the '
        'official unavailable toast and never degrades', (tester) async {
      final methods = <String>[];
      await setupArchiveSession(
        tester,
        channelHandler: (channel, method, args) async {
          methods.add(method);
          switch (method) {
            case 'previewArchivedTaskDeletion':
              throw ChannelRpcError('session-data.unavailable', null);
            case 'deleteArchivedTask':
              return const {'taskId': 'a1'};
            case 'listTaskList':
              return const {
                'items': <dynamic>[],
                'total': 0,
                'hasMore': false,
              };
            case 'listPinnedTaskIds':
            case 'listArchivedTasks':
              return const <dynamic>[];
          }
          return null;
        },
      );

      await openDeleteDialog(tester);
      expect(
        find.text(
          '无法安全检查或删除：所属设备不可用、版本不支持或读取失败，请恢复后重试。',
        ),
        findsOneWidget,
      );
      // The refusal is NOT a degrade: the legacy soft-delete never runs.
      expect(methods, isNot(contains('deleteArchivedTask')));
      expect(find.text('删除这个任务？'), findsNothing);
    });
  });

  group('all archived delete (3.18.0 preview each → execute each)', () {
    testWidgets('per-task status aggregates into the three buckets and the '
        'batch method is never called', (tester) async {
      final methods = <String>[];
      await setupArchiveSession(
        tester,
        channelHandler: (channel, method, args) async {
          methods.add(method);
          switch (method) {
            case 'previewArchivedTaskDeletion':
              return previewWithForks();
            case 'permanentlyDeleteArchivedTask':
              return const {
                'sessionId': 'a1',
                'status': 'deleted',
                'sessionIds': ['a1', 'a1-fork'],
                'retainedArtifacts': 0,
              };
            case 'deleteArchivedTasks':
              throw StateError('the legacy batch must not run');
            case 'listTaskList':
              return const {
                'items': <dynamic>[],
                'total': 0,
                'hasMore': false,
              };
            case 'listPinnedTaskIds':
            case 'listArchivedTasks':
              return const <dynamic>[];
          }
          return null;
        },
      );

      await tester.tap(find.text('全部删除'));
      await tester.pumpAndSettle();
      // Checking → confirmation (deletable total 1).
      expect(find.text('删除这 1 个归档会话？'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '全部删除'));
      await tester.pumpAndSettle();

      expect(methods, contains('previewArchivedTaskDeletion'));
      expect(methods, contains('permanentlyDeleteArchivedTask'));
      expect(methods, isNot(contains('deleteArchivedTasks')));
      expect(find.text('成功 1 项，失败 0 项，已变化跳过 0 项'), findsOneWidget);
      expect(find.text('归档任务一'), findsNothing);
    });

    testWidgets('all-blocked preview skips confirmation and reports every '
        'row as skipped', (tester) async {
      var executed = 0;
      await setupArchiveSession(
        tester,
        channelHandler: (channel, method, args) async {
          switch (method) {
            case 'previewArchivedTaskDeletion':
              return {
                ...previewWithForks(),
                'blockedReason': 'in-use',
                'completed': false,
              };
            case 'permanentlyDeleteArchivedTask':
              executed++;
              return null;
            case 'deleteArchivedTasks':
              throw StateError('the legacy batch must not run');
            case 'listTaskList':
              return const {
                'items': <dynamic>[],
                'total': 0,
                'hasMore': false,
              };
            case 'listPinnedTaskIds':
            case 'listArchivedTasks':
              return const <dynamic>[];
          }
          return null;
        },
      );

      await tester.tap(find.text('全部删除'));
      await tester.pumpAndSettle();

      expect(find.text('成功 0 项，失败 0 项，已变化跳过 1 项'), findsOneWidget);
      expect(executed, 0);
      // No confirmation dialog ever appeared (the row is still listed).
      expect(find.text('成功 0 项，失败 0 项，已变化跳过 1 项'), findsOneWidget);
    });

    testWidgets('an execute that throws stops the loop, counts as failed and '
        'does NOT fall back to the batch', (tester) async {
      final methods = <String>[];
      await setupArchiveSession(
        tester,
        channelHandler: (channel, method, args) async {
          methods.add(method);
          switch (method) {
            case 'previewArchivedTaskDeletion':
              return previewWithForks();
            case 'permanentlyDeleteArchivedTask':
              throw ChannelRpcError('disk busy', null);
            case 'deleteArchivedTasks':
              throw StateError('the legacy batch must not run');
            case 'listTaskList':
              return const {
                'items': <dynamic>[],
                'total': 0,
                'hasMore': false,
              };
            case 'listPinnedTaskIds':
            case 'listArchivedTasks':
              return const <dynamic>[];
          }
          return null;
        },
      );

      await tester.tap(find.text('全部删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '全部删除'));
      await tester.pumpAndSettle();

      expect(methods, isNot(contains('deleteArchivedTasks')));
      expect(find.text('成功 0 项，失败 1 项，已变化跳过 0 项'), findsOneWidget);
    });

    testWidgets('unknown method degrades the batch to deleteArchivedTasks',
        (tester) async {
      final batches = <Map<String, dynamic>>[];
      await setupArchiveSession(
        tester,
        channelHandler: (channel, method, args) async {
          switch (method) {
            case 'previewArchivedTaskDeletion':
            case 'permanentlyDeleteArchivedTask':
              throw ChannelRpcError('Method not found: $method', null);
            case 'deleteArchivedTasks':
              final payload = (args.single as Map).cast<String, dynamic>();
              batches.add(payload);
              return {
                'deletedTaskIds': payload['taskIds'],
                'skippedTaskIds': const <String>[],
                'failedTaskIds': const <String>[],
              };
            case 'listTaskList':
              return const {
                'items': <dynamic>[],
                'total': 0,
                'hasMore': false,
              };
            case 'listPinnedTaskIds':
            case 'listArchivedTasks':
              return const <dynamic>[];
          }
          return null;
        },
      );

      await tester.tap(find.text('全部删除'));
      await tester.pumpAndSettle();
      // Legacy confirmation copy comes back (the pre-3.18.0 dialog).
      expect(find.text('删除这 1 个归档会话？'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '全部删除'));
      await tester.pumpAndSettle();

      expect(batches, hasLength(1));
      expect(batches.single['taskIds'], ['a1']);
      expect(find.text('成功 1 项，失败 0 项，已变化跳过 0 项'), findsOneWidget);
    });
  });
}