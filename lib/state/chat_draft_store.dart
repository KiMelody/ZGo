import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persisted composer drafts of one device (design 10-20): the chat page's
/// input text plus its pending attachments, so an exit or an OS kill does
/// not lose what the user typed. Text and attachment METADATA live in
/// [SharedPreferences] (single per-device key); attachment BYTES live as
/// files under a hub-injected root (`<appSupport>/chat_drafts` in
/// production, resolved outside this layer so `lib/state` stays free of
/// platform plugins — the resolver is injectable and its failure degrades
/// to text-only drafts).
///
/// State model follows [TaskHomeStore]: in-memory map as the source of
/// truth, mutations persist fire-and-forget, every failure swallowed
/// (storage missing, corrupt JSON, unwritable disk) — a failed store never
/// blocks chat, it just stops persisting. Disk files are written BEFORE
/// their metadata entry, so a crash can only orphan files (swept on the
/// next [load]), never produce metadata pointing at missing files; the
/// restore side drops unreadable attachments regardless.
///
/// Bounded storage: at most [maxEntries] entries (oldest-touched pruned
/// first), single texts over [maxTextBytes] are not persisted at all, and
/// attachment bytes are capped at [maxAttachmentBytes] store-wide (a
/// single over-cap entry survives — there is nothing left to drop).
class ChatDraftStore {
  ChatDraftStore({required this.deviceId, this.attachmentRoot});

  final String deviceId;

  /// Resolves the root directory holding `<deviceId>/<entryKey>/` file
  /// trees. Null (or a throwing resolver) disables attachment persistence.
  final Future<Directory?> Function()? attachmentRoot;

  /// Entry cap: past this many drafts the oldest-touched entry is pruned
  /// on write so storage stays bounded (no TTL — silently expiring user
  /// typing is worse than the space).
  static const maxEntries = 20;

  /// A text over this size is skipped entirely (never truncated): pasting
  /// a huge blob into the composer is not draft-worthy state.
  static const maxTextBytes = 32 * 1024;

  /// Store-wide attachment byte budget; exceeded entries are pruned
  /// oldest-first (their file trees go with them).
  static const maxAttachmentBytes = 64 * 1024 * 1024;

  String get _prefsKey => 'chat.drafts.$deviceId';

  /// entryKey → draft. entryKey is the chat sessionId, or a
  /// `draft.<workspaceId>` placeholder on not-yet-created sessions.
  final Map<String, _DraftEntry> _entries = {};

  Directory? _root;
  Future<void>? _loading;

  /// Single-flight [load] awaited by every public op (pages call ops
  /// immediately after construction; the DeviceSession fire-and-forget
  /// [load] merely warms it).
  Future<void> _ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    try {
      _root = await attachmentRoot?.call();
    } catch (e) {
      _root = null; // resolver failure degrades to text-only drafts
      debugPrint('[chat-drafts] root resolve failed: $e');
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((key, value) {
            if (key is! String ||
                value is! Map ||
                value['t'] is! String) {
              return;
            }
            final files = <_DraftFile>[];
            final rawFiles = value['f'];
            if (rawFiles is List) {
              for (final f in rawFiles) {
                if (f is Map &&
                    f['f'] is String &&
                    f['n'] is String &&
                    f['m'] is String) {
                  files.add((
                    file: f['f'] as String,
                    name: f['n'] as String,
                    mime: f['m'] as String,
                    size: (f['s'] as num?)?.toInt() ?? 0,
                  ));
                }
              }
            }
            // putIfAbsent: in-memory entries are never older than disk
            // (same merge discipline as TaskHomeStore).
            _entries.putIfAbsent(
              key,
              () => (
                text: value['t'] as String,
                at: (value['at'] as num?)?.toInt() ?? 0,
                files: files,
              ),
            );
          });
        }
      }
    } catch (e) {
      debugPrint('[chat-drafts] load failed: $e');
    }
    await _sweepOrphans();
  }

  /// Warms the store (prefs + orphan sweep). Fire-and-forget from the
  /// session constructor; public ops await it themselves.
  Future<void> load() => _ensureLoaded();

  /// Upserts the draft text (debounced caller-side). An empty text with no
  /// attachments left removes the entry — this is what makes every
  /// `_inputController.clear()` after a successful send converge here
  /// without per-site hooks.
  Future<void> saveText(String entryKey, String text, int attachmentCount) async {
    await _ensureLoaded();
    if (text.isEmpty && attachmentCount == 0) {
      await remove(entryKey);
      return;
    }
    if (utf8.encode(text).length > maxTextBytes) return;
    final existing = _entries[entryKey];
    _entries[entryKey] = (
      text: text,
      at: clock.now().millisecondsSinceEpoch,
      files: existing?.files ?? const [],
    );
    await _prune(protect: entryKey);
    _persist();
  }

  /// Writes one attachment's bytes to disk and appends its metadata at
  /// [index] (the caller's pending-list position). File first, metadata
  /// second: a mid-write crash orphans a file (swept later) instead of
  /// breaking restore. A failed disk write leaves the entry untouched.
  Future<void> putAttachment(
    String entryKey,
    int index, {
    required String name,
    required String mime,
    required Uint8List bytes,
  }) async {
    await _ensureLoaded();
    final deviceRoot = _deviceRoot;
    if (deviceRoot == null) return;
    try {
      final entryDir = _sub(deviceRoot, _safeDirName(entryKey));
      await entryDir.create(recursive: true);
      final diskName = _diskFileName(index, name);
      await _fileIn(entryDir, diskName).writeAsBytes(bytes, flush: true);
      final existing = _entries[entryKey];
      final files = [...existing?.files ?? const <_DraftFile>[]];
      final slot = (
        file: diskName,
        name: name,
        mime: mime,
        size: bytes.lengthInBytes,
      );
      if (index == files.length) {
        files.add(slot);
      } else if (index >= 0 && index < files.length) {
        files[index] = slot;
      } else {
        return; // gap — caller contract broken, drop silently
      }
      _entries[entryKey] = (
        text: existing?.text ?? '',
        at: clock.now().millisecondsSinceEpoch,
        files: files,
      );
      await _prune(protect: entryKey);
      _persist();
    } catch (e) {
      debugPrint('[chat-drafts] attachment write failed: $e');
    }
  }

  /// Removes the attachment at [index] (the caller's pending-list
  /// position): deletes the disk file and shifts the metadata. An entry
  /// left with neither text nor attachments dies entirely.
  Future<void> removeAttachmentAt(String entryKey, int index) async {
    await _ensureLoaded();
    final deviceRoot = _deviceRoot;
    if (deviceRoot == null) return;
    try {
      final entry = _entries[entryKey];
      if (entry == null || index < 0 || index >= entry.files.length) return;
      await _fileIn(
        _sub(deviceRoot, _safeDirName(entryKey)),
        entry.files[index].file,
      ).delete();
      final files = [...entry.files]..removeAt(index);
      if (entry.text.isEmpty && files.isEmpty) {
        await remove(entryKey);
        return;
      }
      _entries[entryKey] = (text: entry.text, at: entry.at, files: files);
      _persist();
    } catch (e) {
      debugPrint('[chat-drafts] attachment remove failed: $e');
    }
  }

  /// Kills the entry: metadata out, file tree out.
  Future<void> remove(String entryKey) async {
    await _ensureLoaded();
    final existed = _entries.remove(entryKey);
    try {
      final deviceRoot = _deviceRoot;
      if (deviceRoot != null) {
        final dir = _sub(deviceRoot, _safeDirName(entryKey));
        if (await dir.exists()) await dir.delete(recursive: true);
      }
    } catch (e) {
      debugPrint('[chat-drafts] entry dir delete failed: $e');
    }
    if (existed != null) _persist();
  }

  /// One-shot page-init restore. Missing/corrupt attachment files drop
  /// silently (text still restores); an entry with nothing restorable
  /// self-heals away.
  Future<ChatDraftSnapshot?> restore(String entryKey) async {
    await _ensureLoaded();
    final entry = _entries[entryKey];
    if (entry == null) return null;
    final read = <({String file, String name, String mime, Uint8List bytes})>[];
    final deviceRoot = _deviceRoot;
    if (deviceRoot != null) {
      final entryDir = _sub(deviceRoot, _safeDirName(entryKey));
      for (final f in entry.files) {
        try {
          read.add((
            file: f.file,
            name: f.name,
            mime: f.mime,
            bytes: await _fileIn(entryDir, f.file).readAsBytes(),
          ));
        } catch (e) {
          debugPrint('[chat-drafts] attachment read failed (${f.name}): $e');
        }
      }
    }
    if (entry.text.isEmpty && read.isEmpty) {
      await remove(entryKey);
      return null;
    }
    // Metadata must track what was actually readable: dropped files stay
    // dropped, or the caller's list positions drift from the metadata
    // slots that putAttachment/removeAttachmentAt index by.
    if (deviceRoot != null && read.length != entry.files.length) {
      _entries[entryKey] = (
        text: entry.text,
        at: entry.at,
        files: [
          for (final f in read)
            (
              file: f.file,
              name: f.name,
              mime: f.mime,
              size: f.bytes.lengthInBytes,
            ),
        ],
      );
      _persist();
    }
    return ChatDraftSnapshot(
      entry.text,
      [for (final f in read) (name: f.name, mime: f.mime, bytes: f.bytes)],
    );
  }

  /// Drops file trees with no metadata entry (crash-between-write
  /// leftovers, pruned-entry remnants).
  Future<void> _sweepOrphans() async {
    final deviceRoot = _deviceRoot;
    if (deviceRoot == null) return;
    try {
      if (!await deviceRoot.exists()) return;
      final keep = _entries.keys.map(_safeDirName).toSet();
      await for (final entity in deviceRoot.list()) {
        final name = entity.path.split(Platform.pathSeparator).last;
        if (!keep.contains(name)) {
          await entity.delete(recursive: true);
        }
      }
    } catch (e) {
      debugPrint('[chat-drafts] orphan sweep failed: $e');
    }
  }

  /// Enforces [maxEntries] and [maxAttachmentBytes], oldest-touched first,
  /// never dropping the entry being written ([protect]).
  Future<void> _prune({String? protect}) async {
    while (_entries.length > maxEntries) {
      final victim = _oldestKey(protect, requireFiles: false);
      if (victim == null) break;
      await remove(victim);
    }
    var total = _totalAttachmentBytes();
    while (total > maxAttachmentBytes) {
      final victim = _oldestKey(protect, requireFiles: true);
      if (victim == null) break;
      total -= _entries[victim]!.files.fold<int>(0, (a, f) => a + f.size);
      await remove(victim);
    }
  }

  String? _oldestKey(String? protect, {required bool requireFiles}) {
    String? oldest;
    int? oldestAt;
    for (final e in _entries.entries) {
      if (e.key == protect) continue;
      if (requireFiles && e.value.files.isEmpty) continue;
      if (oldestAt == null || e.value.at < oldestAt) {
        oldest = e.key;
        oldestAt = e.value.at;
      }
    }
    return oldest;
  }

  int _totalAttachmentBytes() => _entries.values.fold(
    0,
    (a, e) => a + e.files.fold<int>(0, (b, f) => b + f.size),
  );

  void _persist() {
    unawaited(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_prefsKey, jsonEncode({
          for (final e in _entries.entries)
            e.key: {
              't': e.value.text,
              'at': e.value.at,
              'f': [
                for (final f in e.value.files)
                  {'f': f.file, 'n': f.name, 'm': f.mime, 's': f.size},
              ],
            },
        }));
      } catch (e) {
        debugPrint('[chat-drafts] persist failed: $e');
      }
    }());
  }

  Directory? get _deviceRoot =>
      _root == null ? null : _sub(_root!, deviceId);

  static Directory _sub(Directory parent, String name) =>
      Directory('${parent.path}${Platform.pathSeparator}$name');

  static File _fileIn(Directory parent, String name) =>
      File('${parent.path}${Platform.pathSeparator}$name');

  /// Disk names never trust user input: slot index plus a whitelisted
  /// extension; the original name lives in metadata only.
  static String _diskFileName(int index, String originalName) {
    var ext = originalName.contains('.')
        ? originalName.split('.').last
        : '';
    ext = ext.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    if (ext.length > 10) ext = ext.substring(0, 10);
    return ext.isEmpty ? '$index.bin' : '$index.$ext';
  }

  static String _safeDirName(String entryKey) {
    final safe = entryKey.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return safe.isEmpty ? '_' : safe;
  }
}

/// What [ChatDraftStore.restore] hands the page: the saved text plus the
/// attachments that were readable on disk.
class ChatDraftSnapshot {
  const ChatDraftSnapshot(this.text, this.files);

  final String text;
  final List<({String name, String mime, Uint8List bytes})> files;
}

typedef _DraftFile = ({String file, String name, String mime, int size});

typedef _DraftEntry = ({String text, int at, List<_DraftFile> files});
