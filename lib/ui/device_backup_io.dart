import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:share_plus/share_plus.dart';

/// Platform-channel seam for backup file delivery. The page takes these as
/// optional constructor injections so widget tests never touch a plugin.
typedef SaveBackupFile = Future<bool> Function(
    String fileName, List<int> bytes);
typedef ShareBackupFile = Future<void> Function(
    String fileName, List<int> bytes);
typedef ReadBackupFile = Future<String?> Function();

/// Whether the file picker / share sheet are usable on this platform.
///
/// Decided through [defaultTargetPlatform]: only android/iOS take the file
/// channel. Everything else (including the ohos fork's extra
/// `TargetPlatform.ohos`, or a value newer SDKs may add) falls through to
/// the clipboard path — neither plugin registers anything there.
bool get deviceBackupFileChannelAvailable =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// System "save as" for the encrypted envelope. Returns false when the user
/// cancels (the picker returns no path).
Future<bool> defaultSaveBackupFile(String fileName, List<int> bytes) async {
  final path = await FilePicker.saveFile(
    fileName: fileName,
    type: FileType.any,
    bytes: Uint8List.fromList(bytes),
  );
  return path != null;
}

/// Writes the ciphertext to a private temp file, hands it to the system
/// share sheet, then best-effort removes the temp directory. A receiving
/// app may still be reading the file asynchronously — deletion failure is
/// ignored and leaves only an encrypted artifact in the cache dir.
Future<void> defaultShareBackupFile(String fileName, List<int> bytes) async {
  final dir = Directory.systemTemp.createTempSync('zgo_backup_');
  try {
    final file = File('${dir.path}${Platform.pathSeparator}$fileName');
    await file.writeAsBytes(bytes, flush: true);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path)],
        title: fileName,
        // iPadOS rejects a share sheet with an empty anchor; a 1x1 rect is
        // enough for the plugin's non-empty check.
        sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1),
      ),
    );
  } finally {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // Best-effort cleanup only.
    }
  }
}

/// File-picker import source. Returns null when the user cancels; a thrown
/// error (plugin failure, unreadable bytes) is a real failure the dialog
/// reports, never silently treated as a cancel.
Future<String?> defaultReadBackupFile() async {
  final result = await FilePicker.pickFiles(
    withData: true,
    type: FileType.any,
  );
  if (result == null || result.files.isEmpty) return null;
  final bytes = result.files.first.bytes;
  if (bytes == null) {
    throw StateError('picked file carries no bytes');
  }
  return utf8.decode(bytes);
}
