import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/file_service.dart';

void main() {
  test('first accepted candidate wins; misses advance in candidate order',
      () async {
    final calls = <String>[];
    final port = FileServicePort((method, args) async {
      calls.add(method);
      if (method == 'readMedia') {
        return {
          'dataBase64': base64Encode([1, 2, 3]),
          'mediaType': 'image/png',
          'size': 3,
        };
      }
      throw ChannelRpcError('no such method: $method', null);
    });

    final res = await port.readMedia('/repo', 'a.png');
    // readMediaPreview / mediaPreview miss (bundle names first), readMedia answers
    expect(calls, ['readMediaPreview', 'mediaPreview', 'readMedia']);
    expect(res.bytes, Uint8List.fromList([1, 2, 3]));
    expect(res.mediaType, 'image/png');
    expect(res.totalBytes, 3);
  });

  test('resolved method is reused directly on the next call', () async {
    final calls = <String>[];
    final port = FileServicePort((method, args) async {
      calls.add(method);
      if (method == 'stat') return {'type': 'file', 'size': 12};
      throw ChannelRpcError('no such method: $method', null);
    });

    final res = await port.stat('/repo', 'a.txt');
    expect(res.type, 'file');
    expect(res.size, 12);
    expect(calls, ['stat']);

    calls.clear();
    await port.stat('/repo', 'b.txt');
    expect(calls, ['stat'], reason: 'second call must skip probing');
  });

  test('payloads carry exactly the scope+file fields, no extras', () async {
    final payloads = <Map<String, Object?>>[];
    final port = FileServicePort((method, args) async {
      payloads.add((args.single as Map).cast<String, Object?>());
      if (method == 'stat') return {'type': 'file'};
      if (method == 'readMediaPreview') {
        return {'dataBase64': base64Encode(const <int>[0])};
      }
      return {'text': 'x'};
    });

    await port.stat('/repo', 'a.txt');
    // stat: absolute path only — workspacePath is certified ignored on the
    // wire (spec §1.2) and no maxBytes/offset ride along
    expect(payloads[0], {'path': 'a.txt'});
    expect(payloads[0].containsKey('workspacePath'), isFalse);
    expect(payloads[0].containsKey('maxBytes'), isFalse);

    await port.readMedia('/repo', 'a.png');
    expect(payloads[1], {'path': 'a.png'});
    expect(payloads[1].containsKey('workspacePath'), isFalse);
    expect(payloads[1].containsKey('maxBytes'), isFalse);

    await port.readMedia('/repo', 'a.png', maxBytes: 1 << 20);
    expect(payloads[2]['maxBytes'], 1 << 20);

    await port.readText('/repo', 'a.txt', offset: 8, length: 256);
    expect(payloads[3], {
      'path': 'a.txt',
      'offset': 8,
      'length': 256,
    });
  });

  test('non-missingMethod errors rethrow without advancing', () async {
    final tried = <String>[];
    final port = FileServicePort((method, args) async {
      tried.add(method);
      throw ChannelRpcError('validation failed: bad path', null);
    });
    await expectLater(
      port.stat('/repo', 'a.txt'),
      throwsA(isA<ChannelRpcError>()
          .having((e) => e.message, 'message', 'validation failed: bad path')),
    );
    expect(tried, ['stat']);
  });

  test('every candidate missing → first error rethrown', () async {
    final port = FileServicePort((method, args) async =>
        throw ChannelRpcError('no such method: $method', null));
    await expectLater(port.readText('/repo', 'a.txt', length: 10),
        throwsA(isA<ChannelRpcError>()));
  });

  test('malformed answers throw explicit StateErrors', () async {
    FileServicePort answering(dynamic res) =>
        FileServicePort((method, args) async => res);

    // stat: non-map answer / answer without a type field
    await expectLater(
        answering('not-a-map').stat('/repo', 'p'), throwsStateError);
    await expectLater(
        answering(<String, dynamic>{}).stat('/repo', 'p'), throwsStateError);

    // readMediaPreview: missing or mistyped dataBase64
    await expectLater(answering(<String, dynamic>{}).readMedia('/repo', 'p'),
        throwsStateError);
    await expectLater(
        answering(<String, dynamic>{'dataBase64': 42}).readMedia('/repo', 'p'),
        throwsStateError);

    // readMediaPreview: undecodable base64
    await expectLater(
        answering(<String, dynamic>{'dataBase64': 'not base64!!'})
            .readMedia('/repo', 'p'),
        throwsStateError);

    // readTextFile: map without a content field
    await expectLater(
        answering(<String, dynamic>{'truncated': false})
            .readText('/repo', 'p', length: 10),
        throwsStateError);
  });

  test('answer parsing accepts the documented shapes', () async {
    FileServicePort answering(dynamic res) =>
        FileServicePort((method, args) async => res);

    // Certified wire shape (spec §1.2): totalBytes carries the size
    final media = await answering(<String, dynamic>{
      'dataBase64': base64Encode(utf8.encode('png')),
      'mediaType': 'image/png',
      'totalBytes': 3,
    }).readMedia('/repo', 'p');
    expect(utf8.decode(media.bytes), 'png');
    expect(media.totalBytes, 3);

    // plain-string text answer; certified map shape carries content+truncated
    final plain = await answering('file body')
        .readText('/repo', 'p', length: 10);
    expect(plain.text, 'file body');
    expect(plain.hasMore, isNull);
    final chunked = await answering(
            <String, dynamic>{'content': 'abc', 'truncated': true})
        .readText('/repo', 'p', length: 10);
    expect(chunked.text, 'abc');
    expect(chunked.hasMore, isTrue);
  });

  group('workspace file listing (search panel file tab, design D7)', () {
    test('searchWorkspaceFiles answers typed rows; payload is the exact '
        '{rootPath, query, limit} shape', () async {
      final payloads = <Map<String, Object?>>[];
      final port = FileServicePort((method, args) async {
        payloads.add((args.single as Map).cast<String, Object?>());
        return [
          {
            'name': 'a.dart',
            'path': '/repo/lib/a.dart',
            'relativePath': 'lib/a.dart',
            'type': 'file',
          },
          {
            'path': '/repo/lib',
            'relativePath': 'lib',
            'type': 'directory',
          },
          {'relativePath': ''}, // malformed → dropped
        ];
      });

      final rows = await port.searchWorkspaceFiles('/repo', query: 'a', limit: 50);
      expect(payloads.single, {'rootPath': '/repo', 'query': 'a', 'limit': 50});
      expect(payloads.single.containsKey('workspacePath'), isFalse);
      expect(rows, hasLength(2));
      expect(rows[0].name, 'a.dart');
      expect(rows[0].relativePath, 'lib/a.dart');
      expect(rows[0].path, '/repo/lib/a.dart');
      expect(rows[0].isDirectory, isFalse);
      expect(rows[1].isDirectory, isTrue);
    });

    test('limit truncates the search answer', () async {
      final port = FileServicePort((method, args) async {
        return [
          for (var i = 0; i < 10; i++)
            {'relativePath': 'f$i.dart', 'type': 'file'},
        ];
      });
      final rows = await port.searchWorkspaceFiles('/repo', limit: 3);
      expect(rows, hasLength(3));
    });

    test('search miss falls back to length + paged range, packed parsed '
        'and cached for the port lifetime', () async {
      final calls = <String>[];
      final ranges = <Map<String, Object?>>[];
      final port = FileServicePort((method, args) async {
        calls.add(method);
        if (method == 'searchWorkspaceFiles') {
          throw ChannelRpcError('no such method: $method', null);
        }
        if (method == 'listWorkspaceFilesLength') return 2500000;
        if (method == 'listWorkspaceFilesRange') {
          final m = (args.single as Map).cast<String, Object?>();
          ranges.add(m);
          // Renderer slices the packed string: past the end → ''.
          return (m['offset'] as int) == 0
              ? 'file\tlib/a.dart\nfile\tlib/b.dart'
              : '';
        }
        throw StateError('unexpected $method');
      });

      final rows = await port.searchWorkspaceFiles('/repo', query: 'b.dart');
      // 1 search miss + 1 length + 3 range pages (2.5M chars @ 1 MiB).
      expect(calls, [
        'searchWorkspaceFiles',
        'listWorkspaceFilesLength',
        'listWorkspaceFilesRange',
        'listWorkspaceFilesRange',
        'listWorkspaceFilesRange',
      ]);
      expect(ranges, hasLength(3));
      expect(ranges[0], {'rootPath': '/repo', 'offset': 0, 'length': 1 << 20});
      expect(ranges[1]['offset'], 1 << 20);
      expect(ranges[2]['offset'], 2 << 20);

      expect(rows, hasLength(1), reason: 'contains filter on relativePath');
      expect(rows.single.relativePath, 'lib/b.dart');

      // Second query: the packed walk is cached — only the search method
      // re-probes (a miss never caches in MethodProbe), no re-walk.
      calls.clear();
      final again = await port.searchWorkspaceFiles('/repo', query: 'a.dart');
      expect(calls, ['searchWorkspaceFiles']);
      expect(again.single.relativePath, 'lib/a.dart');
    });

    test('packed parser: escapes, name fallback, windows root separators',
        () async {
      final port = FileServicePort((method, args) async {
        if (method == 'searchWorkspaceFiles') {
          throw ChannelRpcError('no such method: $method', null);
        }
        if (method == 'listWorkspaceFilesLength') return 100;
        // Wire truth (renderer `Vv` @313272002): the first TAB field is the
        // word `directory` or anything else (→ file); the path is `VEe`-
        // escaped (`\t` inside a path rides as the two-char escape).
        return 'directory\tlib/src\nfile\tlib/src/a.dart\nfile\tweird\\tname.txt';
      });

      final rows = await port.searchWorkspaceFiles(r'C:\repo', query: '');
      expect(rows.map((r) => r.relativePath).toList(), [
        'lib/src',
        'lib/src/a.dart',
        'weird\tname.txt',
      ]);
      expect(
        rows[1].path,
        r'C:\repo\lib\src\a.dart',
        reason: 'windows root → native separators, absolute join',
      );
      expect(
        rows.map((r) => r.name).toList(),
        ['src', 'a.dart', 'weird\tname.txt'],
        reason: 'name falls back to the last path segment',
      );
      expect(rows.first.isDirectory, isTrue);
      expect(rows[1].isDirectory, isFalse);
    });

    test('workspaceFilesReachable: search hit → true (and cached direct); '
        'search miss + length hit → true; all miss → false; validation '
        'error → false', () async {
      Future<bool> reachableOf(
        Future<dynamic> Function(String method) responder,
      ) async {
        final port =
            FileServicePort((method, args) => responder(method));
        return port.workspaceFilesReachable('/repo');
      }

      expect(
        await reachableOf((m) async =>
            m == 'searchWorkspaceFiles' ? <dynamic>[] : throw StateError('x')),
        isTrue,
      );
      expect(
        await reachableOf((m) async {
          if (m == 'searchWorkspaceFiles') {
            throw ChannelRpcError('no such method: $m', null);
          }
          if (m == 'listWorkspaceFilesLength') return 12;
          throw ChannelRpcError('no such method: $m', null);
        }),
        isTrue,
      );
      expect(
        await reachableOf((m) async =>
            throw ChannelRpcError('no such method: $m', null)),
        isFalse,
      );
      expect(
        await reachableOf((m) async =>
            throw ChannelRpcError('validation failed: bad rootPath', null)),
        isFalse,
        reason: 'a real failure must not open the tab',
      );
    });

    test('reachability probe payload carries limit-1 empty query', () async {
      final payloads = <Map<String, Object?>>[];
      final port = FileServicePort((method, args) async {
        payloads.add((args.single as Map).cast<String, Object?>());
        return <dynamic>[];
      });
      await port.workspaceFilesReachable('/repo');
      expect(payloads.single, {'rootPath': '/repo', 'query': '', 'limit': 1});
    });
  });
}
