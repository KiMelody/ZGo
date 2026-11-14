import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'side_chat_registry.dart';

/// Persisted side-chat tab manifest of one device, keyed by workspace key
/// (design 11-11-btw-side-chat §3, R8).
///
/// Why a local manifest: `selection_side_chat` never enters the
/// sessions-index (host whitelist `[interactive, fork, workflow_parent]`,
/// research/close-delete-wire.md Q1) and `zcode-session.listSessions` cannot
/// enumerate it — the only server side door is an existence check by known
/// id. The official web remote keeps its side-chat tabs in pure memory and
/// loses them on reload; ZGo's processes die far more often, so the ids it
/// created are persisted here. This is device-local data: clearing app data
/// loses the recovery entry point, not the sessions themselves.
///
/// State model follows [TaskHomeStore]: in-memory map loaded from disk,
/// every mutation persists fire-and-forget, all failures swallowed (platform
/// without storage, corrupt JSON) — the manifest is a convenience over the
/// live registry, never a correctness gate.
///
/// Entry semantics (R8/R9):
/// - `put` — a tab was registered (created). Upsert by sessionId.
/// - `remove` — a tab was destroyed (soft-deleted session). Gone forever.
/// - `retain` — the existence check ran and answered; entries the server did
///   not confirm as live `selection_side_chat` sessions are dropped.
/// - There is deliberately NO close operation: close only stops the runtime
///   and removes the tab from the page; the manifest entry stays so a later
///   page entry rebuilds it.
///
/// Ordinal invariant: one number per parent bucket. A closed tab's number is
/// free for reuse (desktop rule), so a fresh registration can take it while
/// the closed entry is still listed; [put] then renumbers the stale entry to
/// the smallest unused number, keeping the live tab's visible number stable
/// across restores.
class SideChatTabStore {
  SideChatTabStore({
    required this.deviceId,
    Future<SharedPreferences> Function()? prefsProvider,
  }) : _prefs = prefsProvider ?? SharedPreferences.getInstance;

  final String deviceId;
  final Future<SharedPreferences> Function() _prefs;

  String get _storageKey => 'sideChat.tabs.$deviceId';

  /// workspaceKey → parentSessionId → tabs (ordinal-ordered).
  final Map<String, Map<String, List<SideChatTab>>> _manifest = {};

  bool _loaded = false;
  Future<void>? _loading;
  Future<void>? _pendingSave;

  /// True once a [load] attempt settled (success or degrade).
  bool get loaded => _loaded;

  /// Test seam: settles the last fire-and-forget save. Production never
  /// awaits it (writes are memory-synchronous).
  @visibleForTesting
  Future<void> get pendingSave => _pendingSave ?? Future<void>.value();

  /// Loads the disk manifest, merging it into memory (entries already held
  /// are the newer fact — a write that raced the load wins).
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final prefs = await _prefs();
      final raw = prefs.getString(_storageKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((workspaceKey, parents) {
            if (parents is! Map) return;
            parents.forEach((parent, tabs) {
              if (tabs is! List) return;
              final entries = <SideChatTab>[];
              final known = <String>{};
              for (final tab in tabs) {
                if (tab is! Map) continue;
                final id = tab['sessionId'];
                final ordinal = tab['ordinal'];
                if (id is! String || id.isEmpty || ordinal is! num) continue;
                if (!known.add(id)) continue;
                entries.add(
                  SideChatTab(sessionId: id, ordinal: ordinal.toInt()),
                );
              }
              if (entries.isEmpty) return;
              entries.sort((a, b) => a.ordinal.compareTo(b.ordinal));
              // Merge, never overwrite: an in-memory entry is a write that
              // raced this load and is the newer fact.
              final bucket = _bucket('$workspaceKey', '$parent');
              final held = {for (final tab in bucket) tab.sessionId};
              bucket.addAll([
                for (final tab in entries)
                  if (!held.contains(tab.sessionId)) tab,
              ]);
            });
          });
        }
      }
    } catch (_) {
      // Corrupt or missing storage: stay in-memory only.
    } finally {
      _loaded = true;
    }
  }

  /// The manifest entries of [parent] under [workspaceKey], ordinal-ordered.
  /// Answers a sorted copy so callers can replay it verbatim.
  List<SideChatTab> entriesOf(String workspaceKey, String parent) {
    final bucket = _manifest[workspaceKey]?[parent];
    if (bucket == null || bucket.isEmpty) return const <SideChatTab>[];
    return List.unmodifiable(
      [...bucket]..sort((a, b) => a.ordinal.compareTo(b.ordinal)),
    );
  }

  /// Upserts [tab] (registration path) and persists.
  void put(String workspaceKey, String parent, SideChatTab tab) {
    if (workspaceKey.isEmpty || parent.isEmpty || tab.sessionId.isEmpty) {
      return;
    }
    final bucket = _bucket(workspaceKey, parent);
    final index =
        bucket.indexWhere((entry) => entry.sessionId == tab.sessionId);
    if (index >= 0) {
      bucket[index] = tab;
    } else {
      bucket.add(tab);
    }
    _resequence(bucket, preferredId: tab.sessionId);
    _save();
  }

  /// Drops the entry of [sessionId] (destroy path) and persists.
  void remove(String workspaceKey, String parent, String sessionId) {
    final parents = _manifest[workspaceKey];
    final bucket = parents?[parent];
    if (parents == null || bucket == null) return;
    final before = bucket.length;
    bucket.removeWhere((tab) => tab.sessionId == sessionId);
    if (bucket.length == before) return;
    _pruneEmpty(workspaceKey, parent, parents, bucket);
    _save();
  }

  /// Keeps only the entries whose id is in [sessionIds] (existence-check
  /// prune) and persists when anything was dropped.
  void retain(String workspaceKey, String parent, Set<String> sessionIds) {
    final parents = _manifest[workspaceKey];
    final bucket = parents?[parent];
    if (parents == null || bucket == null) return;
    final before = bucket.length;
    bucket.removeWhere((tab) => !sessionIds.contains(tab.sessionId));
    if (bucket.length == before) return;
    _pruneEmpty(workspaceKey, parent, parents, bucket);
    _save();
  }

  void _pruneEmpty(
    String workspaceKey,
    String parent,
    Map<String, List<SideChatTab>> parents,
    List<SideChatTab> bucket,
  ) {
    if (bucket.isEmpty) parents.remove(parent);
    if (parents.isEmpty) _manifest.remove(workspaceKey);
  }

  List<SideChatTab> _bucket(String workspaceKey, String parent) => _manifest
      .putIfAbsent(workspaceKey, () => <String, List<SideChatTab>>{})
      .putIfAbsent(parent, () => <SideChatTab>[]);

  /// Enforces the one-number-per-bucket invariant. [preferredId] (the tab
  /// just registered) keeps its ordinal — a live tab must not renumber under
  /// the user. Every other entry keeps its persisted ordinal on a
  /// first-come basis; an invalid or already-claimed number falls back to the
  /// smallest unused one. Ordering follows the final ordinals so a restore
  /// replays the same sequence.
  void _resequence(List<SideChatTab> bucket, {required String preferredId}) {
    if (bucket.length < 2) return;
    final claimed = <int>{};
    final keep = <int>{};
    for (var i = 0; i < bucket.length; i++) {
      if (bucket[i].sessionId != preferredId) continue;
      claimed.add(bucket[i].ordinal);
      keep.add(i);
      break;
    }
    for (var i = 0; i < bucket.length; i++) {
      if (keep.contains(i)) continue;
      final ordinal = bucket[i].ordinal;
      if (ordinal >= 1 && claimed.add(ordinal)) keep.add(i);
    }
    for (var i = 0; i < bucket.length; i++) {
      if (keep.contains(i)) continue;
      var ordinal = 1;
      while (claimed.contains(ordinal)) {
        ordinal++;
      }
      claimed.add(ordinal);
      bucket[i] = SideChatTab(sessionId: bucket[i].sessionId, ordinal: ordinal);
    }
    bucket.sort((a, b) => a.ordinal.compareTo(b.ordinal));
  }

  void _save() {
    // Chained, not overwritten: writes must land in order (an earlier encode
    // completing last would rewind the disk state), and the first write after
    // construction waits for the load's disk merge so a write racing the load
    // cannot erase entries the loader is about to bring in.
    final prior = _pendingSave ?? _loading ?? Future<void>.value();
    _pendingSave = prior.then((_) => _saveNow());
    unawaited(_pendingSave!);
  }

  Future<void> _saveNow() async {
    try {
      final prefs = await _prefs();
      await prefs.setString(
        _storageKey,
        jsonEncode({
          for (final workspace in _manifest.entries)
            workspace.key: {
              for (final parent in workspace.value.entries)
                parent.key: [
                  for (final tab in parent.value)
                    {'sessionId': tab.sessionId, 'ordinal': tab.ordinal},
                ],
            },
        }),
      );
    } catch (_) {
      // Storage unavailable: the manifest stays in-memory only.
    }
  }
}
