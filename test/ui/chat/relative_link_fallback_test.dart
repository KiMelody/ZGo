import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/file_service.dart';
import 'package:zgo/ui/chat/chat_page.dart';
import 'package:zgo/ui/chat/file_preview_page.dart';
import 'package:zgo/ui/chat/file_read_result.dart';
import 'package:zgo/ui/chat/relative_link_resolver.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../../helpers/chat_role_fakes.dart';

/// A programmed file channel: `readText` answers per path from [files]
/// (ENOENT for anything absent, unless [honorRefusal] is off), `readdir`
/// answers [tree], and every call lands in [calls].
class _ScriptedFiles extends RecordingFileServicePort {
  _ScriptedFiles(super.recording, this.files, this.tree);

  /// Absolute path → file text (a present key means "this file reads").
  final Map<String, String> files;

  /// Absolute directory → entries.
  final Map<String, List<DirEntry>> tree;

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
  _Gateway(this.files, this.tree);

  final _Files files;
  final _Tree tree;
  @override
  late final FileServicePort fileService = _ScriptedFiles(
    recording,
    files,
    tree,
  );
}

/// Terse type aliases so the fixtures read as a table.
typedef _Files = Map<String, String>;
typedef _Tree = Map<String, List<DirEntry>>;

Widget _wrap(Widget child, {String locale = 'zh-CN'}) => MaterialApp(
      theme: buildDarkTheme(),
      darkTheme: buildDarkTheme(),
      builder: (context, child) => UiSettingsProvider(
        settings: UiSettings()..locale = locale,
        child: child!,
      ),
      home: child,
    );


/// Bounded settle: the preview page keeps a spinner alive while the
/// candidate sheet is open (its backdrop is the loading phase), which is a
/// permanent animation `pumpAndSettle` can never drain. Three frames cover
/// the sheet's route transition plus the retargeted read.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}


/// The source view's rendered plain text (the extension highlighter turns
/// `# ADR 8` into spans, so `find.text` cannot see the raw markdown).
String _sourceText(WidgetTester tester) {
  final st = tester.widget<SelectableText>(find.byType(SelectableText));
  return st.data ?? st.textSpan?.toPlainText() ?? '';
}

/// Pushes a chat page carrying [rows], taps the markdown link [href] and
/// settles everything the preview page's read chain does.
Future<void> _tapLink(
  WidgetTester tester,
  _Gateway gateway,
  String href, {
  List<Map<String, dynamic>> rows = const [],
  String locale = 'zh-CN',
}) async {
  await tester.pumpWidget(_wrap(
    ChatPage(host: gateway, sessionId: 's1', title: 't'),
    locale: locale,
  ));
  gateway.feedSnapshot([
    ...rows,
    {
      'rowId': 900,
      'kind': 'assistantText',
      'text': '[open]($href)',
    },
  ]);
  await tester.pumpAndSettle();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// One Read tool row pointing at [filePath] (the L2 base source).
Map<String, dynamic> _readRow(int id, String filePath) => {
      'rowId': id,
      'kind': 'toolCall',
      'toolName': 'Read',
      'input': {'filePath': filePath},
    };

void main() {
  group('fallback chain (design 11-09, PRD AC1/AC2/AC5)', () {
    testWidgets('AC5: an L1 hit costs exactly one read and zero readdir',
        (tester) async {
      final gateway = _Gateway(
        {'/repo/app/notes.md': '# notes'},
        const {},
      );
      await _tapLink(tester, gateway, 'notes.md');

      final files = gateway.fileService as _ScriptedFiles;
      expect(files.textReads, ['/repo/app/notes.md']);
      expect(files.dirReads, isEmpty,
          reason: 'a readable file must never burn search budget');
      expect(find.text('notes.md'), findsOneWidget);
    });

    testWidgets('AC1: a link relative to the last Read row resolves via L2 '
        'with zero readdir', (tester) async {
      final gateway = _Gateway(
        {'/repo/app/docs/adr/0008-new.md': '# ADR 8'},
        const {},
      );
      await _tapLink(
        tester,
        gateway,
        'adr/0008-new.md',
        rows: [_readRow(1, '/repo/app/docs/adr/0007-old.md')],
      );

      final files = gateway.fileService as _ScriptedFiles;
      expect(files.textReads.first, '/repo/app/adr/0008-new.md',
          reason: 'L1: the workspace root join misses');
      expect(files.textReads, contains('/repo/app/docs/adr/0008-new.md'),
          reason: "L2 reaches the Read row's own directory");
      expect(files.textReads.last, '/repo/app/docs/adr/0008-new.md');
      expect(files.textReads.length, files.textReads.toSet().length,
          reason: 'the L2 hit is read ONCE — its probe result seeds the '
              'page memo instead of a second identical RPC');
      expect(files.dirReads, isEmpty, reason: 'L2 hit must short-circuit L3');
      expect(_sourceText(tester), contains('ADR 8'));
    });

    testWidgets('AC2: L3 finds a unique basename in a stranger directory',
        (tester) async {
      final gateway = _Gateway(
        {'/repo/app/some/deep/dir/0008-adr.md': '# deep'},
        {
          '/repo/app': const [
            DirEntry(name: 'some', isDir: true),
            DirEntry(name: 'README.md', isDir: false),
          ],
          '/repo/app/some': const [DirEntry(name: 'deep', isDir: true)],
          '/repo/app/some/deep': const [DirEntry(name: 'dir', isDir: true)],
          '/repo/app/some/deep/dir': const [
            DirEntry(name: '0008-adr.md', isDir: false),
          ],
        },
      );
      await _tapLink(tester, gateway, 'adr/0008-adr.md');

      final files = gateway.fileService as _ScriptedFiles;
      expect(files.textReads.first, '/repo/app/adr/0008-adr.md'); // L1 miss
      expect(files.textReads,
          contains('/repo/app/some/deep/dir/0008-adr.md'),
          reason: 'the L3 hit is opened directly (one read, no stat probe)');
      expect(files.dirReads.first, '/repo/app');
      // plainText renders the SOURCE view: the text lives in SelectableText.
      expect(_sourceText(tester), contains('deep'));
      expect(find.textContaining('some/deep/dir/0008-adr.md'), findsOneWidget,
          reason: 'the appbar subtitle shows the actual opened path');
    });

    testWidgets('a binary L1 hit does not trigger the fallback', (tester) async {
      final gateway = _Gateway(const {}, const {});
      // Make the root read answer a binary chunk instead of ENOENT.
      final files = gateway.fileService as _ScriptedFiles;
      await tester.pumpWidget(_wrap(
        FilePreviewPage(
          path: '/repo/app/blob.dat',
          render: FilePreviewRender.plainText,
          readText: (path) async {
            files.textReads.add(path);
            return const FileTextResult(
              failure: FileReadFailure.binary,
              totalBytes: 16,
            );
          },
          readMediaDataUrl: (path) async => null,
          resolveLinkFallback: () async {
            throw StateError('the fallback must not run for a binary file');
          },
          workspacePath: '/repo/app',
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('二进制文件，无文本预览'), findsOneWidget);
    });

    testWidgets('a failed search degrades to the plain not-found error',
        (tester) async {
      await tester.pumpWidget(_wrap(
        FilePreviewPage(
          path: '/repo/app/adr/x.md',
          render: FilePreviewRender.plainText,
          readText: (path) async =>
              const FileTextResult(failure: FileReadFailure.notFound),
          readMediaDataUrl: (path) async => null,
          resolveLinkFallback: () async => throw StateError('boom'),
          workspacePath: '/repo/app',
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('文件不存在或已被移动'), findsOneWidget);
      expect(find.text('已搜索工作区，未找到同名文件'), findsNothing,
          reason: 'a broken search must not claim it searched');
    });

    testWidgets('AC7: a zero-hit search appends the searched-workspace line',
        (tester) async {
      await tester.pumpWidget(_wrap(
        FilePreviewPage(
          path: '/repo/app/adr/x.md',
          render: FilePreviewRender.plainText,
          readText: (path) async =>
              const FileTextResult(failure: FileReadFailure.notFound),
          readMediaDataUrl: (path) async => null,
          resolveLinkFallback: () async => const PreviewResolution(
            searched: true,
          ),
          workspacePath: '/repo/app',
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('文件不存在或已被移动'), findsOneWidget);
      expect(find.text('已搜索工作区，未找到同名文件'), findsOneWidget);
    });

    testWidgets('AC3: several hits open the candidate sheet and the pick '
        'retargets the page', (tester) async {
      final reads = <String>[];
      await tester.pumpWidget(_wrap(
        FilePreviewPage(
          path: '/repo/app/adr/x.md',
          render: FilePreviewRender.plainText,
          readText: (path) async {
            reads.add(path);
            if (path == '/repo/app/docs/a/x.md') {
              return const FileTextResult(text: '# from docs');
            }
            return const FileTextResult(failure: FileReadFailure.notFound);
          },
          readMediaDataUrl: (path) async => null,
          resolveLinkFallback: () async => const PreviewResolution(
            candidates: [
              PreviewCandidate(
                  path: '/repo/app/docs/a/x.md', label: 'docs/a/x.md'),
              PreviewCandidate(
                  path: '/repo/app/docs/b/x.md', label: 'docs/b/x.md'),
            ],
            searched: true,
          ),
          workspacePath: '/repo/app',
        ),
      ));
      await _settle(tester);

      expect(find.text('找到多个同名文件'), findsOneWidget);
      expect(find.text('docs/a/x.md'), findsOneWidget);
      expect(find.text('docs/b/x.md'), findsOneWidget);

      await tester.tap(find.text('docs/a/x.md'));
      await _settle(tester);

      expect(reads, contains('/repo/app/docs/a/x.md'));
      expect(_sourceText(tester), contains('from docs'));
      expect(find.text('docs/a/x.md'), findsOneWidget,
          reason: 'the appbar subtitle still names the opened file');
    });

    testWidgets('dismissing the candidate sheet keeps the error view',
        (tester) async {
      await tester.pumpWidget(_wrap(
        FilePreviewPage(
          path: '/repo/app/adr/x.md',
          render: FilePreviewRender.plainText,
          readText: (path) async =>
              const FileTextResult(failure: FileReadFailure.notFound),
          readMediaDataUrl: (path) async => null,
          resolveLinkFallback: () async => const PreviewResolution(
            candidates: [
              PreviewCandidate(path: '/repo/app/a/x.md', label: 'a/x.md'),
              PreviewCandidate(path: '/repo/app/b/x.md', label: 'b/x.md'),
            ],
            searched: true,
          ),
          workspacePath: '/repo/app',
        ),
      ));
      await _settle(tester);

      // Barriered dismissal: tap the scrim above the sheet.
      await tester.tapAt(const Offset(10, 10));
      await _settle(tester);

      expect(find.text('文件不存在或已被移动'), findsOneWidget);
      expect(find.text('已搜索工作区，未找到同名文件'), findsNothing,
          reason: 'candidates WERE found (the sheet listed them) — the '
              '"nothing found" appendix would contradict what the user just '
              'saw');
    });

    testWidgets('the searching state says so while the walk runs',
        (tester) async {
      final gate = Completer<PreviewResolution>();
      await tester.pumpWidget(_wrap(
        FilePreviewPage(
          path: '/repo/app/adr/x.md',
          render: FilePreviewRender.plainText,
          readText: (path) async =>
              const FileTextResult(failure: FileReadFailure.notFound),
          readMediaDataUrl: (path) async => null,
          resolveLinkFallback: () => gate.future,
          workspacePath: '/repo/app',
        ),
      ));
      await tester.pump();
      await tester.pump();

      expect(find.text('正在查找…'), findsOneWidget);

      gate.complete(const PreviewResolution(searched: true));
      await tester.pumpAndSettle();

      expect(find.text('正在查找…'), findsNothing);
      expect(find.text('已搜索工作区，未找到同名文件'), findsOneWidget);
    });

    testWidgets('AC7 en: the three new strings render in English',
        (tester) async {
      final gate = Completer<PreviewResolution>();
      await tester.pumpWidget(_wrap(
        FilePreviewPage(
          path: '/repo/app/adr/x.md',
          render: FilePreviewRender.plainText,
          readText: (path) async =>
              const FileTextResult(failure: FileReadFailure.notFound),
          readMediaDataUrl: (path) async => null,
          resolveLinkFallback: () => gate.future,
          workspacePath: '/repo/app',
        ),
        locale: 'en-US',
      ));
      await tester.pump();
      await tester.pump();
      expect(find.text('Looking for it…'), findsOneWidget);

      gate.complete(const PreviewResolution(searched: true));
      await tester.pumpAndSettle();
      expect(find.text('Searched the workspace: no file with that name'),
          findsOneWidget);
    });
  });
}
