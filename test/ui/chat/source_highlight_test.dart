import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/ui/chat/markdown_view.dart';
import 'package:zgo/ui/chat/source_highlight.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

Widget wrap(Widget child) => MaterialApp(
      theme: buildDarkTheme(),
      darkTheme: buildDarkTheme(),
      builder: (context, child) =>
          UiSettingsProvider(settings: UiSettings(), child: child!),
      home: Scaffold(body: child),
    );

/// Real theme + real locale scope to hang a BuildContext off.
Future<BuildContext> pumpContext(WidgetTester tester) async {
  late BuildContext captured;
  await tester.pumpWidget(wrap(Builder(builder: (context) {
    captured = context;
    return const SizedBox.shrink();
  })));
  return captured;
}

/// Every span in the tree, root first (depth-first).
Iterable<TextSpan> spansOf(TextSpan root) sync* {
  yield root;
  for (final child in root.children ?? const <InlineSpan>[]) {
    if (child is TextSpan) yield* spansOf(child);
  }
}

/// The spans carrying [needle], with their own styles.
Iterable<TextSpan> spansContaining(TextSpan root, String needle) =>
    spansOf(root).where((s) => s.text?.contains(needle) ?? false);

/// A small but scope-rich dart sample (keywords, numbers, comment, built-in,
/// string all appear — see the roster probe in-source_highlight.dart).
const dartSample = 'void main() {\n'
    '  final x = 1; // note\n'
    '  print("hi");\n'
    '}\n';

/// Line-aligned fixture (~[bytes] chars) of valid-ish json lines, so the
/// hljs scan sees a realistic document rather than one giant token.
String jsonFixture(int bytes) {
  const line = '{"key": "value", "n": 1234567890, "ok": true},\n';
  final buffer = StringBuffer();
  while (buffer.length < bytes) {
    buffer.write(line);
  }
  return buffer.toString();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('extension → language table', () {
    test('official Dg entries map to their grammars', () {
      const official = {
        'bash': 'bash',
        'c': 'c',
        'cc': 'cpp',
        'cpp': 'cpp',
        'css': 'css',
        'diff': 'diff',
        'go': 'go',
        'h': 'c',
        'htm': 'html',
        'html': 'html',
        'java': 'java',
        'js': 'javascript',
        'json': 'json',
        'jsx': 'jsx',
        'md': 'markdown',
        'mjs': 'javascript',
        'py': 'python',
        'rb': 'ruby',
        'rs': 'rust',
        'sh': 'bash',
        'sql': 'sql',
        'svg': 'xml',
        'toml': 'ini',
        'ts': 'typescript',
        'tsx': 'tsx',
        'xml': 'xml',
        'yaml': 'yaml',
        'yml': 'yaml',
      };
      for (final entry in official.entries) {
        expect(highlightLanguageByExtension[entry.key], entry.value,
            reason: entry.key);
      }
      // mermaid/mmd was the one official entry the design cut.
      expect(highlightLanguageByExtension['mermaid'], isNull);
      expect(highlightLanguageByExtension['mmd'], isNull);
    });

    test('roster languages the official table predates have extensions', () {
      const extras = {
        'dart': 'dart',
        'kt': 'kotlin',
        'kts': 'kotlin',
        'swift': 'swift',
        'cs': 'csharp',
        'php': 'php',
        'hpp': 'cpp',
        'markdown': 'markdown',
        'shell': 'shell',
        'ini': 'ini',
      };
      for (final entry in extras.entries) {
        expect(highlightLanguageByExtension[entry.key], entry.value,
            reason: entry.key);
      }
    });

    test('txt/text/log map to log (no grammar → plain fallback)', () {
      // Official-table aliases, kept even though re_highlight ships no log
      // grammar: the mapping documents intent, getLanguage does the fallback.
      expect(highlightLanguageByExtension['txt'], 'log');
      expect(highlightLanguageByExtension['text'], 'log');
      expect(highlightLanguageByExtension['log'], 'log');
    });

    test('highlightLanguageForPath reads the last-dot extension', () {
      expect(highlightLanguageForPath('C:/w/main.dart'), 'dart');
      expect(highlightLanguageForPath(r'C:\w\src\lib\a.JSON'), 'json');
      expect(highlightLanguageForPath('/w/dir.v2/file.css'), 'css');
      expect(highlightLanguageForPath('/w/.eslintrc.json'), 'json');
      expect(highlightLanguageForPath('/w/archive.tar.gz'), isNull);
      expect(highlightLanguageForPath('/w/notes.unknownext'), isNull);
    });

    test('no extension / dotfile / trailing dot → null', () {
      expect(highlightLanguageForPath('/w/Makefile'), isNull);
      expect(highlightLanguageForPath('/w/.gitignore'), isNull);
      expect(highlightLanguageForPath('/w/weird.'), isNull);
      expect(highlightLanguageForPath('/w/dir.d/file'), isNull);
      expect(highlightLanguageForPath(''), isNull);
    });
  });

  group('highlightSpan fallbacks', () {
    testWidgets('no language → plain', (tester) async {
      final context = await pumpContext(tester);
      expect(
        highlightSpan(context,
            text: dartSample, language: null, base: const TextStyle()),
        isNull,
      );
    });

    testWidgets('unregistered language → plain', (tester) async {
      final context = await pumpContext(tester);
      for (final language in ['log', 'graphql', 'handlebars', 'nope']) {
        expect(
          highlightSpan(context,
              text: dartSample, language: language, base: const TextStyle()),
          isNull,
          reason: language,
        );
      }
    });

    testWidgets('empty text → plain', (tester) async {
      final context = await pumpContext(tester);
      expect(
        highlightSpan(context,
            text: '', language: 'dart', base: const TextStyle()),
        isNull,
      );
    });

    testWidgets('the threshold rejects one unit over the highlight cap',
        (tester) async {
      final context = await pumpContext(tester);
      expect(
        highlightSpan(context,
            text: 'x' * (highlightMaxBytes + 1),
            language: 'json',
            base: const TextStyle()),
        isNull,
      );
      // At the cap the span is a real highlight (the boundary is `>`, the
      // same comparison the source grade uses).
      final atCap = highlightSpan(context,
          text: 'x' * highlightMaxBytes,
          language: 'json',
          base: const TextStyle());
      expect(atCap, isNotNull);
      // The highlight cap sits below the monolith grade on purpose
      // (layout cost is super-linear in span count — see the constant).
      expect(highlightMaxBytes, lessThan(monolithMaxBytes));
    });

    testWidgets('a cap-sized json document highlights within the sentinel',
        (tester) async {
      // CI-tolerant tripwire (design §4.3): scan + flat assembly + span
      // building run once per highlighted monolith. Measured warm JIT is
      // ~0.2 s at the cap; a regression to the packaged quadratic
      // TextSpanRenderer would take minutes here.
      final context = await pumpContext(tester);
      // Exactly the cap (the fixture overshoots it by construction).
      final text =
          jsonFixture(highlightMaxBytes).substring(0, highlightMaxBytes);
      final watch = Stopwatch()..start();
      final span = highlightSpan(context,
          text: text, language: 'json', base: const TextStyle());
      watch.stop();
      expect(span, isNotNull);
      expect(watch.elapsedMilliseconds, lessThan(1500),
          reason: 'cap-sized json took ${watch.elapsedMilliseconds} ms');
    });
  });

  group('highlightSpan assembly', () {
    testWidgets('dart: token colors on top of the caller base',
        (tester) async {
      final context = await pumpContext(tester);
      const base = TextStyle(color: Color(0xFFABCDEF), fontSize: 11);
      final span = highlightSpan(context,
          text: dartSample, language: 'dart', base: base);
      expect(span, isNotNull);
      expect(span!.toPlainText(), dartSample);

      final colors = spansOf(span)
          .map((s) => s.style?.color)
          .whereType<Color>()
          .toSet();
      // Keywords/built-ins/strings/comments paint at least a few distinct
      // colors; the base ink is among them.
      expect(colors.length, greaterThanOrEqualTo(3));
      expect(colors, contains(base.color));

      final voidSpans = spansContaining(span, 'void').length;
      expect(voidSpans, greaterThanOrEqualTo(1));
    });

    testWidgets('json punctuation keeps the base ink, never black',
        (tester) async {
      final context = await pumpContext(tester);
      final base = TextStyle(color: ZInk.solid(context));
      final span = highlightSpan(context,
          text: '{"a": [1, true, null]}', language: 'json', base: base);
      expect(span, isNotNull);

      for (final needle in ['{', ':', ',', '}']) {
        final punctuation = spansContaining(span!, needle).first;
        // Unmapped scopes (punctuation is one) fall back to the base style —
        // re_highlight issue #1's black brackets come from packaged themes,
        // which this palette does not use.
        expect(punctuation.style?.color, base.color, reason: needle);
      }
      expect(
        spansOf(span!).map((s) => s.style?.color).toSet(),
        isNot(contains(Colors.black)),
      );
    });

    testWidgets('the palette has no black and no duplicate-by-accident '
        'entries', (tester) async {
      final context = await pumpContext(tester);
      final theme = sourceHighlightTheme(context);
      expect(theme, isNotEmpty);
      for (final entry in theme.entries) {
        expect(entry.value.color, isNotNull, reason: entry.key);
        expect(entry.value.color, isNot(Colors.black), reason: entry.key);
      }
    });
  });

  group('AppMarkdown highlight parameterization', () {
    testWidgets('default (chat) keeps the plain SelectableText body',
        (tester) async {
      await tester.pumpWidget(wrap(const AppMarkdown(
          '```dart\nvoid main() {\n  print(1);\n}\n```')));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pumpAndSettle();

      final body = tester.widget<SelectableText>(find.byType(SelectableText));
      // The pre-S4 shape: plain data constructor, no rich span anywhere.
      expect(body.data, isNotNull);
      expect(body.textSpan, isNull);
      expect(find.textContaining('print(1);'), findsOneWidget);
      // Header chrome untouched.
      expect(find.text('dart'), findsOneWidget);
      expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
    });

    testWidgets('highlight: true renders the rich highlighted span',
        (tester) async {
      await tester.pumpWidget(wrap(const AppMarkdown(
        '```dart\nvoid main() {\n  print(1);\n}\n```',
        highlight: true,
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pumpAndSettle();

      final body = tester.widget<SelectableText>(find.byType(SelectableText));
      expect(body.data, isNull);
      final span = body.textSpan;
      expect(span, isNotNull);
      expect(span!.toPlainText(), 'void main() {\n  print(1);\n}');
      expect(
        spansOf(span).map((s) => s.style?.color).whereType<Color>().length,
        greaterThan(1),
      );
    });

    testWidgets('highlight: true on an unregistered language stays plain',
        (tester) async {
      await tester.pumpWidget(wrap(const AppMarkdown(
        '```weirdlang\nsome text\n```',
        highlight: true,
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pumpAndSettle();

      final body = tester.widget<SelectableText>(find.byType(SelectableText));
      expect(body.data, isNotNull);
      expect(body.textSpan, isNull);
    });
  });
}
