import 'package:flutter/material.dart';

import 'theme.dart';

/// Status pill shared by the task list rows and the chat turn footers:
/// translucent background in the phase color + small icon + label.
/// Running phases get a spinner instead of a static icon.
///
/// [solid] matches the official mobile list pills: an opaque surface
/// (#46BF72 for done, #001D3D for running) with contrasting text.
class PhasePill extends StatelessWidget {
  final String label;
  final String phase;

  /// Official mobile-list style: opaque background, 10px label.
  final bool solid;

  const PhasePill({super.key, required this.label, required this.phase, this.solid = false});

  @override
  Widget build(BuildContext context) {
    final running = phase == 'running' || phase == 'prewarming';
    final (color, icon) = switch (phase) {
      'running' || 'prewarming' => (ZColors.sky400, Icons.autorenew),
      'completedSuccess' => (ZColors.success, Icons.check),
      'error' || 'failed' => (ZColors.danger, Icons.error_outline),
      'completedInterrupted' => (
          ZColors.neutral400,
          Icons.remove_circle_outline
        ),
      _ => (ZColors.neutral400, Icons.circle_outlined),
    };
    if (solid) {
      final done = phase == 'completedSuccess';
      final bg = done
          ? ZColors.pillSuccessBg
          : running
              ? ZColors.pillRunningBg
              : color.withValues(alpha: 0.15);
      final fg = done
          ? Colors.black
          : running
              ? ZColors.neutral200.withValues(alpha: 0.87)
              : color;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (running)
              SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  valueColor: AlwaysStoppedAnimation(fg),
                ),
              )
            else
              Icon(icon, size: 10, color: fg),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                    fontSize: 10, fontWeight: FontWeight.w500, color: fg)),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (running)
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                valueColor: AlwaysStoppedAnimation(color),
              ),
            )
          else
            Icon(icon, size: 10, color: color),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w500,
                  color: color)),
        ],
      ),
    );
  }
}
