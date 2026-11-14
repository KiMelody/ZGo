import 'package:flutter/material.dart';

import '../../protocol/conversation_quote.dart';
import '../theme.dart';
import '../ui_settings.dart';

/// Composer-attached pending selection quotes (task 11-13-quote-comment-lite
/// R1). Mirrors the pending-files strip: a neutral sub-surface above the
/// input bar, one removable pill per quote (text preview + optional comment).
///
/// Purely presentational — the page owns the list and its lifecycle; this
/// widget answers an index for deletion.
class QuoteChipBar extends StatelessWidget {
  const QuoteChipBar({super.key, required this.quotes, required this.onRemove});

  final List<ConversationQuote> quotes;
  final void Function(int index) onRemove;

  @override
  Widget build(BuildContext context) {
    if (quotes.isEmpty) return const SizedBox.shrink();
    return Container(
      key: const ValueKey('quote-chip-bar'),
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: ZInk.tile(context),
        borderRadius: BorderRadius.circular(ZRadius.tile),
      ),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (var i = 0; i < quotes.length; i++)
            _QuoteChip(
              quote: quotes[i],
              onRemove: () => onRemove(i),
            ),
        ],
      ),
    );
  }
}

class _QuoteChip extends StatelessWidget {
  const _QuoteChip({required this.quote, required this.onRemove});

  final ConversationQuote quote;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final comment = quote.comment;
    return Container(
      constraints: const BoxConstraints(maxWidth: 320),
      padding: const EdgeInsets.fromLTRB(10, 4, 2, 4),
      decoration: BoxDecoration(
        color: ZInk.card(context),
        borderRadius: BorderRadius.circular(ZRadius.field),
        border: Border.all(color: ZInk.hairline(context)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.format_quote, size: 14, color: ZInk.muted(context)),
          const SizedBox(width: 6),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _oneLine(quote.text),
                  style: ZType.caption.copyWith(color: ZInk.soft(context)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (comment != null && comment.isNotEmpty)
                  Text(
                    _oneLine(comment),
                    style: ZType.caption.copyWith(color: ZInk.muted(context)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          IconButton(
            onPressed: onRemove,
            tooltip: tr(context, 'chat.selections.remove'),
            icon: const Icon(Icons.close, size: 14),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
        ],
      ),
    );
  }

  static String _oneLine(String text) =>
      text.replaceAll(RegExp(r'\s+'), ' ').trim();
}
