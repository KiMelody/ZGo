import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// One quick action revealed by swiping a list row to the left.
class SwipeAction {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const SwipeAction({
    required this.icon,
    required this.label,
    required this.color,
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
class SwipeActionsRow extends StatefulWidget {
  final Widget child;
  final List<SwipeAction> actions;

  const SwipeActionsRow({
    super.key,
    required this.child,
    required this.actions,
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
    return Material(
      color: action.color,
      child: InkWell(
        onTap: () {
          HapticFeedback.lightImpact();
          _snapTo(0);
          action.onTap();
        },
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(action.icon, size: 18, color: Colors.white),
            const SizedBox(height: 3),
            Text(
              action.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ZType.caption.copyWith(color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final reveal = _reveal.clamp(0.0, constraints.maxWidth);
        final offset = _offset.clamp(0.0, reveal);
        return ClipRect(
          child: Stack(
            children: [
              // The tray only ever paints the revealed strip (it rides the row
              // edge and is clipped), so a half-open drag never shows action
              // colours through the transparent row background.
              Positioned(
                top: 0,
                bottom: 0,
                right: offset - reveal,
                width: reveal,
                child: ExcludeSemantics(
                  excluding: offset == 0,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final a in widget.actions)
                        Expanded(child: _actionButton(a)),
                    ],
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
