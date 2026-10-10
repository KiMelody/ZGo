import 'dart:async';

import 'package:flutter/material.dart';

import '../../protocol/conversation.dart';
import '../../state/device_session.dart';
import '../theme.dart';
import '../ui_settings.dart';
import 'jump_to_bottom_button.dart';
import 'subagent_feed.dart';
import 'timeline.dart';

/// Read-only transcript of a subagent's child session (task 09-13 R3):
/// the server treats `sess_subagent_agent_*` as a plain Conversation V4
/// session, so this page renders [childSessionId] through the main chat's
/// shared renderer ([ChatTurnGroup]/[ChatRow] — official parity: the web's
/// subagent pane reuses the conversation renderer readOnly) via the chat
/// page's shared [SubagentFeed] pool (acquire/release refcount) — it never
/// opens a private subscription, so Agent tile / sheet / this page share
/// ONE `gateway.subscribe` per child.
///
/// Read-only boundary (R4): no composer and nothing is ever sent to the
/// child session — every send-shaped affordance the shared renderer has is
/// gated off via its `readOnly` flag; the only write is stopping the
/// parent session's background work entry while the subagent runs.
class SubagentDetailPage extends StatefulWidget {
  final ChatGateway gateway;

  /// Shared child-session subscription pool owned by the chat page; this
  /// page only acquires/releases its reference.
  final SubagentFeed feed;

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

  /// Terminal-footer confirm window for the shared timeline render (D3
  /// pre-wiring): entry points that know the chat page's
  /// `turnFooterConfirmWindow` pass it through; everything else leaves it
  /// null and [effectiveConfirmWindow] falls back to the chat default.
  final Duration? confirmWindow;

  /// [confirmWindow] fallback — the chat page's own default window.
  Duration get effectiveConfirmWindow =>
      confirmWindow ?? const Duration(seconds: 3);

  const SubagentDetailPage({
    super.key,
    required this.gateway,
    required this.feed,
    required this.childSessionId,
    this.title,
    this.subagentType,
    this.parentSessionId,
    this.workId,
    this.running = false,
    this.confirmWindow,
  });

  @override
  State<SubagentDetailPage> createState() => _SubagentDetailPageState();
}

class _SubagentDetailPageState extends State<SubagentDetailPage> {
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

  /// Workspace file-preview plumbing for the shared renderer (tappable
  /// file names in tool cards). One instance per page, like the chat page.
  late final ChatPreview _preview = ChatPreview(widget.gateway);

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    widget.feed.acquire(widget.childSessionId);
    _armReadyTimeout();
  }

  @override
  void dispose() {
    _readyTimeout?.cancel();
    widget.feed.release(widget.childSessionId);
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
  /// yank the viewport. Runs at the top of the feed builder: the pool
  /// notifies for every child frame, the row-count compare filters those
  /// belonging to other children or non-growth updates. The count stays
  /// TOTAL rows (not turn groups): groups derive from rows one-way, so the
  /// monotonic growth semantics survive the shared-renderer switch.
  void _followNewRows(ConversationState state) {
    if (!_positionedAtBottom || _loadingOlder) return;
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

  /// The pool's acquire failure is silent by contract, so the page keeps
  /// its own degradation: if the shared subscription hasn't produced a
  /// ready snapshot within 15s, surface an error with a retry.
  void _armReadyTimeout() {
    _readyTimeout?.cancel();
    _readyTimeout = Timer(const Duration(seconds: 15), () {
      if (!mounted || _error != null) return;
      final state = widget.feed.childState(widget.childSessionId);
      // A late-arriving snapshot is fine; anything else — the subscribe
      // still pending (state null) or acked without a snapshot — is the
      // stall we surface.
      if (state != null && state.ready) return;
      // Live-observed 2026-09-15: a large child-session snapshot can kill
      // the desktop bridge mid-push, leaving the page spinning forever.
      // Surface it so the user can retry instead of waiting silently.
      setState(() => _error = tr(context, 'chat.subscribe.timeout'));
    });
  }

  /// Retry = release + acquire: refs hitting zero closes the stalled
  /// subscription, re-acquiring reopens it (a resubscribe itself triggers
  /// the fresh snapshot push — subscribe takes no snapshot parameter).
  void _retry() {
    widget.feed.release(widget.childSessionId);
    widget.feed.acquire(widget.childSessionId);
    if (mounted) setState(() => _error = null);
    _armReadyTimeout();
  }

  // ------------------------------------------------------------ history

  Future<void> _loadOlder() async {
    final state = widget.feed.childState(widget.childSessionId);
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
      // Subscription identity guard (HistoryPager.settle semantics): a
      // resubscribe swapped the state out from under this fetch — the page
      // belongs to a state nobody shows; drop it silently. (Map responses
      // only, as there — a bare List answer has no envelope to guard with.)
      if (res is Map &&
          state != widget.feed.childState(widget.childSessionId)) {
        return;
      }
      if (!mounted) return;
      final page = parseRowsRangeResponse(res, state: state);
      // The rows are immutable log entries — an epoch drift does not
      // invalidate them (round 23, see HistoryPager.settle): toast as a
      // trace, then apply the page anyway.
      if (!page.epochMatches) {
        if (mounted) _toast(tr(context, 'chat.loadOlder.stale'));
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

  /// Model subtitle under the AppBar title (design D4): the official web's
  /// provider display rule via [chatModelLabel]. Localized AnimatedBuilder
  /// so feed notifications repaint the subtitle without rebuilding the
  /// scaffold; not-ready / empty label renders nothing (no placeholder).
  Widget _modelSubtitle(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.feed,
      builder: (context, _) {
        final state = widget.feed.childState(widget.childSessionId);
        final label =
            state == null || !state.ready ? '' : chatModelLabel(state);
        if (label.isEmpty) return const SizedBox.shrink();
        return Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: ZType.caption.copyWith(
            color: ZInk.muted(context),
            fontFamily: 'monospace',
          ),
        );
      },
    );
  }

  /// Minimal onAction for the shared renderer: everything send-shaped is
  /// readOnly-gated, so this wrapper only ever carries read paths — run
  /// the future, surface failures as a toast (the page has no busy strip).
  Future<void> _runAction(
    String label,
    Future<dynamic> Function() action,
  ) async {
    try {
      await action();
    } catch (e) {
      _toast('$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _pageTitle(context),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            _modelSubtitle(context),
          ],
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
      // The feed drives everything state-shaped: it re-notifies whenever any
      // pooled child handle's state changes (and on subscribe completion), so
      // the spinner → transcript transition fires from here. Rebuild surface
      // cost accepted (same pattern as the Agent tile's child timeline).
      body: AnimatedBuilder(
        animation: widget.feed,
        builder: (context, _) {
          final state = widget.feed.childState(widget.childSessionId);
          if (_error != null) {
            return Material(
              color: ZColors.danger.withValues(alpha: 0.15),
              child: ListTile(
                dense: true,
                title: Text(
                  trP(context, 'chat.subscribe.failed', ['$_error']),
                  style: ZType.sub,
                ),
                trailing: TextButton(
                  onPressed: _retry,
                  child: Text(tr(context, 'tasks.retry')),
                ),
              ),
            );
          }
          if (state == null || !state.ready) {
            return const Center(child: CircularProgressIndicator());
          }
          _followNewRows(state);
          // Shared-renderer switch (D3): rows go through the main chat's
          // turn grouping — one ChatTurnGroup per turn, readOnly so every
          // send-shaped affordance stays hidden. childSessionRows drops
          // the spawn-time modelChange marker: the subtitle below the
          // title IS the model display (acceptance fix).
          final groups = groupChatRows(childSessionRows(state.rows));
          final itemCount = groups.length + (state.canLoadOlder ? 1 : 0);
          if (!_positionedAtBottom) {
            // R1b: land on the newest content on the first frame the list is
            // actually mounted — the follow pass only fires on LATER updates
            // and would miss the initial snapshot.
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
          return Stack(
            children: [
              RepaintBoundary(
                child: ListView.builder(
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
                    final group =
                        groups[index - (state.canLoadOlder ? 1 : 0)];
                    return ChatTurnGroup(
                      key: ValueKey('turn-${group.first['rowId']}'),
                      rows: group,
                      gateway: widget.gateway,
                      sessionId: widget.childSessionId,
                      onAction: _runAction,
                      state: state,
                      feed: widget.feed,
                      preview: _preview,
                      confirmWindow: widget.effectiveConfirmWindow,
                      workspaceLabel: null,
                      readOnly: true,
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
          );
        },
      ),
    );
  }
}
