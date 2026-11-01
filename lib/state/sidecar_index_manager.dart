import 'dart:async';

import '../protocol/channel_client.dart' show isAgentRuntimeNotRunningError;
import '../protocol/conversation_state.dart';
import 'task_directory.dart'
    show TaskDirectory, isConversationWorkspacePath;

/// Sidecar sessions-index subscriptions (design 10-28; extracted from
/// DeviceSession by design 10-29 §1): keeps the recently active NON-active
/// workspaces live over the SAME bridge as the active subscription and
/// diffs the set on every relay overview landing.
///
/// All six strategies live here — candidate ranking (top-N by newest relay
/// row), cooldown, in-flight dedup, the running-row slot, failure
/// classification, and eviction unsubscribe — so the policy is one readable
/// block instead of a hub section. The session contributes only the
/// capabilities (wire subscribe/dispose, quiet probe, candidate inputs,
/// notification and lifecycle) through constructor closures; the four
/// state maps and the reconciliation live in this class.
///
/// Behavior is byte-identical to the former DeviceSession block: the
/// subscribe frame (scope + `runtimePolicy:'existing-only'`), the topic
/// gate and the logicalFrameId dedup stay in the protocol layer and are
/// only *called* from here.
class SidecarIndexManager {
  SidecarIndexManager({
    required this.subscribe,
    required this.dispose,
    required this.available,
    required this.probeDeleted,
    required this.relayRows,
    required this.activeKey,
    required this.normalizeKey,
    required this.onChanged,
    required this.isDisposed,
    required this.log,
    required this.limit,
    required this.cooldown,
    required this.clock,
  });

  /// Starts ONE scoped sessions-index subscription on the active bridge.
  /// [onSubscribeFailure] is the per-key automatic-resubscribe hook the
  /// manager classifies (cold runtime vs everything else).
  final Future<SessionsIndexState> Function(
    String key,
    Map<String, dynamic> scope,
    void Function(Object error) onSubscribeFailure,
  ) subscribe;

  /// Disposes the wire subscription of [key] (the manager removes its own
  /// state listener first).
  final Future<void> Function(String key) dispose;

  /// Whether subscriptions can start right now (an open bridge + active
  /// transport must exist).
  final bool Function() available;

  /// Quiet tombstone probe (`_callChannelQuiet` + `probeListDeletedTaskIds`
  /// on the session side): a miss must never feed the link ledger.
  final Future<Set<String>?> Function(Map<String, dynamic> scope) probeDeleted;

  /// Relay overview rows — the candidate ranking input.
  final List<Map<String, dynamic>> Function() relayRows;

  /// Normalized active workspace key (null = no active workspace). The
  /// session applies its key aliases, so the manager's comparisons and the
  /// running-slot check share one spelling.
  final String? Function() activeKey;

  /// Canonicalizes a raw relay/live key through the session's key aliases.
  final String Function(String rawKey) normalizeKey;

  /// Exactly one call per state change: subscribe installed, drop, any
  /// sidecar frame, tombstone probe write. The session owns the single
  /// notify (sidecar frames and set changes each notify once).
  final void Function() onChanged;

  /// The session is disposed: no new subscribe is recorded, no notify.
  final bool Function() isDisposed;

  final void Function(String line) log;

  /// Upper bound on sidecar subscriptions (recently active non-active
  /// workspaces, newest `updatedAt` first).
  final int limit;

  /// Per-key cooldown after the benign cold-runtime refusal.
  final Duration cooldown;

  final DateTime Function() clock;

  /// Wire subscriptions by workspace key — a proxy for the session's wire
  /// handles, tracked here so the eviction checks keep the former
  /// `_sidecarSubs ∪ _sidecarIndexes` semantics.
  final Set<String> _wireKeys = {};

  /// Sidecar index states by workspace key — the live layers the task
  /// directory merges (below the ACTIVE index, above the relay rows).
  final Map<String, SessionsIndexState> _indexes = {};

  /// Keys with a subscribe in flight (dedup across overlapping reconciles).
  final Set<String> _starting = {};

  /// Per-key cooldown deadline after the benign cold-runtime refusal.
  final Map<String, DateTime> _cooldownUntil = {};

  /// Sidecar index states by key (live map, read by TaskHomeService).
  Map<String, SessionsIndexState> get indexes => _indexes;

  /// Per-workspace sidecar readiness (design 11-01 §3): `key → true` once the
  /// sidecar index delivered its snapshot. A workspace whose subscribe is
  /// still in flight (`_starting`, or recorded but not ready yet) reports
  /// false; a workspace with no sidecar subscription at all is ABSENT — its
  /// rows come from the relay overview only, so an empty card is genuine and
  /// must keep the empty-state copy instead of a loading skeleton.
  Map<String, bool> get readinessByWorkspace {
    final readiness = <String, bool>{};
    for (final key in _starting) {
      readiness[key] = false;
    }
    for (final key in _wireKeys) {
      readiness[key] = _indexes[key]?.ready ?? false;
    }
    for (final MapEntry(key: key, value: state) in _indexes.entries) {
      readiness[key] = state.ready;
    }
    return readiness;
  }

  /// Recomputes the sidecar subscription set: candidates are the non-active
  /// workspaces with the newest relay-overview `updatedAt`, capped at
  /// [limit]; the set is diffed against the live subscriptions (new →
  /// subscribe, fallen out / became active → unsubscribe). One pass over
  /// the relay rows; no RPC when the set is unchanged.
  void reconcile() {
    if (isDisposed()) return;
    final desired = _candidates();
    final desiredKeys = {for (final c in desired) c.key};
    for (final key in {..._wireKeys, ..._indexes.keys}) {
      if (desiredKeys.contains(key)) continue;
      // A workspace with a row still in a running phase keeps its layer
      // even after falling out of the top-N: dropping it would flip the row
      // back to the relay's last-turn outcome and could fire a false
      // completion notification. The extra slot lives only until the run
      // ends; becoming the ACTIVE workspace still drops here (the active
      // index covers the same rows).
      if (!_isActiveKey(key) && _hasRunningRow(key)) continue;
      _drop(key, reason: 'left the sidecar set');
    }
    // "Cooldown ~10 min OR until the set changes": a workspace that fell
    // out and re-enters starts over instead of waiting out the old window.
    _cooldownUntil.removeWhere((key, _) => !desiredKeys.contains(key));
    if (!available()) return;
    for (final candidate in desired) {
      if (_indexes.containsKey(candidate.key) ||
          _wireKeys.contains(candidate.key) ||
          _starting.contains(candidate.key)) {
        continue;
      }
      final until = _cooldownUntil[candidate.key];
      if (until != null && clock().isBefore(until)) continue;
      unawaited(_start(candidate));
    }
  }

  /// Tears every sidecar subscription down (workspace switch, suspend):
  /// their per-scope EventListens and subscribes live on the bridge that is
  /// about to die, so they must never outlive it. Silent by design (no
  /// [onChanged]) — the caller is in a teardown path.
  void disposeAll() {
    final keys = {..._wireKeys, ..._indexes.keys};
    for (final key in keys) {
      _indexes.remove(key)?.removeListener(_onIndexChanged);
      _wireKeys.remove(key);
      unawaited(dispose(key));
    }
    if (keys.isNotEmpty) {
      log('[session] sidecars cleared (${keys.length})');
    }
    _cooldownUntil.clear();
  }

  /// Whether [key] is the workspace the conversation link is currently open
  /// on (alias-normalized like the candidate ranking).
  bool _isActiveKey(String key) => activeKey() == key;

  /// Whether a sidecar layer still reports a running-class row (the phase
  /// pill vocabulary: running / prewarming).
  bool _hasRunningRow(String key) {
    final state = _indexes[key];
    if (state == null) return false;
    for (final entry in state.list) {
      if (entry.phase == 'running' || entry.phase == 'prewarming') {
        return true;
      }
    }
    return false;
  }

  /// The top-[limit] non-active workspaces by newest relay row, with the
  /// subscribe scope assembled from the row. The scope needs
  /// `workspacePath` (every scoped wire call does); `workspaceIdentity` is
  /// optional and only passed when the row carries it (3.16.2 relay rows
  /// usually do not).
  ///
  /// Conversation (draft-*) workspaces are skipped: they are ephemeral
  /// one-chat directories whose rows already display in the default group,
  /// so subscribing them would burn the whole budget on drafts.
  List<({String key, Map<String, dynamic> scope})> _candidates() {
    final active = activeKey();
    final latest = <String, ({int updatedAt, String path, String? identity})>{};
    for (final task in relayRows()) {
      final rawKey = TaskDirectory.relayKeyOf(task);
      final path = task['workspacePath'];
      if (rawKey == null || path is! String || path.isEmpty) continue;
      if (isConversationWorkspacePath(path)) continue;
      final key = normalizeKey(rawKey);
      if (active != null && key == active) continue;
      final updatedAt = (task['updatedAt'] as num?)?.toInt() ?? 0;
      final previous = latest[key];
      if (previous == null || updatedAt > previous.updatedAt) {
        final identity = task['workspaceIdentity'];
        latest[key] = (
          updatedAt: updatedAt,
          path: path,
          identity: identity is String && identity.trim().isNotEmpty
              ? identity.trim()
              : null,
        );
      }
    }
    final ranked = latest.entries.toList()
      ..sort((a, b) => b.value.updatedAt.compareTo(a.value.updatedAt));
    return [
      for (final entry in ranked.take(limit))
        (
          key: entry.key,
          scope: {
            'workspacePath': entry.value.path,
            if (entry.value.identity != null)
              'workspaceIdentity': entry.value.identity,
          },
        ),
    ];
  }

  /// Starts ONE sidecar subscription and wires it into the directory.
  Future<void> _start(
    ({String key, Map<String, dynamic> scope}) candidate,
  ) async {
    final key = candidate.key;
    _starting.add(key);
    try {
      final state = await subscribe(
        key,
        candidate.scope,
        (error) => _onSubscribeFailure(key, error),
      );
      _wireKeys.add(key);
      if (isDisposed()) {
        unawaited(_dropWire(key));
        return;
      }
      // The candidate set may have moved while the subscribe flew: a
      // workspace that fell out of the top-N during the await must not
      // leave an over-budget layer installed until the next relay cadence.
      // (A key that left and re-entered counts as desired — the
      // subscription is still the one the set now wants.)
      if (!_candidates().any((c) => c.key == key)) {
        log('[session] sidecar index $key: left the set while subscribing');
        unawaited(_dropWire(key));
        return;
      }
      // Recorded at subscribe time like the active open: rows fall back to
      // it for attribution, and the directory keys the layer by this key.
      state.subscribedWorkspaceKey = key;
      state.addListener(_onIndexChanged);
      _indexes[key] = state;
      log('[session] sidecar index subscribed: $key');
      onChanged();
      // Deleted-task tombstones for this workspace's live rows (§3.3).
      // Quiet channel path: a probe miss must not feed the link ledger.
      unawaited(_probeTombstones(key, state, candidate.scope));
    } catch (e) {
      if (isAgentRuntimeNotRunningError(e)) {
        _cooldownUntil[key] = clock().add(cooldown);
        log('[session] sidecar index $key: cold runtime, cooling down '
            '${cooldown.inMinutes}min');
      } else {
        // Timeouts / bridge trouble: the relay overview cadence retries
        // naturally; no separate retry loop lives here.
        log('[session] sidecar index $key subscribe failed: $e');
      }
    } finally {
      _starting.remove(key);
    }
  }

  /// Automatic-resubscribe failures of one sidecar subscription: a benign
  /// cold-runtime refusal cools the workspace down and drops the
  /// subscription — the built-in 3/6/12s retry would otherwise keep asking
  /// a runtime that is simply off. Every other failure keeps the built-in
  /// retry.
  void _onSubscribeFailure(String key, Object error) {
    if (isDisposed() || !isAgentRuntimeNotRunningError(error)) return;
    _cooldownUntil[key] = clock().add(cooldown);
    log('[session] sidecar index $key: cold runtime on resubscribe, '
        'cooling down ${cooldown.inMinutes}min');
    _drop(key, reason: 'cold runtime');
  }

  /// Pulls one workspace's registry-deleted task ids for the sidecar
  /// layer's tombstone filter (task-registry-semantics §3.3). Any failure
  /// degrades to an empty set (the pre-probe behavior), never blocks.
  Future<void> _probeTombstones(
    String key,
    SessionsIndexState state,
    Map<String, dynamic> scope,
  ) async {
    final deleted = await probeDeleted(scope);
    if (isDisposed() || deleted == null) return;
    // The layer may have been dropped/replaced while the probe flew.
    if (!identical(_indexes[key], state)) return;
    state.deletedTaskIds = Set.of(deleted);
    onChanged();
  }

  /// Removes one sidecar subscription (listener, state map, wire
  /// unsubscribe) and repaints.
  void _drop(String key, {required String reason}) {
    final state = _indexes.remove(key);
    if (state == null && !_wireKeys.contains(key)) return;
    state?.removeListener(_onIndexChanged);
    log('[session] sidecar index dropped: $key ($reason)');
    _wireKeys.remove(key);
    unawaited(dispose(key));
    onChanged();
  }

  /// Drops a subscription whose state was never installed (superseded /
  /// left the set while subscribing). Silent, like the old path.
  Future<void> _dropWire(String key) async {
    _wireKeys.remove(key);
    await dispose(key);
  }

  /// Any sidecar frame: the merged directory changed, repaint the list.
  void _onIndexChanged() {
    if (isDisposed()) return;
    onChanged();
  }
}
