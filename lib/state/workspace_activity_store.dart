import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Persisted per-workspace activity keys of one device (design 11-01 §4):
/// `workspaceKey → last activity epoch ms`.
///
/// The task list derives a card's activity key from the merged directory
/// (newest `lastActivityAt` over the workspace's rows). On a cold start a
/// non-active workspace has no rows until the relay overview lands and its
/// sidecar sessions-index delivers its snapshot (~1 s per topic), so the key
/// is null and the card sinks to the bottom of the idle tier — then jumps
/// back up when the rows arrive. The persisted key keeps the card in its
/// previous idle-tier position across that gap.
///
/// The persisted value never feeds the ACTIVE tier: the 60 s activity window
/// of the card comparator only accepts live keys, so a restored key sorts
/// into the idle layer (its whole point is a stable idle order).
///
/// State model: in-memory cache loaded from disk, kept in sync on every write
/// (memory-synchronously, persist fire-and-forget — the [TaskHomeStore]
/// shape, without a ChangeNotifier: there is nothing to invalidate, the page
/// reads the map during build). [load] MERGES disk state instead of
/// overwriting: a landing racing the async load is the newer fact.
///
/// Failure degrade: load/save failures are swallowed (platform without
/// storage, corrupt JSON) — the card order falls back to the live-only
/// behavior. Never a correctness gate.
class WorkspaceActivityStore {
  WorkspaceActivityStore({required this.deviceId});

  final String deviceId;

  /// Per-device cap. A device owns few workspaces; the cap only bounds keys
  /// of workspaces deleted on the desktop (the whole map is rewritten on
  /// every save), so storage cannot grow without limit.
  static const maxEntries = 200;

  String get _storageKey => 'task.workspaceActivity.$deviceId';

  /// workspaceKey → last activity epoch ms.
  final Map<String, int> _activity = {};
  bool _loaded = false;

  /// True once a [load] attempt settled (success or degrade).
  bool get loaded => _loaded;

  /// Whether the store holds any persisted key (post-load: whether disk state
  /// actually merged in) — the session's re-sort notify reads this.
  bool get hasPersistedState => _activity.isNotEmpty;

  /// The persisted activity key of [workspaceKey], null when unknown.
  int? activityOf(String workspaceKey) => _activity[workspaceKey];

  /// Loads the disk map, merging it under the in-memory entries (a write that
  /// raced the load is the newer fact).
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((key, value) {
            if (value is num) {
              final at = value.toInt();
              final previous = _activity['$key'];
              if (previous == null || at > previous) _activity['$key'] = at;
            }
          });
        }
      }
    } catch (_) {
      // Corrupt or missing storage: stay in-memory only.
    } finally {
      _loaded = true;
    }
  }

  /// Records [activityAt] as the newest activity of [workspaceKey].
  ///
  /// Writes are monotonic per key: an older value (a stale in-flight frame)
  /// never rewinds a newer one.
  void record(String workspaceKey, int activityAt) {
    if (workspaceKey.isEmpty || activityAt <= 0) return;
    final previous = _activity[workspaceKey];
    if (previous != null && previous >= activityAt) return;
    _activity[workspaceKey] = activityAt;
    _cap();
    unawaited(_save());
  }

  /// Cap prune: the oldest activity keys go first (they are the most stale
  /// and the least likely to keep a visible card in place).
  void _cap() {
    if (_activity.length <= maxEntries) return;
    final overflow = _activity.length - maxEntries;
    final oldest = (_activity.keys.toList()
          ..sort((a, b) => _activity[a]!.compareTo(_activity[b]!)))
        .take(overflow)
        .toList();
    for (final key in oldest) {
      _activity.remove(key);
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_storageKey, jsonEncode(_activity));
    } catch (_) {
      // Storage unavailable: keys stay in-memory only.
    }
  }
}
