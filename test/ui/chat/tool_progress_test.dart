// Task 11-04-tool-progress-adapt (step 4): the 3.17.2 row-progress surface
// rendered through the shared timeline module.
//
// A2 — the legacy `{bytes, previewLine}` shape keeps rendering, while the new
//      independent-segment shape (message / total / fraction) never invents a
//      "0.0 KB" default when the bytes key is absent.
// A3 — the Bash tail preview mounts only in the expanded state, shows the
//      last 2 lines of `outputPreview.text` bottom-aligned, expands to 5 from
//      its own toggle (the count keeps its place), and renders sanitized text
//      (ANSI CSI stripped, CR redraws collapsed).
// A6 — settlement flips preview → full output by direct condition swap: every
//      frame of the transition keeps one of the two visible, with no KB line.
// B2 — the terminal group card is a two-layer collapse: head ①⇄②, tail row
//      ②→③, last running detail row ③→②, head in ③ 全收起.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/conversation_state.dart';
import 'package:zgo/ui/chat/timeline.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../../helpers/chat_role_fakes.dart';

Widget wrap(Widget child, {String locale = 'zh-CN'}) => MaterialApp(
  theme: buildDarkTheme(),
  builder: (context, child) => UiSettingsProvider(
    settings: UiSettings()..locale = locale,
    child: child!,
  ),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

ConversationState _stateWith(List<Map<String, dynamic>> rows) =>
    ConversationState()..rows = rows;

Widget _chatRow(Map<String, dynamic> row, {ConversationState? state}) {
  final recording = RecordingCalls();
  return ChatRow(
    row: row,
    conversation: FakeConversation(recording),
    sessionId: 's1',
    onAction: (_, __) async {},
    state: state ?? _stateWith([row]),
    preview: ChatPreview(FakeWorkspaceContext(recording)),
  );
}

Map<String, dynamic> _bashRow({
  String status = 'running',
  Map<String, dynamic>? outputPreview,
  Map<String, dynamic>? output,
  Map<String, dynamic>? progress,
}) => {
  'rowId': 1,
  'kind': 'toolCall',
  'toolName': 'Bash',
  'status': status,
  'inputText': '{"command":"npm run build"}',
  if (outputPreview != null) 'outputPreview': outputPreview,
  if (output != null) 'output': output,
  if (progress != null) 'progress': progress,
};

Map<String, dynamic> _globRow({
  String status = 'running',
  Map<String, dynamic>? progress,
}) => {
  'rowId': 2,
  'kind': 'toolCall',
  'toolName': 'Glob',
  'status': status,
  'inputText': '{"pattern":"**/*.dart","path":"lib"}',
  if (progress != null) 'progress': progress,
};

void main() {
  group('A2 independent progress segments', () {
    testWidgets('legacy bytes + previewLine keeps the old single line', (
      tester,
    ) async {
      final row = _globRow(
        progress: {'bytes': 2048, 'previewLine': 'streaming line'},
      );
      await tester.pumpWidget(wrap(_chatRow(row)));

      expect(find.text('streaming line · 2.0 KB'), findsOneWidget);
    });

    testWidgets('message-only never renders a KB default', (tester) async {
      final row = _globRow(progress: {'message': '扫描协议层方法名引用…'});
      await tester.pumpWidget(wrap(_chatRow(row)));

      expect(find.text('扫描协议层方法名引用…'), findsOneWidget);
      expect(find.textContaining('KB'), findsNothing);
    });

    testWidgets('fraction renders the rounded percent and the total', (
      tester,
    ) async {
      final row = _globRow(
        progress: {
          'fraction': 0.4167,
          'total': 120,
          'message': '已完成 50/120 个文件',
        },
      );
      await tester.pumpWidget(wrap(_chatRow(row)));

      expect(find.text('42%'), findsOneWidget);
      expect(find.text('共 120'), findsOneWidget);
      expect(find.text('已完成 50/120 个文件'), findsOneWidget);
      expect(find.textContaining('KB'), findsNothing);
    });

    testWidgets('all-absent progress renders no row at all', (tester) async {
      final row = _globRow(progress: const {});
      await tester.pumpWidget(wrap(_chatRow(row)));

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining('KB'), findsNothing);
    });
  });

  group('A3 bash tail preview', () {
    Map<String, dynamic> preview(String text, {int totalLines = 412}) => {
      'text': text,
      'fullText': text,
      'totalLines': totalLines,
      'totalBytes': 18842,
      'linesEstimated': false,
    };

    testWidgets('collapsed card mounts no preview area', (tester) async {
      final row = _bashRow(outputPreview: preview('l1\nl2\nDownloading'));
      await tester.pumpWidget(wrap(_chatRow(row)));

      expect(find.textContaining('Downloading'), findsNothing);
    });

    testWidgets('expanded shows the last 2 lines, toggle lifts it to 5', (
      tester,
    ) async {
      final row = _bashRow(
        outputPreview: preview('line1\nline2\nline3\nline4\nDownloading'),
      );
      await tester.pumpWidget(wrap(_chatRow(row)));

      await tester.tap(find.textContaining('终端 ·'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Bottom-aligned window: the newest two lines only.
      expect(find.text('line4'), findsOneWidget);
      expect(find.text('Downloading'), findsOneWidget);
      expect(find.text('line1'), findsNothing);
      expect(find.text('…共 412 行'), findsOneWidget);

      await tester.tap(find.text('展开 5 行'));
      await tester.pump();

      expect(find.text('line1'), findsOneWidget);
      expect(find.text('line4'), findsOneWidget);
      expect(find.text('…共 412 行'), findsOneWidget);

      await tester.tap(find.text('收起 5 行'));
      await tester.pump();
      expect(find.text('line1'), findsNothing);
    });

    testWidgets('preview text is sanitized: CSI stripped, CR collapsed', (
      tester,
    ) async {
      final row = _bashRow(
        outputPreview: preview(
          '\u001b[32mPASS\u001b[0m test/a\ndownload 10%\rdownload 100%',
        ),
      );
      await tester.pumpWidget(wrap(_chatRow(row)));

      await tester.tap(find.textContaining('终端 ·'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('PASS test/a'), findsOneWidget);
      expect(find.text('download 100%'), findsOneWidget);
      // Neither the escape raw bytes nor the redrawn-away segment render.
      expect(find.textContaining('\u001b'), findsNothing);
      expect(find.textContaining('download 10%'), findsNothing);
    });
  });

  group('A6 settlement fallback', () {
    testWidgets('preview swaps to the full output with no blank frame', (
      tester,
    ) async {
      var row = _bashRow(
        status: 'running',
        outputPreview: {
          'text': 'line\nDownloading 128/128 (100%)',
          'totalLines': 412,
        },
      );
      late StateSetter setRow;
      await tester.pumpWidget(
        wrap(
          StatefulBuilder(
            builder: (context, setState) {
              setRow = setState;
              return _chatRow(row, state: _stateWith([row]));
            },
          ),
        ),
      );

      await tester.tap(find.textContaining('终端 ·'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Downloading 128/128 (100%)'), findsOneWidget);

      // The settle upsert strips outputPreview and lands the full output.
      setRow(() {
        row = _bashRow(
          status: 'success',
          output: {'text': 'Build succeeded'},
        );
      });

      for (var frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        final previewVisible =
            find.textContaining('Downloading 128/128').evaluate().isNotEmpty;
        final outputVisible =
            find.textContaining('Build succeeded').evaluate().isNotEmpty;
        expect(
          previewVisible || outputVisible,
          isTrue,
          reason: 'frame $frame: preview and full output both vanished',
        );
        expect(
          find.textContaining('KB').evaluate(),
          isEmpty,
          reason: 'frame $frame: a KB default leaked during settlement',
        );
      }
      expect(find.textContaining('Build succeeded'), findsOneWidget);
    });
  });

  group('B2 terminal group double collapse', () {
    List<Map<String, dynamic>> groupRows() => [
      {
        'rowId': 1,
        'kind': 'toolCall',
        'toolName': 'Bash',
        'status': 'success',
        'inputText': '{"command":"npm run lint"}',
      },
      {
        'rowId': 2,
        'kind': 'toolCall',
        'toolName': 'Bash',
        'status': 'success',
        'inputText': '{"command":"flutter analyze"}',
      },
      {
        'rowId': 3,
        'kind': 'toolCall',
        'toolName': 'Bash',
        'status': 'running',
        'inputText': '{"command":"npm run build"}',
        'outputPreview': {
          'text': 'compiling\nDownloading 128/128 (100%)',
          'totalLines': 412,
        },
      },
    ];

    Future<void> pumpGroup(WidgetTester tester, List<Map<String, dynamic>> rows) {
      final recording = RecordingCalls();
      return tester.pumpWidget(
        wrap(
          ToolGroupCard(
            rows: rows,
            conversation: FakeConversation(recording),
            sessionId: 's1',
            onAction: (_, __) async {},
            state: _stateWith(rows),
            preview: ChatPreview(FakeWorkspaceContext(recording)),
          ),
        ),
      );
    }

    testWidgets('head ①⇄②, tail ②→③, tail-in-③ →②, head ③→①', (
      tester,
    ) async {
      final rows = groupRows();
      await pumpGroup(tester, rows);

      // ① collapsed: header only, no tail, no command detail.
      expect(find.textContaining('终端 · 3 个命令'), findsOneWidget);
      expect(find.text('Downloading 128/128 (100%)'), findsNothing);
      expect(find.text('终端 · npm run lint'), findsNothing);

      // ② head tap surfaces the tail line of the last running row.
      await tester.tap(find.textContaining('终端 · 3 个命令'));
      await tester.pump();
      expect(find.text('Downloading 128/128 (100%)'), findsOneWidget);
      expect(find.text('终端 · npm run lint'), findsNothing);

      // ③ the tail row itself opens the command detail, and the same tail
      //    sinks into the last running row — shown once, never twice.
      await tester.tap(find.text('Downloading 128/128 (100%)'));
      await tester.pump();
      expect(find.text('终端 · npm run lint'), findsOneWidget);
      expect(find.text('终端 · flutter analyze'), findsOneWidget);
      expect(find.text('终端 · npm run build'), findsOneWidget);
      expect(find.text('Downloading 128/128 (100%)'), findsOneWidget);

      // ③ → ② the tail under the last running row collapses the detail.
      await tester.tap(find.text('Downloading 128/128 (100%)'));
      await tester.pump();
      expect(find.text('终端 · npm run lint'), findsNothing);
      expect(find.text('Downloading 128/128 (100%)'), findsOneWidget);

      // ② → ① head tap collapses everything.
      await tester.tap(find.textContaining('终端 · 3 个命令'));
      await tester.pump();
      expect(find.text('Downloading 128/128 (100%)'), findsNothing);
    });

    testWidgets('head in ③ collapses all layers at once', (tester) async {
      final rows = groupRows();
      await pumpGroup(tester, rows);

      await tester.tap(find.textContaining('终端 · 3 个命令'));
      await tester.pump();
      await tester.tap(find.text('Downloading 128/128 (100%)'));
      await tester.pump();
      expect(find.text('终端 · npm run lint'), findsOneWidget);

      await tester.tap(find.textContaining('终端 · 3 个命令'));
      await tester.pump();
      expect(find.text('终端 · npm run lint'), findsNothing);
      expect(find.text('Downloading 128/128 (100%)'), findsNothing);
    });

    testWidgets('no running preview: head goes straight to the detail', (
      tester,
    ) async {
      final rows = <Map<String, dynamic>>[
        for (final row in groupRows())
          if (row['status'] != 'running') row,
      ];
      await pumpGroup(tester, rows);

      await tester.tap(find.textContaining('终端 · 2 个命令'));
      await tester.pump();
      // No tail layer exists → the commands are reachable in one tap.
      expect(find.text('终端 · npm run lint'), findsOneWidget);
      expect(find.text('终端 · flutter analyze'), findsOneWidget);
    });

    // P2-2: the collapse affordances must stay discoverable to screen
    // readers — head flips `expanded` with the layer, both tail strips are
    // always buttons.
    testWidgets('semantics lock: head flips expanded, tails stay buttons', (
      tester,
    ) async {
      Finder semanticsAround(Finder text, {required bool expanded}) =>
          find.ancestor(
            of: text,
            matching: find.byWidgetPredicate(
              (w) => w is Semantics &&
                  w.properties.button == true &&
                  w.properties.expanded == expanded,
            ),
          );

      final rows = groupRows();
      await pumpGroup(tester, rows);

      final head = find.textContaining('终端 · 3 个命令');
      expect(semanticsAround(head, expanded: false), findsOneWidget);

      await tester.tap(head);
      await tester.pump();
      expect(semanticsAround(head, expanded: true), findsOneWidget);
      final tail = find.text('Downloading 128/128 (100%)');
      expect(semanticsAround(tail, expanded: false), findsOneWidget);

      await tester.tap(tail);
      await tester.pump();
      expect(semanticsAround(tail, expanded: true), findsOneWidget);
    });
  });

  // P2-2: the new surfaces must render from the en table too — a missing
  // key would silently fall back to the key itself.
  group('en table renders the same surfaces', () {
    testWidgets('progress segments and preview strings in en-US', (
      tester,
    ) async {
      final row = _globRow(
        progress: {'fraction': 0.4167, 'total': 120, 'message': 'scanning'},
      );
      await tester.pumpWidget(wrap(_chatRow(row), locale: 'en-US'));

      expect(find.text('42%'), findsOneWidget);
      expect(find.text('120 total'), findsOneWidget);
      expect(find.text('scanning'), findsOneWidget);

      final bash = _bashRow(
        outputPreview: {
          'text': 'line1\nline2\nline3\nline4\nDownloading',
          'totalLines': 412,
        },
      );
      await tester.pumpWidget(wrap(_chatRow(bash), locale: 'en-US'));

      await tester.tap(find.textContaining('Terminal ·'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('line4'), findsOneWidget);
      expect(find.text('…412 lines total'), findsOneWidget);

      await tester.tap(find.text('Show 5 lines'));
      await tester.pump();
      expect(find.text('line1'), findsOneWidget);
      expect(find.text('Show fewer lines'), findsOneWidget);
    });
  });
}
