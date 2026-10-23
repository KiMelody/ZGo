import 'dart:convert';
import 'dart:typed_data';

/// One byte-range read of a desktop file — the injected seam over the file
/// channel's `readFileRange` (widget-free: the transport-side call is
/// composed in DeviceSession, this layer never imports the channel).
///
/// Success answers the bytes the desktop returned (empty/short only at EOF,
/// which the page reader treats as a truncated index); ANY channel-level
/// problem — timeout, bridge swing, missing method — is THROWN. The resolver
/// classifies a throw as TRANSIENT (do not cache: retry on the next
/// creation) and a short/garbled answer as DETERMINISTIC (cache the null).
typedef ProjectIndexRead = Future<Uint8List> Function(
  String path,
  int offset,
  int length,
);

/// One live local project root as read from the desktop index.
///
/// The workspace-list completion (research/07 方案 A) synthesizes a
/// workspace entry from each one — `label` from [name], `workspacePath`
/// from [rootPath] — because the desktop's bootstrap only lists the bound
/// window's registry.
class ProjectRoot {
  const ProjectRoot({
    required this.projectId,
    required this.name,
    required this.rootPath,
  });

  /// The desktop project id the root belongs to.
  final String projectId;

  /// `projects.name` (column 2 of the measured 3.16.2 schema); empty when
  /// the desktop stored no name (the UI then falls back to the path's
  /// basename).
  final String name;

  /// `project_roots.root_path` in its desktop-native spelling — exactly the
  /// value task rows carry as `workspacePath`, so it can be used as a
  /// listTaskList scope verbatim.
  final String rootPath;

  @override
  String toString() => 'ProjectRoot($projectId, $name, $rootPath)';
}

/// The desktop's project layer as read from `tasks-index.sqlite`: the
/// lookup `createSession` attribution needs plus the root list the
/// workspace-list completion consumes.
class ProjectMapping {
  const ProjectMapping({required this.byRootPath, required this.roots});

  /// Normalized rootPath → projectId (see
  /// [ProjectResolver.normalizeProjectRoot]). One project may own several
  /// roots.
  final Map<String, String> byRootPath;

  /// Every live local root row, in database order (one entry per
  /// project_roots row).
  final List<ProjectRoot> roots;
}

/// Resolves a workspace path to the 3.16.2 desktop's project id by reading
/// the desktop's own `tasks-index.sqlite` — the ZGo-side fix for the
/// NULL-project attribution of remotely created sessions (design 10-21
/// Part 2, research/05).
///
/// The desktop's `v4 createSession` channel parameters accept an outer
/// `projectId` sibling of `workspacePath` (its internal task facade sends
/// exactly that shape); `reserveCreatedTask` then inserts the row with that
/// project after validating that the workspace path sits in one of the
/// project's roots. The mapping read here is the desktop's own — it passes
/// that validation by construction.
///
/// Degradation is the contract: any failure (no `.zcode/workspace` path in
/// the workspace list, unreadable file, unknown schema) answers null and the
/// createSession payload keeps its current shape. A stale mapping is caught
/// by the desktop's `project.*` validation error and covered by the
/// transport's one-shot retry without the field.
///
/// The same read also feeds the workspace-list completion (research/07
/// 方案 A): [projectRoots] exposes every live local root so DeviceSession can
/// append the roots the desktop's single-window bootstrap registry omits.
///
/// Read form (acceptance round 1, 2026-10-22): the live index is ~25 MB, so
/// pulling it through the relay always tripped the 30 s RPC timeout (25 ×
/// 1 MiB chunks at ~2 s each plus bridge churn). The resolver now parses the
/// SQLite file format itself and reads ONLY the needed pages: the 100-byte
/// header, page 1 (`sqlite_master`), and the b-tree pages of the `projects`
/// and `project_roots` tables — a handful of 4 KiB reads (<20 KiB total)
/// instead of the whole file. Pure Dart: package:sqlite3 / dart:io /
/// sqlite3_flutter_libs are no longer part of the app (sqlite3 is a dev
/// dependency for building test fixtures only).
///
/// WAL: only the main file is read (design decision 2). `projects` changes
/// only when a workspace is first opened, so the main file is almost always
/// fresh enough; a WAL-only schema answers a format failure and degrades.
class ProjectResolver {
  ProjectResolver({
    required List<Map<String, dynamic>> Function() workspaces,
    required ProjectIndexRead readRange,
    void Function(String line)? onLog,
  })  : _workspaces = workspaces,
        _readRange = readRange,
        _log = onLog;

  final List<Map<String, dynamic>> Function() _workspaces;
  final ProjectIndexRead _readRange;
  final void Function(String line)? _log;

  /// The loaded mapping. Null until a read succeeded.
  ProjectMapping? _loaded;

  /// Whether the single resolution attempt reached a DETERMINISTIC answer
  /// (success, no home, or an unusable file). A transient failure leaves
  /// this false so the next creation retries — the acceptance failure was
  /// pinned for the whole process lifetime by an unconditional flag.
  bool _resolved = false;

  /// Concurrent creations share one read instead of pulling the index twice.
  Future<ProjectMapping?>? _inFlight;

  /// The desktop projectId this workspace belongs to, or null when the
  /// mapping is unavailable / the workspace is not a project root.
  Future<String?> projectIdFor(String workspacePath) async {
    final loaded = await mapping();
    final roots = loaded?.byRootPath;
    if (roots == null || roots.isEmpty) return null;
    return roots[normalizeProjectRoot(workspacePath)];
  }

  /// Every live local project root of the loaded mapping (const [] before a
  /// mapping resolved or after a deterministic failure). Sync by design:
  /// the workspace-list completion re-merges on every bootstrap frame
  /// without triggering a read, and the async completion path awaits
  /// [mapping] first.
  List<ProjectRoot> get projectRoots => _loaded?.roots ?? const <ProjectRoot>[];

  /// Resolves the mapping, joining the in-flight read when one is running.
  /// Cache contract of [projectIdFor]: a deterministic failure is answered
  /// from the cache for the process lifetime, a transient failure answers
  /// null and stays retryable. The workspace completion (research/07)
  /// awaits this with nothing else to look up.
  Future<ProjectMapping?> mapping() {
    if (_resolved) return Future.value(_loaded);
    final pending = _inFlight;
    if (pending != null) return pending;
    final future = _readMapping();
    _inFlight = future;
    return future.whenComplete(() {
      if (identical(_inFlight, future)) _inFlight = null;
    });
  }

  Future<ProjectMapping?> _readMapping() async {
    final home = desktopHome();
    if (home == null) {
      _log?.call('[project] no .zcode/workspace path listed — project '
          'attribution disabled');
      // Deterministic: the workspace list will not grow a `.zcode/workspace`
      // entry without a reconnect.
      _resolved = true;
      return null;
    }
    final path = _indexPath(home);
    try {
      final reader = await _IndexPageReader.open(path, _readRange);
      final mapping = await reader.readProjectRoots();
      _log?.call('[project] tasks-index mapping loaded: '
          '${mapping.roots.length} root(s)');
      _loaded = mapping;
      _resolved = true;
      return mapping;
    } on _IndexFormatError catch (e) {
      // Bad magic / truncated file / unknown schema: the file will not heal
      // while this connection lives — cache the degraded answer.
      _log?.call('[project] tasks-index.sqlite unusable ($e) — project '
          'attribution disabled');
      _resolved = true;
      return null;
    } catch (e) {
      // Transient (timeout / bridge swing / channel error): degrade THIS
      // creation only; the next one retries.
      _log?.call('[project] tasks-index read failed ($e) — will retry on '
          'the next creation');
      return null;
    }
  }

  /// Desktop home derived from any listed workspace path carrying a
  /// `<home>/.zcode/workspace/...` segment (3.16.2 draft workspaces always
  /// do when such a workspace is listed). The listed workspace paths are
  /// the only absolute desktop paths this layer sees before a read.
  String? desktopHome() {
    for (final ws in _workspaces()) {
      final path = ws['workspacePath'];
      if (path is! String || path.isEmpty) continue;
      final home = desktopHomeFor(path);
      if (home != null) return home;
    }
    return null;
  }

  /// `<home>` from `<home>/.zcode/workspace/...`; null when the path carries
  /// no such segment (or has nothing in front of it).
  static String? desktopHomeFor(String workspacePath) {
    final normalized = workspacePath.replaceAll(r'\', '/');
    const marker = '/.zcode/workspace';
    final at = normalized.toLowerCase().indexOf(marker);
    if (at <= 0) return null;
    return normalized.substring(0, at);
  }

  static final _driveLetter = RegExp(r'^[A-Za-z]:[\\/]');

  static String _indexPath(String home) {
    final sep =
        _driveLetter.hasMatch(home) || home.contains(r'\') ? r'\' : '/';
    return [home, '.zcode', 'v2', 'tasks-index.sqlite'].join(sep);
  }

  /// Root-path spelling normalization for the lookup: the database stores
  /// desktop-native paths (Windows: backslashes, case-insensitive), while
  /// wire workspace paths may arrive with forward slashes or another case.
  /// POSIX paths stay case-sensitive — only the Windows form folds.
  static String normalizeProjectRoot(String path) {
    var p = path.trim();
    if (p.isEmpty) return p;
    if (_driveLetter.hasMatch(p) || p.contains(r'\')) {
      p = p.replaceAll('/', r'\');
      while (p.length > 1 && p.endsWith(r'\')) {
        p = p.substring(0, p.length - 1);
      }
      return p.toLowerCase();
    }
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }
}

/// A deterministic parse/schema problem: the file is not the index we can
/// read, and re-reading it buys nothing (cached by [ProjectResolver]).
class _IndexFormatError implements Exception {
  const _IndexFormatError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Minimal read-only SQLite table-b-tree reader — only what the project
/// mapping needs. File format reference: sqlite.org/fileformat2.html.
///
/// Reads exactly the pages it walks: 100-byte header → page 1
/// (`sqlite_master`) → each target table's root page and child pages.
/// Overflow chains are followed for both `sqlite_master.sql` rows and leaf
/// data rows (a CREATE statement or a long root path can exceed one page).
class _IndexPageReader {
  _IndexPageReader._(
    this._path,
    this._read,
    this._pageSize,
    this._usable,
    this._pageCount,
  );

  /// SQLite file header size; page 1's b-tree header starts right after it.
  static const _headerBytes = 100;

  static const _magic = 'SQLite format 3\u0000';

  /// Safety bound on corrupt page numbers when the header carries no page
  /// count; the count is normally authoritative.
  static const _pageLimit = 1 << 26;

  final String _path;
  final ProjectIndexRead _read;
  final int _pageSize;

  /// Page size minus the reserved area at the end of every page — the
  /// usable payload region the b-tree actually addresses.
  final int _usable;

  /// Database size in pages from the header (0 = unknown/ignored).
  final int _pageCount;

  static Future<_IndexPageReader> open(
    String path,
    ProjectIndexRead read,
  ) async {
    final header = await read(path, 0, _headerBytes);
    if (header.length < _headerBytes) {
      throw const _IndexFormatError('truncated header');
    }
    for (var i = 0; i < _magic.length; i++) {
      if (header[i] != _magic.codeUnitAt(i)) {
        throw const _IndexFormatError('bad magic');
      }
    }
    // Offset 16: page size, big-endian; the value 1 encodes 65536.
    var pageSize = (header[16] << 8) | header[17];
    if (pageSize == 1) pageSize = 65536;
    if (pageSize < 512 || pageSize > 65536 || (pageSize & (pageSize - 1)) != 0) {
      throw _IndexFormatError('bad page size $pageSize');
    }
    // Offset 20: reserved bytes per page; usable = page size - reserved.
    final usable = pageSize - header[20];
    if (usable < 480) {
      // SQLite's own minimum (fileformat2 §1.3).
      throw _IndexFormatError('bad usable size $usable');
    }
    final pageCount = (header[28] << 24) |
        (header[29] << 16) |
        (header[30] << 8) |
        header[31];
    return _IndexPageReader._(path, read, pageSize, usable, pageCount);
  }

  /// `projects ⋈ project_roots` for local, live projects (the desktop's own
  /// `uniqueRootProject` filter). Every root row is kept — one project may
  /// own several roots. Column positions are the MEASURED 3.16.2 schema
  /// (live index, 2026-10-22):
  ///   projects:       0=project_id, 1=host_id, 2=name, 7=deleted
  ///   project_roots:  0=project_id, 1=root_path
  /// A record with fewer columns than the contract needs is a schema we do
  /// not understand → deterministic failure.
  Future<ProjectMapping> readProjectRoots() async {
    // sqlite_master: (type, name, tbl_name, rootpage, sql).
    int? projectsRoot;
    int? rootsRoot;
    for (final row in await _scanTable(1)) {
      if (row.length < 4) continue;
      if (row[0] != 'table') continue;
      final name = row[1];
      final root = row[3];
      if (root is! int || root <= 0) continue;
      if (name == 'projects') projectsRoot = root;
      if (name == 'project_roots') rootsRoot = root;
    }
    if (projectsRoot == null || rootsRoot == null) {
      throw const _IndexFormatError('missing projects/project_roots');
    }

    final live = <String, String>{};
    for (final row in await _scanTable(projectsRoot)) {
      if (row.length < 8) {
        throw const _IndexFormatError('projects column contract');
      }
      final id = row[0];
      final host = row[1];
      final deleted = row[7];
      if (id is String &&
          id.isNotEmpty &&
          host == 'local' &&
          deleted is int &&
          deleted == 0) {
        final name = row[2];
        live[id] = name is String ? name : '';
      }
    }
    if (live.isEmpty) {
      return const ProjectMapping(byRootPath: {}, roots: []);
    }

    final byRootPath = <String, String>{};
    final roots = <ProjectRoot>[];
    for (final row in await _scanTable(rootsRoot)) {
      if (row.length < 2) {
        throw const _IndexFormatError('project_roots column contract');
      }
      final id = row[0];
      final rootPath = row[1];
      if (id is String &&
          live.containsKey(id) &&
          rootPath is String &&
          rootPath.isNotEmpty) {
        byRootPath[ProjectResolver.normalizeProjectRoot(rootPath)] = id;
        roots.add(
          ProjectRoot(
            projectId: id,
            name: live[id]!,
            rootPath: rootPath,
          ),
        );
      }
    }
    return ProjectMapping(byRootPath: byRootPath, roots: roots);
  }

  /// Walks a table b-tree from [rootPage] and answers every leaf record.
  /// Interior table pages (0x05) recurse into their child pointers plus the
  /// right-most child at header offset 8; leaves (0x0D) decode their cells.
  Future<List<List<Object?>>> _scanTable(int rootPage) async {
    final rows = <List<Object?>>[];
    final visited = <int>{};
    Future<void> visit(int pageNo) async {
      if (!visited.add(pageNo)) {
        throw _IndexFormatError('b-tree cycle at page $pageNo');
      }
      final page = await _page(pageNo);
      // Page 1 carries the 100-byte file header before its b-tree header.
      final h = pageNo == 1 ? _headerBytes : 0;
      if (h + 12 > _usable) throw const _IndexFormatError('short page header');
      final type = page[h];
      final headerSize = switch (type) {
        0x05 => 12, // interior table b-tree
        0x0D => 8, // leaf table b-tree
        _ => throw _IndexFormatError(
            'page $pageNo has b-tree type 0x${type.toRadixString(16)}'),
      };
      final cellCount = (page[h + 3] << 8) | page[h + 4];
      final pointers = h + headerSize;
      if (pointers + cellCount * 2 > _usable) {
        throw const _IndexFormatError('cell pointer array past page');
      }
      for (var i = 0; i < cellCount; i++) {
        final at = pointers + i * 2;
        final cell = (page[at] << 8) | page[at + 1];
        if (cell + 4 > _usable) {
          throw const _IndexFormatError('cell offset past page');
        }
        if (type == 0x05) {
          // Interior table cell: 4-byte left child page number + rowid key.
          await visit(_be32(page, cell));
        } else {
          rows.add(_record(await _leafPayload(page, cell)));
        }
      }
      if (type == 0x05) {
        // Right-most child pointer lives in the page header.
        await visit(_be32(page, h + 8));
      }
    }

    await visit(rootPage);
    return rows;
  }

  Future<Uint8List> _page(int pageNo) async {
    if (pageNo <= 0) {
      throw _IndexFormatError('bad page number $pageNo');
    }
    final limit = _pageCount > 0 ? _pageCount : _pageLimit;
    if (pageNo > limit) {
      throw _IndexFormatError('page $pageNo past database end ($limit)');
    }
    final bytes = await _read(_path, (pageNo - 1) * _pageSize, _pageSize);
    if (bytes.length < _usable) {
      // Short read inside the database: the index is truncated (a transient
      // channel error would have thrown from the seam instead).
      throw _IndexFormatError('short read at page $pageNo '
          '(${bytes.length}/$_usable)');
    }
    return bytes;
  }

  /// One table-leaf cell → its record payload: varint payload length,
  /// varint rowid, then the local payload (plus a 4-byte overflow pointer
  /// when the payload exceeds the local size). The overflow chain is
  /// followed until the declared payload length is assembled.
  Future<Uint8List> _leafPayload(Uint8List page, int cell) async {
    final total = _varint(page, cell, limit: _usable);
    final afterLength = cell + total.length;
    final rowid = _varint(page, afterLength, limit: _usable);
    final start = afterLength + rowid.length;
    final local = _localPayloadSize(total.value);
    final tail = local < total.value ? 4 : 0;
    if (start + local + tail > _usable) {
      throw const _IndexFormatError('leaf payload past page');
    }
    if (local == total.value) {
      return Uint8List.sublistView(page, start, start + local);
    }
    var overflow = _be32(page, start + local);
    final out = BytesBuilder(copy: false)
      ..add(Uint8List.sublistView(page, start, start + local));
    var remaining = total.value - local;
    final seen = <int>{};
    while (remaining > 0) {
      if (overflow == 0 || !seen.add(overflow)) {
        throw const _IndexFormatError('broken overflow chain');
      }
      final next = await _page(overflow);
      final chunk = remaining < _usable - 4 ? remaining : _usable - 4;
      out.add(Uint8List.sublistView(next, 4, 4 + chunk));
      remaining -= chunk;
      overflow = _be32(next, 0);
    }
    return out.takeBytes();
  }

  /// How much of a table-leaf payload lives on the page itself
  /// (fileformat2 §2.3.1, table b-tree fractions: max 64, min 32,
  /// leaf 32):
  ///   maxLocal = usable - 35
  ///   minLocal = ((usable - 12) * 32 / 255) - 23
  int _localPayloadSize(int total) {
    final maxLocal = _usable - 35;
    if (total <= maxLocal) return total;
    final minLocal = ((_usable - 12) * 32) ~/ 255 - 23;
    var local = minLocal + (total - minLocal) % (_usable - 4);
    if (local > maxLocal) local = minLocal;
    return local;
  }

  /// Record format: header-size varint (includes itself), serial-type
  /// varints, then the body values in order.
  static List<Object?> _record(Uint8List payload) {
    final header = _varint(payload, 0);
    final headerEnd = header.value;
    if (headerEnd < header.length || headerEnd > payload.length) {
      throw const _IndexFormatError('bad record header length');
    }
    final types = <int>[];
    var at = header.length;
    while (at < headerEnd) {
      final type = _varint(payload, at, limit: headerEnd);
      at += type.length;
      types.add(type.value);
    }
    if (at != headerEnd) {
      throw const _IndexFormatError('record header overflow');
    }
    final values = <Object?>[];
    var data = headerEnd;
    for (final type in types) {
      switch (type) {
        case 0:
          values.add(null);
        case 1:
        case 2:
        case 3:
        case 4:
        case 5:
        case 6:
          final size = const [0, 1, 2, 3, 4, 6, 8][type];
          values.add(_int(payload, data, size));
          data += size;
        case 7:
          if (data + 8 > payload.length) {
            throw const _IndexFormatError('record value past payload');
          }
          values.add(
            ByteData.sublistView(payload, data, data + 8).getFloat64(0),
          );
          data += 8;
        case 8:
          values.add(0);
        case 9:
          values.add(1);
        default:
          final text = type.isOdd;
          final size = text ? (type - 13) ~/ 2 : (type - 12) ~/ 2;
          if (size < 0 || data + size > payload.length) {
            throw const _IndexFormatError('record value past payload');
          }
          final bytes = Uint8List.sublistView(payload, data, data + size);
          if (text) {
            try {
              values.add(utf8.decode(bytes));
            } on FormatException {
              throw const _IndexFormatError('record text is not utf-8');
            }
          } else {
            values.add(bytes);
          }
          data += size;
      }
    }
    if (data > payload.length) {
      throw const _IndexFormatError('record body past payload');
    }
    return values;
  }

  /// Big-endian signed integer of [size] bytes (serial types 1-6).
  static int _int(Uint8List bytes, int offset, int size) {
    if (offset + size > bytes.length) {
      throw const _IndexFormatError('record integer past payload');
    }
    var value = 0;
    for (var i = 0; i < size; i++) {
      value = (value << 8) | bytes[offset + i];
    }
    return switch (size) {
      1 => value >= 0x80 ? value - 0x100 : value,
      2 => value >= 0x8000 ? value - 0x10000 : value,
      3 => value >= 0x800000 ? value - 0x1000000 : value,
      4 => value >= 0x80000000 ? value - 0x100000000 : value,
      6 => value >= 0x800000000000 ? value - 0x1000000000000 : value,
      // Dart ints are 64-bit two's complement: the wraps ARE the sign.
      _ => value,
    };
  }

  /// SQLite varint: 1-9 bytes, 7 bits each, the 9th byte contributes 8.
  static ({int value, int length}) _varint(
    Uint8List bytes,
    int offset, {
    int? limit,
  }) {
    final end = limit ?? bytes.length;
    var value = 0;
    for (var i = 0; i < 9; i++) {
      final at = offset + i;
      if (at >= end || at >= bytes.length) {
        throw const _IndexFormatError('varint past page');
      }
      final byte = bytes[at];
      if (i == 8) {
        value = (value << 8) | byte;
        return (value: value, length: 9);
      }
      value = (value << 7) | (byte & 0x7f);
      if (byte & 0x80 == 0) return (value: value, length: i + 1);
    }
    throw const _IndexFormatError('varint too long');
  }

  static int _be32(Uint8List bytes, int offset) {
    if (offset + 4 > bytes.length) {
      throw const _IndexFormatError('u32 past page');
    }
    return (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
  }
}
