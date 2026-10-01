import 'package:flutter/foundation.dart';

import '../../protocol/conversation.dart';

/// One typed outcome of the history-page decision chain (task
/// 10-01-history-pager-extract). The pager decides; the chat page reacts —
/// toasts for [HistoryStale] / [HistoryNoOlder] / [HistoryFailed], the
/// prepend measurement chain for [HistoryProceed], nothing for [HistoryHold]
/// / [HistoryDuplicateDropped] (parking and the re-entry gate are handled
/// inside the pager / the measurement side respectively).
sealed class HistoryLoadStep {
  const HistoryLoadStep();
}

/// A fetched page accepted for application: run the prepend measurement
/// chain (`_prependOlderPage`) with it. Emitted from a post-frame callback —
/// the response can land in a microtask BEFORE the list has ever mounted.
class HistoryProceed extends HistoryLoadStep {
  const HistoryProceed({
    required this.state,
    required this.older,
    required this.hasMore,
  });

  final ConversationState state;
  final List<Map<String, dynamic>> older;
  final bool? hasMore;
}

/// DRAG HOLD: the page is parked because the viewport was IN MOTION when it
/// arrived (finger down, coast, rebound) — a prepend cannot be compensated
/// under a live gesture. Flushed by [HistoryPager.flushHeld] after the true
/// [ScrollEndNotification].
class HistoryHold extends HistoryLoadStep {
  const HistoryHold({
    required this.state,
    required this.older,
    required this.hasMore,
  });

  final ConversationState state;
  final List<Map<String, dynamic>> older;
  final bool? hasMore;
}

/// `prependOlderRows` inserted 0 rows: a re-fire raced the prepend window on
/// the same beforeRowId cursor. The measurement side must NOT anchor a
/// no-op prepend (it pre-jumps the view a full page out and the landing
/// drags it all the way back, 09-22 round 14) — it reads the count off
/// `commitPrepend` and releases the re-entry gate itself.
class HistoryDuplicateDropped extends HistoryLoadStep {
  const HistoryDuplicateDropped();
}

/// Empty page: nothing older came back. `hasMore` is already written; the
/// caller toasts `chat.noOlder`.
class HistoryNoOlder extends HistoryLoadStep {
  const HistoryNoOlder();
}

/// The page's log epoch no longer matches the live subscription. Reporting
/// drift is the pager's job; acting on it stays with the caller (chat:
/// toast `chat.loadOlder.stale` and apply anyway — round 23).
class HistoryStale extends HistoryLoadStep {
  const HistoryStale();
}

/// The fetch itself threw. The caller toasts `chat.loadOlder.failed`.
class HistoryFailed extends HistoryLoadStep {
  const HistoryFailed(this.error);

  final Object error;
}

/// One load's identity, captured at the entry gate: the deferred body keeps
/// working on THIS state even if a resubscribe swaps the live one out (the
/// identity guard then drops the page).
typedef HistoryLoadRequest = ({ConversationState state, String sessionId});

/// [HistoryPager.commitPrepend] outcome: the chain generation to land with
/// and how many rows actually went in (0 = duplicate page).
typedef HistoryPrepend = ({int generation, int inserted});

/// The pure-decision half of the chat history load: entry gate, fetch,
/// identity guard, DRAG HOLD parking, prepend commit and the anchor-chain
/// generation (task 10-01-history-pager-extract, commit point B — extracted
/// from the chat page's `_loadOlder` / `_loadOlderSettled` /
/// `_flushPendingOlder`). Command-style plain class, no notification
/// machinery: the host learns about outcomes via [onStep] and about loading
/// gate flips via [onGateChanged].
///
/// Deliberately NOT owned here: the measurement chain (anchor measuring,
/// veil, prepend landing — stays in the chat page State) and the
/// `_compensationPending` re-entry gate, which is shared with that chain
/// and therefore injected as [isCompensationPending] /
/// [setCompensationPending] — one truth, owned by the measurement side.
class HistoryPager {
  HistoryPager({
    required this.fetch,
    required this.currentState,
    required this.isScrollIdle,
    required this.isCompensationPending,
    required this.setCompensationPending,
    required this.postFrame,
    required this.onStep,
    this.onGateChanged,
  });

  /// The conversationRowsRangeV4 RPC.
  final Future<dynamic> Function(String sessionId,
      {int? beforeRowId, int limit}) fetch;

  /// The LIVE subscription state (identity-guard comparisons and the flush
  /// drop read it; loads capture it once at [beginLoad]).
  final ConversationState? Function() currentState;

  /// True only when the offset is at rest: no finger down AND no scroll in
  /// motion (the host folds `_userDragActive` / `_scrollSettled` into this).
  final bool Function() isScrollIdle;

  /// The shared re-entry gate — see the class doc.
  final bool Function() isCompensationPending;
  final void Function(bool value) setCompensationPending;

  /// Frame seam: runs [postFrame]'s callback after the next frame (host:
  /// `WidgetsBinding.addPostFrameCallback`).
  final void Function(void Function() callback) postFrame;

  /// Typed outcomes — toasts and measurement-chain scheduling on the host.
  final void Function(HistoryLoadStep step) onStep;

  /// Called after every loading-gate flip so the host can rebuild (the
  /// gate drives the「加载更早」spinner).
  final void Function()? onGateChanged;

  /// Loading gate: true from [beginLoad] until the fetched page is parked
  /// (stays up), applied, dropped, or the fetch failed. Read by the host's
  /// button spinner and re-entry pre-checks.
  bool _loadingOlder = false;
  bool get loadingOlder => _loadingOlder;

  /// A fetched page parked because the viewport was still in motion when it
  /// arrived (see the DRAG HOLD note in [settle]). Flushed by [flushHeld]
  /// after ScrollEnd; dropped there when a resubscribe swapped the state
  /// out (a stale page belongs to a state nobody shows).
  ({
    ConversationState state,
    List<Map<String, dynamic>> older,
    bool? hasMore,
  })? _pendingOlderPage;

  /// Invalidation epoch for anchor-compensation chains: incremented on
  /// every prepend commit; a chain whose captured generation is no longer
  /// current dies before its next landing (the comparison lives in the
  /// host's `_compensateAnchor`).
  int _anchorGeneration = 0;
  int get anchorGeneration => _anchorGeneration;

  // ------------------------------------------------------------- load

  /// Entry gate for ALL four triggers (open auto-load / prefetch window /
  /// pull release / button). Rejects when there is nothing to page on or a
  /// load / compensation chain is already in flight; otherwise raises the
  /// loading gate and returns the captured identity for [settle].
  HistoryLoadRequest? beginLoad(String? sessionId) {
    final state = currentState();
    if (state == null ||
        sessionId == null ||
        _loadingOlder ||
        isCompensationPending()) {
      return null;
    }
    _setLoading(true);
    return (state: state, sessionId: sessionId);
  }

  /// The deferred body of the load — fetches the page, then either hands it
  /// to the measurement chain ([HistoryProceed]), parks it for the
  /// drag-hold flush ([HistoryHold]) or reports [HistoryNoOlder] /
  /// [HistoryStale] / [HistoryFailed]. The host defers the CALL to a
  /// post-frame so the list has actually mounted (the subscribe microtask
  /// chain can beat the first build); the anchor itself is measured fresh
  /// right before the prepend applies the page.
  Future<void> settle(HistoryLoadRequest request) async {
    final state = request.state;
    try {
      // Cursor = the oldest row actually held (state.oldestRowId). Snapshot
      // `firstRowId` can be a placeholder (live-probed 1) — using it
      // re-fetched the newest window and the「加载更早」button spin forever
      // (live_child_rows_probe documents the same trap).
      final res = await fetch(
        request.sessionId,
        beforeRowId: state.oldestRowId,
        limit: 60,
      );
      // Subscription identity guard: a resubscribe (bridge restart)
      // swapped the state out from under this fetch — its page belongs
      // to a state nobody shows. (Map responses only, as before — a bare
      // List answer has no envelope to guard with.)
      if (res is Map && state != currentState()) {
        debugPrint('[anchor] drop page: state replaced (resubscribe)');
        return;
      }
      final page = parseRowsRangeResponse(res, state: state);
      // The window is dropped when its log epoch no longer matches
      // the live subscription — but our desktop advances the epoch while
      // streaming (fresh snapshot every ~10s, 09-22 13:54 device log),
      // and the request/response race then silently killed EVERY fetched
      // page ("stuck at loading": prefetches fired for three minutes,
      // none ever reached the prepend). The rows themselves are
      // immutable log entries — an epoch drift does not invalidate them.
      // Log it and apply anyway (round 23); the toast stays as a trace
      // of the drift for future diagnosis.
      if (!page.epochMatches) {
        debugPrint('[anchor] epoch drift on fetched page '
            '(at=${page.atLogEpoch} live=${state.logEpoch}) — applying anyway');
        onStep(const HistoryStale());
      }
      final older = page.rows;
      if (older != null && older.isNotEmpty) {
        // DRAG HOLD: while the viewport is still IN MOTION the prepend
        // cannot be compensated — no landing may jumpTo under a live
        // gesture (it would kill the drag or the coast), and unhedged the
        // anchor lands outside the cache extent, the chain gives up, and
        // the viewport keeps staring at swapped-in older rows (09-22 round
        // 13: consecutive give-ups at pixels≈1000, then a landing yanked
        // 1086 -> 14246 correcting the stacked error). Covers the
        // finger-down drag AND the release: ballistic coast, pull rebound
        // — round 16 log showed the reply landing mid-rebound (armed -1144
        // -> pixels 0 = drift surrender, position lost) and mid-slow-coast
        // (a wait-shift check still let a prepend through, the raw landing
        // then jumped a full page 1984 -> 5945). Park the fetched page
        // until the scroll truly ends ([ScrollEndNotification] fires after
        // the release spring settles), then flush through the normal
        // measure→prepend→land path.
        if (!isScrollIdle()) {
          _pendingOlderPage = (
            state: state,
            older: older,
            hasMore: page.hasMore,
          );
          onStep(HistoryHold(
            state: state,
            older: older,
            hasMore: page.hasMore,
          ));
          return; // finally keeps the loading gate up — no duplicate fetch
        }
        // Post-frame: the response can land in a microtask BEFORE the list
        // has ever mounted (feedSnapshot fires the open auto-load while
        // pumpWidget is still ahead — hasClients=false, the anchor measure
        // dies, no chain registers, and the follow's extent-estimate
        // animateTo is left owning the viewport). One frame also re-reads
        // SETTLED boxes for the measurement.
        //
        // The re-entry gate closes HERE, not inside the post-frame prepend:
        // the loading gate clears in the finally below (same microtask), and
        // a coasting prefetch firing in the frame between would pass both
        // gates and re-fire on the SAME cursor (duplicate page, 09-22
        // round 15: the fling test armed a third fetch while page two's
        // prepend was still a frame away). The prepend commit clears it if
        // no anchor can be measured.
        setCompensationPending(true);
        postFrame(() => onStep(HistoryProceed(
              state: state,
              older: older,
              hasMore: page.hasMore,
            )));
      } else if (state.rows.isNotEmpty) {
        state.hasMore = page.hasMore ?? false;
        onStep(const HistoryNoOlder());
      }
    } catch (e) {
      onStep(HistoryFailed(e));
    } finally {
      if (_pendingOlderPage == null) {
        _setLoading(false);
      }
    }
  }

  // ---------------------------------------------------------- prepend

  /// Prepend-frame DRAG HOLD recheck, called by the measurement chain right
  /// before it measures (and again after the frozen-frame capture): the
  /// arrival microtask's settled verdict can be one frame stale — a slow
  /// reader's rhythm is stop-and-go, and a reply that lands in a pause then
  /// prepends just as the NEXT drag starts would prepend into a moving
  /// viewport (09-22 round 16: give-up at pixels 320, next landing
  /// 3616 -> 6581). Same remedy as the arrival hold — park the page until
  /// the true ScrollEnd; the flush measures a fresh anchor then. Returns
  /// true when the page was parked and the caller must abort.
  bool parkPrependIfBusy(
    ConversationState state,
    List<Map<String, dynamic>> older,
    bool? hasMore,
  ) {
    if (isScrollIdle()) return false;
    _pendingOlderPage = (state: state, older: older, hasMore: hasMore);
    // The arrival path already lowered the loading gate (its finally saw
    // no pending page back then) — raise it back, or the one-frame gap
    // lets a prefetch re-fire on the same cursor (the duplicate-page drop
    // makes that harmless, but it wastes a round trip).
    _setLoading(true);
    onStep(HistoryHold(state: state, older: older, hasMore: hasMore));
    return true;
  }

  /// The prepend's data commit, called by the measurement chain after the
  /// anchor is measured and before the veil applies: bumps the chain
  /// generation, writes `hasMore` back and prepends (dedupe inside
  /// [ConversationState.prependOlderRows]). A zero insert means a duplicate
  /// page raced the prepend window — the caller releases the re-entry gate
  /// and aborts WITHOUT anchoring (see [HistoryDuplicateDropped]).
  HistoryPrepend commitPrepend(
    ConversationState state,
    List<Map<String, dynamic>> older,
    bool? hasMore,
  ) {
    final generation = ++_anchorGeneration;
    state.hasMore = hasMore;
    final inserted = state.prependOlderRows(older);
    if (inserted == 0) {
      onStep(const HistoryDuplicateDropped());
    }
    return (generation: generation, inserted: inserted);
  }

  // ------------------------------------------------------------- flush

  /// Flushes a drag-held page ([_pendingOlderPage]) once the scroll has
  /// truly ended (drag released AND the release spring / fling settled —
  /// ScrollEndNotification). If an earlier chain's compensation is still
  /// pending, waits a frame for it to settle first: two prepends without a
  /// landing in between would stack un-compensated offsets. The flush
  /// frame itself opens the loading gate immediately before the prepend
  /// step runs — the cursor still points at the held page's boundary until
  /// then, so a prefetch fired in the window re-fetches the SAME page (it
  /// dedupes to zero inserted rows, and anchoring a no-op prepend is the
  /// full jump-out-and-back of 09-22 round 14).
  void flushHeld() {
    final page = _pendingOlderPage;
    if (page == null) return;
    if (page.state != currentState()) {
      // The subscription was rebuilt under us (bridge restart / resubscribe):
      // the held page belongs to a state nobody shows — drop it, and release
      // the loading gate the hold kept up.
      _pendingOlderPage = null;
      _setLoading(false);
      return;
    }
    if (isCompensationPending()) {
      postFrame(flushHeld);
      return;
    }
    _pendingOlderPage = null;
    postFrame(() {
      _setLoading(false);
      onStep(HistoryProceed(
        state: page.state,
        older: page.older,
        hasMore: page.hasMore,
      ));
    });
  }

  void _setLoading(bool value) {
    _loadingOlder = value;
    onGateChanged?.call();
  }
}
