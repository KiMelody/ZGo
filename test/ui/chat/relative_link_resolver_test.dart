import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/file_service.dart';
import 'package:zgo/ui/chat/relative_link_resolver.dart';

/// A fake listing keyed by exact directory path; unlisted dirs answer empty
/// and every call is recorded (the budget assertions count them).
class _Listing {
  _Listing(this.tree);

  /// `dir → [(name, isDir)]`.
  final Map<String, List<(String, bool)>> tree;
  final List<String> calls = [];

  Future<List<DirEntry>> readdir(String dir) async {
    calls.add(dir);
    return [
      for (final (name, isDir) in tree[dir] ?? const <(String, bool)>[])
        DirEntry(name: name, isDir: isDir),
    ];
  }
}

void main() {
  group('L2 context bases (design 11-09 §L2)', () {
    Map<String, dynamic> readRow(String filePath, {int id = 1}) => {
          'rowId': id,
          'kind': 'toolCall',
          'toolName': 'Read',
          'input': {'filePath': filePath},
        };

    test('a single Read row yields its directory', () {
      expect(
        relativeLinkContextBases([
          readRow('F:/ws/docs/adr/0007.md'),
        ]),
        ['F:/ws/docs/adr'],
      );
    });

    test('newest row first, deduped case-insensitively, index order', () {
      final bases = relativeLinkContextBases([
        readRow('F:/ws/docs/adr/0007.md', id: 1),
        readRow('F:/WS/Docs/ADR/0006.md', id: 2), // same dir, other case
        readRow('F:/ws/src/main.dart', id: 3),
      ]);
      expect(bases, ['F:/ws/src', 'F:/WS/Docs/ADR'],
          reason: 'row order reversed (newest first), one entry per dir — '
              'the NEWEST row\'s casing wins the dedupe');
    });

    test('the cap keeps the 5 most recent bases', () {
      final rows = [
        for (var i = 0; i < 9; i++)
          readRow('F:/ws/dir$i/file$i.md', id: i + 1),
      ];
      final bases = relativeLinkContextBases(rows);
      expect(bases.length, maxRelativeLinkContextBases);
      expect(bases.first, 'F:/ws/dir8');
      expect(bases.last, 'F:/ws/dir4');
    });

    test('non-toolCall rows and non-file tools are ignored', () {
      final bases = relativeLinkContextBases([
        {
          'rowId': 1,
          'kind': 'assistantText',
          'input': {'filePath': 'F:/ws/nope/a.md'},
        },
        {
          'rowId': 2,
          'kind': 'toolCall',
          'toolName': 'Grep',
          'input': {'path': 'F:/ws/some/dir'},
        },
        readRow('F:/ws/real/f.md', id: 3),
      ]);
      expect(bases, ['F:/ws/real']);
    });

    test('streaming rows without a decoded input map fall back to inputText',
        () {
      final bases = relativeLinkContextBases([
        {
          'rowId': 1,
          'kind': 'toolCall',
          'toolName': 'Write',
          'inputText': '{"file_path":"F:/ws/code/a.dart"}',
        },
      ]);
      expect(bases, ['F:/ws/code']);
    });

    test('backslashes normalize to forward slashes; no-dir paths drop', () {
      expect(
        relativeLinkContextBases([
          readRow(r'F:\ws\lib\main.dart'),
          readRow('notes.md', id: 2),
        ]),
        ['F:/ws/lib'],
      );
    });

    test('empty rows → no bases (draft session)', () {
      expect(relativeLinkContextBases(const []), isEmpty);
    });
  });


  group('L2 probe bases (design 11-09 §L2 + excerpt scenario)', () {
    test('directories come first, then ancestors level by level', () {
      expect(
        relativeLinkProbeBases(
          ['/ws/docs/adr', '/ws/src'],
          '/ws',
        ),
        ['/ws/docs/adr', '/ws/src', '/ws/docs'],
        reason: 'both direct dirs before any ancestor; the workspace root is '
            'excluded (it is the L1 join that already missed)',
      );
    });

    test('the excerpt scenario reaches the link base', () {
      // Message reads <ws>/docs/adr/0007.md, link is `adr/0008.md` written
      // relative to <ws>/docs.
      final bases = relativeLinkProbeBases(
        ['/ws/docs/adr'],
        '/ws',
      );
      expect(bases, ['/ws/docs/adr', '/ws/docs']);
      expect(bases, contains('/ws/docs'));
    });

    test('the cap bounds the whole probe stage', () {
      final bases = relativeLinkProbeBases(
        ['/ws/a/b/c/d/e'],
        '/ws',
        limit: 3,
      );
      expect(bases, ['/ws/a/b/c/d/e', '/ws/a/b/c/d', '/ws/a/b/c']);
    });

    test('paths outside the workspace are ignored', () {
      expect(
        relativeLinkProbeBases(['D:/other/proj'], '/ws'),
        isEmpty,
      );
    });
  });

  group('path helpers', () {
    test('directoryOf / joinFsPath / baseNameOf', () {
      expect(directoryOf('F:/a/b/c.md'), 'F:/a/b');
      expect(directoryOf(r'F:\a\b\c.md'), 'F:/a/b');
      expect(directoryOf('c.md'), isNull);
      expect(directoryOf('/c.md'), isNull);
      expect(joinFsPath('F:/a/', 'b/c.md'), 'F:/a/b/c.md');
      expect(joinFsPath('F:/a', r'b\c.md'), 'F:/a/b/c.md');
      expect(baseNameOf('F:/a/b/c.md'), 'c.md');
      expect(baseNameOf(r'F:\a\b\c.md'), 'c.md');
    });

    test('relativeLinkDisplay: workspace-relative, absolute outside, null for '
        'nothing to add', () {
      expect(relativeLinkDisplay('F:/ws', 'F:/ws/docs/a.md'), 'docs/a.md');
      expect(relativeLinkDisplay('F:/ws/', 'F:/ws/docs/a.md'), 'docs/a.md');
      expect(relativeLinkDisplay('F:/ws', 'D:/other/a.md'), 'D:/other/a.md');
      expect(relativeLinkDisplay('F:/ws', 'F:/ws/a.md'), isNull,
          reason: 'a file at the workspace root adds nothing to the title');
      expect(relativeLinkDisplay(null, 'F:/ws/docs/a.md'), 'F:/ws/docs/a.md');
      expect(relativeLinkDisplay(null, 'a.md'), isNull);
    });
  });

  group('L3 search: correctness', () {
    test('finds a file several levels down, reporting a relative path', () async {
      final listing = _Listing({
        'F:/ws': [('some', true), ('README.md', false)],
        'F:/ws/some': [('deep', true)],
        'F:/ws/some/deep': [('dir', true)],
        'F:/ws/some/deep/dir': [('0008-adr.md', false)],
      });
      final hits = await WorkspaceBasenameSearch(readdir: listing.readdir)
          .find('F:/ws', '0008-adr.md');

      expect(hits, ['some/deep/dir/0008-adr.md']);
    });

    test('matching is case-insensitive on both sides', () async {
      final listing = _Listing({
        'F:/ws': [('Docs', true)],
        'F:/ws/Docs': [('ADR-0008.MD', false)],
      });
      final hits = await WorkspaceBasenameSearch(readdir: listing.readdir)
          .find('F:/ws', 'adr-0008.md');

      expect(hits, ['Docs/ADR-0008.MD'],
          reason: 'the hit keeps the real on-disk casing for the open path');
    });

    test('directories with the matching name do not match', () async {
      final listing = _Listing({
        'F:/ws': [('adr.md', true)],
        'F:/ws/adr.md': [],
      });
      final hits = await WorkspaceBasenameSearch(readdir: listing.readdir)
          .find('F:/ws', 'adr.md');

      expect(hits, isEmpty);
    });

    test('multiple hits are collected in BFS order', () async {
      final listing = _Listing({
        'F:/ws': [('a', true), ('b', true)],
        'F:/ws/a': [('x.md', false)],
        'F:/ws/b': [('x.md', false)],
      });
      final hits = await WorkspaceBasenameSearch(readdir: listing.readdir)
          .find('F:/ws', 'x.md');

      expect(hits, ['a/x.md', 'b/x.md']);
    });

    test('skipped directories are listed but never entered', () async {
      final listing = _Listing({
        'F:/ws': [
          ('node_modules', true),
          ('NODE_MODULES', true),
          ('src', true),
        ],
        'F:/ws/src': [('x.md', false)],
      });
      final budget = SearchBudget();
      final search = WorkspaceBasenameSearch(
        readdir: listing.readdir,
        budget: budget,
      );

      final hits = await search.find('F:/ws', 'x.md');

      expect(hits, ['src/x.md']);
      expect(listing.calls, ['F:/ws', 'F:/ws/src'],
          reason: 'node_modules never listed (case-insensitive skip)');
      expect(budget.entries, 4,
          reason: '3 root entries (both skipped ones included) + x.md — the '
              'listing paid for the skipped names, so they count');
    });

    test('an unreadable directory degrades to an empty listing', () async {
      var n = 0;
      final hits = await WorkspaceBasenameSearch(readdir: (dir) async {
        n++;
        if (dir == 'F:/ws') return [const DirEntry(name: 'bad', isDir: true)];
        throw StateError('boom');
      }).find('F:/ws', 'x.md');

      expect(hits, isEmpty);
      expect(n, 2, reason: 'the walk continued past the failure');
    });
  });

  group('L3 search: hard budget (AC4)', () {
    test('readdir cap 40: stops after exactly 40 calls', () async {
      // A wide flat tree: 1 root + 39 children, each empty, then one more
      // dir that WOULD hold the hit at call 41.
      final tree = <String, List<(String, bool)>>{
        'F:/ws': [
          for (var i = 0; i < 60; i++) ('d$i', true),
        ],
        for (var i = 0; i < 60; i++) 'F:/ws/d$i': <(String, bool)>[],
      };
      tree['F:/ws/d59'] = [('x.md', false)];
      final listing = _Listing(tree);
      final budget = SearchBudget();
      final search =
          WorkspaceBasenameSearch(readdir: listing.readdir, budget: budget);

      final hits = await search.find('F:/ws', 'x.md');

      expect(listing.calls.length, searchMaxReaddirCalls);
      expect(budget.readdirCalls, 40);
      expect(budget.exhausted, isTrue);
      expect(hits, isEmpty, reason: 'the hit sat past the cap — reported as 0');
    });

    test('entry cap 5000: stops once the counter reaches the cap', () async {
      // One directory of 6000 entries, the hit near the very end. Each
      // listing of 6000 blows the entry budget inside a single listing.
      final listing = _Listing({
        'F:/ws': [
          for (var i = 0; i < 5999; i++) ('f$i.txt', false),
          ('target.md', false),
        ],
      });
      final budget = SearchBudget();
      final search =
          WorkspaceBasenameSearch(readdir: listing.readdir, budget: budget);

      final hits = await search.find('F:/ws', 'target.md');

      expect(budget.entries, searchMaxEntries,
          reason: 'stops at exactly the cap, not at the end of the listing');
      expect(budget.exhausted, isTrue);
      expect(hits, isEmpty, reason: 'the hit was past the entry cap');
      expect(listing.calls.length, 1);
    });

    test('the entry cap still collects a hit found before the boundary',
        () async {
      final listing = _Listing({
        'F:/ws': [
          ('target.md', false),
          for (var i = 0; i < 6000; i++) ('f$i.txt', false),
        ],
      });
      final budget = SearchBudget();
      final hits = await WorkspaceBasenameSearch(
        readdir: listing.readdir,
        budget: budget,
      ).find('F:/ws', 'target.md');

      expect(hits, ['target.md'],
          reason: 'the budget caps effort, never discards what was found');
      expect(budget.exhausted, isTrue);
    });

    test('depth cap 6: a hit at depth 7 is never reached', () async {
      // Chain: ws/d1/d2/…/d8, the hit inside d8 (depth 8).
      final tree = <String, List<(String, bool)>>{};
      var dir = 'F:/ws';
      for (var i = 1; i <= 8; i++) {
        tree[dir] = [('d$i', true)];
        dir = '$dir/d$i';
      }
      tree[dir] = [('x.md', false)];
      final listing = _Listing(tree);
      final budget = SearchBudget();

      final hits = await WorkspaceBasenameSearch(
        readdir: listing.readdir,
        budget: budget,
      ).find('F:/ws', 'x.md');

      expect(hits, isEmpty);
      expect(budget.depth, searchMaxDepth,
          reason: 'the deepest listing is depth 6 — d7 was never enqueued');
      expect(listing.calls.length, searchMaxDepth + 1,
          reason: 'proves the depth cap converged by itself: the walk '
              'ended without the call cap ever firing');
      expect(budget.exhausted, isFalse,
          reason: 'depth is a structural bound, not a count-exhaustion');
    });

    test('a file at exactly depth 6 is still found', () async {
      final tree = <String, List<(String, bool)>>{};
      var dir = 'F:/ws';
      for (var i = 1; i <= 6; i++) {
        tree[dir] = [('d$i', true)];
        dir = '$dir/d$i';
      }
      tree[dir] = [('x.md', false)];
      final hits = await WorkspaceBasenameSearch(readdir: _Listing(tree).readdir)
          .find('F:/ws', 'x.md');

      expect(hits, ['d1/d2/d3/d4/d5/d6/x.md']);
    });

    test('the readdir count never exceeds the cap on any input shape',
        () async {
      // Deep + wide + unreadable mix; the assertion is the invariant, not
      // one specific number.
      final tree = <String, List<(String, bool)>>{};
      for (var i = 0; i < 200; i++) {
        tree['F:/ws'] = [
          ...?tree['F:/ws'],
          ('d$i', true),
        ];
        tree['F:/ws/d$i'] = [
          ('sub', true),
          for (var j = 0; j < 100; j++) ('f$j', false),
        ];
        tree['F:/ws/d$i/sub'] = [('x.md', false)];
      }
      final listing = _Listing(tree);
      final budget = SearchBudget();

      await WorkspaceBasenameSearch(
        readdir: listing.readdir,
        budget: budget,
      ).find('F:/ws', 'never-there.md');

      expect(listing.calls.length, lessThanOrEqualTo(searchMaxReaddirCalls));
      expect(budget.entries, lessThanOrEqualTo(searchMaxEntries));
    });
  });
}
