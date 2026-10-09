import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/git_service.dart';
import 'package:zgo/ui/chat/diff_view.dart';
import 'package:zgo/ui/chat/git_panel.dart';
import 'package:zgo/ui/ui_settings.dart';

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

Widget _wrap(Widget child) => MaterialApp(
      builder: (context, c) =>
          UiSettingsProvider(settings: UiSettings(), child: c!),
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
  });

  group('GitReviewPanel', () {
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
