import 'sqlite_pages.dart';

export 'sqlite_pages.dart' show SqliteRangeRead;

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
    required SqliteRangeRead readRange,
    void Function(String line)? onLog,
    String? Function()? loadCachedHome,
    Future<void> Function(String home)? saveCachedHome,
  })  : _workspaces = workspaces,
        _readRange = readRange,
        _log = onLog,
        _loadCachedHome = loadCachedHome,
        _saveCachedHome = saveCachedHome;

  final List<Map<String, dynamic>> Function() _workspaces;
  final SqliteRangeRead _readRange;
  final void Function(String line)? _log;

  /// Desktop-home cache seam (resolver-home-fallback, 2026-10-23): the
  /// single-window workspace registry can list no `.zcode/workspace` path at
  /// all (no draft/default session open on the desktop), and then
  /// [desktopHome] has nothing to derive from. A home a PREVIOUS connection
  /// learned still names the same desktop's index. Nothing validates it
  /// here — the db is authoritative, so a stale home fails inside the normal
  /// read path and degrades exactly like a wrong wire-derived home. Injected
  /// by the composition root (lib/protocol stays plugin-free).
  final String? Function()? _loadCachedHome;
  final Future<void> Function(String home)? _saveCachedHome;

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
    // Wire first: a listed draft/default workspace names the CURRENT home.
    // Only when the registry lists none (empty single-window registry) does
    // the last persisted home stand in — see [_loadCachedHome].
    final wireHome = desktopHome();
    final home = wireHome ?? _cachedHome();
    if (wireHome != null) {
      await _rememberHome(wireHome);
    } else if (home != null) {
      _log?.call('[project] home from cache (wire listed none)');
    }
    if (home == null) {
      _log?.call('[project] no .zcode/workspace path listed — project '
          'attribution disabled');
      // Deterministic: the workspace list will not grow a `.zcode/workspace`
      // entry without a reconnect.
      _resolved = true;
      return null;
    }
    final path = indexPath(home);
    try {
      final reader = await SqlitePageReader.open(path, _readRange);
      final mapping = await _readProjectRoots(reader);
      _log?.call('[project] tasks-index mapping loaded: '
          '${mapping.roots.length} root(s)');
      _loaded = mapping;
      _resolved = true;
      return mapping;
    } on SqliteFormatError catch (e) {
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

  /// Persists a wire-derived home for the next connection (R2). A failed
  /// save is logged and ignored: the mapping never depends on the cache,
  /// only the next cold registry does.
  Future<void> _rememberHome(String home) async {
    final save = _saveCachedHome;
    if (save == null) return;
    try {
      await save(home);
    } catch (e) {
      _log?.call('[project] cached home save failed ($e)');
    }
  }

  /// The last persisted home, when the seam carries one. A throwing seam
  /// degrades like any other failure — the resolver never throws.
  String? _cachedHome() {
    try {
      return _loadCachedHome?.call();
    } catch (e) {
      _log?.call('[project] cached home read failed ($e)');
      return null;
    }
  }

  /// The desktop home this resolver knows synchronously: the wire-derived
  /// one first (a listed `<home>/.zcode/workspace/...` path), else the home a
  /// previous connection persisted. Null while neither source names one.
  /// Read-only seam for the default-workspace synthesis (10-26 D1) — it
  /// never triggers a read and adds no state.
  String? get knownHome => desktopHome() ?? _cachedHome();

  /// `<home>/.zcode/workspace/default` in [home]'s own separator conventions
  /// (Windows drives/backslashes keep `\`, POSIX keeps `/`) — the same rule
  /// [indexPath] uses. The synthesized entry is sent as a listTaskList
  /// scope, i.e. as a `workspace_key` filter value, so it must match the
  /// desktop's native spelling.
  static String defaultWorkspacePath(String home) {
    final normalized = home.replaceAll(r'\', '/');
    var trimmed = normalized;
    while (trimmed.length > 1 && trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    final sep =
        _driveLetter.hasMatch(home) || home.contains(r'\') ? r'\' : '/';
    return [trimmed.replaceAll('/', sep), '.zcode', 'workspace', 'default']
        .join(sep);
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

  /// `<home>/.zcode/v2/tasks-index.sqlite` in [home]'s own separator
  /// conventions. Shared with [TaskGroupResolver] (the task-group tables
  /// live in the SAME database): one path derivation, never a copy.
  static String indexPath(String home) {
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

/// `projects ⋈ project_roots` for local, live projects (the desktop's own
/// `uniqueRootProject` filter). Every root row is kept — one project may
/// own several roots. Column positions are the MEASURED 3.16.2 schema
/// (live index, 2026-10-22):
///   projects:       0=project_id, 1=host_id, 2=name, 7=deleted
///   project_roots:  0=project_id, 1=root_path
/// A record with fewer columns than the contract needs is a schema we do
/// not understand → deterministic failure.
Future<ProjectMapping> _readProjectRoots(SqlitePageReader reader) async {
  // sqlite_master: (type, name, tbl_name, rootpage, sql).
  int? projectsRoot;
  int? rootsRoot;
  for (final row in await reader.scanTable(1)) {
    if (row.length < 4) continue;
    if (row[0] != 'table') continue;
    final name = row[1];
    final root = row[3];
    if (root is! int || root <= 0) continue;
    if (name == 'projects') projectsRoot = root;
    if (name == 'project_roots') rootsRoot = root;
  }
  if (projectsRoot == null || rootsRoot == null) {
    throw const SqliteFormatError('missing projects/project_roots');
  }

  final live = <String, String>{};
  for (final row in await reader.scanTable(projectsRoot)) {
    if (row.length < 8) {
      throw const SqliteFormatError('projects column contract');
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
  for (final row in await reader.scanTable(rootsRoot)) {
    if (row.length < 2) {
      throw const SqliteFormatError('project_roots column contract');
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
