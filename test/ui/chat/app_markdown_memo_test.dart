import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/ui/chat/markdown_view.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

/// Task 11-19 chat-scroll wave 2 step 1: the [AppMarkdown] widget-instance
/// memo. Repeated builds carrying the identical text string must hand back
/// the same [MarkdownBody] instance (zero re-parse); content / style /
/// environment changes must invalidate. The legitimacy of the identity
/// compare is the row instance-immutability contract (chat-conventions §9).

Widget wrap(Widget child, {ThemeData? theme}) => MaterialApp(
  theme: buildDarkTheme(),
  darkTheme: buildDarkTheme(),
  builder: (context, inner) =>
      UiSettingsProvider(settings: UiSettings(), child: inner!),
  // An explicit Theme avoids MaterialApp's 200 ms AnimatedTheme: theme flips
  // land in one frame (the notify + didChangeDependencies are the contract
  // under test, not the animation).
  home: Theme(
    data: theme ?? buildDarkTheme(),
    child: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

/// Rebuild driver: every [ValueNotifier] bump re-invokes [builder] with a
/// FRESH [AppMarkdown] widget instance, forcing the element update (a const
/// widget would be skipped before reaching the state).
Widget driven(ValueNotifier<int> notifier, Widget Function(int n) builder) =>
    ValueListenableBuilder<int>(
      valueListenable: notifier,
      builder: (context, n, _) => builder(n),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => debugMarkdownBodiesBuilt = 0);

  testWidgets('identical text across rebuilds keeps the MarkdownBody instance',
      (tester) async {
    const text = 'Hello **world**, see `doThing()`.';
    final notifier = ValueNotifier<int>(0);
    await tester.pumpWidget(wrap(driven(notifier, (_) => AppMarkdown(text))));
    final first = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    expect(debugMarkdownBodiesBuilt, 1);

    for (var i = 0; i < 3; i++) {
      notifier.value++;
      await tester.pump();
      final current = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
      expect(identical(first, current), isTrue,
          reason: 'same text instance + same params → cached subtree');
    }
    expect(debugMarkdownBodiesBuilt, 1,
        reason: 'repeated rebuilds must not re-parse the markdown');
  });

  testWidgets('a new text string invalidates the memo', (tester) async {
    final notifier = ValueNotifier<int>(0);
    await tester.pumpWidget(wrap(driven(
      notifier,
      (n) => AppMarkdown('answer v$n'),
    )));
    final first = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    expect(debugMarkdownBodiesBuilt, 1);

    notifier.value++;
    await tester.pump();
    final second = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    expect(identical(first, second), isFalse);
    expect(debugMarkdownBodiesBuilt, 2);
    expect(find.textContaining('answer v1'), findsOneWidget);
  });

  testWidgets('style parameter flips invalidate the memo', (tester) async {
    const text = 'unchanged text';
    final notifier = ValueNotifier<int>(0);
    await tester.pumpWidget(wrap(driven(
      notifier,
      (n) => AppMarkdown(text, selectable: n.isEven, highlight: n.isEven),
    )));
    expect(debugMarkdownBodiesBuilt, 1);

    notifier.value++;
    await tester.pump();
    expect(debugMarkdownBodiesBuilt, 2,
        reason: 'selectable/highlight ride the cached subtree');

    notifier.value++;
    await tester.pump();
    expect(debugMarkdownBodiesBuilt, 3);
  });

  testWidgets('image-resolver presence flips invalidate the memo',
      (tester) async {
    const text = '![pic](C:/w/pic.png)';
    final notifier = ValueNotifier<int>(0);
    Future<Uint8List?> resolver(String path) async => null;
    await tester.pumpWidget(wrap(driven(
      notifier,
      (n) => AppMarkdown(text, imageResolver: n.isEven ? null : resolver),
    )));
    expect(debugMarkdownBodiesBuilt, 1);

    notifier.value++;
    await tester.pump();
    expect(debugMarkdownBodiesBuilt, 2,
        reason: 'a wired/unwired sizedImageBuilder changes the MarkdownBody');
  });

  testWidgets('theme flip invalidates the memo and re-renders the body',
      (tester) async {
    const text = 'Theme **sensitive** body';
    final notifier = ValueNotifier<int>(0);
    Widget page(ThemeData theme) => wrap(
      driven(notifier, (_) => AppMarkdown(text)),
      theme: theme,
    );
    await tester.pumpWidget(page(buildDarkTheme()));
    final first = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    expect(debugMarkdownBodiesBuilt, 1);

    await tester.pumpWidget(page(buildLightTheme()));
    await tester.pump();
    final second = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    expect(debugMarkdownBodiesBuilt, 2,
        reason: 'theme flips must restyle the cached style sheet');
    expect(identical(first, second), isFalse);
    expect(
      second.styleSheet!.p!.color,
      isNot(first.styleSheet!.p!.color),
      reason: 'the rebuilt style sheet carries the new theme colour',
    );
  });

  testWidgets('link callbacks stay live on a cached body (trampoline)',
      (tester) async {
    const text = 'see [doc](other.md)';
    final tapped = <String>[];
    final notifier = ValueNotifier<int>(0);
    await tester.pumpWidget(wrap(driven(
      notifier,
      (_) => AppMarkdown(text, onLinkTap: tapped.add),
    )));
    expect(debugMarkdownBodiesBuilt, 1);

    notifier.value++; // fresh widget + fresh closure, same text
    await tester.pump();
    expect(debugMarkdownBodiesBuilt, 1,
        reason: 'callback identity is reached through the state trampoline');

    final body = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    body.onTapLink!('doc', 'other.md', '');
    expect(tapped, ['other.md']);
  });
}