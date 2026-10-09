import 'dart:convert';
import 'dart:typed_data';

import 'channel_client.dart';
import 'method_probe.dart';

/// Typed results of the desktop fileService (`file` channel). Field names
/// follow the desktop's zod-verified shapes; the live probe may still
/// adjust the scope shape (args only — the
/// answer fields below are the desktop's own zod-verified shapes).
class FileStat {
  final String? type;
  final int? size;
  const FileStat({this.type, this.size});
}

class MediaPreview {
  final Uint8List bytes;
  final String? mediaType;

  /// Total file size when the desktop reports it (`size` in the wire shape;
  /// `totalBytes` accepted as a fallback). Null when unknown.
  final int? totalBytes;
  const MediaPreview({required this.bytes, this.mediaType, this.totalBytes});
}

class TextChunk {
  final String text;

  /// More pages available at the next offset. Null until the live probe
  /// certifies the pagination field ("hasMore semantics").
  final bool? hasMore;
  const TextChunk({required this.text, this.hasMore});
}

/// One workspace file row of the search panel's file tab
/// (`{name, path, relativePath, type: file|directory}`, renderer `Vv`
/// parse @313271506).
class WorkspaceFileEntry {
  final String name;
  final String path;
  final String relativePath;
  final bool isDirectory;
  const WorkspaceFileEntry({
    required this.name,
    required this.path,
    required this.relativePath,
    required this.isDirectory,
  });
}

/// Workspace file reads for the preview surfaces (markdown images, HTML
/// preview assembly) — the desktop's fileService on the `file` channel
/// (`Channels.file`, a fixed channel name outside the probing surface).
///
/// Method names (`readMediaPreview` / `readTextFile` / `stat`) come
/// from the desktop bundle and run through [MethodProbe]
/// like every other port — never hardcoded as a success assumption. Older
/// naming variants trail the bundle-derived names so a divergent desktop
/// build still works.
///
/// Scope shape live-certified 2026-09-29 (desktop 3.14.3): args.workspacePath is IGNORED (identical answers with
/// and without it) and relative paths resolve against the desktop process
/// CWD — so the wire payload is `{path}` only and callers must pass ABSOLUTE
/// paths. The workspacePath parameter stays on the public API so re-adding
/// the wire field is a one-line change if a future desktop requires it.
///
/// Answer parsing is defensive: a missing/mistyped primary field throws a
/// [StateError] naming the port and the answer shape — errors surface, they
/// are never swallowed into empty results. Answer field names are the
/// desktop's own: stat `{type, size, mtimeMs}`,
/// readMediaPreview `{dataBase64, mediaType, totalBytes}`, readTextFile
/// `{content, offset, bytesRead, totalBytes, truncated, isBinary}`.
class FileServicePort {
  /// Binds one RPC: the channel is fixed by the port owner, method/args vary.
  final Future<dynamic> Function(String method, List<Object?> args) call;

  FileServicePort(this.call);

  late final MethodProbe _probe = MethodProbe(call);

  // Candidate tables (new→old).
  static const _statCandidates = ['stat', 'getStat', 'fileStat'];
  static const _mediaCandidates = [
    'readMediaPreview',
    'mediaPreview',
    'readMedia',
  ];
  static const _textCandidates = ['readTextFile', 'readText', 'readFileText'];
  // Workspace file listing (the ⌘K file tab). Names are renderer-side
  // evidence (createFileService @270609580-@270610091) — the runtime
  // zcode.cjs does NOT carry them, so a runtime miss proves nothing.
  static const _searchFilesCandidates = ['searchWorkspaceFiles'];
  static const _listLengthCandidates = ['listWorkspaceFilesLength'];
  static const _listRangeCandidates = ['listWorkspaceFilesRange'];

  // Wire payload is `{path}` only — workspacePath certified ignored;
  // the parameter is kept for API stability only.
  Map<String, dynamic> _scope(String workspacePath, String path) =>
      {'path': path};

  /// File metadata (`{type, size}` — `type` is read and
  /// falls back to readMediaPreview when `size` is not a number).
  Future<FileStat> stat(String workspacePath, String path) async {
    final res = await _probe.run(
      'stat',
      _statCandidates,
      argsOf: (_) => <Object?>[_scope(workspacePath, path)],
    );
    if (res is! Map) {
      throw StateError('fileService.stat: unexpected answer ${res.runtimeType}');
    }
    final type = res['type'] ?? res['kind'];
    if (type is! String || type.isEmpty) {
      throw StateError('fileService.stat: no type field in answer '
          'keys=${res.keys.take(8).toList()}');
    }
    return FileStat(type: type, size: (res['size'] as num?)?.toInt());
  }

  /// Media bytes for inline preview (`{dataBase64, mediaType, size}` wire
  /// shape; the desktop errors with "Media file is too large for inline
  /// preview" beyond its cap — that error surfaces to the caller).
  Future<MediaPreview> readMedia(
    String workspacePath,
    String path, {
    int? maxBytes,
  }) async {
    final res = await _probe.run(
      'readMediaPreview',
      _mediaCandidates,
      argsOf: (_) => <Object?>[
        {
          ..._scope(workspacePath, path),
          if (maxBytes != null) 'maxBytes': maxBytes,
        },
      ],
    );
    if (res is! Map) {
      throw StateError(
          'fileService.readMediaPreview: unexpected answer ${res.runtimeType}');
    }
    final data = res['dataBase64'];
    if (data is! String || data.isEmpty) {
      throw StateError('fileService.readMediaPreview: no dataBase64 in answer '
          '(kind=${res['kind']}) keys=${res.keys.take(8).toList()}');
    }
    final Uint8List bytes;
    try {
      bytes = base64Decode(data);
    } on FormatException {
      throw StateError('fileService.readMediaPreview: bad base64 payload');
    }
    final total = res['totalBytes'] ?? res['size'];
    return MediaPreview(
      bytes: bytes,
      mediaType: res['mediaType'] is String ? res['mediaType'] as String : null,
      totalBytes: total is num ? total.toInt() : null,
    );
  }

  /// Paginated text read (`{path, offset, length}` → `{content, truncated,
  /// bytesRead, …}`; the certified text field is `content`).
  Future<TextChunk> readText(
    String workspacePath,
    String path, {
    int offset = 0,
    required int length,
  }) async {
    final res = await _probe.run(
      'readTextFile',
      _textCandidates,
      argsOf: (_) => <Object?>[
        {..._scope(workspacePath, path), 'offset': offset, 'length': length},
      ],
    );
    if (res is String) return TextChunk(text: res);
    if (res is! Map) {
      throw StateError(
          'fileService.readTextFile: unexpected answer ${res.runtimeType}');
    }
    final text = res['content'] ?? res['text'];
    if (text is! String) {
      throw StateError('fileService.readTextFile: no content field in answer '
          'keys=${res.keys.take(8).toList()}');
    }
    return TextChunk(
      text: text,
      hasMore: res['truncated'] is bool ? res['truncated'] as bool : null,
    );
  }

  // ------------------------------------------------ workspace file listing
  //
  // The search panel's file tab (renderer @313272117 `UEe`/`Vv` isomorph).
  // Primary method `searchWorkspaceFiles`; desktops without it fall back to
  // listing the whole tree (`listWorkspaceFilesLength` + paged
  // `listWorkspaceFilesRange`) and filtering locally. rootPath is the
  // workspace ABSOLUTE path — the certified scope rule above applies.

  /// Cheap reachability verdict for the file tab: the search method probed
  /// with a limit-1 empty query, falling to the length method (one count,
  /// no data). Any failure → false (the tab hides, the "all" tab degrades).
  Future<bool> workspaceFilesReachable(String rootPath) async {
    try {
      await _probe.run(
        'searchWorkspaceFiles',
        _searchFilesCandidates,
        argsOf: (_) => <Object?>[
          {'rootPath': rootPath, 'query': '', 'limit': 1},
        ],
      );
      return true;
    } on ChannelRpcError catch (e) {
      if (!MethodProbe.missingMethod(e.message)) return false;
    } catch (_) {
      return false;
    }
    try {
      await _probe.run(
        'listWorkspaceFilesLength',
        _listLengthCandidates,
        argsOf: (_) => <Object?>[{'rootPath': rootPath}],
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Workspace file search: `searchWorkspaceFiles({rootPath, query, limit})`
  /// when the desktop serves it, else the packed full listing filtered
  /// locally (contains, case-insensitive). All candidates miss → the probe
  /// error propagates and the caller hides the file tab.
  Future<List<WorkspaceFileEntry>> searchWorkspaceFiles(
    String rootPath, {
    String query = '',
    int limit = 100,
  }) async {
    try {
      final res = await _probe.run(
        'searchWorkspaceFiles',
        _searchFilesCandidates,
        argsOf: (_) => <Object?>[
          {'rootPath': rootPath, 'query': query, 'limit': limit},
        ],
      );
      return _parseFileEntries(res, rootPath: rootPath, limit: limit);
    } on ChannelRpcError catch (e) {
      if (!MethodProbe.missingMethod(e.message)) rethrow;
      final all = await _listAllFiles(rootPath);
      final needle = query.trim().toLowerCase();
      final hits = needle.isEmpty
          ? all
          : all
              .where((f) => f.relativePath.toLowerCase().contains(needle))
              .toList();
      return hits.length > limit ? hits.sublist(0, limit) : hits;
    }
  }

  /// The whole tree as `{path, relativePath, type}` rows. The packed string
  /// is walked once per root and cached for the port's lifetime — every
  /// keystroke in the fallback mode must not re-walk the workspace
  /// (staleness window = the holding page's lifetime, accepted).
  List<WorkspaceFileEntry>? _listedCache;
  String? _listedCacheRoot;

  Future<List<WorkspaceFileEntry>> _listAllFiles(String rootPath) async {
    if (_listedCache != null && _listedCacheRoot == rootPath) {
      return _listedCache!;
    }
    final lengthRes = await _probe.run(
      'listWorkspaceFilesLength',
      _listLengthCandidates,
      argsOf: (_) => <Object?>[{'rootPath': rootPath}],
    );
    final total = lengthRes is num ? lengthRes.toInt() : 0;
    // Page size 4 MiB of packed characters per range call (the renderer
    // pages `REe=4e6`, @313271364); 1 MiB keeps each RPC payload modest.
    const pageChars = 1 << 20;
    final packed = StringBuffer();
    for (var offset = 0; offset < total; offset += pageChars) {
      final res = await _probe.run(
        'listWorkspaceFilesRange',
        _listRangeCandidates,
        argsOf: (_) => <Object?>[
          {
            'rootPath': rootPath,
            'offset': offset,
            'length': pageChars,
          },
        ],
      );
      if (res is String) packed.write(res);
    }
    final rows = _parsePackedFiles(packed.toString(), rootPath);
    _listedCache = rows;
    _listedCacheRoot = rootPath;
    return rows;
  }

  /// Parses a searchWorkspaceFiles answer (array of entry maps) into typed
  /// rows; malformed entries are dropped, never thrown.
  List<WorkspaceFileEntry> _parseFileEntries(
    dynamic res, {
    required String rootPath,
    required int limit,
  }) {
    if (res is! List) return const [];
    final rows = <WorkspaceFileEntry>[];
    for (final e in res) {
      if (e is! Map) continue;
      final relativePath = '${e['relativePath'] ?? e['path'] ?? ''}';
      if (relativePath.isEmpty) continue;
      rows.add(_entryFromRelativePath(
        relativePath,
        rootPath: rootPath,
        type: '${e['type'] ?? ''}',
        name: '${e['name'] ?? ''}',
        path: e['path'] is String ? e['path'] as String : null,
      ));
      if (rows.length >= limit) break;
    }
    return rows;
  }

  /// Packed-string parser, renderer `Vv` @313271506 verbatim: records are
  /// `\n`-separated, each `type TAB escapedRelativePath` (TAB field
  /// separator; escapes `\\` → `\\`, TAB → `\t`, LF → `\n`).
  static List<WorkspaceFileEntry> _parsePackedFiles(
    String packed,
    String rootPath,
  ) {
    if (packed.isEmpty) return const [];
    final rows = <WorkspaceFileEntry>[];
    for (final record in packed.split('\n')) {
      if (record.isEmpty) continue;
      final tab = record.indexOf('\t');
      if (tab == -1) continue;
      final relativePath = _unescapePackedPath(record.substring(tab + 1));
      if (relativePath.isEmpty) continue;
      rows.add(_entryFromRelativePath(
        relativePath,
        rootPath: rootPath,
        type: record.substring(0, tab),
      ));
    }
    return rows;
  }

  static WorkspaceFileEntry _entryFromRelativePath(
    String relativePath, {
    required String rootPath,
    required String type,
    String? name,
    String? path,
  }) {
    final isWindowsRoot = rootPath.contains('\\');
    final native = isWindowsRoot
        ? relativePath.replaceAll('/', '\\')
        : relativePath;
    final root = rootPath.endsWith('/') || rootPath.endsWith('\\')
        ? rootPath
        : '$rootPath${isWindowsRoot ? '\\' : '/'}';
    final lastSlash = relativePath.lastIndexOf('/');
    final bareName =
        lastSlash == -1 ? relativePath : relativePath.substring(lastSlash + 1);
    return WorkspaceFileEntry(
      name: name != null && name.isNotEmpty ? name : bareName,
      path: path ?? '$root$native',
      relativePath: relativePath,
      isDirectory: type == 'directory',
    );
  }

  /// Renderer `VEe` @313271478: `\t` → TAB, `\n` → LF, `\\` → `\`, any
  /// other escape keeps the escaped char itself.
  static String _unescapePackedPath(String escaped) {
    if (!escaped.contains('\\')) return escaped;
    final out = StringBuffer();
    for (var i = 0; i < escaped.length; i++) {
      final ch = escaped[i];
      if (ch == r'\' && i + 1 < escaped.length) {
        final next = escaped[++i];
        out.write(next == 't' ? '\t' : next == 'n' ? '\n' : next);
      } else {
        out.write(ch);
      }
    }
    return out.toString();
  }
}
