import 'package:flutter/material.dart';

import '../../protocol/conversation_quote.dart';
import '../theme.dart';
import '../ui_settings.dart';
import 'markdown_view.dart';

/// Isolated selection surface of the quote entry (task 11-13-quote-comment-lite
/// R1): the message body is rendered inside a plain [SelectionArea] so the
/// transcript's scroll/long-press arena no longer competes with selection
/// gestures, then the picked segment is annotated and the page answers a
/// [ConversationQuote].
///
/// Read-only by construction: the page only reads the passed text and pops.
/// Markdown rows keep their rendering (`selectable: false` → plain Text),
/// which is exactly what [SelectionArea] can select across; user rows are
/// plain text.
class SelectionQuotePage extends StatefulWidget {
  const SelectionQuotePage({
    super.key,
    required this.text,
    this.markdown = false,
  });

  /// Raw message text (markdown source for assistant rows).
  final String text;

  /// Render [text] as markdown instead of a plain paragraph.
  final bool markdown;

  @override
  State<SelectionQuotePage> createState() => _SelectionQuotePageState();
}

class _SelectionQuotePageState extends State<SelectionQuotePage> {
  final GlobalKey<SelectionAreaState> _areaKey =
      GlobalKey<SelectionAreaState>();
  final TextEditingController _comment = TextEditingController();

  /// Latest selection (trimmed). Cached on every change so the footer can
  /// gate the Next action.
  String _selected = '';

  /// Step 2: the segment is fixed and the optional comment is being typed.
  bool _annotating = false;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  void _selectAll() {
    // Public SelectableRegion API; onSelectionChanged then refreshes
    // [_selected] like a manual drag would.
    _areaKey.currentState?.selectableRegion.selectAll();
  }

  void _confirm() {
    final comment = _comment.text.trim();
    Navigator.of(context).pop(
      ConversationQuote(
        text: _selected,
        comment: comment.isEmpty ? null : comment,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'chat.selections.quoteTitle')),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _annotating ? _annotateBody(context) : _selectBody(context),
            ),
            _footer(context),
          ],
        ),
      ),
    );
  }

  Widget _selectBody(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_selected.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                tr(context, 'chat.selections.quoteSelectHint'),
                style: ZType.caption.copyWith(color: ZInk.muted(context)),
              ),
            ),
          SelectionArea(
            key: _areaKey,
            onSelectionChanged: (content) {
              final next = content?.plainText.trim() ?? '';
              if (next == _selected) return;
              setState(() => _selected = next);
            },
            child: widget.markdown
                ? AppMarkdown(widget.text, selectable: false)
                : Text(widget.text, style: ZType.body),
          ),
        ],
      ),
    );
  }

  Widget _annotateBody(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: ZInk.tile(context),
              borderRadius: BorderRadius.circular(ZRadius.field),
              border: Border.all(color: ZInk.hairline(context)),
            ),
            child: Text(
              _selected,
              style: ZType.sub.copyWith(color: ZInk.soft(context)),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            tr(context, 'chat.selections.comment'),
            style: ZType.caption.copyWith(color: ZInk.muted(context)),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _comment,
            minLines: 2,
            maxLines: 4,
            maxLength: ConversationQuoteLimits.maxCommentLength,
            // The hard limit is enforced; the counter would only add noise.
            buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
            style: ZType.body,
            decoration: InputDecoration(
              hintText: tr(context, 'chat.selections.commentHint'),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(ZRadius.field),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _footer(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: ZInk.hairline(context))),
      ),
      child: Row(
        children: [
          if (_annotating)
            TextButton(
              onPressed: () => setState(() => _annotating = false),
              child: Text(tr(context, 'chat.selections.quoteBack')),
            )
          else
            TextButton(
              onPressed: _selectAll,
              child: Text(tr(context, 'chat.selections.quoteSelectAll')),
            ),
          const Spacer(),
          FilledButton(
            onPressed: _annotating
                ? _confirm
                : (_selected.isEmpty
                    ? null
                    : () => setState(() => _annotating = true)),
            child: Text(
              tr(
                context,
                _annotating
                    ? 'chat.selections.quoteConfirm'
                    : 'chat.selections.quoteNext',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
