import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/file_service.dart';
import 'package:zgo/ui/chat/chat_page.dart';
import 'package:zgo/ui/chat/chat_preview.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../../helpers/chat_role_fakes.dart';

/// A programmed file channel: `readText` answers per path from [files]
/// (anything absent throws ENOENT unless [errors] programs the failure),
/// `readdir` answers [tree], and every call lands in the per-kind lists.
class _ScriptedFiles extends RecordingFileServicePort {
  _ScriptedFiles(super.recording, this.files, this.tree, [this.errors = const {}]);

  /// Absolute path → file text (a present key means "this file reads").
  final Map<String, String> files;

  /// Absolute directory → entries.
  final Map<String, List<DirEntry>> tree;

  /// Absolute path → the error object the desktop would throw.
  final Map<String, Object> errors;

  final List<String> textReads = [];
  final List<String> dirReads = [];

  @override
  Future<TextChunk> readText(
    String workspacePath,
    String path, {
    int offset = 0,
    required int length,
  }) async {
    textReads.add(path);
    final err = errors[path];
    if (err != null) throw err;
    final text = files[path];
    if (text == null) {
      throw Exception("ENOENT: no such file or directory, open '$path'");
    }
    return TextChunk(
      text: text,
      bytesRead: text.length,
      totalBytes: text.length,
      hasMore: false,
      isBinary: false,
    );
  }

  @override
  Future<List<DirEntry>> readdir(String workspacePath, String dir) async {
    dirReads.add(dir);
    return tree[dir] ?? const [];
  }
}

class _Gateway extends FakeChatGateway {
  _Gateway(this.files, this.tree, [this.errors = const {}]);

  final Map<String, String> files;
  final Map<String, List<DirEntry>> tree;
  final Map<String, Object> errors;

  @override
  late final FileServicePort fileService =
      _ScriptedFiles(recording, files, tree, errors);
}

Widget _wrap(Widget child) => MaterialApp(
      theme: buildDarkTheme(),
      darkTheme: buildDarkTheme(),
      builder: (context, child) => UiSettingsProvider(
        settings: UiSettings(),
        child: child!,
      ),
      home: child,
    );

/// The source view's rendered plain text (the extension highlighter turns
/// `# x` into spans, so `find.text` cannot see the raw markdown).
String _sourceText(WidgetTester tester) {
  final st = tester.widget<SelectableText>(find.byType(SelectableText));
  return st.data ?? st.textSpan?.toPlainText() ?? '';
}

/// Pushes a chat page, feeds one assistant row carrying `[open](href)` and
/// taps it. [searching] selects bounded pumps instead of `pumpAndSettle`:
/// the candidate sheet keeps the loading phase's spinner alive, which
/// `pumpAndSettle` can never drain.
Future<void> _tapLink(
  WidgetTester tester,
  _Gateway gateway,
  String href, {
  bool searching = false,
}) async {
  await tester.pumpWidget(
    _wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
  );
  gateway.feedSnapshot([
    {
      'rowId': 900,
      'kind': 'assistantText',
      'text': '[open]($href)',
    },
  ]);
  await tester.pumpAndSettle();
  await tester.tap(find.text('open'));
  if (searching) {
    await _settle(tester);
  } else {
    await tester.pumpAndSettle();
  }
}

/// Bounded settle: the preview page keeps a spinner alive while the
/// candidate sheet is open, which `pumpAndSettle` can never drain.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

void main() {
  group('absolute-link basename fallback (PRD 11-09 abs)', () {
    testWidgets('AC1: a separator-eaten absolute link resolves by basename '
        'inside the workspace', (tester) async {
      // `F:\ZLinker\.local-archive\mocks\x.md` with `\.local` escaped to
      // `.local`: the drive-letter shape passes `_absolute` but the desktop
      // answers ENOENT.
      const broken = 'F:/ZLinker.local-archive/mocks/x.md';
      final gateway = _Gateway(
        {'/repo/app/mocks/x.md': '# recovered'},
        {
          '/repo/app': const [
            DirEntry(name: 'mocks', isDir: true),
            DirEntry(name: 'README.md', isDir: false),
          ],
          '/repo/app/mocks': const [
            DirEntry(name: 'x.md', isDir: false),
          ],
        },
      );
      await _tapLink(tester, gateway, broken);

      final files = gateway.fileService as _ScriptedFiles;
      expect(files.textReads.first, broken,
          reason: 'the absolute path is read as-is, no workspace join');
      expect(files.textReads, contains('/repo/app/mocks/x.md'),
          reason: 'the basename hit is opened directly (one read)');
      expect(files.dirReads.first, '/repo/app');
      expect(_sourceText(tester), contains('recovered'));
      expect(find.text('文件不存在或已被移动'), findsNothing);
    });

    testWidgets('AC2: several hits open the candidate sheet; the pick '
        'retargets the page', (tester) async {
      const broken = 'F:/ZLinker.local-archive/x.md';
      final gateway = _Gateway(
        {
          '/repo/app/docs/a/x.md': '# from docs',
          '/repo/app/docs/b/x.md': '# from other',
        },
        {
          '/repo/app': const [DirEntry(name: 'docs', isDir: true)],
          '/repo/app/docs': const [
            DirEntry(name: 'a', isDir: true),
            DirEntry(name: 'b', isDir: true),
          ],
          '/repo/app/docs/a': const [DirEntry(name: 'x.md', isDir: false)],
          '/repo/app/docs/b': const [DirEntry(name: 'x.md', isDir: false)],
        },
      );
      await _tapLink(tester, gateway, broken, searching: true);
      await _settle(tester);

      expect(find.text('找到多个同名文件'), findsOneWidget);
      expect(find.text('docs/a/x.md'), findsOneWidget);
      expect(find.text('docs/b/x.md'), findsOneWidget);

      await tester.tap(find.text('docs/a/x.md'));
      await _settle(tester);

      expect(_sourceText(tester), contains('from docs'));
      expect(find.text('docs/a/x.md'), findsOneWidget,
          reason: 'the appbar subtitle names the opened file');
    });

    testWidgets('AC3: a readable absolute link costs one read and zero '
        'readdir', (tester) async {
      final gateway = _Gateway({'/repo/app/notes.md': '# notes'}, const {});
      await _tapLink(tester, gateway, '/repo/app/notes.md');

      final files = gateway.fileService as _ScriptedFiles;
      expect(files.textReads, ['/repo/app/notes.md']);
      expect(files.dirReads, isEmpty,
          reason: 'a readable file must never burn search budget');
      expect(find.text('notes.md'), findsOneWidget);
    });

    testWidgets('AC4: a non-notFound failure does not trigger the search',
        (tester) async {
      const broken = '/repo/app/notes.md';
      final gateway = _Gateway(
        const {},
        const {},
        {broken: Exception('EACCES: permission denied, open \'$broken\'')},
      );
      await _tapLink(tester, gateway, broken);

      final files = gateway.fileService as _ScriptedFiles;
      expect(files.dirReads, isEmpty,
          reason: 'only ENOENT may pay for the workspace walk');
      expect(find.text('读取失败'), findsOneWidget);
      expect(find.text('文件不存在或已被移动'), findsNothing);
    });

    test('the resolver skips L2 (no reads) and reports the search as run',
        () async {
      final gateway = _Gateway(
        const {},
        {
          '/repo/app': const [DirEntry(name: 'mocks', isDir: true)],
          '/repo/app/mocks': const [DirEntry(name: 'x.md', isDir: false)],
        },
      );
      final preview = ChatPreview(gateway);

      final resolution = await preview.resolveAbsoluteLink(
        '/repo/app',
        'F:/ZLinker.local-archive/mocks/x.md',
      );

      final files = gateway.fileService as _ScriptedFiles;
      expect(files.textReads, isEmpty,
          reason: 'an absolute path names its own location — no base probes');
      expect(resolution.searched, isTrue);
      expect(resolution.candidates.single.path, '/repo/app/mocks/x.md');
      expect(resolution.candidates.single.label, 'mocks/x.md');
    });

    test('the resolver excludes the already-missed path from candidates',
        () async {
      // The workspace really does contain the same absolute path's basename
      // — but AT the failing path? A path outside the workspace cannot be
      // re-emitted by the search, so the realistic duplicate is a path that
      // the read refused while the listing still shows it (stale index).
      final gateway = _Gateway(
        const {},
        {
          '/repo/app': const [DirEntry(name: 'x.md', isDir: false)],
        },
      );
      final preview = ChatPreview(gateway);

      final resolution = await preview.resolveAbsoluteLink(
        '/repo/app',
        '/repo/app/x.md',
      );

      expect(resolution.candidates, isEmpty,
          reason: 'the link already missed at this exact path — listing it '
              'back would be a candidate that cannot open');
      expect(resolution.searched, isTrue);
    });

    test('an absolute path with no basename resolves to nothing, silently',
        () async {
      final gateway = _Gateway(const {}, const {});
      final preview = ChatPreview(gateway);

      final resolution = await preview.resolveAbsoluteLink('/repo/app', '/');

      expect(resolution.candidates, isEmpty);
      expect(resolution.searched, isFalse);
      expect((gateway.fileService as _ScriptedFiles).dirReads, isEmpty);
    });
  });
}
