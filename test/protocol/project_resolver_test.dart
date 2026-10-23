import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:zgo/protocol/project_resolver.dart';

/// 3.16.2 project attribution resolver (design 10-21 Part 2, research/05;
/// rewritten for on-demand page reads after acceptance round 1, 2026-10-22).
/// The desktop's own tasks-index.sqlite is the mapping source; the resolver
/// must answer `rootPath → projectId` by reading only the needed pages and
/// degrade to null on EVERY failure (never throw — a creation must not
/// depend on this feature).
///
/// The fixture databases are built with package:sqlite3 (dev dependency
/// only; the resolver is pure Dart).
void main() {
  group('mapping', () {
    test('projects JOIN project_roots maps every live local root', () async {
      final bytes = _fixture(
        projects: [
          {'id': 'p1', 'host': 'local', 'deleted': 0},
          {'id': 'p2', 'host': 'local', 'deleted': 1},
          {'id': 'p3', 'host': 'remote', 'deleted': 0},
          {'id': 'p4', 'host': 'local', 'deleted': 0},
        ],
        roots: [
          ['p1', r'F:\ZLinker'],
          ['p2', r'F:\Deleted'],
          ['p3', r'F:\Remote'],
          ['p4', r'D:\Alpha'],
          ['p4', r'D:\Beta'],
        ],
      );
      final resolver = _resolverFor(_FakeIndex(bytes));

      expect(await resolver.projectIdFor(r'F:\ZLinker'), 'p1');
      expect(await resolver.projectIdFor(r'D:\Alpha'), 'p4');
      expect(await resolver.projectIdFor(r'D:\Beta'), 'p4',
          reason: 'one project may own several roots');
      expect(await resolver.projectIdFor(r'F:\Deleted'), isNull,
          reason: 'deleted projects are excluded');
      expect(await resolver.projectIdFor(r'F:\Remote'), isNull,
          reason: 'only local-host projects are attributed');
      expect(await resolver.projectIdFor(r'F:\NotAProject'), isNull);
    });

    test('Windows roots match case-insensitively across slash spellings',
        () async {
      final bytes = _fixture(
        projects: [
          {'id': 'p1', 'host': 'local', 'deleted': 0},
        ],
        roots: [
          ['p1', r'F:\ZLinker'],
        ],
      );
      final resolver = _resolverFor(_FakeIndex(bytes));

      expect(await resolver.projectIdFor(r'f:\zlinker'), 'p1');
      expect(await resolver.projectIdFor('F:/ZLinker/'), 'p1');
    });

    test('POSIX roots stay case-sensitive', () async {
      final bytes = _fixture(
        projects: [
          {'id': 'p1', 'host': 'local', 'deleted': 0},
        ],
        roots: [
          ['p1', '/home/melody/project'],
        ],
      );
      final resolver = _resolverFor(_FakeIndex(bytes));

      expect(await resolver.projectIdFor('/home/melody/project'), 'p1');
      expect(await resolver.projectIdFor('/home/melody/project/'), 'p1');
      expect(await resolver.projectIdFor('/Home/Melody/Project'), isNull);
    });

    test('the map is read once — later lookups reuse the cache', () async {
      final index = _FakeIndex(_fixture(
        projects: [
          {'id': 'p1', 'host': 'local', 'deleted': 0},
        ],
        roots: [
          ['p1', r'F:\ZLinker'],
        ],
      ));
      final resolver = _resolverFor(index);

      expect(await resolver.projectIdFor(r'F:\ZLinker'), 'p1');
      final readsAfterFirst = index.calls;
      expect(readsAfterFirst, greaterThan(0));
      expect(await resolver.projectIdFor(r'F:\Other'), isNull);
      expect(await resolver.projectIdFor(r'F:\ZLinker'), 'p1');
      expect(index.calls, readsAfterFirst,
          reason: 'later lookups never re-read the index');
    });

    test('multi-page tables (interior b-tree pages) resolve every root',
        () async {
      final projects = [
        for (var i = 0; i < 500; i++)
          {'id': 'project-$i', 'host': 'local', 'deleted': 0},
      ];
      final roots = [
        for (var i = 0; i < 500; i++) ['project-$i', 'D:\\root-$i'],
      ];
      final resolver = _resolverFor(_FakeIndex(_fixture(
        projects: projects,
        roots: roots,
      )));

      expect(await resolver.projectIdFor(r'D:\root-0'), 'project-0');
      expect(await resolver.projectIdFor(r'D:\root-250'), 'project-250');
      expect(await resolver.projectIdFor(r'D:\root-499'), 'project-499');
    });

    test('overflow chains: long sqlite_master sql and long root paths',
        () async {
      final longRoot = '/very/long/${'b' * 6000}';
      final bytes = _fixture(
        // The CREATE statement itself overflows sqlite_master's page.
        longSqlDefault: 'a' * 6000,
        projects: [
          {'id': 'p1', 'host': 'local', 'deleted': 0},
        ],
        roots: [
          ['p1', longRoot],
          ['p1', r'F:\ZLinker'],
        ],
      );
      final resolver = _resolverFor(_FakeIndex(bytes));

      expect(await resolver.projectIdFor(longRoot), 'p1',
          reason: 'a leaf record larger than one page follows its overflow');
      expect(await resolver.projectIdFor(r'F:\ZLinker'), 'p1');
    });
  });

  group('project list (workspace-list completion)', () {
    test('exposes name + rootPath + projectId for every live local root',
        () async {
      final bytes = _fixture(
        projects: [
          {'id': 'p1', 'name': 'ZLinker', 'host': 'local', 'deleted': 0},
          {'id': 'p2', 'name': 'Gone', 'host': 'local', 'deleted': 1},
          {'id': 'p3', 'name': 'Remote', 'host': 'remote', 'deleted': 0},
          // The live schema allows a missing name; the completion falls
          // back to the path basename UI-side.
          {'id': 'p4', 'host': 'local', 'deleted': 0},
        ],
        roots: [
          ['p1', r'F:\ZLinker'],
          ['p1', r'D:\Alpha'],
          ['p2', r'F:\Deleted'],
          ['p3', r'F:\Remote'],
          ['p4', r'E:\NoName'],
        ],
      );
      final resolver = _resolverFor(_FakeIndex(bytes));

      expect(await resolver.mapping(), isNotNull);
      expect(
        resolver.projectRoots
            .map((r) => (r.projectId, r.name, r.rootPath))
            .toList(),
        [
          ('p1', 'ZLinker', r'F:\ZLinker'),
          ('p1', 'ZLinker', r'D:\Alpha'),
          ('p4', '', r'E:\NoName'),
        ],
        reason: 'deleted/remote projects are excluded, every root row is '
            'kept in database order, name rides along',
      );
    });

    test('projectRoots is empty before a read and after a bad file',
        () async {
      final index = _FakeIndex(_bytes('definitely not sqlite'));
      final resolver = _resolverFor(index);

      expect(resolver.projectRoots, isEmpty,
          reason: 'reading the getter never triggers a read');
      expect(await resolver.projectIdFor(r'F:\ZLinker'), isNull);
      expect(resolver.projectRoots, isEmpty);
    });
  });

  group('read budget', () {
    test('a multi-MB index costs a handful of pages, not a full pull',
        () async {
      final bytes = _fixture(
        projects: [
          for (var i = 0; i < 15; i++)
            {'id': 'project-$i', 'host': 'local', 'deleted': 0},
        ],
        roots: [
          for (var i = 0; i < 15; i++) ['project-$i', 'D:\\project-$i'],
        ],
        bloatRows: 400,
      );
      expect(bytes.length, greaterThan(1 << 20),
          reason: 'the fixture must be big enough that a full pull would '
              'blow the budget (the live index is ~25 MB)');

      final index = _FakeIndex(bytes);
      final resolver = _resolverFor(index);
      expect(await resolver.projectIdFor(r'D:\project-14'), 'project-14');

      expect(index.calls, lessThanOrEqualTo(12),
          reason: 'header + page 1 + the two table b-trees, never a full '
              'file pull');
      expect(index.bytesRead, lessThan(1 << 20),
          reason: 'the whole live-index regression: only pages, not bytes');
    });
  });

  group('failure classes', () {
    test('a transient read failure is retried on the next creation',
        () async {
      final index = _FakeIndex(_fixture(
        projects: [
          {'id': 'p1', 'host': 'local', 'deleted': 0},
        ],
        roots: [
          ['p1', r'F:\ZLinker'],
        ],
      ));
      var transientFailures = 1;
      final resolver = ProjectResolver(
        workspaces: () => _workspaces,
        readRange: (path, offset, length) async {
          if (transientFailures > 0) {
            transientFailures--;
            throw TimeoutException('bridge swing', const Duration(seconds: 30));
          }
          return index.read(path, offset, length);
        },
      );

      expect(await resolver.projectIdFor(r'F:\ZLinker'), isNull,
          reason: 'the affected creation degrades');
      expect(await resolver.projectIdFor(r'F:\ZLinker'), 'p1',
          reason: 'a transient failure is NOT cached — the next creation '
              'retries and succeeds');
    });

    test('a deterministic failure is read once and cached', () async {
      final index = _FakeIndex(_bytes('definitely not sqlite'));
      final resolver = _resolverFor(index);

      expect(await resolver.projectIdFor(r'F:\ZLinker'), isNull);
      expect(await resolver.projectIdFor(r'F:\ZLinker'), isNull);
      expect(index.calls, 1,
          reason: 'bad magic answers from the 100-byte header alone and is '
              'cached for the process lifetime');
    });

    test('no workspace path carrying .zcode/workspace disables the resolver',
        () async {
      var reads = 0;
      final resolver = ProjectResolver(
        workspaces: () => const [
          {'workspacePath': r'F:\ZLinker'},
        ],
        readRange: (path, offset, length) async {
          reads++;
          return Uint8List(0);
        },
      );

      expect(await resolver.projectIdFor(r'F:\ZLinker'), isNull);
      expect(reads, 0, reason: 'nothing to derive a desktop home from');
    });

    test('missing tables answer null and stay cached', () async {
      final index = _FakeIndex(_fixture(createTables: false));
      final resolver = _resolverFor(index);

      expect(await resolver.projectIdFor(r'F:\ZLinker'), isNull);
      final reads = index.calls;
      expect(await resolver.projectIdFor(r'F:\ZLinker'), isNull);
      expect(index.calls, reads, reason: 'a deterministic answer is cached');
    });

    test('an unreadable answer (short read) is deterministic', () async {
      var reads = 0;
      final resolver = ProjectResolver(
        workspaces: () => _workspaces,
        readRange: (path, offset, length) async {
          reads++;
          return Uint8List(0);
        },
      );

      expect(await resolver.projectIdFor(r'F:\ZLinker'), isNull);
      expect(await resolver.projectIdFor(r'F:\ZLinker'), isNull);
      expect(reads, 1, reason: 'an empty header is a truncated index, not a '
          'transient channel failure');
    });

    test('a projects column contract mismatch answers null', () async {
      final bytes = _fixture(
        narrowProjects: true,
        projects: [
          {'id': 'p1', 'host': 'local', 'deleted': 0},
        ],
        roots: [
          ['p1', r'F:\ZLinker'],
        ],
      );
      final resolver = _resolverFor(_FakeIndex(bytes));

      expect(await resolver.projectIdFor(r'F:\ZLinker'), isNull);
    });

    test('an empty live project set maps nothing (still cached)', () async {
      final index = _FakeIndex(_fixture());
      final resolver = _resolverFor(index);

      expect(await resolver.projectIdFor(r'F:\ZLinker'), isNull);
      final reads = index.calls;
      expect(await resolver.projectIdFor(r'F:\ZLinker'), isNull);
      expect(index.calls, reads);
    });
  });

  group('desktop home derivation', () {
    test('Windows draft workspace path yields the home before .zcode', () {
      expect(
        ProjectResolver.desktopHomeFor(
            r'C:\Users\Melody\.zcode\workspace\draft-1234'),
        'C:/Users/Melody',
      );
      expect(
        ProjectResolver.desktopHomeFor(
            r'C:\Users\Melody\.zcode\workspace\default'),
        'C:/Users/Melody',
      );
    });

    test('POSIX draft workspace path yields the home before .zcode', () {
      expect(
        ProjectResolver.desktopHomeFor(
            '/Users/melody/.zcode/workspace/draft-x'),
        '/Users/melody',
      );
    });

    test('paths without the segment answer null', () {
      expect(ProjectResolver.desktopHomeFor(r'F:\ZLinker'), isNull);
      expect(ProjectResolver.desktopHomeFor('/home/melody/project'), isNull);
      expect(
          ProjectResolver.desktopHomeFor('.zcode/workspace/draft-x'), isNull);
      expect(ProjectResolver.desktopHomeFor(''), isNull);
    });
  });
}

/// Live 3.16.2 shape: draft rows carry no `workspacePurpose` (the resolver
/// only needs the path to derive the desktop home).
const List<Map<String, dynamic>> _workspaces = [
  {
    'workspacePath': r'C:\Users\Melody\.zcode\workspace\draft-1234',
    'label': 'draft-1234',
  },
];

ProjectResolver _resolverFor(_FakeIndex index) => ProjectResolver(
      workspaces: () => _workspaces,
      readRange: index.read,
    );

/// Byte-view read seam: answers exactly the requested slice, so the page
/// reader's offset/length arithmetic is exercised as on the wire.
class _FakeIndex {
  _FakeIndex(this.data);

  final Uint8List data;
  int calls = 0;
  int bytesRead = 0;

  Future<Uint8List> read(String path, int offset, int length) async {
    calls++;
    if (offset >= data.length) return Uint8List(0);
    final end = offset + length > data.length ? data.length : offset + length;
    bytesRead += end - offset;
    return Uint8List.sublistView(data, offset, end);
  }
}

/// Builds a real SQLite file in a temp dir and returns its bytes — the same
/// shape the resolver gets off the wire (main db file only; a plain rollback
/// journal leaves no -wal sidecar).
///
/// `projects` deliberately mirrors the measured 3.16.2 column positions:
/// 0=project_id, 1=host_id, 7=deleted.
Uint8List _fixture({
  bool createTables = true,
  bool narrowProjects = false,
  List<Map<String, Object?>> projects = const [],
  List<List<String>> roots = const [],
  int bloatRows = 0,
  String longSqlDefault = '',
}) {
  final dir = Directory.systemTemp.createTempSync('zgo_project_fixture_');
  final path = '${dir.path}${Platform.pathSeparator}index.sqlite';
  final db = sqlite3.open(path);
  try {
    if (createTables) {
      if (narrowProjects) {
        db.execute('CREATE TABLE projects('
            'project_id TEXT, host_id TEXT, deleted INTEGER)');
      } else {
        final color = longSqlDefault.isEmpty
            ? 'color TEXT'
            : "color TEXT DEFAULT '$longSqlDefault'";
        db.execute(
          'CREATE TABLE projects('
          'project_id TEXT PRIMARY KEY, host_id TEXT, name TEXT, '
          'created_at INTEGER, updated_at INTEGER, $color, icon TEXT, '
          'deleted INTEGER)',
        );
      }
      db.execute(
          'CREATE TABLE project_roots(project_id TEXT, root_path TEXT)');
      for (final p in projects) {
        if (narrowProjects) {
          db.execute(
            'INSERT INTO projects(project_id, host_id, deleted) '
            'VALUES(?, ?, ?)',
            [p['id'], p['host'], p['deleted']],
          );
        } else {
          db.execute(
            'INSERT INTO projects(project_id, host_id, name, deleted) '
            'VALUES(?, ?, ?, ?)',
            [p['id'], p['host'], p['name'], p['deleted']],
          );
        }
      }
      for (final r in roots) {
        db.execute(
          'INSERT INTO project_roots(project_id, root_path) VALUES(?, ?)',
          [r[0], r[1]],
        );
      }
      if (bloatRows > 0) {
        // Padding unrelated to the mapping: makes the file exceed 1 MiB so
        // the read-budget test would catch a full-pull regression.
        db.execute('CREATE TABLE bloat(payload BLOB)');
        final blob = Uint8List(4096);
        for (var i = 0; i < bloatRows; i++) {
          db.execute('INSERT INTO bloat VALUES(?)', [blob]);
        }
      }
    }
  } finally {
    db.dispose();
  }
  final bytes = File(path).readAsBytesSync();
  dir.deleteSync(recursive: true);
  return bytes;
}

Uint8List _bytes(String text) => Uint8List.fromList(text.codeUnits);
