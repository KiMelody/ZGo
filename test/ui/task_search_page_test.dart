import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/protocol/connection_params.dart';
import 'package:zgo/ui/chat/file_preview_page.dart';
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

/// S7 file-tab fixture: the file channel answers the reachability probe and
/// the query-filtered search from [rows] (`{name, path, relativePath,
/// type}`, the desktop row shape); [answer] serves every other method
/// (the read family) — null when absent.
FakeDeviceSession fileTabSession(
  List<Map<String, dynamic>> rows, {
  Future<dynamic> Function(String method, Object? arg)? answer,
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
        if (channel != Channels.file) return null;
        final arg = args.isEmpty ? null : args.first;
        if (method == 'searchWorkspaceFiles') {
          final q = arg is Map ? '${arg['query'] ?? ''}' : '';
          return [
            for (final row in rows)
              if (q.isEmpty || '${row['relativePath']}'.contains(q)) row,
          ];
        }
        return answer == null ? null : answer(method, arg);
      },
    );

Map<String, dynamic> fileRow(String relative, {bool dir = false}) => {
      'name': relative.split('/').last,
      'path': '/repo/app/$relative',
      'relativePath': relative,
      'type': dir ? 'directory' : 'file',
    };

/// Opens the page, lands on the 文件 tab (the probe grows it in) and runs
/// [query] through the debounced search (the 250ms timer needs real clock
/// movement — `pumpAndSettle` alone never fires it).
Future<void> pumpFileTab(WidgetTester tester, FakeDeviceSession session,
    {String query = ''}) async {
  await tester.pumpWidget(wrap(host(
    (_) => TaskSearchPage(
      session: session,
      onOpenTask: (_, __) {},
      onOpenCommand: (_) {},
    ),
  )));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await tester.tap(find.descendant(
    of: find.byType(TabBar),
    matching: find.text('文件'),
  ));
  await tester.pumpAndSettle();
  if (query.isNotEmpty) {
    await tester.enterText(find.byType(TextField), query);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
  }
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

  group('file tab preview dispatch (S7/R8)', () {
    testWidgets('a file row dispatches through the shared routing table '
        '(md → markdown render kind)', (tester) async {
      final session = fileTabSession(
        [fileRow('docs/report.md')],
        answer: (method, arg) async {
          if (method != 'readTextFile') return null;
          return {
            'content': 'report body',
            'offset': 0,
            'bytesRead': 11,
            'totalBytes': 11,
            'truncated': false,
          };
        },
      );
      await pumpFileTab(tester, session, query: 'report');

      expect(find.widgetWithText(ListTile, 'docs/report.md'), findsOneWidget);
      await tester.tap(find.widgetWithText(ListTile, 'docs/report.md'));
      await tester.pumpAndSettle();

      // The md extension routes through ChatPreview.open's table — the
      // same one the chat rows dispatch through.
      expect(find.byType(FilePreviewPage), findsOneWidget);
      expect(
        tester.widget<FilePreviewPage>(find.byType(FilePreviewPage)).render,
        FilePreviewRender.markdown,
      );
      expect(
        session.channelCalls
            .where((c) => c.$2 == 'readTextFile')
            .map((c) => (c.$3.first as Map)['path'])
            .toList(),
        ['/repo/app/docs/report.md'],
      );
    });

    testWidgets('directory rows stay inert (R8/M3)', (tester) async {
      final session = fileTabSession([
        fileRow('src', dir: true),
        fileRow('src/main.dart'),
      ]);
      await pumpFileTab(tester, session, query: 'src');

      // Both rows rendered (the directory and its child file).
      expect(find.widgetWithText(ListTile, 'src'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'src/main.dart'), findsOneWidget);
      await tester.tap(find.widgetWithText(ListTile, 'src'));
      await tester.pumpAndSettle();

      // No preview surface and no read: a directory never enters the
      // fallback dispatch (its missing extension would wave it through).
      expect(find.byType(FilePreviewPage), findsNothing);
      expect(session.channelCalls.where((c) => c.$2 == 'readTextFile'),
          isEmpty);
    });

    testWidgets('a blacklisted file row still opens and lands on the '
        'read\'s honest verdict (design §6: only directories are excluded)',
        (tester) async {
      final session = fileTabSession(
        [fileRow('bundle.zip')],
        answer: (method, arg) async {
          if (method != 'readTextFile') return null;
          return {
            'content': '',
            'isBinary': true,
            'bytesRead': 0,
            'totalBytes': 2048,
            'truncated': false,
          };
        },
      );
      await pumpFileTab(tester, session, query: 'bundle');

      expect(find.widgetWithText(ListTile, 'bundle.zip'), findsOneWidget);
      await tester.tap(find.widgetWithText(ListTile, 'bundle.zip'));
      await tester.pumpAndSettle();

      // Ungated like the markdown-link family: a tapped row is explicit
      // intent, so the wire's binary sniff decides the copy.
      expect(find.byType(FilePreviewPage), findsOneWidget);
      expect(find.text('二进制文件，无文本预览'), findsOneWidget);
    });
  });

  // ---------------------------------------------------- keyboard / focus

  /// Keyboard regression net beyond the chat page (task 11-06 IM-D-03):
  /// the search field must keep focus while the IME shrinks the viewport
  /// and the conditional tab subtree grows (the 文件 tab's `if (filesTab)`
  /// children appear only on a positive probe verdict — 3 → 4 tabs, the
  /// TabBar and TabBarView remount behind `ValueKey(_tabs.length)`) — the
  /// same remount-on-reorder shape that made the chat composer drop focus
  /// (chat-conventions §8 契约一).
  ///
  /// The recipe is the repo's settled one: explicit `physicalSize` +
  /// `devicePixelRatio` so the layout has a real height, `viewInsets` for
  /// the IME (`FakeViewPadding`, the real view — a tree-injected MediaQuery
  /// would not resize the Scaffold), then a SIZE PROBE proving the keyboard
  /// branch actually ran before any focus assertion is trusted
  /// (green-means-tested: an inset that never reached the tree passes
  /// silently).
  testWidgets(
      'keyboard shrink keeps the search field focused across conditional '
      'tab growth', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // The reachability probe is held until the keyboard is up, so the
    // conditional growth lands mid-keyboard — after the field took focus.
    final probeGate = Completer<void>();
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: RemoteConnectionParams.parse(
          'https://zcode.z.ai/remote/v4?sid=a&hash=b&t=1&mid=m&name=n&app_version=3')!,
      entries: const [],
      workspaces: [
        {'workspacePath': '/repo/app', 'workspaceIdentity': 'app-id'},
      ],
      channelHandler: (channel, method, args) async {
        if (channel != Channels.file) return null;
        if (method != 'searchWorkspaceFiles') return null;
        final arg = args.isEmpty ? null : args.first;
        final q = arg is Map ? '${arg['query'] ?? ''}' : '';
        if (q.isEmpty) {
          // The limit-1 empty-query reachability probe.
          await probeGate.future;
          return <dynamic>[];
        }
        return <dynamic>[if (q.contains('report')) fileRow('docs/report.md')];
      },
    );
    addTearDown(() => session.dispose());

    await tester.pumpWidget(wrap(host(
      (_) => TaskSearchPage(
        session: session,
        onOpenTask: (_, __) {},
        onOpenCommand: (_) {},
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // Probe still in flight: the 文件 tab has not grown in yet.
    expect(find.byType(Tab), findsNWidgets(3));

    // `autofocus: true` took the field on open — the focus this test then
    // pins across the keyboard dance. The page owns no FocusNode, so the
    // live node is the field's inner EditableText one.
    final field = find.byType(TextField).first;
    FocusNode nodeOf() => tester
        .widget<EditableText>(
          find.descendant(of: field, matching: find.byType(EditableText)),
        )
        .focusNode;
    expect(tester.widget<TextField>(field).autofocus, isTrue);
    final focusedBefore = FocusManager.instance.primaryFocus;
    expect(nodeOf().hasFocus, isTrue);
    expect(focusedBefore, isNotNull);

    // Resting geometry of the results viewport — the TabBarView fills the
    // body's Expanded, so its height tracks the Scaffold's resize (the
    // search row itself is pinned to the top and never moves).
    Size resultsProbe() => tester.getSize(find.byType(TabBarView));
    final restingResults = resultsProbe();

    // Raise the IME the way the real view does: the viewport shrinks and
    // the Scaffold resizes its body.
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // SIZE PROBE: the keyboard branch is provably live — the body lost
    // most of the inset, so the focus assertion below is meaningful.
    expect(restingResults.height - resultsProbe().height, greaterThan(100));

    // The verdict lands mid-keyboard: the 文件 tab grows in, remounting
    // both the TabBar and the TabBarView (the keyed controller swap).
    probeGate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(Tab), findsNWidgets(4));

    // Typing then reshapes the results subtree again: the debounced file
    // search replaces the empty note with the matching row.
    await tester.enterText(field, 'report');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(FocusManager.instance.primaryFocus, same(focusedBefore));
    expect(nodeOf().hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  });
}
