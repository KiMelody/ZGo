import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/ui/chat/image_viewer_page.dart';
import 'package:zgo/ui/chat/markdown_view.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

/// 1x1 PNG — valid decode target for Image.memory in tests.
final Uint8List kPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAC'
    'hwGA60e6kgAAAABJRU5ErkJggg==');

Widget wrap(Widget child) => MaterialApp(
      theme: buildDarkTheme(),
      darkTheme: buildDarkTheme(),
      builder: (context, child) =>
          UiSettingsProvider(settings: UiSettings(), child: child!),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders paragraphs and inline code', (tester) async {
    await tester.pumpWidget(wrap(const AppMarkdown(
        'Hello **world**, see `doThing()` for details.')));
    expect(find.textContaining('Hello'), findsOneWidget);
    expect(find.textContaining('doThing()'), findsOneWidget);
  });

  testWidgets('fenced code block gets language header + copy button',
      (tester) async {
    await tester.pumpWidget(wrap(const AppMarkdown(
        '```dart\nvoid main() {}\n```')));
    await tester.pumpAndSettle();
    expect(find.text('dart'), findsOneWidget);
    expect(find.byIcon(Icons.copy_outlined), findsOneWidget);

    await tester.tap(find.byIcon(Icons.copy_outlined));
    await tester.pumpAndSettle();
    expect(find.text('已复制'), findsOneWidget);
  });

  testWidgets('fenced code block is collapsed by default and toggles',
      (tester) async {
    await tester.pumpWidget(wrap(const AppMarkdown(
        '```dart\nvoid main() {}\nvoid x() {}\n```')));
    await tester.pumpAndSettle();
    // Collapsed: header shows language + line count, body is absent.
    expect(find.text('dart'), findsOneWidget);
    expect(find.text('2 行'), findsOneWidget);
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
    expect(find.textContaining('void main()'), findsNothing);

    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pumpAndSettle();
    expect(find.textContaining('void main()'), findsOneWidget);
    expect(find.byIcon(Icons.expand_less), findsOneWidget);

    await tester.tap(find.byIcon(Icons.expand_less));
    await tester.pumpAndSettle();
    expect(find.textContaining('void main()'), findsNothing);
  });

  testWidgets('unordered list renders', (tester) async {
    await tester.pumpWidget(wrap(const AppMarkdown('- one\n- two')));
    expect(find.text('one'), findsOneWidget);
    expect(find.text('two'), findsOneWidget);
  });

  group('image resolver (09-29-file-preview)', () {
    testWidgets('success renders the image; tap opens the fullscreen viewer',
        (tester) async {
      final paths = <String>[];
      await tester.pumpWidget(wrap(AppMarkdown(
        '![pic](C:/w/pic.png)',
        imageResolver: (path) async {
          paths.add(path);
          return kPng;
        },
      )));
      await tester.pumpAndSettle();
      // flutter_markdown parses the reference through Uri, which lowercases
      // a single-letter (drive) scheme — the resolver sees 'c:/...' (reads
      // are case-insensitive on Windows).
      expect(paths, ['c:/w/pic.png']);
      expect(find.byType(Image), findsOneWidget);

      await tester.tap(find.byType(Image));
      await tester.pumpAndSettle();
      expect(find.byType(ImageViewerPage), findsOneWidget);
      expect(find.text('c:/w/pic.png'), findsOneWidget); // viewer chrome
    });

    testWidgets('resolver failure renders the placeholder row, not a collapse',
        (tester) async {
      await tester.pumpWidget(wrap(AppMarkdown(
        '![pic](C:/w/gone.png)',
        imageResolver: (_) async => null,
      )));
      await tester.pumpAndSettle();
      expect(find.textContaining('[图片加载失败] gone.png'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('svg goes straight to the placeholder without a fetch',
        (tester) async {
      var fetched = false;
      await tester.pumpWidget(wrap(AppMarkdown(
        '![diagram](C:/w/d.svg)',
        imageResolver: (_) async {
          fetched = true;
          return kPng;
        },
      )));
      await tester.pumpAndSettle();
      expect(fetched, isFalse);
      expect(find.textContaining('d.svg'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('no resolver keeps the legacy inert behavior', (tester) async {
      await tester.pumpWidget(
          wrap(const AppMarkdown('![pic](C:/w/pic.png)')));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
      expect(find.textContaining('图片加载失败'), findsNothing);
    });
  });

  group('onLinkTap', () {
    testWidgets('link taps hand the raw href to the callback',
        (tester) async {
      final hrefs = <String>[];
      await tester.pumpWidget(wrap(AppMarkdown(
        // Each link its own paragraph — the finder then matches the block.
        '[the doc](C:/w/doc.html)\n\n[web](https://x.y/z)',
        onLinkTap: hrefs.add,
      )));
      await tester.tap(find.text('the doc'));
      await tester.pump();
      await tester.tap(find.text('web'));
      expect(hrefs, ['C:/w/doc.html', 'https://x.y/z']);
    });

    testWidgets('links stay inert without onLinkTap (legacy)', (tester) async {
      await tester
          .pumpWidget(wrap(const AppMarkdown('[the doc](C:/w/doc.html)')));
      await tester.tap(find.text('the doc'));
      await tester.pumpAndSettle();
      expect(find.byType(ImageViewerPage), findsNothing);
    });
  });
}
