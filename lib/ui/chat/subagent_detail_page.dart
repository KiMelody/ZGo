import 'dart:async';

import 'package:flutter/material.dart';

import '../../protocol/conversation.dart';
import '../../state/device_session.dart';
import '../theme.dart';
import '../ui_settings.dart';
import 'diff_view.dart';
import 'jump_to_bottom_button.dart';
import 'markdown_view.dart';
import 'tool_row_semantics.dart';

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

  // Scroll trio matching the chat page (task 09-23 R1): stick detection on
  // the controller listener, initial landing on the newest row, and
  // smooth follow while new rows stream in.
  final ScrollController _scrollController = ScrollController();
  bool _stickToBottom = true;
  bool _positionedAtBottom = false;
  int _lastRowCount = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _subscribe();
  }

  @override
  void dispose() {
    _readyTimeout?.cancel();
    _handle?.state.removeListener(_followNewRows);
    _handle?.close();
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    final stick = _isStuckToBottom();
    // Only a flip of the pinned state rebuilds (it toggles the
    // jump-to-bottom button); steady scrolling stays free.
    if (stick == _stickToBottom) return;
    if (mounted) setState(() => _stickToBottom = stick);
  }

  /// Live pinned-to-bottom check (40px slack, chat-page threshold).
  /// Post-frame callers must use this instead of the cached
  /// [_stickToBottom]: prepending older rows grows only maxScrollExtent
  /// (pixels unchanged → no controller notification), which would leave
  /// the cache stale.
  bool _isStuckToBottom() {
    if (!_scrollController.hasClients) return false;
    final position = _scrollController.position;
    return position.pixels >= position.maxScrollExtent - 40;
  }

  /// Streaming follow (R1c): smooth-scroll to the new bottom while the
  /// reader is pinned to it; scrolled-up readers keep their position and use
  /// the jump button to come back. Prepending older history ([_loadOlder])
  /// must never fire this. Like the chat page's follow pass, the pinned
  /// check runs on the posted frame — a delta landing mid-drag must not
  /// yank the viewport.
  void _followNewRows() {
    if (!_positionedAtBottom || _loadingOlder) return;
    final state = _handle?.state;
    if (state == null) return;
    final grew = state.rows.length > _lastRowCount;
    _lastRowCount = state.rows.length;
    if (!grew) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // The cached (pre-delta) pinned state decides — NOT a live
      // recomputation: an appended row grows maxScrollExtent before the
      // follow pass moves pixels, so a live check would read "scrolled
      // away" and kill the follow. Stale-cache risk after prepending is
      // covered by the recompute in [_loadOlder].
      if (!mounted || _loadingOlder || !_stickToBottom) return;
      _animateToBottom();
    });
  }

  /// Scrolls to the newest row (200ms easeOut) — shared by the follow pass
  /// and the jump-to-bottom button's tap.
  void _animateToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  Future<void> _subscribe() async {
    _readyTimeout?.cancel();
    // Retry path: drop the stalled subscription first so a fresh one (and a
    // fresh forced snapshot) goes out instead of reusing the dead handle.
    final stale = _handle;
    _handle = null;
    stale?.state.removeListener(_followNewRows);
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
      handle.state.addListener(_followNewRows);
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
      final res = await widget.gateway.conversationCommands.rowsRange(
        widget.childSessionId,
        // Cursor = the oldest held row (placeholder-proof; snapshot
        // `firstRowId` can be 1 — see ConversationState.oldestRowId).
        beforeRowId: state.oldestRowId,
        limit: 60,
      );
      final page = parseRowsRangeResponse(res, state: state);
      // Drop the whole result when the epoch moved.
      if (!page.epochMatches) {
        if (mounted) _toast(tr(context, 'chat.loadOlder.stale'));
        return;
      }
      final older = page.rows;
      if (older != null && older.isNotEmpty) {
        state
          ..hasMore = page.hasMore
          ..prependOlderRows(older);
        // Prepending keeps pixels (only maxScrollExtent grows → no scroll
        // notification), so the pinned cache is stale: recompute once the
        // taller list has laid out, else the jump button stays hidden.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scrollController.hasClients) return;
          final stick = _isStuckToBottom();
          if (stick != _stickToBottom) {
            setState(() => _stickToBottom = stick);
          }
        });
      } else if (state.rows.isNotEmpty) {
        state.hasMore = page.hasMore ?? false;
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
      await widget.gateway.conversationCommands.cancelBackgroundWork(parent, workId);
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
              icon: Icon(Icons.stop_circle_outlined,
                  color: ZInk.dangerTone(context)),
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
          : Stack(
              children: [
                RepaintBoundary(
                  child: AnimatedBuilder(
                    animation: handle.state,
                    builder: (context, _) {
                      final state = handle.state;
                      final itemCount =
                          state.rows.length + (state.canLoadOlder ? 1 : 0);
                      if (!_positionedAtBottom) {
                        // R1b: land on the newest content on the first frame
                        // the list is actually mounted — the state listener
                        // only fires on LATER updates and would miss the
                        // initial snapshot.
                        _positionedAtBottom = true;
                        _lastRowCount = state.rows.length;
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (!mounted || !_scrollController.hasClients) {
                            return;
                          }
                          _scrollController.jumpTo(
                            _scrollController.position.maxScrollExtent,
                          );
                        });
                      }
                      return ListView.builder(
                        controller: _scrollController,
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
                          final row = state
                              .rows[index - (state.canLoadOlder ? 1 : 0)];
                          return SubagentTimelineRow(row: row);
                        },
                      );
                    },
                  ),
                ),
                // Jump-to-newest control, bottom-right; the stick detection
                // in [_onScroll] drives its visibility.
                Positioned(
                  right: 16,
                  bottom: 16,
                  child: JumpToBottomButton(
                    visible: !_stickToBottom,
                    onPressed: _animateToBottom,
                  ),
                ),
              ],
            ),
    );
  }
}

/// Simplified read-only timeline row: assistant markdown, collapsible
/// reasoning, compact tool summaries (+ diff), plain task block; anything
/// else (turnHeader, timelineMarker, nested subagent rows…) renders as a
/// light divider. Shared by this page's list and the chat page's inline
/// Agent expansion (task internal-task).
class SubagentTimelineRow extends StatelessWidget {
  final Map<String, dynamic> row;

  const SubagentTimelineRow({super.key, required this.row});

  @override
  Widget build(BuildContext context) {
    switch (row['kind']) {
      case 'assistantText':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: AppMarkdown(row['text'] as String? ?? ''),
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
            child: AppMarkdown(text, bodyStyle: ZType.sub),
          ),
        ],
      ),
    );
  }
}

/// Compact tool row (chat page `_ToolCallTile` collapse pattern, task 09-23
/// R2): collapsed shows only the status icon + the per-tool summary
/// (from [toolRowSemantics] — the old second name·preview summary is
/// converged, Q6a) + diff +/- counts; the diff renders inside the expansion,
/// so a file edit no longer floods the timeline.
class _ToolSummary extends StatelessWidget {
  final Map<String, dynamic> row;

  const _ToolSummary({required this.row});

  @override
  Widget build(BuildContext context) {
    final summary = toolRowSemantics(
      row,
      locale: UiSettingsProvider.of(context)?.locale ?? 'zh-CN',
    );
    final color = switch (row['status'] as String? ?? '') {
      'running' || 'inputStreaming' || 'pendingApproval' => ZColors.sky400,
      'success' => ZInk.successTone(context),
      'error' => ZInk.dangerTone(context),
      'cancelled' => ZInk.warningTone(context),
      _ => ZInk.faint(context),
    };
    final diff = extractDiff(row);
    final title = Expanded(
      child: Text(
        summary.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: ZType.sub.copyWith(
          color: ZInk.muted(context),
          fontFamily: 'monospace',
        ),
      ),
    );
    final counts = [
      if (summary.additions > 0)
        Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Text(
            '+${summary.additions}',
            style: ZType.caption.copyWith(color: ZInk.successTone(context)),
          ),
        ),
      if (summary.deletions > 0)
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            '-${summary.deletions}',
            style: ZType.caption.copyWith(color: ZInk.dangerTone(context)),
          ),
        ),
    ];
    final leading = Icon(summary.icon, size: 13, color: color);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: diff == null
          // No diff → nothing to expand: static summary row (title fills the
          // remaining width, so the Expanded must sit in THIS row).
          ? Row(children: [leading, const SizedBox(width: 6), title, ...counts])
          : ListTileTheme.merge(
              // Keep the collapsed row on the same compact grid as the
              // plain (no-diff) rows.
              horizontalTitleGap: 6,
              minLeadingWidth: 13,
              child: ExpansionTile(
                dense: true,
                minTileHeight: ZTile.headHeight,
                tilePadding: EdgeInsets.zero,
                leading: leading,
                title: Row(children: [title, ...counts]),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: DiffView(diff: diff),
                  ),
                ],
              ),
            ),
    );
  }
}
