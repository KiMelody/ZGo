import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// One quick action revealed by swiping a list row to the left.
///
/// [fgColor] is a FOREGROUND tone (icon + label share it) — the tray surface
/// is neutral ([ZInk.tile]), matching the long-press action sheet's language
/// of neutral rows with colored accents.
class SwipeAction {
  final IconData icon;
  final String label;
  final Color fgColor;
  final VoidCallback onTap;

  const SwipeAction({
    required this.icon,
    required this.label,
    required this.fgColor,
    required this.onTap,
  });
}

/// Left-swipe quick actions for a list row.
///
/// Mobile rows carry no visible per-row buttons (official layout parity) —
/// dragging the row left reveals [actions] instead. A release past the halfway
/// point (or a fast fling) snaps the tray open with a light haptic pulse;
/// tapping the row, or any action, closes it. The row keeps its own tap and
/// long-press handling, and the long-press action sheet stays available for
/// keyboard and screen-reader users.
///
/// F1 slider-and-slot geometry (09-29 mock, reworked after check WARN-1):
/// the tray is a neutral tile surface whose seam side (left) is square and
/// outer edge (right) rounds with [trayRadius]; cells are separated by
/// hairlines, no seam-side border — the row's own border is the seam line.
/// The tray pads [childRadius]-wide under the row's seam-side corners (the
/// pad grows with the drag), so the row's rounded corner notches reveal the
/// slot colour instead of the page background and the row reads as sliding
/// out of one card. Gesture and animation behaviour is identical to the
/// color-block era.
class SwipeActionsRow extends StatefulWidget {
  final Widget child;
  final List<SwipeAction> actions;

  /// Tray outer-edge (right) radius — the [ZRadius] tier matching the
  /// wrapped row's own shape.
  final double trayRadius;

  /// The wrapped row's own corner radius; the tray pads this wide under the
  /// row's seam-side (right) corners so their notches show the slot colour.
  final double childRadius;

  const SwipeActionsRow({
    super.key,
    required this.child,
    required this.actions,
    required this.trayRadius,
    required this.childRadius,
  });

  /// Width of one revealed action button.
  static const double actionWidth = 64;

  @override
  State<SwipeActionsRow> createState() => _SwipeActionsRowState();
}

class _SwipeActionsRowState extends State<SwipeActionsRow>
    with SingleTickerProviderStateMixin {
  static const _snapDuration = Duration(milliseconds: 180);

  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: _snapDuration,
  )..addListener(_onTick);

  /// Revealed width in logical pixels (the live value while dragging).
  double _offset = 0;
  double _animFrom = 0;
  double _animTo = 0;

  double get _reveal => widget.actions.length * SwipeActionsRow.actionWidth;

  bool get _isOpen => _offset > 0;

  void _onTick() {
    final t = Curves.easeOutCubic.transform(_anim.value);
    setState(() => _offset = _animFrom + (_animTo - _animFrom) * t);
  }

  void _snapTo(double target) {
    if (target > 0 && !_isOpen) HapticFeedback.lightImpact();
    _anim.stop();
    _animFrom = _offset;
    _animTo = target;
    _anim.forward(from: 0);
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  Widget _actionButton(SwipeAction action) {
    return InkWell(
      onTap: () {
        HapticFeedback.lightImpact();
        _snapTo(0);
        action.onTap();
      },
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(action.icon, size: 18, color: action.fgColor),
          const SizedBox(height: 3),
          Text(
            action.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ZType.caption.copyWith(color: action.fgColor),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final reveal = _reveal.clamp(0.0, constraints.maxWidth);
        final offset = _offset.clamp(0.0, reveal);
        // Slot pad under the row's seam-side corners: 0 seated (the tray is
        // fully off-canvas, so the closed row is untouched), childRadius when
        // dragged past it — the row's rounded notches then reveal the slot
        // colour instead of the page background.
        final pad = widget.childRadius <= 0
            ? 0.0
            : offset.clamp(0.0, widget.childRadius);
        return ClipRect(
          child: Stack(
            children: [
              // The tray only ever paints the revealed strip plus the pad
              // (both ride the row edge and are clipped), so a half-open drag
              // never shows the neutral tray through the transparent row
              // background beyond the notch area.
              Positioned(
                top: 0,
                bottom: 0,
                right: offset - reveal,
                width: reveal + pad,
                child: ExcludeSemantics(
                  excluding: offset == 0,
                  child: Material(
                    color: ZInk.tile(context),
                    clipBehavior: Clip.antiAlias,
                    shape: RoundedRectangleBorder(
                      // F1: square seam side (left) — the row's own border is
                      // the seam line; rounded outer edge (right) only.
                      borderRadius: BorderRadius.horizontal(
                        right: Radius.circular(widget.trayRadius),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Slot pad — pure tray surface, no separator against
                        // the first cell (seam side stays borderless).
                        SizedBox(width: pad),
                        for (final (i, a) in widget.actions.indexed) ...[
                          if (i > 0)
                            Container(width: 1, color: ZInk.hairline(context)),
                          Expanded(child: _actionButton(a)),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              Transform.translate(
                offset: Offset(-offset, 0),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragStart: (_) => _anim.stop(),
                  onHorizontalDragUpdate: (d) => setState(
                    () => _offset = (_offset - d.delta.dx).clamp(0.0, reveal),
                  ),
                  onHorizontalDragEnd: (d) {
                    final v = d.primaryVelocity ?? 0;
                    if (v < -250) return _snapTo(reveal);
                    if (v > 250) return _snapTo(0);
                    _snapTo(_offset > reveal / 2 ? reveal : 0);
                  },
                  child: widget.child,
                ),
              ),
              if (offset > 0)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: constraints.maxWidth - offset,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _snapTo(0),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
