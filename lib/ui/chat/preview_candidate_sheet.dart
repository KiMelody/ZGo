/// Candidate picker for an ambiguous relative-link resolve (task
/// 11-09-relative-link-resolve, design §歧义 UI): when the L2/L3 fallback
/// finds more than one file with the requested basename, the user picks
/// which one to open. Auto-picking the "shallowest" hit would be a guess the
/// UI cannot own; a visible choice can be re-made when it is wrong.
///
/// Visual tokens mirror [ErrorDetailSheet] (the same grabber / heading /
/// tile / stadium family): a title line, then one tappable tile per
/// candidate showing the workspace-relative path (the thing that actually
/// distinguishes the two files).
library;

import 'package:flutter/material.dart';

import '../theme.dart';
import '../ui_settings.dart';
import '../widgets/sheet_scaffold.dart';
import 'relative_link_resolver.dart';

/// Opens the candidate sheet and answers the picked absolute path, or null
/// when dismissed.
///
/// `useRootNavigator: false` keeps the sheet inside the chat route's
/// navigator — required for the dual-pane embedded pane (spec
/// interaction-patterns §6).
Future<String?> showPreviewCandidateSheet(
  BuildContext context, {
  required List<PreviewCandidate> candidates,
}) {
  return showModalBottomSheet<String>(
    context: context,
    useRootNavigator: false,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => zSheetScaffold(
      sheetContext,
      maxHeightFactor: 0.7,
      child: PreviewCandidateSheet(candidates: candidates),
    ),
  );
}

/// The sheet body (extracted so tests can mount it without a route).
class PreviewCandidateSheet extends StatelessWidget {
  final List<PreviewCandidate> candidates;

  const PreviewCandidateSheet({super.key, required this.candidates});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 0, 0, ZSpacing.screen),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: ZSpacing.screen),
            child: Row(
              children: [
                Icon(
                  Icons.manage_search,
                  size: ZTile.iconSize,
                  color: ZInk.muted(context),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    tr(context, 'chat.preview.candidatesTitle'),
                    style: ZType.heading.copyWith(color: ZInk.solid(context)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          for (final candidate in candidates)
            _CandidateTile(
              candidate: candidate,
              onTap: () => Navigator.of(context).pop(candidate.path),
            ),
        ],
      ),
    );
  }
}

class _CandidateTile extends StatelessWidget {
  final PreviewCandidate candidate;
  final VoidCallback onTap;

  const _CandidateTile({required this.candidate, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          ZSpacing.screen, 4, ZSpacing.screen, 4),
      child: Material(
        color: ZInk.tile(context),
        borderRadius: BorderRadius.circular(ZRadius.field),
        child: InkWell(
          borderRadius: BorderRadius.circular(ZRadius.field),
          onTap: onTap,
          // Only the hit box grows to the 44x48 floor; the drawn icon stays
          // 16 (interaction-patterns §2's explicit-expand pattern).
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: zTouchHeight),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: ZTile.headPadding,
                vertical: 12,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.description_outlined,
                    size: ZTile.iconSize,
                    color: ZInk.muted(context),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      candidate.label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style:
                          ZType.body.copyWith(color: ZInk.soft(context)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
