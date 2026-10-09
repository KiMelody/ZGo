import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/protocol/connection_params.dart';
import 'package:zgo/ui/slash_items.dart';
import 'package:zgo/ui/task_search_page.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../helpers/fake_device_session.dart';

Widget wrap(Widget child) => MaterialApp(
      theme: buildDarkTheme(),
      darkTheme: buildDarkTheme(),
      builder: (context, child) =>
          UiSettingsProvider(settings: UiSettings(), child: child!),
      home: child,
    );

/// The page pops itself on row taps — push it through a real navigator so
/// the pop lands somewhere.
Widget host(WidgetBuilder build) => Builder(
      builder: (context) => Center(
        child: ElevatedButton(
          onPressed: () =>
              Navigator.of(context).push(MaterialPageRoute(builder: build)),
          child: const Text('open'),
        ),
      ),
    );

FakeDeviceSession fileProbeSession({
  required Future<dynamic> Function(String method) fileAnswer,
}) =>
    FakeDeviceSession(
      deviceId: 'd1',
      params: RemoteConnectionParams.parse(
          'https://zcode.z.ai/remote/v4?sid=a&hash=b&t=1&mid=m&name=n&app_version=3')!,
      entries: const [],
      workspaces: [
        {'workspacePath': '/repo/app', 'workspaceIdentity': 'app-id'},
      ],
      channelHandler: (channel, method, args) async {
        if (channel == Channels.file) return fileAnswer(method);
        return null;
      },
    );

/// Opens a fresh [TaskSearchPage] through a real navigator and reports
/// whether the 文件 tab rendered.
Future<bool> pumpsFilesTab(WidgetTester tester, FakeDeviceSession session,
    {String initialQuery = ''}) async {
  await tester.pumpWidget(wrap(host(
    (_) => TaskSearchPage(
      session: session,
      onOpenTask: (_, __) {},
      onOpenCommand: (_) {},
    ),
  )));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  if (initialQuery.isNotEmpty) {
    await tester.enterText(find.byType(TextField), initialQuery);
    await tester.pumpAndSettle();
  }
  return find.text('文件').evaluate().isNotEmpty;
}

void main() {
  testWidgets('file tab miss stays hidden (design D7/Q7)', (tester) async {
    // Both methods miss (pre-listing desktop) → the tab never renders,
    // and the 全部 tab's file section degrades with it.
    expect(
      await pumpsFilesTab(
        tester,
        fileProbeSession(
          fileAnswer: (m) async =>
              throw ChannelRpcError('no such method: $m', null),
        ),
      ),
      isFalse,
    );
    expect(find.byType(Tab), findsNWidgets(3));
  });

  testWidgets('a positive probe adds the files tab (searchWorkspaceFiles '
      'answers)', (tester) async {
    expect(
      await pumpsFilesTab(
        tester,
        fileProbeSession(
          fileAnswer: (m) async =>
              m == 'searchWorkspaceFiles' ? <dynamic>[] : null,
        ),
      ),
      isTrue,
    );
    expect(find.byType(Tab), findsNWidgets(4));
  });

  testWidgets('actions tab: contains filter and selection pre-fills a new '
      'chat with the insert text', (tester) async {
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: RemoteConnectionParams.parse(
              'https://zcode.z.ai/remote/v4?sid=a&hash=b&t=1&mid=m&name=n&app_version=3')!,
      entries: const [],
      workspaces: const [],
    );
    SlashItem? picked;
    await tester.pumpWidget(wrap(host(
      (_) => TaskSearchPage(
        session: session,
        onOpenTask: (_, __) {},
        onOpenCommand: (item) => picked = item,
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // The all tab also renders an 操作 section header — target the tab.
    await tester.tap(find.descendant(
      of: find.byType(TabBar),
      matching: find.text('操作'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('/compact'), findsOneWidget);

    // contains matching on name/description (the retired sheet's口径).
    await tester.enterText(find.byType(TextField), '压缩');
    await tester.pumpAndSettle();
    expect(find.text('/compact'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'nomatch-here');
    await tester.pumpAndSettle();
    expect(find.text('/compact'), findsNothing);
    expect(find.text('没有匹配的结果'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'compact');
    await tester.pumpAndSettle();
    await tester.tap(find.text('/compact'));
    await tester.pumpAndSettle();

    expect(picked, isNotNull);
    expect(picked!.insert, '/compact ');
  });

  testWidgets('tasks tab: title hits with highlight; tap '
      'hands the entry to the host', (tester) async {
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: RemoteConnectionParams.parse(
              'https://zcode.z.ai/remote/v4?sid=a&hash=b&t=1&mid=m&name=n&app_version=3')!,
      entries: [
        {
          'sessionId': 's1',
          'title': '修复登录页',
          'phase': 'running',
          'lastActivityAt': DateTime.now().millisecondsSinceEpoch,
        },
        {
          'sessionId': 's2',
          'title': '写周报',
          'phase': 'completedSuccess',
          'lastActivityAt': DateTime.now().millisecondsSinceEpoch - 1000,
        },
      ],
      workspaces: [
        {'workspacePath': '/repo/app', 'workspaceIdentity': 'app-id'},
      ],
    );

    SessionEntry? opened;
    Map<String, dynamic>? openedWs;
    await tester.pumpWidget(wrap(host(
      (_) => TaskSearchPage(
        session: session,
        onOpenTask: (entry, ws) {
          opened = entry;
          openedWs = ws;
        },
        onOpenCommand: (_) {},
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(
      of: find.byType(TabBar),
      matching: find.text('任务'),
    ));
    await tester.pumpAndSettle();
    // Empty query lists the recent tasks (palette-style baseline). Task
    // titles render as RichText (highlight spans) — findRichText needed.
    expect(find.text('修复登录页', findRichText: true), findsOneWidget);
    expect(find.text('写周报', findRichText: true), findsOneWidget);

    // Title hit: the match segment carries the highlight span.
    await tester.enterText(find.byType(TextField), '登录');
    await tester.pumpAndSettle();
    expect(find.text('修复登录页', findRichText: true), findsOneWidget);
    expect(find.text('写周报', findRichText: true), findsNothing);

    // Clear the query: the baseline list returns (title-only matching).
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(find.text('写周报', findRichText: true), findsOneWidget);

    await tester.tap(find.text('写周报', findRichText: true));
    await tester.pumpAndSettle();
    expect(opened, isNotNull);
    expect(opened!.sessionId, 's2');
    expect(openedWs, isNotNull,
        reason: 'the workspace scope resolves like the task list rows');
  });

  testWidgets('all tab: matched sections render with headers', (tester) async {
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: RemoteConnectionParams.parse(
              'https://zcode.z.ai/remote/v4?sid=a&hash=b&t=1&mid=m&name=n&app_version=3')!,
      entries: [
        {
          'sessionId': 's1',
          'title': 'compact 报告',
          'phase': 'running',
          'lastActivityAt': DateTime.now().millisecondsSinceEpoch,
        },
      ],
      workspaces: const [],
    );
    await tester.pumpWidget(wrap(host(
      (_) => TaskSearchPage(
        session: session,
        onOpenTask: (_, __) {},
        onOpenCommand: (_) {},
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'compact');
    await tester.pumpAndSettle();

    // Both sources hit → both sections with their headers, tasks first
    // (official palette order). Section headers live in the list; the tab
    // labels duplicate the same strings.
    expect(
      find.descendant(of: find.byType(ListView), matching: find.text('任务')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.byType(ListView), matching: find.text('操作')),
      findsOneWidget,
    );
    expect(find.text('compact 报告', findRichText: true), findsOneWidget);
    expect(find.text('/compact'), findsOneWidget);

    // Nothing anywhere → the shared empty note.
    await tester.enterText(find.byType(TextField), 'zzz-nothing');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的结果'), findsOneWidget);
  });
}
