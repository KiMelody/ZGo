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
/// The whole policy lives here — candidate ranking (top-N by newest relay
/// row), cooldown (deadline OR newer relay activity, design 11-02 §2),
/// in-flight dedup, the running-row slot, failure classification, eviction
/// unsubscribe and the workspace-switch carry-over (design 11-02 §3) — so
/// the policy is one readable block instead of a hub section. The session
/// contributes only the capabilities (wire subscribe/dispose, quiet probe,
/// candidate inputs, notification and lifecycle) through constructor
/// closures; the state maps and the reconciliation live in this class.
///
/// Carry-over in one line: [detachAll] keeps the layer *data* (marks it
/// stale) while the old bridge — and every wire subscription on it — dies;
/// reconcile treats a stale key as uninstalled and re-subscribes, and the
/// fresh state only REPLACES the stale one on its first ready frame.
///
/// The subscribe frame (scope + `runtimePolicy:'existing-only'`), the topic
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
    required this.onColdRefusal,
    required this.onChanged,
    required this.isDisposed,
    required this.log,
    required this.limit,
    required this.cooldown,
    required this.clock,
    this.staleTtl = const Duration(seconds: 60),
    this.staleRunningCap = const Duration(minutes: 10),
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

  /// One cold-runtime refusal against [key] — the initial subscribe as well
  /// as the automatic resubscribe failure hook. Purely observational: the
  /// session records per-workspace evidence for the card 「休眠」 marker.
  /// The cooldown policy itself stays inside this manager.
  final void Function(String key) onColdRefusal;

  /// Exactly one call per state change: subscribe installed, drop, any
  /// sidecar frame, tombstone probe write. The session owns the single
  /// notify (sidecar frames and set changes each notify once).
  final void Function() onChanged;

  /// The session is disposed: no new subscribe is recorded, no notify.
  final bool Function() isDisposed;

  final void Function(String line) log;

  /// Upper bound on the RANKED sidecar set (recently active non-active
  /// workspaces, newest `updatedAt` first, key lexicographic tie-break).
  /// Retained running-row layers and switch carry-over stale layers may
  /// exceed it — this bounds the resubscribe wave, not the subscription count.
  final int limit;

  /// Per-key cooldown window after the benign cold-runtime refusal. It ends
  /// at the deadline OR early when the workspace's relay rows show newer
  /// activity than the watermark recorded at the refusal.
  final Duration cooldown;

  final DateTime Function() clock;

  /// How long a detached (stale) layer may keep serving the merge after a
  /// workspace switch before reconcile drops it. The effective bound is
  /// "first successful reconcile past this age" — the relay cadence is the
  /// expiry clock (design 11-02 §3.3, review P3-1). Injectable so tests can
  /// shrink it.
  final Duration staleTtl;

  /// Hard ceiling on the running-row TTL exemption ([_expireStale]). A
  /// stale running layer that keeps failing to resubscribe (cold-runtime
  /// cooldown cycle) would otherwise stay frozen forever: its wire is dead,
  /// so it never receives the terminal frame. At the cap the layer drops
  /// and the row falls back to the relay's terminal state — the run must
  /// have ended by then (a live run implies a warm runtime, which implies
  /// the fresh subscribe succeeded), so any completion edge the drop
  /// produces is a real, just late, notification. Injectable so tests can
  /// shrink it (check P2-1).
  final Duration staleRunningCap;

  /// Wire subscriptions by workspace key — a proxy for the session's wire
  /// handles, tracked here so the eviction checks keep the former
  /// `_sidecarSubs ∪ _sidecarIndexes` semantics.
  final Set<String> _wireKeys = {};

  /// Sidecar index states by workspace key — the live layers the task
  /// directory merges (below the ACTIVE index, above the relay rows).
  final Map<String, SessionsIndexState> _indexes = {};

  /// Keys whose layer is carry-over DATA from the previous bridge (design
  /// 11-02 §3): the wire subscription is gone, the state keeps rendering
  /// until a fresh subscription delivers its first ready frame or the
  /// [staleTtl] bound expires. A stale key counts as NOT installed for the
  /// reconcile subscribe guard (it must be able to re-subscribe).
  final Map<String, DateTime> _staleAt = {};

  /// Fresh states waiting for their first ready frame before they replace a
  /// stale layer (design 11-02 §3.3): the stale state keeps serving the
  /// merge until the new wire actually carries data.
  final Map<String, SessionsIndexState> _pendingFresh = {};

  /// Teardown generation: bumped by every [detachAll] / [disposeAll], so a
  /// subscribe that was in flight on the dying bridge cannot install its
  /// state on the new one.
  int _teardownEpoch = 0;

  /// Keys with a subscribe in flight (dedup across overlapping reconciles).
  final Set<String> _starting = {};

  /// Per-key cooldown deadline after the benign cold-runtime refusal.
  final Map<String, DateTime> _cooldownUntil = {};

  /// Per-key relay-row activity watermark recorded when the cooldown was
  /// written: the key's `max(updatedAt)` at refusal time (relay epoch ms —
  /// the same domain as the candidate rows, never converted to the local
  /// clock). A newer value means activity happened after the cooldown, so
  /// reconcile may retry while the deadline is still running.
  final Map<String, int> _cooldownWatermark = {};

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
  /// [limit], plus any stale layer still reporting a running-class row (the
  /// running-row slot's carry-over counterpart, design 11-02 §3.2); the set
  /// is diffed against the live subscriptions (new → subscribe, fallen out
  /// / became active → unsubscribe). One pass over the relay rows; no RPC
  /// when the set is unchanged.
  void reconcile() {
    if (isDisposed()) return;
    final now = clock();
    // Expired carry-over layers retire through the normal drop path so the
    // list repaints (review P3-11: a silent removal would leave the UI
    // showing rows that no longer exist in the merge).
    _expireStale(now);
    final desired = _desiredCandidates();
    final desiredKeys = {for (final c in desired) c.key};
    for (final key in {..._wireKeys, ..._indexes.keys}) {
      if (desiredKeys.contains(key)) continue;
      // A workspace with a row still in a running phase keeps its layer
      // even after falling out of the top-N: dropping it would flip the row
      // back to the relay's last-turn outcome and could fire a false
      // completion notification. The extra slot lives only until the run
      // ends; becoming the ACTIVE workspace still drops here (the active
      // index covers the same rows). Stale layers go through the same
      // check (P2-4) — a frozen running row must not be retired by TTL.
      if (!_isActiveKey(key) && _hasRunningRow(key)) continue;
      _drop(key, reason: 'left the sidecar set');
    }
    // "Cooldown ~10 min OR until the set changes": a workspace that fell
    // out and re-enters starts over instead of waiting out the old window.
    // ORDER MATTERS: this prune must stay BEFORE the cooldown gate — it is
    // what guarantees every key reaching the gate with a live cooldown is
    // still in `desired`, so `candidate.updatedAt` is that key's current
    // relay activity.
    _cooldownUntil.removeWhere((key, _) => !desiredKeys.contains(key));
    _cooldownWatermark.removeWhere((key, _) => !desiredKeys.contains(key));
    if (!available()) return;
    for (final candidate in desired) {
      // A stale key counts as NOT installed (design 11-02 §3.2 / review
      // P1-1): the carry-over data is still in `_indexes`, but the wire
      // must be re-subscribed on the new bridge or the layer freezes.
      if ((_indexes.containsKey(candidate.key) &&
              !_staleAt.containsKey(candidate.key)) ||
          _wireKeys.contains(candidate.key) ||
          _starting.contains(candidate.key)) {
        continue;
      }
      // Cooldown = deadline OR activity: retry when the key's relay rows
      // moved past the watermark recorded at the refusal (a row refresh is
      // new activity, not the same cold runtime being asked again). Both
      // values are relay epoch ms — no cross-clock comparison.
      final until = _cooldownUntil[candidate.key];
      final watermark = _cooldownWatermark[candidate.key];
      if (until != null &&
          clock().isBefore(until) &&
          (watermark == null || candidate.updatedAt <= watermark)) {
        continue;
      }
      unawaited(_start(candidate));
    }
  }

  /// Tears every sidecar subscription down on suspend / dispose: their
  /// per-scope EventListens and subscribes live on the bridge that is about
  /// to die, so they must never outlive it. The layer DATA goes too — a
  /// suspend is a cold start (the design 11-02 §3.3 invariant). Silent by
  /// design (no [onChanged]) — the caller is in a teardown path.
  void disposeAll() => _teardown(keepStates: false);

  /// Workspace-switch teardown (design 11-02 §3.1): detaches the listeners
  /// and disposes the wire (the old bridge dies with the switch), but KEEPS
  /// the layer data as stale carry-over — the merge keeps rendering real
  /// phases through the new bridge's subscribe + first snapshot window.
  /// Silent, like [disposeAll]; the switch path notifies on its own.
  void detachAll() => _teardown(keepStates: true);

  /// Hands the previous ACTIVE workspace's state to the manager at the
  /// switch seam (design 11-02 §3.1, review P1-2/P3-9): its wire dies with
  /// the old bridge, but the state carries the freshest rendered rows.
  /// Only a READY state is accepted — an unsnapshotted state would seed a
  /// fake empty card (review P2-5) — and the subscription identity is
  /// rewritten to the canonical [key] (the open path records the raw key).
  /// Must be called right after [detachAll] (the only current call site):
  /// writing `_indexes` while a live wire/pending fresh exists for the key
  /// would leave a stale layer and a live subscription coexisting.
  void seedStale(
    String key,
    SessionsIndexState state, {
    required DateTime now,
  }) {
    if (!state.ready) return;
    // The manager's own listener never rides the active subscription; make
    // sure a state that previously was a sidecar cannot double-listen.
    state.removeListener(_onIndexChanged);
    _indexes[key]?.removeListener(_onIndexChanged);
    _indexes[key] = state;
    _staleAt[key] = now;
    state.subscribedWorkspaceKey = key;
  }

  /// Shared teardown body for [detachAll] / [disposeAll].
  ///
  /// Both dispose every wire on the dying bridge and clear the in-flight
  /// set: a subscribe still in flight resolves after the switch, and
  /// waiting for its 60 s ack timeout would keep the key un-subscribable
  /// (the [SidecarIndexManager._teardownEpoch] guard makes the late
  /// continuation harmless). Cooldown + watermark SURVIVE teardown — they
  /// describe the desktop runtime, not the link, so a switched bridge must
  /// not retry a workspace that just refused. [keepStates] is the detach
  /// semantic: keep the data and mark it stale. [disposeAll] additionally
  /// forgets every stale mark because no layered state survives it.
  void _teardown({required bool keepStates}) {
    _teardownEpoch++;
    final keys = {..._wireKeys, ..._indexes.keys, ..._pendingFresh.keys};
    for (final key in keys) {
      final state = _indexes[key];
      _pendingFresh.remove(key)?.removeListener(_onIndexChanged);
      state?.removeListener(_onIndexChanged);
      if (keepStates && state != null) {
        _staleAt[key] = clock();
      } else {
        _indexes.remove(key);
        _staleAt.remove(key);
      }
      _wireKeys.remove(key);
      unawaited(dispose(key));
    }
    if (!keepStates) _staleAt.clear();
    _starting.clear();
    if (keys.isNotEmpty) {
      log(keepStates
          ? '[session] sidecars detached (${keys.length})'
          : '[session] sidecars cleared (${keys.length})');
    }
  }

  /// Retires carry-over layers older than [staleTtl] through [_drop] so the
  /// repaint happens (review P3-11). A stale layer still reporting a
  /// running-class row is exempt up to [staleRunningCap]: dropping it early
  /// would flip the row to the relay's last-turn outcome and could fire a
  /// false completion notification (review P2-4) — the same promise the
  /// live running slot makes. Past the cap the layer drops anyway: a frozen
  /// running display with no resubscribe in sight is strictly worse than
  /// the (real, late) terminal fallback (check P2-1).
  void _expireStale(DateTime now) {
    final expired = <String>[
      for (final entry in _staleAt.entries)
        if (!now.isBefore(entry.value.add(staleTtl)) &&
            (!_hasRunningRow(entry.key) ||
                !now.isBefore(entry.value.add(staleRunningCap))))
          entry.key,
    ];
    for (final key in expired) {
      _drop(key, reason: 'stale TTL expired');
    }
  }

  /// [reconcile]'s desired set: the top-[limit] candidates plus any stale
  /// key still reporting a running-class row, even after it fell out of the
  /// top-N (review P2-4). The stale entry's scope comes from its relay row;
  /// a stale-running key with no relay row stays layered (the eviction and
  /// TTL guards read the state) but cannot be re-scoped for a subscribe.
  List<({String key, Map<String, dynamic> scope, int updatedAt})>
  _desiredCandidates() {
    final desired = _candidates();
    if (_staleAt.isEmpty) return desired;
    final desiredKeys = {for (final c in desired) c.key};
    final latest = _latestByKey();
    for (final key in _staleAt.keys) {
      if (desiredKeys.contains(key) || !_hasRunningRow(key)) continue;
      final row = latest[key];
      if (row == null) continue;
      desiredKeys.add(key);
      desired.add((
        key: key,
        scope: {
          'workspacePath': row.path,
          if (row.identity != null) 'workspaceIdentity': row.identity,
        },
        updatedAt: row.updatedAt,
      ));
    }
    return desired;
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

  /// The full per-key relay latest map (`key → newest row`), shared by the
  /// candidate ranking and the cooldown watermark so both read the same
  /// value in the same domain. The active workspace and conversation
  /// (draft-*) paths are excluded exactly like the ranking.
  Map<String, ({int updatedAt, String path, String? identity})>
  _latestByKey() {
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
    return latest;
  }

  /// The top-[limit] non-active workspaces by newest relay row, with the
  /// subscribe scope assembled from the row. The scope needs
  /// `workspacePath` (every scoped wire call does); `workspaceIdentity` is
  /// optional and only passed when the row carries it (3.16.2 relay rows
  /// usually do not). `updatedAt` rides along (filled from the full latest
  /// map before `take(limit)`) so the cooldown gate compares the candidate's
  /// current relay activity without re-scanning the rows.
  ///
  /// Ranking ties break on the key's lexicographic order: `List.sort` is not
  /// stable, so without it the [limit]-th slot would flip between equal
  /// `updatedAt` rows and the subscription set would churn (design 11-02 §1,
  /// review P3-4).
  ///
  /// Conversation (draft-*) workspaces are skipped: they are ephemeral
  /// one-chat directories whose rows already display in the default group,
  /// so subscribing them would burn the whole budget on drafts.
  List<({String key, Map<String, dynamic> scope, int updatedAt})>
  _candidates() {
    final latest = _latestByKey();
    final ranked = latest.entries.toList()
      ..sort((a, b) {
        final byUpdatedAt = b.value.updatedAt.compareTo(a.value.updatedAt);
        return byUpdatedAt != 0 ? byUpdatedAt : a.key.compareTo(b.key);
      });
    return [
      for (final entry in ranked.take(limit))
        (
          key: entry.key,
          scope: {
            'workspacePath': entry.value.path,
            if (entry.value.identity != null)
              'workspaceIdentity': entry.value.identity,
          },
          updatedAt: entry.value.updatedAt,
        ),
    ];
  }

  /// Starts ONE sidecar subscription and wires it into the directory.
  Future<void> _start(
    ({String key, Map<String, dynamic> scope, int updatedAt}) candidate,
  ) async {
    final key = candidate.key;
    final epoch = _teardownEpoch;
    _starting.add(key);
    try {
      final state = await subscribe(
        key,
        candidate.scope,
        (error) => _onSubscribeFailure(key, error),
      );
      if (epoch != _teardownEpoch) {
        // A switch/suspend tore this bridge down while the subscribe was in
        // flight: the wire belongs to the dead bridge — dispose it instead
        // of installing a layer nobody controls.
        unawaited(dispose(key));
        return;
      }
      _wireKeys.add(key);
      if (isDisposed()) {
        unawaited(_dropWire(key));
        return;
      }
      // The candidate set may have moved while the subscribe flew: a
      // workspace that fell out of the top-N during the await must not
      // leave an over-budget layer installed until the next relay cadence.
      // (A key that left and re-entered counts as desired — the
      // subscription is still the one the set now wants. Stale-running
      // keys count as desired too, P2-4.)
      if (!_desiredCandidates().any((c) => c.key == key)) {
        log('[session] sidecar index $key: left the set while subscribing');
        unawaited(_dropWire(key));
        return;
      }
      // Recorded at subscribe time like the active open: rows fall back to
      // it for attribution, and the directory keys the layer by this key.
      state.subscribedWorkspaceKey = key;
      state.addListener(_onIndexChanged);
      if (_staleAt.containsKey(key)) {
        // The carry-over layer keeps serving until this fresh state proves
        // it has data (first ready frame, design 11-02 §3.3 / review
        // P2-3): an ack-only replacement would reproduce the phase-
        // regression window this task exists to close.
        _pendingFresh[key] = state;
        _promoteReadyPending();
      } else {
        _indexes[key] = state;
        log('[session] sidecar index subscribed: $key');
        onChanged();
      }
      // Deleted-task tombstones for this workspace's live rows (§3.3).
      // Quiet channel path: a probe miss must not feed the link ledger.
      unawaited(_probeTombstones(key, state, candidate.scope));
    } catch (e) {
      if (isAgentRuntimeNotRunningError(e)) {
        _writeCooldown(key);
        onColdRefusal(key);
        log('[session] sidecar index $key: cold runtime, cooling down '
            '${cooldown.inMinutes}min');
      } else {
        // Timeouts / bridge trouble: the relay overview cadence retries
        // naturally; no separate retry loop lives here.
        log('[session] sidecar index $key subscribe failed: $e');
      }
    } finally {
      // Only the attempt that owns the set entry may clear it: a teardown
      // already cleared `_starting`, and the NEXT attempt may have re-added
      // the key (the epoch check keeps this attempt from clearing it).
      if (epoch == _teardownEpoch) _starting.remove(key);
    }
  }

  /// Automatic-resubscribe failures of one sidecar subscription: a benign
  /// cold-runtime refusal cools the workspace down and drops the
  /// subscription — the built-in 3/6/12s retry would otherwise keep asking
  /// a runtime that is simply off. Every other failure keeps the built-in
  /// retry.
  void _onSubscribeFailure(String key, Object error) {
    if (isDisposed() || !isAgentRuntimeNotRunningError(error)) return;
    _writeCooldown(key);
    onColdRefusal(key);
    log('[session] sidecar index $key: cold runtime on resubscribe, '
        'cooling down ${cooldown.inMinutes}min');
    if (_staleAt.containsKey(key)) {
      // The fresh wire died, but the carry-over data is still the best the
      // merge has: keep it serving (and re-subscribable) until TTL / the
      // next successful subscribe. Dropping the state here would reopen
      // the phase-regression window.
      unawaited(_dropWire(key));
      return;
    }
    _drop(key, reason: 'cold runtime');
  }

  /// Records the cooldown for [key]: the deadline plus the key's newest
  /// relay-row `updatedAt` at refusal time (the watermark). A later relay
  /// refresh above the watermark is activity after the cooldown — the cold
  /// runtime may have been started by the desktop — so reconcile retries.
  /// Both maps share the relay epoch-ms domain; the clock only sets the
  /// deadline.
  void _writeCooldown(String key) {
    _cooldownUntil[key] = clock().add(cooldown);
    _cooldownWatermark[key] = _latestByKey()[key]?.updatedAt ?? 0;
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
    // The layer may have been dropped/replaced while the probe flew, or the
    // state may still be pending (not promoted) behind a stale layer.
    if (!identical(_indexes[key], state) &&
        !identical(_pendingFresh[key], state)) {
      return;
    }
    state.deletedTaskIds = Set.of(deleted);
    onChanged();
  }

  /// Removes one sidecar subscription (listener, state map, wire
  /// unsubscribe) and repaints.
  void _drop(String key, {required String reason}) {
    final state = _indexes.remove(key);
    _staleAt.remove(key);
    _pendingFresh.remove(key)?.removeListener(_onIndexChanged);
    if (state == null && !_wireKeys.contains(key)) return;
    state?.removeListener(_onIndexChanged);
    log('[session] sidecar index dropped: $key ($reason)');
    _wireKeys.remove(key);
    unawaited(dispose(key));
    onChanged();
  }

  /// Drops a subscription whose state was never installed (superseded /
  /// left the set while subscribing). Silent, like the old path — a stale
  /// layer that is still serving is kept until TTL.
  Future<void> _dropWire(String key) async {
    _pendingFresh.remove(key)?.removeListener(_onIndexChanged);
    _wireKeys.remove(key);
    await dispose(key);
  }

  /// Any sidecar frame: the merged directory changed, repaint the list.
  /// A fresh state behind a stale layer promotes itself on its first ready
  /// frame (same listener, no separate one-shot registration).
  void _onIndexChanged() {
    if (isDisposed()) return;
    _promoteReadyPending();
    onChanged();
  }

  /// Installs every pending fresh state that has delivered its first ready
  /// frame (design 11-02 §3.3 / review P2-3). The stale state kept serving
  /// the merge until exactly this point.
  void _promoteReadyPending() {
    if (_pendingFresh.isEmpty) return;
    for (final key in List.of(_pendingFresh.keys)) {
      final fresh = _pendingFresh[key];
      if (fresh == null || !fresh.ready) continue;
      _pendingFresh.remove(key);
      final stale = _indexes[key];
      if (!identical(stale, fresh)) stale?.removeListener(_onIndexChanged);
      _indexes[key] = fresh;
      _staleAt.remove(key);
      log('[session] sidecar index ready, stale layer replaced: $key');
      onChanged();
    }
  }
}
