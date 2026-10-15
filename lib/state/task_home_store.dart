import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persisted task-home anchors + local delete tombstones of one device
/// (design 10-15 §1.1/§1.2). The 10-02 sticky-home cache
/// (`_confirmedHomeKeys`) was pure memory: a cold restart dropped every
/// confirmed home and multi-copy rows fell back to the relay pick; the
/// local delete tombstones shared the same fate, letting a surviving
/// mirror copy resurrect a deleted task across restarts. Both now live in
/// [SharedPreferences] (the [DeviceStore] carrier) under per-device keys.
///
/// State model: the maps are an in-memory cache loaded from disk and kept
/// in sync on every mutation (mutate memory synchronously, persist
/// fire-and-forget — the DeviceStore「先内存再落盘」shape, minus the
/// notify: readers re-read per rebuild anyway). [load] MERGES disk state
/// in instead of overwriting: a write racing the load (the session
/// constructor confirms live homes before the async read settles) is the
/// newer fact and must survive.
///
/// Failure degrade: load/save failures are swallowed (platform without
/// storage, corrupt JSON) — anchors are an optimization over the cold
/// pick and tombstones degrade to the pre-persistence memory set, the
/// same philosophy as the deleted-task probe (spec task-registry-semantics
/// §3.3). Never a correctness gate.
class TaskHomeStore {
  TaskHomeStore({required this.deviceId});

  final String deviceId;

  /// Anchor cap (design §1.1): past this many entries the oldest
  /// last-confirmed anchors are pruned on write so storage stays bounded.
  static const maxEntries = 2000;

  /// Consecutive absence from relay∪live after which an anchor is pruned
  /// (design §1.1) — driven by [DeviceSession.reconcileTaskHomes].
  static const absenceTtl = Duration(days: 7);

  /// Tombstone TTL (check P1-1, 2026-10-15): the ONLY removal path of a
  /// local delete. A re-listing overview never lifts a tombstone —
  /// surviving mirror copies and stale cache frames legitimately re-list
  /// deleted ids (the live index keeps serving soft-deleted rows), so the
  /// old「复现移除」evidence was too weak and stripped tombstones within
  /// one reconcile, resurrecting them. Entries expire after [tombstoneTtl]
  /// instead and are pruned on load / reconcile.
  static const tombstoneTtl = Duration(days: 7);

  String get _anchorsKey => 'task.homeAnchors.$deviceId';
  String get _tombstonesKey => 'task.locallyDeletedTaskIds.$deviceId';

  /// taskId → (workspaceKey, lastConfirmedAt epoch ms). The timestamp
  /// drives both the cap prune (oldest confirmed goes first) and the
  /// absence prune ([absenceTtl]).
  final Map<String, ({String key, int confirmedAt})> _anchors = {};

  /// taskId → deletedAt epoch ms (check P1-1: add-only; TTL expiry is the
  /// only removal).
  final Map<String, int> _tombstones = {};
  bool _loaded = false;

  /// True once a [load] attempt settled (success or degrade) — the flag
  /// tests poll on for the restored state.
  bool get loaded => _loaded;

  /// Whether any anchor or tombstone is held (post-load: whether the disk
  /// actually had state worth a re-merge notify).
  bool get hasPersistedState => _anchors.isNotEmpty || _tombstones.isNotEmpty;

  /// The anchor view TaskDirectory reads: taskId → workspace key.
  Map<String, String> get homeKeys =>
      {for (final e in _anchors.entries) e.key: e.value.key};

  /// Live view of the local delete tombstones: the UNEXPIRED ids as a Set
  /// (TaskDirectory consumes this per read; filtering here means an expired
  /// entry can never hide a row, even before the next prune removes it
  /// from storage).
  Set<String> get locallyDeletedTaskIds {
    final cutoff = clock.now().millisecondsSinceEpoch -
        tombstoneTtl.inMilliseconds;
    return {
      for (final e in _tombstones.entries)
        if (e.value > cutoff) e.key,
    };
  }

  /// Loads both maps, merging disk state into memory ([putIfAbsent] /
  /// union — in-memory entries are never older than disk). Sets [loaded]
  /// whatever the outcome; failures leave the empty cold-pick state.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawAnchors = prefs.getString(_anchorsKey);
      if (rawAnchors != null && rawAnchors.isNotEmpty) {
        try {
          final decoded = jsonDecode(rawAnchors);
          if (decoded is Map) {
            decoded.forEach((id, value) {
              if (value is Map && value['key'] is String) {
                _anchors.putIfAbsent(
                  '$id',
                  () => (
                    key: value['key'] as String,
                    confirmedAt: (value['at'] as num?)?.toInt() ?? 0,
                  ),
                );
              }
            });
          }
        } catch (_) {
          // Corrupt anchor JSON degrades to whatever memory holds.
        }
      }
      final rawDeleted = prefs.getString(_tombstonesKey);
      if (rawDeleted != null && rawDeleted.isNotEmpty) {
        try {
          final decoded = jsonDecode(rawDeleted);
          if (decoded is Map) {
            // Current format: { taskId: deletedAtMillis }.
            decoded.forEach((id, at) {
              if (at is num) _tombstones.putIfAbsent('$id', () => at.toInt());
            });
          } else if (decoded is List) {
            // Pre-TTL format ([taskId, ...], check P1-1 migration): adopt
            // each id at the CURRENT timestamp — the delete was confirmed
            // at some unknown earlier point, so the migration starts its
            // TTL clock now and it expires after one full window.
            final adoptedAt = clock.now().millisecondsSinceEpoch;
            for (final id in decoded) {
              if ('$id'.isNotEmpty) {
                _tombstones.putIfAbsent('$id', () => adoptedAt);
              }
            }
          }
        } catch (_) {
          // Corrupt tombstone JSON degrades to whatever memory holds.
        }
      }
      // Load-time TTL prune (check P1-1): an expired tombstone never gets
      // a second life from disk.
      pruneExpiredTombstones();
    } catch (_) {
      // Platform without storage (plain unit tests / rare device states):
      // stay in-memory only.
    } finally {
      _loaded = true;
    }
  }

  /// Writes (establish / overwrite) the anchor for [taskId] — write
  /// sources ①② and the reconcile self-heal of design §1.1; the
  /// anti-pollution gate lives on the callers, not here.
  void anchorHome(String taskId, String key, {DateTime? now}) {
    if (taskId.isEmpty || key.isEmpty) return;
    _anchors[taskId] = (
      key: key,
      confirmedAt: (now ?? clock.now()).millisecondsSinceEpoch,
    );
    _capAnchors();
    _scheduleAnchorSave();
  }

  /// Refreshes the last-confirmed timestamp only (write source ③ — a live
  /// confirmation agreeing with the existing anchor): keeps the anchor
  /// fresh against the absence prune without flipping anything.
  void refreshHome(String taskId, {DateTime? now}) {
    final anchor = _anchors[taskId];
    if (anchor == null) return;
    _anchors[taskId] = (
      key: anchor.key,
      confirmedAt: (now ?? clock.now()).millisecondsSinceEpoch,
    );
    _scheduleAnchorSave();
  }

  /// Last-confirmed epoch ms of [taskId]'s anchor, null when unanchored —
  /// the observability surface the prune rules (cap / absence) assert on.
  int? confirmedAtOf(String taskId) => _anchors[taskId]?.confirmedAt;

  /// Drops the anchor (id entered the persistent tombstone, or pruned).
  void dropAnchor(String taskId) {
    if (_anchors.remove(taskId) == null) return;
    _scheduleAnchorSave();
  }

  /// Absence prune (design §1.1): drops anchors whose id is in NEITHER
  /// the relay overview NOR the live index and whose last confirmation
  /// is older than [absenceTtl].
  void pruneAbsent(Set<String> presentIds, {DateTime? now}) {
    final cutoff =
        (now ?? clock.now()).millisecondsSinceEpoch - absenceTtl.inMilliseconds;
    final expired = [
      for (final e in _anchors.entries)
        if (!presentIds.contains(e.key) && e.value.confirmedAt < cutoff) e.key,
    ];
    if (expired.isEmpty) return;
    for (final id in expired) {
      _anchors.remove(id);
    }
    _scheduleAnchorSave();
  }

  /// Cap prune (design §1.1): over [maxEntries] the least recently
  /// confirmed anchors go first.
  void _capAnchors() {
    if (_anchors.length <= maxEntries) return;
    final overflow = _anchors.length - maxEntries;
    final oldest = (_anchors.keys.toList()
          ..sort((a, b) => _anchors[a]!.confirmedAt
              .compareTo(_anchors[b]!.confirmedAt)))
        .take(overflow)
        .toList();
    for (final id in oldest) {
      _anchors.remove(id);
    }
  }

  /// Records a confirmed local delete (the delete RPC returned success):
  /// tombstones the task id across restarts so a surviving mirror copy
  /// cannot resurrect it. Add-only (check P1-1) — a fresh delete refreshes
  /// the timestamp; removal happens only through [pruneExpiredTombstones].
  void addLocalDelete(String taskId, {DateTime? now}) {
    if (taskId.isEmpty) return;
    final at = (now ?? clock.now()).millisecondsSinceEpoch;
    if (_tombstones[taskId] == at) return;
    _tombstones[taskId] = at;
    _scheduleTombstoneSave();
  }

  /// Tombstone TTL prune (check P1-1): drops entries older than
  /// [tombstoneTtl] — their ONLY removal path. Runs on load and on the
  /// session's reconcile; the [locallyDeletedTaskIds] view filters expired
  /// entries even before this removes them from storage.
  void pruneExpiredTombstones({DateTime? now}) {
    final cutoff =
        (now ?? clock.now()).millisecondsSinceEpoch -
            tombstoneTtl.inMilliseconds;
    final expired = [
      for (final e in _tombstones.entries)
        if (e.value <= cutoff) e.key,
    ];
    if (expired.isEmpty) return;
    for (final id in expired) {
      _tombstones.remove(id);
    }
    _scheduleTombstoneSave();
  }

  Future<void> _saveAnchors() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _anchorsKey,
        jsonEncode({
          for (final e in _anchors.entries)
            e.key: {'key': e.value.key, 'at': e.value.confirmedAt},
        }),
      );
    } catch (_) {
      // Storage unavailable: anchors stay in-memory only.
    }
  }

  Future<void> _saveTombstones() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_tombstonesKey, jsonEncode(_tombstones));
    } catch (_) {
      // Storage unavailable: tombstones stay in-memory only.
    }
  }

  void _scheduleAnchorSave() {
    unawaited(_saveAnchors());
  }

  void _scheduleTombstoneSave() {
    unawaited(_saveTombstones());
  }
}
