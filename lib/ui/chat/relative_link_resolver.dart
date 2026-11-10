/// Relative-link resolution for workspace previews (task
/// 11-09-relative-link-resolve, design §回退链): the two fallback layers that
/// run after the L1 workspace-root join answered ENOENT.
///
/// * [relativeLinkContextBases] — **L2**, a pure function over the
///   conversation rows: the directories of the most recent file-tool rows,
///   newest first, deduped, capped. The desktop agent's messages link
///   relative to whatever file it was last reading (`adr/0008-x.md` in a
///   message that excerpts `<ws>/docs/adr/0007.md`), so those dirnames are
///   the highest-probability bases.
/// * [WorkspaceBasenameSearch] — **L3**, a budget-bounded BFS that finds a
///   file by basename anywhere under the workspace. The readdir transport is
///   injected as a callback: this file knows nothing about the wire (the
///   port lives in `protocol/file_service.dart`), so the budget boundaries
///   are unit-testable with a fake listing.
///
/// Both layers are pure/transport-injected, so the fallback chain in
/// `chat_preview.dart` stays a thin orchestrator.
library;

import '../../protocol/file_service.dart';
import 'file_read_result.dart';
import 'tool_row_semantics.dart';

/// L3 budget caps (design §L3 固定成本 — user-final: a fixed budget, not a
/// wall-clock timeout). Any one cap reached stops the search immediately
/// with whatever was found so far.
const int searchMaxReaddirCalls = 40;
const int searchMaxEntries = 5000;
const int searchMaxDepth = 6;

/// How many L2 context bases are tried at most. The excerpt scenario's base
/// is nearly always in the 1-2 most recent tool rows; the cap keeps a long
/// session from stat-storming.
const int maxRelativeLinkContextBases = 5;

/// Directory names the L3 search never descends into (generated/vendored
/// output). Compared case-insensitively — the target platform is Windows.
/// Entries whose NAME is skipped still count against [SearchBudget.entries]:
/// the listing paid for them, so the budget stays honest.
const Set<String> skippedSearchDirs = {
  '.git',
  'node_modules',
  'build',
  'dist',
  'out',
  '.dart_tool',
  '.gradle',
  '.idea',
  'target',
};

/// One resolved preview target: the absolute [path] the wire reads, the
/// [label] the candidate list shows (workspace-relative where possible) and
/// the [read] outcome when the resolver already paid for it (L2 probes its
/// bases with the real read, so a hit must not be fetched twice — the page
/// seeds its memo with it).
class PreviewCandidate {
  final String path;
  final String label;
  final FileTextResult? read;
  const PreviewCandidate({
    required this.path,
    required this.label,
    this.read,
  });
}

/// Outcome of one L2 → L3 fallback (`ChatPreview.resolveRelativeLink`).
/// [candidates] are in priority order — L2 bases first (newest tool row
/// first), then L3 BFS order — and [searched] is true once the L3 walk ran
/// (the "searched the workspace" appendix must only claim what happened).
class PreviewResolution {
  final List<PreviewCandidate> candidates;
  final bool searched;
  const PreviewResolution({
    this.candidates = const [],
    this.searched = false,
  });
}

/// L2: the workspace directories the current conversation's most recent
/// file-tool rows point into — newest row first, deduped (case-insensitively,
/// Windows paths), at most [limit].
///
/// Only `kind == 'toolCall'` rows of file-shaped tools count (a Grep row's
/// `path` is a directory, so its dirname would be one level too high). The
/// path itself comes from the same key order as `toolFilePath`
/// ([toolFilePathKeys]), whether the row carries a decoded `input` map or
/// only the streaming `inputText` string.
List<String> relativeLinkContextBases(
  List<Map<String, dynamic>> rows, {
  int limit = maxRelativeLinkContextBases,
}) {
  if (limit <= 0) return const [];
  final bases = <String>[];
  final seen = <String>{};
  for (var i = rows.length - 1; i >= 0; i--) {
    final row = rows[i];
    if (row['kind'] != 'toolCall') continue;
    if (!_isFileTool('${row['toolName'] ?? ''}')) continue;
    final path = _rowFilePath(row);
    if (path == null) continue;
    final dir = directoryOf(path);
    if (dir == null) continue;
    if (!seen.add(dir.toLowerCase())) continue;
    bases.add(dir);
    if (bases.length >= limit) break;
  }
  return bases;
}

/// The parent directory of [path] with `/` separators, null when the path has
/// no directory component (`notes.md`) or the component is empty.
String? directoryOf(String path) {
  final p = path.replaceAll('\\', '/');
  final slash = p.lastIndexOf('/');
  if (slash <= 0) return null;
  final dir = p.substring(0, slash);
  return dir.isEmpty ? null : dir;
}

/// Joins [base] and [rel] with one `/`, tolerating a trailing separator on
/// the base and either separator style in [rel].
String joinFsPath(String base, String rel) {
  final b = base.replaceAll('\\', '/');
  final r = rel.replaceAll('\\', '/');
  return b.endsWith('/') ? '$b$r' : '$b/$r';
}

/// L2 probe bases: the recent tool-row directories themselves, then their
/// ancestors INSIDE [workspacePath] level by level (nearest first). Deduped,
/// at most [limit] probes.
///
/// Two passes, not one: the design's literal formula is `<dir>/<rel>`, which
/// the first pass covers. But the excerpt scenario that motivates the
/// feature links `adr/0008-x.md` in a message that read
/// `<ws>/docs/adr/0007-x.md` — the base is `<ws>/docs` (the directory the
/// agent was *working from*), an ancestor of the read file's own directory.
/// The PRD forbids hardcoding `docs/` (a link may be relative to any
/// ancestor), so the second pass walks up and lets the file system answer.
/// [workspacePath] itself is excluded: it is exactly the L1 join that just
/// missed. The [limit] keeps the whole L2 stage at a fixed RPC cost.
List<String> relativeLinkProbeBases(
  List<String> dirs,
  String workspacePath, {
  int limit = maxRelativeLinkContextBases,
}) {
  var root = workspacePath.replaceAll('\\', '/');
  while (root.length > 1 && root.endsWith('/')) {
    root = root.substring(0, root.length - 1);
  }
  // Only workspace subtrees are worth probing: a row pointing outside the
  // workspace (another drive, an absolute tool path) has no bearing on a
  // link resolved against it.
  bool insideRoot(String? path) {
    if (path == null || path.isEmpty) return false;
    if (root.isEmpty) return true;
    return path.toLowerCase().startsWith('${root.toLowerCase()}/');
  }

  final out = <String>[];
  final seen = <String>{};
  bool add(String path) {
    if (!insideRoot(path) || path.toLowerCase() == root.toLowerCase()) {
      return false;
    }
    if (seen.add(path.toLowerCase())) out.add(path);
    return out.length >= limit;
  }

  // Pass 1 — the directories themselves, newest row first.
  for (final dir in dirs) {
    if (add(dir.replaceAll('\\', '/'))) return out;
  }
  // Pass 2 — one ancestor level at a time across all directories, so a
  // shallow match on any recent row is probed before a deeper one.
  var level = <String>[
    for (final dir in dirs)
      if (directoryOf(dir.replaceAll('\\', '/')) case final parent?) parent,
  ];
  while (level.isNotEmpty) {
    final next = <String>[];
    for (final parent in level) {
      if (add(parent)) return out;
      if (directoryOf(parent) case final grandparent?) next.add(grandparent);
    }
    level = next;
  }
  return out;
}

/// The last path segment of [path] (`/` or `\` separated), '' for an empty
/// or separator-terminated path.
String baseNameOf(String path) {
  final p = path.replaceAll('\\', '/');
  final slash = p.lastIndexOf('/');
  return slash < 0 ? p : p.substring(slash + 1);
}

/// The path to show under the preview's title: workspace-relative when
/// [path] sits inside [workspacePath], the absolute path otherwise (outside
/// the workspace the absolute form is the honest one). Null when there is
/// nothing to add beyond the basename.
String? relativeLinkDisplay(String? workspacePath, String path) {
  final abs = path.replaceAll('\\', '/');
  final base = baseNameOf(abs);
  if (workspacePath == null || workspacePath.isEmpty) {
    return abs == base ? null : abs;
  }
  var ws = workspacePath.replaceAll('\\', '/');
  while (ws.length > 1 && ws.endsWith('/')) {
    ws = ws.substring(0, ws.length - 1);
  }
  final display = abs == ws
      ? ''
      : abs.startsWith('$ws/')
          ? abs.substring(ws.length + 1)
          : abs;
  return (display.isEmpty || display == base) ? null : display;
}

/// File-shaped tool names whose `filePath` points at a FILE. Matching is
/// contains-based because tool names drift between desktop versions
/// (`Read`, `read_file`, `MultiEdit`, `NotebookEdit`, …) — the only
/// contract needed here is "this row names a file it touched".
bool _isFileTool(String raw) {
  final t = raw.toLowerCase();
  return t.contains('read') ||
      t.contains('write') ||
      t.contains('edit') ||
      t.contains('notebook') ||
      t.contains('file');
}

/// The row's file path: the decoded `input` map first (same key order as
/// [toolFilePath]), then the streaming `inputText` JSON.
String? _rowFilePath(Map<String, dynamic> row) {
  final input = row['input'];
  if (input is Map) {
    for (final key in toolFilePathKeys) {
      final value = input[key];
      if (value is String && value.isNotEmpty) return value;
    }
  }
  final text = row['inputText'];
  return text is String && text.isNotEmpty ? toolFilePath(text) : null;
}

/// Mutable counters of one L3 search: readdir calls, scanned entries and the
/// deepest level listed. [exhausted] flips the moment a count cap is
/// reached; the search loop then stops without waiting for anything. The
/// depth cap is enforced at enqueue time (nothing is ever queued past
/// [maxDepth]), so it converges by construction rather than by aborting.
class SearchBudget {
  SearchBudget({
    this.maxReaddirCalls = searchMaxReaddirCalls,
    this.maxEntries = searchMaxEntries,
    this.maxDepth = searchMaxDepth,
  });

  final int maxReaddirCalls;
  final int maxEntries;
  final int maxDepth;

  int readdirCalls = 0;
  int entries = 0;

  /// Deepest directory level listed so far (root = 0).
  int depth = 0;

  /// True once a count cap is reached — the search converges immediately.
  bool get exhausted =>
      readdirCalls >= maxReaddirCalls || entries >= maxEntries;
}

/// Lists one directory; a thrown error is treated as an empty listing by the
/// search (one unreadable directory must not abort the whole walk).
typedef ReaddirCallback = Future<List<DirEntry>> Function(String dir);

/// L3: breadth-first basename search under [rootPath], transport-injected.
///
/// BFS from the workspace root; every listing and every entry counts against
/// [budget], and a count cap ends the walk at once. Subdirectories named in
/// [skippedDirs] are listed but never entered (their entry still counts),
/// and nothing deeper than [SearchBudget.maxDepth] is enqueued. Matching is
/// case-insensitive on the basename (Windows file-system semantics); only
/// files (not directories) match.
///
/// Returns hits as paths RELATIVE to [rootPath] with `/` separators, in BFS
/// order — the caller joins them back onto the workspace.
class WorkspaceBasenameSearch {
  WorkspaceBasenameSearch({
    required this.readdir,
    SearchBudget? budget,
    this.skippedDirs = skippedSearchDirs,
  }) : budget = budget ?? SearchBudget();

  final ReaddirCallback readdir;
  final SearchBudget budget;
  final Set<String> skippedDirs;

  Future<List<String>> find(String rootPath, String fileName) async {
    final root = _trimTrailingSlash(rootPath.replaceAll('\\', '/'));
    final target = fileName.toLowerCase();
    if (root.isEmpty || target.isEmpty) return const [];
    final hits = <String>[];
    final queue = <(String, int)>[(root, 0)]; // (directory, depth)
    while (queue.isNotEmpty && !budget.exhausted) {
      final (dir, depth) = queue.removeAt(0);
      if (depth > budget.depth) budget.depth = depth;
      budget.readdirCalls++;
      List<DirEntry> entries;
      try {
        entries = await readdir(dir);
      } catch (_) {
        continue;
      }
      for (final entry in entries) {
        budget.entries++;
        final child = '$dir/${entry.name}';
        if (entry.isDir) {
          if (depth + 1 <= budget.maxDepth &&
              !skippedDirs.contains(entry.name.toLowerCase())) {
            queue.add((child, depth + 1));
          }
        } else if (entry.name.toLowerCase() == target) {
          hits.add(child.substring(root.length + 1));
        }
        if (budget.exhausted) break;
      }
    }
    return hits;
  }

  static String _trimTrailingSlash(String path) {
    var p = path;
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }
}
