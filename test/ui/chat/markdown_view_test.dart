import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/ui/chat/markdown_view.dart';
import 'package:zlinker/ui/theme.dart';
import 'package:zlinker/ui/ui_settings.dart';

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
    await tester.pumpWidget(wrap(const ZLinkerMarkdown(
        'Hello **world**, see `doThing()` for details.')));
    expect(find.textContaining('Hello'), findsOneWidget);
    expect(find.textContaining('doThing()'), findsOneWidget);
  });

  testWidgets('fenced code block gets language header + copy button',
      (tester) async {
    await tester.pumpWidget(wrap(const ZLinkerMarkdown(
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
    await tester.pumpWidget(wrap(const ZLinkerMarkdown(
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
    await tester.pumpWidget(wrap(const ZLinkerMarkdown('- one\n- two')));
    expect(find.text('one'), findsOneWidget);
    expect(find.text('two'), findsOneWidget);
  });
}
