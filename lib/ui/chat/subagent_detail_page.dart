import 'dart:async';

import 'package:flutter/material.dart';

import '../../state/device_session.dart';
import '../theme.dart';
import '../ui_settings.dart';
import 'diff_view.dart';
import 'markdown_view.dart';

/// Read-only transcript of a subagent's child session (task 09-13 R3):
/// the server treats `sess_subagent_agent_*` as a plain Conversation V4
/// session, so this page subscribes directly to [childSessionId] and
/// renders a simplified timeline.
///
/// Read-only boundary (R4): no composer and nothing is ever sent to the
/// child session — the only action is stopping the parent session's
/// background work entry while the subagent still runs.
class SubagentDetailPage extends StatefulWidget {
  final ChatGateway gateway;

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

  const SubagentDetailPage({
    super.key,
    required this.gateway,
    required this.childSessionId,
    this.title,
    this.subagentType,
    this.parentSessionId,
    this.workId,
    this.running = false,
  });

  @override
  State<SubagentDetailPage> createState() => _SubagentDetailPageState();
}

class _SubagentDetailPageState extends State<SubagentDetailPage> {
  ChatHandle? _handle;
  String? _error;
  bool _loadingOlder = false;
  Timer? _readyTimeout;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void dispose() {
    _readyTimeout?.cancel();
    _handle?.close();
    super.dispose();
  }

  Future<void> _subscribe() async {
    _readyTimeout?.cancel();
    // Retry path: drop the stalled subscription first so a fresh one (and a
    // fresh forced snapshot) goes out instead of reusing the dead handle.
    final stale = _handle;
    _handle = null;
    await stale?.close();
    if (mounted) setState(() => _error = null);
    _readyTimeout = Timer(const Duration(seconds: 15), () {
      if (!mounted || _error != null) return;
      final state = _handle?.state;
      // A late-arriving snapshot is fine; anything else — the subscribe
      // still pending (state null) or acked without a snapshot — is the
      // stall we surface.
      if (state != null && state.ready) return;
      // Live-observed 2026-09-15: a large child-session snapshot can kill
      // the desktop bridge mid-push, leaving the page spinning forever.
      // Surface it so the user can retry instead of waiting silently.
      setState(() => _error = tr(context, 'chat.subscribe.timeout'));
    });
    try {
      final handle = await widget.gateway.subscribe(widget.childSessionId);
      if (!mounted) {
        await handle.close();
        return;
      }
      setState(() {
        _handle = handle;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  // ------------------------------------------------------------ history

  Future<void> _loadOlder() async {
    final state = _handle?.state;
    if (state == null || _loadingOlder) return;
    setState(() => _loadingOlder = true);
    try {
      final res = await widget.gateway.rowsRange(
        widget.childSessionId,
        beforeRowId: state.firstRowId,
        limit: 60,
      );
      List? rows;
      int? firstRowId;
      bool? hasMore;
      String? atLogEpoch;
      if (res is Map) {
        hasMore = res['hasMore'] as bool?;
        atLogEpoch = res['atLogEpoch'] as String?;
        // Web parity: drop the whole result when the epoch moved.
        if (!state.rangeEnvelopeMatches(atLogEpoch)) {
          if (mounted) _toast(tr(context, 'chat.loadOlder.stale'));
          return;
        }
        final rowsObj = res['rows'];
        if (rowsObj is Map) {
          rows = rowsObj['window'] as List? ?? rowsObj['rows'] as List?;
          firstRowId = (rowsObj['firstRowId'] as num?)?.toInt();
        } else if (rowsObj is List) {
          rows = rowsObj;
        }
        rows ??= res['items'] as List? ?? res['window'] as List?;
        firstRowId ??= (res['firstRowId'] as num?)?.toInt();
      } else if (res is List) {
        rows = res;
      }
      if (rows != null && rows.isNotEmpty) {
        final older = rows
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList()
          ..sort(
            (a, b) =>
                ((a['rowId'] as num?) ?? 0).compareTo((b['rowId'] as num?) ?? 0),
          );
        state
          ..hasMore = hasMore
          ..prependOlderRows(older, firstRowId);
      } else if (state.rows.isNotEmpty) {
        state.hasMore = hasMore ?? false;
        if (mounted) _toast(tr(context, 'chat.noOlder'));
      }
    } catch (e) {
      if (mounted) _toast(trP(context, 'chat.loadOlder.failed', ['$e']));
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
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
      await widget.gateway.cancelBackgroundWork(parent, workId);
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

  @override
  Widget build(BuildContext context) {
    final handle = _handle;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _pageTitle(context),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (widget.running)
            IconButton(
              tooltip: tr(context, 'chat.agents.stop'),
              icon: const Icon(Icons.stop_circle_outlined,
                  color: ZColors.danger),
              onPressed: _confirmStop,
            ),
        ],
      ),
      body: _error != null
          ? Material(
              color: ZColors.danger.withValues(alpha: 0.15),
              child: ListTile(
                dense: true,
                title: Text(
                  trP(context, 'chat.subscribe.failed', ['$_error']),
                  style: ZType.sub,
                ),
                trailing: TextButton(
                  onPressed: _subscribe,
                  child: Text(tr(context, 'tasks.retry')),
                ),
              ),
            )
          : handle == null || !handle.state.ready
          ? const Center(child: CircularProgressIndicator())
          : AnimatedBuilder(
              animation: handle.state,
              builder: (context, _) {
                final state = handle.state;
                final itemCount =
                    state.rows.length + (state.canLoadOlder ? 1 : 0);
                return ListView.builder(
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
                    final row =
                        state.rows[index - (state.canLoadOlder ? 1 : 0)];
                    return _timelineRow(context, row);
                  },
                );
              },
            ),
    );
  }

  /// Simplified read-only timeline: assistant markdown, collapsible
  /// reasoning, compact tool summaries (+ diff); anything else (turnHeader,
  /// timelineMarker, nested subagent rows…) renders as a light separator.
  Widget _timelineRow(BuildContext context, Map<String, dynamic> row) {
    switch (row['kind']) {
      case 'assistantText':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: ZLinkerMarkdown(row['text'] as String? ?? ''),
        );
      case 'reasoning':
        return _ReasoningStrip(
          text: row['text'] as String? ?? '',
          streaming: row['state'] == 'streaming',
        );
      case 'toolCall':
        return _ToolSummary(row: row);
      case 'userInput':
        // The subagent's task prompt: plain read-only block.
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: ZInk.tile(context),
            borderRadius: BorderRadius.circular(ZRadius.tile),
          ),
          child: Text(
            row['text'] as String? ?? '',
            style: ZType.body.copyWith(color: ZInk.soft(context)),
          ),
        );
      default:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Divider(height: 1, color: ZInk.hairline(context)),
        );
    }
  }
}

class _ReasoningStrip extends StatelessWidget {
  final String text;
  final bool streaming;

  const _ReasoningStrip({required this.text, this.streaming = false});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: ZInk.tile(context),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ZRadius.tile),
        side: BorderSide(color: ZInk.hairline(context)),
      ),
      child: ExpansionTile(
        dense: true,
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        title: Row(
          children: [
            Icon(
              Icons.psychology_outlined,
              size: 14,
              color: streaming ? ZColors.sky400 : ZInk.faint(context),
            ),
            const SizedBox(width: 6),
            Text(
              streaming
                  ? tr(context, 'chat.reasoning.thinking')
                  : tr(context, 'chat.reasoning'),
              style: ZType.sub.copyWith(color: ZInk.muted(context)),
            ),
          ],
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: ZLinkerMarkdown(text, bodyStyle: ZType.sub),
          ),
        ],
      ),
    );
  }
}

/// Compact tool row: status icon + toolName (+ input preview), with the
/// diff rendered inline when the row is a file edit.
class _ToolSummary extends StatelessWidget {
  final Map<String, dynamic> row;

  const _ToolSummary({required this.row});

  @override
  Widget build(BuildContext context) {
    final status = row['status'] as String? ?? '';
    final (icon, color) = switch (status) {
      'running' ||
      'inputStreaming' ||
      'pendingApproval' => (Icons.hourglass_top, ZColors.sky400),
      'success' => (Icons.check, ZColors.success),
      'error' => (Icons.error_outline, ZColors.danger),
      'cancelled' => (Icons.block, ZColors.warning),
      _ => (Icons.build_outlined, ZInk.faint(context)),
    };
    final name = row['toolName'] as String? ?? 'tool';
    final preview = row['inputText'] as String? ?? '';
    final diff = extractDiff(row);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 13, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  preview.isEmpty ? name : '$name · $preview',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ZType.sub.copyWith(
                    color: ZInk.muted(context),
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ],
          ),
          if (diff != null) DiffView(diff: diff),
        ],
      ),
    );
  }
}
