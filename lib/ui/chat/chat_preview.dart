/// Workspace-file preview plumbing for every host that dispatches a
/// workspace path into a preview surface: the chat timeline rows (tool
/// names, kv expanders, markdown links, changes sheet), the subagent
/// detail page, the task search page's file tab and the Git review
/// panel. Extracted verbatim from `timeline.dart` (S7 entry round,
/// design 10-18 §6): the entry blacklist and the routing table live
/// here ONCE, so no entry point can drift into its own copy.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../state/device_session.dart';
import '../theme.dart';
import '../ui_settings.dart';
import 'file_preview_page.dart';
import 'file_read_result.dart';
import 'image_viewer_page.dart';
import 'pdf_preview_page.dart';
import 'relative_link_resolver.dart';

/// Workspace-file preview plumbing shared by every file-entry host
/// (design 09-29-file-preview §4.4/§5): the markdown image resolver with a
/// session-scoped LRU (re-rendered rows must not re-fetch), the extension
/// dispatch into the preview surfaces, the markdown link split (http(s) →
/// system browser, scheme-less local path → dispatch) and the read
/// callbacks the preview page assembles with. Paths resolve against the
/// session's active workspace ([WorkspaceContextPort.workspacePath]);
/// without one the resolver returns null and [open] answers a snackbar
/// instead of dispatching (design 10-18 §3.2).
class ChatPreview {
  ChatPreview(this._workspaceContext, {this.contextRows});

  final WorkspaceContextPort _workspaceContext;

  /// Live rows of the hosting conversation (L2 context bases, design
  /// 11-09 §L2). Read at RESOLVE time, not construction: the preview opens
  /// from a link tap and the fallback must see the rows the message was
  /// rendered from. Hosts without a conversation (task search page) leave
  /// it null — the L3 basename search still runs.
  final List<Map<String, dynamic>> Function()? contextRows;

  /// Insertion-ordered LRU (re-inserted on hit); null results are cached
  /// too — a missing file stays a placeholder without hammering the
  /// desktop on every re-render.
  final Map<String, Uint8List?> _imageCache = {};
  static const _imageCacheCap = 32;

  /// In-flight fetches: simultaneously-mounted widgets for one path (a
  /// markdown answer with the same image twice) share a single RPC.
  final Map<String, Future<Uint8List?>> _pending = {};

  /// Raster extensions Flutter can decode — the fullscreen viewer's set
  /// (design 10-18 §3.2); every other non-blacklisted extension opens the
  /// preview page's source view.
  static const _imageExts = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};

  /// Entry-dispatch blacklist (design 10-18 §3.1 兜底制): formats with
  /// neither text value nor a render route. Matched on the lowercased last
  /// `.`-segment (`.tar.gz` → `gz`); extension-less names (Makefile) and
  /// dot-files (.gitignore → `gitignore`) pass — their read lands on the
  /// wire's own binary sniff, which is the honest verdict. `ico` sits here
  /// on purpose although the html assembler inlines it as a resource: the
  /// two lists answer different questions (design §3.1 注).
  static const _blacklistExts = {
    // archives
    'zip', '7z', 'rar', 'tar', 'gz', 'bz2', 'xz', 'zst', 'jar',
    // binaries
    'exe', 'dll', 'so', 'dylib', 'bin', 'o', 'a', 'class', 'pyc', 'wasm',
    'sqlite', 'db',
    // office (OLE / zip containers)
    'doc', 'docx', 'xls', 'xlsx', 'xlsm', 'ppt', 'pptx',
    // media
    'mp3', 'wav', 'ogg', 'flac', 'm4a', 'opus', 'mp4', 'mov', 'webm', 'm4v',
    'avi', 'mkv',
    // bitmaps Flutter cannot decode
    'tif', 'tiff', 'heic', 'heif', 'avif', 'ico',
    // fonts
    'woff', 'woff2', 'ttf', 'otf', 'eot',
    // disk images / installers
    'dmg', 'iso', 'img', 'ipa', 'apk', 'hap',
  };

  /// Whether [path] opens a preview surface at all — the entry points
  /// (tool-row file names, kv expanders) gate their tap affordances on
  /// this so nothing renders as a dead link: every non-blacklisted
  /// extension lights up (design §3.2) and blacklisted formats stay inert.
  /// The markdown-link path deliberately does NOT consult this (design §0
  /// L1): a clicked link is explicit intent, so a blacklisted file reached
  /// through one opens the source stub and lands on the read's verdict
  /// (binary / missing) instead of a dead tap.
  static bool dispatchable(String path) {
    return !_blacklistExts.contains(_extOf(path));
  }

  /// Fallback mimes for data URLs when the desktop ships no mediaType.
  static const _mimeByExt = {
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'bmp': 'image/bmp',
    'ico': 'image/x-icon',
    'woff': 'font/woff',
    'woff2': 'font/woff2',
    'ttf': 'font/ttf',
    'otf': 'font/otf',
    'pdf': 'application/pdf',
  };

  /// App-side text cap ([previewReadCapBytes], shared with the PDF
  /// whole-read cutoff). The desktop clamps one `readTextFile`
  /// call to 256 KiB (research/official-large-text §1, client bundle and
  /// asar alike), so this cap is only ever reached through the 256 KiB
  /// read loop in [readText] — the pre-S2 single 2 MiB request made the
  /// server cut every >256 KiB file silently at the first chunk.
  static const _maxTextBytes = previewReadCapBytes;

  /// One wire read step: the desktop server-side clamp
  /// (`clampReadLength`, 256 KiB) as the request size, so every step comes
  /// back with as much as the server is willing to hand out.
  static const _readStepBytes = 256 * 1024;

  String? get _workspace {
    final ws = _workspaceContext.workspacePath;
    return (ws == null || ws.isEmpty) ? null : ws;
  }

  static String _baseName(String path) =>
      path.split(RegExp(r'[\\/]')).last;

  /// The desktop resolves relative paths against ITS OWN process CWD, not
  /// the workspace (live-certified, spec §1.2) — scheme-less relative
  /// references from markdown must be joined onto the workspace before they
  /// reach the wire.
  static String _absolute(String ws, String path) {
    final p = path.replaceAll('\\', '/');
    if (_isAbsolutePath(p)) return p;
    final base = ws.replaceAll('\\', '/');
    return base.endsWith('/') ? '$base$p' : '$base/$p';
  }

  /// Drive-letter (`C:/…`), UNC (`//…`) or posix-root (`/…`) — the forms
  /// [_absolute] hands through untouched.
  static bool _isAbsolutePath(String path) {
    final p = path.replaceAll('\\', '/');
    return p.startsWith('/') || RegExp(r'^[A-Za-z]:/').hasMatch(p);
  }

  static String _extOf(String path) {
    final i = path.lastIndexOf('.');
    return i < 0 ? '' : path.substring(i + 1).toLowerCase();
  }

  /// Markdown image resolver (design §4.3). Null on any failure — the
  /// markdown side renders the placeholder row.
  Future<Uint8List?> resolveImage(String path) async {
    final ws = _workspace;
    if (ws == null) return null;
    final abs = _absolute(ws, path);
    if (_imageCache.containsKey(abs)) return _imageCache[abs];
    final future = _pending.putIfAbsent(abs, () => _fetchImage(ws, abs));
    try {
      return await future;
    } finally {
      _pending.remove(abs);
    }
  }

  Future<Uint8List?> _fetchImage(String ws, String path) async {
    try {
      final res = await _workspaceContext.fileService.readMedia(ws, path);
      return _remember(path, res.bytes);
    } catch (_) {
      return _remember(path, null);
    }
  }

  Uint8List? _remember(String path, Uint8List? bytes) {
    _imageCache.remove(path);
    _imageCache[path] = bytes;
    while (_imageCache.length > _imageCacheCap) {
      _imageCache.remove(_imageCache.keys.first);
    }
    return bytes;
  }

  /// Entry dispatch (design 10-18 §3.2 routing table): images → fullscreen
  /// viewer (bytes fetched through the cache); html/htm → the assembled
  /// dual-view preview; md/markdown → the render kind with the chat's own
  /// [AppMarkdown] over the highlighted source view; svg → the sandboxed
  /// svg render kind; pdf → its own [PdfPreviewPage] (the second-tier
  /// sandbox with the three read-only bridge handlers); every other
  /// non-blacklisted extension → the source-only `plainText` kind.
  /// Ungated on purpose for the markdown-link family: blacklisted files
  /// only arrive here through [openLink] and land on the read's verdict
  /// (binary / missing) as the cannot-preview state, not a dead tap.
  Future<void> open(BuildContext context, String path) async {
    final ws = _workspace;
    if (ws == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr(context, 'chat.preview.noWorkspace'))),
      );
      return;
    }
    final ext = _extOf(path);
    if (_imageExts.contains(ext)) {
      final bytes = await resolveImage(path);
      if (!context.mounted) return;
      if (bytes == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              trP(context, 'chat.img.loadFailed', [_baseName(path)]),
            ),
          ),
        );
        return;
      }
      Navigator.of(context).push(
        zRoute((_) => ImageViewerPage(bytes: bytes, fileName: path)),
      );
      return;
    }
    if (ext == 'pdf') {
      Navigator.of(context).push(
        zRoute(
          (_) => PdfPreviewPage(
            path: _absolute(ws, path),
            stat: (p) => _workspaceContext.fileService.stat(ws, p),
            readMediaDataUrl: (p) => _readMediaDataUrl(ws, p),
            readRange: (p, offset, length) async =>
                (await _workspaceContext.fileService.readFileRange(ws, p,
                        offset: offset, length: length))
                    .bytes,
          ),
        ),
      );
      return;
    }
    final render = switch (ext) {
      'html' || 'htm' => FilePreviewRender.html,
      'md' || 'markdown' => FilePreviewRender.markdown,
      'svg' => FilePreviewRender.svg,
      _ => FilePreviewRender.plainText,
    };
    Navigator.of(context).push(
      zRoute(
        (_) => FilePreviewPage(
          path: _absolute(ws, path),
          render: render,
          readText: readText,
          readMediaDataUrl: (p) => _readMediaDataUrl(ws, p),
          // Markdown render view only: the chat's own image pipeline and
          // link split (design §4.1). A local link pushes its own preview
          // over this page — the zRoute back stack unwinds the chain.
          resolveImage: resolveImage,
          openLink: (href) => openLink(context, href),
          // Link fallback for a link whose read answered notFound (design
          // 11-09): a relative link tries the L2 context bases then the L3
          // basename search; an absolute link skips L2 — its own path already
          // names the location, so only the basename search can recover a
          // path whose separator the markdown escaping ate.
          resolveLinkFallback: () => _isAbsolutePath(path)
              ? resolveAbsoluteLink(ws, path)
              : resolveRelativeLink(ws, path),
          workspacePath: ws,
        ),
      ),
    );
  }

  /// Markdown link split (design §4.4): http(s) → system browser
  /// (externalApplication), scheme-less local path → [open]; other schemes
  /// (data:, file:, mailto:…) stay inert. Windows drive paths (`C:\…`)
  /// parse as a single-letter scheme, hence the length check.
  ///
  /// Desktop-authored markdown links carry **percent-encoded** local paths
  /// (`F:%5CMoney%5Cprd.md` — `\` ships as `%5C`); the official web client
  /// never notices because the browser decodes the href. The decode runs on
  /// the local branch only, *after* the scheme split, so a `%3F`/`%23` in a
  /// file name can never re-enter [Uri.tryParse] as query/fragment.
  void openLink(BuildContext context, String href) {
    final normalized = href.replaceAll('\\', '/');
    final uri = Uri.tryParse(normalized);
    if (uri == null) return;
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (uri.scheme.isEmpty || uri.scheme.length == 1) {
      // Decode first, re-slash after: decoding `%5C` surfaces literal
      // separators again. [_absolute] downstream only understands `/`.
      open(context, decodeLocalPath(normalized).replaceAll('\\', '/'));
    }
  }

  /// Decodes a whole URL-encoded **local** path string (the desktop's
  /// markdown link form). A malformed escape (`F:100%`, `%ZZ`, a truncated
  /// UTF-8 sequence) throws inside [Uri.decodeComponent]; the raw string is
  /// returned instead — never worse than not decoding at all. Pure so the
  /// decode contract is unit-tested without a [BuildContext].
  static String decodeLocalPath(String path) {
    try {
      return Uri.decodeComponent(path);
    } on ArgumentError {
      return path;
    } on FormatException {
      return path;
    }
  }

  /// ENOENT first, then the desktop's over-limit channel, everything else
  /// unknown (design §2). The regex family lives in
  /// [classifyReadFailure] (file_read_result.dart), shared with the PDF
  /// page's own classifier.
  static FileReadFailure _classifyReadError(Object error) =>
      classifyReadFailure('$error');

  /// Reads [path] whole and classifies the outcome (design §1.3 + §2).
  ///
  /// The desktop clamps one `readTextFile` to 256 KiB, so the file is
  /// pulled in 256 KiB steps (`offset += bytesRead`) until the wire says
  /// no more (`truncated == false`), an empty answer marks EOF (a server
  /// answer past the end of the file is an empty payload, not an error),
  /// or the 2 MiB cap is reached. The assembled text keeps the last
  /// chunk's metadata ([FileTextResult.totalBytes] / [truncated]).
  ///
  /// Public as the read-layer seam the read-loop tests drive directly;
  /// production callers go through [open].
  @visibleForTesting
  Future<FileTextResult> readText(String path) async {
    final ws = _workspace;
    if (ws == null) {
      return const FileTextResult(failure: FileReadFailure.readFailed);
    }
    final abs = _absolute(ws, path);
    final buffer = StringBuffer();
    var offset = 0;
    var truncated = false;
    int? totalBytes;
    try {
      while (offset < _maxTextBytes) {
        final res = await _workspaceContext.fileService.readText(
          ws,
          abs,
          offset: offset,
          length: math.min(_readStepBytes, _maxTextBytes - offset),
        );
        totalBytes = res.totalBytes ?? totalBytes;
        if (res.isBinary == true) {
          return FileTextResult(
            failure: FileReadFailure.binary,
            totalBytes: totalBytes,
          );
        }
        buffer.write(res.text);
        // A null `bytesRead` falls back to the decoded text's own byte
        // length; both zero means EOF (see the doc comment).
        final read = res.bytesRead ?? utf8.encode(res.text).length;
        if (read <= 0) break;
        offset += read;
        truncated = res.hasMore ??
            (totalBytes != null
                ? offset < totalBytes
                : offset >= _maxTextBytes);
        if (res.hasMore == false) break;
      }
    } catch (e) {
      return FileTextResult(
        failure: _classifyReadError(e),
        totalBytes: totalBytes,
      );
    }
    if (buffer.isEmpty) {
      return FileTextResult(
        failure: FileReadFailure.empty,
        totalBytes: totalBytes,
      );
    }
    return FileTextResult(
      text: buffer.toString(),
      totalBytes: totalBytes,
      truncated: truncated,
    );
  }

  /// The L2/L3 fallback chain (design 11-09 §回退链). Called by the preview
  /// page only after the L1 workspace-root read answered
  /// [FileReadFailure.notFound] — a missing file can also be "the link was
  /// written relative to the directory the agent was reading", which no
  /// single root join can guess.
  ///
  /// * **L2** tries `<dir of a recent file-tool row>/<rel>` for at most
  ///   [maxRelativeLinkContextBases] bases (newest row first). A hit stops
  ///   the chain — nothing else runs.
  /// * **L3** runs only when L2 missed: a basename BFS over the workspace
  ///   under the [searchMaxReaddirCalls]/[searchMaxEntries]/[searchMaxDepth]
  ///   caps. Hits are typed, so the caller can offer a choice.
  ///
  /// [relativePath] is the caller's decoded local path (the straight
  /// `adr/0008-x.md` form); [workspacePath] is the root L1 already used.
  /// Probing uses [readText] itself, so every attempt pays the same read step
  /// the real open would — a hit is one RPC, and its classification is
  /// already right.
  Future<PreviewResolution> resolveRelativeLink(
    String workspacePath,
    String relativePath,
  ) async {
    if (relativePath.isEmpty) return const PreviewResolution();
    final rel = relativePath.replaceAll('\\', '/');
    final fileName = baseNameOf(rel);
    final l1Path = joinFsPath(workspacePath, rel);
    final candidates = <PreviewCandidate>[];
    final seen = <String>{l1Path.toLowerCase()};

    void addCandidate(String abs, {FileTextResult? read}) {
      if (!seen.add(abs.toLowerCase())) return;
      candidates.add(PreviewCandidate(
        path: abs,
        label: relativeLinkDisplay(workspacePath, abs) ?? baseNameOf(abs),
        read: read,
      ));
    }

    // L2 — recent file-tool directories (and their ancestors inside the
    // workspace): the agent writes `adr/0008-x.md` while reading
    // `<ws>/docs/adr/0007-x.md`, so the base can be one or more levels above
    // the read file's own directory. Nearest-first, capped, no `docs/`
    // special case (PRD 非目标).
    final rows = contextRows?.call() ?? const <Map<String, dynamic>>[];
    final probeBases = relativeLinkProbeBases(
      relativeLinkContextBases(rows),
      workspacePath,
    );
    for (final base in probeBases) {
      final abs = joinFsPath(base, rel);
      // The L1 join already paid for this exact read and missed: probing it
      // again would be a wasted RPC (and a duplicate candidate if it hit).
      if (abs.toLowerCase() == l1Path.toLowerCase()) continue;
      final result = await readText(abs);
      if (result.failure == null) {
        addCandidate(abs, read: result);
        break;
      }
    }
    if (candidates.isNotEmpty) {
      return PreviewResolution(candidates: candidates);
    }
    return _searchBasename(workspacePath, fileName, excludePath: l1Path);
  }

  /// Fallback for an ABSOLUTE link whose read answered ENOENT (task
  /// 11-09-preview-abs-basename-fallback): the markdown escaping can eat the
  /// separator after a backslash (`F:\ZLinker\.local-archive` ships as
  /// `F:/ZLinker.local-archive`), which the drive-letter shape still lets
  /// through, so the desktop answers notFound for a path that was never real.
  /// L2 is skipped on purpose — an absolute path already names its location,
  /// so a directory guessed from the tool rows is not a meaningful base;
  /// only the L3 basename search can recover the file.
  Future<PreviewResolution> resolveAbsoluteLink(
    String workspacePath,
    String absolutePath,
  ) async {
    final fileName = baseNameOf(absolutePath);
    if (fileName.isEmpty) return const PreviewResolution();
    return _searchBasename(
      workspacePath,
      fileName,
      excludePath: absolutePath,
    );
  }

  /// L3 — workspace-wide basename search, hard-budgeted
  /// ([WorkspaceBasenameSearch]'s own readdir/entry/depth caps). Hits are
  /// workspace-relative on the wire, so they are joined back onto the root.
  ///
  /// [excludePath] is the path whose read already missed (the L1 join for a
  /// relative link, the link itself for an absolute one): re-reading it would
  /// be a wasted RPC and a candidate that cannot open.
  Future<PreviewResolution> _searchBasename(
    String workspacePath,
    String fileName, {
    String? excludePath,
  }) async {
    final search = WorkspaceBasenameSearch(
      readdir: (dir) => _workspaceContext.fileService.readdir(
        workspacePath,
        dir,
      ),
    );
    final hits = await search.find(workspacePath, fileName);
    final excluded = excludePath?.replaceAll('\\', '/').toLowerCase();
    final seen = <String>{if (excluded != null) excluded};
    final candidates = <PreviewCandidate>[];
    for (final hit in hits) {
      final abs = joinFsPath(workspacePath, hit);
      if (!seen.add(abs.toLowerCase())) continue;
      candidates.add(PreviewCandidate(
        path: abs,
        label: relativeLinkDisplay(workspacePath, abs) ?? baseNameOf(abs),
      ));
    }
    return PreviewResolution(candidates: candidates, searched: true);
  }

  Future<String?> _readMediaDataUrl(String ws, String path) async {
    try {
      final abs = _absolute(ws, path);
      final res = await _workspaceContext.fileService.readMedia(ws, abs);
      final mime = res.mediaType ?? _mimeByExt[_extOf(abs)];
      return 'data:${mime ?? 'application/octet-stream'};base64,'
          '${base64Encode(res.bytes)}';
    } catch (_) {
      return null;
    }
  }
}
