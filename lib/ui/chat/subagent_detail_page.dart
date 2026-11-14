import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../../protocol/conversation.dart';
import '../../state/device_session.dart';
import '../theme.dart';
import '../ui_settings.dart';
import 'jump_to_bottom_button.dart';
import 'subagent_feed.dart';
import 'timeline.dart';
import 'transcript_viewport.dart';

/// Read-only transcript of a subagent's child session (task 09-13 R3):
/// the server treats `sess_subagent_agent_*` as a plain Conversation V4
/// session, so this page renders [childSessionId] through the main chat's
/// shared renderer ([ChatTurnGroup]/[ChatRow] — official parity: the web's
/// subagent pane reuses the conversation renderer readOnly) via the chat
/// page's shared [SubagentFeed] pool (acquire/release refcount) — it never
/// opens a private subscription, so Agent tile / sheet / this page share
/// ONE `ConversationPort.subscribe` per child.
///
/// Read-only boundary (R4): no composer and nothing is ever sent to the
/// child session — every send-shaped affordance the shared renderer has is
/// gated off via its `readOnly` flag; the only write is stopping the
/// parent session's background work entry while the subagent runs.
class SubagentDetailPage extends StatefulWidget {
  /// Page-construction boundary (ADR-0008 rule ii): the union of the roles
  /// this page's render tree needs. Inner rows narrow to
  /// [ConversationPort] + [ChatPageActions].
  final ChatPageHost host;

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
    required this.host,
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
  Timer? _readyTimeout;

  /// One open auto-fill per page (chat-page parity): the snapshot is a tail
  /// window — pull one older page the first time the gate is open.
  bool _autoFilled = false;

  // Scroll trio matching the chat page (task 09-23 R1): stick detection on
  // the controller listener, initial landing on the newest row, and
  // smooth follow while new rows stream in. Everything else about the
  // scroll position (drag/settled bookkeeping, prefetch, DRAG HOLD parking,
  // the prepend anchor chain, the veil) lives in the shared viewport.
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _viewportListKey = GlobalKey();
  bool _stickToBottom = true;
  bool _positionedAtBottom = false;
  int _lastRowCount = 0;

  /// The shared history-load viewport (task 10-29-transcript-viewport) —
  /// the same module as the main chat, so the pinned prepend now captures a
  /// frozen frame and lands on the measured newest end instead of playing a
  /// visible return-to-bottom animation (the declared user-visible change).
  late final TranscriptViewport _viewport = TranscriptViewport(
    fetch: _fetchOlderRows,
    currentState: () => widget.feed.childState(widget.childSessionId),
    currentSessionId: () => widget.childSessionId,
    isStickToBottom: () => _stickToBottom,
    // The list's own bottom padding (16) — the pinned landing formula.
    listBottomPadding: 16,
    onToast: _onHistoryToast,
    postFrame: (callback) => WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) callback();
    }),
  );

  /// The conversationRowsRangeV4 RPC behind the viewport.
  Future<dynamic> _fetchOlderRows(
    String sessionId, {
    int? beforeRowId,
    int limit = 60,
  }) =>
      widget.host.conversationCommands.rowsRange(
        sessionId,
        beforeRowId: beforeRowId,
        limit: limit,
      );

  /// Drill-in callbacks for the read-only render tree (fork / side-chat
  /// stay masked by `readOnly`, so only the drill-in chain is provided).
  late final ChatPageActions _actions = ChatPageActions(
    openSubagent: (context, feed,
            {required childSessionId,
            title,
            subagentType,
            workId,
            parentSessionId,
            running = false,
            confirmWindow}) =>
        openSubagentDetail(
      context,
      widget.host,
      feed: feed,
      childSessionId: childSessionId,
      title: title,
      subagentType: subagentType,
      workId: workId,
      parentSessionId: parentSessionId,
      running: running,
      confirmWindow: confirmWindow,
    ),
  );

  /// Toast reactions to the viewport's typed outcomes — i18n/UX stay here.
  void _onHistoryToast(HistoryToastStep step) {
    if (!mounted) return;
    switch (step) {
      case HistoryStale():
        _toast(tr(context, 'chat.loadOlder.stale'));
      case HistoryNoOlder():
        _toast(tr(context, 'chat.noOlder'));
      case HistoryFailed(:final error):
        _toast(trP(context, 'chat.loadOlder.failed', ['$error']));
    }
  }

  /// Frozen-frame capture source ([TranscriptVeil] mounts it).
  final GlobalKey _viewportFreezeKey = GlobalKey();

  /// Workspace file-preview plumbing for the shared renderer (tappable
  /// file names in tool cards). One instance per page, like the chat page.
  /// The rows callback is the CHILD session's (design 11-09 L2): links in a
  /// subagent transcript resolve against the files that subagent read.
  late final ChatPreview _preview = ChatPreview(
    widget.host,
    contextRows: () =>
        widget.feed.childState(widget.childSessionId)?.rows ?? const [],
  );

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _viewport.attach(
      controller: _scrollController,
      listKey: _viewportListKey,
      freezeKey: _viewportFreezeKey,
      // Child-session rows drop the spawn-time modelChange marker; the
      // viewport's group/endKey derivation must match the rows actually
      // rendered above it.
      groupRows: (rows) => groupChatRows(childSessionRows(rows)),
    );
    widget.feed.acquire(widget.childSessionId);
    _armReadyTimeout();
  }

  @override
  void dispose() {
    _readyTimeout?.cancel();
    widget.feed.release(widget.childSessionId);
    _viewport.dispose();
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
  /// the jump button to come back. Prepending older history (the viewport's
  /// chain) must never fire this: the re-entry gate skips the follow while a
  /// prepend chain owns the viewport. Like the chat page's follow pass, the
  /// pinned check runs on the posted frame — a delta landing mid-drag must
  /// not yank the viewport. Runs at the top of the feed builder: the pool
  /// notifies for every child frame, the row-count compare filters those
  /// belonging to other children or non-growth updates. The count stays
  /// TOTAL rows (not turn groups): groups derive from rows one-way, so the
  /// monotonic growth semantics survive the shared-renderer switch.
  void _followNewRows(ConversationState state) {
    if (!_positionedAtBottom || _viewport.loadingOlder) return;
    final grew = state.rows.length > _lastRowCount;
    _lastRowCount = state.rows.length;
    if (!grew) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // The cached (pre-delta) pinned state decides — NOT a live
      // recomputation: an appended row grows maxScrollExtent before the
      // follow pass moves pixels, so a live check would read "scrolled
      // away" and kill the follow. Stale-cache risk after prepending is
      // covered by the viewport's own pinned landing.
      if (!mounted || _viewport.loadingOlder || !_stickToBottom) return;
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

  /// Scroll-events router — identity routing, idle bookkeeping, the
  /// prefetch/pull triggers, veil lift and the ScrollEnd flush all live in
  /// the shared viewport (the detail page installs no rubber-band physics,
  /// so it simply has no pull entry).
  bool _onNotification(ScrollNotification n) {
    _viewport.onScrollNotification(n);
    return false;
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
      await widget.host.conversationCommands.cancelBackgroundWork(parent, workId);
    } catch (e) {
      if (!mounted) return;
      _toast(
        e is CommandSuspendedException
            ? tr(context, 'chat.suspend.pending')
            : '$e',
      );
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

  /// Live running view (design D3): the stop button flips with the child
  /// session's LAST turnHeader row, not the entry-time [widget.running]
  /// snapshot (gap-matrix debt — a subagent finishing while the page is
  /// open used to keep the button until re-entry). Not-ready sessions and
  /// headerless transcripts have no wire verdict yet → entry snapshot.
  bool _childRunning() {
    final state = widget.feed.childState(widget.childSessionId);
    if (state == null || !state.ready) return widget.running;
    for (final row in state.rows.reversed) {
      if (row['kind'] == 'turnHeader') {
        return (row['state'] as String? ?? '') == 'running';
      }
    }
    return widget.running;
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
          // Feed-driven so the stop button flips live with the child
          // session's turnHeader (design D3, same pattern as
          // [_modelSubtitle] below the title).
          AnimatedBuilder(
            animation: widget.feed,
            builder: (context, _) => _childRunning()
                ? IconButton(
                    tooltip: tr(context, 'chat.agents.stop'),
                    icon: Icon(Icons.stop_circle_outlined,
                        color: ZInk.dangerTone(context)),
                    onPressed: _confirmStop,
                  )
                : const SizedBox.shrink(),
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
          // Open auto-fill (chat-page parity): the snapshot is a tail
          // window — pull one older page the first time the gate is open.
          // Post-frame: the gate flip notifies listeners, which is illegal
          // mid-build.
          if (!_autoFilled && state.canLoadOlder) {
            _autoFilled = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _viewport.loadOlder();
            });
          }
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
              // Prepend veil + frozen frame (the shared viewport's round-21/24
              // mechanism): the veil hides only the PAINT — layout and the
              // anchor measurement run normally underneath — while the frozen
              // capture of the last pre-prepend frame stands still on top.
              // Arming is capture-gated: a failed capture keeps the list
              // visible (never a blank flash).
              NotificationListener<ScrollNotification>(
                onNotification: _onNotification,
                // The viewport's gate and anchor-cache flips rebuild the
                // ListView shell (spinner + scrollCacheExtent) only.
                child: ListenableBuilder(
                  listenable: _viewport,
                  builder: (context, _) {
                    final cacheExtent = _viewport.anchorCacheExtent;
                    return TranscriptVeil(
                      viewport: _viewport,
                      child: ListView.builder(
                        key: _viewportListKey,
                        controller: _scrollController,
                        // Widened only across a compensation's landing
                        // frames — the anchor resurfaces inside it.
                        scrollCacheExtent: cacheExtent == null
                            ? null
                            : ScrollCacheExtent.pixels(cacheExtent),
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                        itemCount: itemCount,
                        itemBuilder: (context, index) {
                          if (state.canLoadOlder && index == 0) {
                            return Center(
                              child: TextButton.icon(
                                onPressed: _viewport.loadingOlder
                                    ? null
                                    : _viewport.loadOlder,
                                icon: _viewport.loadingOlder
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
                            conversation: widget.host,
                            sessionId: widget.childSessionId,
                            onAction: _runAction,
                            state: state,
                            feed: widget.feed,
                            preview: _preview,
                            confirmWindow: widget.effectiveConfirmWindow,
                            // Drill-in chain only: fork / side-chat stay
                            // masked by readOnly.
                            actions: _actions,
                            readOnly: true,
                          );
                        },
                      ),
                    );
                  },
                ),
              ),
              // Jump-to-newest control, bottom-right; the stick detection
              // in [_onScroll] drives its visibility. It stays ABOVE the
              // frozen frame so the reader can always leave the freeze.
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
