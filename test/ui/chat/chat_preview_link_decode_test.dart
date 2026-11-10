import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/file_service.dart';
import 'package:zgo/ui/chat/chat_page.dart';
import 'package:zgo/ui/chat/chat_preview.dart';
import 'package:zgo/ui/chat/file_preview_page.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../../helpers/chat_role_fakes.dart';

/// Holds the main-file read so a pushed preview stays in its loading phase
/// (widget tests cannot host the markdown render surface long enough to
/// matter); every call is recorded for the path assertions.
class _HoldTextPort extends RecordingFileServicePort {
  _HoldTextPort(super.recording);

  final completer = Completer<TextChunk>();
  final List<List<Object?>> textCalls = [];

  @override
  Future<TextChunk> readText(
    String workspacePath,
    String path, {
    int offset = 0,
    required int length,
  }) {
    textCalls.add([workspacePath, path, offset, length]);
    return completer.future;
  }
}

class _HoldTextGateway extends FakeChatGateway {
  @override
  late final FileServicePort fileService = _HoldTextPort(recording);

  List<List<Object?>> get textCalls => (fileService as _HoldTextPort).textCalls;
}

Widget wrap(Widget child) => MaterialApp(
      theme: buildDarkTheme(),
      darkTheme: buildDarkTheme(),
      builder: (context, child) =>
          UiSettingsProvider(settings: UiSettings(), child: child!),
      home: child,
    );

/// Pushes a chat row holding one markdown link `[open](href)`, taps it and
/// returns the pushed preview's first text-read path (the wire path after
/// `openLink` → `_absolute`).
Future<String?> _tapMarkdownLink(WidgetTester tester, String href) async {
  final gateway = _HoldTextGateway();
  await tester.pumpWidget(
    wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
  );
  gateway.feedSnapshot([
    {
      'rowId': 1,
      'kind': 'assistantText',
      'text': '[open]($href)\n\ndone',
    },
  ]);
  await tester.pumpAndSettle();

  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump();

  expect(find.byType(FilePreviewPage), findsOneWidget,
      reason: 'the link must reach a preview surface: $href');
  return gateway.textCalls.single[1] as String?;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('decodeLocalPath (pure)', () {
    test('AC1: an encoded drive path decodes to a real Windows path', () {
      const encoded = r'F:%5CMoney%5Cdocs%5Cprd.md';
      final decoded = ChatPreview.decodeLocalPath(encoded);

      expect(decoded, r'F:\Money\docs\prd.md');
      // The second half of the contract: after re-slashing, the drive
      // regexp in `_absolute` matches — no workspace join.
      final forwarded = decoded.replaceAll(r'\', '/');
      expect(forwarded, 'F:/Money/docs/prd.md');
      expect(RegExp(r'^[A-Za-z]:/').hasMatch(forwarded), isTrue);
    });

    test('AC1: a fully encoded form (no literal colon) decodes the same',
        () {
      // `scheme.isEmpty` branch at the call site: the colon is `%3A`.
      expect(ChatPreview.decodeLocalPath(r'F%3A%5Cfoo%5Cbar.md'),
          r'F:\foo\bar.md');
    });

    test('AC2: a malformed escape falls back to the raw string, no throw',
        () {
      const malformed = [
        'F:100%', // lone trailing percent
        r'F:%5Cfoo%ZZ.md', // non-hex escape
        r'F:%5Cfoo%E4.md', // truncated UTF-8 sequence
        'F:%', // truncated escape
        'F:%5', // truncated escape, one nibble
      ];
      for (final input in malformed) {
        expect(ChatPreview.decodeLocalPath(input), input, reason: input);
      }
    });

    test('AC3: relative paths and literal absolute paths pass unchanged',
        () {
      for (final input in [
        'shots/a.png',
        'notes/prd.md',
        'C:/w/a.md',
        r'C:\w\a.md',
        '/repo/app/x.md',
      ]) {
        expect(ChatPreview.decodeLocalPath(input), input, reason: input);
      }
    });

    test('AC3: %3F/%23 in a file name decode to literal ? and #', () {
      expect(ChatPreview.decodeLocalPath(r'F:%5Cfoo%3Fbar.md'),
          r'F:\foo?bar.md');
      expect(ChatPreview.decodeLocalPath(r'F:%5Cfoo%23bar.md'),
          r'F:\foo#bar.md');
      // Encoded spaces (the other common desktop escape) too.
      expect(ChatPreview.decodeLocalPath(r'F:%5Ca%20b%5Cc.md'),
          r'F:\a b\c.md');
    });
  });

  group('openLink: encoded local hrefs (AC1/AC3 end to end)', () {
    testWidgets('an encoded windows path is decoded and NOT joined onto the '
        'workspace', (tester) async {
      final path = await _tapMarkdownLink(tester, r'F:%5CMoney%5Cprd.md');

      expect(path, 'F:/Money/prd.md');
      expect(path, isNot(startsWith('/repo/app')),
          reason: 'the drive path must not be treated as workspace-relative');
    });

    testWidgets('a fully encoded drive path (no literal colon) dispatches '
        'too', (tester) async {
      final path = await _tapMarkdownLink(tester, r'F%3A%5Cw%5Cnotes.md');

      expect(path, 'F:/w/notes.md');
    });

    testWidgets('a relative link still joins the workspace (regression)',
        (tester) async {
      final path = await _tapMarkdownLink(tester, 'notes/prd.md');

      expect(path, '/repo/app/notes/prd.md');
    });

    testWidgets('a literal-slash absolute link still passes through '
        '(regression)', (tester) async {
      final path = await _tapMarkdownLink(tester, 'C:/w/notes.md');

      expect(path, 'C:/w/notes.md');
    });

    testWidgets('a %3F in the file name decodes after the scheme split and '
        'is not read as a query string', (tester) async {
      final path = await _tapMarkdownLink(tester, r'F:%5Cw%5Cfoo%3Fbar.md');

      expect(path, 'F:/w/foo?bar.md');
    });

    testWidgets('a %23 in the file name is not read as a fragment',
        (tester) async {
      final path = await _tapMarkdownLink(tester, r'F:%5Cw%5Cfoo%23bar.md');

      expect(path, 'F:/w/foo#bar.md');
    });
  });
}