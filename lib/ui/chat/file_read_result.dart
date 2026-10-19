/// Text-read outcome plumbing for the file preview surfaces (task
/// 10-18-file-preview-formats design §2): the read layer classifies WHY a
/// file produced no text — aligned with the official codeViewer error
/// family (notFound / binary / tooLarge / empty / readFailed) — so the
/// preview page renders the reason instead of a generic failure. Lives in
/// its own library so `timeline.dart` (the reader) and
/// `file_preview_page.dart` (the consumer) share it without an import
/// cycle.
library;

/// Why a text read produced no content.
enum FileReadFailure { notFound, binary, empty, tooLarge, readFailed }

/// Preview-wide per-file read cap (2 MiB): the text preview's truncation
/// ceiling and the PDF page's whole-read cutoff are the same user-facing
/// "files up to this size preview in full" line, so they share one value.
/// (The HTML assembler's own resource-fetch caps are a separate scale.)
const int previewReadCapBytes = 2 * 1024 * 1024;

/// Official `f6` classifier (research/official-pdf-integration §2 error
/// table): a missing file surfaces as ENOENT / "no such file or directory"
/// in the error text; the desktop's over-limit reads answer the "…file is
/// too large for inline preview" family. Everything else is an unclassified
/// read failure.
FileReadFailure classifyReadFailure(String message) {
  if (_missingFileRe.hasMatch(message)) return FileReadFailure.notFound;
  if (_tooLargeRe.hasMatch(message)) return FileReadFailure.tooLarge;
  return FileReadFailure.readFailed;
}

final _missingFileRe = RegExp(
  r'\bENOENT\b|no such file or directory',
  caseSensitive: false,
);

final _tooLargeRe = RegExp(r'too large', caseSensitive: false);

/// One whole-file text read: [text] non-null means success (possibly
/// truncated at the app's 2 MiB cap — see [truncated]); otherwise
/// [failure] carries the classified reason. [totalBytes] is the wire file
/// size in BYTES (null when the desktop omitted it) — the truncation
/// banner's `N`.
class FileTextResult {
  final String? text;
  final FileReadFailure? failure;
  final int? totalBytes;
  final bool truncated;

  const FileTextResult({
    this.text,
    this.failure,
    this.totalBytes,
    this.truncated = false,
  });
}
