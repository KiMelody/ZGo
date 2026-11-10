// Task 11-08-error-detail: 错误透传 — one-line preview + detail sheet.
//
// Locks the three surfaces the PRD's ACs cover:
//   AC1/AC2 — the errored turn's preview line: renders only for a terminal
//             error phase WITH a non-blank message, sits under the pill,
//             keeps the turn group's row count untouched, and opens the
//             sheet on tap (hit area ≥44×48).
//   AC3     — the zero-row start-failed card: the real message replaces the
//             generic advice and the whole card opens the sheet; without a
//             message the generic copy stays and the card stays inert.
//   AC5/AC7 — the sheet renders present fields only (no empty shells) and
//             keeps message/code/attribution/traceId untranslated.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/ui/chat/error_detail_sheet.dart';
import 'package:zgo/ui/chat/subagent_feed.dart';
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

List<Map<String, dynamic>> turnRows({
  String phase = 'error',
  int id = 1,
}) =>
    [
      {'rowId': id, 'kind': 'userInput', 'text': '换个模型再试'},
      {
        'rowId': id + 1,
        'kind': 'assistantText',
        'text': '已把 fallback 接到旧字段。',
      },
      {'rowId': id + 2, 'kind': 'turnHeader', 'state': phase},
    ];

const fullError = <String, dynamic>{
  'message': '429 Rate limit exceeded: quota exhausted for glm-4.7 on '
      'individual plan (retry after 32s)',
  'code': '429',
  'traceId': 'trc_9f2ka81x',
  'attribution': 'provider',
};

/// One turn group through the shared renderer — the surface the page hands
/// the task row's lastError to.
Widget turnGroup({
  Map<String, dynamic>? lastError,
  List<Map<String, dynamic>>? rows,
  bool readOnly = false,
  Duration confirmWindow = Duration.zero,
}) {
  final recording = RecordingCalls();
  final conversation = FakeConversation(recording);
  return ChatTurnGroup(
    key: const ValueKey('turn-1'),
    rows: rows ?? turnRows(),
    conversation: conversation,
    sessionId: 's1',
    onAction: (_, __) async {},
    state: conversation.state,
    feed: SubagentFeed(conversation: conversation),
    preview: ChatPreview(FakeWorkspaceContext(recording)),
    confirmWindow: confirmWindow,
    readOnly: readOnly,
    lastError: lastError,
  );
}

void main() {
  group('AC1 turn error preview line', () {
    testWidgets('an errored turn with a message renders one danger line '
        'under the pill', (tester) async {
      await tester.pumpWidget(wrap(turnGroup(lastError: fullError)));
      await tester.pump();

      expect(find.text('出错'), findsOneWidget);
      expect(find.textContaining('429 Rate limit exceeded'), findsOneWidget);
      // Danger tone + the 12px tier, single line with ellipsis.
      final text = tester.widget<Text>(
        find.textContaining('429 Rate limit exceeded'),
      );
      expect(text.maxLines, 1);
      expect(text.overflow, TextOverflow.ellipsis);
      expect(text.style!.fontSize, ZType.sub.fontSize);
      expect(
        text.style!.color,
        ZInk.dangerTone(tester.element(find.byType(ChatTurnGroup))),
      );
    });

    testWidgets('a running / completed turn never renders the preview — '
        'it belongs to the error phase only', (tester) async {
      for (final phase in ['running', 'completedSuccess']) {
        await tester.pumpWidget(
          wrap(turnGroup(lastError: fullError, rows: turnRows(phase: phase))),
        );
        await tester.pump();
        expect(
          find.textContaining('429 Rate limit exceeded'),
          findsNothing,
          reason: 'phase=$phase',
        );
      }
    });

    testWidgets('failed counts as the error phase', (tester) async {
      await tester.pumpWidget(
        wrap(turnGroup(lastError: fullError, rows: turnRows(phase: 'failed'))),
      );
      await tester.pump();
      expect(find.textContaining('429 Rate limit exceeded'), findsOneWidget);
    });

    testWidgets('no lastError / blank message / message-less meta renders no '
        'line (AC1 gate)', (tester) async {
      for (final error in [
        null,
        const <String, dynamic>{},
        const {'message': '   '},
        const {'code': '429'},
      ]) {
        await tester.pumpWidget(wrap(turnGroup(lastError: error)));
        await tester.pump();
        expect(find.byIcon(Icons.error_outline), findsOneWidget,
            reason: 'only the pill glyph: error=$error');
      }
    });

    testWidgets('the preview sits between the pill and the turn body and '
        'adds no stream row', (tester) async {
      // SliverList geometry is the reason this line is a header-layer child:
      // the group's row count and the state's rows stay untouched.
      await tester.pumpWidget(wrap(turnGroup(lastError: fullError)));
      await tester.pump();

      final pillY = tester.getTopLeft(find.text('出错')).dy;
      final lineY =
          tester.getTopLeft(find.textContaining('429 Rate limit exceeded')).dy;
      final bodyY = tester.getTopLeft(find.textContaining('已把 fallback')).dy;
      expect(lineY, greaterThan(pillY));
      expect(lineY, lessThan(bodyY));
    });

    testWidgets('the preview keeps a ≥44×48 hit area while painting a 12px '
        'line (spec interaction-patterns §2)', (tester) async {
      await tester.pumpWidget(wrap(turnGroup(lastError: fullError)));
      await tester.pump();

      final preview = find.textContaining('429 Rate limit exceeded');
      final ink = find
          .ancestor(of: preview, matching: find.byType(InkWell))
          .first;
      final size = tester.getSize(ink);
      expect(size.width, greaterThanOrEqualTo(zTouchWidth));
      expect(size.height, greaterThanOrEqualTo(zTouchHeight));
      // Only the box grows — the line's glyph stays 12 (the phase pill draws
      // the same Icons.error_outline at 10, so scope the lookup to the
      // preview's own InkWell).
      final icon = tester.widget<Icon>(
        find.descendant(of: ink, matching: find.byIcon(Icons.error_outline)),
      );
      expect(icon.size, 12);
    });

    testWidgets('a terminal phase seen on the first build releases the preview '
        'immediately (history / snapshot)', (tester) async {
      await tester.pumpWidget(
        wrap(
          turnGroup(
            lastError: fullError,
            confirmWindow: const Duration(seconds: 3),
          ),
        ),
      );
      await tester.pump();
      expect(find.textContaining('429 Rate limit exceeded'), findsOneWidget);
    });

    testWidgets('a live flip to error is held by the confirm window — the '
        'preview never lands before its pill', (tester) async {
      // Same gate as the phase pill: a bridge replay can flip a live turn
      // terminal for a few seconds, and an error line without its pill would
      // read as a different turn's error.
      await tester.pumpWidget(
        wrap(
          turnGroup(
            rows: turnRows(phase: 'running'),
            lastError: fullError,
            confirmWindow: const Duration(milliseconds: 150),
          ),
        ),
      );
      await tester.pump();
      expect(find.textContaining('429 Rate limit exceeded'), findsNothing);

      await tester.pumpWidget(
        wrap(
          turnGroup(
            rows: turnRows(phase: 'error'),
            lastError: fullError,
            confirmWindow: const Duration(milliseconds: 150),
          ),
        ),
      );
      await tester.pump();
      expect(find.textContaining('429 Rate limit exceeded'), findsNothing,
          reason: 'inside the window the preview stays withheld');

      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('出错'), findsOneWidget);
      expect(find.textContaining('429 Rate limit exceeded'), findsOneWidget);
    });

    testWidgets('tapping the preview opens the detail sheet with the full '
        'text (AC2)', (tester) async {
      await tester.pumpWidget(wrap(turnGroup(lastError: fullError)));
      await tester.pump();

      await tester.tap(find.textContaining('429 Rate limit exceeded'));
      await tester.pumpAndSettle();

      expect(find.byType(ErrorDetailSheet), findsOneWidget);
      expect(find.text('最近一次错误'), findsOneWidget);
      // The preview line still sits behind the sheet — assert the sheet's
      // own copy (body tier) rather than "anywhere on screen".
      expect(
        find.descendant(
          of: find.byType(ErrorDetailSheet),
          matching: find.text(fullError['message']),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(ErrorDetailSheet),
          matching: find.text('429'),
        ),
        findsOneWidget,
      );
      expect(find.text('provider'), findsOneWidget);
      expect(find.text('trc_9f2ka81x'), findsOneWidget);
    });

    testWidgets('readOnly surfaces still show the preview — reading the '
        'error sends nothing', (tester) async {
      await tester.pumpWidget(
        wrap(turnGroup(lastError: fullError, readOnly: true)),
      );
      await tester.pump();
      expect(find.textContaining('429 Rate limit exceeded'), findsOneWidget);
    });
  });

  group('AC5/AC7 detail sheet', () {
    Future<void> pumpSheet(
      WidgetTester tester,
      Map<String, dynamic> error, {
      String locale = 'zh-CN',
    }) async {
      await tester.pumpWidget(
        wrap(ErrorDetailSheet(error: error), locale: locale),
      );
      await tester.pump();
    }

    testWidgets('all fields present: message block + two kv rows + trace row '
        '+ copy button', (tester) async {
      await pumpSheet(tester, fullError);

      expect(find.text('最近一次错误'), findsOneWidget);
      expect(find.textContaining('可能来自其他轮次'), findsOneWidget);
      expect(find.text(fullError['message']), findsOneWidget);
      expect(find.text('code'), findsOneWidget);
      expect(find.text('429'), findsOneWidget);
      expect(find.text('attribution'), findsOneWidget);
      expect(find.text('provider'), findsOneWidget);
      expect(find.text('trc_9f2ka81x'), findsOneWidget);
      expect(find.text('复制 TraceID'), findsOneWidget);
      expect(find.text('复制完整报错'), findsOneWidget);
    });

    testWidgets('message-only meta: no kv rows, no trace row, no empty '
        'shells (AC5)', (tester) async {
      await pumpSheet(tester, const {'message': 'boom'});

      expect(find.text('boom'), findsOneWidget);
      expect(find.text('code'), findsNothing);
      expect(find.text('attribution'), findsNothing);
      expect(find.text('复制 TraceID'), findsNothing);
      // The primary action stays — the message itself is worth copying.
      expect(find.text('复制完整报错'), findsOneWidget);
      expect(find.textContaining('null'), findsNothing);
    });

    testWidgets('blank values render no block at all (AC5)', (tester) async {
      await pumpSheet(tester, const {
        'message': 'boom',
        'code': '  ',
        'attribution': '',
        'traceId': '   ',
      });

      expect(find.text('boom'), findsOneWidget);
      expect(find.text('code'), findsNothing);
      expect(find.text('attribution'), findsNothing);
      expect(find.text('复制 TraceID'), findsNothing);
    });

    testWidgets('code/attribution only (no message): no message block', (
      tester,
    ) async {
      await pumpSheet(tester, const {'code': '429', 'attribution': 'relay'});

      expect(find.text('429'), findsOneWidget);
      expect(find.text('relay'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ErrorDetailSheet),
          matching: find.byType(SingleChildScrollView),
        ),
        findsNothing,
        reason: 'the scrollable message block is the only one on this sheet — '
            'its absence proves no empty tile was reserved',
      );
    });

    testWidgets('the complete-error copy joins every present field', (
      tester,
    ) async {
      String? clipboard;
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (message) async {
        if (message.method == 'Clipboard.setData') {
          clipboard = (message.arguments as Map)['text'] as String?;
        }
        return null;
      });
      addTearDown(() {
        TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      await pumpSheet(tester, fullError);
      await tester.tap(find.text('复制完整报错'));
      await tester.pump();

      expect(
        clipboard,
        '429 — ${fullError['message']}\n'
        'attribution: provider\n'
        'traceId: trc_9f2ka81x',
      );
      expect(find.text('已复制'), findsOneWidget);
    });

    testWidgets('a message-only copy leaves the absent lines out', (
      tester,
    ) async {
      String? clipboard;
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (message) async {
        if (message.method == 'Clipboard.setData') {
          clipboard = (message.arguments as Map)['text'] as String?;
        }
        return null;
      });
      addTearDown(() {
        TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      await pumpSheet(tester, const {'message': 'boom'});
      await tester.tap(find.text('复制完整报错'));
      await tester.pump();

      expect(clipboard, 'boom');
    });

    testWidgets('the TraceID pill copies just the id and toasts', (
      tester,
    ) async {
      String? clipboard;
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (message) async {
        if (message.method == 'Clipboard.setData') {
          clipboard = (message.arguments as Map)['text'] as String?;
        }
        return null;
      });
      addTearDown(() {
        TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      await pumpSheet(tester, fullError);
      await tester.tap(find.text('复制 TraceID'));
      await tester.pump();

      expect(clipboard, 'trc_9f2ka81x');
      expect(find.text('TraceID 已复制'), findsOneWidget);
    });

    testWidgets('en locale renders the English copy, never the raw keys', (
      tester,
    ) async {
      await pumpSheet(tester, fullError, locale: 'en-US');

      expect(find.text('Most recent error'), findsOneWidget);
      expect(find.text('Copy full error'), findsOneWidget);
      expect(find.text('Copy TraceID'), findsOneWidget);
      expect(find.textContaining('chat.error'), findsNothing);
    });
  });

  group('AC3 start-failed card (two states)', () {
    // The page-level states are covered end-to-end in chat_page_test.dart;
    // here the sheet + gate helpers that both entry points share are pinned.
    testWidgets('errorMessageOf gates on a non-blank message string', (
      tester,
    ) async {
      expect(errorMessageOf(null), isNull);
      expect(errorMessageOf(const {}), isNull);
      expect(errorMessageOf(const {'message': ''}), isNull);
      expect(errorMessageOf(const {'message': '  '}), isNull);
      expect(errorMessageOf(const {'message': 42}), isNull);
      expect(errorMessageOf(const {'message': 'boom'}), 'boom');
    });

    test('errorCopyText omits absent fields entirely', () {
      expect(errorCopyText(const {'message': 'boom'}), 'boom');
      expect(errorCopyText(const {'code': '500'}), '500');
      expect(
        errorCopyText(const {'message': 'boom', 'traceId': 'tr-1'}),
        'boom\ntraceId: tr-1',
      );
    });
  });
}