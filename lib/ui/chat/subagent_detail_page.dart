import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show RenderRepaintBoundary, ScrollCacheExtent;

import '../../protocol/conversation.dart';
import '../../state/device_session.dart';
import '../theme.dart';
import '../ui_settings.dart';
import 'jump_to_bottom_button.dart';
import 'subagent_feed.dart';
import 'timeline.dart';

/// Read-only transcript of a subagent's child session (task 09-13 R3):
/// the server treats `sess_subagent_agent_*` as a plain Conversation V4
/// session, so this page renders [childSessionId] through the main chat's
/// shared renderer ([ChatTurnGroup]/[ChatRow] — official parity: the web's
/// subagent pane reuses the conversation renderer readOnly) via the chat
/// page's shared [SubagentFeed] pool (acquire/release refcount) — it never
/// opens a private subscription, so Agent tile / sheet / this page share
/// ONE `gateway.subscribe` per child.
///
/// Read-only boundary (R4): no composer and nothing is ever sent to the
/// child session — every send-shaped affordance the shared renderer has is
/// gated off via its `readOnly` flag; the only write is stopping the
/// parent session's background work entry while the subagent runs.
class SubagentDetailPage extends StatefulWidget {
  final ChatGateway gateway;

  /// Shared child-session subscription pool owned by the chat page; this
  /// page only acquires/releases its reference.
  final SubagentFeed feed;

  /// Child session id (`sess_subagent_agent_*`) to subscribe to.
  final String childSessionId;

  /// AppBar label: [title] (works/running entry) falls back to
  /// [subagentType], then the generic agents label.
  final String? title;
  final String? subagentType;

  /// Parent-session ids for the stop action (running subagents only);
  /// `workId` equals the subagent's agentId (live-probed 2026-09-13).
  final String? parentSessionId;
  final String? workId;
  final bool running;

  /// Terminal-footer confirm window for the shared timeline render (D3
  /// pre-wiring): entry points that know the chat page's
  /// `turnFooterConfirmWindow` pass it through; everything else leaves it
  /// null and [effectiveConfirmWindow] falls back to the chat default.
  final Duration? confirmWindow;

  /// [confirmWindow] fallback — the chat page's own default window.
  Duration get effectiveConfirmWindow =>
      confirmWindow ?? const Duration(seconds: 3);

  const SubagentDetailPage({
    super.key,
    required this.gateway,
    required this.feed,
    required this.childSessionId,
    this.title,
    this.subagentType,
    this.parentSessionId,
    this.workId,
    this.running = false,
    this.confirmWindow,
  });

  @override
  State<SubagentDetailPage> createState() => _SubagentDetailPageState();
}

/// Reading anchor captured before a prepend (miniature of the chat page's
/// `_HistoryAnchor`): stable-group key + row ids + the group's measured
/// viewport-relative dy and the extent at measure time.
typedef _ReadingAnchor = ({
  Key key,
  Set<num> rowIds,
  double dy,
  double baseMax,
});

class _SubagentDetailPageState extends State<SubagentDetailPage> {
  String? _error;
  bool _loadingOlder = false;
  Timer? _readyTimeout;

  // History-load triggers (design D2, chat-page semantics minus the
  // rubber-band): one open auto-fill, drag-driven top-window prefetch, and
  // a lite drag-hold that parks a mid-gesture page until ScrollEnd.
  bool _autoFilled = false;
  bool _scrollActive = false;

  /// Fetched-but-held page ([_loadOlder] drag-hold): landing a prepend
  /// under the reader's finger yanks the viewport, so the page waits for
  /// ScrollEnd. [_loadingOlder] stays armed through the landing (same
  /// cursor must not be fetched twice).
  ({ConversationState state, RowsRangePage page})? _pendingPage;

  // Scroll trio matching the chat page (task 09-23 R1): stick detection on
  // the controller listener, initial landing on the newest row, and
  // smooth follow while new rows stream in.
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _listKey = GlobalKey();
  bool _stickToBottom = true;
  bool _positionedAtBottom = false;
  int _lastRowCount = 0;

  // Prepend anchor compensation (design D2, a miniature of the chat page's
  // chain — same spec §9 discipline; the 10-15 revision additionally ports
  // the chat page's round-24 frozen frame + veil, still minus the generation
  // machinery a single load path doesn't need): widened cache while the
  // anchor resurfaces (`null` = platform default), and the previous page's
  // measured height as the next landing's headroom (first landing uses the
  // design's 4000).
  double? _anchorCacheExtent;
  double? _lastPageExtent;

  /// Prepend veil + frozen frame (design D2 10-15 revision, chat-page
  /// round-24 twin): between the prepend and the measured landing the list
  /// paints transparent ([_listVeiled]) while [_frozenFrame] — the capture
  /// of the last pre-prepend paint — stands still on top. The plain veil
  /// alone is FORBIDDEN: on device it read as a full-screen black flash
  /// (dark theme, OLED, 1-2 frames), so the veil is only ever armed together
  /// with a captured frame, and a failed capture downgrades the chain to the
  /// visible-landing path (a misplaced list beats a blank one).
  bool _listVeiled = false;
  ui.Image? _frozenFrame;

  /// [RepaintBoundary] around the list — the capture source for
  /// [_frozenFrame].
  final GlobalKey _freezeKey = GlobalKey();

  /// Workspace file-preview plumbing for the shared renderer (tappable
  /// file names in tool cards). One instance per page, like the chat page.
  late final ChatPreview _preview = ChatPreview(widget.gateway);

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    widget.feed.acquire(widget.childSessionId);
    _armReadyTimeout();
  }

  @override
  void dispose() {
    _readyTimeout?.cancel();
    widget.feed.release(widget.childSessionId);
    _scrollController.dispose();
    _frozenFrame?.dispose();
    super.dispose();
  }

  void _onScroll() {
    final stick = _isStuckToBottom();
    // Only a flip of the pinned state rebuilds (it toggles the
    // jump-to-bottom button); steady scrolling stays free.
    if (stick == _stickToBottom) return;
    if (mounted) setState(() => _stickToBottom = stick);
  }

  /// Live pinned-to-bottom check (40px slack, chat-page threshold).
  /// Post-frame callers must use this instead of the cached
  /// [_stickToBottom]: prepending older rows grows only maxScrollExtent
  /// (pixels unchanged → no controller notification), which would leave
  /// the cache stale.
  bool _isStuckToBottom() {
    if (!_scrollController.hasClients) return false;
    final position = _scrollController.position;
    return position.pixels >= position.maxScrollExtent - 40;
  }

  /// Streaming follow (R1c): smooth-scroll to the new bottom while the
  /// reader is pinned to it; scrolled-up readers keep their position and use
  /// the jump button to come back. Prepending older history ([_loadOlder])
  /// must never fire this. Like the chat page's follow pass, the pinned
  /// check runs on the posted frame — a delta landing mid-drag must not
  /// yank the viewport. Runs at the top of the feed builder: the pool
  /// notifies for every child frame, the row-count compare filters those
  /// belonging to other children or non-growth updates. The count stays
  /// TOTAL rows (not turn groups): groups derive from rows one-way, so the
  /// monotonic growth semantics survive the shared-renderer switch.
  void _followNewRows(ConversationState state) {
    if (!_positionedAtBottom || _loadingOlder) return;
    final grew = state.rows.length > _lastRowCount;
    _lastRowCount = state.rows.length;
    if (!grew) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // The cached (pre-delta) pinned state decides — NOT a live
      // recomputation: an appended row grows maxScrollExtent before the
      // follow pass moves pixels, so a live check would read "scrolled
      // away" and kill the follow. Stale-cache risk after prepending is
      // covered by the recompute in [_loadOlder].
      if (!mounted || _loadingOlder || !_stickToBottom) return;
      _animateToBottom();
    });
  }

  /// Scrolls to the newest row (200ms easeOut) — shared by the follow pass
  /// and the jump-to-bottom button's tap.
  void _animateToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  /// The pool's acquire failure is silent by contract, so the page keeps
  /// its own degradation: if the shared subscription hasn't produced a
  /// ready snapshot within 15s, surface an error with a retry.
  void _armReadyTimeout() {
    _readyTimeout?.cancel();
    _readyTimeout = Timer(const Duration(seconds: 15), () {
      if (!mounted || _error != null) return;
      final state = widget.feed.childState(widget.childSessionId);
      // A late-arriving snapshot is fine; anything else — the subscribe
      // still pending (state null) or acked without a snapshot — is the
      // stall we surface.
      if (state != null && state.ready) return;
      // Live-observed 2026-09-15: a large child-session snapshot can kill
      // the desktop bridge mid-push, leaving the page spinning forever.
      // Surface it so the user can retry instead of waiting silently.
      setState(() => _error = tr(context, 'chat.subscribe.timeout'));
    });
  }

  /// Retry = release + acquire: refs hitting zero closes the stalled
  /// subscription, re-acquiring reopens it (a resubscribe itself triggers
  /// the fresh snapshot push — subscribe takes no snapshot parameter).
  void _retry() {
    widget.feed.release(widget.childSessionId);
    widget.feed.acquire(widget.childSessionId);
    if (mounted) setState(() => _error = null);
    _armReadyTimeout();
  }

  // ------------------------------------------------------------ history

  Future<void> _loadOlder() async {
    final state = widget.feed.childState(widget.childSessionId);
    if (state == null || _loadingOlder) return;
    setState(() => _loadingOlder = true);
    try {
      final res = await widget.gateway.conversationCommands.rowsRange(
        widget.childSessionId,
        // Cursor = the oldest held row (placeholder-proof; snapshot
        // `firstRowId` can be 1 — see ConversationState.oldestRowId).
        beforeRowId: state.oldestRowId,
        limit: 60,
      );
      // Subscription identity guard (HistoryPager.settle semantics): a
      // resubscribe swapped the state out from under this fetch — the page
      // belongs to a state nobody shows; drop it silently. (Map responses
      // only, as there — a bare List answer has no envelope to guard with.)
      if (res is Map &&
          state != widget.feed.childState(widget.childSessionId)) {
        return;
      }
      if (!mounted) return;
      final page = parseRowsRangeResponse(res, state: state);
      // The rows are immutable log entries — an epoch drift does not
      // invalidate them (round 23, see HistoryPager.settle): toast as a
      // trace, then apply the page anyway.
      if (!page.epochMatches) {
        if (mounted) _toast(tr(context, 'chat.loadOlder.stale'));
      }
      final older = page.rows;
      if (older == null || older.isEmpty) {
        if (state.rows.isNotEmpty) {
          state.hasMore = page.hasMore ?? false;
          if (mounted) _toast(tr(context, 'chat.noOlder'));
        }
        return;
      }
      if (_scrollActive) {
        // DRAG HOLD (lite, design D2): the page landed mid-gesture —
        // prepending now would yank the viewport under the finger. Park it;
        // ScrollEnd flushes it (see [_flushPendingPage]). _loadingOlder
        // stays armed through the landing, so the same cursor cannot be
        // re-fetched while the reader keeps dragging.
        _pendingPage = (state: state, page: page);
        return;
      }
      // Awaited so the frozen-frame capture's own park decision (a drag
      // starting mid-capture, see [_prependOlderPage]) lands BEFORE the
      // finally below releases the gate — an early release would leave the
      // parked window free to re-fetch the same cursor.
      await _prependOlderPage(state, page);
    } catch (e) {
      if (mounted) _toast(trP(context, 'chat.loadOlder.failed', ['$e']));
    } finally {
      // The parked path releases the gate on landing, not here.
      if (mounted && _pendingPage == null) {
        setState(() => _loadingOlder = false);
      }
    }
  }

  /// The one prepend path (direct or drag-hold flush): capture the list's
  /// current paint, measure the reading anchor BEFORE the rows land (spec §9
  /// hard discipline — real RenderBox positions, never a maxScrollExtent
  /// estimate as the landing), prepend, then compensate post-frame under the
  /// veil. Pinned readers skip the freeze entirely: their landing is the
  /// follow pass's own ease back to the bottom, which must stay visible.
  Future<void> _prependOlderPage(
    ConversationState state,
    RowsRangePage page,
  ) async {
    final pinned = _stickToBottom;
    // FROZEN FRAME (chat-page round 24 twin): capture the CURRENT paint
    // before the prepend applies — the veil alone replaced the list with a
    // blank for 1-2 frames and read as a full-screen black flash on device.
    // Drawing this capture over the veil shows the SAME pixels standing
    // still until the measured landing. A failed capture (no boundary /
    // capture error) downgrades the chain to the visible-landing path: a
    // misplaced list beats a blank one. The pinned verdict is read BEFORE
    // the prepend: the post-frame stick recompute below flips the cache
    // first (max grows, pixels stand still), so a late read would starve
    // the follow pass (caught by the anchor test's pinned case).
    ui.Image? frozen;
    if (!pinned) {
      final boundary = _freezeKey.currentContext?.findRenderObject();
      if (boundary is RenderRepaintBoundary && !boundary.debugNeedsPaint) {
        final ratio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 3.0;
        try {
          frozen = await boundary.toImage(pixelRatio: ratio);
        } catch (_) {
          frozen = null;
        }
      }
      if (!mounted) {
        frozen?.dispose();
        return;
      }
      // The capture is async (GPU read-back): re-check the hold AFTER the
      // gap — a drag that started mid-capture must park the page, not
      // prepend under a moving finger (same remedy as the fetch-time hold;
      // [_loadingOlder] stays armed through the parked landing).
      if (_scrollActive) {
        frozen?.dispose();
        _pendingPage = (state: state, page: page);
        return;
      }
    }
    final anchor = pinned ? null : _measureAnchor();
    state
      ..hasMore = page.hasMore
      ..prependOlderRows(page.rows!);
    setState(() {
      _listVeiled = frozen != null;
      _frozenFrame = frozen;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_scrollController.hasClients) {
        _liftVeil();
        return;
      }
      final stick = _isStuckToBottom();
      if (stick != _stickToBottom) {
        setState(() => _stickToBottom = stick);
      }
      if (anchor != null) {
        _compensateAnchor(anchor);
      } else if (pinned) {
        // 增长回底 (design D2: 贴底态退化为 follow 行为) — the follow pass
        // reads the already-reflipped cache, so carry the return here.
        _animateToBottom();
      }
    });
  }

  // ---------------------------------------------------------- anchoring

  /// Reading anchor captured before a prepend: the first group at/over the
  /// viewport top, retreated to the nearest STABLE group (userInput /
  /// timelineMarker first row — such a group can only ever gain rows above,
  /// never lose its lead row, so the key survives a page-boundary re-group
  /// that orphans an assistant-led group's key).
  _ReadingAnchor? _measureAnchor() {
    if (!_scrollController.hasClients) return null;
    final viewport = _listViewportBox();
    if (viewport == null) return null;
    final viewportTop = viewport.localToGlobal(Offset.zero).dy;
    final groups = _builtGroups();
    if (groups.isEmpty) return null;
    var anchorIdx = -1;
    for (var i = 0; i < groups.length; i++) {
      if (groups[i].$2.localToGlobal(Offset.zero).dy >= viewportTop - 40) {
        anchorIdx = i;
        break;
      }
    }
    anchorIdx = anchorIdx < 0 ? groups.length - 1 : anchorIdx;
    var stableIdx = anchorIdx;
    while (stableIdx >= 0) {
      final firstKind = groups[stableIdx].$1.rows.first['kind'];
      if (firstKind == 'timelineMarker' || firstKind == 'userInput') break;
      stableIdx--;
    }
    final (widget, box) = groups[stableIdx >= 0 ? stableIdx : anchorIdx];
    return (
      key: widget.key!,
      rowIds: widget.rows.map((r) => r['rowId']).whereType<num>().toSet(),
      dy: box.localToGlobal(Offset.zero).dy - viewportTop,
      baseMax: _scrollController.position.maxScrollExtent,
    );
  }

  /// Post-prepend landing (design D2): re-find the anchor group, measure its
  /// real position and jump by the measured delta — maxScrollExtent plays no
  /// part in the LANDING, so row-height variance cannot skew it. The prepend
  /// usually pushes the anchor out of the laid-out window (a 60-row page
  /// spans several viewports), so the cache is widened for the landing frames
  /// and the estimate only ever powers a COARSE hop (one re-measure follows);
  /// a still-unfound anchor keeps the estimate-grade position with a trace —
  /// no guess-crawl. The frozen frame stands over every hop and estimate
  /// jump; every terminal exit of the chain lifts the veil.
  void _compensateAnchor(_ReadingAnchor anchor) {
    setState(() => _anchorCacheExtent = (_lastPageExtent ?? 2000) * 2);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_scrollController.hasClients) {
        _restoreAnchorCacheExtent();
        _liftVeil();
        return;
      }
      if (_findAnchorBox(anchor) != null) {
        _landAnchor(anchor);
        return;
      }
      // Coarse hop by the extent estimate (estimate delta since measure) —
      // hidden under the frozen frame; its own programmatic notifications
      // carry no dragDetails, so they cannot lift the veil mid-hop.
      final position = _scrollController.position;
      _scrollController.jumpTo(math.max(
        0.0,
        position.pixels + (position.maxScrollExtent - anchor.baseMax),
      ));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!_scrollController.hasClients) {
          _restoreAnchorCacheExtent();
          _liftVeil();
          return;
        }
        if (_findAnchorBox(anchor) != null) {
          _landAnchor(anchor);
        } else {
          debugPrint('[anchor] detail: anchor not built after one hop, '
              'keeping the estimate-grade position');
          _restoreAnchorCacheExtent();
          _liftVeil();
        }
      });
    });
  }

  /// The measured landing: jump by the anchor's real viewport shift, then
  /// book the measured page height for the next landing's cache headroom.
  /// The jump and the veil lift land in the same run, so the reader resumes
  /// directly on the settled view.
  void _landAnchor(_ReadingAnchor anchor) {
    final viewport = _listViewportBox();
    final box = viewport == null ? null : _findAnchorBox(anchor);
    if (box == null) {
      _restoreAnchorCacheExtent();
      _liftVeil();
      return;
    }
    final viewportTop = viewport!.localToGlobal(Offset.zero).dy;
    final newDy = box.localToGlobal(Offset.zero).dy - viewportTop;
    _scrollController.jumpTo(
      math.max(0.0, _scrollController.position.pixels + (newDy - anchor.dy)),
    );
    _lastPageExtent =
        _scrollController.position.maxScrollExtent - anchor.baseMax;
    _restoreAnchorCacheExtent();
    _liftVeil();
  }

  /// Lifts the prepend veil ([_listVeiled]) — idempotent, safe to call from
  /// every compensation exit and scroll notification. Also drops the frozen
  /// frame; its disposal waits one frame so the layer that already painted
  /// it lets go first.
  void _liftVeil() {
    if (!_listVeiled && _frozenFrame == null) return;
    final frame = _frozenFrame;
    setState(() {
      _listVeiled = false;
      _frozenFrame = null;
    });
    if (frame != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => frame.dispose());
    }
  }

  void _restoreAnchorCacheExtent() {
    if (!mounted || _anchorCacheExtent == null) return;
    setState(() => _anchorCacheExtent = null);
  }

  /// The anchor group's box after the prepend: key hit first, rowId overlap
  /// as the merged-group fallback (chat-page order).
  RenderBox? _findAnchorBox(_ReadingAnchor anchor) {
    final groups = _builtGroups();
    for (final (widget, box) in groups) {
      if (widget.key == anchor.key) return box;
    }
    for (final (widget, box) in groups) {
      final ids = widget.rows.map((r) => r['rowId']).whereType<num>();
      if (ids.any(anchor.rowIds.contains)) return box;
    }
    return null;
  }

  /// The list's viewport-sized render box, or null when nothing is laid out.
  RenderBox? _listViewportBox() {
    final box = _listKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box;
  }

  /// Every currently-built turn group, in list order: (widget, box) — the
  /// chat page's visit pattern. Only BUILT children exist here (SliverList
  /// keeps just the viewport plus its cacheExtent alive), which is what the
  /// widened-cache landing frames are for.
  List<(ChatTurnGroup, RenderBox)> _builtGroups() {
    final groups = <(ChatTurnGroup, RenderBox)>[];
    final listContext = _listKey.currentContext;
    if (listContext == null) return groups;
    void visit(Element element) {
      final widget = element.widget;
      if (widget is ChatTurnGroup) {
        final box = element.findRenderObject();
        if (widget.key != null &&
            box is RenderBox &&
            box.attached &&
            box.hasSize) {
          groups.add((widget, box));
        }
        return;
      }
      element.visitChildElements(visit);
    }

    listContext.visitChildElements(visit);
    return groups;
  }

  /// ScrollEnd landing for a drag-held page (design D2). The identity guard
  /// mirrors the fetch-time one: a resubscribe swapped the state mid-hold →
  /// silent drop (rows are somebody else's now). Awaited for the same reason
  /// as [_loadOlder]: a capture-park inside the prepend must re-arm the gate
  /// (via [_pendingPage]) before it releases.
  Future<void> _flushPendingPage() async {
    final pending = _pendingPage;
    if (pending == null) return;
    _pendingPage = null;
    if (pending.state == widget.feed.childState(widget.childSessionId)) {
      await _prependOlderPage(pending.state, pending.page);
    }
    // Same condition as [_loadOlder]'s finally: a capture-time re-park (see
    // [_prependOlderPage]) keeps the gate armed until THAT landing releases
    // it — releasing here would re-enable the button under a parked page and
    // re-fetch the same cursor.
    if (mounted && _pendingPage == null) {
      setState(() => _loadingOlder = false);
    }
  }

  /// Scroll-events router for the history triggers (design D2). Identity
  /// routing first (chat-page convention): the shared renderer hosts
  /// horizontal scrollables (diff cards, code blocks) — only THIS list's
  /// position may drive loads.
  bool _onScrollNotification(ScrollNotification n) {
    final context = n.context;
    if (context == null) return false;
    final scrollable = Scrollable.maybeOf(context);
    if (scrollable == null ||
        !identical(scrollable.position, _scrollController.position)) {
      return false;
    }
    if (n is ScrollStartNotification) {
      _scrollActive = true;
      // A user drag never waits under the frozen frame (round-24 rule: the
      // freeze must not feel sticky). dragDetails-gated so the chain's own
      // coarse-hop jump stays hidden until the measured landing.
      if (n.dragDetails != null) _liftVeil();
    } else if (n is ScrollEndNotification) {
      _scrollActive = false;
      _flushPendingPage();
    } else if (n is ScrollUpdateNotification && n.dragDetails != null) {
      // Same finger rule: any drag movement lifts the veil immediately.
      _liftVeil();
      // Prefetch window (chat-page threshold): a live drag reaching within
      // max(64, 2×viewport) of the top pulls the next page. Programmatic
      // frames carry no dragDetails — a positioning jump must not load.
      final metrics = n.metrics;
      if (metrics.pixels >= 0 &&
          metrics.pixels <= math.max(64.0, metrics.viewportDimension * 2)) {
        final state = widget.feed.childState(widget.childSessionId);
        if (state != null &&
            state.canLoadOlder &&
            !_loadingOlder &&
            _pendingPage == null) {
          _loadOlder();
        }
      }
    }
    return false;
  }

  // ------------------------------------------------------------ stop

  Future<void> _confirmStop() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr(dialogContext, 'chat.agents.stop')),
        content: Text(tr(dialogContext, 'chat.agents.stopConfirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(tr(dialogContext, 'common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(tr(dialogContext, 'chat.agents.stop')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final parent = widget.parentSessionId ?? '';
    final workId = widget.workId ?? '';
    if (parent.isEmpty || workId.isEmpty) return;
    try {
      await widget.gateway.conversationCommands.cancelBackgroundWork(parent, workId);
    } catch (e) {
      _toast('$e');
    }
  }

  // ------------------------------------------------------------ ui

  void _toast(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  String _pageTitle(BuildContext context) {
    final title = (widget.title ?? '').trim();
    if (title.isNotEmpty) return title;
    final type = (widget.subagentType ?? '').trim();
    if (type.isNotEmpty) return trP(context, 'chat.subagent', [type]);
    return tr(context, 'chat.agents.detailTitle');
  }

  /// Live running view (design D3): the stop button flips with the child
  /// session's LAST turnHeader row, not the entry-time [widget.running]
  /// snapshot (gap-matrix debt — a subagent finishing while the page is
  /// open used to keep the button until re-entry). Not-ready sessions and
  /// headerless transcripts have no wire verdict yet → entry snapshot.
  bool _childRunning() {
    final state = widget.feed.childState(widget.childSessionId);
    if (state == null || !state.ready) return widget.running;
    for (final row in state.rows.reversed) {
      if (row['kind'] == 'turnHeader') {
        return (row['state'] as String? ?? '') == 'running';
      }
    }
    return widget.running;
  }

  /// Model subtitle under the AppBar title (design D4): the official web's
  /// provider display rule via [chatModelLabel]. Localized AnimatedBuilder
  /// so feed notifications repaint the subtitle without rebuilding the
  /// scaffold; not-ready / empty label renders nothing (no placeholder).
  Widget _modelSubtitle(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.feed,
      builder: (context, _) {
        final state = widget.feed.childState(widget.childSessionId);
        final label =
            state == null || !state.ready ? '' : chatModelLabel(state);
        if (label.isEmpty) return const SizedBox.shrink();
        return Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: ZType.caption.copyWith(
            color: ZInk.muted(context),
            fontFamily: 'monospace',
          ),
        );
      },
    );
  }

  /// Minimal onAction for the shared renderer: everything send-shaped is
  /// readOnly-gated, so this wrapper only ever carries read paths — run
  /// the future, surface failures as a toast (the page has no busy strip).
  Future<void> _runAction(
    String label,
    Future<dynamic> Function() action,
  ) async {
    try {
      await action();
    } catch (e) {
      _toast('$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _pageTitle(context),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            _modelSubtitle(context),
          ],
        ),
        actions: [
          // Feed-driven so the stop button flips live with the child
          // session's turnHeader (design D3, same pattern as
          // [_modelSubtitle] below the title).
          AnimatedBuilder(
            animation: widget.feed,
            builder: (context, _) => _childRunning()
                ? IconButton(
                    tooltip: tr(context, 'chat.agents.stop'),
                    icon: Icon(Icons.stop_circle_outlined,
                        color: ZInk.dangerTone(context)),
                    onPressed: _confirmStop,
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
      // The feed drives everything state-shaped: it re-notifies whenever any
      // pooled child handle's state changes (and on subscribe completion), so
      // the spinner → transcript transition fires from here. Rebuild surface
      // cost accepted (same pattern as the Agent tile's child timeline).
      body: AnimatedBuilder(
        animation: widget.feed,
        builder: (context, _) {
          final state = widget.feed.childState(widget.childSessionId);
          if (_error != null) {
            return Material(
              color: ZColors.danger.withValues(alpha: 0.15),
              child: ListTile(
                dense: true,
                title: Text(
                  trP(context, 'chat.subscribe.failed', ['$_error']),
                  style: ZType.sub,
                ),
                trailing: TextButton(
                  onPressed: _retry,
                  child: Text(tr(context, 'tasks.retry')),
                ),
              ),
            );
          }
          if (state == null || !state.ready) {
            return const Center(child: CircularProgressIndicator());
          }
          _followNewRows(state);
          // Open auto-fill (chat-page parity): the snapshot is a tail
          // window — pull one older page the first time the gate is open.
          // Post-frame: _loadOlder setStates, which is illegal mid-build.
          if (!_autoFilled && state.canLoadOlder) {
            _autoFilled = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _loadOlder();
            });
          }
          // Shared-renderer switch (D3): rows go through the main chat's
          // turn grouping — one ChatTurnGroup per turn, readOnly so every
          // send-shaped affordance stays hidden. childSessionRows drops
          // the spawn-time modelChange marker: the subtitle below the
          // title IS the model display (acceptance fix).
          final groups = groupChatRows(childSessionRows(state.rows));
          final itemCount = groups.length + (state.canLoadOlder ? 1 : 0);
          if (!_positionedAtBottom) {
            // R1b: land on the newest content on the first frame the list is
            // actually mounted — the follow pass only fires on LATER updates
            // and would miss the initial snapshot.
            _positionedAtBottom = true;
            _lastRowCount = state.rows.length;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || !_scrollController.hasClients) {
                return;
              }
              _scrollController.jumpTo(
                _scrollController.position.maxScrollExtent,
              );
            });
          }
          return Stack(
            children: [
              // Frozen-frame capture source (round-24 twin) + prepend veil:
              // the veil hides only the PAINT — layout and the anchor
              // measurement run normally underneath, so the measured landing
              // happens off-screen while [_frozenFrame] (Stack top) shows the
              // same pixels standing still. Arming is capture-gated: a failed
              // capture keeps the list visible (never a blank flash).
              RepaintBoundary(
                key: _freezeKey,
                child: NotificationListener<ScrollNotification>(
                  onNotification: _onScrollNotification,
                  child: Opacity(
                    opacity: _listVeiled ? 0.0 : 1.0,
                    child: ListView.builder(
                      key: _listKey,
                      controller: _scrollController,
                      // Widened only across a compensation's landing frames —
                      // the anchor resurfaces inside it (design D2).
                      scrollCacheExtent: _anchorCacheExtent == null
                          ? null
                          : ScrollCacheExtent.pixels(_anchorCacheExtent!),
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      itemCount: itemCount,
                      itemBuilder: (context, index) {
                        if (state.canLoadOlder && index == 0) {
                          return Center(
                            child: TextButton.icon(
                              onPressed: _loadingOlder ? null : _loadOlder,
                              icon: _loadingOlder
                                  ? const SizedBox(
                                      width: 12,
                                      height: 12,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 1.5),
                                    )
                                  : const Icon(Icons.expand_less, size: 16),
                              label: Text(tr(context, 'chat.loadOlder')),
                            ),
                          );
                        }
                        final group =
                            groups[index - (state.canLoadOlder ? 1 : 0)];
                        return ChatTurnGroup(
                          key: ValueKey('turn-${group.first['rowId']}'),
                          rows: group,
                          gateway: widget.gateway,
                          sessionId: widget.childSessionId,
                          onAction: _runAction,
                          state: state,
                          feed: widget.feed,
                          preview: _preview,
                          confirmWindow: widget.effectiveConfirmWindow,
                          workspaceLabel: null,
                          readOnly: true,
                        );
                      },
                    ),
                  ),
                ),
              ),
              // Jump-to-newest control, bottom-right; the stick detection
              // in [_onScroll] drives its visibility.
              Positioned(
                right: 16,
                bottom: 16,
                child: JumpToBottomButton(
                  visible: !_stickToBottom,
                  onPressed: _animateToBottom,
                ),
              ),
              // The frozen pre-prepend paint, topmost: same pixels stand
              // still until the measured landing lifts it (never armed
              // without a capture — see [_listVeiled]).
              if (_frozenFrame != null)
                Positioned.fill(
                  child: RawImage(
                    image: _frozenFrame,
                    fit: BoxFit.fill,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
