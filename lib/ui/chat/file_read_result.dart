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
