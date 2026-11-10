import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import '../ui_settings.dart';
import '../widgets/sheet_scaffold.dart';

/// Error-detail bottom sheet (task 11-08-error-detail): the ONE place the
/// task row's `lastError` meta is rendered in full — opened from the turn
/// error preview line (timeline `_TurnErrorLine`) and from the start-failed
/// card (chat_page `_emptyOrStartFailed`).
///
/// Data contract: [error] is the map [TaskMetaPort.taskLastError] answers —
/// `{message, code?, traceId?, attribution?}` with ABSENT keys for missing
/// values (never null values). Every block below renders only when its value
/// is a non-blank string, so a shape-drifted payload degrades to fewer
/// blocks, never to an empty shell (PRD AC5). The values are raw wire text
/// and stay untranslated (PRD AC7).
class ErrorDetailSheet extends StatelessWidget {
  final Map<String, dynamic> error;

  /// Height cap of the scrollable message block (visual source: the mock's
  /// `max-height: 150px` — a long stack trace scrolls inside its own tile
  /// instead of pushing the copy button off the sheet).
  static const double messageMaxHeight = 150;

  /// Width of the kv label column (`code` / `attribution`).
  static const double _kvLabelWidth = 72;

  const ErrorDetailSheet({super.key, required this.error});

  @override
  Widget build(BuildContext context) {
    final message = errorMessageOf(error);
    final code = _fieldOf(error, 'code');
    final attribution = _fieldOf(error, 'attribution');
    final traceId = _fieldOf(error, 'traceId');
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          ZSpacing.screen, 0, ZSpacing.screen, ZSpacing.screen),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.error_outline,
                size: ZTile.iconSize,
                color: ZInk.dangerTone(context),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  tr(context, 'chat.error.recent'),
                  style: ZType.heading.copyWith(color: ZInk.solid(context)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // Expectation management: the task row only keeps the LAST error,
          // so the sheet must say it may belong to another turn.
          Text(
            tr(context, 'chat.error.recentHint'),
            style: ZType.caption.copyWith(color: ZInk.faint(context)),
          ),
          const SizedBox(height: 10),
          if (message != null) _messageBlock(context, message),
          if (code != null) _kv(context, 'code', code),
          if (attribution != null) _kv(context, 'attribution', attribution),
          if (traceId != null) _traceRow(context, traceId),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(shape: const StadiumBorder()),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: errorCopyText(error)));
                _toast(context, tr(context, 'chat.copied'));
              },
              child: Text(tr(context, 'chat.error.copyAll')),
            ),
          ),
        ],
      ),
    );
  }

  /// Full message on the tile surface, capped and internally scrollable —
  /// newlines are preserved (wire errors are often multi-paragraph).
  Widget _messageBlock(BuildContext context, String message) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: messageMaxHeight),
      decoration: BoxDecoration(
        color: ZInk.tile(context),
        borderRadius: BorderRadius.circular(ZRadius.field),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Text(
          message,
          style: ZType.body.copyWith(color: ZInk.soft(context)),
        ),
      ),
    );
  }

  /// `code` / `attribution` row: the wire field name as the label (the same
  /// identifiers the desktop shows — they are not prose and are what a
  /// support report needs), the value in the code face.
  Widget _kv(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _kvLabelWidth,
            child: Text(
              label,
              style: ZType.caption.copyWith(color: ZInk.faint(context)),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: ZType.caption.copyWith(
                fontFamily: 'monospace',
                color: ZInk.soft(context),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// TraceID line: the id ellipsizes, the neighbouring pill copies it —
  /// same key family as the task list's Copy-TraceID entry.
  Widget _traceRow(BuildContext context, String traceId) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              traceId,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ZType.caption.copyWith(
                fontFamily: 'monospace',
                color: ZInk.muted(context),
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            style: TextButton.styleFrom(
              backgroundColor: ZInk.tile(context),
              foregroundColor: ZInk.soft(context),
              shape: const StadiumBorder(),
              textStyle: ZType.caption,
              visualDensity: VisualDensity.compact,
            ),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: traceId));
              _toast(context, tr(context, 'tasks.traceIdCopied'));
            },
            child: Text(tr(context, 'tasks.action.copyTraceId')),
          ),
        ],
      ),
    );
  }

  /// 1s confirmation toast — the repository-wide copy-affordance idiom.
  static void _toast(BuildContext context, String copy) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(copy), duration: const Duration(seconds: 1)),
    );
  }
}

/// Opens [ErrorDetailSheet] from either entry point.
///
/// `useRootNavigator: false` keeps the sheet inside the chat route's
/// navigator — required for the dual-pane embedded pane (spec
/// interaction-patterns §6).
Future<void> showErrorDetailSheet(
  BuildContext context, {
  required Map<String, dynamic> error,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: false,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => zSheetScaffold(
      sheetContext,
      maxHeightFactor: 0.7,
      child: ErrorDetailSheet(error: error),
    ),
  );
}

/// The row's usable error message, null when absent/blank — the single gate
/// both entry points use for "does this surface show an error at all".
///
/// Returned TRIMMED: the value feeds the one-line previews, and a wire
/// message with leading whitespace would otherwise render a blank first
/// line (`maxLines: 1` keeps exactly that blank line).
String? errorMessageOf(Map<String, dynamic>? error) {
  final value = _fieldOf(error, 'message');
  return value?.trim();
}

/// The copy payload of 「复制完整报错」: `code — message` first (the one line a
/// paste into a report should lead with), then the other present fields as
/// `key: value` lines. Unset fields contribute nothing.
String errorCopyText(Map<String, dynamic> error) {
  final message = errorMessageOf(error);
  final code = _fieldOf(error, 'code');
  final attribution = _fieldOf(error, 'attribution');
  final traceId = _fieldOf(error, 'traceId');
  final head = message == null
      ? code
      : code == null
          ? message
          : '$code — $message';
  return [
    if (head != null) head,
    if (attribution != null) 'attribution: $attribution',
    if (traceId != null) 'traceId: $traceId',
  ].join('\n');
}

/// Non-blank string [key] of [error], null otherwise. Defensive on purpose:
/// the sheet is also reachable from tests and future callers that feed raw
/// wire shapes (the state layer already normalizes, this is the second
/// gate).
String? _fieldOf(Map<String, dynamic>? error, String key) {
  final value = error?[key];
  if (value is! String) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  return value;
}