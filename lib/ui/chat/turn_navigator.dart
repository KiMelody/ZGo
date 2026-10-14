import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme.dart';
import '../ui_settings.dart';

/// Pure row classifier behind the turn navigator (task 10-14): a
/// `kind == 'userInput'` row is a REAL user query — one navigator cell —
/// unless it is a tool-answer form.
///
/// Discriminator (design §2.1, wire-verified 10-14 against the official
/// web bundle): real queries carry `origin: 'realUser'` on the wire; the
/// official directory is `visibleUserInputs.filter(origin === 'realUser')`
/// and its optimistic projection writes the same value. When `origin` is
/// absent (older desktop), exclude the tool-answer markers instead — the
/// locally rebuilt AskUserQuestion rows (`ConversationState`
/// `_rebuildPendingAskUserQuestions`) carry `payload.toolCallId` +
/// `anchorRowId` (AskUserQuestion exchanges themselves travel as toolCall
/// rows and never occupy a `userInput` row in this wire, so the fallback
/// is defensive only).
bool isRealUserQueryRow(Map<String, dynamic> row) {
  final origin = row['origin'];
  if (origin != null) return '$origin' == 'realUser';
  final payload = row['payload'];
  if (payload is Map && payload['toolCallId'] != null) return false;
  return row['anchorRowId'] == null;
}

/// The navigator directory: ascending rowIds of the real user queries in
/// [rows] (pure projection of `ConversationState.rows`; memoized by the
/// page on `(rows.length, firstRowId, lastRowId)` so streaming text deltas
/// never recompute it).
List<int> turnNavigatorQueryRowIds(List<Map<String, dynamic>> rows) => [
  for (final row in rows)
    if (row['kind'] == 'userInput' &&
        isRealUserQueryRow(row) &&
        row['rowId'] is num)
      (row['rowId'] as num).toInt(),
];

/// Right-edge turn navigator strip (design §3, official web
/// `chat.turnNavigator` parity): one 10dp slot per real user query, the
/// visual bar 12×2dp anchored inside the list's existing 16dp right
/// padding (2dp from the edge — content never yields, zero overlap by
/// construction), the full 44dp slot width is the tap target. Tapping a
/// cell asks the page to land that query on the viewport top; [activeIndex]
/// is the query currently at the viewport top (page-computed, kept
/// unchanged when nothing is measurable — no flicker). When the cells
/// exceed the available height the strip scrolls itself and keeps the
/// active cell visible; with older history still unloaded ([canLoadOlder])
/// a fainter ghost cell — same geometry, not tappable, hidden from the
/// semantics tree, never highlighted — hints "more above" at the list head.
///
/// Long-press (design §3.1, 10-14 R2) floats an enlarged overlay out to
/// the left: a 68dp scaffold-background panel with ~32dp slots, the thin
/// strip and the panel rendering one-or-the-other at the same spot. It
/// collapses via a big-cell tap (jump + collapse), the transparent
/// outside-tap barrier, or the page calling [TurnNavigatorState.collapse]
/// when the list scrolls.
///
/// Self-contained display widget: inputs + [onJump(rowId)] only, no
/// protocol dependencies (the directory/highlight/jump mechanics live in
/// the chat page state). The mount point must provide a bounded height
/// AND full width (the page's Positioned.fill does — the barrier and the
/// panel need the whole message area; every inactive pixel stays
/// transparent to hit tests).
class TurnNavigator extends StatefulWidget {
  /// Query rowIds, ascending — one cell each.
  final List<int> rowIds;

  /// Highlighted cell index (clamped internally); null = nothing
  /// measurable yet, the previous highlight stands.
  final int? activeIndex;

  /// Older history exists beyond the loaded window — a dimmer ghost cell
  /// (same geometry, not tappable, not a query) leads the real cells.
  final bool canLoadOlder;

  /// Called with the tapped cell's query rowId.
  final ValueChanged<int> onJump;

  const TurnNavigator({
    super.key,
    required this.rowIds,
    required this.activeIndex,
    required this.canLoadOlder,
    required this.onJump,
  });

  @override
  State<TurnNavigator> createState() => TurnNavigatorState();

  // Geometry contract (design §3, mock 定稿: the desktop originals).
  static const double hitWidth = 44;
  static const double slotHeight = 10;
  static const double barWidth = 12;
  static const double barHeight = 2;
  static const double barRightInset = 2;

  /// `max-h ≈ 可用高 - 6rem` (mock: calc(100% - 96px)).
  static const double maxHeightInset = 96;

  /// Ghost placeholder opacity (design §3, R2 revision): roughly half the
  /// resting-cell ghost tone (ZInk.ghost ≈ 30% foreground), so the
  /// "more above" hint reads as the faintest mark on the strip.
  static const double ghostAlpha = 0.15;

  // Expanded overlay (design §3.1, 10-14 R2 real-device feedback).
  /// Float panel width (~64–72dp), floating over the body's right edge.
  static const double overlayWidth = 68;

  /// Enlarged cell geometry: a ~4×24dp bar inside a ~32dp slot.
  static const double expandedSlotHeight = 32;
  static const double expandedBarWidth = 4;
  static const double expandedBarHeight = 24;

  /// Vertical breathing room inside the panel — the rounded corners must
  /// not crowd the first/last bar.
  static const double overlayPaddingY = 8;

  /// Float-out duration ("向左运动的浮动动画", design §3.1: ~220ms).
  static const Duration expandDuration = Duration(milliseconds: 220);

  /// Long-press trigger deadline (design §3.1, R4 real-device feedback:
  /// the 500ms framework default felt laggy).
  static const Duration longPressDuration = Duration(milliseconds: 250);

  /// The transparent outside-tap barrier while expanded. Exposed so tests
  /// can target it (a barrier tap collapses without jumping).
  static const Key barrierKey = ValueKey('turn-navigator-barrier');
}

/// State handle for the mount side: the chat page holds a
/// `GlobalKey<TurnNavigatorState>` and calls [collapse] from its scroll
/// notification hook — "the list scrolled" is the page's knowledge, while
/// the expanded state and its animation stay inside this component
/// (design §3.1; the component never imports the page).
class TurnNavigatorState extends State<TurnNavigator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _curve;
  final _stripController = ScrollController();
  final _panelController = ScrollController();

  /// Expanded overlay flag. The panel renders while this is true OR the
  /// float animation is still settling (the slide-out frames), so collapse
  /// never needs a setState — the controller's ticks drive the swap.
  bool _expanded = false;

  bool get _overlayVisible =>
      _expanded || _controller.status != AnimationStatus.dismissed;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: TurnNavigator.expandDuration,
    );
    // Same float recipe as zRoute: fast-out slide in, its mirror back out.
    _curve = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _syncStrip(jump: true);
  }

  @override
  void didUpdateWidget(TurnNavigator oldWidget) {
    super.didUpdateWidget(oldWidget);
    // canLoadOlder flips move the real cells by the ghost's head slot —
    // the active cell's strip position needs the same resync.
    if (widget.activeIndex != oldWidget.activeIndex ||
        widget.canLoadOlder != oldWidget.canLoadOlder) {
      _syncStrip();
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    _stripController.dispose();
    _panelController.dispose();
    super.dispose();
  }

  /// Long-press trigger (design §3.1): floats the enlarged overlay out
  /// from the right edge. No-op while already expanded.
  void _expand() {
    if (_expanded) return;
    setState(() => _expanded = true);
    _controller.forward();
    // The overlay opens with the active cell in view (mock setActive
    // auto-scroll on strip swap).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncStrip(jump: true);
    });
  }

  /// The hot zone's long-press gesture factory: an explicit 250ms deadline
  /// (R4 real-device feedback — the 500ms framework default felt laggy),
  /// wired to [LongPressGestureRecognizer.onLongPress] so the arena
  /// behavior matches the plain GestureDetector `onLongPress` it replaced.
  static GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>
  _longPressGesture(VoidCallback onLongPress) =>
      GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
        () => LongPressGestureRecognizer(
          duration: TurnNavigator.longPressDuration,
        ),
        (recognizer) => recognizer.onLongPress = onLongPress,
      );

  /// Collapse the expanded overlay (big-cell tap, outside barrier, or the
  /// page's list-scrolled request). No-op while collapsed; the panel
  /// slides back out and the thin strip returns when it is gone.
  void collapse() {
    if (!_expanded) return;
    _expanded = false;
    _controller.reverse();
  }

  /// Leading ghost slot at the list head ([canLoadOlder]); the single
  /// place the ListView index ↔ real-cell index shift lives, shared by
  /// the thin strip, the expanded panel and the strip auto-scroll math
  /// (real-cell indices stay the widget-facing `activeIndex` semantics).
  int get _leading => widget.canLoadOlder ? 1 : 0;

  /// Keeps the active cell inside whichever strip viewport is live (thin
  /// strip or expanded panel) once the cells overflow the capped height
  /// (mock setActive auto-scroll). No-op while everything fits.
  void _syncStrip({bool jump = false}) {
    if (widget.activeIndex == null) return;
    final panel = _overlayVisible;
    final controller = panel ? _panelController : _stripController;
    final slot = panel
        ? TurnNavigator.expandedSlotHeight
        : TurnNavigator.slotHeight;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !controller.hasClients) return;
      final position = controller.position;
      if (position.maxScrollExtent <= 0) return;
      final cellCenter = slot * (_leading + widget.activeIndex!) + slot / 2;
      final desired = (cellCenter - position.viewportDimension / 2)
          .clamp(0.0, position.maxScrollExtent);
      if ((desired - position.pixels).abs() < 1) return;
      if (jump) {
        controller.jumpTo(desired);
      } else {
        controller.animateTo(
          desired,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ids = widget.rowIds;
    // Display gate (PRD): fewer than two loaded queries renders nothing.
    if (ids.length < 2) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        // 可用高 - 6rem, floored at two slots so a tiny message area
        // never produces a negative height.
        final bounded = constraints.maxHeight.isFinite;
        final cap = math.max(
          constraints.maxHeight - TurnNavigator.maxHeightInset,
          TurnNavigator.slotHeight * 2,
        );
        final panelCap = math.max(
          constraints.maxHeight - TurnNavigator.maxHeightInset,
          TurnNavigator.expandedSlotHeight * 2,
        );
        // The controller drives both the slide and the thin-strip ↔ panel
        // swap (same spot, one-or-the-other rendering): the panel stays
        // mounted through the slide-out, the thin strip returns once it
        // is gone.
        return AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final expanded = _overlayVisible;
            return Stack(
              children: [
                if (!expanded)
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    width: TurnNavigator.hitWidth,
                    child: RawGestureDetector(
                      // Long-press trigger (design §3.1): anywhere in the
                      // 44dp band, thin cells included — the long-press
                      // recognizer wins the arena at the deadline, so a
                      // plain tap keeps jumping (its recognizer concedes).
                      // Translucent so taps and list drags still fall
                      // through where no cell sits (V1 behavior).
                      behavior: HitTestBehavior.translucent,
                      gestures: {
                        LongPressGestureRecognizer: _longPressGesture(_expand),
                      },
                      child: Semantics(
                        container: true,
                        label: tr(context, 'chat.turnNavigator.label'),
                        child: _thinStrip(context, ids, cap, bounded),
                      ),
                    ),
                  ),
                if (expanded) ...[
                  // Outside-tap barrier (design §3.1): transparent,
                  // collapse without jump. Translucent so the list below
                  // still receives drags — a drag beats the tap
                  // recognizer, the page sees the scroll and collapses.
                  Positioned.fill(
                    child: ExcludeSemantics(
                      child: GestureDetector(
                        key: TurnNavigator.barrierKey,
                        behavior: HitTestBehavior.translucent,
                        onTap: collapse,
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    width: TurnNavigator.overlayWidth,
                    child: Transform.translate(
                      // "向左运动的浮动动画": from off-viewport right to
                      // rest (design §3.1); the collapse mirrors it back.
                      offset: Offset(
                        TurnNavigator.overlayWidth * (1 - _curve.value),
                        0,
                      ),
                      child: Semantics(
                        container: true,
                        label: tr(context, 'chat.turnNavigator.label'),
                        child: _panel(context, ids, panelCap, bounded),
                      ),
                    ),
                  ),
                ],
              ],
            );
          },
        );
      },
    );
  }

  Widget _thinStrip(
    BuildContext context,
    List<int> ids,
    double cap,
    bool bounded,
  ) {
    final contentHeight = (ids.length + _leading) * TurnNavigator.slotHeight;
    final boxHeight = bounded ? math.min(contentHeight, cap) : cap;
    final overflows = bounded && contentHeight > cap;
    return Center(
      child: SizedBox(
        width: double.infinity,
        height: boxHeight,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ListView.builder(
              controller: _stripController,
              padding: EdgeInsets.zero,
              itemExtent: TurnNavigator.slotHeight,
              // Only the overflowing strip may claim drags — when
              // everything fits a scrollable would still swallow
              // the message list's vertical drags landing in the
              // hit band (design: 不拦截列表滚动手势).
              physics: overflows
                  ? const ClampingScrollPhysics()
                  : const NeverScrollableScrollPhysics(),
              itemCount: ids.length + _leading,
              itemBuilder: (context, index) => index < _leading
                  ? _ghostCell(context, expanded: false)
                  : _cell(context, index - _leading, ids, widget.activeIndex),
            ),
          ],
        ),
      ),
    );
  }

  /// The expanded float panel (design §3.1): scaffold-background surface
  /// (the hard requirement behind this R2 — on device the jump-button card
  /// tone read as a foreign color against the chat background), translucent
  /// with no border stroke (R3 — the hairline read as too strong a frame on
  /// device; R4 — 0.85 still read too solid, set 0.5) and only a light
  /// shadow, rounded with the tile token.
  Widget _panel(
    BuildContext context,
    List<int> ids,
    double cap,
    bool bounded,
  ) {
    final theme = Theme.of(context);
    final contentHeight = (ids.length + _leading) *
            TurnNavigator.expandedSlotHeight +
        TurnNavigator.overlayPaddingY * 2;
    final boxHeight = bounded ? math.min(contentHeight, cap) : cap;
    final overflows = bounded && contentHeight > cap;
    final radius = BorderRadius.circular(ZRadius.tile);
    return Center(
      child: SizedBox(
        width: TurnNavigator.overlayWidth,
        height: boxHeight,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor.withValues(alpha: 0.5),
            borderRadius: radius,
            // Light float shadow (jump-button recipe, elevation 3 tone);
            // raw alpha is deliberate — no shadow token exists in theme.
            boxShadow: const [
              BoxShadow(
                color: Color(0x28000000),
                blurRadius: 10,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                vertical: TurnNavigator.overlayPaddingY,
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ListView.builder(
                    controller: _panelController,
                    padding: EdgeInsets.zero,
                    itemExtent: TurnNavigator.expandedSlotHeight,
                    physics: overflows
                        ? const ClampingScrollPhysics()
                        : const NeverScrollableScrollPhysics(),
                    itemCount: ids.length + _leading,
                    itemBuilder: (context, index) => index < _leading
                        ? _ghostCell(context, expanded: true)
                        : _panelCell(context, index - _leading, ids),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Ghost placeholder cell (design §3, R2 revision): same geometry as a
  /// real cell at [TurnNavigator.ghostAlpha] — roughly half the resting
  /// tone — NOT tappable, hidden from the semantics tree, never
  /// highlighted. It only hints "more above" while older history is
  /// unloaded, so it lives INSIDE the scrollable head (scrolls with the
  /// content) instead of covering it like the retired gradient did.
  Widget _ghostCell(BuildContext context, {required bool expanded}) {
    final color = ZInk.ghost(context).withValues(
      alpha: TurnNavigator.ghostAlpha,
    );
    final bar = Container(
      width: expanded
          ? TurnNavigator.expandedBarWidth
          : TurnNavigator.barWidth,
      height: expanded
          ? TurnNavigator.expandedBarHeight
          : TurnNavigator.barHeight,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(ZRadius.pill),
      ),
    );
    return ExcludeSemantics(
      child: expanded
          ? Center(child: bar)
          : Padding(
              padding: const EdgeInsets.only(
                right: TurnNavigator.barRightInset,
              ),
              child: Align(alignment: Alignment.centerRight, child: bar),
            ),
    );
  }

  Widget _cell(
    BuildContext context,
    int index,
    List<int> ids,
    int? activeIndex,
  ) {
    final isActive = activeIndex != null && index == activeIndex;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.onJump(ids[index]),
      child: Semantics(
        button: true,
        label: trP(context, 'chat.turnNavigator.jumpToQuery', [
          '${index + 1}',
        ]),
        child: Padding(
          padding: const EdgeInsets.only(right: TurnNavigator.barRightInset),
          child: Align(
            alignment: Alignment.centerRight,
            child: AnimatedContainer(
              width: TurnNavigator.barWidth,
              height: TurnNavigator.barHeight,
              duration: const Duration(milliseconds: 150),
              decoration: BoxDecoration(
                color: isActive ? ZInk.solid(context) : ZInk.ghost(context),
                borderRadius: BorderRadius.circular(ZRadius.pill),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _panelCell(BuildContext context, int index, List<int> ids) {
    final isActive = widget.activeIndex != null && index == widget.activeIndex;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        widget.onJump(ids[index]);
        collapse();
      },
      child: Semantics(
        button: true,
        label: trP(context, 'chat.turnNavigator.jumpToQuery', [
          '${index + 1}',
        ]),
        child: Center(
          child: AnimatedContainer(
            width: TurnNavigator.expandedBarWidth,
            height: TurnNavigator.expandedBarHeight,
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              color: isActive ? ZInk.solid(context) : ZInk.ghost(context),
              borderRadius: BorderRadius.circular(ZRadius.pill),
            ),
          ),
        ),
      ),
    );
  }
}
