import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Per-device task-phase baseline persisted to disk: the in-memory one dies
/// with the process, so a task that was running when the app was killed would
/// otherwise re-baseline silently on the next launch and never notify.
///
/// Notifications are an enhancement, so every failure path is swallowed — a
/// missing, corrupt or stale snapshot just means the hub cold-starts with the
/// silent baseline it has always used.
class PhaseSnapshotStore {
  /// Snapshots older than this are treated as absent (and swept): a completion
  /// from a previous day must not pop a notice on a later launch. Snapshots
  /// are overwritten whenever a phase changes, so this constant also bounds
  /// how many keys ever pile up.
  static const ttl = Duration(hours: 12);

  static const _prefix = 'notify.taskPhases.';

  const PhaseSnapshotStore();

  /// The saved phases of [deviceId], or null when absent, corrupt or older
  /// than [ttl].
  Future<Map<String, String>?> restore(String deviceId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = _decode(prefs.getString('$_prefix$deviceId'));
      if (saved == null || _expired(saved.ts)) return null;
      return saved.phases;
    } catch (_) {
      return null;
    }
  }

  /// Overwrites the snapshot of [deviceId] with [phases], stamped now.
  Future<void> save(String deviceId, Map<String, String> phases) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        '$_prefix$deviceId',
        jsonEncode({
          'ts': DateTime.now().millisecondsSinceEpoch,
          'phases': phases,
        }),
      );
    } catch (_) {
      // Storage unavailable — the in-memory baseline still works.
    }
  }

  /// Drops every snapshot past [ttl] (called once at startup). This is what
  /// keeps deleted/forgotten devices from accumulating keys forever.
  Future<void> sweep() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys().toList()) {
        if (!key.startsWith(_prefix)) continue;
        final saved = _decode(prefs.getString(key));
        if (saved == null || _expired(saved.ts)) await prefs.remove(key);
      }
    } catch (_) {
      // A lingering key is harmless on its own.
    }
  }

  static bool _expired(int ts) =>
      DateTime.now().millisecondsSinceEpoch - ts > ttl.inMilliseconds;

  /// Decodes a stored payload; null for missing/corrupt/foreign shapes.
  static ({int ts, Map<String, String> phases})? _decode(String? raw) {
    if (raw == null) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    final ts = decoded['ts'];
    final phases = decoded['phases'];
    if (ts is! int || phases is! Map) return null;
    return (
      ts: ts,
      phases: {
        for (final entry in phases.entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: entry.value as String,
      },
    );
  }
}
