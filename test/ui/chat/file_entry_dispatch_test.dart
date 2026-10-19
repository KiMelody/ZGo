import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/protocol/file_service.dart';
import 'package:zgo/ui/chat/chat_page.dart';
import 'package:zgo/ui/chat/file_preview_page.dart';
import 'package:zgo/ui/chat/image_viewer_page.dart';
import 'package:zgo/ui/chat/pdf_preview_page.dart';
import 'package:zgo/ui/chat/timeline.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../../helpers/recording_chat_gateway.dart';

/// 1x1 PNG — valid decode target for Image.memory in tests.
final Uint8List kPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAC'
    'hwGA60e6kgAAAABJRU5ErkJggg==');

/// 32x32 PNG — same, but with a real hit box so tap() lands inside the
/// InkWell (a 1x1 fixture's center point rounds out of its own box).
final Uint8List kPng32 = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKklEQVR4nO3NQQkAAAgE'
    'sItqJCMZzRQ+hMH+S/WcikAgEAgEAoFAIPgSLPH0wFuCZjkoAAAAAElFTkSuQmCC');

class FakeChatGateway extends RecordingChatGateway {}

/// Programmed attachment bytes for the R3 inline-fullscreen test:
/// _AttachmentView loads through the conversation transport's
/// attachmentRead, not the gateway's fileReadMedia.
class _AttachmentTransport extends RecordingConversationTransport {
  _AttachmentTransport() : super((_, __) {}, () => false);

  @override
  Future<({Uint8List bytes, String? mediaType})> attachmentRead(
    String sessionId, {
    required String ref,
  }) async => (bytes: kPng, mediaType: 'image/png');
}

class _AttachmentGateway extends FakeChatGateway {
  @override
  ConversationTransport get conversationCommands => _AttachmentTransport();
}

/// Holds `fileReadText` so the preview page stays in its loading phase —
/// the real InAppWebView cannot be hosted in widget tests, so the html
/// dispatch asserts the push + the RPC shape only. The override records
/// its own calls (the shared `calls` list is bypassed).
class _HoldTextGateway extends FakeChatGateway {
  final completer = Completer<TextChunk>();
  final List<List<Object?>> textCalls = [];

  @override
  Future<TextChunk> fileReadText(String workspacePath, String path,
      {int offset = 0, required int length}) {
    textCalls.add([workspacePath, path, offset, length]);
    return completer.future;
  }
}

/// Holds `fileStat` so the pdf page stays in its loading phase — same
/// reason as [_HoldTextGateway]: the pdf WebView (and its 1 MB assets) must
/// not be reached in a widget test.
class _HoldStatGateway extends FakeChatGateway {
  final completer = Completer<FileStat>();
  final List<List<Object?>> statCalls = [];

  @override
  Future<FileStat> fileStat(String workspacePath, String path) {
    statCalls.add([workspacePath, path]);
    return completer.future;
  }
}

/// Programmed `conversationFileChangesV4` answers for the changes sheet.
class _FileChangesTransport implements ConversationTransport {
  _FileChangesTransport(this.payload);

  final Object? payload;
  int calls = 0;

  @override
  Future<dynamic> fileChanges(
    String sessionId, {
    required Map<String, dynamic> target,
    int? baseRevision,
    String? baseLogEpoch,
  }) async {
    calls++;
    return payload;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      Future.value(const {'status': 'accepted'});
}

class _ChangesGateway extends FakeChatGateway {
  _ChangesGateway(Object? payload) : transport = _FileChangesTransport(payload);

  final _FileChangesTransport transport;

  @override
  ConversationTransport get conversationCommands => transport;
}

Widget wrap(Widget child) => MaterialApp(
      theme: buildDarkTheme(),
      darkTheme: buildDarkTheme(),
      builder: (context, child) =>
          UiSettingsProvider(settings: UiSettings(), child: child!),
      home: child,
    );

Map<String, dynamic> _writeRow(String path) => {
      'rowId': 2,
      'kind': 'toolCall',
      'toolName': 'Write',
      'status': 'success',
      'inputText': '{"filePath": "$path"}',
    };

Future<void> _pumpToolRow(
  WidgetTester tester,
  RecordingChatGateway gateway, {
  String path = 'C:/w/a.png',
}) async {
  await tester.pumpWidget(
    wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
  );
  gateway.feedSnapshot([
    {'rowId': 1, 'kind': 'userInput', 'text': '写个文件'},
    _writeRow(path),
  ]);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('tool-row file dispatch', () {
    testWidgets('png write row: tapping the file name opens the fullscreen '
        'viewer through fileReadMedia', (tester) async {
      final gateway = FakeChatGateway()
        ..fileReadMediaResult = MediaPreview(bytes: kPng);
      await _pumpToolRow(tester, gateway, path: 'C:/w/a.png');

      await tester.tap(find.text('a.png'));
      await tester.pumpAndSettle();

      expect(find.byType(ImageViewerPage), findsOneWidget);
      expect(
        gateway.calls.where((c) => c.$1 == 'fileReadMedia').single.$2,
        containsAllInOrder(['/repo/app', 'C:/w/a.png']),
      );
    });

    testWidgets('html write row: tapping the file name pushes the preview '
        'page and reads through fileReadText', (tester) async {
      final gateway = _HoldTextGateway();
      await _pumpToolRow(tester, gateway, path: 'C:/w/page.html');

      await tester.tap(find.text('page.html'));
      await tester.pump();
      await tester.pump();

      expect(find.byType(FilePreviewPage), findsOneWidget);
      expect(find.byType(ImageViewerPage), findsNothing);
      // Loading phase held: the assembler's main-file read is pending.
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      // First loop step: 256 KiB (the server's own clamp) — the pre-S2
      // single 2 MiB request was what the server silently cut at 256 KiB.
      expect(gateway.textCalls.single,
          ['/repo/app', 'C:/w/page.html', 0, 256 * 1024]);
    });

    testWidgets('md write row: tapping opens the markdown render kind '
        'through the read loop', (tester) async {
      final gateway = _HoldTextGateway();
      await _pumpToolRow(tester, gateway, path: 'C:/w/notes.md');

      await tester.tap(find.text('notes.md'));
      await tester.pump();
      await tester.pump();

      expect(find.byType(FilePreviewPage), findsOneWidget);
      expect(find.byType(ImageViewerPage), findsNothing);
      expect(
        tester.widget<FilePreviewPage>(find.byType(FilePreviewPage)).render,
        FilePreviewRender.markdown,
      );
      expect(gateway.textCalls.single,
          ['/repo/app', 'C:/w/notes.md', 0, 256 * 1024]);
    });

    testWidgets('svg write row dispatches into the svg render kind',
        (tester) async {
      final gateway = _HoldTextGateway();
      await _pumpToolRow(tester, gateway, path: 'C:/w/logo.svg');

      await tester.tap(find.text('logo.svg'));
      await tester.pump();
      await tester.pump();

      expect(find.byType(FilePreviewPage), findsOneWidget);
      expect(
        tester.widget<FilePreviewPage>(find.byType(FilePreviewPage)).render,
        FilePreviewRender.svg,
      );
      expect(gateway.textCalls.single,
          ['/repo/app', 'C:/w/logo.svg', 0, 256 * 1024]);
    });

    testWidgets('pdf write row: tapping pushes PdfPreviewPage through the '
        'stat probe', (tester) async {
      final gateway = _HoldStatGateway();
      await _pumpToolRow(tester, gateway, path: 'C:/w/doc.pdf');

      // The name segment is a tappable span once the row is dispatchable
      // (S6 turned pdf on; before, the whole title was inert plain text).
      await tester.tap(find.text('doc.pdf'));
      await tester.pump();
      await tester.pump();

      expect(find.byType(PdfPreviewPage), findsOneWidget);
      expect(find.byType(FilePreviewPage), findsNothing);
      expect(find.byType(ImageViewerPage), findsNothing);
      // The pdf page's three-state read starts with the official stat probe
      // (the mode fork); bytes travel through fileReadRange behind the
      // document's own bridge — never the text/media reads.
      expect(gateway.statCalls.single, ['/repo/app', 'C:/w/doc.pdf']);
      expect(gateway.calls.where((c) => c.$1 == 'fileReadMedia'), isEmpty);
      expect(gateway.calls.where((c) => c.$1 == 'fileReadText'), isEmpty);
      // Loading phase held: the stat probe is still pending.
      expect(find.byType(CircularProgressIndicator), findsWidgets);
    });
  });

  group('dispatchable matrix (design §3)', () {
    // Blacklist by class representative (design §3.1) + the boundary set
    // (R2-L3): extension-less names, dot-files, double extensions (last
    // segment), case, and directory-shaped paths (folded in as-is — the
    // directory exclusion lives at the entry point, R8/M3, not here).
    const cases = <String, bool>{
      // render / text surfaces all stay dispatchable
      'C:/w/a.png': true,
      'C:/w/a.webp': true,
      'C:/w/page.html': true,
      'C:/w/page.htm': true,
      'C:/w/notes.md': true,
      'C:/w/notes.markdown': true,
      'C:/w/logo.svg': true,
      'C:/w/doc.pdf': true, // S6: pdf opens its own PdfPreviewPage
      'C:/w/data.json': true,
      'C:/w/run.py': true,
      'C:/w/style.css': true,
      // archives
      'C:/w/bundle.zip': false,
      'C:/w/bundle.tar.gz': false,
      'C:/w/BUNDLE.ZIP': false,
      'C:/w/app.jar': false,
      // binaries
      'C:/w/tool.exe': false,
      'C:/w/lib.so': false,
      'C:/w/mod.wasm': false,
      'C:/w/data.sqlite': false,
      // office containers
      'C:/w/report.docx': false,
      'C:/w/sheet.xlsx': false,
      'C:/w/deck.pptx': false,
      // media
      'C:/w/clip.mp4': false,
      'C:/w/voice.mp3': false,
      'C:/w/scene.mkv': false,
      // bitmaps Flutter cannot decode
      'C:/w/scan.tiff': false,
      'C:/w/shot.heic': false,
      'C:/w/favicon.ico': false,
      // fonts
      'C:/w/font.woff2': false,
      'C:/w/font.ttf': false,
      // disk images / installers
      'C:/w/installer.dmg': false,
      'C:/w/app.apk': false,
      'C:/w/app.hap': false,
      // boundary set
      'C:/w/Makefile': true,
      'C:/w/.gitignore': true,
      'C:/w/sub/dir': true,
      'C:/w/sub/dir/': true,
    };

    for (final entry in cases.entries) {
      test('dispatchable(${entry.key}) == ${entry.value}', () {
        expect(ChatPreview.dispatchable(entry.key), entry.value);
      });
    }
  });

  group('markdown body integration', () {
    testWidgets('same-path images share one cached fileReadMedia RPC',
        (tester) async {
      final gateway = FakeChatGateway()
        ..fileReadMediaResult = MediaPreview(bytes: kPng);
      await tester.pumpWidget(
        wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
      );
      gateway.feedSnapshot([
        {
          'rowId': 1,
          'kind': 'assistantText',
          'text': '![p](C:/w/a.png)\n\nagain ![p](C:/w/a.png)',
        },
      ]);
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsNWidgets(2));
      expect(gateway.calls.where((c) => c.$1 == 'fileReadMedia'), hasLength(1),
          reason: 'the session LRU collapses duplicate image fetches');
    });

    testWidgets('relative markdown image resolves against the workspace',
        (tester) async {
      // Live-certified: the desktop resolves relative paths against its own
      // process CWD (spec §1.2) — the app must join the workspace first.
      final gateway = FakeChatGateway()
        ..fileReadMediaResult = MediaPreview(bytes: kPng);
      await tester.pumpWidget(
        wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
      );
      gateway.feedSnapshot([
        {
          'rowId': 1,
          'kind': 'assistantText',
          'text': '![p](shots/a.png)\n\ndone',
        },
      ]);
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsOneWidget);
      expect(
        gateway.calls.where((c) => c.$1 == 'fileReadMedia').single.$2,
        containsAllInOrder(['/repo/app', '/repo/app/shots/a.png']),
      );
    });

    testWidgets('markdown local link dispatches to the preview page',
        (tester) async {
      final gateway = _HoldTextGateway();
      await tester.pumpWidget(
        wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
      );
      gateway.feedSnapshot([
        {
          'rowId': 1,
          'kind': 'assistantText',
          'text': '[open it](C:/w/page.html)\n\ndone',
        },
      ]);
      await tester.pumpAndSettle();

      await tester.tap(find.text('open it'));
      await tester.pump();
      await tester.pump();

      expect(find.byType(FilePreviewPage), findsOneWidget);
      expect(gateway.textCalls, hasLength(1));
    });

    testWidgets('a markdown link to a blacklisted file reaches the '
        'cannot-preview state (links stay ungated, design §0 L1)',
        (tester) async {
      final gateway = FakeChatGateway()
        ..fileReadTextResult = const TextChunk(
          text: '',
          bytesRead: 262144,
          totalBytes: 262144,
          hasMore: true,
          isBinary: true,
        );
      await tester.pumpWidget(
        wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
      );
      gateway.feedSnapshot([
        {
          'rowId': 1,
          'kind': 'assistantText',
          'text': '[zip](C:/w/bundle.zip)\n\ndone',
        },
      ]);
      await tester.pumpAndSettle();

      await tester.tap(find.text('zip'));
      await tester.pumpAndSettle();

      expect(find.byType(FilePreviewPage), findsOneWidget);
      expect(find.text('二进制文件，无文本预览'), findsOneWidget);
    });

    testWidgets('markdown http link launches the system browser',
        (tester) async {
      final launched = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/url_launcher'),
        (call) async {
          launched.add('$call');
          return true;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/url_launcher'), null));

      final gateway = FakeChatGateway();
      await tester.pumpWidget(
        wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
      );
      gateway.feedSnapshot([
        {
          'rowId': 1,
          'kind': 'assistantText',
          'text': '[docs](https://example.com/guide)\n\ndone',
        },
      ]);
      await tester.pumpAndSettle();

      await tester.tap(find.text('docs'));
      await tester.pumpAndSettle();

      expect(find.byType(FilePreviewPage), findsNothing);
      expect(launched.any((e) => e.contains('https://example.com/guide')),
          isTrue, reason: 'launchUrl hit the platform channel: $launched');
    });
  });

  group('inline image fullscreen (R3)', () {
    testWidgets('attachment image tap opens the fullscreen viewer',
        (tester) async {
      final gateway = _AttachmentGateway();
      await tester.pumpWidget(
        wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
      );
      gateway.feedSnapshot([
        {
          'rowId': 1,
          'kind': 'userInput',
          'text': '看图',
          'attachments': [
            {'ref': 'r1', 'fileName': 'shot.png', 'mime': 'image/png'},
          ],
        },
      ]);
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Image).first);
      await tester.pumpAndSettle();

      expect(find.byType(ImageViewerPage), findsOneWidget);
      expect(find.text('shot.png'), findsOneWidget);
    });

    testWidgets('tool display image tap opens the fullscreen viewer',
        (tester) async {
      final gateway = FakeChatGateway();
      await tester.pumpWidget(
        wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
      );
      gateway.feedSnapshot([
        {'rowId': 1, 'kind': 'userInput', 'text': '画图'},
        {
          'rowId': 2,
          'kind': 'toolCall',
          'toolName': 'NodeREPL',
          'status': 'success',
          'display': {
            'kind': 'node_repl_images',
            'images': [
              {'base64': base64Encode(kPng32)},
            ],
          },
        },
      ]);
      await tester.pumpAndSettle();

      // Images live inside the collapsed tool tile: expand first.
      await tester.tap(find.byType(ExpansionTile).first);
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Image).first);
      await tester.pumpAndSettle();

      expect(find.byType(ImageViewerPage), findsOneWidget);
    });
  });

  group('file changes sheet', () {
    testWidgets('file rows render with counts and dispatch on tap',
        (tester) async {
      final gateway = _ChangesGateway({
        'files': [
          {'path': 'C:/w/a.png', 'additions': 3, 'deletions': 1},
          {'path': 'C:/w/notes.md'},
        ],
      })
        ..fileReadMediaResult = MediaPreview(bytes: kPng);
      await tester.pumpWidget(
        wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
      );
      gateway.feedSnapshot([
        {'rowId': 1, 'kind': 'userInput', 'text': '改文件'},
      ]);
      await tester.pumpAndSettle();

      // The bubble is a SelectableText — its long-press selection wins the
      // arena; press the bubble padding just outside the text (chat_page_test
      // idiom) where the row's GestureDetector owns the press.
      final topLeft = tester.getTopLeft(find.text('改文件'));
      await tester.longPressAt(topLeft - const Offset(8, 4));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看文件变更'));
      await tester.pumpAndSettle();

      expect(find.text('C:/w/a.png'), findsOneWidget);
      expect(find.text('C:/w/notes.md'), findsOneWidget);
      expect(find.text('+3'), findsOneWidget);
      expect(find.text('-1'), findsOneWidget);
      expect(gateway.transport.calls, 1);

      // Tapping the png row pushes the viewer over the sheet.
      await tester.tap(find.text('C:/w/a.png'));
      await tester.pumpAndSettle();
      expect(find.byType(ImageViewerPage), findsOneWidget);
    });

    testWidgets('garbage payload falls back to the raw JSON sheet',
        (tester) async {
      final gateway = _ChangesGateway({'status': 'accepted', 'files': 2});
      await tester.pumpWidget(
        wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
      );
      gateway.feedSnapshot([
        {'rowId': 1, 'kind': 'userInput', 'text': '改文件'},
      ]);
      await tester.pumpAndSettle();

      final topLeft = tester.getTopLeft(find.text('改文件'));
      await tester.longPressAt(topLeft - const Offset(8, 4));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看文件变更'));
      await tester.pumpAndSettle();

      // Raw JSON dump (the previous behavior), not the row sheet.
      expect(find.textContaining('"status"'), findsOneWidget);
      expect(find.textContaining('+3'), findsNothing);
    });
  });
}
