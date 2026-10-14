import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/ui/chat/chat_page.dart';
import 'package:zgo/ui/chat/markdown_view.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../../helpers/recording_chat_gateway.dart';

class FakeChatGateway extends RecordingChatGateway {}

Widget wrap(Widget child) => MaterialApp(
      theme: buildDarkTheme(),
      darkTheme: buildDarkTheme(),
      builder: (context, child) =>
          UiSettingsProvider(settings: UiSettings(), child: child!),
      home: child,
    );

/// The fenced code block's outer container (the only widget with the
/// vertical seam margin inside the markdown layer).
Finder codeBlock() => find.byWidgetPredicate(
      (w) => w is Container && w.margin == const EdgeInsets.symmetric(vertical: 6),
    );

/// The chat-tile head container inside the code block header.
Finder codeHead() => find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.padding == ZTile.head &&
          w.constraints == const BoxConstraints(minHeight: ZTile.headHeight),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpConversation(WidgetTester tester, String text) async {
    tester.view.devicePixelRatio = 3.75;
    tester.view.physicalSize = const Size(1440, 2560);
    addTearDown(tester.view.reset);
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
      {'rowId': 2, 'kind': 'assistantText', 'text': text},
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('fenced code block spans the full column inside the assistant '
      'bubble (10-14 batch add-on)', (tester) async {
    const longWord = 'Supercalifragilisticexpialidocious_but_unbreakable_long_word';
    await pumpConversation(
      tester,
      '$longWord\n\n```dart\nvoid main() {}\n```\n\nafter',
    );

    // 384dp logical width, 16dp list padding.
    const listPad = 16.0;
    final blockBox = tester.renderObject<RenderBox>(codeBlock());
    final blockLeft = blockBox.localToGlobal(Offset.zero).dx;

    // The prose paragraph directly above the block (the user bubble's
    // SelectableText sits to the right; the trailing paragraph below).
    final blockTop = blockBox.localToGlobal(Offset.zero).dy;
    final proseBox = find
        .byType(SelectableText)
        .evaluate()
        .map((el) => tester.renderObject<RenderBox>(find.byWidget(el.widget)))
        .where((b) => b.localToGlobal(Offset.zero).dy < blockTop)
        .reduce((a, b) =>
            a.localToGlobal(Offset.zero).dy > b.localToGlobal(Offset.zero).dy
                ? a
                : b);
    // Left edge aligns with the prose text left edge (the list padding).
    expect(proseBox.localToGlobal(Offset.zero).dx, blockLeft);
    expect(blockLeft, listPad);

    // Right edge reaches the list padding line — the same right edge the
    // reasoning/tool cards span, i.e. 24dp past the old bubble margin.
    expect(blockLeft + blockBox.size.width, 384 - listPad);

    // Prose keeps its 24dp wrap inset (formerly the bubble margin), so the
    // unbreakable word's box stops 24dp short of the column edge.
    expect(proseBox.size.width, 384 - 2 * listPad - 24);

    // Header follows the shared chat-tile head geometry.
    final headBox = tester.renderObject<RenderBox>(codeHead());
    expect(headBox.size.height, greaterThanOrEqualTo(ZTile.headHeight));

    // Expanded body is full-bleed too: the horizontal scroll view spans
    // the block, not a narrowed inset.
    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pumpAndSettle();
    final bodyScroll = tester.renderObject<RenderBox>(
      find.descendant(
        of: codeBlock(),
        matching: find.byType(SingleChildScrollView),
      ),
    );
    // The body sits inside the block's 1dp hairline border.
    expect(bodyScroll.localToGlobal(Offset.zero).dx,
        blockBox.localToGlobal(Offset.zero).dx + 1);
    expect(bodyScroll.size.width, blockBox.size.width - 2);
  });

  testWidgets('bare AppMarkdown stays full-bleed without proseRightInset '
      '(reasoning strip / inline preview call sites)', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(384, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(
      Scaffold(
        body: Center(
          child: SizedBox(
            width: 300,
            child: const AppMarkdown('some prose line\n\n```js\nx();\n```'),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final proseBox =
        tester.renderObject<RenderBox>(find.byType(SelectableText).first);
    // No trailing inset: the long-ish line is capped only by the container.
    final blockBox = tester.renderObject<RenderBox>(codeBlock());
    expect(proseBox.localToGlobal(Offset.zero).dx,
        blockBox.localToGlobal(Offset.zero).dx);
    // Wrap width == container width (300): prose wraps at the same edge the
    // code block does when no proseRightInset is requested.
    expect(proseBox.size.width, lessThanOrEqualTo(300));
    expect(blockBox.size.width, 300);
  });
}
