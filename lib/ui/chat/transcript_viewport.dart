import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable, kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;

import '../../protocol/conversation.dart';
import 'timeline.dart';
import 'transcript_viewport_math.dart';

/// The only step type the host still sees (task 10-29-transcript-viewport):
/// the viewport decides and lands, the page toasts. [HistoryStale] and
/// [HistoryNoOlder] can arrive in the SAME settle (an epoch-drifted page
/// applies and its empty follow-up still reports noOlder), so the host
/// consumes them through a callback, never a single return value.
sealed class HistoryToastStep {
  const HistoryToastStep();
}

/// Empty page: nothing older came back. `hasMore` has been written already;
/// the host toasts `chat.noOlder`.
final class HistoryNoOlder extends HistoryToastStep {
  const HistoryNoOlder();
}

/// The page's log epoch no longer matches the live subscription. Rows are
/// immutable log entries — the page still applies (round 23); the host toasts
/// `chat.loadOlder.stale`.
final class HistoryStale extends HistoryToastStep {
  const HistoryStale();
}

/// The fetch itself threw. The host toasts `chat.loadOlder.failed`.
final class HistoryFailed extends HistoryToastStep {
  const HistoryFailed(this.error);

  final Object error;
}

/// The veil has no `landing` stage: the landing and the lift happen in the
/// same frame (the veiled branch `jumpTo`s and lifts), so `none` already
/// means "not frozen".
enum TranscriptVeilPhase { none, frozen }

/// What [TranscriptVeil] paints from. The [image] lifetime is owned by
/// [TranscriptViewport] — the widget reads it, never disposes it.
@immutable
class TranscriptVeilState {
  const TranscriptVeilState.none()
      : phase = TranscriptVeilPhase.none,
        image = null;

  /// [image] is non-null by contract (the viewport only arms the veil with a
  /// successful capture — a plain veil without a frozen frame is the device
  /// black flash, round 24).
  const TranscriptVeilState.frozen(this.image)
      : phase = TranscriptVeilPhase.frozen;

  final TranscriptVeilPhase phase;
  final ui.Image? image;
}

/// Landing dispatch seam: `duration == null` is a jump, non-null an animated
/// glide. Production forwards to the attached [ScrollController].
typedef LandingSink = void Function(double target, {Duration? duration});

/// One built turn group as the compensation chain sees it: the [key] the
/// prepend may orphan, the [rows] it carries (first-row stability and the
/// rowId fallback), and its global [top]/[height].
typedef GroupMeasurement = ({
  Key key,
  List<Map<String, dynamic>> rows,
  double top,
  double height,
});

/// Scroll offset sample — the subset of [ScrollPosition] the chain reads.
typedef ScrollSample = ({
  double pixels,
  double maxScrollExtent,
  double viewportDimension,
});

/// Measurement seam of [TranscriptViewport] (design §7): production walks
/// the Element tree under the attached list key; controller tests inject a
/// fake and drive the whole compensation chain without a widget tree.
abstract interface class TranscriptMeasurePort {
  /// The list's viewport-sized render box, or null when nothing is laid out.
  ({double top, double height})? viewportBox();

  /// Every currently-built turn group, in list order.
  List<GroupMeasurement> builtGroups();

  /// A single row's render box by its `ValueKey('row-<rowId>')`, or null when
  /// that row is not independently built (merged inside a text part).
  ({double top, double height})? rowBox(Key rowKey);

  /// The live scroll offset.
  ScrollSample position();

  /// The row grouping the built groups obey (`timeline.groupChatRows`; the
  /// detail page filters through `childSessionRows` first).
  List<List<Map<String, dynamic>>> groupRows(List<Map<String, dynamic>> rows);
}

/// The history-load viewport (task 10-29-transcript-viewport): the physical
/// half of "load one older page" — idle bookkeeping (drag/settled/
/// positioning/pull), the four triggers, DRAG HOLD parking and flush, the
/// prepend measurement + frozen-frame veil + anchor compensation, the
/// re-entry gate and the layout-cache pre-widen.
///
/// Deliberately NOT owned here (the host keeps them): streaming follow,
/// jump-to-bottom state, the keyboard shrink-follow, the turn navigator, and
/// the ListView shell (builder/itemBuilder/physics/padding/keys). Row
/// rendering stays in `timeline.dart`.
///
/// Decisions (entry gate, fetch, identity guard, parking, prepend commit,
/// chain generation) live in this module too — the old standalone paging
/// class is gone; the host hears about toasts via [onToast] and about
/// gate/cache flips via [ChangeNotifier].
class TranscriptViewport extends ChangeNotifier {
  TranscriptViewport({
    required this.fetch,
    required this.currentState,
    required this.currentSessionId,
    required this.isStickToBottom,
    required this.listBottomPadding,
    required this.onToast,
    required this.postFrame,
    TranscriptMeasurePort? measure,
    Future<ui.Image?> Function()? capture,
    LandingSink? landing,
  })  : _injectedMeasure = measure,
        _injectedCapture = capture,
        _injectedLanding = landing;

  /// The conversationRowsRangeV4 RPC behind one page load.
  final Future<dynamic> Function(String sessionId,
      {int? beforeRowId, int limit}) fetch;

  /// The LIVE subscription state (identity-guard comparisons and the flush
  /// drop read it; a load captures it once at [loadOlder]).
  final ConversationState? Function() currentState;

  /// The session the internal triggers (prefetch / pull / open) load for —
  /// chat: `_sessionId`, detail: `childSessionId`.
  final String? Function() currentSessionId;

  /// The page's cached pinned verdict (read-only): the landing's pinned
  /// demotion test uses it exactly like the pre-extraction
  /// `_measureAnchor`.
  final bool Function() isStickToBottom;

  /// The host ListView's bottom padding — the pinned landing's content-end
  /// formula. The viewport never guesses ListView padding.
  final double listBottomPadding;

  /// Toast sink for [HistoryToastStep] outcomes (host handles i18n/UX).
  final void Function(HistoryToastStep step) onToast;

  /// Frame seam (production: `WidgetsBinding.addPostFrameCallback` behind the
  /// host's `mounted` guard; tests: a manual queue).
  final void Function(void Function() callback) postFrame;

  final TranscriptMeasurePort? _injectedMeasure;
  final Future<ui.Image?> Function()? _injectedCapture;
  final LandingSink? _injectedLanding;

  ScrollController? _controller;
  GlobalKey? _freezeKey;
  _ElementMeasurePort? _elementPort;

  /// [RepaintBoundary] around the list — the capture source for the frozen
  /// frame. Host-injected through [attach]; [TranscriptVeil] mounts it.
  GlobalKey? get freezeKey => _freezeKey;

  /// Pull threshold (logical px) for the history pull gesture: releasing a
  /// top overscroll at least this deep loads the older page.
  static const double _kPullThreshold = 64.0;

  bool _disposed = false;

  // ------------------------------------------------------- idle bookkeeping

  /// Pull-gesture arming: true while the current drag holds the list
  /// overscrolled past [_kPullThreshold] at the top; the first non-drag
  /// scroll update afterwards is the release frame.
  bool _pullArmed = false;

  /// True from a user drag's ScrollStart until its release frame: the anchor
  /// compensation must not jump under an active finger — the jump replaces
  /// the position's drag activity and every later move event of that gesture
  /// dies silently.
  bool _userDragActive = false;

  /// False from the first scroll update of any session (drag, ballistic
  /// coast, release spring, programmatic animation) until its ScrollEnd —
  /// i.e. true only while the offset is AT REST. A prepend landing mid-coast
  /// must not jump (kills the user's momentum, "滑着也被拉", round 15).
  bool _scrollSettled = true;

  /// True while a programmatic scroll (jumpTo / animateTo — open positioning,
  /// keyboard shrink-follow, jump-to-bottom, anchor compensation) is in
  /// flight. Its pixel sweep crosses the prefetch window without the user
  /// reading anywhere near it, so the trigger parks until ScrollEnd.
  bool _positioning = false;

  // ------------------------------------------------------------- load state

  bool _loadingOlder = false;

  /// Loading gate: true from [loadOlder] until the fetched page is parked
  /// (stays up), applied, dropped, or the fetch failed. Read by the host's
  /// button spinner and the re-entry pre-checks.
  bool get loadingOlder => _loadingOlder;

  /// A fetched page parked because the viewport was still in motion when it
  /// arrived (arrival hold, or the prepend-frame re-checks). Flushed by
  /// [flushHeld] after the true ScrollEnd.
  ({
    ConversationState state,
    List<Map<String, dynamic>> older,
    bool? hasMore,
  })? _pendingOlderPage;

  /// Invalidation epoch for anchor-compensation chains: incremented on every
  /// prepend commit; a chain whose captured generation is no longer current
  /// dies before its landing.
  int _anchorGeneration = 0;

  /// Chain counter readout for the controller tests (invariant 10: the bump
  /// happens BEFORE the duplicate verdict). Not part of the host surface.
  @visibleForTesting
  int get anchorGeneration => _anchorGeneration;

  /// True from a prepend until its anchor compensation chain settles (lands,
  /// gives up, or dies with no viewport). Between the prepend and the landing
  /// the viewport sits at the UN-compensated offset — still inside the
  /// trigger window — and a re-fire there would stale-drop its own chain and
  /// leave the content shift uncompensated.
  bool _compensationPending = false;

  /// Re-entry gate readout for the host's streaming follow (skip while a
  /// prepend chain owns the viewport).
  bool get compensationInFlight => _compensationPending;

  /// Turn-navigator jump gate: no drag, no compensation chain, no
  /// programmatic scroll.
  bool get canJumpToQuery =>
      !_userDragActive && !_compensationPending && !_positioning;

  /// True while a PROGRAMMATIC scroll (the open/follow glide, jump-to-bottom,
  /// keyboard catch-up, a compensation landing) carries the viewport. The
  /// host's pinned verdict reads it to tell its own motion from the reader's:
  /// a follow sweeping through the middle of the list is not the reader
  /// leaving the bottom (A7 device acceptance, 2026-10-29 — the mid-flight
  /// `stick=false` sample used to stick, and the open auto-load's prepend then
  /// anchored to the reading position instead of the newest end).
  bool get isPositioning => _positioning;

  /// Last page's MEASURED content shift — pure prepend height with every
  /// viewport movement cancelled out. The next prepend's cache pre-widen and
  /// the give-up fallback consume it.
  double? _lastMeasuredDelta;

  /// Temporary oversize cacheExtent for the anchor compensation (null =
  /// platform default). The host ListView reads it as
  /// `viewport.anchorCacheExtent ?? <jump extent>`; flips notify listeners.
  double? _anchorCacheExtent;
  double? get anchorCacheExtent => _anchorCacheExtent;

  // ------------------------------------------------------------ veil state

  final ValueNotifier<TranscriptVeilState> _veil =
      ValueNotifier(const TranscriptVeilState.none());

  /// Veil channel for [TranscriptVeil] — a separate listenable so veil frames
  /// rebuild only the Opacity/RawImage subtree, never the list rows.
  ValueListenable<TranscriptVeilState> get veil => _veil;

  bool get _veiled => _veil.value.phase == TranscriptVeilPhase.frozen;

  // ------------------------------------------------------------- assembly

  /// Production assembly: takes the host's controller + measurement keys and
  /// installs the default measurement/capture/landing implementations (an
  /// injected test port wins over the default). Scroll notifications still
  /// arrive through the host's NotificationListener.
  ///
  /// [groupRows] lets the detail page group through `childSessionRows`; chat
  /// omits it (plain `groupChatRows`).
  void attach({
    required ScrollController controller,
    required GlobalKey listKey,
    required GlobalKey freezeKey,
    List<List<Map<String, dynamic>>> Function(List<Map<String, dynamic>>)?
        groupRows,
  }) {
    _controller = controller;
    _freezeKey = freezeKey;
    _elementPort = _ElementMeasurePort(
      listKey: listKey,
      controller: controller,
      groupRows: groupRows ?? groupChatRows,
    );
  }

  TranscriptMeasurePort? get _measure => _injectedMeasure ?? _elementPort;

  ScrollSample? _positionOrNull() {
    final measure = _measure;
    final controller = _controller;
    if (controller != null && !controller.hasClients) return null;
    if (measure != null) {
      try {
        return measure.position();
      } catch (_) {
        return null;
      }
    }
    if (controller == null || !controller.hasClients) return null;
    final p = controller.position;
    return (
      pixels: p.pixels,
      maxScrollExtent: p.maxScrollExtent,
      viewportDimension: p.viewportDimension,
    );
  }

  bool get _scrollIdle => !_userDragActive && _scrollSettled;

  // ------------------------------------------------------- scroll routing

  /// Host `NotificationListener` forwarding, unchanged. Identity routing is
  /// re-done here: nested scrollables (diff cards, expanded code blocks) must
  /// not fire history loads. Without an attached controller (pure controller
  /// tests) there is no position to route by — the notification is applied
  /// as-is.
  void onScrollNotification(ScrollNotification n) {
    if (_disposed) return;
    final controller = _controller;
    if (controller != null) {
      if (!controller.hasClients) return;
      final notificationContext = n.context;
      final scrollable = notificationContext == null
          ? null
          : Scrollable.maybeOf(notificationContext);
      if (scrollable == null ||
          !identical(scrollable.position, controller.position)) {
        return;
      }
    }
    if (n is ScrollStartNotification) {
      // dragDetails != null → a user drag starts; null → programmatic
      // activity (jumpTo / animateTo).
      if (n.dragDetails != null && _veiled) _liftVeil();
      _pullArmed = false;
      _userDragActive = n.dragDetails != null;
      _positioning = n.dragDetails == null;
    } else if (n is ScrollUpdateNotification) {
      if (_veiled) _liftVeil();
      _scrollSettled = false;
      final pixels = n.metrics.pixels;
      // The first non-drag update after a drag is the release frame
      // (RefreshIndicator's pattern) — the finger is up again, so deferred
      // anchor compensation may resume.
      if (n.dragDetails == null) _userDragActive = false;
      // Prefetch window (official web parity). Programmatic frames and the
      // pull gesture don't count: a jump's pixel sweep is not reading, and a
      // sub-threshold pull must release into a silent bounce.
      final inWindow =
          pixels <= math.max(64.0, n.metrics.viewportDimension * 2);
      final userDriven = n.dragDetails != null
          ? pixels >= 0 // live drag: negative = mid-pull overscroll
          : pixels > 0 && !_positioning;
      if (inWindow && userDriven) _prefetchOlder();
      if (n.dragDetails != null) {
        _pullArmed = pixels <= -_kPullThreshold;
      } else if (_pullArmed && pixels <= -_kPullThreshold) {
        _pullArmed = false;
        if (!_loadingOlder) unawaited(loadOlder());
      }
    } else if (n is ScrollEndNotification) {
      _positioning = false;
      _userDragActive = false;
      _scrollSettled = true;
      flushHeld();
    }
  }

  /// Scroll-proximity prefetch entry (guarded by the caller).
  void _prefetchOlder() {
    final state = currentState();
    if (state == null || !state.canLoadOlder || _loadingOlder) return;
    unawaited(loadOlder());
  }

  // ----------------------------------------------------------------- load

  /// Loads one older page — the single entry ALL four triggers (open
  /// auto-load / prefetch window / pull release / button) funnel into.
  Future<void> loadOlder() async {
    final state = currentState();
    final sessionId = currentSessionId();
    if (state == null ||
        sessionId == null ||
        _loadingOlder ||
        _compensationPending) {
      return;
    }
    _setLoading(true);
    final request = (state: state, sessionId: sessionId);
    // Post-frame so the list has actually mounted (the subscribe microtask
    // chain can beat the first build); the anchor itself is measured fresh
    // right before the prepend applies the page.
    postFrame(() {
      if (_disposed) return;
      unawaited(_settle(request));
    });
  }

  /// The deferred body of the load — fetches the page, then parks it for the
  /// drag-hold flush, applies it through the prepend chain, or reports
  /// [HistoryNoOlder] / [HistoryStale] / [HistoryFailed].
  Future<void> _settle(
      ({ConversationState state, String sessionId}) request) async {
    final state = request.state;
    try {
      // Cursor = the oldest row actually held (state.oldestRowId). The
      // snapshot `firstRowId` can be a placeholder (live-probed 1) — using
      // it re-fetched the newest window and the button spun forever.
      final res = await fetch(
        request.sessionId,
        beforeRowId: state.oldestRowId,
        limit: 60,
      );
      // Identity guard: a resubscribe swapped the state out from under this
      // fetch — its page belongs to a state nobody shows.
      if (res is Map && state != currentState()) {
        debugPrint('[anchor] drop page: state replaced (resubscribe)');
        return;
      }
      final page = parseRowsRangeResponse(res, state: state);
      // The window is dropped when its log epoch no longer matches the live
      // subscription — but the rows are immutable log entries; apply anyway
      // and keep the toast as a trace (round 23).
      if (!page.epochMatches) {
        debugPrint('[anchor] epoch drift on fetched page '
            '(at=${page.atLogEpoch} live=${state.logEpoch}) — applying anyway');
        _emit(const HistoryStale());
      }
      final older = page.rows;
      if (older != null && older.isNotEmpty) {
        // DRAG HOLD: while the viewport is still IN MOTION the prepend
        // cannot be compensated (no landing may jump under a live gesture,
        // and unhedged the anchor lands outside the cache extent). Park the
        // page until the true ScrollEnd.
        if (!_scrollIdle) {
          _pendingOlderPage = (
            state: state,
            older: older,
            hasMore: page.hasMore,
          );
          return; // finally keeps the loading gate up — no duplicate fetch
        }
        // The re-entry gate closes HERE, not inside the post-frame prepend:
        // the loading gate clears in the finally below (same microtask), and
        // a coasting prefetch firing in the frame between would pass both
        // gates and re-fire on the SAME cursor (round 15).
        _compensationPending = true;
        postFrame(() {
          if (_disposed) return;
          unawaited(_prependPage(state, older, page.hasMore));
        });
      } else if (state.rows.isNotEmpty) {
        state.hasMore = page.hasMore ?? false;
        _emit(const HistoryNoOlder());
      }
    } catch (e) {
      _emit(HistoryFailed(e));
    } finally {
      if (_pendingOlderPage == null) {
        _setLoading(false);
      }
    }
  }

  /// Prepend-frame DRAG HOLD recheck, called right before measuring (and
  /// again after the frozen-frame capture): the arrival verdict can be one
  /// frame stale — a slow reader's rhythm is stop-and-go. Returns true when
  /// the page was parked and the caller must abort.
  bool _parkPrependIfBusy(
    ConversationState state,
    List<Map<String, dynamic>> older,
    bool? hasMore,
  ) {
    if (_scrollIdle) return false;
    _pendingOlderPage = (state: state, older: older, hasMore: hasMore);
    // The arrival path already lowered the loading gate — raise it back, or
    // the one-frame gap lets a prefetch re-fire on the same cursor.
    _setLoading(true);
    return true;
  }

  /// Applies a fetched history page: hold recheck → capture the frozen frame
  /// → hold recheck again → measure the anchor → commit → veil + post-frame
  /// compensation. Every terminal exit either lands or releases the re-entry
  /// gate.
  Future<void> _prependPage(
    ConversationState state,
    List<Map<String, dynamic>> older,
    bool? hasMore,
  ) async {
    if (_disposed) return;
    if (_parkPrependIfBusy(state, older, hasMore)) return;
    // FROZEN FRAME (round 24): capture the list's CURRENT paint before the
    // prepend applies — the plain veil replaced the list with a blank for
    // 1-2 frames and read as a full-screen black flash on device. A failed
    // capture (no boundary / capture error) downgrades the chain to the
    // visible-landing path: a misplaced list beats a blank one.
    final frozen = await _captureFrozenFrame();
    if (_disposed) {
      frozen?.dispose();
      return;
    }
    // The capture is async (GPU read-back): re-check the hold AFTER the gap.
    if (_parkPrependIfBusy(state, older, hasMore)) {
      frozen?.dispose();
      return;
    }
    final anchor = _measureAnchor(state);
    final outcome = _commitPrepend(state, older, hasMore);
    final gen = outcome.generation;
    if (outcome.inserted == 0) {
      // Duplicate page: a re-fire raced this chain's prepend window. Nothing
      // shifted — anchoring a no-op prepend pre-jumps the view a full page
      // out and the landing drags it all the way back (round 14).
      debugPrint('[anchor] duplicate page dropped');
      _compensationPending = false;
      frozen?.dispose();
      return;
    }
    if (anchor == null) {
      // No measurable anchor (unmounted list / empty groups): release the
      // re-entry gate — the prepend stands uncompensated.
      _compensationPending = false;
      frozen?.dispose();
      return;
    }
    final position = _positionOrNull();
    // Pre-widen the layout cache WITH the data change: the anchor sits ~one
    // page below the offset after the prepend, beyond the ~250px default
    // cache. Predicted from the last page's measured height (round 21).
    double? preWiden;
    if (!anchor.stick && _lastMeasuredDelta != null && position != null) {
      preWiden =
          preWidenExtent(_lastMeasuredDelta!, position.viewportDimension);
    }
    _anchorCacheExtent = preWiden;
    _veil.value = frozen == null
        ? const TranscriptVeilState.none()
        : TranscriptVeilState.frozen(frozen);
    _notify();
    postFrame(() {
      if (_disposed) return;
      if (_positionOrNull() == null) {
        _compensationPending = false;
        _liftVeil();
        return;
      }
      _compensateAnchor(anchor, hop: 0, gen: gen, chainState: state);
    });
  }

  /// Bumps the chain generation, writes `hasMore` back and prepends (dedupe
  /// inside [ConversationState.prependOlderRows]). The generation bumps
  /// BEFORE the duplicate verdict — the chain it would have served is stale
  /// either way.
  ({int generation, int inserted}) _commitPrepend(
    ConversationState state,
    List<Map<String, dynamic>> older,
    bool? hasMore,
  ) {
    final generation = ++_anchorGeneration;
    state.hasMore = hasMore;
    final inserted = state.prependOlderRows(older);
    return (generation: generation, inserted: inserted);
  }

  /// Flushes a drag-held page once the scroll has truly ended. If an earlier
  /// chain's compensation is still pending, waits a frame for it to settle —
  /// two prepends without a landing in between would stack un-compensated
  /// offsets. The flush frame opens the loading gate immediately before the
  /// prepend runs (round 14 ordering).
  void flushHeld() {
    final page = _pendingOlderPage;
    if (page == null) return;
    if (page.state != currentState()) {
      // The subscription was rebuilt under us: the held page belongs to a
      // state nobody shows — drop it, release the loading gate.
      _pendingOlderPage = null;
      _setLoading(false);
      return;
    }
    if (_compensationPending) {
      postFrame(() {
        if (!_disposed) flushHeld();
      });
      return;
    }
    _pendingOlderPage = null;
    postFrame(() {
      if (_disposed) return;
      _setLoading(false);
      unawaited(_prependPage(page.state, page.older, page.hasMore));
    });
  }

  // ------------------------------------------------------------- capturing

  Future<ui.Image?> _captureFrozenFrame() async {
    final capture = _injectedCapture ?? (_freezeKey == null ? null : _capture);
    if (capture == null) return null;
    try {
      return await capture();
    } catch (_) {
      return null;
    }
  }

  /// Production capture: the [RepaintBoundary] injected through [attach].
  /// `debugNeedsPaint` (a repaint scheduled but not yet painted — the loading
  /// spinner frame on a slow device) skips the capture; a raster error
  /// downgrades to null.
  Future<ui.Image?> _capture() async {
    final boundary = _freezeKey?.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || boundary.debugNeedsPaint) {
      return null;
    }
    final ratio =
        WidgetsBinding.instance.platformDispatcher.implicitView?.devicePixelRatio ??
            3.0;
    try {
      return await boundary.toImage(pixelRatio: ratio);
    } catch (_) {
      return null;
    }
  }

  /// Lifts the veil (idempotent, safe from every terminal exit and scroll
  /// notification) and drops the frozen frame; its disposal waits one frame
  /// so the layer that already painted it lets go first.
  void _liftVeil() {
    final state = _veil.value;
    if (state.phase == TranscriptVeilPhase.none) return;
    _veil.value = const TranscriptVeilState.none();
    final frame = state.image;
    if (frame != null) {
      postFrame(() => frame.dispose());
    }
  }

  // ------------------------------------------------------------- measuring

  _Anchor? _measureAnchor(ConversationState state) {
    final measure = _measure;
    final position = _positionOrNull();
    if (measure == null || position == null) return null;
    final viewport = measure.viewportBox();
    if (viewport == null) return null;
    final viewportTop = viewport.top;
    final allGroups = measure.groupRows(state.rows);
    if (allGroups.isEmpty) return null;
    // Extent BEFORE the prepend (measured pre-fetch, hence converged): the
    // compensation's coarse first hop re-derives the estimate delta from it.
    final baseMax = position.maxScrollExtent;
    final stick = isStickToBottom();
    final groups = measure.builtGroups();
    if (groups.isEmpty) return null;
    var anchorIdx = -1;
    for (var i = 0; i < groups.length; i++) {
      if (groups[i].top >= viewportTop - 40) {
        anchorIdx = i;
        break;
      }
    }
    anchorIdx = anchorIdx < 0 ? groups.length - 1 : anchorIdx;
    // Retreat to the nearest STABLE group at/above the reading position: a
    // group keyed by a non-user first row merges away when a rowsRange page
    // boundary splits a turn (the prepend re-groups, the first rowId changes,
    // the key orphans and the compensation used to hop to the list end —
    // the 09-21 "yanked to the bottom" device report). A userInput or
    // timelineMarker first can only ever gain rows ABOVE its first row,
    // never lose it, so its key survives any prepend.
    var stableIdx = anchorIdx;
    while (stableIdx >= 0) {
      final firstKind = groups[stableIdx].rows.first['kind'];
      if (firstKind == 'timelineMarker' || firstKind == 'userInput') break;
      stableIdx--;
    }
    final useIdx = stableIdx >= 0 ? stableIdx : anchorIdx;
    final group = groups[useIdx];
    if (kDebugMode) {
      debugPrint('[anchor] measure stick=$stick key=${group.key} '
          'rowIds=${group.rows.map((r) => r['rowId']).toList()} '
          'retreated=${useIdx != anchorIdx}');
    }
    // Row-level anchor (exact landing when the group's key orphans to a
    // page-boundary merge): measure the first row's own box now so the
    // compensation can land on IT instead of the merged group's top.
    final rowKey = ValueKey('row-${group.rows.first['rowId']}');
    final rowBox = measure.rowBox(rowKey);
    return (
      key: group.key,
      rowIds: group.rows.map((r) => r['rowId']).whereType<num>().toSet(),
      dy: group.top - viewportTop,
      stick: stick,
      // Pinned landing target: the TRUE newest group, measured too — if the
      // user scrolled away from the bottom while the page loaded, the
      // landing demotes to the reading anchor instead (round 8).
      endKey: stick ? ValueKey('turn-${allGroups.last.first['rowId']}') : null,
      baseMax: baseMax,
      rowKey: rowKey,
      rowDy: rowBox == null ? null : rowBox.top - viewportTop,
      measurePixels: position.pixels,
    );
  }

  // ----------------------------------------------------------- compensating

  /// Post-prepend compensation: re-find the anchor group, measure its real
  /// position and jump by the measured delta — maxScrollExtent plays no part
  /// in the LANDING, so row-height variance cannot skew it. Every branch is
  /// a byte-for-byte transplant of the chat page's chain (rounds 3-24),
  /// including the hop chain, the 120000 cache cap, the 0.85× give-up and
  /// the 96-180ms visible-landing easing.
  void _compensateAnchor(
    _Anchor anchor, {
    required int hop,
    int? gen,
    ConversationState? chainState,
  }) {
    if (_disposed) return;
    // Stale chains die here: a newer load's commit already superseded this
    // one — an older chain landing later would stack a jump on top of it.
    if (gen != null && gen != _anchorGeneration) {
      _setAnchorCacheExtent(null);
      _liftVeil();
      debugPrint('[anchor] stale gen=$gen dropped');
      return;
    }
    // No stale return below this point: every remaining exit is terminal for
    // this chain, so each clears the re-entry gate.
    if (_userDragActive) {
      // A drag arrived under the veil: show the list while the chain waits
      // the finger out; the landing's correction then runs visible and eases.
      _liftVeil();
      // A drag is when the widened cache costs the most: every frame lays
      // out the whole (up to 120000px) window the compensation pre-widened.
      // Drop it while the chain parks on the finger — but ONLY when no hop
      // widen has happened yet (hop 0): a hop>0 chain is mid-hunt and its
      // wide window is what keeps the anchor laid out, so clearing it there
      // downgrades the landing to the give-up estimate. At hop 0 the release
      // re-measures and re-widens on demand, so landing precision is
      // unchanged (task 11-19 step 2; anchor regression in
      // transcript_viewport_test).
      if (hop == 0) _setAnchorCacheExtent(null);
      postFrame(() {
        if (_disposed || _positionOrNull() == null) return;
        _compensateAnchor(anchor, hop: hop, gen: gen, chainState: chainState);
      });
      return;
    }
    // Our own programmatic scroll is carrying the viewport: its motion must
    // not read as user drift, or the landing surrenders off a phantom
    // (round 15). A STICK chain does not wait — its measured endKey landing
    // is the authoritative bottom. A READING chain waits the motion out and
    // re-measures the anchor from the settled position.
    if (chainState != null && _positioning && !anchor.stick) {
      _liftVeil();
      postFrame(() {
        if (_disposed || _positionOrNull() == null) return;
        if (_positioning) {
          _compensateAnchor(anchor,
              hop: hop, gen: gen, chainState: chainState);
          return;
        }
        final fresh = _measureAnchor(chainState);
        _compensateAnchor(fresh ?? anchor, hop: hop, gen: gen);
      });
      return;
    }
    final measure = _measure;
    final viewport = measure?.viewportBox();
    final position = _positionOrNull();
    if (measure == null || viewport == null || position == null) {
      _compensationPending = false;
      _liftVeil();
      return;
    }
    // Mid rubber-band rebound (pixels outside [0, max] right after the finger
    // lifted): landing from that moving baseline kills the rebound and reads
    // as a yank. The rebound converges within a few frames — re-check then.
    if (position.pixels < 0 || position.pixels > position.maxScrollExtent) {
      _liftVeil();
      postFrame(() {
        if (_disposed || _positionOrNull() == null) return;
        _compensateAnchor(anchor, hop: hop, gen: gen, chainState: chainState);
      });
      return;
    }
    // Stick demotion: judged by the offset's drift from measure time, not by
    // the page's sticky flag — the prepend itself grows max and flips that
    // flag without any user movement.
    final landingStick = landingIsStick(
      anchorStick: anchor.stick,
      positioning: _positioning,
      s: (
        top: 0,
        dy: 0,
        viewportTop: 0,
        pixels: position.pixels,
        measurePixels: anchor.measurePixels,
        maxScrollExtent: position.maxScrollExtent,
      ),
    );
    final landingKey = landingStick ? anchor.endKey! : anchor.key;
    final groups = measure.builtGroups();
    ({double top, double height})? box;
    for (final group in groups) {
      if (group.key == landingKey) {
        box = (top: group.top, height: group.height);
        break;
      }
    }
    // Landing base: the anchor group normally. When its key orphaned to a
    // page-boundary merge, land on the anchor ROW's own box (exact — rows
    // survive any re-group) if it was measurable at anchor time.
    var rowLanding = false;
    if (box == null && anchor.rowKey != null && anchor.rowDy != null) {
      final rowBox = measure.rowBox(anchor.rowKey!);
      if (rowBox != null) {
        box = rowBox;
        rowLanding = true;
        debugPrint('[anchor] row landing ${anchor.rowKey}');
      }
    }
    if (box == null) {
      for (final group in groups) {
        final ids = group.rows.map((r) => r['rowId']).whereType<num>();
        if (ids.any(anchor.rowIds.contains)) {
          box = (top: group.top, height: group.height);
          debugPrint('[anchor] rowId fallback -> ${group.key}');
          break;
        }
      }
    }
    if (box == null) {
      if (groups.isEmpty) {
        // Parked past the real content end (nothing laid out = blank
        // viewport): step back into range instead of staying stuck.
        _land(math.max(0.0, position.maxScrollExtent));
        _compensationPending = false;
        _liftVeil();
        return;
      }
      if (hop == 0) {
        // Anchor not built: widen the cache for one frame so SliverList lays
        // out down to the anchor's expected depth. Measured landing follows;
        // no pixel is ever jumped by estimate.
        final need = hopCacheNeed(
          maxScrollExtent: position.maxScrollExtent,
          baseMax: anchor.baseMax,
          viewportHeight: viewport.height,
        );
        _setAnchorCacheExtent(need);
        postFrame(() {
          if (_disposed) return;
          if (_positionOrNull() == null) {
            _compensationPending = false;
            _liftVeil();
            return;
          }
          _compensateAnchor(anchor,
              hop: hop + 1, gen: gen, chainState: chainState);
        });
        return;
      }
      // Still not found with the widened cache: the key orphaned AND its row
      // isn't an independently-keyed widget AND the rowIds fallback matched
      // nothing built. Land by the last page's MEASURED height (0.85-fold)
      // instead of compounding an uncompensated prepend into the NEXT
      // landing. Skipped while the viewport is in motion; the veil lifts
      // either way — the reader must never be left staring at a blank list.
      debugPrint('[anchor] give up hop=$hop pixels='
          '${position.pixels.toStringAsFixed(1)} builtGroups='
          '${groups.length}');
      _setAnchorCacheExtent(null);
      // At the very head the reader is looking at the FRESH page — an
      // estimated jump there leaps somewhere they never chose (round 21).
      final giveUp = giveUpLanding(
        anchorStick: anchor.stick,
        lastMeasuredDelta: _lastMeasuredDelta,
        userDragActive: _userDragActive,
        scrollSettled: _scrollSettled,
        pixels: position.pixels,
      );
      if (giveUp != null) {
        _land(clampLanding(giveUp, position.maxScrollExtent));
      }
      _compensationPending = false;
      _liftVeil();
      return;
    }
    final viewportTop = viewport.top;
    final viewportBottom = viewportTop + viewport.height;
    final top = box.top;
    final dy = rowLanding ? anchor.rowDy! : anchor.dy;
    final sample = (
      top: top,
      dy: dy,
      viewportTop: viewportTop,
      pixels: position.pixels,
      measurePixels: anchor.measurePixels,
      maxScrollExtent: position.maxScrollExtent,
    );
    final double target;
    if (landingStick) {
      target = stickLanding(
        s: sample,
        boxBottom: top + box.height,
        viewportBottom: viewportBottom,
        listBottomPadding: listBottomPadding,
      );
    } else {
      target = readingLanding(sample);
    }
    debugPrint('[anchor] LAND hop=$hop stick=$landingStick veiled=$_veiled'
        ' key=$landingKey pixels=${position.pixels.toStringAsFixed(1)} -> '
        '${target.toStringAsFixed(1)}');
    if (!landingStick) {
      // TRUE content shift of this prepend (see [measuredDelta]) — feeds the
      // NEXT prepend's cache pre-widen and the give-up fallback.
      _lastMeasuredDelta = measuredDelta(sample);
    }
    _setAnchorCacheExtent(null);
    _compensationPending = false;
    final clamped = clampLanding(target, position.maxScrollExtent);
    if (_veiled) {
      // Veiled transit: the offset's trip to the landing happened off
      // screen, so land exactly and lift in the same frame (round 21).
      _land(clamped);
      _liftVeil();
      return;
    }
    // VISIBLE landing: small reading corrections ANIMATE instead of
    // teleporting (round 12); pinned landings and far corrections snap.
    final correction = (clamped - position.pixels).abs();
    _land(clamped,
        duration: visibleLandingDuration(correction, stick: landingStick));
  }

  /// Landing dispatch: the injected sink when present, else the attached
  /// controller.
  void _land(double target, {Duration? duration}) {
    if (_disposed) return;
    final landing = _injectedLanding;
    if (landing != null) {
      landing(target, duration: duration);
      return;
    }
    final controller = _controller;
    if (controller == null || !controller.hasClients) return;
    if (duration == null) {
      controller.jumpTo(target);
    } else {
      controller.animateTo(target, duration: duration, curve: Curves.easeOut);
    }
  }

  // ------------------------------------------------------- state plumbing

  void _setLoading(bool value) {
    if (_disposed) return;
    _loadingOlder = value;
    notifyListeners();
  }

  void _setAnchorCacheExtent(double? value) {
    if (_disposed || _anchorCacheExtent == value) return;
    _anchorCacheExtent = value;
    notifyListeners();
  }

  void _emit(HistoryToastStep step) {
    if (_disposed) return;
    onToast(step);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    final image = _veil.value.image;
    _veil.value = const TranscriptVeilState.none();
    image?.dispose();
    _veil.dispose();
    _controller = null;
    super.dispose();
  }
}

/// The prepend veil (round 21 + round 24): between the prepend's first frame
/// and the measured landing the list paints transparent behind the LAST
/// pre-prepend paint (the frozen frame), so the reader sees the same pixels
/// standing still for a frame or two, then the landed view — nothing goes
/// blank, nothing teleports.
///
/// Shape contract (task 10-29-transcript-viewport, design §6 — the existing
/// chat_page_test veil assertions depend on it): `Stack(fit: passthrough)` →
/// `RepaintBoundary(freezeKey)` → `Opacity` (ALWAYS present, only the value
/// flips) → [child]; the frozen frame is a `Positioned.fill(RawImage)` on
/// top, mounted only while a capture exists (a plain veil without a frozen
/// frame is the device black flash — forbidden).
class TranscriptVeil extends StatelessWidget {
  const TranscriptVeil({
    super.key,
    required this.viewport,
    required this.child,
  });

  final TranscriptViewport viewport;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TranscriptVeilState>(
      valueListenable: viewport.veil,
      child: child,
      builder: (context, state, list) {
        return Stack(
          fit: StackFit.passthrough,
          children: [
            RepaintBoundary(
              key: viewport.freezeKey,
              child: Opacity(
                opacity:
                    state.phase == TranscriptVeilPhase.frozen ? 0.0 : 1.0,
                child: list,
              ),
            ),
            if (state.image != null)
              Positioned.fill(
                child: RawImage(
                  image: state.image,
                  fit: BoxFit.fill,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// The measured reading anchor for one prepend (mirror of the chat page's
/// `_HistoryAnchor`).
typedef _Anchor = ({
  Key key,
  Set<num> rowIds,
  double dy,
  bool stick,
  Key? endKey,
  double baseMax,
  Key? rowKey,
  double? rowDy,
  // Offset at measure time: lets the compensation derive the TRUE content
  // shift of the prepend (drags during the chain's wait cancel out).
  double measurePixels,
});

/// Production [TranscriptMeasurePort]: walks the Element tree under the list
/// key (SliverList keeps only the viewport plus its cacheExtent alive, which
/// is exactly why the compensation sometimes has to hop).
class _ElementMeasurePort implements TranscriptMeasurePort {
  _ElementMeasurePort({
    required this.listKey,
    required this.controller,
    required List<List<Map<String, dynamic>>> Function(
            List<Map<String, dynamic>>) groupRows,
  }) : _groupRows = groupRows;

  final GlobalKey listKey;
  final ScrollController controller;
  final List<List<Map<String, dynamic>>> Function(List<Map<String, dynamic>>)
      _groupRows;

  @override
  ({double top, double height})? viewportBox() {
    // The message list's viewport-sized render box (Listener/GestureDetector
    // wrap the viewport exactly), or null when nothing is laid out.
    final box = listKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return (top: box.localToGlobal(Offset.zero).dy, height: box.size.height);
  }

  @override
  List<GroupMeasurement> builtGroups() {
    final groups = <GroupMeasurement>[];
    final listContext = listKey.currentContext;
    if (listContext == null) return groups;
    void visit(Element element) {
      final widget = element.widget;
      if (widget is ChatTurnGroup) {
        final box = element.findRenderObject();
        if (widget.key != null &&
            box is RenderBox &&
            box.attached &&
            box.hasSize) {
          groups.add((
            key: widget.key!,
            rows: widget.rows,
            top: box.localToGlobal(Offset.zero).dy,
            height: box.size.height,
          ));
        }
        return;
      }
      element.visitChildElements(visit);
    }

    listContext.visitChildElements(visit);
    return groups;
  }

  @override
  ({double top, double height})? rowBox(Key rowKey) {
    ({double top, double height})? found;
    final listContext = listKey.currentContext;
    if (listContext == null) return null;
    void visit(Element element) {
      if (found != null) return;
      final widget = element.widget;
      if (widget is ChatRow || widget is ToolGroupCard) {
        if (widget.key == rowKey) {
          final box = element.findRenderObject();
          if (box is RenderBox && box.attached && box.hasSize) {
            found =
                (top: box.localToGlobal(Offset.zero).dy, height: box.size.height);
          }
        }
        return;
      }
      element.visitChildElements(visit);
    }

    listContext.visitChildElements(visit);
    return found;
  }

  @override
  ScrollSample position() {
    final p = controller.position;
    return (
      pixels: p.pixels,
      maxScrollExtent: p.maxScrollExtent,
      viewportDimension: p.viewportDimension,
    );
  }

  @override
  List<List<Map<String, dynamic>>> groupRows(
          List<Map<String, dynamic>> rows) =>
      _groupRows(rows);
}
