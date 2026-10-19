import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/file_service.dart';
import 'package:zgo/protocol/git_service.dart';
import 'package:zgo/ui/chat/chat_preview.dart';
import 'package:zgo/ui/chat/diff_view.dart';
import 'package:zgo/ui/chat/file_preview_page.dart';
import 'package:zgo/ui/chat/git_panel.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../../helpers/recording_chat_gateway.dart';

/// Records every wire call the port makes and answers from [_handler].
class _FakeGit {
  _FakeGit(this._handler);

  final Future<dynamic> Function(String method, List<Object?> args) _handler;
  final List<(String, List<Object?>)> calls = [];

  late final GitPort port = GitPort((method, args) async {
    calls.add((method, args));
    return _handler(method, args);
  });

  List<String> get methods => [for (final c in calls) c.$1];
  int countOf(String m) => methods.where((x) => x == m).length;
}

/// A repository with one unstaged file, one untracked file and two branches.
Future<dynamic> _repoHandler(String method, List<Object?> args) async {
  switch (method) {
    case 'getRepositorySummary':
      return {
        'isRepository': true,
        'branchName': 'main',
        'isDirty': true,
        'headRefType': 'branch',
      };
    case 'refresh':
      return {'summary': <String, Object?>{}};
    case 'getChanges':
      return <Object?>[
        {
          'path': '/repo/a.dart',
          'workspaceRelativePath': 'lib/a.dart',
          'kind': 'modified',
          'section': 'unstaged',
          'added': 5,
          'removed': 2,
        },
        {
          'path': '/repo/b.dart',
          'workspaceRelativePath': 'lib/b.dart',
          'kind': 'untracked',
          'section': 'untracked',
          'isUntracked': true,
          'added': 3,
        },
      ];
    case 'getLocalBranches':
      return {
        'headRefType': 'branch',
        'currentBranchName': 'main',
        'branches': [
          {'name': 'main', 'isCurrent': true, 'upstreamName': 'origin/main'},
          {'name': 'dev', 'isCurrent': false},
        ],
      };
    case 'getIdentity':
      return {'userName': 'Ada', 'userEmail': 'ada@example.com'};
    case 'getDiff':
      return {
        'path': 'lib/a.dart',
        'availability': 'patch',
        'patch': '@@ -1,2 +1,2 @@\n ctx\n-old\n+new\n',
      };
    case 'switchBranch':
      return {'ok': true, 'didChange': true, 'branchName': 'dev'};
    case 'commit':
      return {'commitHash': 'abc', 'summary': 'x'};
    case 'push':
      return {'branchName': 'main', 'trackingBranchName': 'origin/main'};
    case 'stagePaths':
    case 'unstagePaths':
      return null;
    case 'generateCommitMessage':
      return {'message': 'feat: generated'};
    default:
      throw StateError('unexpected $method');
  }
}

Future<dynamic> _nonRepoHandler(String method, List<Object?> args) async {
  if (method == 'getRepositorySummary') {
    return {'kind': 'not-repository', 'isGitAvailable': true};
  }
  throw StateError('unexpected $method');
}

Future<dynamic> _brokenHandler(String method, List<Object?> args) async {
  throw ChannelRpcError('not connected', null);
}

Future<dynamic> _gitUnavailableHandler(String method, List<Object?> args) async {
  if (method == 'getRepositorySummary') {
    return {'kind': 'not-repository', 'isRepository': false, 'isGitAvailable': false};
  }
  throw StateError('unexpected $method');
}

Widget _wrap(Widget child, [UiSettings? settings]) => MaterialApp(
      builder: (context, c) =>
          UiSettingsProvider(settings: settings ?? UiSettings(), child: c!),
      home: Scaffold(body: child),
    );

/// Pumps enough frames for the async load chain to resolve and for
/// modal-sheet/dialog enter animations to finish (never pumpAndSettle while
/// the loading spinner is animating).
Future<void> _flush(WidgetTester tester, [int n = 8]) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// A tall surface so bottom-sheet rows never fall below the default 600px
/// test viewport (the taps would miss otherwise).
void _tallView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

GitWorkspaceController _controller(_FakeGit fake) =>
    GitWorkspaceController(fake.port, '/repo');

void main() {
  group('unifiedDiffToDiffData', () {
    test('maps hunk/±/context lines and drops diff metadata', () {
      const patch = 'diff --git a/a b/a\n'
          'index 1a2b3c..4d5e6f 100644\n'
          '--- a/a\n'
          '+++ b/a\n'
          '@@ -1,3 +1,3 @@\n'
          ' ctx\n'
          '-old\n'
          '+new\n';
      final data = unifiedDiffToDiffData(
        patch,
        filePath: 'lib/a.dart',
        additions: 1,
        deletions: 1,
      );
      expect(data.filePath, 'lib/a.dart');
      expect(data.additions, 1);
      expect(data.deletions, 1);
      expect(data.lines.map((l) => l.type).toList(), [
        DiffLineType.context, // @@ hunk header kept as a marker
        DiffLineType.context, // ' ctx'
        DiffLineType.removed,
        DiffLineType.added,
      ]);
      expect(data.lines.first.text, '@@ -1,3 +1,3 @@');
      expect(data.lines[2].text, '-old');
      expect(data.lines[3].text, '+new');
    });

    test('binary markers and file headers never leak into the body', () {
      const patch = 'diff --git a/bin b/bin\n'
          'Binary files a/bin and b/bin differ\n';
      final data = unifiedDiffToDiffData(patch);
      expect(data.lines, isEmpty);
    });
  });

  group('GitWorkspaceController lifecycle', () {
    testWidgets('an in-flight reload completing after dispose does not throw',
        (tester) async {
      final gate = Completer<void>();
      final fake = _FakeGit((method, args) async {
        if (method == 'getRepositorySummary') {
          await gate.future;
          return {'isRepository': true, 'branchName': 'main'};
        }
        return _repoHandler(method, args);
      });
      final c = _controller(fake);
      await tester.pumpWidget(_wrap(GitStatusGroup(controller: c)));
      await tester.pump(); // initState started the load; it is now in flight
      c.dispose();
      gate.complete();
      await tester.pump();
      // No FlutterError from notifying a disposed notifier.
      expect(tester.takeException(), isNull);
    });

    test('a reload requested during an in-flight read is replayed, not dropped',
        () async {
      final gate = Completer<void>();
      var summaryCalls = 0;
      final fake = _FakeGit((method, args) async {
        if (method == 'getRepositorySummary') {
          summaryCalls++;
          if (summaryCalls == 1) await gate.future;
          return {'isRepository': true, 'branchName': 'main'};
        }
        return _repoHandler(method, args);
      });
      final c = _controller(fake);
      final first = c.reload(); // in flight
      final second = c.reload(); // queued behind the first
      gate.complete();
      await first;
      await second;
      expect(summaryCalls, 2);
      expect(c.loading, isFalse);
    });
  });

  group('ChangeCapsule', () {
    testWidgets('workspace summary wins over the turn summary', (tester) async {
      await tester.pumpWidget(_wrap(ChangeCapsule(
        gitWorktree: const GitChangeStats(fileCount: 2, added: 105, removed: 0),
        activeTask: const GitChangeStats(fileCount: 1, added: 5, removed: 5),
        onOpen: () {},
      )));
      expect(find.text('更改'), findsOneWidget);
      expect(find.textContaining('+105'), findsOneWidget);
      expect(find.textContaining('+5'), findsNothing);
    });

    testWidgets('falls back to the turn summary when the workspace is clean',
        (tester) async {
      await tester.pumpWidget(_wrap(ChangeCapsule(
        activeTask: const GitChangeStats(fileCount: 1, added: 5, removed: 5),
        onOpen: () {},
      )));
      expect(find.textContaining('+5'), findsOneWidget);
      expect(find.textContaining('-5'), findsOneWidget);
    });

    testWidgets('renders nothing when neither source is present',
        (tester) async {
      await tester.pumpWidget(_wrap(ChangeCapsule(onOpen: () {})));
      expect(find.text('更改'), findsNothing);
      expect(find.byType(InkWell), findsNothing);
    });

    testWidgets('renders as a full-width card at the chat-tile spec',
        (tester) async {
      await tester.pumpWidget(_wrap(ChangeCapsule(
        activeTask: const GitChangeStats(fileCount: 1, added: 5, removed: 5),
        onOpen: () {},
      )));

      final container = tester.widget<Container>(find.ancestor(
        of: find.text('更改'),
        matching: find.byType(Container),
      ).first);
      final decor = container.decoration! as BoxDecoration;
      // Card tokens (user-directed 10-14): tile radius with the hairline
      // border kept, head-row height floor and horizontal inset.
      expect(decor.borderRadius, BorderRadius.circular(ZRadius.tile));
      expect(decor.border, isNotNull);
      expect(container.constraints!.minHeight, ZTile.headHeight);
      expect(container.padding, ZTile.head);
      // Splash follows the new radius.
      final ink = tester.widget<InkWell>(find.ancestor(
        of: find.text('更改'),
        matching: find.byType(InkWell),
      ));
      expect(ink.borderRadius, BorderRadius.circular(ZRadius.tile));
      // Spans the full column width — no content-adaptive shrink-wrap.
      expect(tester.getSize(find.ancestor(
        of: find.text('更改'),
        matching: find.byType(Container),
      ).first).width, tester.getSize(find.byType(ChangeCapsule)).width);
      // Copy and icon at the shared head-row spec (sub / 16, not the old
      // caption / 13 chip), plus the sibling-card bottom rhythm.
      expect(tester.widget<Text>(find.text('更改')).style!.fontSize,
          ZType.sub.fontSize);
      expect(tester.widget<Icon>(find.byIcon(Icons.edit_note_outlined)).size,
          ZTile.iconSize);
      expect(
        tester.widget<Padding>(find.byWidgetPredicate((w) =>
            w is Padding &&
            w.padding == const EdgeInsets.only(bottom: ZTile.seam))).padding,
        const EdgeInsets.only(bottom: ZTile.seam),
      );
    });
  });

  group('GitStatusGroup', () {
    testWidgets('renders the git rows for a repository workspace',
        (tester) async {
      final fake = _FakeGit(_repoHandler);
      await tester.pumpWidget(_wrap(GitStatusGroup(controller: _controller(fake))));
      await _flush(tester);

      expect(find.text('Git 工具'), findsOneWidget);
      expect(find.text('更改'), findsOneWidget);
      expect(find.text('main'), findsOneWidget);
      expect(find.text('提交或推送'), findsOneWidget);
      // workspace-level total (+5 +3, -2) — the group aggregates all rows.
      expect(find.textContaining('+8'), findsWidgets);
      expect(find.textContaining('未提交的更改'), findsOneWidget);
    });

    testWidgets('hides entirely on a non-repository workspace',
        (tester) async {
      final fake = _FakeGit(_nonRepoHandler);
      await tester.pumpWidget(_wrap(GitStatusGroup(controller: _controller(fake))));
      await _flush(tester);

      expect(find.text('Git 工具'), findsNothing);
      expect(find.text('更改'), findsNothing);
    });

    testWidgets('shows a human-readable failure row when the read fails',
        (tester) async {
      final fake = _FakeGit(_brokenHandler);
      await tester.pumpWidget(_wrap(GitStatusGroup(controller: _controller(fake))));
      await _flush(tester);

      expect(find.text('Git 工具'), findsOneWidget);
      expect(find.text('无法加载 Git 改动'), findsOneWidget);
    });

    testWidgets('git-unavailable workspace shows the unavailable empty state',
        (tester) async {
      final fake = _FakeGit(_gitUnavailableHandler);
      await tester.pumpWidget(_wrap(GitStatusGroup(controller: _controller(fake))));
      await _flush(tester);

      expect(find.text('Git 不可用'), findsOneWidget);
      expect(find.text('未检测到 git 可执行文件'), findsOneWidget);
      expect(find.text('更改'), findsNothing);
    });

    testWidgets('tapping the header collapses the rows and back',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = UiSettings();
      final fake = _FakeGit(_repoHandler);
      await tester.pumpWidget(
          _wrap(GitStatusGroup(controller: _controller(fake)), settings));
      await _flush(tester);
      expect(fake.countOf('getRepositorySummary'), 1);

      await tester.tap(find.text('Git 工具'));
      await _flush(tester);
      expect(settings.gitToolsCollapsed, isTrue);
      expect(find.text('更改'), findsNothing);
      expect(find.text('提交或推送'), findsNothing);
      // Collapsed keeps the header with a compact stats summary.
      expect(find.text('Git 工具'), findsOneWidget);
      expect(find.textContaining('+8'), findsWidgets);

      await tester.tap(find.text('Git 工具'));
      await _flush(tester);
      expect(settings.gitToolsCollapsed, isFalse);
      expect(find.text('更改'), findsOneWidget);
      expect(find.text('提交或推送'), findsOneWidget);
      // Collapse cycling never re-issues the workspace read.
      expect(fake.countOf('getRepositorySummary'), 1);
    });

    testWidgets('settings switch off hides the group and issues no reads',
        (tester) async {
      final settings = UiSettings()..gitToolsPanelEnabled = false;
      final fake = _FakeGit(_repoHandler);
      await tester.pumpWidget(
          _wrap(GitStatusGroup(controller: _controller(fake)), settings));
      await _flush(tester);

      expect(find.text('Git 工具'), findsNothing);
      expect(find.text('更改'), findsNothing);
      expect(fake.countOf('getRepositorySummary'), 0);
    });

    testWidgets('short viewport shows the capsule: one line collapsed, '
        'two lines expanded with sheet links, re-armed per landscape stint',
        (tester) async {
      // Landscape-phone shape: wide and short (<480 logical height).
      tester.view.physicalSize = const Size(2400, 1080);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final settings = UiSettings();
      final fake = _FakeGit(_repoHandler);
      await tester.pumpWidget(
          _wrap(GitStatusGroup(controller: _controller(fake)), settings));
      await _flush(tester);

      // Collapsed: single line, no inline rows, compact stats summary.
      expect(find.text('更改'), findsNothing);
      expect(find.textContaining('+8'), findsWidgets);
      expect(settings.gitToolsCollapsed, isFalse); // untouched

      // Expand: two lines with quick links (no inline status rows).
      await tester.tap(find.text('Git 工具'));
      await _flush(tester);
      expect(find.text('更改'), findsOneWidget); // link on the second line
      expect(find.text('main'), findsOneWidget);
      expect(find.text('提交或推送'), findsOneWidget);
      expect(fake.countOf('getRepositorySummary'), 1); // never re-issued

      // The changes link opens the full-height review sheet.
      await tester.tap(find.text('更改'));
      await _flush(tester);
      expect(find.byType(GitReviewPanel), findsOneWidget);
      // Dismiss via a scrim tap (outside the 92%-height sheet).
      await tester.tapAt(const Offset(20, 20));
      await _flush(tester);

      // Back on a portrait viewport the persisted preference rules: the
      // card shows its inline rows.
      tester.view.physicalSize = const Size(1080, 2400);
      await tester.pump();
      await _flush(tester);
      expect(find.text('更改'), findsOneWidget);

      // Re-entering landscape re-arms the one-line capsule.
      tester.view.physicalSize = const Size(2400, 1080);
      await tester.pump();
      await _flush(tester);
      expect(find.text('更改'), findsNothing);
      expect(find.textContaining('+8'), findsWidgets);
    });
  });

  group('GitReviewPanel', () {
    testWidgets('first load in flight shows a spinner, not the '
        'not-repository empty state', (tester) async {
      final gate = Completer<void>();
      Future<dynamic> slowSummary(String method, List<Object?> args) async {
        if (method == 'getRepositorySummary') {
          await gate.future;
          return {'isRepository': true, 'branchName': 'main'};
        }
        return _repoHandler(method, args);
      }

      final fake = _FakeGit(slowSummary);
      final c = _controller(fake);
      // showGitReviewPanel kicks off the reload right before building the
      // sheet; hold the summary read open so the panel paints mid-load.
      unawaited(c.reload());
      await tester.pumpWidget(_wrap(GitReviewPanel(controller: c)));

      expect(find.byType(CircularProgressIndicator), findsWidgets);
      expect(find.text('不是 Git 仓库'), findsNothing);
      expect(find.text('当前工作区不受 Git 管理'), findsNothing);

      gate.complete();
      await _flush(tester);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('lib/a.dart'), findsOneWidget);
    });

    testWidgets('no workspace bound renders the not-repository verdict, '
        'never an eternal spinner', (tester) async {
      final fake = _FakeGit(_repoHandler);
      // Empty workspacePath: reload() no-ops on the available guard, so the
      // panel must fall to the verdict branch instead of spinning forever.
      final c = GitWorkspaceController(fake.port, '');
      await tester.pumpWidget(_wrap(GitReviewPanel(controller: c)));
      await _flush(tester);

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('不是 Git 仓库'), findsOneWidget);
      expect(fake.countOf('getRepositorySummary'), 0); // no RPC was issued
    });

    testWidgets('groups untracked/unstaged rows and stages a file',
        (tester) async {
      final fake = _FakeGit(_repoHandler);
      final c = _controller(fake);
      await c.reload();
      await tester.pumpWidget(_wrap(GitReviewPanel(controller: c)));
      await _flush(tester);

      expect(find.text('未跟踪'), findsOneWidget);
      expect(find.text('lib/a.dart'), findsOneWidget);
      expect(find.text('lib/b.dart'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, '暂存').first);
      await _flush(tester);
      expect(fake.countOf('stagePaths'), greaterThanOrEqualTo(1));
    });

    testWidgets('tapping a file renders its unified diff through DiffView',
        (tester) async {
      final fake = _FakeGit(_repoHandler);
      final c = _controller(fake);
      await c.reload();
      await tester.pumpWidget(_wrap(GitReviewPanel(controller: c)));
      await _flush(tester);

      await tester.tap(find.text('lib/a.dart'));
      await _flush(tester);
      expect(find.byType(DiffView), findsOneWidget);
      expect(find.text('+new'), findsOneWidget);
      expect(find.text('-old'), findsOneWidget);
    });

    testWidgets('availability binary degrades to the binary title',
        (tester) async {
      Future<dynamic> binaryDiff(String method, List<Object?> args) async {
        if (method == 'getDiff') {
          return {'path': 'lib/a.dart', 'availability': 'binary'};
        }
        return _repoHandler(method, args);
      }

      final fake = _FakeGit(binaryDiff);
      final c = _controller(fake);
      await c.reload();
      await tester.pumpWidget(_wrap(GitReviewPanel(controller: c)));
      await _flush(tester);

      await tester.tap(find.text('lib/a.dart'));
      await _flush(tester);
      expect(find.text('二进制文件'), findsOneWidget);
      expect(find.byType(DiffView), findsNothing);
    });

    testWidgets('non-repository workspace shows the not-repository empty state',
        (tester) async {
      final fake = _FakeGit(_nonRepoHandler);
      final c = _controller(fake);
      await c.reload();
      await tester.pumpWidget(_wrap(GitReviewPanel(controller: c)));
      await _flush(tester);

      expect(find.text('不是 Git 仓库'), findsOneWidget);
    });

    testWidgets('git-unavailable workspace shows the unavailable empty state',
        (tester) async {
      final fake = _FakeGit(_gitUnavailableHandler);
      final c = _controller(fake);
      await c.reload();
      await tester.pumpWidget(_wrap(GitReviewPanel(controller: c)));
      await _flush(tester);

      expect(find.text('Git 不可用'), findsOneWidget);
      expect(find.text('未检测到 git 可执行文件'), findsOneWidget);
    });

    testWidgets('truncated diffs render their rows plus the truncation notice',
        (tester) async {
      Future<dynamic> truncatedDiff(String method, List<Object?> args) async {
        if (method == 'getDiff') {
          return {
            'path': 'lib/a.dart',
            'availability': 'truncated',
            'patch': '@@ -1,2 +1,2 @@\n ctx\n-old\n+new\n',
          };
        }
        return _repoHandler(method, args);
      }

      final fake = _FakeGit(truncatedDiff);
      final c = _controller(fake);
      await c.reload();
      await tester.pumpWidget(_wrap(GitReviewPanel(controller: c)));
      await _flush(tester);

      await tester.tap(find.text('lib/a.dart'));
      await _flush(tester);
      expect(find.byType(DiffView), findsOneWidget);
      expect(find.text('+new'), findsOneWidget);
      expect(find.text('Diff 已截断'), findsOneWidget);
    });
  });

  group('GitReviewPanel preview entry (S7/R8b)', () {
    /// The `_repoHandler` changed set widened with the dispatch boundary
    /// family (PRD R2-L3): extension-less name, dot-file, double extension
    /// and a blacklist representative — one row per gating verdict.
    Future<dynamic> mixedChangesHandler(
        String method, List<Object?> args) async {
      if (method == 'getChanges') {
        return <Object?>[
          for (final rel in const [
            'lib/a.dart',
            'Makefile',
            '.gitignore',
            'bundle.tar.gz',
            'assets/font.woff2',
          ])
            {
              'path': '/repo/$rel',
              'workspaceRelativePath': rel,
              'kind': 'modified',
              'section': 'unstaged',
              'added': 1,
            },
        ];
      }
      return _repoHandler(method, args);
    }

    testWidgets('dispatchable rows grow the open icon and it dispatches '
        'through the chat rows\' own routing table', (tester) async {
      _tallView(tester);
      final fake = _FakeGit(mixedChangesHandler);
      final c = _controller(fake);
      await c.reload();
      final gateway = RecordingChatGateway()
        ..fileReadTextResult = const TextChunk(
          text: 'void main() {}',
          bytesRead: 14,
          totalBytes: 14,
          hasMore: false,
        );
      await tester.pumpWidget(
        _wrap(GitReviewPanel(controller: c, preview: ChatPreview(gateway))),
      );
      await _flush(tester);

      // The icon set IS the shared judgment's verdict — asserted against
      // the same function the chat rows consult (one source, two entries).
      final openable = const [
        'lib/a.dart',
        'Makefile',
        '.gitignore',
        'bundle.tar.gz',
        'assets/font.woff2',
      ].where((p) => ChatPreview.dispatchable('/repo/$p')).toList();
      expect(openable, ['lib/a.dart', 'Makefile', '.gitignore']);
      expect(
        find.byIcon(Icons.visibility_outlined),
        findsNWidgets(openable.length),
      );

      await tester.tap(find.byIcon(Icons.visibility_outlined).first);
      await _flush(tester);

      // Row order: the unstaged section renders the changed set as given,
      // so `.first` is lib/a.dart — a plainText source preview over the
      // panel, leaving the review sheet behind.
      expect(find.byType(FilePreviewPage), findsOneWidget);
      expect(
        tester.widget<FilePreviewPage>(find.byType(FilePreviewPage)).render,
        FilePreviewRender.plainText,
      );
      expect(find.textContaining('void main'), findsWidgets);
      expect(
        gateway.calls.where((x) => x.$1 == 'fileReadText').single.$2,
        containsAllInOrder(['/repo/app', '/repo/lib/a.dart']),
      );
    });

    testWidgets('a host without a preview renders no icon and keeps the '
        'diff-only row', (tester) async {
      _tallView(tester);
      final fake = _FakeGit(mixedChangesHandler);
      final c = _controller(fake);
      await c.reload();
      await tester.pumpWidget(_wrap(GitReviewPanel(controller: c)));
      await _flush(tester);

      expect(find.byIcon(Icons.visibility_outlined), findsNothing);

      await tester.tap(find.text('lib/a.dart'));
      await _flush(tester);
      expect(find.byType(DiffView), findsOneWidget);
    });

    testWidgets('with the preview wired, the primary tap and the stage '
        'button keep their own paths', (tester) async {
      _tallView(tester);
      final fake = _FakeGit(mixedChangesHandler);
      final c = _controller(fake);
      await c.reload();
      await tester.pumpWidget(
        _wrap(
          GitReviewPanel(
            controller: c,
            preview: ChatPreview(RecordingChatGateway()),
          ),
        ),
      );
      await _flush(tester);

      // Primary tap → the diff path, untouched by the new icon.
      await tester.tap(find.text('lib/a.dart'));
      await _flush(tester);
      expect(find.byType(DiffView), findsOneWidget);
      expect(find.byType(FilePreviewPage), findsNothing);

      // Back out of the diff, then stage through the button beside the icon.
      await tester.tap(find.byIcon(Icons.arrow_back));
      await _flush(tester);
      await tester.tap(find.widgetWithText(TextButton, '暂存').first);
      await _flush(tester);
      expect(fake.countOf('stagePaths'), greaterThanOrEqualTo(1));
    });
  });

  group('write gates (no confirmation → no call)', () {
    testWidgets('branch switch: cancelling the confirm dialog calls nothing',
        (tester) async {
      _tallView(tester);
      final fake = _FakeGit(_repoHandler);
      await tester.pumpWidget(_wrap(GitStatusGroup(controller: _controller(fake))));
      await _flush(tester);

      await tester.tap(find.byIcon(Icons.alt_route_outlined));
      await _flush(tester);
      expect(find.text('dev'), findsOneWidget);
      await tester.tap(find.text('dev'));
      await _flush(tester);
      expect(find.text('切换到 dev？'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await _flush(tester);
      expect(fake.countOf('switchBranch'), 0);
    });

    testWidgets('branch switch: confirming the dialog performs the switch',
        (tester) async {
      _tallView(tester);
      final fake = _FakeGit(_repoHandler);
      await tester.pumpWidget(_wrap(GitStatusGroup(controller: _controller(fake))));
      await _flush(tester);

      await tester.tap(find.byIcon(Icons.alt_route_outlined));
      await _flush(tester);
      await tester.tap(find.text('dev'));
      await _flush(tester);
      await tester.tap(find.text('切换'));
      await _flush(tester);
      expect(fake.countOf('switchBranch'), 1);
    });

    testWidgets('commit: dismissing the dialog calls nothing', (tester) async {
      _tallView(tester);
      final fake = _FakeGit(_repoHandler);
      await tester.pumpWidget(_wrap(GitStatusGroup(controller: _controller(fake))));
      await _flush(tester);

      await tester.tap(find.byIcon(Icons.upload_outlined));
      await _flush(tester);
      await tester.tap(find.text('提交'));
      await _flush(tester);
      expect(find.text('提交更改'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await _flush(tester);
      expect(fake.countOf('commit'), 0);
    });

    testWidgets('push: cancelling the confirm dialog calls nothing',
        (tester) async {
      _tallView(tester);
      final fake = _FakeGit(_repoHandler);
      await tester.pumpWidget(_wrap(GitStatusGroup(controller: _controller(fake))));
      await _flush(tester);

      await tester.tap(find.byIcon(Icons.upload_outlined));
      await _flush(tester);
      await tester.tap(find.text('推送'));
      await _flush(tester);
      expect(find.text('推送更改'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await _flush(tester);
      expect(fake.countOf('push'), 0);
    });

    testWidgets('identityMissing blocks commit and shows the copy',
        (tester) async {
      _tallView(tester);
      Future<dynamic> noIdentity(String method, List<Object?> args) async {
        if (method == 'getIdentity') {
          return {'userName': null, 'userEmail': null};
        }
        return _repoHandler(method, args);
      }

      final fake = _FakeGit(noIdentity);
      await tester.pumpWidget(_wrap(GitStatusGroup(controller: _controller(fake))));
      await _flush(tester);

      await tester.tap(find.byIcon(Icons.upload_outlined));
      await _flush(tester);
      await tester.tap(find.text('提交'));
      await _flush(tester);

      expect(find.text('请先配置 user.name 和 user.email'), findsOneWidget);
      final commitButton = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '提交'),
      );
      expect(commitButton.onPressed, isNull);
      expect(fake.countOf('commit'), 0);
    });

    testWidgets('AI generate failure hides the button permanently',
        (tester) async {
      _tallView(tester);
      Future<dynamic> noAi(String method, List<Object?> args) async {
        if (method == 'generateCommitMessage') {
          throw ChannelRpcError(
              'Commit message generation is not available.', null);
        }
        return _repoHandler(method, args);
      }

      final fake = _FakeGit(noAi);
      await tester.pumpWidget(_wrap(GitStatusGroup(controller: _controller(fake))));
      await _flush(tester);

      await tester.tap(find.byIcon(Icons.upload_outlined));
      await _flush(tester);
      await tester.tap(find.text('提交'));
      await _flush(tester);
      expect(find.text('生成提交消息'), findsOneWidget);

      await tester.tap(find.text('生成提交消息'));
      await _flush(tester);
      expect(find.text('生成提交消息'), findsNothing);
    });
  });
}
