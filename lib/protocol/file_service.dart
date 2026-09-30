import 'dart:convert';
import 'dart:typed_data';

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
}
