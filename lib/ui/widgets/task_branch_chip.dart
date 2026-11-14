import 'package:flutter/material.dart';

import '../theme.dart';
import '../ui_settings.dart';

/// Read-only worktree branch label of a task row (R2: display only — no tap
/// target, no action). The caller decides whether to mount it: a non-empty
/// `worktreeRoot` plus a resolved branch name. Detached HEAD / a missing
/// branch name never reaches this widget.
class TaskBranchChip extends StatelessWidget {
  const TaskBranchChip({super.key, required this.branchName});

  final String branchName;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: tr(context, 'tasks.branch.worktree'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: ZInk.tile(context),
          borderRadius: BorderRadius.circular(ZRadius.mini),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.alt_route, size: 11, color: ZInk.faint(context)),
            const SizedBox(width: 3),
            // Branch names can be long; the chip never pushes the row's
            // title/time off the layout.
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 120),
              child: Text(
                branchName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ZType.caption.copyWith(color: ZInk.faint(context)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
