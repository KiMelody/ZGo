import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show ValueListenable, listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';

import '../../protocol/channel_client.dart';
import '../../protocol/conversation.dart';
import '../../state/device_session.dart';
import '../../state/entitlement_poller.dart';
import '../../state/new_task_defaults.dart';
import '../../state/quota_reset.dart';
import '../quota_reset_dialog.dart';
import '../slash_items.dart';
import '../theme.dart';
import '../ui_settings.dart';
import 'confirm_gate.dart';
import 'copy_mappings.dart';
import 'git_panel.dart';
import 'interaction_answer.dart';
import 'goal_panel.dart';
import 'jump_to_bottom_button.dart';
import 'mention_sheet.dart';
import 'subagent_feed.dart';
import 'timeline.dart';
import 'top_bounce_physics.dart';
import 'transcript_viewport.dart';
import 'turn_navigator.dart';
import 'workflow_card.dart';
import 'workflow_run_page.dart';

/// Native chat view for one task (session), backed by Conversation V4 over
/// the page-construction boundary [ChatPageHost] (ADR-0008 rule ii).
/// Draft mode (no [sessionId]): the first message issues `createSession`
/// with the draft model/mode/thought config.
class ChatPage extends StatefulWidget {
  final ChatPageHost host;
  final String? sessionId;
  final String title;
  final ThemeController? theme;

  /// Dual-pane desktop layout: embedded in the right pane, so no back
  /// button in the app bar (there is no route to pop inside the pane).
  final bool embedded;

  /// Pre-fill the composer (e.g. a slash command picked on the list page).
  final String? initialComposerText;

  /// Optional workspace chip shown next to the task title (chat
  /// second header row).
  final String? workspaceLabel;

  /// The workspace this DRAFT page was opened in (ignored for existing
  /// sessions). The first send asks the gateway to re-point the bridge here
  /// when a reconnect moved it elsewhere; null keeps the legacy behavior
  /// (create in whatever workspace is active).
  final String? draftWorkspacePath;

  /// Pinned state of the opened task (from the list entry) so the 更多 menu
  /// can show 置顶任务 / 取消置顶任务 like the web and toggle it.
  final bool initialPinned;

  /// Opens the plan-usage page (quota warning banner / pill action). Left
  /// null where no usage route exists; the banner then shows the model
  /// switch only.
  final VoidCallback? onOpenUsage;

  /// Off-peak host for the queue-position system card (D2/OQ1): when this
  /// session is bound to an off-peak task reporting `queuePosition > 0`,
  /// the chat renders the official `#N in queue` card. Null hides it
  /// (draft pages, pages opened without an off-peak surface).
  final OffPeakHost? offPeakHost;

  /// Opens the off-peak tasks page from the card's action (design D2). The
  /// action only renders when provided (official `a=!!t`) — the
  /// bound-presentation decision adds no in-chat creation entry.
  final VoidCallback? onOpenOffPeak;

  /// Terminal-footer confirm window (F): a turnHeader going terminal must
  /// hold this long before the phase pill and feedback row render — bridge
  /// replays flip a live turn terminal for a few seconds. Injectable so
  /// tests can shrink it.
  final Duration turnFooterConfirmWindow;

  /// Subagent regression hysteresis (E): a running report within this
  /// window of an observed terminal keeps the terminal display. Injectable
  /// so tests can shrink it.
  final Duration subagentHysteresis;

  const ChatPage({
    super.key,
    required this.host,
    this.sessionId,
    required this.title,
    this.theme,
    this.embedded = false,
    this.initialComposerText,
    this.workspaceLabel,
    this.draftWorkspacePath,
    this.initialPinned = false,
    this.onOpenUsage,
    this.offPeakHost,
    this.onOpenOffPeak,
    this.turnFooterConfirmWindow = const Duration(seconds: 3),
    this.subagentHysteresis = const Duration(seconds: 15),
  });

  @override
  State<ChatPage> createState() => _ChatPageState();
}

/// Direct-ask dialog for the side-chat entry (D2). Stateful so it owns its
/// [TextEditingController]: the flow pops the dialog before the command
/// round-trip, and the exit transition keeps rebuilding the field — a
/// controller disposed at pop time would be used after disposal.
class _AskSideChatDialog extends StatefulWidget {
  const _AskSideChatDialog({
    required this.title,
    required this.hint,
    required this.cancelCopy,
    required this.confirmCopy,
  });

  final String title;
  final String hint;
  final String cancelCopy;
  final String confirmCopy;

  @override
  State<_AskSideChatDialog> createState() => _AskSideChatDialogState();
}

class _AskSideChatDialogState extends State<_AskSideChatDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _controller.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        minLines: 1,
        maxLines: 5,
        textInputAction: TextInputAction.send,
        decoration: InputDecoration(hintText: widget.hint),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.cancelCopy),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.confirmCopy)),
      ],
    );
  }
}

class _PendingFile {
  final String fileName;
  final String mime;
  final Uint8List bytes;

  _PendingFile(this.fileName, this.mime, this.bytes);
}

/// The most recent optimistic model/thought switch (design 10-01): kept so
/// a bridge-lost switch can be auto-retried ONCE when the authoritative
/// frame overrides it. A new switch replaces the stored one; [retried]
/// guards against retry loops.
class _LastSwitch {
  _LastSwitch(this.sid, this.provider, this.model, this.thought, this.patch);

  final String sid;
  final String provider;
  final String model;
  final String thought;

  /// Re-lands the optimistic patch (the sheet's captured closure — merges
  /// onto whatever config is current at call time).
  final void Function() patch;
  final DateTime at = clock.now();
  bool retried = false;
}

class _ChatPageState extends State<ChatPage> {
  ChatHandle? _handle;
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();

  /// Workspace file-preview plumbing (markdown images, entry dispatch) —
  /// one per page so the image cache spans the whole session view.
  late final _preview = ChatPreview(widget.host);

  /// Workspace Git view shared by the status group (D2), the message change
  /// capsule (D3), the review panel (D4) and the write flows (D5) — one read
  /// chain, one notify. Inert when the page has no workspace.
  late final GitWorkspaceController _git = GitWorkspaceController(
    widget.host.git,
    widget.host.workspacePath ?? '',
  );

  /// Page-level navigation callbacks handed to the timeline and the
  /// status-strip widgets (ADR-0008 rule ii): fork / side-chat / subagent
  /// drill-in. The two flows live on this page so the pushed pages reuse
  /// the same host, workspace chip and theme; inner rows only hold the
  /// callbacks.
  late final ChatPageActions _actions = ChatPageActions(
    fork: _forkToNewSession,
    askInSideChat: _startSelectionSideChat,
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
    openWorkflowRun: (context, {
      required runId,
      display,
      title,
      workStartedAt,
      workEndedAt,
    }) {
      final state = _state;
      if (state == null) return;
      Navigator.of(context).push(
        zRoute(
          (_) => WorkflowRunPage(
            state: state,
            runId: runId,
            display: display,
            title: title,
            workStartedAt: workStartedAt,
            workEndedAt: workEndedAt,
          ),
        ),
      );
    },
  );

  /// Marks the message list subtree for the history anchor-compensation
  /// measurements (see [_measureAnchor] / [_compensateAnchor]).
  final GlobalKey _listKey = GlobalKey();
  String? _sessionId;

  /// Composer-draft persistence key: the session once created, else a
  /// workspace-scoped placeholder that dies with the first successful
  /// send (design 10-20). Follows [_sessionId] live so a draft page that
  /// fails its follow-up send after createSession keeps its text under
  /// the new key.
  String get _draftKey =>
      _sessionId ?? 'draft.${widget.host.chatWorkspaceId ?? ''}';

  /// Debounce for draft writes (500ms): the only reliable persistence
  /// window on mobile is during editing — an OS kill fires no lifecycle
  /// callback, so saves cannot wait for dispose.
  Timer? _draftPersistTimer;
  String? _error;
  bool _sending = false;

  /// Observed turn phase of the active handle: the turn-terminal overview
  /// refresh (design 11-01 §2) fires on the running→terminal edge, seeded
  /// from the first snapshot so a page opened mid-turn still sees it.
  bool _turnWasRunning = false;

  /// Off-peak queue-position card (D2): the bound task's live queue
  /// position (`>0` renders the card) and its title (empty → the official
  /// `chatCreated.defaultTitle`). Null position = no card. Fetched once
  /// per page open (OQ2: enter-time pull, no polling).
  int? _offPeakQueuePosition;
  String? _offPeakTaskTitle;

  /// The latest optimistic model/thought switch the config sheet issued
  /// (design 10-01) — the raw material for the one-shot bridge-lost retry
  /// in [_onConfigMaybeReverted]. Null until a sheet switch happens.
  _LastSwitch? _lastSwitch;

  /// Session ids that already got the one-shot Start-plan auto switch
  /// (design 10-24 §4, PRD §6). A successful switch stops matching the
  /// trigger on its own (the provider is no longer a Start plan); this
  /// marker exists for the failure case, where the trigger would otherwise
  /// fire again on every entitlement refresh. Once marked, the banner and
  /// the manual sheet remain the recovery path.
  final Set<String> _autoSwitched = {};

  /// Entitled `account:*` provider ids read alongside the last entitlement
  /// snapshot (design 10-24 §2). Null = not read yet or the provider
  /// settings view was unreachable — [StartPlanAutoSwitch.evaluate] then
  /// declines to judge.
  Set<String>? _entitledProviderIds;

  /// The history-load viewport (task 10-29-transcript-viewport): page-load
  /// decisions (entry gate, identity guard, DRAG HOLD parking, prepend
  /// commit, chain generation), the four triggers, the anchor measurement +
  /// frozen-frame veil + landing compensation, the re-entry gate and the
  /// layout-cache pre-widen all live in the module. This page keeps the
  /// ListView shell, the streaming follow, the jump-to-bottom button, the
  /// keyboard shrink-follow and the turn navigator; it only toasts the
  /// typed outcomes and reads the read-only gates.
  late final TranscriptViewport _viewport = TranscriptViewport(
    fetch: _fetchOlderRows,
    currentState: () => _state,
    currentSessionId: () => _sessionId,
    isStickToBottom: () => _stickToBottom,
    listBottomPadding: _listPadding.bottom,
    onToast: _onHistoryToast,
    // Every old post-frame callback started with `if (!mounted) return` —
    // the seam carries that guard so the viewport's frame callbacks keep
    // the exact old semantics.
    postFrame: (callback) => WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) callback();
    }),
  );

  /// The conversationRowsRangeV4 RPC behind [TranscriptViewport].
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

  /// Turn navigator directory (design §2.1): ascending rowIds of the real
  /// user queries in the loaded window, recomputed in the state listener
  /// only when `(rows.length, firstRowId, lastRowId)` changes — streaming
  /// text deltas hit the memo key and never recompute (PRD AC: the cell
  /// list does not recompute on text deltas).
  List<int> _queryRowIds = const [];
  (int, String?, String?)? _queryDirKey;

  /// Turn navigator highlight: the query at the viewport top, computed on
  /// scroll ([_updateActiveQueryIndex]). A ValueNotifier so a highlight
  /// change repaints only the strip, never the page.
  final ValueNotifier<int?> _activeQueryIndex = ValueNotifier(null);

  /// True while the keyboard occupies the viewport (IME inset past the
  /// 100/80 hysteresis band, R2 10-16). Flipped by [_KeyboardProbe] —
  /// ChatPage.build must never read the inset itself (2026-09-20 掉帧红线,
  /// chat-conventions §8.2). Consumed by the leaf slots that fold the
  /// keyboard-occupied viewport: the second header row and the pre-list
  /// banner run. Portrait heights never trip the `short` (<480) check while
  /// the IME shrinks the body to roughly that territory, so the keyboard
  /// needs its own equivalently-collapsed layout.
  final ValueNotifier<bool> _imeOccupied = ValueNotifier(false);

  /// Turn navigator expanded-overlay handle (design §3.1): the page pushes
  /// "the list scrolled" into the component via
  /// [TurnNavigatorState.collapse] from the scroll hook ([_onListScroll]).
  /// Expanded state and its animation live inside the component — never
  /// here; the component does not import the page.
  final GlobalKey<TurnNavigatorState> _turnNavigatorKey =
      GlobalKey<TurnNavigatorState>();

  /// [RepaintBoundary] around the list — the frozen-frame capture source,
  /// injected into the viewport through [TranscriptViewport.attach] and
  /// mounted by [TranscriptVeil].
  final GlobalKey _freezeKey = GlobalKey();

  /// Temporary oversize cacheExtent for the turn-navigator jump (task
  /// 10-14; null = platform default). The target turn may sit outside the
  /// ~250px layout cache, so the cache widens for a frame, the landing is
  /// MEASURED (never estimated — chat-conventions §9), and the extent is
  /// restored. The prepend chain's own widen lives in the viewport
  /// ([TranscriptViewport.anchorCacheExtent]); the two never hold at once,
  /// so build reads `viewport.anchorCacheExtent ?? _jumpCacheExtent`.
  double? _jumpCacheExtent;
  bool _showSlash = false;

  /// @-mention picker state (see _maybeOpenMentionPicker).
  bool _mentionOpen = false;
  int _mentionTriggerEnd = 0;
  bool get _mentionEnabled => true;
  String? _progress;
  final List<_PendingFile> _pendingFiles = [];
  double? _uploadProgress;
  WorkspacePrep? _prep;
  List<SkillEntry> _skills = [];
  bool _skillsLoading = false;

  /// Subagent catalog (`subagents.list`), feeding the `/` capability list as
  /// `@name` entries (official slash panel merges commands/skills/subagents).
  List<Map<String, dynamic>> _subagents = const [];

  /// Draft-mode (no session yet) model/mode/thought selection, passed as
  /// `config` to createSession on first send.
  final Map<String, String> _draftConfig = {};

  /// Keys the user picked explicitly in the config sheet (`onDraftChange`).
  /// They skip sanitizeNewTaskConfig's silent "follow the desktop" drop,
  /// while the initState seeds from the global UiSettings defaults keep it
  /// (PRD model-value-split §3).
  final Set<String> _draftExplicit = {};

  /// Whether to keep the view pinned to the newest message. Starts true so
  /// opening the chat lands at the bottom; the user scrolling up unpins it.
  bool _stickToBottom = true;

  /// List viewport dimension seen by the last metrics pass — primer for the
  /// keyboard shrink-follow ([_onListMetrics]); null until the first
  /// [ScrollMetricsNotification] arrives.
  double? _lastViewportDim;

  /// Set right after a shrink-follow jump: the jump used the max extent the
  /// layout had at that instant, and SliverList then settles the freshly
  /// revealed bottom rows and revises the extent (visible when the inset
  /// lands in one step — split screen, keyboard shortcuts — instead of
  /// animating frame by frame). The next metrics notification earns one
  /// catch-up jump so a pinned view really sits on the newest row.
  bool _pinCatchUpPending = false;

  /// Content bottom seen by the last scroll-follow pass; null until the
  /// initial snapshot is positioned.
  double? _lastContentBottom;

  /// Starts from [ChatPage.initialPinned]; flips when the 更多 pin toggle runs.
  bool _pinned = false;

  /// Plan-quota snapshot for the composer pill / warning banner. Fetched
  /// once per page open through the session-wide poller (staleness cached
  /// on the gateway side, no background timer); absence just hides the
  /// pill — quota problems never surface as chat errors.
  EntitlementView? _entitlement;

  /// Shared child-session subscription pool + subagent terminal hysteresis
  /// (Agent tile expansion / running works-bar entries / goal-panel tiles).
  late final SubagentFeed _feed = SubagentFeed(
    conversation: widget.host,
    regressionHysteresis: widget.subagentHysteresis,
  );

  /// Inline edit-resend (D1, official 09 shoot): rowId (stringified) of the
  /// user message currently edited in place; null = no editing. The card
  /// replaces the bubble inside its turn group; send/cancel converge here
  /// ([_sendUserEdit]) so bubbles hold no gateway commands.
  final ValueNotifier<String?> _editingRowId = ValueNotifier(null);

  ConversationState? get _state => _handle?.state;

  /// Cross-terminal deletion tombstone (task 10-06 chat tombstone): the
  /// desktop's sessions-index dropped this session id — another terminal
  /// deleted the session. The page stays READ-ONLY (the user may still
  /// copy content out): banner + disabled send, no pop, no data clearing.
  bool get _tombstoned {
    final id = _sessionId;
    return id != null && widget.host.isSessionDeleted(id);
  }

  /// Authoritative subscribe refusal (10-11 sessionNotFound terminal):
  /// the desktop's subscribe channel answered fault.subscribe.
  /// sessionNotFound for this session — it is neither active nor
  /// persisted, so the subscription is terminally failed. Same read-only
  /// page form as [_tombstoned] (banner + disabled send, no pop), but
  /// epistemically authoritative: the channel REJECTED the session where
  /// the tombstone only INFERS a deletion from index diffs. When both
  /// hold, this one takes the banner (authority over inference).
  bool get _sessionMissing {
    final id = _sessionId;
    return id != null && widget.host.isSessionMissing(id);
  }

  @override
  void initState() {
    super.initState();
    _sessionId = widget.sessionId;
    _pinned = widget.initialPinned;
    if (_sessionId == null) {
      // Draft mode: seed the model/mode/thought picks with the global
      // new-task defaults (UiSettings; empty = follow desktop, not seeded).
      // Read WITHOUT registering a dependency — dependOnInheritedWidgetOf
      // ExactType is illegal in initState, getInheritedWidgetOfExactType
      // is the dependency-free lookup.
      final ui = context
          .getInheritedWidgetOfExactType<UiSettingsProvider>()
          ?.settings;
      if (ui != null) {
        if (ui.newTaskMode.isNotEmpty) _draftConfig['mode'] = ui.newTaskMode;
        if (ui.newTaskModel.isNotEmpty) {
          _draftConfig['model'] = ui.newTaskModel;
        }
        if (ui.newTaskThought.isNotEmpty) {
          _draftConfig['thought'] = ui.newTaskThought;
        }
      }
    }
    final initial = widget.initialComposerText;
    if (initial != null && initial.isNotEmpty) {
      _inputController.text = initial;
    } else {
      // Composer-draft restore (design 10-20): list-page prefills win over
      // a stored draft; the store degrades to a no-op when empty.
      unawaited(_restoreDraft());
    }
    _scrollController.addListener(_onScroll);
    _viewport.attach(
      controller: _scrollController,
      listKey: _listKey,
      freezeKey: _freezeKey,
    );
    if (_sessionId != null) {
      _subscribe();
      unawaited(_loadOffPeakQueue());
    }
    _loadPrep();
    _loadEntitlement();
    _inputController.addListener(() {
      final text = _inputController.text;
      final show =
          (text.startsWith('/') || text.startsWith('\$')) &&
          !text.contains(' ');
      if (show != _showSlash && mounted) {
        setState(() => _showSlash = show);
      }
      _maybeOpenMentionPicker(text);
      _scheduleDraftPersist();
    });
  }

  /// Reads the stored draft into the composer. Guards against clobbering
  /// anything the user managed to type/pick before the async load landed.
  Future<void> _restoreDraft() async {
    final snapshot = await widget.host.chatDraftStore.restore(_draftKey);
    if (!mounted || snapshot == null) return;
    if (snapshot.text.isNotEmpty && _inputController.text.isEmpty) {
      _inputController.text = snapshot.text;
      _inputController.selection = TextSelection.collapsed(
        offset: snapshot.text.length,
      );
    }
    if (snapshot.files.isNotEmpty && _pendingFiles.isEmpty) {
      setState(() {
        _pendingFiles.addAll([
          for (final f in snapshot.files) _PendingFile(f.name, f.mime, f.bytes),
        ]);
      });
    }
  }

  /// Debounced draft upsert; an emptied composer (the `_send()` success
  /// paths all clear it) converges here into an entry removal.
  void _scheduleDraftPersist() {
    _draftPersistTimer?.cancel();
    _draftPersistTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(_persistDraft());
    });
  }

  Future<void> _persistDraft() {
    return widget.host.chatDraftStore.saveText(
      _draftKey,
      _inputController.text,
      _pendingFiles.length,
    );
  }

  /// D2: resolve the off-peak queue position bound to this session. The
  /// off-peak list keys each run by its produced `sessionId`; only a
  /// position `>0` renders the card (the official `chatCreated.queued`
  /// fallback is intentionally dropped — design D2/OQ1: no-number and
  /// unbound rows render nothing). A failed pull keeps the card hidden:
  /// it is an enhancement, never an error surface.
  Future<void> _loadOffPeakQueue() async {
    final host = widget.offPeakHost;
    final id = _sessionId;
    if (host == null || id == null) return;
    try {
      final tasks = await host.offPeak.list();
      final match = tasks.where((t) => t.sessionId == id).firstOrNull;
      if (!mounted) return;
      final position = match?.queuePosition;
      final title = match?.title.trim() ?? '';
      setState(() {
        _offPeakQueuePosition =
            (position != null && position > 0) ? position : null;
        _offPeakTaskTitle = title.isEmpty ? null : title;
      });
    } catch (_) {
      // Enhancement only: a failed pull renders no card.
    }
  }

  /// D2 off-peak queue card — the official `$It` component (@315439717),
  /// bound-presentation variant: title = task title (fallback
  /// `chatCreated.defaultTitle`), body = `{queuedAt} · {boundHint}`, moon
  /// icon box, and an optional "open off-peak tasks" action. Hidden until
  /// [_offPeakQueuePosition] is resolved (>0).
  Widget _offPeakQueueCard(BuildContext context) {
    final position = _offPeakQueuePosition;
    if (position == null) return const SizedBox.shrink();
    final title = _offPeakTaskTitle ??
        tr(context, 'offPeak.chatCreated.defaultTitle');
    final body =
        '${trP(context, 'offPeak.chatCreated.queuedAt', ['$position'])}'
        ' · ${tr(context, 'offPeak.chatCreated.boundHint')}';
    return _contentCol(
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: ZInk.card(context).withValues(alpha: 0.70),
            borderRadius: BorderRadius.circular(ZRadius.tile),
            border: Border.all(
              color: ZInk.cardBorder(context).withValues(alpha: 0.70),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: ZInk.barTrackSoft(context),
                  borderRadius: BorderRadius.circular(ZRadius.field),
                ),
                child: Icon(Icons.dark_mode_outlined,
                    size: 20, color: ZInk.muted(context)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ZType.bodyStrong.copyWith(
                            color: ZInk.solid(context))),
                    const SizedBox(height: 2),
                    Text(body,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ZType.body.copyWith(
                            color: ZInk.faint(context))),
                  ],
                ),
              ),
              if (widget.onOpenOffPeak != null) ...[
                const SizedBox(width: 12),
                TextButton(
                  onPressed: widget.onOpenOffPeak,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(ZRadius.field),
                      side: BorderSide(
                          color: ZInk.cardBorder(context)
                              .withValues(alpha: 0.70)),
                    ),
                  ),
                  child: Text(tr(context, 'offPeak.chatCreated.open')),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// @-mention handling: typing `@` at word start opens the mention
  /// picker; the picked reference replaces the trigger and gets a trailing
  /// space. Debounced by the sheet-open flag.
  void _maybeOpenMentionPicker(String text) {
    if (_mentionOpen || !_mentionEnabled) return;
    final sel = _inputController.selection;
    if (!sel.isValid) return;
    final i = sel.baseOffset;
    if (i < 1 || i > text.length) return;
    if (text[i - 1] != '@') return;
    const newlines = '\n';
    final atWordStart =
        i == 1 ||
        text[i - 2] == ' ' ||
        text[i - 2] == newlines;
    if (!atWordStart) return;
    _mentionOpen = true;
    _mentionTriggerEnd = i;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final entry = await showMentionSheet(context, widget.host);
      _mentionOpen = false;
      if (!mounted || entry == null) return;
      final start =
          (_mentionTriggerEnd - 1).clamp(0, _inputController.text.length);
      final next = applyMentionInsert(
          _inputController.text, _mentionTriggerEnd, entry.insert);
      // The `@` trigger is replaced by the full insert + one trailing space.
      _inputController.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(
            offset: start + entry.insert.length + 1),
      );
    });
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final max = _scrollController.position.maxScrollExtent;
    final stick = _scrollController.position.pixels >= max - 40;
    // Scroll notifications arrive per frame: only a flip of the pinned state
    // rebuilds (it toggles the jump-to-bottom button), steady scrolling stays
    // free.
    if (stick == _stickToBottom) return;
    // A FALSE sample taken while OUR OWN programmatic motion carries the
    // viewport (the open/follow glide, jump-to-bottom, keyboard catch-up) is
    // not the reader leaving the bottom: the 200ms glide sweeps the middle
    // of the list and targets an extent ESTIMATE that the descent itself can
    // revise upward, so it can end short of the real maxScrollExtent. Letting
    // that sample stick leaves the pin off for good, and the open auto-load's
    // prepend then anchors to the reading position instead of the newest end
    // (A7 device acceptance, 2026-10-29). The opposite flip — the motion
    // reaching the end — still lands, so the jump-to-bottom glide keeps
    // restoring the pin.
    if (!stick && _viewport.isPositioning) return;
    debugPrint('[anchor] stick=$stick pixels='
        '${_scrollController.position.pixels.toStringAsFixed(1)} max=$max');
    if (mounted) setState(() => _stickToBottom = stick);
  }

  /// Scroll-events router: identity routing, the turn navigator's collapse +
  /// highlight slices, and the history slice forwarded to the viewport
  /// ([TranscriptViewport.onScrollNotification]).
  ///
  /// Identity routing (same pattern as [_onListMetrics]): the subtree has
  /// sibling scrollables — diff cards and expanded code blocks scroll
  /// horizontally — and their notifications bubble through here too. A
  /// horizontal drag would otherwise almost always satisfy the prefetch
  /// window and fire a 60-row history load the user never asked for.
  bool _onListScroll(ScrollNotification n) {
    if (!_scrollController.hasClients) return false;
    final notificationContext = n.context;
    final scrollable = notificationContext == null
        ? null
        : Scrollable.maybeOf(notificationContext);
    if (scrollable == null ||
        !identical(scrollable.position, _scrollController.position)) {
      return false;
    }
    // Expanded-navigator dismissal (design §3.1, four collapse routes):
    // any scroll of THIS list collapses the long-press overlay. No-op
    // while collapsed; identity routing above keeps sibling scrollables
    // (diff cards, code blocks) from dismissing it.
    _turnNavigatorKey.currentState?.collapse();
    // History physics (idle bookkeeping, prefetch/pull triggers, veil lift,
    // ScrollEnd flush) — all inside the viewport.
    _viewport.onScrollNotification(n);
    if (n is ScrollUpdateNotification || n is ScrollEndNotification) {
      // Navigator highlight rides the same pass, post-frame (design §2.2).
      _scheduleActiveQueryUpdate();
    }
    return false;
  }

  /// Keyboard shrink-follow (2026-09-20 真机): with resizeToAvoidBottomInset
  /// the IME animation compresses the list viewport frame by frame while the
  /// scroll offset stays put — content stays anchored to the viewport top and
  /// the newest rows slide under the composer. While pinned to the bottom,
  /// jump along on every shrink frame. jumpTo, not animateTo: the IME
  /// animation already paces the motion (insets arrive per frame), a second
  /// easing curve would fight it. One extra catch-up jump follows the shrink
  /// jump (see [_pinCatchUpPending]) — the SliverList revises its max extent
  /// a frame later. Keyboard-down recovery needs nothing: the offset is
  /// clamped back and the pixels >= max - 40 stick test above keeps holding.
  /// Content growth is not this listener's business — the viewport dimension
  /// doesn't shrink then, and [_scrollToBottom] owns the follow. The
  /// notification's metrics is a detached copy, so routing happens by
  /// position identity: only the main list's scrollable drives the jump (the
  /// floating status strip's own scrollable — a sibling Stack branch — cannot
  /// bubble here; the check keeps the listener honest if it ever moves above
  /// the Stack).
  bool _onListMetrics(ScrollMetricsNotification notification) {
    if (!_scrollController.hasClients) return false;
    final scrollable = Scrollable.maybeOf(notification.context);
    if (scrollable == null ||
        !identical(scrollable.position, _scrollController.position)) {
      return false;
    }
    final previous = _lastViewportDim;
    final dim = notification.metrics.viewportDimension;
    _lastViewportDim = dim;
    final shrunk = previous != null && previous - dim > 0.5;
    final catchUp = _pinCatchUpPending;
    _pinCatchUpPending = shrunk;
    if (_stickToBottom && (shrunk || catchUp)) {
      debugPrint('[anchor] shrink-follow jump max='
          '${_scrollController.position.maxScrollExtent.toStringAsFixed(1)}');
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    }
    return false;
  }

  Future<void> _loadPrep() async {
    try {
      final prep = await widget.host.prepareWorkspace();
      if (mounted) {
        setState(() => _prep = prep);
        // Model options are the auto switch's target pool (design 10-24 §4);
        // they usually land after the entitlement snapshot.
        _maybeAutoSwitchStartPlan();
      }
    } catch (_) {}
    if (mounted) setState(() => _skillsLoading = true);
    try {
      final skills = await widget.host.skills();
      if (mounted) setState(() => _skills = skills);
    } catch (_) {
      if (mounted) setState(() => _skills = const []);
    } finally {
      if (mounted) setState(() => _skillsLoading = false);
    }
    try {
      final subagents = await widget.host.mentionSubagents();
      if (mounted) setState(() => _subagents = subagents);
    } catch (_) {
      if (mounted) setState(() => _subagents = const []);
    }
  }

  @override
  void dispose() {
    // mobile-view-state back to workspace-only (the phone left this task).
    try {
      widget.host.sendViewState();
    } catch (_) {}
    // Absence memory recovery (10-06 tombstone + 10-11 missing): the page
    // held this id's reader in both sets — release them so the add-only
    // sets do not outlive the page.
    final sessionId = _sessionId;
    if (sessionId != null) {
      widget.host.forgetDeletedSession(sessionId);
      widget.host.forgetMissingSession(sessionId);
    }
    _handle?.close();
    _feed.dispose();
    _git.dispose();
    _editingRowId.dispose();
    // Draft flush: a non-empty composer survives page death (back-out,
    // pane switch, hot restart); an already-cleared one was removed by
    // the debounced write after the send that cleared it.
    _draftPersistTimer?.cancel();
    if (_inputController.text.isNotEmpty || _pendingFiles.isNotEmpty) {
      unawaited(_persistDraft());
    }
    _inputController.dispose();
    _viewport.dispose();
    _scrollController.dispose();
    _activeQueryIndex.dispose();
    _imeOccupied.dispose();
    super.dispose();
  }

  /// Inline edit send (D1): the rewind switch maps onto the 3.14
  /// `workspaceMode` wire field — 'rewind' goes out, preserve stays OFF the
  /// wire (the desktop default; old-desktop compatible, F1). Success closes
  /// the editor; failure toasts and KEEPS the edit state for retry.
  Future<void> _sendUserEdit(
    Map<String, dynamic> target,
    String newText,
    bool rewind,
  ) async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    final locale = localeOf(context);
    try {
      await widget.host.conversationCommands.editUserQuery(
        sessionId,
        target,
        newText,
        workspaceMode: rewind ? 'rewind' : null,
      );
      _editingRowId.value = null;
    } catch (e) {
      debugPrint('[chat] editUserQuery: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              trP(context, 'chat.action.edit.failed', [
                commandErrorCopy('$e', locale) ?? '$e',
              ]),
            ),
          ),
        );
      }
    }
  }

  /// Turn-terminal trigger of the task-overview refresh (design 11-01 §2).
  ///
  /// Observation point = `ConversationState.control.phase` leaving the
  /// running class (`isRunning`: running/prewarming) — the same predicate
  /// the stop button uses. Chosen over scanning `turnHeader.state` for
  /// [turnTerminalPhases] because it is one control field on the live
  /// snapshot, independent of which rows are inside the session's tail
  /// window. `turnHeader.state` may also carry plain `completed` on the
  /// wire (mapped by statusToPhase), so a raw-string compare would miss a
  /// real terminal.
  ///
  /// The refresh is a status-correction net, not the visibility trigger: the
  /// row already entered the overview at create time with `status=null`; the
  /// terminal frame is what turns it into the real status word.
  void _onTurnPhaseChanged() {
    final state = _state;
    if (state == null) return;
    final running = state.isRunning;
    final wasRunning = _turnWasRunning;
    _turnWasRunning = running;
    if (!wasRunning || running) return;
    // User-action trigger: bypass the cadence throttle. The edge is already
    // single-shot (`_turnWasRunning`) and a turn terminal is not a storm
    // source — the anti-swallow wait inside the seam still applies.
    unawaited(widget.host.refreshTaskOverview(bypassThrottle: true));
  }

  Future<void> _subscribe() async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    try {
      final handle = await widget.host
          .subscribe(sessionId)
          .timeout(const Duration(seconds: 60));
      if (!mounted) {
        await handle.close();
        return;
      }
      setState(() {
        _handle = handle;
        _error = null;
      });
      // mobile-view-state: the desktop shows 「手机正在操作此任务」 from it.
      widget.host.sendViewState(taskId: sessionId);
      handle.state.addListener(_scrollToBottom);
      handle.state.addListener(_onConfigMaybeReverted);
      handle.state.addListener(_refreshQueryDirectory);
      // Turn-terminal trigger (design 11-01 §2): seed the observed phase
      // from the first snapshot so a page opened mid-turn still sees the
      // running→terminal edge.
      handle.state.addListener(_onTurnPhaseChanged);
      _turnWasRunning = handle.state.isRunning;
      // The snapshot may already be applied when the handle resolves —
      // seed the directory now (the memo key makes a redundant call free).
      _refreshQueryDirectory();
      // Start-plan auto switch (design 10-24 §4): the handle's first
      // snapshot may not carry `config` yet — re-check once when it does.
      if (handle.state.config == null) {
        handle.state.addListener(_autoSwitchWhenConfigReady);
      }
      _maybeAutoSwitchStartPlan();
      // Terminal-hysteresis memory rides the parent conversation (subagent
      // rows + backgroundWorks).
      _feed.observe(handle.state);
      // The server snapshot is a tail window (can be as few as 3 rows).
      // The client shows the full history immediately, so
      // auto-load the missing older rows once on open.
      if (handle.state.canLoadOlder) {
        await _viewport.loadOlder();
      }
      // Explicitly position at the newest message: the state listener only
      // fires on LATER updates and misses the initial snapshot.
      _scrollToBottom();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final max = _scrollController.position.maxScrollExtent;
      // Follow only when content actually grew (new rows appended);
      // in-place refreshes (background-task progress) never move the view.
      final grew = _lastContentBottom == null || max > _lastContentBottom! + 0.5;
      _lastContentBottom = max;
      // A prepend's compensation chain owns the viewport while pending —
      // its stick landing re-lands on the MEASURED newest end. An
      // animateTo(max) fired in between races it on the SliverList's
      // extent ESTIMATE (tall rows skew it by hundreds of px) and the
      // loser's target survives: the offset parks past the true end
      // (09-22 round 13 test: expected the true bottom, landed 160px
      // past it after the extent estimate shrank).
      if (!grew || !_stickToBottom || _viewport.compensationInFlight) {
        debugPrint('[anchor] follow-skip grew=$grew stick=$_stickToBottom '
            'px=${_scrollController.position.pixels.toStringAsFixed(1)}');
        return;
      }
      debugPrint('[anchor] follow-fire px='
          '${_scrollController.position.pixels.toStringAsFixed(1)}');
      _animateToBottom();
    });
  }

  /// Scrolls to the newest row (200ms easeOut) — the one motion shared by the
  /// follow-on-new-content pass above and the jump-to-bottom button's tap.
  void _animateToBottom() {
    if (!_scrollController.hasClients) return;
    debugPrint('[anchor] anim-bottom px='
        '${_scrollController.position.pixels.toStringAsFixed(1)} '
        'stick=$_stickToBottom from='
        '${StackTrace.current.toString().split('\n').take(5).join(' / ')}');
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  // ---------------------------------------------------- turn navigator

  /// Directory refresh (design §2.1): the memo key makes text-delta
  /// notifies free — only a row-set shape change recomputes. Runs as a
  /// state listener; [setState] fires only when the directory value really
  /// changed.
  void _refreshQueryDirectory() {
    final state = _state;
    if (state == null || !mounted) return;
    final rows = state.rows;
    final key = (
      rows.length,
      rows.isEmpty ? null : '${rows.first['rowId']}',
      rows.isEmpty ? null : '${rows.last['rowId']}',
    );
    if (_queryDirKey == key) return;
    _queryDirKey = key;
    final next = turnNavigatorQueryRowIds(rows);
    if (listEquals(next, _queryRowIds)) return;
    setState(() => _queryRowIds = next);
    // The highlight may follow the new directory (a fresh query appended
    // while pinned to the bottom arrives without any scroll notification).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateActiveQueryIndex();
    });
  }

  /// Highlight scheduling: scroll notifications fire BEFORE their frame's
  /// layout, so computing inline reads the PREVIOUS frame's boxes — a jump
  /// or drag release would leave the highlight one layout behind with
  /// nothing to correct it. Scheduling post-frame reads the settled layout
  /// instead (coalesced to one pass per frame).
  bool _activeQueryScheduled = false;

  void _scheduleActiveQueryUpdate() {
    if (_activeQueryScheduled || _queryRowIds.length < 2) return;
    _activeQueryScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _activeQueryScheduled = false;
      if (mounted) _updateActiveQueryIndex();
    });
  }

  /// Highlight pass (design §2.2): the first built query group at/over the
  /// viewport top wins; when every built query sits above it, the last one
  /// does (the nearest above). Built groups form one contiguous SliverList
  /// window, so "last built above" IS the nearest above. When no query
  /// group is measurable (viewport deep inside a long answer, beyond the
  /// layout cache), the current value stands — no flicker.
  void _updateActiveQueryIndex() {
    final queries = _queryRowIds;
    if (queries.length < 2 || !_scrollController.hasClients) return;
    final viewport = _listViewportBox();
    if (viewport == null) return;
    final viewportTop = viewport.localToGlobal(Offset.zero).dy;
    int? active;
    for (final (widget, box) in _builtGroups()) {
      final first = widget.rows.first['rowId'];
      if (first is! num) continue;
      final index = queries.indexOf(first.toInt());
      if (index < 0) continue;
      if (box.localToGlobal(Offset.zero).dy >= viewportTop - 40) {
        active = index;
        break;
      }
      active = index;
    }
    if (active == null || active == _activeQueryIndex.value) return;
    _activeQueryIndex.value = active;
  }

  /// Navigator tap (design §2.3): detach the bottom pin, then land the
  /// tapped query on the viewport top — measured, never estimated
  /// (chat-conventions §9). The gates keep the jump from racing an active
  /// drag, a prepend compensation chain, or another programmatic scroll.
  void _jumpToQuery(int rowId) {
    if (!_scrollController.hasClients) return;
    if (!_viewport.canJumpToQuery) return;
    if (_stickToBottom && mounted) setState(() => _stickToBottom = false);
    _landOnQuery(rowId, hop: 0);
  }

  /// Upper bound for the jump's one-frame cache widen (same ceiling the
  /// anchor compensation uses).
  static const double _kJumpMaxCacheExtent = 120000.0;

  /// Measured landing on a query turn group: `target = pixels +
  /// (boxTop - viewportTop)` from real RenderBoxes; off-window targets
  /// get the cache widened (hop 0) or a coarse side probe (hop 1) first so
  /// layout walks in — the estimate only positions the probe or sizes the
  /// cache, never the final landing.
  Future<void> _landOnQuery(int rowId, {required int hop}) async {
    if (!mounted || !_scrollController.hasClients) return;
    final position = _scrollController.position;
    final viewport = _listViewportBox();
    if (viewport == null) return;
    final viewportTop = viewport.localToGlobal(Offset.zero).dy;
    final groupKey = ValueKey('turn-$rowId');
    RenderBox? box;
    for (final (widget, candidate) in _builtGroups()) {
      if (widget.key == groupKey) {
        box = candidate;
        break;
      }
    }
    if (box != null) {
      final target = (position.pixels +
              (box.localToGlobal(Offset.zero).dy - viewportTop))
          .clamp(0.0, position.maxScrollExtent);
      debugPrint('[nav] jump rowId=$rowId hop=$hop '
          'px=${position.pixels.toStringAsFixed(1)} -> '
          '${target.toStringAsFixed(1)}');
      // Keep the widened cache through the glide: restoring it first lets
      // the SliverList revert to the extent ESTIMATE mid-flight and the
      // animation gets clamped by the noisy value (parks short of the true
      // end). With the cache wide, max stays exact for the whole flight.
      await _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
      if (mounted && _jumpCacheExtent != null) {
        setState(() => _jumpCacheExtent = null);
      }
      return;
    }
    if (hop == 0) {
      // Off-window target: widen the layout cache for a frame so
      // SliverList lays out down/up to it, then measure (the width covers
      // both directions at the current extent, ×2 headroom for the
      // SliverList's extent estimate — same ceiling as the anchor chain).
      setState(() {
        _jumpCacheExtent = math.min(
          (position.maxScrollExtent + position.viewportDimension) * 2,
          _kJumpMaxCacheExtent,
        );
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _landOnQuery(rowId, hop: 1);
      });
      return;
    }
    if (hop == 1) {
      // Still not built with the widened cache (enormous session): coarse
      // probe to the target's side, let the real layout walk in, then the
      // measured landing — the estimate-grade-anchor discipline of
      // [_compensateAnchor], never a landing on the estimate itself.
      var towardTop = true;
      for (final (widget, _) in _builtGroups()) {
        final first = widget.rows.first['rowId'];
        if (first is num && first.toInt() > rowId) {
          towardTop = false;
          break;
        }
      }
      _scrollController.jumpTo(towardTop ? 0.0 : position.maxScrollExtent);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _landOnQuery(rowId, hop: 2);
      });
      return;
    }
    // Degenerate: unmeasurable even at the probe — give up where we are.
    if (_jumpCacheExtent != null) {
      setState(() => _jumpCacheExtent = null);
    }
  }

  void _toast(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// Config-revert notice (design 09-25 D3): an authoritative snapshot
  /// overrode a still-fresh optimistic model/thought switch (the command
  /// was lost in a bridge swing) — surface it instead of silently
  /// snapping the sheet back. The state flag is consume-on-read; the
  /// `state.updated` confirmation path never sets it.
  ///
  /// Design 10-01: before reverting honestly, a switch that is still fresh
  /// (≤15s) and never retried is re-sent ONCE with the same parameters —
  /// the desktop's enqueue path cannot replay model switches, so the app
  /// bridges the crash window itself. A second override always falls back
  /// to the revert notice; no loops.
  void _onConfigMaybeReverted() {
    final state = _handle?.state;
    if (state == null || !state.consumeConfigReverted()) return;
    final last = _lastSwitch;
    final retryable = last != null &&
        !last.retried &&
        clock.now().difference(last.at) <= _switchRetryWindow;
    if (retryable) {
      last.retried = true;
      unawaited(_retryLastSwitch(last));
      return;
    }
    if (!mounted) return;
    _toast(tr(context, 'chat.sheet.switchReverted'));
  }

  /// How long after a switch its bridge-lost re-send is still worth trying.
  static const Duration _switchRetryWindow = Duration(seconds: 15);

  /// Re-issues the lost switch (same parameters — the command is a setting,
  /// idempotent) and re-lands the optimistic patch; any failure or a later
  /// override lands on the honest revert notice (see above).
  Future<void> _retryLastSwitch(_LastSwitch last) async {
    debugPrint('[chat] switch retry '
        'model=${last.model} thought=${last.thought}');
    try {
      await widget.host.conversationCommands.switchModelConfig(
        last.sid,
        provider: last.provider,
        model: last.model,
        thought: last.thought,
      );
    } catch (e) {
      debugPrint('[chat] switch retry failed: $e');
      if (!mounted) return;
      _toast(tr(context, 'chat.sheet.switchReverted'));
      return;
    }
    last.patch();
    if (!mounted) return;
    _toast(tr(context, 'chat.sheet.switchRetrying'));
  }

  /// Switches the live session to [option] — the config sheet's model-tap
  /// branch, extracted so the Start-plan auto switch rides the exact same
  /// chain (design 10-24 §4): thought-validity fallback, optimistic patch,
  /// lost-ack revert trace and the one-shot retry record.
  ///
  /// [closeSheet] is the sheet's own choreography (pop + pending toast). The
  /// auto switch runs on the page's context outside any sheet, so it keeps
  /// the sheet open and reports with its own toast; nothing else differs.
  /// Returns whether the command was accepted or optimistically applied
  /// (a transport failure on the lost-ack path counts as pending), false on
  /// an explicit rejection.
  Future<bool> switchModel(
    ConfigOptionValue option, {
    bool closeSheet = true,
  }) async {
    final sid = _sessionId;
    final state = _state;
    if (sid == null || sid.isEmpty || state == null) return false;
    final (provider, model) = _splitModelValue(option.value);
    // thought must be valid for the target model: keep current if
    // supported, else fall back to the thought option's currentValue.
    final currentThought = state.currentThought;
    final thoughtOption = _prep?.option('thought_level');
    final thought =
        currentThought.isNotEmpty &&
            (thoughtOption?.options.any((o) => o.value == currentThought) ??
                false)
        ? currentThought
        : '${thoughtOption?.currentValue ?? (currentThought.isNotEmpty ? currentThought : 'enabled')}';
    // Config exactly as the switch leaves it — the optimistic patch lands
    // it, the lost-ack path arms the revert trace with the same value.
    Map<String, dynamic> switchedConfig() => {
      ...?state.config,
      'provider': provider,
      'model': model,
      'thought': thought,
    };
    void patch() => state.optimisticPatch({'config': switchedConfig()});
    _lastSwitch = _LastSwitch(sid, provider, model, thought, patch);
    return _apply(
      context,
      () => widget.host.conversationCommands.switchModelConfig(
        sid,
        provider: provider,
        model: model,
        thought: thought,
      ),
      // Accepted (design 10-02 Step 3): clear any trace armed earlier —
      // old-config snapshots from here on are the desktop's pending
      // semantics, never a lost command.
      onAccepted: () {
        state.clearConfigRevertTrace();
        patch();
      },
      // PRD 09-19: a lost ack (bridge reconnect window) is not a rejection
      // — land the patch anyway and ARM the revert trace: an authoritative
      // snapshot still carrying the old config is now evidence of a
      // swallowed command (design 10-02 Step 3).
      onTimeoutOptimistic: () {
        patch();
        state.armConfigRevertTrace({'config': switchedConfig()});
      },
      closeSheet: closeSheet,
    );
  }

  Future<void> _run(String errorPrefix, Future<dynamic> Function() run) async {
    // Read the locale before the async gap: [businessErrorCopy] needs it, and
    // it must not receive a BuildContext.
    final locale = UiSettingsProvider.of(context)?.locale ?? 'zh-CN';
    try {
      final res = await run();
      // This verdict is mirrored verbatim (De Morgan) by [_ackOk] — the
      // delete flow's pop gate. Change one, change the other.
      if (res is Map &&
          res['status'] != null &&
          res['status'] != 'accepted' &&
          res['status'] != 'noop') {
        final reason = '${res['reasonCode'] ?? res['status']}';
        // Known reasonCodes get plain-language copy (the side-chat guard);
        // everything else keeps the raw code (unchanged).
        _toast('$errorPrefix: ${commandErrorCopy(reason, locale) ?? reason}');
      }
    } catch (e) {
      // Raw error to the log; the snack bar gets plain language for the
      // known transport shapes (commandErrorCopy, R3).
      debugPrint('[chat] $errorPrefix: $e');
      _toast(
        commandErrorCopy('$e', locale) ??
            businessErrorCopy('$e', locale) ??
            '$errorPrefix: $e',
      );
    }
  }

  // ------------------------------------------------------------ sending

  String _guessMime(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    return switch (ext) {
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'svg' => 'image/svg+xml',
      'pdf' => 'application/pdf',
      'txt' || 'md' || 'log' => 'text/plain',
      'json' => 'application/json',
      'zip' => 'application/zip',
      _ => 'application/octet-stream',
    };
  }

  /// Attachment size precheck cap (D6, F5): 30 MB — the desktop's own
  /// media budget constant (`31457280`, runtime @646551) and the value the
  /// official composer enforces client-side.
  static const _kMaxAttachmentBytes = 30 * 1024 * 1024;

  Future<void> _pickFiles() async {
    try {
      final result = await FilePicker.pickFiles(
        withData: true,
        allowMultiple: true,
      );
      if (result == null) return;
      var rejected = 0;
      final before = _pendingFiles.length;
      setState(() {
        for (final file in result.files) {
          final bytes = file.bytes;
          if (bytes == null) continue;
          // Oversize precheck: reject before the entry even lands in the
          // pending bar (official `chat.attachments.maxFileSize` behavior).
          if (bytes.lengthInBytes > _kMaxAttachmentBytes) {
            rejected++;
            continue;
          }
          _pendingFiles.add(
            _PendingFile(file.name, _guessMime(file.name), bytes),
          );
        }
      });
      // Persist the newly-landed attachments immediately (design 10-20):
      // byte writes are one-shot per pick, no debounce.
      final store = widget.host.chatDraftStore;
      for (var i = before; i < _pendingFiles.length; i++) {
        final f = _pendingFiles[i];
        unawaited(
          store.putAttachment(
            _draftKey,
            i,
            name: f.fileName,
            mime: f.mime,
            bytes: f.bytes,
          ),
        );
      }
      if (rejected > 0 && mounted) {
        _toast(trP(context, 'chat.attach.tooLarge', ['30']));
      }
    } catch (e) {
      if (mounted) _toast(trP(context, 'chat.attach.pickFailed', ['$e']));
    }
  }

  Future<List<Map<String, dynamic>>> _uploadPending(String sessionId) async {
    final uploaded = <Map<String, dynamic>>[];
    for (var i = 0; i < _pendingFiles.length; i++) {
      final file = _pendingFiles[i];
      final descriptor = await widget.host.conversationCommands.attachmentPut(
        sessionId,
        fileName: file.fileName,
        mime: file.mime,
        bytes: file.bytes,
        onProgress: (p) =>
            setState(() => _uploadProgress = (i + p) / _pendingFiles.length),
      );
      uploaded.add(descriptor);
    }
    return uploaded;
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    if ((text.isEmpty && _pendingFiles.isEmpty) || _sending) return;
    // Absence guards (10-06 tombstone + 10-11 sessionNotFound terminal):
    // a deleted-elsewhere or refused session accepts no sends — the
    // slash-bar shortcuts below route here directly, past the greyed
    // button.
    if (_tombstoned || _sessionMissing) return;
    HapticFeedback.lightImpact();

    // Slash commands (as in the web composer).
    if (text == '/compact' || text.startsWith('/compact ')) {
      _inputController.clear();
      setState(() => _showSlash = false);
      await _run(
        tr(context, 'chat.compact.failed'),
        () => widget.host.conversationCommands.compact(_requireSession()),
      );
      return;
    }
    if (text == '/goal pause') {
      _inputController.clear();
      setState(() => _showSlash = false);
      await _run(
        tr(context, 'chat.goal.pauseFailed'),
        () => widget.host.conversationCommands.pauseGoal(_requireSession()),
      );
      return;
    }
    if (text == '/goal resume') {
      _inputController.clear();
      setState(() => _showSlash = false);
      await _run(
        tr(context, 'chat.goal.resumeFailed'),
        () => widget.host.conversationCommands.resumeGoal(_requireSession()),
      );
      return;
    }

    // held-queue confirmation: when inputRouting is `choice` the user
    // picks whether to clear the held queue or keep it.
    String? heldDisposition;
    final state = _state;
    if (state != null &&
        state.inputRoutingMode == 'choice' &&
        state.queueItems.isNotEmpty) {
      heldDisposition = await _askHeldQueueDisposition();
      if (heldDisposition == null) return; // cancelled
      if (!mounted) return;
    }

    setState(() {
      _sending = true;
      _uploadProgress = null;
      _showSlash = false;
      // Draft first-send surfaces "creating" from the very start: the draft
      // guard, the v4 handshake and the health gate can each stall for tens
      // of seconds BEFORE the createSession rpc runs (2026-10-27 P1).
      _progress = _sessionId == null ? tr(context, 'chat.creating') : null;
    });
    try {
      var sessionId = _sessionId;
      if (sessionId == null) {
        // A connection rebuild auto-opens the preferred workspace under an
        // open draft page; creating here would land the task in that
        // workspace instead of the one the user is looking at. Re-point the
        // bridge first; a dead end blocks the send (draft text and pending
        // attachments stay) instead of producing a wrong-workspace task.
        final draftGuard = await widget.host.ensureDraftWorkspace(
          widget.draftWorkspacePath,
        );
        if (draftGuard is! WorkspaceOpenOpened) {
          if (!mounted) return;
          // Same failure split as the task list: a cold per-workspace
          // runtime needs the "open it on the desktop" instruction, not the
          // "workspace is not open" copy. An aborted guard is not a failure
          // (link/bridge replaced mid-open): block the send without a toast.
          final key = switch (draftGuard) {
            WorkspaceOpenRuntimeNotRunning() =>
              'tasks.agentRuntimeNotRunning',
            WorkspaceOpenUnreachable() ||
            WorkspaceOpenTransportFailure() =>
              'tasks.workspaceUnreachable',
            WorkspaceOpenOpened() || WorkspaceOpenAborted() => null,
          };
          if (key != null) _toast(tr(context, key));
          return;
        }
        if (!mounted) return;
        // 1) create the session (can take a while when the runtime warms;
        //    the "creating" progress has been up since _send began)
        // Plain text first message is sent WITH createSession (firstInput,
        // as the composer does). This avoids a send-before-subscribe
        // race where the first command can be dropped on a fresh session.
        final canUseFirstInput =
            text.isNotEmpty &&
            _pendingFiles.isEmpty &&
            !text.startsWith('/goal ') &&
            heldDisposition == null;
        final workspaceId = widget.host.chatWorkspaceId;
        if (workspaceId == null || workspaceId.isEmpty) {
          throw StateError(tr(context, 'tasks.noWorkspaces.title'));
        }
        sessionId = await widget.host.conversationCommands.createSession(
          workspaceId,
          firstText: canUseFirstInput ? text : null,
          config: _buildDraftConfig(),
        );
        if (!mounted) return;
        // Anchor write source ① (spec task-registry-semantics §3.8): the
        // phone created the session, so the App is the source of truth for
        // its home workspace. The ACTIVE workspace is the target — never
        // [ChatPage.draftWorkspacePath], which may name a path the bridge
        // did not actually land on (`_openWorkspaceNow` prefers the bridge's
        // own key). The state layer canonicalizes the key.
        widget.host.anchorCreatedTask(sessionId, widget.host.workspacePath);
        // Primary visibility trigger (design 11-01 §2): the new row is
        // listed by listTaskList ~230 ms after the ack (run8), so the 0 ms
        // pull already sees it. Fire-and-forget — sending must not wait.
        // A user action is not a storm source: bypass the cadence throttle
        // (the seam still waits out a stale in-flight round before dialing).
        unawaited(widget.host.refreshTaskOverview(bypassThrottle: true));
        // The draft placeholder entry dies the moment the session exists —
        // its content continues under the session key via the debounced
        // writes, and a stale placeholder must not resurface in the next
        // new-task page (design 10-20).
        unawaited(widget.host.chatDraftStore.remove('draft.$workspaceId'));
        _sessionId = sessionId;
        // 2) subscribe in the background — must NOT block sending
        setState(() => _progress = null);
        if (canUseFirstInput) {
          // Message already sent with the session; just display history.
          _inputController.clear();
          setState(() => _pendingFiles.clear());
          _subscribe();
          return;
        }
        // Attachments / goal commands: the follow-up command needs an active
        // subscription, so wait for it before proceeding.
        await _subscribe();
      }
      if (text.startsWith('/goal ')) {
        final res = await widget.host.conversationCommands.sendGoalCommand(
          sessionId,
          text.substring('/goal '.length).trim(),
          heldQueueDisposition: heldDisposition,
        );
        if (ackRejected(res)) {
          if (mounted) {
            _toast(trP(context, 'chat.send.failed', [ackReason(res)]));
          }
          return;
        }
        _inputController.clear();
        return;
      }
      List<Map<String, dynamic>>? attachments;
      if (_pendingFiles.isNotEmpty) {
        setState(() => _progress = tr(context, 'chat.attach.uploading'));
        attachments = await _uploadPending(sessionId);
        setState(() => _progress = null);
      }
      // Plain send: the transport classifies the outcome (queued on a
      // channel-level failure, ADR-0010) and this switch maps the four
      // variants 1:1 onto the former inline handling.
      final result = await widget.host.conversationCommands
          .sendTextOrQueue(
            sessionId,
            text,
            attachments: attachments,
            heldQueueDisposition: heldDisposition,
          );
      switch (result) {
        case SendTextSent():
          _inputController.clear();
          setState(() => _pendingFiles.clear());
        case SendTextQueued():
          // The transport already parked the message (the bar above shows
          // it); attachments cannot be present in this branch.
          _inputController.clear();
        case SendTextRejected(:final reason):
          if (mounted) {
            _toast(trP(context, 'chat.send.failed', [reason]));
          }
        case SendTextFailed(:final error):
          if (mounted) {
            _toast(trP(context, 'chat.send.failed', ['$error']));
          }
      }
    } catch (e) {
      // createSession / slash / goal / upload paths surface errors as
      // before — they do not go through sendTextOrQueue (design B).
      // Attachment uploads land here too: size-budget rejections map to the
      // oversize copy (D6), and with attachments still pending the bar gets
        // a one-tap retry (files stay in _pendingFiles by design).
        debugPrint('[chat] send failed: $e');
        if (mounted) {
          final locale = localeOf(context);
          final message =
              attachmentErrorCopy('$e', locale) ??
              commandErrorCopy('$e', locale) ??
              '$e';
          // No !_sending here: the catch runs BEFORE the finally resets the
          // flag, so it would read true forever. The :1139 guard already
          // blocks concurrent re-entry — the action only fires after this
          // _send() has fully unwound.
          final canRetry = _pendingFiles.isNotEmpty;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(trP(context, 'chat.send.failed', [message])),
            action: canRetry
                ? SnackBarAction(
                    label: tr(context, 'common.retry'),
                    onPressed: () => unawaited(_send()),
                  )
                : null,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _uploadProgress = null;
          _progress = null;
        });
      }
    }
  }

  String _requireSession() {
    final sessionId = _sessionId;
    if (sessionId == null) throw StateError(tr(context, 'chat.noSession'));
    return sessionId;
  }

  /// Builds the createSession `config` payload: the draft picks (seeded
  /// from the global new-task defaults in initState, overridden by sheet
  /// picks) validated against the live prepareWorkspace options, plus an
  /// always-legal thought. Shared with the scheduled-send fire path so
  /// both ship identical payloads.
  Map<String, dynamic> _buildDraftConfig() => sanitizeNewTaskConfig(
    _draftConfig,
    _prep,
    explicitKeys: _draftExplicit,
  );

  Future<String?> _askHeldQueueDisposition() {
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, 'chat.held.title')),
        content: Text(tr(context, 'chat.held.body')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'keepQueueAndSend'),
            child: Text(tr(context, 'chat.held.keep')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'clearQueueAndSend'),
            child: Text(tr(context, 'chat.held.clear')),
          ),
        ],
      ),
    );
  }

  /// The message list's viewport-sized render box (Listener/GestureDetector
  /// wrap the viewport exactly), or null when nothing is laid out.
  RenderBox? _listViewportBox() {
    final box = _listKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box;
  }

  /// Every currently-built turn group, in list order: (widget, box) — the
  /// turn navigator's directory/highlight pass (the history anchor chain
  /// measures through the viewport's own element port). Only BUILT children
  /// exist here — SliverList keeps just the viewport plus its cacheExtent
  /// alive.
  List<(ChatTurnGroup, RenderBox)> _builtGroups() {
    final groups = <(ChatTurnGroup, RenderBox)>[];
    final listContext = _listKey.currentContext;
    if (listContext == null) return groups;
    void visit(Element element) {
      final widget = element.widget;
      if (widget is ChatTurnGroup) {
        final box = element.findRenderObject();
        if (widget.key != null &&
            box is RenderBox &&
            box.attached &&
            box.hasSize) {
          groups.add((widget, box));
        }
        return;
      }
      element.visitChildElements(visit);
    }

    listContext.visitChildElements(visit);
    return groups;
  }

  // ------------------------------------------------------------ sheets

  /// Quota warning (R3): the fetched plan snapshot reports exhausted or
  /// limited. The fetch happens once per page open, so the banner persists
  /// for the page's lifetime and the next open re-evaluates it against the
  /// shared poller's freshest ok snapshot.
  ///
  /// 10-24 C: the expired Start-plan shape (provider present, quota/remaining
  /// empty, `startPlanExpired:true`) carries no percentage to read, so the
  /// explicit flag lights the same banner (PRD §5 — previously silent).
  bool get _showQuotaWarning {
    final view = _entitlement;
    return view != null &&
        view.phase == EntitlementPhase.ok &&
        (view.exhausted || view.data?['startPlanExpired'] == true);
  }

  /// Whether the visible warning is the expiry form — its copy differs from
  /// the exhausted form (「额度已用尽」 would be wrong for an expiry).
  bool get _quotaExpired {
    final view = _entitlement;
    return view != null &&
        view.phase == EntitlementPhase.ok &&
        view.data?['startPlanExpired'] == true;
  }

  Future<void> _loadEntitlement() async {
    try {
      final view = await widget.host.entitlementSnapshot();
      // The Start-plan auto switch needs the entitled provider set at the
      // same moment (design 10-24 §3). A failed read is null = entitlement
      // unknown, and the auto switch declines to judge.
      Set<String>? entitledIds;
      try {
        entitledIds = await widget.host.entitledProviderIds();
      } catch (_) {
        entitledIds = null;
      }
      if (!mounted) return;
      setState(() {
        _entitlement = view;
        _entitledProviderIds = entitledIds;
      });
      // The reset scope rides the snapshot (injected by the session's
      // entitlementSnapshot); this plain refresh picks the pools up — a
      // no-op without a provider id (the banner action never shows).
      unawaited(widget.host.quotaResetController.refresh());
      _maybeAutoSwitchStartPlan();
    } catch (_) {
      // Gateways may reject; the banner then stays hidden and the chat is
      // not disturbed.
    }
  }

  /// One-shot Start-plan auto switch (design 10-24 §4, PRD §1-6): judge the
  /// last entitlement snapshot against the live session's current model and
  /// switch to an entitled coding plan when the Start plan is spent,
  /// expired, or no longer entitled.
  ///
  /// Called from every readiness edge of the page-open path —
  /// [_loadEntitlement] (snapshot), [_loadPrep] (model options) and the
  /// live snapshot's config — because the three async loads land in no
  /// fixed order. The guard below keeps repeated calls free.
  void _maybeAutoSwitchStartPlan() {
    if (!mounted) return;
    final sessionId = _sessionId;
    if (sessionId == null || sessionId.isEmpty) return; // draft: never
    if (_autoSwitched.contains(sessionId)) return;
    final view = _entitlement;
    final state = _state;
    final prep = _prep;
    if (view == null || state == null || prep == null) return;
    final provider = state.config?['provider'];
    final plan = StartPlanAutoSwitch.evaluate(
      view: view,
      entitledIds: _entitledProviderIds,
      currentProviderId: provider is String ? provider : null,
      currentModelId: state.currentModel,
      modelOptions: prep.option('model')?.options ?? const [],
    );
    if (plan == null) return;
    if (!_autoSwitched.add(sessionId)) return;
    unawaited(_runStartPlanAutoSwitch(plan));
  }

  Future<void> _runStartPlanAutoSwitch(StartPlanSwitchPlan plan) async {
    final switched = await switchModel(plan.targetOption, closeSheet: false);
    if (!mounted || !switched) return;
    _toast(trP(context, 'chat.quota.autoSwitched', [
      plan.targetOption.modelProviderName ?? plan.targetOption.name,
    ]));
  }

  /// The live snapshot's config lands after [_subscribe] resolves, so a
  /// page-open hook can run before there is any current provider to judge.
  /// Re-run once on the first frame that carries one, then detach.
  void _autoSwitchWhenConfigReady() {
    final state = _handle?.state;
    if (state == null || state.config == null) return;
    state.removeListener(_autoSwitchWhenConfigReady);
    _maybeAutoSwitchStartPlan();
  }

  /// Banner「使用重置券」入口 removed (PRD: the sheet is the single
  /// reset entry) — the dialog + success chain live in [_showResetDialog].
  /// [resettable] comes from the EntitlementView projection
  /// (`resettablePools`, see the usage sheet), so the dialog lists exactly
  /// the pools the row credited.
  Future<void> _showResetDialog(Set<String> resettable) async {
    final type = await showQuotaResetDialog(
      context,
      controller: widget.host.quotaResetController,
      resettable: resettable,
    );
    if (!mounted || type == null) return;
    _toast(tr(context, 'usage.reset.success'));
    // The controller's success chain force-refreshed the poller; re-read
    // it so the exhausted banner flips immediately.
    await _loadEntitlement();
  }

  /// Provider id of the model the config sheet treats as currently selected
  /// (the entitlement filter's exemption, design 10-24 §3): the draft pick's
  /// provider segment, else the live session config's provider. Null when
  /// nothing is selected.
  String? get _sheetCurrentProviderId {
    if (_sessionId == null || _sessionId!.isEmpty) {
      final draftModel = _draftConfig['model'] ?? '';
      if (draftModel.isEmpty) return null;
      final (provider, _) = _splitModelValue(draftModel);
      return provider.isEmpty ? null : provider;
    }
    final provider = _state?.config?['provider'];
    return provider is String && provider.isNotEmpty ? provider : null;
  }

  Future<void> _showModelSheet() async {
    // PRD 09-19: sessions created with an empty default model config can
    // ship no usable model options from prepareWorkspace — fetch the
    // model-provider catalog as the sheet's fallback selector data. Normal
    // sessions (options present) never trigger the extra RPC.
    var catalog = const <Map<String, dynamic>>[];
    final modelOption = _prep?.option('model');
    if (modelOption == null || modelOption.options.isEmpty) {
      catalog = await widget.host.modelProviderCatalog();
    }
    // Design 10-24 §4: the sheet is stateless, so the page prefetches the
    // entitled provider ids it filters account groups by. A failed read is
    // null = entitlement unknown → no filtering (PRD §3) and it never
    // blocks the sheet from opening.
    Set<String>? entitledIds;
    try {
      entitledIds = await widget.host.entitledProviderIds();
    } catch (_) {
      entitledIds = null;
    }
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _ModelModeSheet(
        conversation: widget.host,
        state: _state,
        prep: _prep,
        sessionId: _sessionId,
        providerCatalog: catalog,
        draftConfig: _draftConfig,
        entitledIds: entitledIds,
        currentProviderId: _sheetCurrentProviderId,
        onDraftChange: (key, value) {
          setState(() {
            _draftConfig[key] = value;
            _draftExplicit.add(key);
          });
        },
        onSwitchIssued: (record) => _lastSwitch = record,
        onSwitchModel: switchModel,
      ),
    );
  }

  /// Slash entries = builtin/custom commands from prepareWorkspace plus the
  /// desktop's skills (`$name`) and subagents (`@name`). Official `/`
  /// capability panel merges [commands, skills, subagents], so subagents
  /// moved here out of the `@` mention panel. The synthesis lives in
  /// [buildSlashItems] — shared with the task-search page's actions tab.
  List<SlashItem> get _slashItems => buildSlashItems(
        commands: _prep?.slashCommands,
        skills: _skills,
        subagents: _subagents,
      );

  /// Dedicated skill picker so skills are one tap away (no `/` guessing).
  void _openSkillsPicker() {
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: false,
      showDragHandle: true,
      builder: (context) => _SkillsPickerSheet(
        skills: _skills,
        loading: _skillsLoading,
        onSelect: (skill) {
          _insertAtCursor('\$${skill.name}');
          Navigator.of(context).pop();
          setState(() => _showSlash = false);
        },
        onRefresh: _loadPrep,
      ),
    );
  }

  /// The workspace's `workflow` slash command name (official add-workflow
  /// visibility condition: a `/workflow` command exists in slashCommands) —
  /// null hides the add-context 工作流 item.
  String? _workflowCommandName() {
    for (final c in _prep?.slashCommands ?? const <SlashCommand>[]) {
      if (c.name == 'workflow') return c.name;
    }
    return null;
  }

  /// Writes [insert] at the composer cursor (or replaces the selection),
  /// adding a leading space when the preceding character is not whitespace
  /// (official Xet spacer rule) and one trailing space.
  void _insertAtCursor(String insert) {
    final value = _inputController.value;
    final sel = value.selection;
    final start = sel.isValid ? sel.start : value.text.length;
    final end = sel.isValid ? sel.end : value.text.length;
    final needsSpace =
        start > 0 && !RegExp(r'\s').hasMatch(value.text.substring(start - 1, start));
    final prefix = needsSpace ? ' ' : '';
    final next = value.text.replaceRange(start, end, '$prefix$insert ');
    _inputController.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(
        offset: start + prefix.length + insert.length + 1,
      ),
    );
  }

  /// Manual `@` mention panel (add-context footer shortcut / tool entry).
  Future<void> _openMentionPanel() async {
    final entry = await showMentionSheet(context, widget.host);
    if (!mounted || entry == null) return;
    _insertAtCursor(entry.insert);
  }

  /// Add-context panel (official ＋ / `chat.composer.actionMenu`, design D4):
  /// 附件/目标/工作流 + 文件/会话 pickers + the `@`/`$` footer shortcuts.
  Future<void> _openAddContextMenu() async {
    final result = await showAddContextSheet(
      context,
      workspaceContext: widget.host,
      isDraft: _sessionId == null,
      workflowCommand: _workflowCommandName(),
    );
    if (!mounted || result == null) return;
    switch (result.action) {
      case AddContextAction.attach:
        await _pickFiles();
      case AddContextAction.mention:
        await _openMentionPanel();
      case AddContextAction.skills:
        _openSkillsPicker();
      case null:
        final insert = result.insert;
        if (insert != null) _insertAtCursor(insert);
    }
  }

  /// Usage sheet (R7): one fresh entitlement fetch per open feeds the limit
  /// columns and the reset countdown; the sheet then renders that snapshot
  /// without polling.
  Future<void> _showUsageSheet() async {
    final state = _state;
    if (state == null) return;
    final controller = widget.host.quotaResetController;
    unawaited(controller.refresh());
    await _loadEntitlement();
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _UsageSheet(
        state: state,
        entitlement: _entitlement,
        controller: controller,
        onUseReset: _showResetDialog,
      ),
    );
  }

  /// Background-task management sheet (single entry, three partitions:
  /// 终端/工作流/子智能体). Anchored to the chat route's navigator
  /// (`useRootNavigator: false`) so it stays inside the dual-pane chat pane
  /// (chat-conventions §6).
  void _showBackgroundWorksSheet() {
    final state = _state;
    if (state == null || !mounted) return;
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: false,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => _BackgroundWorksSheet(
        state: state,
        conversation: widget.host,
        actions: _actions,
        feed: _feed,
        confirmWindow: widget.turnFooterConfirmWindow,
      ),
    );
  }

  Future<void> _showPlansSheet() async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    try {
      final plans = await widget.host.conversationCommands.plans(sessionId);
      if (!mounted) return;
      showModalBottomSheet(
        context: context,
        showDragHandle: true,
        builder: (context) =>
            JsonSheet(title: tr(context, 'chat.plans'), data: plans),
      );
    } catch (e) {
      _toast(trP(context, 'chat.plans.failed', ['$e']));
    }
  }

  /// "更多" menu actions for the session itself.
  Future<void> _renameSession() async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    final controller = TextEditingController(text: widget.title);
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, 'chat.more.rename')),
        content: TextField(
          controller: controller,
          maxLines: 1,
          decoration: InputDecoration(
            hintText: tr(context, 'chat.more.rename.hint'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr(context, 'devices.add.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(tr(context, 'chat.more.rename.save')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.isEmpty || !mounted) return;
    await _run(
      tr(context, 'chat.op.failed.generic'),
      () => widget.host.renameTask(sessionId, text),
    );
  }

  void _copySessionId() {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    Clipboard.setData(ClipboardData(text: sessionId));
    _toast(tr(context, 'chat.more.idCopied'));
  }

  void _copyWorkspacePath() {
    final path = widget.host.workspacePath;
    if (path == null || path.isEmpty) {
      _toast(tr(context, 'chat.more.noPath'));
      return;
    }
    Clipboard.setData(ClipboardData(text: path));
    _toast(tr(context, 'chat.more.pathCopied'));
  }

  /// 复制任务路径 (D2): the session file path, constructed exactly like the
  /// desktop's own `getTaskSessionFilePath` (F2: pure
  /// `` `${workspacePath}/${taskId}.zcode-session` `` — no RPC needed, both
  /// fields are already on the wire data ZGo holds).
  void _copyTaskPath() {
    final sessionId = _sessionId;
    final ws = widget.host.workspacePath;
    if (sessionId == null || ws == null || ws.isEmpty) {
      _toast(tr(context, 'chat.more.noPath'));
      return;
    }
    final sep = ws.endsWith('/') || ws.endsWith('\\') ? '' : '/';
    Clipboard.setData(ClipboardData(text: '$ws$sep$sessionId.zcode-session'));
    _toast(tr(context, 'chat.more.pathCopied'));
  }

  /// 复制日志路径 (D2): desktop-local path, only reachable via the
  /// zcode-task `getTaskNativeSessionLogFile` RPC (F2). Any failure (bridge
  /// down / older desktop without the method / null path) degrades to the
  /// no-path toast — never an error surface.
  Future<void> _copyLogPath() async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    try {
      final res = await widget.host.taskNativeSessionLogFile(sessionId);
      if (!mounted) return;
      final path = res is Map ? res['path'] as String? : null;
      if (path == null || path.isEmpty) {
        _toast(tr(context, 'chat.more.noLogPath'));
        return;
      }
      Clipboard.setData(ClipboardData(text: path));
      _toast(tr(context, 'chat.more.logCopied'));
    } catch (e) {
      debugPrint('[chat] copyLogPath: $e');
      if (mounted) _toast(tr(context, 'chat.more.noLogPath'));
    }
  }

  void _copyTaskLink() {
    final sessionId = _sessionId;
    final base = widget.host.remoteUrl;
    if (sessionId == null || base == null || base.isEmpty) {
      _toast(tr(context, 'chat.more.noLink'));
      return;
    }
    final uri = Uri.parse(base);
    final link = uri
        .replace(
          queryParameters: {...uri.queryParameters, 'session': sessionId},
        )
        .toString();
    Clipboard.setData(ClipboardData(text: link));
    _toast(tr(context, 'chat.more.linkCopied'));
  }

  /// The "更多" dropdown actions (second header row).
  void _onMoreMenu(String action) {
    final sessionId = _sessionId;
    switch (action) {
      case 'rename':
        _renameSession();
      case 'pin':
        if (sessionId != null) {
          final target = !_pinned;
          _run(
            tr(context, 'chat.op.failed.generic'),
            () => widget.host.setTaskPinned(sessionId, target),
          );
          setState(() => _pinned = target);
        }
      case 'archive':
        if (sessionId != null) {
          _run(
            tr(context, 'chat.op.failed.generic'),
            () => widget.host.setTaskArchived(sessionId, true),
          );
        }
      case 'unread':
        if (sessionId != null) {
          _run(
            tr(context, 'chat.op.failed.generic'),
            () => widget.host.setTaskUnread(sessionId, true),
          );
        }
      case 'copyPath':
        _copyWorkspacePath();
      case 'copyTaskPath':
        _copyTaskPath();
      case 'copyLogPath':
        _copyLogPath();
      case 'copyId':
        _copySessionId();
      case 'copyLink':
        _copyTaskLink();
      case 'compact':
        if (sessionId != null) {
          _run(
            tr(context, 'chat.compact.failed'),
            () => widget.host.conversationCommands.compact(sessionId),
          );
        }
      case 'usage':
        _showUsageSheet();
      case 'plans':
        _showPlansSheet();
      case 'deleteSession':
        if (sessionId != null) {
          _deleteSession(sessionId);
        }
    }
  }

  /// Delete confirmation (tasks.action.delete*): the task is removed
  /// from the workspace and records cannot be recovered. Routing mirrors the
  /// task list's C1/D4 delete (task_list_page `_deleteTaskDialog`): the
  /// registry write goes through [TaskMetaPort.deleteTask] — deleteSession
  /// never touches tasks-index, a "deleted" row would resurrect through the
  /// relay overview / bootstrap / reseed paths — and a registry-external
  /// draft row (resolve misses, isTaskResolveFailure) falls back ONCE to the
  /// V4 `deleteSession` command. The page pops only on a real delete
  /// ([_ackOk] mirrors `_run`'s failure verdict); the failure toast is
  /// already `_run`'s, so a failed RPC stays on the chat page.
  Future<void> _deleteSession(String sessionId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (dialogCtx) => AlertDialog(
        title: Text(tr(dialogCtx, 'tasks.action.deleteTitle')),
        content: Text(
          trP(dialogCtx, 'tasks.action.deleteDesc', [
            widget.title.isNotEmpty ? widget.title : sessionId,
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: Text(tr(dialogCtx, 'common.cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogCtx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: Text(tr(dialogCtx, 'tasks.action.delete')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    var deleted = false;
    await _run(
      tr(context, 'chat.op.failed.generic'),
      // Returns the winning ack so `_run`'s verdict branch sees it (a
      // failed ack must toast, not just refuse the pop): [_ackOk] gates
      // the pop on the same envelope.
      () async {
        try {
          final res = await widget.host.deleteTask(sessionId);
          deleted = _ackOk(res);
          return res;
        } catch (e) {
          if (!isTaskResolveFailure(e)) rethrow;
          final res =
              await widget.host.conversationCommands.deleteSession(sessionId);
          deleted = _ackOk(res);
          return res;
        }
      },
    );
    if (deleted && mounted) Navigator.of(context).maybePop();
  }

  /// Mirrors `_run`'s success verdict for one RPC answer: a Map ack whose
  /// `status` is neither `accepted` nor `noop` is a failure; anything else —
  /// including answers without an ack envelope (the zcode-task
  /// `deleteTask` result) — counts as done.
  static bool _ackOk(dynamic res) =>
      res is! Map ||
      res['status'] == null ||
      res['status'] == 'accepted' ||
      res['status'] == 'noop';

  /// Menu order: pin toggle / rename / archive / unread, then the
  /// copy actions (official 06 order: 复制路径 / 复制任务路径 / 复制日志
  /// 路径 / 复制会话 ID); client-only extras (link, compact, usage, plans)
  /// trail.
  List<PopupMenuEntry<String>> _moreMenuItems(BuildContext context) => [
    _menuItem(
      'pin',
      Icons.push_pin_outlined,
      _pinned ? 'chat.more.unpin' : 'chat.more.pin',
    ),
    _menuItem('rename', Icons.edit_outlined, 'chat.more.rename'),
    _menuItem('archive', Icons.archive_outlined, 'chat.more.archive'),
    _menuItem('unread', Icons.mark_email_unread_outlined, 'chat.more.unread'),
    const PopupMenuDivider(),
    _menuItem('copyPath', Icons.folder_copy_outlined, 'chat.more.copyPath'),
    _menuItem('copyTaskPath', Icons.description_outlined, 'chat.more.copyTaskPath'),
    _menuItem('copyLogPath', Icons.article_outlined, 'chat.more.copyLogPath'),
    _menuItem('copyId', Icons.tag, 'chat.more.copyId'),
    const PopupMenuDivider(),
    _menuItem('copyLink', Icons.link, 'chat.more.copyLink'),
    _menuItem('compact', Icons.compress, 'chat.more.compact'),
    _menuItem('usage', Icons.query_stats_outlined, 'chat.more.usage'),
    _menuItem('plans', Icons.checklist_outlined, 'chat.more.plans'),
    const PopupMenuDivider(),
    _menuItem('deleteSession', Icons.delete_outline, 'tasks.action.delete'),
  ];

  /// Message list gutter; [_compensateAnchor] lands the pinned state on the
  /// true content end, which sits this far above the viewport bottom.
  static const EdgeInsets _listPadding = EdgeInsets.fromLTRB(16, 8, 16, 8);

  /// Content column: messages cap at 848px, the composer at 864px,
  /// centered inside the pane. On narrow screens they simply fill.
  static const double _kMessageColumnWidth = 848;
  static const double _kComposerColumnWidth = 864;

  /// Keyboard-occupied viewport (R2 10-16): ceiling for the pre-list banner
  /// run. The IME shrinks the body by its full inset; with the header row
  /// already folded, an unbounded run here is what could still push the
  /// fixed stack (banners + composer) past the body height — a RenderFlex
  /// overflow the shrunken viewport must scroll instead. Sized so the run
  /// still shows whole single banners (error bar ~64, quota warning ~110,
  /// off-peak card ~72) while two-plus stacked ones start scrolling.
  static const double _kBannerRunMaxHeight = 200;

  Widget _contentCol(Widget child, {double maxWidth = _kMessageColumnWidth}) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: SizedBox(width: double.infinity, child: child),
      ),
    );
  }

  /// The message stream itself — the layer the jump-to-bottom control floats
  /// over (see [build]).
  Widget _messageList(BuildContext context, ConversationState? state) {
    if (state == null) {
      if (_sessionId == null) {
        return Center(
          child: Text(
            tr(context, 'chat.draftHint'),
            style: TextStyle(color: ZInk.faint(context)),
          ),
        );
      }
      // Subscribe still pending (no ack → no state): keep the spinner, but
      // surface bridge degradation and — after a few seconds — admit the
      // wait: the ack latency is unbounded (desktop hydration), and a bare
      // spinner reads as frozen (internal-task).
      return Center(child: _LoadingPlaceholder(degraded: _bridgeDegraded()));
    }
    if (!state.ready) return const Center(child: CircularProgressIndicator());
    // The shrink-follow listener rides the list subtree only (see
    // [_onListMetrics]) — the floating status strip's scrollable lives in a
    // sibling Stack branch whose notifications can't bubble into it.
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: _onListMetrics,
      child: AnimatedBuilder(
        animation: state,
        builder: (context, _) {
          final groups = groupChatRows(state.rows);
          // D9 anchor plan: interactions anchored into the held window
          // render after their turn group (below); the bottom strip's
          // _PendingInteractions excludes the same ids.
          final anchorPlan = anchoredInteractionPlan(
            groups,
            state.pendingInteractions,
          );
          final itemCount = groups.length + (state.canLoadOlder ? 1 : 0);
          if (groups.isEmpty && !state.canLoadOlder) {
            // Empty conversation — or the shell-session start-failure card
            // (design 09-25 D1/D2). The gate reads the task displayStatus
            // view, which refreshes on the gateway's notifier, not on
            // [state] — hence the double-listen (Listenable.merge).
            return AnimatedBuilder(
              animation: Listenable.merge([state, widget.host]),
              builder: (context, _) => _emptyOrStartFailed(context, state),
            );
          }
          return _contentCol(
            NotificationListener<ScrollNotification>(
              onNotification: _onListScroll,
              // ListenableBuilder: the viewport's gate and anchor-cache
              // flips rebuild the ListView shell (spinner + scrollCacheExtent)
              // without touching the rows.
              child: ListenableBuilder(
                listenable: _viewport,
                builder: (context, _) {
                  final cacheExtent =
                      _viewport.anchorCacheExtent ?? _jumpCacheExtent;
                  // Prepend veil (round 21) + frozen frame (round 24): the
                  // veil hides only the PAINT — layout and the anchor
                  // measurement run normally underneath, so the measured
                  // landing happens off-screen. The frozen capture of the
                  // last pre-prepend frame is drawn OVER the veil: the same
                  // pixels stand still until the landing lifts it — no blank
                  // flash, no wrong-guess frame.
                  return TranscriptVeil(
                    viewport: _viewport,
                    child: ListView.builder(
                      key: _listKey,
                      controller: _scrollController,
                      scrollCacheExtent: cacheExtent == null
                          ? null
                          : ScrollCacheExtent.pixels(cacheExtent),
                      // Top rubber-band only while older history exists;
                      // flipping to null restores the platform clamp (no
                      // pull, no trigger).
                      physics: state.canLoadOlder
                          ? const TopRubberBandPhysics()
                          : null,
                      padding: _listPadding,
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
                                  : const Icon(Icons.history, size: 14),
                              label: Text(
                                tr(context, 'chat.loadOlder'),
                                style: ZType.sub,
                              ),
                            ),
                          );
                        }
                        final groupIndex =
                            index - (state.canLoadOlder ? 1 : 0);
                        final group = groups[groupIndex];
                        final previous =
                            groupIndex > 0 ? groups[groupIndex - 1] : null;
                        final divider = _timeDividerLabel(previous, group);
                        final anchored =
                            anchorPlan.byGroup[groupIndex] ??
                            const <Map<String, dynamic>>[];
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (divider != null) _TimeDivider(label: divider),
                            // Stable identity for the history anchor
                            // compensation: keyed by the turn's first row so
                            // the viewport can re-find the same group after a
                            // prepend remounts the window (the `turn-…` key
                            // prefix is a contract — see transcript_viewport).
                            // The load-older button row stays unkeyed.
                            ChatTurnGroup(
                              key: ValueKey('turn-${group.first['rowId']}'),
                              rows: group,
                              conversation: widget.host,
                              sessionId: _sessionId ?? '',
                              onAction: _run,
                              state: state,
                              feed: _feed,
                              preview: _preview,
                              confirmWindow: widget.turnFooterConfirmWindow,
                              actions: _actions,
                              editingRowId: _editingRowId,
                              onEditSend: _sendUserEdit,
                              gitController: _git,
                            ),
                            // D9: interactions anchored to a row of this
                            // group render directly after it (in-stream),
                            // same card component as the bottom strip.
                            for (final interaction in anchored)
                              _interactionCardFor(
                                state: state,
                                conversation: widget.host,
                                interaction: interaction,
                              ),
                          ],
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }

  /// The zero-rows view: the plain empty hint, or — when the task view
  /// says the session's turn died server-side (displayStatus "error";
  /// design 09-25 D1/D2) — a start-failed card in the established
  /// phase-pill error vocabulary instead of a misleading "empty" chat.
  /// Gate = error + zero rows + a real (non-draft) session; this branch
  /// only runs after `state.ready`, i.e. an established subscription. A
  /// view miss (null) renders nothing — prefer no card over a wrong
  /// card. A session that gains rows mid-error drops back to the normal
  /// list (the existing task-failure presentation's domain).
  Widget _emptyOrStartFailed(BuildContext context, ConversationState state) {
    final sessionId = _sessionId;
    final startFailed = sessionId != null &&
        state.rows.isEmpty &&
        widget.host.taskDisplayStatus(sessionId) == 'error';
    if (!startFailed) {
      return Center(
        child: Text(
          tr(context, 'chat.empty'),
          style: TextStyle(color: ZInk.faint(context)),
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(ZSpacing.card),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 320),
          padding: const EdgeInsets.all(ZSpacing.card),
          decoration: BoxDecoration(
            color: ZColors.danger.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(ZRadius.tile),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 20, color: ZInk.dangerTone(context)),
              const SizedBox(height: 8),
              Text(
                tr(context, 'chat.session.startFailedTitle'),
                textAlign: TextAlign.center,
                style: ZType.heading.copyWith(color: ZInk.dangerTone(context)),
              ),
              const SizedBox(height: 4),
              Text(
                tr(context, 'chat.session.startFailedBody'),
                textAlign: TextAlign.center,
                style: ZType.sub.copyWith(color: ZInk.muted(context)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Status strip (goal/works/queue/interactions). Keyboard-open callers
  /// wrap it in a bottom-aligned positioned slot inside the message Stack,
  /// where the scroll view shrink-wraps to min(intrinsic, stack height) and
  /// scrolls when the banners overflow; no-keyboard callers place it as a
  /// plain Column child.
  Widget _statusStrip(BuildContext context, ConversationState state) {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Git group first (official mwt partition order: environment →
          // goal → todo → agents). Self-hides on a non-repository workspace.
          // The page's shared preview rides along (S7/R8b): review-panel
          // file rows dispatch through the same vector as the chat rows.
          GitStatusGroup(controller: _git, preview: _preview),
          _GoalBanner(state: state),
          _GoalProcessPanel(
            state: state,
            conversation: widget.host,
            actions: _actions,
            feed: _feed,
          ),
          _QueueBar(state: state, conversation: widget.host),
          _PendingInteractions(state: state, conversation: widget.host),
        ],
      ),
    );
  }

  /// Bridge degradation flag of the live transport (`session.degraded`,
  /// non-null while the native bridge is down/rebuilding). Null when no
  /// transport is open (`conversationCommands` throws before the first
  /// workspace) — the placeholder then just tracks the slow hint.
  ValueListenable<String?>? _bridgeDegraded() {
    try {
      return widget.host.conversationCommands.degraded;
    } catch (_) {
      return null;
    }
  }

  /// Workspace chip (folder icon + label) shared by the two header forms —
  /// portrait renders it in the second header row, landscape in the compact
  /// app bar (mock 方案 B keeps it visible on both).
  Widget _workspaceChip(BuildContext context) {
    final label = widget.workspaceLabel!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: ZInk.tile(context),
        borderRadius: BorderRadius.circular(ZRadius.field),
        border: Border.all(color: ZInk.hairline(context)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.folder_outlined,
            size: 13,
            color: ZInk.muted(context),
          ),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 96),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ZType.sub.copyWith(color: ZInk.muted(context)),
            ),
          ),
        ],
      ),
    );
  }

  /// Portrait second header row: task title + workspace chip + text 更多
  /// (the landscape compact app bar carries the equivalents instead).
  Widget _secondHeaderRow(BuildContext context, String? wsLabel) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 4, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ZType.heading.copyWith(color: ZInk.solid(context)),
            ),
          ),
          if (wsLabel != null) ...[
            const SizedBox(width: 6),
            _workspaceChip(context),
          ],
          PopupMenuButton<String>(
            tooltip: tr(context, 'chat.more'),
            onSelected: _onMoreMenu,
            itemBuilder: _moreMenuItems,
            position: PopupMenuPosition.under,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tr(context, 'chat.more'),
                    style: ZType.body.copyWith(color: ZColors.sky500),
                  ),
                  const Icon(
                    Icons.keyboard_arrow_down,
                    size: 16,
                    color: ZColors.sky500,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Pre-list banner run: subscribe failure / absence tombstone (missing or
  /// deleted session) / off-peak queue card / quota warning — ONE constant
  /// type at ONE constant Column position (spec §8.1; previously these
  /// children were added and removed inline, shifting every later child's
  /// Element pairing on each flip).
  ///
  /// While the keyboard occupies the viewport (R2 10-16) the run is capped
  /// at [_kBannerRunMaxHeight] and scrolls: the IME shrinks the body by its
  /// full inset, and an unbounded run is what could still push the fixed
  /// stack (banners + composer) past the body height — scroll instead of a
  /// RenderFlex overflow. Keyboard down returns the run verbatim, so the
  /// resting layout is unchanged.
  ///
  /// (The GatewayBanner above the status-strip slot is NOT part of this run:
  /// it renders after the message list, and moving it here would reorder the
  /// visual stack.)
  Widget _preListBanners(BuildContext context) {
    final run = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_error != null && !_sessionMissing)
          Material(
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
          ),
        // Absence banners: the authoritative subscribe refusal (10-11
        // sessionNotFound terminal) and the cross-terminal deletion
        // tombstone (10-06) — the tombstone's own gateway-animating
        // builder (`chat` in build is captured once per State.build, so
        // only AnimatedBuilders re-run on the session's tombstone
        // notify). Authority precedence: when both hold, the
        //「会话不存在」refusal wins the banner. The always-present slot
        // keeps the Column child list structurally constant (spec
        // §8.1 discipline); the message list above stays read-only
        // either way.
        AnimatedBuilder(
          animation: widget.host,
          builder: (context, _) {
            final missing = _sessionMissing;
            if (!missing && !_tombstoned) return const SizedBox.shrink();
            return Material(
              color: ZColors.danger.withValues(alpha: 0.15),
              child: ListTile(
                dense: true,
                leading: Icon(
                  Icons.delete_outline,
                  color: ZInk.dangerTone(context),
                ),
                title: Text(
                  tr(
                    context,
                    missing
                        ? 'chat.banner.sessionMissing'
                        : 'chat.banner.sessionDeleted',
                  ),
                  style: ZType.sub,
                ),
              ),
            );
          },
        ),
        // D2 off-peak queue card: its own state-driven slot (empty
        // unless the session is bound to an off-peak run with a live
        // queue position).
        _offPeakQueueCard(context),
        if (_showQuotaWarning)
          // Warning-only banner (PRD: the「使用重置券」action moved to
          // the usage sheet; switch model / view usage remain).
          Material(
            color: ZColors.danger.withValues(alpha: 0.15),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr(
                      context,
                      _quotaExpired
                          ? 'chat.quota.expiredTitle'
                          : 'chat.quota.exhaustedTitle',
                    ),
                    style: ZType.sub.copyWith(
                      fontWeight: FontWeight.w600,
                      color: ZInk.dangerTone(context),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    tr(
                      context,
                      _quotaExpired
                          ? 'chat.quota.expiredBody'
                          : 'chat.quota.exhaustedBody',
                    ),
                    style: ZType.caption.copyWith(color: ZInk.muted(context)),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        onPressed: _showModelSheet,
                        child: Text(
                          tr(context, 'chat.quota.switchModel'),
                          style: ZType.sub,
                        ),
                      ),
                      if (widget.onOpenUsage != null)
                        TextButton(
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                          onPressed: widget.onOpenUsage,
                          child: Text(
                            tr(context, 'chat.quota.viewUsage'),
                            style: ZType.sub,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
    return ValueListenableBuilder<bool>(
      valueListenable: _imeOccupied,
      builder: (context, imeOccupied, _) => imeOccupied
          ? ConstrainedBox(
              constraints: const BoxConstraints(
                maxHeight: _kBannerRunMaxHeight,
              ),
              child: SingleChildScrollView(child: run),
            )
          : run,
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    // Short viewport (landscape phones, folding half-open; portrait phones
    // are ~844 tall and never trigger): the header collapses to ONE 48px
    // row — back + task title + workspace chip + ⋮ menu — and the second
    // header row (caption + title + text 更多) is dropped entirely, so the
    // message area clears the 40%-of-screen-height density line (mock
    // 方案 B; probe-measured baseline was 37.4%).
    final short = MediaQuery.heightOf(context) < 480;
    final wsLabel = (widget.workspaceLabel ?? '').isEmpty
        ? null
        : widget.workspaceLabel;
    // This build deliberately does NOT read the IME inset: the keyboard
    // animation delivers a fresh inset every frame (~300ms), and a dependency
    // here rebuilt the whole page per frame — app bar, row regrouping,
    // markdown relayout (2026-09-20 真机掉帧). The dependency lives in
    // _KeyboardProbe instead (placed ABOVE the Scaffold: the body's
    // MediaQuery strips the bottom inset, so nothing inside the body could
    // read it anyway) and only the strip slots consume it. The Scaffold
    // itself still depends on the inset and re-lays-out every frame — that
    // part is unavoidable — but as long as this build stays idle the body
    // widget instance it receives is identical, Element updates short-circuit
    // on widget identity and the entire chat content subtree skips rebuild;
    // only the cheap layout shrink remains (an order of magnitude cheaper).
    final chat = Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        toolbarHeight: short ? 48 : null,
        title: short
            ? Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ZType.heading.copyWith(
                        color: ZInk.solid(context),
                      ),
                    ),
                  ),
                  if (wsLabel != null) ...[
                    const SizedBox(width: 6),
                    _workspaceChip(context),
                  ],
                ],
              )
            : Text(tr(context, 'chat.appBar')),
        actions: [
          if (widget.theme != null)
            IconButton(
              icon: Icon(switch (widget.theme!.mode) {
                ThemeMode.dark => Icons.dark_mode_outlined,
                ThemeMode.light => Icons.light_mode_outlined,
                _ => Icons.brightness_6_outlined,
              }, size: 20),
              tooltip: tr(context, 'settings.theme'),
              onPressed: widget.theme!.cycle,
            ),
          // Landscape compact: the second row's text 更多 becomes the ⋮
          // icon here (same menu).
          if (short)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, size: 22),
              tooltip: tr(context, 'chat.more'),
              onSelected: _onMoreMenu,
              itemBuilder: _moreMenuItems,
              position: PopupMenuPosition.under,
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: Column(
          children: [
            // Second header row: task title + workspace chip + 更多
            // (portrait content; landscape carries all of it in the app
            // bar). The slot itself stays occupied — constant type, constant
            // Column position (spec §8.1: a toggling child here shifts every
            // later child's pairing). Two folds render the same placeholder
            // inside it: `short` (landscape) and the IME-occupied viewport
            // (R2 10-16 — the keyboard shrinks the body to short-viewport
            // territory while heightOf stays at the full screen, so plain
            // `short` never fires). The inset is not read here; the probe
            // owns the hysteresis flip (§8.2).
            ValueListenableBuilder<bool>(
              valueListenable: _imeOccupied,
              builder: (context, imeOccupied, _) => _contentCol(
                short || imeOccupied
                    ? const SizedBox.shrink()
                    : _secondHeaderRow(context, wsLabel),
              ),
            ),
            _preListBanners(context),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(child: _messageList(context, state)),
                  // Jump-to-newest control: floating in the message area it
                  // covers the list only — the takeover cover, sheets and menus
                  // are page-level layers painted above it.
                  Positioned.fill(
                    bottom: 8,
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: JumpToBottomButton(
                        visible: !_stickToBottom,
                        onPressed: _animateToBottom,
                      ),
                    ),
                  ),
                  // Turn navigator (task 10-14): right-edge query strip,
                  // vertically centered, the visual bars falling entirely
                  // inside the list's existing 16dp right padding — content
                  // never yields, zero overlap by construction. The 44dp
                  // hit band's inner 28dp lies over content by design
                  // (taps jump; drags pass through to the list). The mount
                  // is a full fill so the long-press overlay (R2, design
                  // §3.1) can span its 68dp float panel plus the
                  // outside-tap barrier; every inactive pixel inside the
                  // component stays transparent to hit tests.
                  Positioned.fill(
                    child: state == null || _queryRowIds.length < 2
                        ? const SizedBox.shrink()
                        : AnimatedBuilder(
                            animation: state,
                            builder: (context, _) =>
                                ValueListenableBuilder<int?>(
                                  valueListenable: _activeQueryIndex,
                                  builder: (context, active, _) =>
                                      TurnNavigator(
                                        key: _turnNavigatorKey,
                                        rowIds: _queryRowIds,
                                        activeIndex: active,
                                        canLoadOlder: state.canLoadOlder,
                                        onJump: _jumpToQuery,
                                      ),
                                ),
                          ),
                  ),
                  // Status strip while the IME is up: floats over the list
                  // bottom instead of being a Column flex child. The loose
                  // Flexible it used before (09-18 R2) split the remaining
                  // height with the Expanded list 1:1 and RenderFlex never
                  // redistributes what a loose child leaves unused — the free
                  // space pooled at the Column tail, leaving a blank band the
                  // height of the strip's unused share between the composer
                  // and the keyboard (2026-09-20 真机报告). Anchored to the
                  // bottom it shrink-wraps to min(intrinsic, stack height),
                  // so the strip still scrolls when the banners overflow and
                  // the composer stays pinned above the IME.
                  // The Positioned.fill is unconditional — the slot inside
                  // consults _KeyboardScope; a conditional here would flip the
                  // Stack's child count on every keyboard toggle.
                  Positioned.fill(
                    child: _StatusStripSlot(
                      floating: true,
                      state: state,
                      buildStrip: _statusStrip,
                    ),
                  ),
                ],
              ),
            ),
            AnimatedBuilder(
              animation: widget.host,
              builder: (context, _) =>
                  _GatewayBanner(sessionLink: widget.host),
            ),
            // Status strip (goal/works/queue/interactions), no-keyboard
            // variant: a plain intrinsic-height child so it never splits
            // leftover space with the message list's Expanded (a permanent
            // Flexible would shrink the strip below its intrinsic height on
            // short viewports — visual change; see internal-task
            // R2). While the IME is up the strip renders inside the Stack
            // above; this slot must stay occupied (constant type, constant
            // Column position) — letting the child disappear would shift every
            // later Column child, force the composer's Element to remount on
            // the first IME inset frame, drop the TextField focus and cancel
            // the keyboard right after it started showing (2026-09-20 真机
            // IME_ANIMATION_CANCEL 回归).
            _StatusStripSlot(
              floating: false,
              state: state,
              buildStrip: _statusStrip,
            ),
            if (_showSlash)
              _SlashCommandBar(
                query: _inputController.text,
                items: _slashItems,
                onSelect: (item) {
                  if (item.name == 'compact') {
                    _inputController.text = '/compact';
                    _send();
                  } else {
                    _inputController.text = item.insert;
                    _inputController.selection = TextSelection.collapsed(
                      offset: _inputController.text.length,
                    );
                    setState(() => _showSlash = false);
                  }
                },
              ),
            if (_progress != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _progress!,
                      style: ZType.caption.copyWith(color: ZInk.muted(context)),
                    ),
                  ],
                ),
              ),
            if (_pendingFiles.isNotEmpty)
              _PendingFilesBar(
                files: _pendingFiles,
                uploadProgress: _uploadProgress,
                onRemove: (i) {
                  setState(() => _pendingFiles.removeAt(i));
                  unawaited(
                    widget.host.chatDraftStore.removeAttachmentAt(
                      _draftKey,
                      i,
                    ),
                  );
                },
              ),
            // Locally-queued replayable messages (3.12.3): sits directly
            // above the composer like the pendingCommands cards.
            // Null queue (pre-3.12.3 desktop / not connected) renders nothing.
            AnimatedBuilder(
              animation: widget.host,
              builder: (context, _) {
                final replayable = widget.host.replayableQueue;
                if (replayable == null) return const SizedBox.shrink();
                return AnimatedBuilder(
                  animation: replayable,
                  builder: (context, _) => _ReplayableQueueBar(queue: replayable),
                );
              },
            ),
            AnimatedBuilder(
              animation: (state == null)
                ? widget.host
                : Listenable.merge([state, widget.host]),
              builder: (context, _) {
                return _contentCol(
                  _InputBar(
                    controller: _inputController,
                    sending: _sending,
                    hasAttachments: _pendingFiles.isNotEmpty,
                    isDraft: _sessionId == null,
                    state: state,
                    prep: _prep,
                    draftConfig: _draftConfig,
                    conversation: widget.host,
                    sessionTruth: widget.host,
                    sessionId: _sessionId,
                    feed: state == null ? null : _feed,
                    subagentConfirmWindow: widget.turnFooterConfirmWindow,
                    onSend: _send,
                    onAddMenu: _openAddContextMenu,
                    onModelSheet: _showModelSheet,
                    onUsage: _showUsageSheet,
                    onBackgroundWorks: _showBackgroundWorksSheet,
                  ),
                  maxWidth: _kComposerColumnWidth,
                );
              },
            ),
          ],
        ),
      ),
    );
    return _KeyboardProbe(
      imeOccupied: _imeOccupied,
      child: AnimatedBuilder(
        animation: widget.host,
        builder: (context, _) => widget.host.kicked
            ? Stack(children: [chat, _kickedOverlay(context)])
            : chat,
      ),
    );
  }

  Widget _kickedOverlay(BuildContext context) {
    return Positioned.fill(
      child: Material(
        color: (ZInk.isDark(context)
                ? ZColors.darkBackground
                : ZColors.lightBackground)
            .withValues(alpha: 0.92),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(ZSpacing.emptyState),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.phonelink_erase_outlined,
                  size: 44,
                  color: ZInk.dangerTone(context),
                ),
                const SizedBox(height: 16),
                Text(
                  tr(context, 'chat.kicked.title'),
                  style: ZType.heading,
                ),
                const SizedBox(height: 8),
                Text(
                  tr(context, 'chat.kicked.body'),
                  textAlign: TextAlign.center,
                  style: ZType.body.copyWith(color: ZInk.faint(context)),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: () => _run(
                    tr(context, 'chat.op.failed.generic'),
                    widget.host.reconnect,
                  ),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: Text(tr(context, 'chat.kicked.reconnect')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  PopupMenuItem<String> _menuItem(String value, IconData icon, String key) {
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Text(tr(context, key)),
        ],
      ),
    );
  }

  /// Centered HH:mm divider between two groups whose timestamps are more
  /// than 10 minutes apart (timeline separators). Rows without a
  /// recognizable timestamp field produce no divider.
  String? _timeDividerLabel(
    List<Map<String, dynamic>>? previous,
    List<Map<String, dynamic>> group,
  ) {
    final prevAt = rowTimestamp(previous?.first);
    final at = rowTimestamp(group.first);
    if (at == null) return null;
    if (prevAt != null && at - prevAt < 10 * 60 * 1000) return null;
    final time = DateTime.fromMillisecondsSinceEpoch(at).toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}';
  }

  /// Fork flow shared by the message-action sheet and the feedback row
  /// (task C1, official parity): send `forkAssistant`, then — like the web's
  /// onFork — push the ack's new sessionId as a fresh ChatPage (the landing
  /// IS the feedback; no extra toast), or snack the fallback copy when the
  /// server acked created without a usable id (the row surfaces via
  /// sessions-index). Failures keep [_run]'s snack shapes: a non-pass status
  /// reads 「分叉失败: `reasonCode|status`」, a thrown error goes through
  /// commandErrorCopy/businessErrorCopy (busy and resolve-failure map to
  /// plain-language copy).
  ///
  /// Lives on the page since ADR-0008 rule ii: the pushed page reuses this
  /// page's host, workspace chip and theme; the timeline holds only the
  /// [ChatPageActions] callback.
  Future<void> _forkToNewSession(
    BuildContext context,
    String sessionId,
    Map<String, dynamic> target,
  ) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final locale = localeOf(context);
    final errorPrefix = tr(context, 'chat.action.fork.failed');
    final createdCopy = tr(context, 'chat.fork.created');
    final draftTitle = tr(context, 'tasks.new');
    dynamic ack;
    try {
      ack = await widget.host.conversationCommands
          .forkAssistant(sessionId, target);
    } catch (e) {
      debugPrint('[chat] $errorPrefix: $e');
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            commandErrorCopy('$e', locale) ??
                businessErrorCopy('$e', locale) ??
                '$errorPrefix: $e',
          ),
        ),
      );
      return;
    }
    final newId = forkSessionIdOf(ack);
    if (newId != null) {
      navigator.push(
        zRoute(
          (_) => ChatPage(
            host: widget.host,
            sessionId: newId,
            title: draftTitle,
            workspaceLabel: widget.workspaceLabel,
            theme: widget.theme,
          ),
        ),
      );
      return;
    }
    // Same pass-set as the wire (accepted | duplicate carry the result) —
    // unlike _run's generic check, `duplicate` here means "created" (the
    // commandId dedupe replaying the original ack).
    final status = ack is Map ? ack['status'] : null;
    if (status == 'accepted' || status == 'duplicate') {
      messenger.showSnackBar(SnackBar(content: Text(createdCopy)));
    } else if (status != null) {
      messenger.showSnackBar(
        SnackBar(content: Text('$errorPrefix: ${ack['reasonCode'] ?? status}')),
      );
    }
  }

  /// Side-chat flow behind the message-action sheet's 「在辅助对话中提问」
  /// entry (task parity-reference D2, official ask-in-side-chat parity): ask
  /// the user what to send, then `createSelectionSideSession(firstInput:
  /// {text})` and push the new sessionId as a fresh ChatPage (the fork-jump
  /// precedent — the landing is the feedback, no extra toast). Cancelled or
  /// blank input creates NOTHING: ZGo never sends a first message the user
  /// did not type.
  ///
  /// Lives on the page since ADR-0008 rule ii (same host reuse rule as
  /// [_forkToNewSession]).
  Future<void> _startSelectionSideChat(
    BuildContext context,
    String sessionId,
  ) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final locale = localeOf(context);
    final dialogTitle = tr(context, 'chat.selections.askInSideChat');
    final hint = tr(context, 'chat.selections.askHint');
    final cancelCopy = tr(context, 'devices.add.cancel');
    final confirmCopy = tr(context, 'chat.selections.askConfirm');
    final errorPrefix = tr(context, 'chat.selections.askFailed');
    final pageTitle = tr(context, 'sidePane.selectionChat');
    final asked = await showDialog<String>(
      context: context,
      useRootNavigator: false,
      builder: (_) => _AskSideChatDialog(
        title: dialogTitle,
        hint: hint,
        cancelCopy: cancelCopy,
        confirmCopy: confirmCopy,
      ),
    );
    final text = asked?.trim() ?? '';
    // Empty/cancel: create nothing, send no first message.
    if (text.isEmpty) return;
    String newId;
    try {
      newId = await widget.host.conversationCommands
          .createSelectionSideSession(
        sessionId,
        firstText: text,
      );
    } catch (e) {
      debugPrint('[chat] $errorPrefix: $e');
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            commandErrorCopy('$e', locale) ??
                businessErrorCopy('$e', locale) ??
                '$errorPrefix: $e',
          ),
        ),
      );
      return;
    }
    navigator.push(
      zRoute(
        (_) => ChatPage(
          host: widget.host,
          sessionId: newId,
          title: pageTitle,
          workspaceLabel: widget.workspaceLabel,
          theme: widget.theme,
        ),
      ),
    );
  }
}

/// ------------------------------------------------------- keyboard scope

/// IME "occupies the viewport" hysteresis band (dp, R2 10-16): the fold
/// engages once the bottom inset is past [_kImeOccupiedEnter] and releases
/// only below [_kImeOccupiedExit]. The band in between keeps the fold stable
/// while the ~300ms IME animation runs and while OEM candidate strips make
/// the inset jitter.
const double _kImeOccupiedEnter = 100;
const double _kImeOccupiedExit = 80;

/// Publishes the keyboard-open state to the strip slots via [_KeyboardScope]
/// and the keyboard-occupied-viewport boolean to the fold slots via
/// [imeOccupied]. Deliberately the only widget in the page that depends on
/// the IME inset (besides the Scaffold's own layout): the animation delivers
/// a fresh inset every frame for ~300ms, and a dependency in ChatPage.build
/// would rebuild the whole page per frame (2026-09-20 真机掉帧). This probe
/// rebuilds instead and returns the identical child widget, so Element
/// updates short-circuit below it; the scope notifies its dependents only
/// when the boolean flips, and [imeOccupied] only at the hysteresis band
/// edges — its listeners rebuild their own small slot, never the page.
class _KeyboardProbe extends StatefulWidget {
  const _KeyboardProbe({required this.imeOccupied, required this.child});

  /// Owned by [_ChatPageState]; flipped in place (see [imeOccupied]).
  final ValueNotifier<bool> imeOccupied;

  final Widget child;

  @override
  State<_KeyboardProbe> createState() => _KeyboardProbeState();
}

class _KeyboardProbeState extends State<_KeyboardProbe> {
  bool _open = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Read here, above the Scaffold: the Scaffold strips the bottom view
    // inset from the body's MediaQuery (removeViewInsets), so widgets inside
    // the body can never see the real value (that is why the old read lived
    // in ChatPage.build).
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    _open = bottom > 0;
    // Hysteresis flip (R2 10-16): a ValueNotifier setter no-ops on an equal
    // value, so only the two band edges ever notify — the fold slots
    // rebuild on the enter/exit frame, not on every animated inset frame.
    widget.imeOccupied.value = widget.imeOccupied.value
        ? bottom > _kImeOccupiedExit
        : bottom > _kImeOccupiedEnter;
  }

  @override
  Widget build(BuildContext context) {
    return _KeyboardScope(open: _open, child: widget.child);
  }
}

class _KeyboardScope extends InheritedWidget {
  const _KeyboardScope({required this.open, required super.child});

  final bool open;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_KeyboardScope>()?.open ??
      false;

  @override
  bool updateShouldNotify(_KeyboardScope oldWidget) => oldWidget.open != open;
}

/// Status-strip slot — the keyboard-aware leaf of the chat page. One class
/// for both call sites in [ChatPage.build]: the floating variant anchors the
/// open-keyboard strip to the message Stack's bottom, the Column variant
/// renders it as a plain child while the keyboard is closed and shrinks
/// otherwise (the placeholder discipline that keeps the composer mounted is
/// documented at the call site).
class _StatusStripSlot extends StatelessWidget {
  const _StatusStripSlot({
    required this.floating,
    required this.state,
    required this.buildStrip,
  });

  final bool floating;
  final ConversationState? state;
  final Widget Function(BuildContext context, ConversationState state)
      buildStrip;

  @override
  Widget build(BuildContext context) {
    final keyboardOpen = _KeyboardScope.of(context);
    final state = this.state;
    if (state == null) return const SizedBox.shrink();
    // The state dependency is kept inside the leaf, separate from the inset
    // one: an inset frame rebuilds only this slot, a state change only
    // refreshes the strip content.
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        final visible = floating ? keyboardOpen : !keyboardOpen;
        if (!visible) return const SizedBox.shrink();
        final strip = buildStrip(context, state);
        return floating
            ? Align(alignment: Alignment.bottomCenter, child: strip)
            : strip;
      },
    );
  }
}

/// ---------------------------------------------------------------- rows

/// Central placeholder while the Conversation V4 state has not arrived
/// (subscribe ack pending). Spinner plus two optional status lines: the
/// bridge-degraded copy while [degraded] is non-null, and — after a few
/// seconds — the slow-connection copy. Both describe state only; the ack
/// latency is unbounded so no countdown is promised.
class _LoadingPlaceholder extends StatefulWidget {
  final ValueListenable<String?>? degraded;

  const _LoadingPlaceholder({this.degraded});

  @override
  State<_LoadingPlaceholder> createState() => _LoadingPlaceholderState();
}

class _LoadingPlaceholderState extends State<_LoadingPlaceholder> {
  static const _slowHintAfter = Duration(seconds: 5);
  Timer? _slowTimer;
  bool _slow = false;
  bool _degraded = false;

  @override
  void initState() {
    super.initState();
    _slowTimer = Timer(_slowHintAfter, () {
      if (mounted) setState(() => _slow = true);
    });
    widget.degraded?.addListener(_onDegraded);
    _degraded = widget.degraded?.value != null;
  }

  void _onDegraded() {
    if (!mounted) return;
    setState(() => _degraded = widget.degraded?.value != null);
  }

  @override
  void didUpdateWidget(_LoadingPlaceholder old) {
    super.didUpdateWidget(old);
    if (old.degraded != widget.degraded) {
      old.degraded?.removeListener(_onDegraded);
      widget.degraded?.addListener(_onDegraded);
      _degraded = widget.degraded?.value != null;
    }
  }

  @override
  void dispose() {
    _slowTimer?.cancel();
    widget.degraded?.removeListener(_onDegraded);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        if (_degraded) ...[
          const SizedBox(height: 12),
          Text(
            tr(context, 'chat.load.bridgeRecovering'),
            style: TextStyle(color: ZInk.muted(context)),
          ),
        ],
        if (_slow) ...[
          const SizedBox(height: 4),
          Text(
            tr(context, 'chat.load.slowHint'),
            style: TextStyle(color: ZInk.faint(context)),
          ),
        ],
      ],
    );
  }
}

/// Banner driven by gateway link status: quiet when healthy, "reconnecting"
/// while the relay link is down mid-chat (a send may pause until recovery).
/// The kicked state has its own full-screen overlay further up the tree
/// (see _kickedOverlay) — this banner stays hidden there.
class _GatewayBanner extends StatelessWidget {
  final SessionLinkPort sessionLink;

  const _GatewayBanner({required this.sessionLink});

  @override
  Widget build(BuildContext context) {
    if (sessionLink.kicked || sessionLink.status != DeviceStatus.connecting) {
      return const SizedBox.shrink();
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      color: ZColors.warning.withValues(alpha: 0.15),
      child: Row(
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.5),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              tr(context, 'chat.reconnecting'),
              style: ZType.sub.copyWith(color: ZInk.soft(context)),
            ),
          ),
        ],
      ),
    );
  }
}

/// anchorRowId anchor plan (D9): which pending interactions anchor to a row
/// inside the HELD window, mapped to the turn-group index each anchor row
/// lives in (the ListView item layer — the cards render AFTER that group;
/// `assistantTurnParts` grouping stays untouched). Interactions with no
/// anchor or an anchor outside the window (history not loaded) are absent
/// from the plan and stay in the bottom [_PendingInteractions] list —
/// anchored ids and the bottom list are mutually exclusive. Same-anchor
/// interactions order by interactionId.
({Map<int, List<Map<String, dynamic>>> byGroup, Set<String> anchoredIds})
    anchoredInteractionPlan(
      List<List<Map<String, dynamic>>> groups,
      List<Map<String, dynamic>> interactions,
    ) {
  final groupOfRow = <int, int>{};
  for (var g = 0; g < groups.length; g++) {
    for (final row in groups[g]) {
      final id = row['rowId'];
      if (id is num) groupOfRow[id.toInt()] = g;
    }
  }
  final byGroup = <int, List<Map<String, dynamic>>>{};
  final anchoredIds = <String>{};
  final ordered = [...interactions]
    ..sort((a, b) => '${a['interactionId'] ?? ''}'.compareTo(
      '${b['interactionId'] ?? ''}',
    ));
  for (final interaction in ordered) {
    final id = interaction['interactionId'];
    if (id is! String || id.isEmpty) continue;
    final anchor = (interaction['anchorRowId'] as num?)?.toInt();
    final group = anchor == null ? null : groupOfRow[anchor];
    if (group == null) continue;
    (byGroup[group] ??= []).add(interaction);
    anchoredIds.add(id);
  }
  return (byGroup: byGroup, anchoredIds: anchoredIds);
}

/// Centered HH:mm separator between turns.
class _TimeDivider extends StatelessWidget {
  final String label;

  const _TimeDivider({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Text(
          label,
          style: ZType.caption.copyWith(color: ZInk.ghost(context)),
        ),
      ),
    );
  }
}

/// ---------------------------------------------------------------- bars

class _GoalBanner extends StatelessWidget {
  final ConversationState state;

  const _GoalBanner({required this.state});

  @override
  Widget build(BuildContext context) {
    final goal = state.goal;
    if (goal == null) return const SizedBox.shrink();
    final objective = '${goal['objective'] ?? ''}';
    if (objective.isEmpty) return const SizedBox.shrink();
    final status = '${goal['status'] ?? ''}';
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: ZColors.success.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(ZRadius.tile),
        border: Border.all(color: ZColors.success.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(Icons.flag_outlined,
              size: 14, color: ZInk.successTone(context)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              objective,
              style: ZType.sub.copyWith(color: ZInk.soft(context)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (status.isNotEmpty)
            Text(
              status,
              style:
                  ZType.caption.copyWith(color: ZInk.successTone(context)),
            ),
        ],
      ),
    );
  }
}

/// Bridges the conversation snapshot's goal/subagent data to the
/// web 目标面板 widget (hidden when no goal is set — the plain
/// _GoalBanner covers that case).
class _GoalProcessPanel extends StatelessWidget {
  final ConversationState state;
  final ConversationPort conversation;
  final SubagentFeed? feed;

  /// Page-level navigation (ADR-0008 rule ii) — the agent drill-in.
  final ChatPageActions? actions;

  const _GoalProcessPanel({
    required this.state,
    required this.conversation,
    this.feed,
    this.actions,
  });

  @override
  Widget build(BuildContext context) {
    if (state.snapshot?['goal'] is! Map) return const SizedBox.shrink();
    final pooledFeed = feed;
    return GoalPanel(
      state: state,
      feed: feed,
      onPauseGoal: (sid) => conversation.conversationCommands.pauseGoal(sid),
      onResumeGoal: (sid) => conversation.conversationCommands.resumeGoal(sid),
      onOpenAgent: pooledFeed == null || actions?.openSubagent == null
          ? null
          : (agent) => actions!.openSubagent!(
                context,
                pooledFeed,
                childSessionId: agent['childSessionId'] as String?,
                title: agent['title'] as String?,
                subagentType: agent['subagentType'] as String?,
                workId: agent['agentId'] as String?,
                parentSessionId: state.snapshot?['sessionId'] as String?,
                running: true,
              ),
    );
  }
}

/// Running background-work counts by kind. bash/workflow come from the
/// snapshot `backgroundWorks` (the official composer grouping @314278500);
/// subagents come from the pooled running view. Used by the composer pill,
/// the management sheet and its auto-close gate — one source of truth.
({int bash, int workflow, int subagent}) _runningWorkCounts(
  ConversationState state,
  List<Map<String, dynamic>> runningSubagents,
) {
  var bash = 0;
  var workflow = 0;
  for (final w in state.backgroundWorks) {
    if (w['status'] != 'running' || w['endedAt'] != null) continue;
    if (w['kind'] == 'bash') {
      bash++;
    } else if (w['kind'] == 'workflow') {
      workflow++;
    }
  }
  return (bash: bash, workflow: workflow, subagent: runningSubagents.length);
}

int _runningWorkTotal(({int bash, int workflow, int subagent}) counts) =>
    counts.bash + counts.workflow + counts.subagent;

/// Background-task management sheet (single entry, three partitions):
/// 终端 (bash) · 工作流 (workflow) · 子智能体 (subagents) — the front door
/// reversed from the 09-17 split (bash used to live on the works bar). The
/// subagent partition keeps every existing capability: live action tail,
/// 详情/停止 actions, ended rows from the parent window and 「加载更早」
/// paging back through rowsRange.
///
/// Subscription lifecycle: the sheet holds pooled child subscriptions for
/// its own lifetime (acquire on rebuild sync, release ALL on dispose) —
/// closing the sheet must never leak a feed reference (chat-conventions §7
/// Common Mistake).
class _BackgroundWorksSheet extends StatefulWidget {
  final ConversationState state;
  final ConversationPort conversation;

  /// Page-level navigation (ADR-0008 rule ii) — the agent drill-in.
  final ChatPageActions? actions;
  final SubagentFeed feed;

  /// Auto-close confirm window: once the whole running count stayed 0 this
  /// long (every background work terminal), the sheet closes itself.
  final Duration confirmWindow;

  const _BackgroundWorksSheet({
    required this.state,
    required this.conversation,
    this.actions,
    required this.feed,
    required this.confirmWindow,
  });

  @override
  State<_BackgroundWorksSheet> createState() => _BackgroundWorksSheetState();
}

class _BackgroundWorksSheetState extends State<_BackgroundWorksSheet> {
  /// childSessionIds this sheet currently holds in the pooled subscription.
  final Set<String> _held = {};

  /// Older `kind=='subagent'` rows collected through rowsRange paging
  /// (kept locally — paging from the sheet must not reshape the chat list).
  final List<Map<String, dynamic>> _older = [];

  bool _paging = false;
  bool _noMore = false;
  bool _seenRunning = false;

  /// Auto-close window — armed by [_reconcileAutoClose] once every
  /// background work went terminal; the still-empty re-check lives in the
  /// callback (the gate only decides the window elapsed).
  late final ConfirmGate _closeGate = ConfirmGate(
    window: widget.confirmWindow,
    onConfirmed: () {
      if (!mounted) return;
      if (_currentRunningTotal != 0) return;
      // A drill-in page (workflow detail) can sit above the sheet: pop()
      // would close that page instead. Remove the sheet's own route.
      final route = ModalRoute.of(context);
      if (route == null) return;
      final navigator = Navigator.of(context);
      if (route.isCurrent) {
        navigator.pop();
      } else {
        navigator.removeRoute(route);
      }
    },
  );

  /// Bash/workflow works with a live status (the snapshot `backgroundWorks`).
  List<Map<String, dynamic>> _runningWorks(String kind) => [
    for (final w in widget.state.backgroundWorks)
      if (w['kind'] == kind && w['status'] == 'running' && w['endedAt'] == null)
        w,
  ];

  /// Terminal workflow runs for the sheet's ended sub-section (design 11-03
  /// §5). A run already mirrored by a running work is excluded — the live
  /// row owns it (joined by `workId → runId`, else `toolCallId`). Wire order
  /// is preserved: a run snapshot carries no createdAt, so there is nothing
  /// to sort by and its arrival order is the only honest ordering.
  List<WorkflowRun> _endedWorkflowRuns(List<Map<String, dynamic>> running) {
    final runs = widget.state.workflowRuns;
    final liveRunIds = <String>{};
    for (final w in running) {
      final workId = '${w['workId'] ?? w['id'] ?? ''}';
      if (workId.isEmpty) continue;
      final run = runs.byRunId(workId) ?? runs.byToolCallId(workId);
      if (run != null) liveRunIds.add(run.runId);
    }
    return [
      for (final run in runs.views)
        if (const {'completed', 'errored', 'stopped'}.contains(run.status) &&
            !liveRunIds.contains(run.runId))
          run,
    ];
  }

  int get _currentRunningTotal => _runningWorkTotal(
    _runningWorkCounts(
      widget.state,
      subagentsRunningView(widget.state, widget.feed),
    ),
  );

  String get _sessionId =>
      widget.state.snapshot?['sessionId'] as String? ?? '';

  /// N in「已全部加载 · 共 N 个」— the cross-window total.
  int get _totalCount {
    final ids = widget.state.subagentsInfo?['childSessionIds'];
    return ids is List ? ids.length : 0;
  }

  /// Reconciles pooled child subscriptions with the running rows on screen.
  void _syncSubscriptions(List<Map<String, dynamic>> running) {
    final wanted = {
      for (final a in running)
        if ((a['childSessionId'] as String? ?? '').isNotEmpty)
          a['childSessionId'] as String,
    };
    for (final id in wanted.difference(_held)) {
      widget.feed.acquire(id);
      _held.add(id);
    }
    for (final id in _held.difference(wanted)) {
      widget.feed.release(id);
      _held.remove(id);
    }
  }

  @override
  void dispose() {
    _closeGate.dispose();
    // Symmetric release: every acquire made while the sheet lived is undone
    // here, early-exit or not.
    for (final id in _held) {
      widget.feed.release(id);
    }
    _held.clear();
    super.dispose();
  }

  /// All-terminal auto close (PRD: same 3s confirm semantics as the pill).
  /// The "must have seen running first" rule stays here — the gate owns
  /// only the hold window. The verdict is the aggregate running count, not
  /// the subagent view alone: a live bash/workflow work keeps the sheet up.
  void _reconcileAutoClose(({int bash, int workflow, int subagent}) counts) {
    if (_runningWorkTotal(counts) > 0) {
      _seenRunning = true;
      _closeGate.observe(false);
      return;
    }
    if (_seenRunning) _closeGate.observe(true);
  }

  // ------------------------------------------------------------ paging

  /// Pages older parent-session rows and collects their subagent rows.
  /// Cursor = the smallest collected rowId (window rows included) — never
  /// the snapshot's placeholder `firstRowId` (see [ConversationState.oldestRowId]).
  Future<void> _loadEarlier() async {
    if (_paging || _noMore || _sessionId.isEmpty) return;
    setState(() => _paging = true);
    final state = widget.state;
    try {
      int? cursor = state.oldestRowId;
      for (final r in _older) {
        final id = (r['rowId'] as num?)?.toInt();
        if (id != null && (cursor == null || id < cursor)) cursor = id;
      }
      final res = await widget.conversation.conversationCommands.rowsRange(
        _sessionId,
        beforeRowId: cursor,
        limit: 60,
      );
      // Subscription identity guard (same rule as the viewport's settle): a
      // resubscribe swapped the state out from under this fetch — its page
      // belongs to a state nobody shows; drop it silently.
      if (res is Map && state != widget.state) {
        debugPrint('[sheet] drop page: state replaced (resubscribe)');
        return;
      }
      if (res is! Map) {
        _noMore = true;
        return;
      }
      // Response order is preserved (sortOldestFirst: false): the sheet
      // filters kind=='subagent' rows in arrival order and tracks its own
      // min-rowId cursor below — no state writeback, results stay sheet-
      // local (chat-conventions §7.3).
      final page = parseRowsRangeResponse(
        res,
        state: state,
        sortOldestFirst: false,
      );
      // The rows are immutable log entries — an epoch drift does not
      // invalidate them (round 23; same rule as the viewport's settle):
      // toast as a trace, then apply the page anyway.
      if (!page.epochMatches) {
        if (mounted) _toast(tr(context, 'chat.loadOlder.stale'));
      }
      final hasMore = page.hasMore;
      final rows = page.rows;
      if (rows == null || rows.isEmpty) {
        _noMore = hasMore != true;
        return;
      }
      final existing = _older
          .map((r) => (r['rowId'] as num?)?.toInt())
          .toSet();
      for (final row in rows) {
        if (row['kind'] != 'subagent') continue;
        if (existing.add((row['rowId'] as num?)?.toInt())) {
          _older.add(row);
        }
      }
      if (hasMore != true) _noMore = true;
    } catch (e) {
      if (mounted) _toast(trP(context, 'chat.loadOlder.failed', ['$e']));
    } finally {
      if (mounted) setState(() => _paging = false);
    }
  }

  // ------------------------------------------------------------ stop

  /// Stop confirm aligned with the detail page's dialog (chat.agents.stop*).
  Future<void> _confirmStop(Map<String, dynamic> agent) async {
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
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
    if (confirmed != true || !mounted) return;
    // `agentId` is the running entry's work id (live-probed 2026-09-13);
    // some builds surface it as workId.
    final workId = '${agent['agentId'] ?? agent['workId'] ?? ''}';
    if (workId.isEmpty || _sessionId.isEmpty) return;
    try {
      await widget.conversation.conversationCommands.cancelBackgroundWork(_sessionId, workId);
    } catch (e) {
      _toast('$e');
    }
  }

  void _toast(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  // ------------------------------------------------------------ data

  /// Ended subagent rows: parent-window rows plus older collected ones,
  /// deduped by childSessionId, running entries excluded, terminal view
  /// applied, newest first.
  List<Map<String, dynamic>> _endedRows() {
    final liveIds = {
      for (final a in subagentsRunningView(widget.state, widget.feed))
        '${a['childSessionId'] ?? ''}',
    };
    final seen = <String>{};
    final out = <Map<String, dynamic>>[];
    final candidates = [
      ...widget.state.rows,
      ..._older,
    ];
    for (final row in candidates) {
      if (row['kind'] != 'subagent') continue;
      final sid = '${row['childSessionId'] ?? ''}';
      if (liveIds.contains(sid) || sid.isEmpty || !seen.add(sid)) continue;
      final status = widget.feed.effectiveStatus(sid, '${row['status'] ?? ''}');
      if (!subagentTerminalStatuses.contains(status)) continue;
      out.add(row);
    }
    out.sort(
      (a, b) => ((b['rowId'] as num?) ?? 0).compareTo((a['rowId'] as num?) ?? 0),
    );
    return out;
  }

  // ------------------------------------------------------------ ui

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([widget.state, widget.feed]),
      builder: (context, _) {
        final running = subagentsRunningView(widget.state, widget.feed);
        _syncSubscriptions(running);
        final counts = _runningWorkCounts(widget.state, running);
        _reconcileAutoClose(counts);
        final ended = _endedRows();
        final bash = _runningWorks('bash');
        final workflow = _runningWorks('workflow');
        final endedWorkflow = _endedWorkflowRuns(workflow);
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.78,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildHeader(context),
                  if (bash.isNotEmpty) ...[
                    _buildSectionLabel(
                      context,
                      'chat.bgSheet.sectionTerminal',
                      bash.length,
                    ),
                    for (final w in bash) _buildWorkItem(context, w),
                  ],
                  if (workflow.isNotEmpty || endedWorkflow.isNotEmpty) ...[
                    _buildSectionLabel(
                      context,
                      'chat.bgSheet.sectionWorkflow',
                      workflow.length + endedWorkflow.length,
                    ),
                    for (final w in workflow) _buildWorkflowItem(context, w),
                    if (endedWorkflow.isNotEmpty) ...[
                      _buildSectionLabel(
                        context,
                        'chat.subagentSheet.sectionEnded',
                      ),
                      for (final run in endedWorkflow)
                        _buildEndedWorkflowItem(context, run),
                    ],
                  ],
                  if (running.isNotEmpty || ended.isNotEmpty) ...[
                    _buildSectionLabel(
                      context,
                      'chat.subagentSheet.title',
                      running.length + ended.length,
                    ),
                    if (running.isNotEmpty) ...[
                      _buildSectionLabel(
                        context,
                        'chat.subagentSheet.sectionRunning',
                      ),
                      for (final a in running) _buildRunItem(context, a),
                    ],
                    if (ended.isNotEmpty) ...[
                      _buildSectionLabel(
                        context,
                        'chat.subagentSheet.sectionEnded',
                      ),
                      for (final row in ended) _buildEndedItem(context, row),
                    ],
                  ],
                  const SizedBox(height: 8),
                  _buildLoadMore(context),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 6),
      child: Row(
        children: [
          Text(
            tr(context, 'chat.bgSheet.title'),
            style: ZType.heading.copyWith(color: ZInk.solid(context)),
          ),
          const Spacer(),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: tr(context, 'common.close'),
            icon: Icon(Icons.close, size: 18, color: ZInk.muted(context)),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionLabel(BuildContext context, String key, [int? count]) {
    final label = tr(context, key);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 2),
      child: Row(
        children: [
          Text(
            count == null ? label : '$label · $count',
            style: ZType.caption.copyWith(color: ZInk.muted(context)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Container(height: 1, color: ZInk.hairline(context)),
          ),
        ],
      ),
    );
  }

  /// Cancels one bash/workflow work record (`cancelBackgroundWork`); a
  /// cancelled work is only removed from the management surface, the
  /// underlying process keeps running (chat-conventions §7.2).
  void _cancelWork(Map<String, dynamic> work) {
    final workId = '${work['workId'] ?? work['id'] ?? ''}';
    if (workId.isEmpty || _sessionId.isEmpty) return;
    try {
      widget.conversation.conversationCommands.cancelBackgroundWork(
        _sessionId,
        workId,
      );
    } catch (e) {
      _toast('$e');
    }
  }

  /// One running bash work row: spinner + title + elapsed + ✕ (direct
  /// cancel — the retired works bar's behavior, no confirm).
  Widget _buildWorkItem(BuildContext context, Map<String, dynamic> work) {
    final title = '${work['title'] ?? work['kind'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.5),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ZType.body.copyWith(color: ZInk.solid(context)),
            ),
          ),
          _SheetElapsed(startedAt: work['startedAt'] as num?),
          IconButton(
            icon: Icon(Icons.close, size: 14, color: ZInk.muted(context)),
            tooltip: tr(context, 'chat.bgSheet.cancelWork'),
            visualDensity: VisualDensity.compact,
            onPressed: () => _cancelWork(work),
          ),
        ],
      ),
    );
  }

  /// One running workflow row: the snapshot `backgroundWorks` entry is the
  /// row authority; the session's `workflowRuns` mirror supplies progress
  /// when a run joins by workId/runId (best-effort — the wire carries no
  /// explicit backgroundWorks↔run link; real-device shape check pending).
  /// The whole row opens the read-only detail page when a mirror run exists;
  /// the ✕ keeps owning the right column (gesture-arena inner win).
  Widget _buildWorkflowItem(BuildContext context, Map<String, dynamic> work) {
    final title = '${work['title'] ?? ''}';
    final workId = '${work['workId'] ?? work['id'] ?? ''}';
    final runs = widget.state.workflowRuns;
    final run = runs.byRunId(workId) ?? runs.byToolCallId(workId);
    final open = widget.actions?.openWorkflowRun;
    return InkWell(
      onTap: run == null || open == null
          ? null
          : () => open(
                context,
                runId: run.runId,
                title: title.isEmpty ? null : title,
                workStartedAt: (work['startedAt'] as num?)?.toInt(),
                workEndedAt: (work['endedAt'] as num?)?.toInt(),
              ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ZType.body.copyWith(color: ZInk.solid(context)),
                  ),
                ),
                _SheetElapsed(startedAt: work['startedAt'] as num?),
                IconButton(
                  icon: Icon(Icons.close, size: 14, color: ZInk.muted(context)),
                  tooltip: tr(context, 'chat.bgSheet.cancelWork'),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _cancelWork(work),
                ),
              ],
            ),
            if (run != null)
              Padding(
                padding: const EdgeInsets.only(left: 20, top: 2),
                child: Text(
                  trP(context, 'chat.bgSheet.workflowProgress', [
                    '${run.nodesSettled}',
                    '${run.nodesTotal}',
                    '${run.actorsCount}',
                  ]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ZType.caption.copyWith(color: ZInk.soft(context)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// One ended workflow row (design 11-03 §5): status glyph + resolved name
  /// + a `settled/total nodes · N agents` caption (zero parts omitted).
  /// The whole row opens the read-only detail page; the mirror carries no
  /// work timestamps, so the page gets null bounds (no fabricated elapsed).
  Widget _buildEndedWorkflowItem(BuildContext context, WorkflowRun run) {
    final (icon, color) = switch (run.status) {
      'completed' => (Icons.check, ZInk.successTone(context)),
      'errored' => (Icons.close, ZInk.dangerTone(context)),
      _ => (Icons.stop, ZInk.warningTone(context)),
    };
    final name = workflowRunName(
          rows: widget.state.rows,
          runId: run.runId,
          toolCallId: run.toolCallId,
        ) ??
        tr(context, 'chat.workflowDetail.titleFallback');
    final parts = <String>[
      if (run.nodesTotal > 0)
        trP(context, 'chat.workflowCard.steps', [
          '${run.nodesSettled}',
          '${run.nodesTotal}',
        ]),
      if (run.actorsCount > 0)
        trP(context, 'chat.workflowCard.agents', ['${run.actorsCount}']),
    ];
    final open = widget.actions?.openWorkflowRun;
    return InkWell(
      onTap: open == null
          ? null
          : () => open(context, runId: run.runId, title: name),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ZType.body.copyWith(color: ZInk.solid(context)),
                  ),
                  if (parts.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        parts.join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ZType.caption.copyWith(
                          color: ZInk.soft(context),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, size: 14, color: ZInk.ghost(context)),
          ],
        ),
      ),
    );
  }

  /// One running row (mock .run-item, official-aligned + user revisions):
  /// static agent glyph + 2-line title + live action tail + elapsed, the
  /// WHOLE row opens the detail page; a red icon-only stop button owns the
  /// right-most column (gesture-arena inner win = the official overlay's
  /// stopPropagation), still behind the confirm dialog.
  Widget _buildRunItem(BuildContext context, Map<String, dynamic> agent) {
    final title = '${agent['title'] ?? agent['subagentType'] ?? ''}';
    final sid = '${agent['childSessionId'] ?? ''}';
    final tail = subagentActionText(context, widget.feed.childState(sid));
    return InkWell(
      onTap: sid.isEmpty || widget.actions?.openSubagent == null
          ? null
          : () => widget.actions!.openSubagent!(
                context,
                widget.feed,
                childSessionId: sid,
                title: '${agent['title'] ?? ''}',
                subagentType: agent['subagentType'] as String?,
                workId: '${agent['agentId'] ?? agent['workId'] ?? ''}',
                parentSessionId: _sessionId,
                running: true,
                confirmWindow: widget.confirmWindow,
              ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                Icons.smart_toy_outlined,
                size: 17,
                color: ZInk.muted(context),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: ZType.body.copyWith(color: ZInk.solid(context)),
                  ),
                  if (tail != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        tail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ZType.caption.copyWith(
                          color: ZInk.soft(context),
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: _SheetElapsed(startedAt: agent['startedAt'] as num?),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: tr(context, 'chat.agents.stop'),
              icon: Icon(
                Icons.stop_circle_outlined,
                color: ZInk.dangerTone(context),
              ),
              onPressed: () => _confirmStop(agent),
            ),
          ],
        ),
      ),
    );
  }

  /// One ended row: status glyph + title, whole row opens the detail page
  /// (mock .end-item).
  Widget _buildEndedItem(BuildContext context, Map<String, dynamic> row) {
    final sid = '${row['childSessionId'] ?? ''}';
    final status = widget.feed.effectiveStatus(sid, '${row['status'] ?? ''}');
    final (icon, color, wordKey) = switch (status) {
      'success' => (
          Icons.check,
          ZInk.successTone(context),
          'chat.subagent.status.success',
        ),
      'error' || 'failed' || 'denied' => (
          Icons.close,
          ZInk.dangerTone(context),
          'chat.subagent.status.failed',
        ),
      _ => (
          Icons.block,
          ZInk.warningTone(context),
          'chat.subagentSheet.status.stopped',
        ),
    };
    final title = '${row['summaryText'] ?? row['subagentType'] ?? ''}';
    return InkWell(
      onTap: sid.isEmpty || widget.actions?.openSubagent == null
          ? null
          : () => widget.actions!.openSubagent!(
                context,
                widget.feed,
                childSessionId: sid,
                subagentType: row['subagentType'] as String?,
                workId: row['workId'] as String?,
                parentSessionId: _sessionId,
                confirmWindow: widget.confirmWindow,
              ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ZType.body.copyWith(color: ZInk.solid(context)),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              tr(context, wordKey),
              style: ZType.caption.copyWith(color: ZInk.faint(context)),
            ),
            Icon(Icons.chevron_right, size: 14, color: ZInk.ghost(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadMore(BuildContext context) {
    if (_noMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Center(
          child: Text(
            trP(context, 'chat.subagentSheet.allLoaded', ['$_totalCount']),
            style: ZType.caption.copyWith(color: ZInk.muted(context)),
          ),
        ),
      );
    }
    return Center(
      child: TextButton.icon(
        onPressed: _paging ? null : _loadEarlier,
        icon: _paging
            ? const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              )
            : const Icon(Icons.history, size: 14),
        label: Text(
          tr(context, 'chat.subagentSheet.loadMore'),
          style: ZType.sub,
        ),
      ),
    );
  }
}

/// Compact ghost/danger action button of the management sheet (mock
/// .btn-ghost / .btn-stop).
/// Elapsed mm:ss of a running sheet row (1s cadence — the mock shows
/// second-precision durations).
class _SheetElapsed extends StatefulWidget {
  final num? startedAt;

  const _SheetElapsed({this.startedAt});

  @override
  State<_SheetElapsed> createState() => _SheetElapsedState();
}

class _SheetElapsedState extends State<_SheetElapsed> {
  Timer? _timer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final started = widget.startedAt?.toInt();
    if (started == null) return const SizedBox.shrink();
    final secs = (_now.millisecondsSinceEpoch - started) ~/ 1000;
    final m = secs ~/ 60;
    final s = secs % 60;
    final label = m <= 0
        ? trP(context, 'chat.time.secOnly', ['$s'])
        : trP(context, 'chat.time.minSec', ['$m', '$s']);
    return Text(
      label,
      style: ZType.sub.copyWith(
        color: ZInk.muted(context),
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

class _QueueBar extends StatelessWidget {
  final ConversationState state;
  final ConversationPort conversation;

  const _QueueBar({required this.state, required this.conversation});

  @override
  Widget build(BuildContext context) {
    final items = state.queueItems;
    if (items.isEmpty) return const SizedBox.shrink();
    final sessionId = state.snapshot?['sessionId'] as String? ?? '';
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      padding: const EdgeInsets.all(10),
      // The queue is a neutral sub-surface inside the composer
      // area — no accent tint. ZInk.tile's contract names the queue directly.
      decoration: BoxDecoration(
        color: ZInk.tile(context),
        borderRadius: BorderRadius.circular(ZRadius.tile),
        border: Border.all(color: ZInk.hairline(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.queue_outlined,
                  size: 14, color: ZInk.muted(context)),
              const SizedBox(width: 6),
              Text(
                trP(context, 'chat.queue.count', ['${items.length}']),
                style: ZType.sub.copyWith(color: ZInk.muted(context)),
              ),
              const Spacer(),
              InkWell(
                onTap: () {
                  final next = !state.autoDrain;
                  state.optimisticPatch({
                    'queue': {...?state.queue, 'autoDrain': next},
                  });
                  conversation.conversationCommands.setAutoDrain(sessionId, next);
                },
                child: Text(
                  state.autoDrain
                      ? tr(context, 'chat.queue.autoOn')
                      : tr(context, 'chat.queue.autoOff'),
                  style: ZType.caption.copyWith(color: ZInk.muted(context)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Each queued message is its own pill row with
          // a drag handle (⋮⋮) for reordering — no up/down arrows.
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            buildDefaultDragHandles: false,
            itemCount: items.length,
            onReorderItem: (oldIndex, newIndex) {
              if (newIndex == oldIndex) return;
              // onReorderItem's newIndex is the post-removal insert position;
              // map it onto the web's beforeQueueItemId semantics.
              final before = newIndex > oldIndex ? newIndex + 1 : newIndex;
              _reorder(context, sessionId, items, oldIndex,
                  before >= items.length ? null : before);
            },
            itemBuilder: (context, i) {
              return Padding(
                key: ValueKey('${items[i]['queueItemId']}'),
                padding: EdgeInsets.only(bottom: i == items.length - 1 ? 0 : 4),
                child: Container(
                  decoration: BoxDecoration(
                    color: ZInk.card(context),
                    borderRadius: BorderRadius.circular(ZRadius.field),
                    border: Border.all(color: ZInk.hairline(context)),
                  ),
                  child: Row(
                    children: [
                      ReorderableDragStartListener(
                        index: i,
                        child: SizedBox(
                          width: 36,
                          height: 44,
                          child: Icon(Icons.drag_indicator,
                              size: 18, color: ZInk.ghost(context)),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          '${items[i]['text'] ?? ''}',
                          style: ZType.sub.copyWith(color: ZInk.soft(context)),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      _QueueAction(
                        icon: Icons.play_arrow,
                        tooltip: tr(context, 'chat.queue.sendNow'),
                        onTap: () {
                          final id = '${items[i]['queueItemId']}';
                          state.optimisticRemoveQueueItem(id);
                          conversation.conversationCommands.sendQueuedNow(sessionId, id);
                        },
                      ),
                      _QueueAction(
                        icon: Icons.edit_outlined,
                        tooltip: tr(context, 'chat.queue.edit'),
                        onTap: () => _edit(context, sessionId, items[i]),
                      ),
                      _QueueAction(
                        icon: Icons.close,
                        tooltip: tr(context, 'devices.menu.delete'),
                        onTap: () async {
                          final id = '${items[i]['queueItemId']}';
                          final confirmed = await showDialog<bool>(
                            context: context,
                            useRootNavigator: false,
                            builder: (context) => AlertDialog(
                              title: Text(tr(context, 'chat.queue.delete.title')),
                              content: Text(
                                '${items[i]['text'] ?? ''}',
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context, false),
                                  child: Text(tr(context, 'devices.add.cancel')),
                                ),
                                FilledButton(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: ZColors.danger,
                                  ),
                                  onPressed: () => Navigator.pop(context, true),
                                  child: Text(
                                    tr(context, 'devices.delete.confirm'),
                                  ),
                                ),
                              ],
                            ),
                          );
                          if (confirmed != true) return;
                          state.optimisticRemoveQueueItem(id);
                          conversation.conversationCommands.deleteQueueItem(sessionId, id);
                        },
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  /// Drag-to-reorder: the same `reorderQueueItem
  /// {queueItemId, beforeQueueItemId|null}` command, driven by the
  /// drag handle on each queued row.
  /// [targetIndex] is the index the item should occupy after the move;
  /// `null` moves it to the end.
  void _reorder(
    BuildContext context,
    String sessionId,
    List<Map<String, dynamic>> items,
    int index,
    int? targetIndex,
  ) {
    if (targetIndex != null && (targetIndex < 0 || targetIndex > items.length)) {
      return;
    }
    final id = '${items[index]['queueItemId']}';
    final String? beforeId;
    if (targetIndex == null) {
      beforeId = null;
    } else if (targetIndex == items.length) {
      beforeId = null;
    } else {
      beforeId = '${items[targetIndex]['queueItemId']}';
    }
    conversation.conversationCommands.reorderQueueItem(sessionId, id, beforeId);
  }

  Future<void> _edit(
    BuildContext context,
    String sessionId,
    Map<String, dynamic> item,
  ) async {
    final controller = TextEditingController(text: '${item['text'] ?? ''}');
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, 'chat.queue.edit.title')),
        content: TextField(
          controller: controller,
          maxLines: 4,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr(context, 'devices.add.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(tr(context, 'devices.rename.save')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.isEmpty) return;
    // Optimistic text update; server queue patch confirms.
    final q = state.queue;
    if (q != null && q['items'] is List) {
      final items = [
        for (final i in q['items'] as List)
          if (i is Map && '${i['queueItemId']}' == '${item['queueItemId']}')
            {...i, 'text': text}
          else
            i,
      ];
      state.optimisticPatch({
        'queue': {...q, 'items': items},
      });
    }
    await conversation.conversationCommands.editQueueItem(sessionId, '${item['queueItemId']}', text);
  }
}

class _QueueAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _QueueAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(
        icon,
        size: 16,
        color: ZInk.muted(context),
      ),
      tooltip: tooltip,
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
    );
  }
}

/// Locally-queued replayable messages (3.12.3 `web-remote-replayable`):
/// sendText failures at bridge level, waiting for recovery to be enqueued.
/// pendingCommands card semantics — one pill row per message with
/// the first content line, the current state and an undo action (local
/// removal + idempotent `cancelTaskCommand`).
class _ReplayableQueueBar extends StatelessWidget {
  final ReplayableCommandQueue queue;

  const _ReplayableQueueBar({required this.queue});

  @override
  Widget build(BuildContext context) {
    final items = queue.items;
    if (items.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      padding: const EdgeInsets.all(10),
      // Same neutral sub-surface as the held queue bar (_QueueBar).
      decoration: BoxDecoration(
        color: ZInk.tile(context),
        borderRadius: BorderRadius.circular(ZRadius.tile),
        border: Border.all(color: ZInk.hairline(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < items.length; i++)
            Padding(
              padding: EdgeInsets.only(bottom: i == items.length - 1 ? 0 : 4),
              child: Container(
                padding: const EdgeInsets.fromLTRB(10, 2, 2, 2),
                decoration: BoxDecoration(
                  color: ZInk.card(context),
                  borderRadius: BorderRadius.circular(ZRadius.field),
                  border: Border.all(color: ZInk.hairline(context)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            items[i].content,
                            style: ZType.sub.copyWith(
                              color: ZInk.soft(context),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            switch (items[i].state) {
                              ReplayableQueueItemState.queued =>
                                tr(context, 'chat.replayable.queued'),
                              ReplayableQueueItemState.sending =>
                                tr(context, 'chat.replayable.sending'),
                              ReplayableQueueItemState.failed =>
                                tr(context, 'chat.replayable.failed'),
                            },
                            style: ZType.caption.copyWith(
                              color:
                                  items[i].state ==
                                      ReplayableQueueItemState.failed
                                  ? ZInk.dangerTone(context)
                                  : ZInk.muted(context),
                            ),
                          ),
                          if (items[i].state == ReplayableQueueItemState.failed &&
                              items[i].error != null)
                            Text(
                              items[i].error!,
                              style: ZType.caption.copyWith(
                                color: ZInk.muted(context),
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                    if (items[i].state == ReplayableQueueItemState.failed)
                      _QueueAction(
                        icon: Icons.refresh,
                        tooltip: tr(context, 'tasks.retry'),
                        onTap: () => queue.retry(items[i].commandId),
                      ),
                    _QueueAction(
                      icon: Icons.close,
                      tooltip: tr(context, 'chat.replayable.undo'),
                      onTap: () => queue.cancel(items[i].commandId),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PendingFilesBar extends StatelessWidget {
  final List<_PendingFile> files;
  final double? uploadProgress;
  final void Function(int index) onRemove;

  const _PendingFilesBar({
    required this.files,
    required this.uploadProgress,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: ZInk.tile(context),
        borderRadius: BorderRadius.circular(ZRadius.tile),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (uploadProgress != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: LinearProgressIndicator(value: uploadProgress),
            ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var i = 0; i < files.length; i++)
                Chip(
                  avatar: const Icon(Icons.attach_file, size: 14),
                  label: Text(
                    files[i].fileName,
                    style: ZType.caption,
                  ),
                  onDeleted: () => onRemove(i),
                  deleteIcon: const Icon(Icons.close, size: 14),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// ---------------------------------------------------------------- interactions

/// One pending-interaction card — the shared builder for BOTH surfaces
/// (bottom strip and anchored-in-stream, D9) so resolve/snooze wiring stays
/// single-sourced. [readOnly] (design D2, subagent detail page) keeps the
/// question + options display while hiding every answering affordance.
Widget _interactionCardFor({
  required ConversationState state,
  required ConversationPort conversation,
  required Map<String, dynamic> interaction,
  bool readOnly = false,
}) {
  final sessionId = state.snapshot?['sessionId'] as String? ?? '';
  if ((interaction['payload'] as Map?)?['kind'] == 'workspaceHookReview') {
    final payload = interaction['payload'];
    return _HookReviewCard(
      interaction: interaction,
      readOnly: readOnly,
      onTrust: (reviewItemIds) => conversation.conversationCommands
          .respondWorkspaceHookReview(
            sessionId,
            payload is Map
                ? Map<String, dynamic>.from(payload)
                : const {},
            reviewItemIds,
          ),
    );
  }
  return _InteractionCard(
    interaction: interaction,
    readOnly: readOnly,
    onResolve: ({optionId, freeText, action, content}) =>
        conversation.conversationCommands.resolveInteraction(
          sessionId,
          interaction['interactionId'] as String? ?? '',
          optionId: optionId,
          freeText: freeText,
          action: action,
          content: content,
        ),
    onSnooze: () => conversation.conversationCommands.snoozeInteractionAutoResolution(
          sessionId,
          interaction['interactionId'] as String? ?? '',
        ),
  );
}

class _PendingInteractions extends StatelessWidget {
  final ConversationState state;
  final ConversationPort conversation;

  const _PendingInteractions({required this.state, required this.conversation});

  @override
  Widget build(BuildContext context) {
    final interactions = state.pendingInteractions;
    if (interactions.isEmpty) return const SizedBox.shrink();
    // D9 mutual exclusion: interactions whose anchorRowId resolved into the
    // held window render IN the stream (after their turn group) — the bottom
    // list carries only the unanchored rest.
    final anchoredIds =
        anchoredInteractionPlan(groupChatRows(state.rows), interactions)
            .anchoredIds;
    final bottom = [
      for (final interaction in interactions)
        if (!(interaction['interactionId'] is String &&
            anchoredIds.contains(interaction['interactionId'])))
        interaction,
    ];
    if (bottom.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        for (final interaction in bottom)
          _interactionCardFor(
            state: state,
            conversation: conversation,
            interaction: interaction,
          ),
      ],
    );
  }
}

class _InteractionCard extends StatefulWidget {
  final Map<String, dynamic> interaction;
  final Future<dynamic> Function({
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  })
  onResolve;

  /// Defers the auto-resolution timer (web snoozeInteractionAutoResolution,
  /// desktop setting「提问自动继续」).
  final Future<void> Function()? onSnooze;

  /// Read-only boundary (design D2): question + options stay visible as
  /// plain display (option affordances greyed out); the answering inputs
  /// (free-text row, questions' custom answers + submit) and snooze hide —
  /// child-session questions are answered via the parent conversation.
  final bool readOnly;

  const _InteractionCard({
    required this.interaction,
    required this.onResolve,
    this.onSnooze,
    this.readOnly = false,
  });

  @override
  State<_InteractionCard> createState() => _InteractionCardState();
}

class _InteractionCardState extends State<_InteractionCard> {
  final _freeTextController = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _freeTextController.dispose();
    super.dispose();
  }

  Future<void> _resolve({
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onResolve(
        optionId: optionId,
        freeText: freeText,
        action: action,
        content: content,
      );
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final payload = widget.interaction['payload'];
    if (payload is! Map) return const SizedBox.shrink();
    final kind = payload['kind'];
    final options = payload['options'];
    final questions = payload['questions'];
    final freeText = payload['freeText'] == true;
    // Sensitive input masking (D8): payload-level `sensitive` (F6 batch:
    // runtime @696465 — question-level has NO sensitive field) renders both
    // the free-text row and the questions' custom inputs in password mode.
    final sensitive = payload['sensitive'] == true;
    // A questions form replaces the free-text row —
    // each question carries its own custom-answer input, so a second input
    // would only blur which field answers what. The plain input stays for
    // freeText-only interactions (no questions): their only answering
    // channel.
    final hasQuestions = questions is List && questions.isNotEmpty;

    final title = kind == 'permission'
        ? trP(context, 'chat.interact.permission', [
            '${payload['toolName'] ?? ''}',
          ])
        : tr(context, 'chat.interact.waiting');

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ZColors.warning.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(ZRadius.tile),
        border: Border.all(color: ZColors.warning.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.privacy_tip_outlined,
                size: 14,
                color: ZInk.warningTone(context),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: ZType.body.copyWith(color: ZInk.solid(context)),
                ),
              ),
            ],
          ),
          if (kind == 'userInput' &&
              (payload['prompt'] as String? ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '${payload['prompt']}',
                style: ZType.sub.copyWith(color: ZInk.soft(context)),
              ),
            ),
          if (kind == 'permission' && payload['summary'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '${payload['summary']}',
                style: ZType.sub.copyWith(color: ZInk.soft(context)),
              ),
            ),
          const SizedBox(height: 8),
          if (options is List && options.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final option in options)
                  if (option is Map)
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        minimumSize: Size.zero,
                      ),
                      // Read-only (D2): options stay on display, greyed out.
                      onPressed: widget.readOnly || _busy
                          ? null
                          : () => _resolve(optionId: '${option['optionId']}'),
                      child: Text(
                        _optionLabel(option),
                        style: ZType.sub,
                      ),
                    ),
              ],
            ),
          if (questions is List && questions.isNotEmpty)
            _QuestionsView(
              questions: questions.cast<Map>(),
              busy: _busy,
              sensitive: sensitive,
              readOnly: widget.readOnly,
              onResolve: (content) =>
                  _resolve(content: content, action: 'accept'),
            ),
          if (freeText && !hasQuestions && !widget.readOnly)
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _freeTextController,
                    style: ZType.body,
                    obscureText: sensitive,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: tr(context, 'chat.interact.hint'),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.send, size: 18),
                  onPressed: _busy
                      ? null
                      : () =>
                            _resolve(freeText: _freeTextController.text.trim()),
                ),
              ],
            ),
          if (widget.onSnooze != null && !widget.readOnly)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: InkWell(
                  borderRadius: BorderRadius.circular(ZRadius.mini),
                  onTap: _busy ? null : () => widget.onSnooze!(),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.snooze_outlined,
                          size: 12,
                          color: ZInk.muted(context),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          tr(context, 'chat.interact.snooze'),
                          style: ZType.caption.copyWith(
                            color: ZInk.muted(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // Permission options ride the desktop lexicon's canonical English labels
  // ("chat.permission.*" family); when the schema-required `kind` ever goes
  // missing, these spellings still map to the localized strings. Model-
  // authored question choices (questions[].options) never pass through here
  // and render verbatim.
  static const _canonicalOptionLabels = {
    'allow once': 'chat.interact.allowOnce',
    'always allow': 'chat.interact.allowAlways',
    'always allow in this project': 'chat.interact.allowAlways',
    'deny': 'chat.interact.deny',
  };

  String _optionLabel(Map option) {
    // kind (schema-required enum) is the localization key; the wire `label`
    // is canonical English and would shadow it (10-28: zh UI showed English
    // buttons because label took precedence).
    final kind = option['kind'] as String?;
    final kindKey = switch (kind) {
      'allowOnce' => 'chat.interact.allowOnce',
      'allowAlways' => 'chat.interact.allowAlways',
      'deny' => 'chat.interact.deny',
      'custom' => 'chat.interact.custom',
      _ => null,
    };
    if (kindKey != null) return tr(context, kindKey);
    final label = option['label'] as String?;
    if (label != null && label.isNotEmpty) {
      final canonical = _canonicalOptionLabels[
          label.trim().toLowerCase()];
      return canonical == null ? label : tr(context, canonical);
    }
    return '${option['optionId'] ?? tr(context, 'chat.interact.pick')}';
  }
}

/// trustState values carried by the workspaceHookReview interaction items
/// (3.12.3 wire enum) with a badge color each. The colors below are base
/// (dark) references only — [_trustBadge] resolves every state through its
/// ZInk tone slot at the use site so the label stays readable in light mode;
/// the key set here must stay complete — the badge label lookup relies on
/// [containsKey].
const _hookTrustStates = <String, Color>{
  'not_applicable': ZColors.neutral500,
  'pending_trust': ZColors.warning,
  'trusted_persistent': ZColors.success,
  'blocked_untrusted': ZColors.danger,
  'blocked_policy': ZColors.danger,
  'revoked': ZColors.danger,
  'stale_digest': ZColors.warning,
};

/// Renders the `workspaceHookReview` interaction (3.12.3 workspace hooks):
/// workspace label, bundle summary and a per-hook checklist — every item
/// starts checked, so the single action trusts all pending hooks at once
/// (the desktop decision schema has no decline action; unanswered reviews
/// time out server-side).
class _HookReviewCard extends StatefulWidget {
  final Map<String, dynamic> interaction;
  final Future<dynamic> Function(List<String> reviewItemIds) onTrust;

  /// Read-only boundary (design D2, step-3 supplement): hides the trust
  /// action on the subagent detail page — respondWorkspaceHookReview is a
  /// write command against the child session.
  final bool readOnly;

  const _HookReviewCard({
    required this.interaction,
    required this.onTrust,
    this.readOnly = false,
  });

  @override
  State<_HookReviewCard> createState() => _HookReviewCardState();
}

class _HookReviewCardState extends State<_HookReviewCard> {
  final Set<String> _checked = {};
  bool _busy = false;

  /// Hook items of the interaction frame; tolerant of missing fields.
  List<Map> get _items {
    final payload = widget.interaction['payload'];
    final items = payload is Map ? payload['items'] : null;
    return items is List ? items.whereType<Map>().toList() : <Map>[];
  }

  @override
  void initState() {
    super.initState();
    _checked.addAll([for (final item in _items) '${item['reviewItemId']}']);
  }

  Future<void> _trust() async {
    if (_busy || _checked.isEmpty) return;
    setState(() => _busy = true);
    try {
      await widget.onTrust(List.of(_checked));
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final payload = widget.interaction['payload'];
    if (payload is! Map) return const SizedBox.shrink();
    final summary = payload['summary'];
    final summaryMap = summary is Map ? summary : const <String, dynamic>{};
    int count(String key) => (summaryMap[key] as num?)?.toInt() ?? 0;
    final workspaceLabel =
        '${payload['workspaceLabel'] ?? payload['workspaceIdentity'] ?? ''}';

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ZColors.warning.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(ZRadius.tile),
        border: Border.all(color: ZColors.warning.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.fact_check_outlined,
                size: 14,
                color: ZInk.warningTone(context),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  workspaceLabel.isNotEmpty
                      ? workspaceLabel
                      : tr(context, 'chat.hook.title'),
                  style: ZType.body.copyWith(color: ZInk.solid(context)),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              trP(context, 'chat.hook.summary', [
                '${count('eventCount')}',
                '${count('hookCount')}',
                '${count('pendingCount')}',
              ]),
              style: ZType.sub.copyWith(color: ZInk.soft(context)),
            ),
          ),
          for (final item in _items)
            _HookReviewItem(
              item: item,
              checked: _checked.contains('${item['reviewItemId']}'),
              busy: _busy,
              onChecked: widget.readOnly
                  ? null
                  : (on) => setState(() {
                        on == true
                            ? _checked.add('${item['reviewItemId']}')
                            : _checked.remove('${item['reviewItemId']}');
                      }),
            ),
          // Read-only: display-only card — no trust button (D2).
          if (!widget.readOnly)
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    minimumSize: Size.zero,
                  ),
                  onPressed: _busy || _checked.isEmpty ? null : _trust,
                child: Text(
                  tr(context, 'chat.hook.trustChecked'),
                  style: ZType.sub,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One checklist row: hook name, event name, the command in mono small
/// print and a trustState badge.
class _HookReviewItem extends StatelessWidget {
  final Map item;
  final bool checked;
  final bool busy;

  /// Null on the read-only subagent detail page — the checkbox shows its
  /// state but cannot be toggled (D2).
  final ValueChanged<bool?>? onChecked;

  const _HookReviewItem({
    required this.item,
    required this.checked,
    required this.busy,
    this.onChecked,
  });

  @override
  Widget build(BuildContext context) {
    final displayName =
        '${item['displayName'] ?? item['reviewItemId'] ?? ''}';
    final event = '${item['event'] ?? ''}';
    final displayCommand = '${item['displayCommand'] ?? ''}';
    final trustState = '${item['trustState'] ?? ''}';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 32,
          height: 28,
          child: Checkbox(value: checked, onChanged: busy ? null : onChecked),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        displayName,
                        style: ZType.sub.copyWith(
                          color: ZInk.solid(context),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    _trustBadge(context, trustState),
                  ],
                ),
                if (event.isNotEmpty)
                  Text(
                    event,
                    style: ZType.caption.copyWith(
                      color: ZInk.muted(context),
                    ),
                  ),
                if (displayCommand.isNotEmpty)
                  Text(
                    displayCommand,
                    style: ZType.caption.copyWith(
                      color: ZInk.faint(context),
                      fontFamily: 'monospace',
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _trustBadge(BuildContext context, String trustState) {
    if (trustState.isEmpty) return const SizedBox.shrink();
    final color = switch (trustState) {
      'blocked_untrusted' || 'blocked_policy' || 'revoked' =>
        ZInk.dangerTone(context),
      'pending_trust' || 'stale_digest' => ZInk.warningTone(context),
      'trusted_persistent' => ZInk.successTone(context),
      _ => _hookTrustStates[trustState] ?? ZColors.neutral500,
    };
    // Known enums render their localized label; unknown ones fall back to
    // the raw wire value instead of a broken tr key.
    final label = _hookTrustStates.containsKey(trustState)
        ? tr(context, 'chat.hook.state.$trustState')
        : trustState;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(ZRadius.mini),
      ),
      child: Text(label, style: ZType.caption.copyWith(color: color)),
    );
  }
}

/// Renders a form-style `userInput` interaction (the `questions` payload):
/// every question with its options. Selections stay local per question and
/// only the explicit ↑ submit sends the full-shape content
/// (`buildBotElicitationContent`: answers text keys + answer_N + accept).
class _QuestionsView extends StatefulWidget {
  final List<Map> questions;
  final bool busy;

  /// Payload-level `sensitive` (D8) — masks every question's custom input.
  final bool sensitive;

  /// Read-only boundary (design D2): option chips stay visible greyed out;
  /// the custom-answer chip/input and the submit button hide.
  final bool readOnly;
  final void Function(Map<String, dynamic> content) onResolve;

  const _QuestionsView({
    required this.questions,
    required this.busy,
    required this.sensitive,
    required this.onResolve,
    this.readOnly = false,
  });

  @override
  State<_QuestionsView> createState() => _QuestionsViewState();
}

class _QuestionsViewState extends State<_QuestionsView> {
  /// Collector — the semantic truth for option picks, custom-input open
  /// flags and custom text (see [InteractionAnswers]); the controllers
  /// below are view buffers only.
  InteractionAnswers _answers = const InteractionAnswers();

  /// One controller per question, created eagerly so the inline input can
  /// mount/unmount freely; a collapse always clears its text (no hidden
  /// state survives a collapse).
  final Map<int, TextEditingController> _customControllers = {};

  /// One focus node per question, paired with the controller. Focus is
  /// requested explicitly one frame after the input mounts — `autofocus`
  /// fires while the OEM IME (notably Xiaomi/HyperOS) is still starting and
  /// the show-keyboard request gets dropped.
  final Map<int, FocusNode> _customFocusNodes = {};

  @override
  void initState() {
    super.initState();
    for (var i = 0; i < widget.questions.length; i++) {
      final controller = TextEditingController();
      // Live rebuild while typing so the answered counter tracks the text.
      controller.addListener(() {
        if (mounted) setState(() {});
      });
      _customControllers[i] = controller;
      _customFocusNodes[i] = FocusNode();
    }
  }

  @override
  void dispose() {
    for (final controller in _customControllers.values) {
      controller.dispose();
    }
    for (final node in _customFocusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  /// View-buffer half of a collapse: the collector already dropped the
  /// semantic text — controller.clear() never fires onChanged, so the
  /// buffer is dropped here and mirrored via [InteractionAnswers.setCustom].
  void _clearCustomView(int index) {
    if (_customControllers[index]!.text.isNotEmpty) {
      _customControllers[index]!.clear();
      _answers = _answers.setCustom(index, '');
    }
  }

  /// Unified toggle: tapping the picked option deselects it (single-select
  /// may return to "nothing picked"), tapping another single-select option
  /// re-chooses. Any option tap collapses the custom input and drops its
  /// text — single-select options and the custom answer are mutually
  /// exclusive.
  void _toggleOption(int index, Map question, String value) {
    setState(() {
      _answers = _answers.toggleOption(index, question, value);
      _clearCustomView(index);
    });
  }

  /// Custom chip: expands the inline input and focuses it on the next frame
  /// (see [_customFocusNodes] for why not `autofocus`); tapping again
  /// collapses and clears. Multi-select keeps custom as an extra coexisting
  /// answer; single-select clears the picked option first.
  void _toggleCustom(int index, Map question) {
    setState(() {
      final wasOpen = _answers.customOpen.contains(index);
      _answers = _answers.toggleCustom(index, question);
      if (wasOpen) _clearCustomView(index);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _answers.customOpen.contains(index)) {
        _customFocusNodes[index]?.requestFocus();
      }
    });
  }

  /// Wire shape assembly lives in [buildInteractionContent]; this only
  /// pairs the current questions with the collector.
  Map<String, dynamic> _buildContent() =>
      buildInteractionContent(widget.questions, _answers);

  @override
  Widget build(BuildContext context) {
    final answered = [
      for (var i = 0; i < widget.questions.length; i++)
        if (_answers.answersOf(i).isNotEmpty) i,
    ].length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < widget.questions.length; i++)
          _QuestionItem(
            index: i,
            question: widget.questions[i],
            busy: widget.busy,
            sensitive: widget.sensitive,
            readOnly: widget.readOnly,
            selected: _answers.selections[i] ?? const [],
            customOpen: _answers.customOpen.contains(i),
            customController: _customControllers[i]!,
            customFocusNode: _customFocusNodes[i]!,
            onToggleOption: (value) =>
                _toggleOption(i, widget.questions[i], value),
            onToggleCustom: () => _toggleCustom(i, widget.questions[i]),
            onCustomChanged: (text) => _answers = _answers.setCustom(i, text),
          ),
        // Read-only (D2): no answering → no submit row (the answered
        // counter inside it can never light up either).
        if (!widget.readOnly)
          Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Answered counter, only once something is answered.
                if (answered > 0)
                  Padding(
                    padding: const EdgeInsets.only(right: 9),
                    child: Text(
                      trP(context, 'chat.interact.answered', [
                        '$answered',
                        '${widget.questions.length}',
                      ]),
                      style: ZType.caption.copyWith(
                        color: ZInk.faint(context),
                      ),
                    ),
                  ),
                // ↑ submit: the composer send key's squircle, bottom-right of
                // the card like the composer. Always tappable — nothing
                // picked sends the explicit "no answer" content; busy is the
                // one disabled/spinner state.
                SizedBox(
                  width: 36,
                  height: 36,
                  child: Tooltip(
                    message: tr(context, 'chat.interact.submitAnswers'),
                    child: Material(
                      color: widget.busy
                          ? ZColors.sky500.withValues(alpha: 0.75)
                          : ZColors.sky500,
                      borderRadius: BorderRadius.circular(ZRadius.mini),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(ZRadius.mini),
                        onTap: widget.busy
                            ? null
                            : () => widget.onResolve(_buildContent()),
                        child: Center(
                          child: widget.busy
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(
                                  Icons.arrow_upward,
                                  size: 18,
                                  color: Colors.white,
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _QuestionItem extends StatelessWidget {
  final int index;
  final Map question;
  final bool busy;

  /// Payload-level `sensitive` (D8) — password-mode custom input.
  final bool sensitive;

  /// Read-only boundary (design D2): option chips grey out; the custom
  /// -answer chip and its input never render.
  final bool readOnly;
  final List<String> selected;
  final bool customOpen;
  final TextEditingController customController;
  final FocusNode customFocusNode;
  final void Function(String value) onToggleOption;
  final void Function() onToggleCustom;

  /// Single sync point from the view buffer into the collector — the
  /// controller stays the view truth, [InteractionAnswers] the semantic one
  /// (the live rebuild for the answered counter rides the controller's
  /// addListener above).
  final void Function(String text) onCustomChanged;

  const _QuestionItem({
    required this.index,
    required this.question,
    required this.busy,
    required this.sensitive,
    required this.readOnly,
    required this.selected,
    required this.customOpen,
    required this.customController,
    required this.customFocusNode,
    required this.onToggleOption,
    required this.onToggleCustom,
    required this.onCustomChanged,
  });

  @override
  Widget build(BuildContext context) {
    final q = question;
    final label = q['label'] ?? q['question'] ?? q['value'] ?? '';
    final options = q['options'];
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${index + 1}. $label',
            style: ZType.sub.copyWith(height: 1.4, color: ZInk.solid(context)),
          ),
          if (q['description'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '${q['description']}',
                style: ZType.caption.copyWith(color: ZInk.faint(context)),
              ),
            ),
          if (options is List && options.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final o in options)
                    if (o is Map)
                      FilterChip(
                        label: Text(
                          '${o['label'] ?? o['value'] ?? ''}',
                          style: ZType.sub,
                        ),
                        selected: selected.contains('${o['value']}'),
                        // Read-only (D2): the option stays on display,
                        // greyed out.
                        onSelected: busy || readOnly
                            ? null
                            : (on) => onToggleOption('${o['value']}'),
                      ),
                  // Read-only (D2): the custom answer opens an input — an
                  // answering affordance, hidden.
                  if (!readOnly)
                    FilterChip(
                      avatar: const Icon(Icons.edit, size: 13),
                      label: Text(
                        tr(context, 'chat.interact.customAnswer'),
                        style: ZType.sub,
                      ),
                      selected: customOpen,
                      onSelected: busy ? null : (on) => onToggleCustom(),
                    ),
                ],
              ),
            ),
            if (customOpen && !readOnly)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: TextField(
                  key: ValueKey('askq-custom-$index'),
                  controller: customController,
                  focusNode: customFocusNode,
                  enabled: !busy,
                  onChanged: onCustomChanged,
                  obscureText: sensitive,
                  style: ZType.sub,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: tr(context, 'chat.interact.customHint'),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// ---------------------------------------------------------------- sheets

/// 'builtin:zai-coding-plan/GLM-5.2' → (provider, model)
/// 'uuid/deepseek/deepseek-v4.1-flash' → (uuid, 'deepseek/deepseek-v4.1-flash')
/// Split on the FIRST slash, mirroring the desktop `FC` parse: the provider
/// is the leading segment and the model is everything after it — model ids
/// may themselves contain '/' (Command Code's deepseek family), so a
/// trailing-slash split would put part of the model into the provider.
(String, String) _splitModelValue(String value) {
  final idx = value.indexOf('/');
  if (idx <= 0) return (value, value);
  return (value.substring(0, idx), value.substring(idx + 1));
}

/// Hides model choices whose `account:*` provider group the account is not
/// entitled to (design 10-24 §3). [entitledIds] null = the provider-settings
/// view could not be read (old desktop / bridge failure) → no filtering,
/// everything renders as before. An empty set is a successful read with zero
/// entitlements and filters every unentitled account group.
///
/// [currentProviderId] is exempt: the group holding the model in use (live
/// config or draft pick) never hides — a selection vanishing from the list
/// is more confusing than a visible unusable group. Personal providers
/// (non-`account:` ids) and options without a provider id are never hidden.
List<ConfigOptionValue> filterByEntitlement(
  List<ConfigOptionValue> choices, {
  required Set<String>? entitledIds,
  required String? currentProviderId,
}) {
  final entitled = entitledIds;
  if (entitled == null) return choices;
  return [
    for (final choice in choices)
      if (!_hidesModelChoice(choice, entitled, currentProviderId)) choice,
  ];
}

bool _hidesModelChoice(
  ConfigOptionValue choice,
  Set<String> entitledIds,
  String? currentProviderId,
) {
  final id = choice.modelProviderId;
  return id != null &&
      id.startsWith('account:') &&
      !entitledIds.contains(id) &&
      id != currentProviderId;
}

/// Why [StartPlanAutoSwitch.evaluate] considers the current Start plan done.
enum StartPlanSwitchReason { exhausted, expired, disentitled }

/// The auto-switch decision: which prep model option to switch to and which
/// terminal signal fired (design 10-24 §2).
typedef StartPlanSwitchPlan = ({
  ConfigOptionValue targetOption,
  StartPlanSwitchReason reason,
});

/// Start-plan terminal detection and target selection (design 10-24 §2) —
/// a pure function over the already-loaded page state, unit-tested against
/// the live-probed snapshot shapes (research §3/§7).
class StartPlanAutoSwitch {
  static final RegExp _startPlanProvider =
      RegExp(r'^account:(zai|bigmodel)-start-plan$');
  static final RegExp _codingPlanProvider =
      RegExp(r'^account:(zai|bigmodel)-(individual|team)-coding-plan$');

  /// Returns the switch plan when the live session's provider is a Start
  /// plan AND one of the three terminal signals fired AND an entitled
  /// coding-plan option exists; null otherwise (nothing to do, or not this
  /// feature's business).
  ///
  /// [entitledIds] follows the gateway convention: null = the provider
  /// settings view could not be read, so entitlement is unknown and the
  /// whole judgement is skipped; an empty set still judges (the target
  /// lookup then simply finds nothing).
  static StartPlanSwitchPlan? evaluate({
    required EntitlementView view,
    required Set<String>? entitledIds,
    required String? currentProviderId,
    required String? currentModelId,
    required List<ConfigOptionValue> modelOptions,
  }) {
    final provider = currentProviderId ?? '';
    if (!_startPlanProvider.hasMatch(provider)) return null;
    if (entitledIds == null) return null;
    final reason = view.exhausted
        ? StartPlanSwitchReason.exhausted
        : view.data?['startPlanExpired'] == true
        ? StartPlanSwitchReason.expired
        : !entitledIds.contains(provider)
        ? StartPlanSwitchReason.disentitled
        : null;
    if (reason == null) return null;
    // Official FPe order: an entitled coding plan (individual/team) outranks
    // the Start plan; the set preserves the provider-settings view order.
    String? targetProvider;
    for (final id in entitledIds) {
      if (_codingPlanProvider.hasMatch(id)) {
        targetProvider = id;
        break;
      }
    }
    if (targetProvider == null) return null;
    final candidates = [
      for (final option in modelOptions)
        if (_optionProviderId(option) == targetProvider) option,
    ];
    if (candidates.isEmpty) return null;
    final modelId = _splitModelValue(currentModelId ?? '').$2;
    final target = modelId.isEmpty
        ? candidates.first
        : candidates.firstWhere(
            (option) => _splitModelValue(option.value).$2 == modelId,
            orElse: () => candidates.first,
          );
    return (targetOption: target, reason: reason);
  }

  /// The option's provider: the wire `modelProviderId` when present, else
  /// the provider segment of its `provider/model` value (older desktops).
  static String? _optionProviderId(ConfigOptionValue option) {
    final explicit = option.modelProviderId;
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final fromValue = _splitModelValue(option.value).$1;
    return fromValue.isEmpty ? null : fromValue;
  }
}

class _ModelModeSheet extends StatelessWidget {
  final ConversationPort conversation;
  final ConversationState? state;
  final WorkspacePrep? prep;
  final String? sessionId;

  /// PRD 09-19 fallback: enabled providers from the `model-provider`
  /// channel, fetched by the page only when [prep] carries no model
  /// options. Empty when the channel is gone → the degraded text stays.
  final List<Map<String, dynamic>> providerCatalog;
  final Map<String, String>? draftConfig;
  final void Function(String key, String value)? onDraftChange;

  /// Entitled `account:*` provider ids prefetched by the page (design
  /// 10-24 §3) — null keeps every group (view unreachable / no answer).
  final Set<String>? entitledIds;

  /// Provider of the currently selected model (live config or draft pick);
  /// its group is exempt from the entitlement filter.
  final String? currentProviderId;

  /// Design 10-01: every issued switchModelConfig is reported to the page
  /// (which stores it as [_ChatPageState._lastSwitch]) so a bridge-lost
  /// switch can be auto-retried once on revert detection.
  final void Function(_LastSwitch record)? onSwitchIssued;

  /// Live-session model tap (design 10-24 §4): the whole switch chain lives
  /// in [_ChatPageState.switchModel] so the Start-plan auto switch reuses it
  /// verbatim; the sheet only forwards the choice.
  final void Function(ConfigOptionValue value)? onSwitchModel;

  const _ModelModeSheet({
    required this.conversation,
    required this.state,
    required this.prep,
    required this.sessionId,
    required this.providerCatalog,
    this.draftConfig,
    this.onDraftChange,
    this.entitledIds,
    this.currentProviderId,
    this.onSwitchIssued,
    this.onSwitchModel,
  });

  bool get _isDraft => sessionId == null || sessionId!.isEmpty;

  /// Config options beyond the model/mode/thought selects (e.g. max output
  /// length, search enhancement) surfaced read-only from prepareWorkspace.
  List<ConfigOption> get _otherOptions {
    const known = {'model', 'mode', 'thought_level'};
    final options = prep?.configOptions;
    if (options == null) return const [];
    return options.where((o) => !known.contains(o.id)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final sid = sessionId ?? '';
    final config = state?.config ?? const {};
    final modelOption = prep?.option('model');
    // PRD 09-19: when prepareWorkspace ships no usable model options, the
    // model section renders the model-provider catalog instead; provider
    // ids never contain '/', so `_splitModelValue` still splits cleanly.
    // Design 10-24 §3: the entitlement filter runs once over the assembled
    // list (wire options and the fallback catalog alike) before rendering.
    final modelChoices = filterByEntitlement(
      (modelOption != null && modelOption.options.isNotEmpty)
          ? modelOption.options
          : <ConfigOptionValue>[
              for (final p in providerCatalog)
                for (final m in (p['models'] as List? ?? const []))
                  ConfigOptionValue(
                    value:
                        '${p['id'] ?? p['name'] ?? ''}/'
                        '${m is Map ? '${m['id'] ?? m['modelId'] ?? ''}' : '$m'}',
                    name: m is Map ? '${m['id'] ?? m['modelId'] ?? ''}' : '$m',
                    // Same provider segment the value carries; missing ids
                    // stay null (never filtered — nothing to match on).
                    modelProviderId: p['id'] is String &&
                            (p['id'] as String).isNotEmpty
                        ? p['id'] as String
                        : null,
                    modelProviderName: '${p['name'] ?? p['id'] ?? ''}',
                  ),
            ],
      entitledIds: entitledIds,
      currentProviderId: currentProviderId,
    );
    final modeOption = prep?.option('mode');
    final thoughtOption = prep?.option('thought_level');
    final followup = '${config['followupMode'] ?? 'queue'}';

    // Current selection: prefer the LIVE session config (updates after a
    // switch), fall back to prepareWorkspace's currentValue / draft. The
    // draft branch walks the same chain the payload ships
    // ([effectiveNewTaskThought]) so the sheet never shows "unselected"
    // while createSession carries a defaulted level.
    final liveModelValue =
        '${config['provider'] ?? ''}/${config['model'] ?? ''}';
    final currentModelValue =
        _isDraft || config['model'] == null || '${config['model']}'.isEmpty
        ? (draftConfig?['model'] ?? '${modelOption?.currentValue ?? ''}')
        : liveModelValue;
    final currentThoughtValue = _isDraft
        ? effectiveNewTaskThought(draftConfig, prep)
        : (state?.currentThought.isNotEmpty == true
              ? state!.currentThought
              : '${thoughtOption?.currentValue ?? ''}');
    final currentModeValue = _isDraft
        ? (draftConfig?['mode'] ?? 'build')
        : state?.currentMode ?? 'build';

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(
            horizontal: ZSpacing.screen, vertical: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _isDraft
                  ? tr(context, 'chat.sheet.draftTitle')
                  : tr(context, 'chat.sheet.title'),
              style: ZType.heading,
            ),
            const SizedBox(height: 16),
            if (modelChoices.isNotEmpty) ...[
              // Desktop ships config-option names in English (wire 3.14 定证
              // `{id:"model", name:"Model"}` — same class as "Full access",
              // i18n spec §9), so the section header always rides the local
              // lexicon; `option('model')` matches by id, so there is no
              // other legit desktop name to fall back to.
              Text(
                tr(context, 'chat.composer.modelPlaceholder'),
                style: ZType.body.copyWith(color: ZInk.solid(context)),
              ),
              const SizedBox(height: 8),
              // The menu groups models by provider (BigModel /
              // tx / kimi_zz …): header whenever the provider changes.
              // The GROUP KEY prefers the provider id (design 10-24 §4) so
              // two providers sharing a display name never merge; the header
              // text stays the provider name.
              for (final (i, v) in modelChoices.indexed) ...[
                if (i == 0 ||
                    (v.modelProviderId ?? v.modelProviderName) !=
                        (modelChoices[i - 1].modelProviderId ??
                            modelChoices[i - 1].modelProviderName))
                  Padding(
                    padding: EdgeInsets.only(top: i == 0 ? 0 : 10, bottom: 2),
                    child: Text(
                      v.modelProviderName ?? v.name,
                      style: ZType.caption.copyWith(
                        fontWeight: FontWeight.w600,
                        color: ZInk.ghost(context),
                      ),
                    ),
                  ),
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    currentModelValue == v.value
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: 18,
                    color: currentModelValue == v.value
                        ? ZColors.sky500
                        : ZInk.ghost(context),
                  ),
                  title: Text(
                    v.name,
                    style: ZType.body.copyWith(color: ZInk.solid(context)),
                  ),
                  subtitle: v.modelProviderName != null
                      ? Text(
                          v.modelProviderName!,
                          style: ZType.caption.copyWith(
                            color: ZInk.faint(context),
                          ),
                        )
                      : null,
                  onTap: () {
                    if (_isDraft) {
                      onDraftChange?.call('model', v.value);
                    } else {
                      // Behavior frozen (design 10-24 §4): the page method is
                      // the very chain that used to live here — thought
                      // validity, optimistic patch, revert trace, retry
                      // record and the sheet-close choreography.
                      onSwitchModel?.call(v);
                    }
                  },
                ),
              ],
              const SizedBox(height: 12),
            ] else
              Text(
                trP(context, 'chat.sheet.currentModel', [
                  state?.currentModel ?? '',
                ]),
                style: ZType.sub.copyWith(color: ZInk.muted(context)),
              ),
            if (thoughtOption != null && thoughtOption.options.isNotEmpty) ...[
              // Same wire discipline as the model header above: desktop
              // config-option names are English ("Thought level"), the
              // section title always rides the local lexicon (the chip
              // labels below stay the desktop originals).
              Text(
                tr(context, 'chat.sheet.thought'),
                style: ZType.body.copyWith(color: ZInk.solid(context)),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final v in thoughtOption.options)
                    ChoiceChip(
                      label: Text(v.name),
                      selected:
                          currentThoughtValue == v.value ||
                          state?.currentThought == v.value,
                      onSelected: (_) {
                        if (_isDraft) {
                          onDraftChange?.call('thought', v.value);
                        } else {
                          final modelValue = currentModelValue;
                          final (provider, model) = modelValue.isNotEmpty
                              ? _splitModelValue(modelValue)
                              : (
                                  '${config['provider'] ?? ''}',
                                  '${config['model'] ?? ''}',
                                );
                          Map<String, dynamic> switchedConfig() => {
                            ...?state!.config,
                            'thought': v.value,
                          };
                          void patch() => state?.optimisticPatch({
                            'config': switchedConfig(),
                          });
                          onSwitchIssued?.call(
                            _LastSwitch(sid, provider, model, v.value, patch),
                          );
                          _apply(
                            context,
                            () => conversation.conversationCommands.switchModelConfig(
                              sid,
                              provider: provider,
                              model: model,
                              thought: v.value,
                            ),
                            // Same trace discipline as the model switch
                            // (design 10-02 Step 3): accepted clears, lost
                            // ack lands the patch and arms.
                            onAccepted: () {
                              state?.clearConfigRevertTrace();
                              patch();
                            },
                            onTimeoutOptimistic: () {
                              patch();
                              state?.armConfigRevertTrace({
                                'config': switchedConfig(),
                              });
                            },
                          );
                        }
                      },
                    ),
                ],
              ),
            ] else if ((state?.thoughtLevels ?? const []).isNotEmpty) ...[
              Text(
                tr(context, 'chat.sheet.thought'),
                style: ZType.body.copyWith(color: ZInk.solid(context)),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final level in state!.thoughtLevels)
                    ChoiceChip(
                      label: Text(level),
                      selected: state?.currentThought == level,
                      onSelected: (_) {
                        // The degraded path never patched optimistically, so
                        // the record's re-land is a no-op — the retry only
                        // re-sends the command (behavior frozen otherwise).
                        onSwitchIssued?.call(
                          _LastSwitch(
                            sid,
                            '${config['provider'] ?? ''}',
                            '${config['model'] ?? ''}',
                            level,
                            () {},
                          ),
                        );
                        _apply(
                          context,
                          () => conversation.conversationCommands.switchModelConfig(
                            sid,
                            provider: '${config['provider'] ?? ''}',
                            model: '${config['model'] ?? ''}',
                            thought: level,
                          ),
                        );
                      },
                    ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            Text(
              tr(context, 'chat.sheet.mode'),
              style: ZType.body.copyWith(color: ZInk.solid(context)),
            ),
            const SizedBox(height: 8),
            if (modeOption != null && modeOption.options.isNotEmpty)
              for (final v in modeOption.options)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    currentModeValue == v.value
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: 18,
                    color: currentModeValue == v.value
                        ? ZColors.sky500
                        : ZInk.ghost(context),
                  ),
                  // Desktop's config-options payload carries English-only
                  // names ("Full access" for yolo); local labels are the
                  // display source, same table the no-prep fallback uses.
                  title: Text(
                    tr(context, 'chat.mode.${v.value}'),
                    style: ZType.body.copyWith(color: ZInk.solid(context)),
                  ),
                  subtitle: Text(
                    tr(context, 'chat.mode.${v.value}.desc'),
                    style: ZType.caption.copyWith(
                      color: ZInk.faint(context),
                    ),
                  ),
                  onTap: () {
                    if (_isDraft) {
                      onDraftChange?.call('mode', v.value);
                    } else {
                      _apply(
                        context,
                        () => conversation.conversationCommands.switchCollaborationMode(sid, v.value),
                        onAccepted: () => state?.optimisticPatch({
                          'config': {...?state!.config, 'mode': v.value},
                        }),
                      );
                    }
                  },
                )
            else
              for (final m in const ['build', 'edit', 'plan', 'yolo'])
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    currentModeValue == m
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: 18,
                    color: currentModeValue == m
                        ? ZColors.sky500
                        : ZInk.ghost(context),
                  ),
                  title: Text(
                    tr(context, 'chat.mode.$m'),
                    style: ZType.body.copyWith(color: ZInk.solid(context)),
                  ),
                  subtitle: Text(
                    tr(context, 'chat.mode.$m.desc'),
                    style: ZType.caption.copyWith(color: ZInk.faint(context)),
                  ),
                  onTap: () {
                    if (_isDraft) {
                      onDraftChange?.call('mode', m);
                    } else {
                      _apply(
                        context,
                        () => conversation.conversationCommands.switchCollaborationMode(sid, m),
                        onAccepted: () => state?.optimisticPatch({
                          'config': {...?state!.config, 'mode': m},
                        }),
                      );
                    }
                  },
                ),
            if (!_isDraft) ...[
              const SizedBox(height: 16),
              Text(
                tr(context, 'chat.sheet.followup'),
                style: ZType.body.copyWith(color: ZInk.solid(context)),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final f in const ['queue', 'guide'])
                    ChoiceChip(
                      label: Text(
                        f == 'queue'
                            ? tr(context, 'chat.followup.queue')
                            : tr(context, 'chat.followup.guide'),
                      ),
                      selected: followup == f,
                      onSelected: (_) => _apply(
                        context,
                        () => conversation.conversationCommands.setFollowupMode(sid, f),
                        onAccepted: () => state?.optimisticPatch({
                          'config': {...?state!.config, 'followupMode': f},
                        }),
                      ),
                    ),
                ],
              ),
            ],
            if (_otherOptions.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                tr(context, 'chat.sheet.other'),
                style: ZType.body.copyWith(color: ZInk.solid(context)),
              ),
              const SizedBox(height: 8),
              for (final o in _otherOptions)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          o.name,
                          style: ZType.body.copyWith(color: ZInk.solid(context)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${o.currentValue}',
                        style: ZType.sub.copyWith(color: ZInk.muted(context)),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Runs a config command and lands [onAccepted] on an accepted answer.
///
/// [onTimeoutOptimistic] marks a switchModelConfig call (PRD 09-19): the
/// server answers `accepted` but pushes no confirming frame, and the
/// bridge's ~10s reconnect window can swallow the response after the
/// server already applied the switch. A transport-level failure is
/// therefore not a rejection: the callback lands the optimistic patch,
/// the sheet closes with a "pending" toast, and the next sheet open (or
/// a later state frame) shows the real value. Explicit status
/// rejections keep the rejection SnackBar and never patch.
///
/// Design 10-02 Step 3: the same switch calls also confirm an ACCEPTED
/// switch with the pending-semantics toast — the desktop applies the
/// switch lazily (it lands on the user's next message), so the sheet
/// close alone reads as "nothing happened".
///
/// [closeSheet] is the sheet choreography (pop + pending toast): true for
/// every config-sheet control; false for the Start-plan auto switch, which
/// runs on the page's context outside any sheet and reports with its own
/// toast (design 10-24 §4). The rejection SnackBar and the lost-ack patch
/// are identical either way. Returns whether the command was accepted or
/// optimistically applied (lost ack = pending), false on explicit
/// rejection or an unrelated failure.
Future<bool> _apply(
  BuildContext context,
  Future<dynamic> Function() run, {
  void Function()? onAccepted,
  void Function()? onTimeoutOptimistic,
  bool closeSheet = true,
}) async {
  try {
    final res = await run();
    if (context.mounted) {
      if (res is Map &&
          res['status'] != null &&
          res['status'] != 'accepted') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              trP(context, 'chat.sheet.rejected', [
                '${res['reasonCode'] ?? res['status']}',
              ]),
            ),
          ),
        );
        return false;
      }
      onAccepted?.call();
      if (closeSheet) Navigator.pop(context);
      if (onTimeoutOptimistic != null && closeSheet) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr(context, 'chat.sheet.switchPending'))),
        );
      }
      return true;
    }
  } catch (e) {
    debugPrint('[chat] sheet op: $e');
    if (onTimeoutOptimistic != null && context.mounted) {
      onTimeoutOptimistic();
      if (closeSheet) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr(context, 'chat.sheet.switchPending'))),
        );
      }
      return true;
    } else if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            trP(context, 'chat.op.failed', [
              commandErrorCopy('$e', localeOf(context)) ?? '$e',
            ]),
          ),
        ),
      );
    }
  }
  return false;
}

/// Context usage detail panel, restyled onto the desktop/remote entitlement
/// panel (PRD internal-task, pixel spec in
/// research/reference-panel-spec.md): capacity head, six-class legend,
/// cache hit rate, remaining quota block, and the bottom limit columns.
class _UsageSheet extends StatelessWidget {
  final ConversationState state;

  /// Entitlement snapshot taken when the sheet opened (R7) — the limit
  /// columns and the reset countdown read it; no polling inside the sheet.
  final EntitlementView? entitlement;
  final QuotaResetController controller;

  /// Opens the reset dialog with the pools this sheet found resettable.
  final void Function(Set<String>) onUseReset;

  const _UsageSheet({
    required this.state,
    required this.entitlement,
    required this.controller,
    required this.onUseReset,
  });

  @override
  Widget build(BuildContext context) {
    // Live refresh (acceptance 4): usage_update events notify the state
    // while the sheet is open, so read the numbers inside a listener.
    return SafeArea(
      child: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final contextUsage = state.contextUsage;
          return ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.85,
            ),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                    ZSpacing.screen, 4, ZSpacing.screen, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (contextUsage.hasData)
                      _contextSection(context, contextUsage),
                    if (contextUsage.breakdown.isNotEmpty)
                      _legend(context, contextUsage.breakdown),
                    if (contextUsage.hitRate != null)
                      _hitRateRow(context, contextUsage.hitRate!),
                    _remainingSection(context),
                    _limitsColumns(context),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// R1 — capacity head: label + used/max/pct on the right, gradient bar
  /// below (`bg-surface` track; orange above the >0.8 threshold).
  Widget _contextSection(BuildContext context, ContextUsageView view) {
    final ratio = view.ratio ?? 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(
                tr(context, 'chat.usage.context'),
                style: ZType.body.copyWith(color: ZInk.muted(context)),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              trP(context, 'chat.usage.contextValue', [
                compactTokens(context, view.used!),
                compactTokens(context, view.max!),
                _fmtPercent(ratio),
              ]),
              style: _usageNumber(context, ZType.body),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _UsageBar(
          value: ratio,
          height: 10,
          radius: 5,
          track: ZInk.barTrackSoft(context),
          orange: ratio > 0.8,
          gradient: true,
        ),
      ],
    );
  }

  /// R2 — six-class legend: dot (one blue at a stepped opacity), label,
  /// right-aligned share. No per-row bar and no chars (PRD R2).
  Widget _legend(
    BuildContext context,
    List<ContextUsageBreakdownItem> items,
  ) {
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        children: [
          for (final (i, item) in items.indexed)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 15),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: ZInk.usageBlue(context)
                          .withValues(alpha: _legendOpacity(i)),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      tr(context, _breakdownLabelKey(item.source)),
                      style: ZType.sub.copyWith(color: ZInk.muted(context)),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(_fmtPercent(item.percent),
                      style: _usageNumber(context, ZType.sub)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// R3 — average cache hit rate, one row without a dot.
  Widget _hitRateRow(BuildContext context, double hitRate) {
    return Padding(
      padding: const EdgeInsets.only(top: 26),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(
              tr(context, 'chat.contextUsage.cacheHitRate'),
              style: ZType.body.copyWith(color: ZInk.muted(context)),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(_fmtPercent(hitRate), style: _usageNumber(context, ZType.body)),
        ],
      ),
    );
  }

  /// R4 — remaining quota: the 5-hour pill carries its window expiry clock
  /// inline (「重置」stays reserved for reset opportunities, 2026-09-16);
  /// the reset-credit row is the app's entry point. Rows (and the whole
  /// block) hide when their data is absent; nothing renders as a placeholder.
  Widget _remainingSection(BuildContext context) {
    final view = entitlement;
    final limit = view?.limitFor('TOKENS_LIMIT', unit: 3, number: 5);
    // The panel shows what's LEFT of the window, not
    // what's used (bundle PF: clamp(100 - percentage)).
    final percent = view?.remainingPercent(limit);
    final windowClock = switch (limit?.nextResetTime) {
      null => null,
      final ms => EntitlementView.fmtResetClock(
          DateTime.fromMillisecondsSinceEpoch(ms),
        ),
    };
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final pools = controller.pools;
        // Projection: the pools the plan can actually reset (the
        // composition shared with the usage page). A pool the plan has no
        // window for (a V1 plan's weekly coupon) is never credited nor
        // offered by the dialog.
        final resettable = view?.resettablePools(pools) ?? const [];
        final credits = resettable.fold(0, (sum, r) => sum + r.pool.count);
        final earliestReset = switch (view?.earliestResetExpiry(pools)) {
          null => null,
          final at => EntitlementView.fmtResetClock(at),
        };
        final resettableTypes = {for (final r in resettable) r.type};
        if (percent == null && windowClock == null && credits == 0) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(top: 26),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr(context, 'chat.usage.remaining.title'),
                style: ZType.body.copyWith(
                  fontWeight: FontWeight.w600,
                  color: ZInk.solid(context),
                ),
              ),
              if (percent != null)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 3),
                        decoration: BoxDecoration(
                          color: ZInk.usageGreen(context)
                              .withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(ZRadius.field),
                        ),
                        child: Text(
                          tr(context, 'chat.usage.limit.fiveHour'),
                          style: ZType.caption.copyWith(
                            height: 1.2,
                            color: ZInk.usageGreen(context),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        trP(
                          context,
                          'chat.usage.remaining.left',
                          [_fmtPercentValue(percent)],
                        ),
                        style:
                            ZType.sub.copyWith(color: ZInk.muted(context)),
                      ),
                      if (windowClock != null) ...[
                        const SizedBox(width: 6),
                        Text(
                          windowClock,
                          style: ZType.caption.copyWith(
                              color: ZInk.faint(context)),
                        ),
                      ],
                    ],
                  ),
                ),
              if (credits > 0)
                Container(
                  margin: const EdgeInsets.only(top: 14),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: ZInk.hairline(context),
                    borderRadius: BorderRadius.circular(ZRadius.field),
                    border: Border.all(
                      color: ZInk.usageGreen(context)
                          .withValues(alpha: 0.35),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          earliestReset == null
                              ? trP(context, 'chat.usage.resetCredits',
                                  ['$credits'])
                              : trP(context, 'chat.usage.resetCreditsExpiry',
                                  ['$credits', earliestReset]),
                          style: ZType.sub.copyWith(color: ZInk.muted(context)),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () => onUseReset(resettableTypes),
                        style: TextButton.styleFrom(
                          backgroundColor: ZInk.usageGreen(context)
                              .withValues(alpha: 0.15),
                          foregroundColor: ZInk.usageGreen(context),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 5),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          textStyle: ZType.sub,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(ZRadius.field),
                          ),
                        ),
                        child: Text(tr(context, 'chat.quota.useReset')),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// R5 — three equal-width limit columns, all in remaining
  /// semantics (bundle `PF`: `clamp(100 - percentage)`). 工具调用 is the
  /// monthly built-in tool quota (entitlementMonthlyMcpUsage), ZCode MCP
  /// the server-side aggregate (entitlementServerMcpUsage); a limit absent
  /// from the snapshot drops its column.
  Widget _limitsColumns(BuildContext context) {
    final view = entitlement;
    final fiveHour = view?.remainingPercent(
      view.limitFor('TOKENS_LIMIT', unit: 3, number: 5),
    );
    final toolCalls = view?.remainingPercent(
      view.limitFor('TIME_LIMIT', unit: 5, number: 1),
    );
    final zcodeMcp = view?.remainingPercent(view.serverMcpLimit);
    final columns = <Widget>[
      if (fiveHour != null)
        _limitColumn(
            context, tr(context, 'chat.usage.limit.fiveHour'), fiveHour),
      if (toolCalls != null)
        _limitColumn(
            context, tr(context, 'chat.usage.limit.toolCalls'), toolCalls),
      if (zcodeMcp != null)
        _limitColumn(
            context, tr(context, 'chat.usage.limit.zcodeMcp'), zcodeMcp,
            orange: true),
    ];
    if (columns.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 28),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (i, column) in columns.indexed) ...[
            if (i > 0) const SizedBox(width: 14),
            Expanded(child: column),
          ],
        ],
      ),
    );
  }

  /// One limit column: title → remaining percentage → mini bar. The fill
  /// color is a fixed per-column tone (the chart scale), not a
  /// usage threshold.
  Widget _limitColumn(
    BuildContext context,
    String name,
    double percent, {
    bool orange = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          name,
          style: ZType.sub.copyWith(color: ZInk.muted(context)),
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 5),
        Text(
          _fmtPercentValue(percent),
          style: _usageNumber(context, ZType.bodyStrong),
        ),
        const SizedBox(height: 7),
        _UsageBar(
          value: percent / 100,
          height: 5,
          radius: 3,
          track: ZInk.barTrack(context),
          orange: orange,
        ),
      ],
    );
  }
}

/// Reference-panel tone without a ZColors token: the gradient's deep stop
/// (#4185D5 pixel spec ≈ the color-mix step; same value in both
/// modes, design.md §3b). The old #353535 track moved into
/// [ZInk.barTrackSoft].
const _usageBlueDeep = Color(0xFF4185D5);

/// Rounded track + fill bar of the usage panel. The capacity bar carries
/// the reference's blue gradient, the mini limit bars a flat fill; an
/// orange fill replaces both at their high-usage thresholds.
class _UsageBar extends StatelessWidget {
  final double value;
  final double height;
  final double radius;
  final Color track;
  final bool orange;
  final bool gradient;

  const _UsageBar({
    required this.value,
    required this.height,
    required this.radius,
    required this.track,
    this.orange = false,
    this.gradient = false,
  });

  @override
  Widget build(BuildContext context) {
    final fill = orange ? ZInk.usageOrange(context) : ZInk.usageBlue(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        return Container(
          height: height,
          decoration: BoxDecoration(
            color: track,
            borderRadius: BorderRadius.circular(radius),
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Container(
              width: constraints.maxWidth * value.clamp(0.0, 1.0),
              decoration: BoxDecoration(
                color: gradient && !orange ? null : fill,
                gradient: gradient && !orange
                    ? LinearGradient(
                        colors: [ZInk.usageBlue(context), _usageBlueDeep],
                      )
                    : null,
                borderRadius: BorderRadius.circular(radius),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Legend dot opacity ladder by row index (measured on the reference:
/// 1.0/.82/.64/.5/.42/.38). Extra rows beyond the ladder reuse its last
/// step — the projection can rank more than six sources.
double _legendOpacity(int index) {
  const ladder = [1.0, 0.82, 0.64, 0.5, 0.42, 0.38];
  return ladder[index < ladder.length ? index : ladder.length - 1];
}

/// Tabular-figure value style of the panel (percentages and token counts
/// line up column-wise (tabular-nums). [base] picks
/// the tier — the panel uses [ZType.body], [ZType.sub] and [ZType.bodyStrong].
TextStyle _usageNumber(BuildContext context, TextStyle base) {
  return base.copyWith(
    color: ZInk.solid(context),
    fontFeatures: const [FontFeature.tabularFigures()],
  );
}

/// Mapping: breakdown source → i18n key. Unknown sources
/// render their raw id.
String _breakdownLabelKey(String source) => switch (source) {
  'messages' => 'chat.contextUsage.breakdown.messages',
  'system_prompt' => 'chat.contextUsage.breakdown.systemPrompt',
  'meta_user_context' => 'chat.contextUsage.breakdown.metaUserContext',
  'skills' => 'chat.contextUsage.breakdown.skills',
  'tool_prompt' => 'chat.contextUsage.breakdown.toolPrompt',
  'system_tool_schemas' => 'chat.contextUsage.breakdown.systemTools',
  'mcp_tool_schemas' => 'chat.contextUsage.breakdown.mcpTools',
  _ => source,
};

/// Percent with at most one decimal (maximumFractionDigits: 1).
String _fmtPercent(double ratio) => _fmtPercentValue(ratio * 100);

/// Same formatting for an already-percent value (entitlement percentages
/// arrive as 0..100).
String _fmtPercentValue(double percent) => percent == percent.roundToDouble()
    ? '${percent.round()}%'
    : '${percent.toStringAsFixed(1)}%';

/// ---------------------------------------------------------------- input

/// One entry in the slash popup: a builtin/custom command or a skill.
/// Type moved to [SlashItem] (slash_items.dart) — shared with the
/// task-search actions tab.
class _SlashCommandBar extends StatelessWidget {
  final String query;
  final List<SlashItem> items;
  final void Function(SlashItem item) onSelect;

  const _SlashCommandBar({
    required this.query,
    required this.items,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final q = query.startsWith('/') || query.startsWith('\$')
        ? query.substring(1)
        : query;
    final filtered = q.isEmpty
        ? items
        : items
              .where((c) => c.name.toLowerCase().startsWith(q.toLowerCase()))
              .toList();
    if (filtered.isEmpty) {
      return Container(
        margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: ZInk.card(context),
          borderRadius: BorderRadius.circular(ZRadius.tile),
        ),
        child: Text(
          tr(context, 'chat.slash.empty'),
          style: ZType.sub.copyWith(color: ZInk.faint(context)),
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      constraints: const BoxConstraints(maxHeight: 260),
      decoration: BoxDecoration(
        color: ZInk.card(context),
        borderRadius: BorderRadius.circular(ZRadius.tile),
        border: Border.all(color: ZInk.hairline(context)),
      ),
      // Material closest to the tiles so their ink splashes paint (the
      // decorated Container above would otherwise hide them — debug assert).
      child: Material(
        type: MaterialType.transparency,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final command in filtered)
              ListTile(
                dense: true,
                leading: Icon(
                  command.isSubagent
                      ? Icons.smart_toy_outlined
                      : command.isSkill
                          ? ZSymbols.extension
                          : ZSymbols.terminal,
                  size: 16,
                  color: ZInk.iconNeutral(context),
                ),
                title: Text(
                  command.isSubagent
                      ? '@${command.name}'
                      : command.isSkill
                          ? '\$${command.name}'
                          : '/${command.name}',
                  style: ZType.body.copyWith(fontFamily: 'monospace'),
                ),
                subtitle: Text(
                  command.description,
                  style: ZType.caption.copyWith(color: ZInk.faint(context)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => onSelect(command),
              ),
          ],
        ),
      ),
    );
  }
}

class _SkillsPickerSheet extends StatelessWidget {
  final List<SkillEntry> skills;
  final bool loading;
  final void Function(SkillEntry skill) onSelect;
  final Future<void> Function() onRefresh;

  const _SkillsPickerSheet({
    required this.skills,
    required this.loading,
    required this.onSelect,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final list = skills.where((s) => s.enabled).toList();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            ZSpacing.screen, 4, ZSpacing.screen, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  tr(context, 'chat.skills.title'),
                  style: ZType.heading,
                ),
                const Spacer(),
                IconButton(
                  icon: Icon(
                    Icons.refresh,
                    size: 18,
                    color: ZInk.muted(context),
                  ),
                  tooltip: tr(context, 'tasks.retry'),
                  onPressed: onRefresh,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (loading)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else if (list.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  tr(context, 'chat.skills.empty'),
                  style: ZType.body.copyWith(color: ZInk.muted(context)),
                ),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final s in list)
                      ListTile(
                        dense: true,
                        leading: Icon(
                          Icons.auto_awesome_outlined,
                          size: 18,
                          color: ZInk.warningTone(context),
                        ),
                        title: Text(
                          '\$${s.name}',
                          style: ZType.body.copyWith(
                            fontFamily: 'monospace',
                          ),
                        ),
                        subtitle: s.description != null
                            ? Text(
                                s.description!,
                                style: ZType.sub.copyWith(
                                  color: ZInk.faint(context),
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              )
                            : null,
                        onTap: () => onSelect(s),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Composer: rounded container with the text field on top and a
/// control row underneath — left: add-context / mode chip; right: usage
/// ring, model chip, thought chip, send/stop button.
///
/// Stateful: listens to the text controller so the send button's
/// empty-input disabled state updates on every keystroke
/// without rebuilding the whole page.
class _InputBar extends StatefulWidget {
  final TextEditingController controller;
  final bool sending;

  /// Pending attachments count as input for the send button's enabled
  /// state (text is tracked internally via the controller).
  final bool hasAttachments;
  final bool isDraft;
  final ConversationState? state;
  final WorkspacePrep? prep;
  final Map<String, String>? draftConfig;
  final ConversationPort conversation;
  final SessionTruthPort sessionTruth;
  final String? sessionId;

  /// Shared child-session pool backing the subagent pill's terminal
  /// hysteresis view (null in draft mode → no pill).
  final SubagentFeed? feed;

  /// Terminal destroy-confirm window for the subagent pill (same anti-replay
  /// window as the turn footer).
  final Duration subagentConfirmWindow;

  final VoidCallback onSend;

  /// Opens the add-context panel (official ＋ / `chat.composer.actionMenu`);
  /// 附件/目标/工作流/文件/会话/插件 sections live there (design D4).
  final VoidCallback onAddMenu;
  final VoidCallback onModelSheet;
  final VoidCallback onUsage;

  /// Opens the background-task management sheet (wired only with a live
  /// session).
  final VoidCallback? onBackgroundWorks;

  const _InputBar({
    required this.controller,
    required this.sending,
    required this.hasAttachments,
    required this.isDraft,
    required this.state,
    required this.prep,
    required this.draftConfig,
    required this.conversation,
    required this.sessionTruth,
    required this.sessionId,
    required this.feed,
    required this.subagentConfirmWindow,
    required this.onSend,
    required this.onAddMenu,
    required this.onModelSheet,
    required this.onUsage,
    this.onBackgroundWorks,
  });

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onText);
    _inputFocus = FocusNode()..addListener(_onFocus);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onText);
    _inputFocus.removeListener(_onFocus);
    _inputFocus.dispose();
    super.dispose();
  }

  void _onText() {
    if (mounted) setState(() {});
  }

  /// Short-viewport toggle: the tool row starts collapsed (landscape phones
  /// / folding half-open) and the expand button reveals it temporarily.
  bool _toolsExpanded = false;

  /// Landscape density (mock 方案 B): focusing the input reveals the tool
  /// chips, blur/send takes them back; the ⇅ toggle stays as the manual
  /// entry. Portrait never consults [_toolsExpanded] (toolsVisible is
  /// unconditionally true there), so the listener is inert on tall
  /// viewports.
  late final FocusNode _inputFocus;

  /// Mirrors the last build's short-viewport verdict — the focus listener
  /// must not register a MediaQuery dependency (IME frame cost, spec §8.2).
  bool _shortViewport = false;

  void _onFocus() {
    if (!mounted || !_shortViewport) return;
    setState(() => _toolsExpanded = _inputFocus.hasFocus);
  }

  /// Send-side half of the landscape contract: a send reclaims the tool
  /// row so the post-send transcript keeps the room.
  void _sendAndCollapse() {
    if (_shortViewport && _toolsExpanded) {
      setState(() => _toolsExpanded = false);
    }
    onSend();
  }

  bool get _hasInput =>
      widget.controller.text.trim().isNotEmpty || widget.hasAttachments;

  /// Cross-terminal deletion tombstone (10-06): the sessions-index dropped
  /// this session — the send button greys out (the page keeps the messages
  /// read-only).
  bool get _sessionDeleted {
    final sid = sessionId;
    return sid != null && sessionTruth.isSessionDeleted(sid);
  }

  /// Authoritative subscribe refusal (10-11): the subscribe channel
  /// answered sessionNotFound for this session — same greyed-send form as
  /// [_sessionDeleted], epistemically authoritative (see
  /// _ChatPageState._sessionMissing).
  bool get _sessionMissing {
    final sid = sessionId;
    return sid != null && sessionTruth.isSessionMissing(sid);
  }

  // Field forwarders so the build/helpers below read like the original
  // stateless widget.
  TextEditingController get controller => widget.controller;
  bool get sending => widget.sending;
  bool get isDraft => widget.isDraft;
  ConversationState? get state => widget.state;
  SubagentFeed? get feed => widget.feed;
  ConversationPort get conversation => widget.conversation;
  SessionTruthPort get sessionTruth => widget.sessionTruth;
  WorkspacePrep? get prep => widget.prep;
  Map<String, String>? get draftConfig => widget.draftConfig;
  String? get sessionId => widget.sessionId;
  VoidCallback get onSend => widget.onSend;
  VoidCallback get onAddMenu => widget.onAddMenu;
  VoidCallback get onModelSheet => widget.onModelSheet;
  VoidCallback get onUsage => widget.onUsage;
  VoidCallback? get onBackgroundWorks => widget.onBackgroundWorks;

  String get _modeValue => isDraft
      ? (draftConfig?['mode'] ?? 'build')
      : (state?.currentMode ?? 'build');

  /// Shared with the subagent detail page's subtitle ([modelLabelOf]):
  /// draft values are `provider/model` composites and get split first
  /// (the first slash, conditional — a bare model id carries no provider;
  /// the model half may keep its own slashes); live sessions keep the
  /// config's bare model + provider pair.
  String get _modelLabel {
    if (isDraft) {
      final picked = draftConfig?['model'] ?? '';
      final value = picked.isNotEmpty
          ? picked
          : '${prep?.option('model')?.currentValue ?? ''}';
      if (value.isEmpty) return '';
      // Conditional split, unlike [_splitModelValue] (which echoes a
      // slash-less value as both provider and model). First slash: the
      // model segment may itself contain '/' (deepseek/deepseek-v4.1-flash).
      final idx = value.indexOf('/');
      return idx > 0
          ? modelLabelOf(value.substring(idx + 1), value.substring(0, idx))
          : modelLabelOf(value, '');
    }
    return modelLabelOf(
      state?.currentModel ?? '',
      '${state?.config?['provider'] ?? ''}',
    );
  }

  String get _thoughtLabel {
    final raw = isDraft
        ? (draftConfig?['thought'] ??
              '${prep?.option('thought_level')?.currentValue ?? ''}')
        : (state?.currentThought ?? '');
    if (raw.isEmpty) return '';
    // Friendly option name (低/高/最高) when prep knows the value.
    for (final o
        in prep?.option('thought_level')?.options ??
            const <ConfigOptionValue>[]) {
      if (o.value == raw) return o.name;
    }
    return raw;
  }

  double? get _usageRatio => state?.contextUsage.ratio;

  /// Visibility keys off option availability, not the current value (PRD
  /// 09-19): a session created with an empty default model config still
  /// gets the pickers. Drafts keep the value-driven visibility (unchanged).
  bool get _modelPickerVisible {
    if (isDraft) return _modelLabel.isNotEmpty;
    final option = prep?.option('model');
    return option != null && option.options.isNotEmpty;
  }

  bool get _thoughtPickerVisible {
    if (isDraft) return _thoughtLabel.isNotEmpty;
    final option = prep?.option('thought_level');
    // thoughtLevels is the server's own copy of the thought choices inside
    // the config snapshot — keep the chip when prep missed the option but
    // the config carries levels, so a normal session never loses it
    // (visual-zero-change constraint).
    return (option != null && option.options.isNotEmpty) ||
        (state?.thoughtLevels.isNotEmpty ?? false);
  }

  List<String> get _thoughtChoices {
    final fromPrep =
        prep?.option('thought_level')?.options.map((o) => o.value).toList() ??
        const <String>[];
    return fromPrep.isNotEmpty ? fromPrep : (state?.thoughtLevels ?? const []);
  }

  @override
  Widget build(BuildContext context) {
    // Official stop/send swap (bundle @~1423479, `cn = en && !nn`): the
    // right slot is the stop button only while the composer is empty and
    // the desktop reports canStop (pre-3.15: falls back to isRunning);
    // with input the send button owns the slot.
    final showStop = !_hasInput && (state?.effectiveCanStop ?? false);
    // The hint swaps once messages are queued, so typing more
    // keeps appending to the queue instead of looking like a fresh message.
    final queued = state?.queueItems.isNotEmpty ?? false;
    // Composer: icon-only buttons below sm (640), icon+label above.
    final wide = MediaQuery.sizeOf(context).width >= 640;
    // Short viewport (landscape phones, folding half-open; portrait phones
    // are ~844 tall and never trigger): collapse the tool row into an
    // expand toggle so the input line keeps the scarce vertical room.
    final short = MediaQuery.heightOf(context) < 480;
    // Rotating portrait → landscape mid-typing: the input keeps its focus
    // across the turn, but the focus listener only fires on focus *events*
    // — adopt the focused state as the short-viewport verdict flips so the
    // chips match the (still-focused) input.
    if (short && !_shortViewport && _inputFocus.hasFocus) {
      _toolsExpanded = true;
    }
    _shortViewport = short;
    final toolsVisible = !short || _toolsExpanded;
    // Horizontal insets are consumed once by the body-level SafeArea above
    // (aligned message flow and composer); this one only keeps its bottom
    // gesture-bar duty.
    return SafeArea(
      left: false,
      right: false,
      top: false,
      child: Padding(
        // Short viewports: tighten the composer's vertical paddings (with
        // the input's contentPadding below, part of the landscape density
        // budget that keeps the message area usable).
        padding: short
            ? const EdgeInsets.fromLTRB(12, 2, 12, 5)
            : const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Container(
          padding: short
              ? const EdgeInsets.fromLTRB(6, 2, 6, 2)
              : const EdgeInsets.fromLTRB(6, 6, 6, 6),
          decoration: BoxDecoration(
            color: ZInk.card(context),
            borderRadius: BorderRadius.circular(ZRadius.tile),
            border: Border.all(color: ZInk.hairline(context)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                focusNode: _inputFocus,
                minLines: 1,
                maxLines: 6,
                style: ZType.body.copyWith(color: ZInk.solid(context)),
                decoration: InputDecoration(
                  hintText: tr(
                    context,
                    queued ? 'chat.input.hint.queued' : 'chat.input.hint',
                  ),
                  hintStyle: TextStyle(color: ZInk.ghost(context)),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: short ? 3 : 8,
                  ),
                  // Short viewports: the tools toggle AND the send cluster
                  // share the input line (true single-row composer); tool
                  // chips drop to a second line only while expanded.
                  suffixIcon: short
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Icon(
                                _toolsExpanded
                                    ? Icons.unfold_less
                                    : Icons.unfold_more,
                                size: 20,
                                color: ZInk.muted(context),
                              ),
                              tooltip: tr(
                                context,
                                _toolsExpanded
                                    ? 'chat.input.toolsCollapse'
                                    : 'chat.input.toolsExpand',
                              ),
                              onPressed: () => setState(
                                () => _toolsExpanded = !_toolsExpanded,
                              ),
                            ),
                            // Same swap as the wide row below: stop owns
                            // the slot on an empty composer, send takes
                            // it back once there is input.
                            if (showStop)
                              _StopButton(onStop: () => _stop(context))
                            else
                              _SendButton(
                                enabled: _hasInput &&
                                    !sending &&
                                    !_sessionDeleted &&
                                    !_sessionMissing,
                                sending: sending,
                                onSend: _sendAndCollapse,
                              ),
                          ],
                        )
                      : null,
                ),
                textInputAction: TextInputAction.newline,
              ),
              // Short viewports: compact visual density for the whole tool
              // row (48dp icon buttons shrink ~8dp) — one Theme override
              // instead of per-button tweaks.
              Theme(
                data: short
                    ? Theme.of(context)
                        .copyWith(visualDensity: VisualDensity.compact)
                    : Theme.of(context),
                child: Row(
                children: [
                  // Short viewports keep the tools collapsed (toggle moved
                  // into the TextField suffixIcon), so the whole left cluster
                  // is gated on visibility; the send cluster stays put.
                  if (toolsVisible) ...[
                    // Same 40dp layout width in both viewport modes
                    // (short mode's compact Theme below would do it
                    // anyway): keeps the left cluster's visual rhythm at
                    // 16dp, matching the send/stop side.
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        Icons.add_circle_outline,
                        size: 20,
                        color: ZInk.muted(context),
                      ),
                      tooltip: tr(context, 'chat.composer.actionMenu'),
                      onPressed: sending ? null : onAddMenu,
                    ),
                    _ControlChip(
                      label: tr(context, 'chat.mode.$_modeValue'),
                      icon: Icons.tune,
                      onTap: () => _pickMode(context),
                      showLabel: wide,
                    ),
                    // Background-task entry (single composer button, three
                    // kinds). Sits right of the mode chip; its appearance
                    // never shifts the other controls (Spacer keeps the
                    // right cluster in place).
                    if (state != null && feed != null &&
                        onBackgroundWorks != null)
                      _BackgroundTasksPill(
                        state: state!,
                        feed: feed!,
                        confirmWindow: widget.subagentConfirmWindow,
                        onTap: onBackgroundWorks!,
                      ),
                  ],
                  if (toolsVisible) const Spacer(),
                  if (toolsVisible && _usageRatio != null)
                    _UsageRing(ratio: _usageRatio!, onTap: onUsage),
                  if (toolsVisible && _modelPickerVisible)
                    ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: _kControlChipMaxWidth,
                      ),
                      child: _ControlChip(
                        label: _modelLabel.isEmpty
                            ? tr(context, 'chat.composer.modelPlaceholder')
                            : _modelLabel,
                        icon: Icons.memory_outlined,
                        onTap: onModelSheet,
                        showLabel: wide,
                      ),
                    ),
                  if (toolsVisible && _thoughtPickerVisible)
                    ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: _kControlChipMaxWidth,
                      ),
                      child: _ControlChip(
                        label: _thoughtLabel.isEmpty
                            ? tr(context, 'chat.composer.thoughtPlaceholder')
                            : _thoughtLabel,
                        icon: Icons.psychology_alt_outlined,
                        onTap: () => _pickThought(context),
                        showLabel: wide,
                      ),
                    ),
                  // The composer stays sendable while a turn
                  // runs — follow-ups queue mid-turn — with the official
                  // swap at the right edge: an empty composer shows stop
                  // (canStop), input shows send (bundle @~1423479; no
                  // side-by-side pair). Kicked never reaches this button:
                  // the full-screen takeover overlay already blocks all
                  // input (single button instance — the collapsed/expanded
                  // landscape states share this row). A cross-terminal
                  // deletion tombstone (10-06) greys the button instead.
                  if (!short)
                    showStop
                        ? _StopButton(onStop: () => _stop(context))
                        : _SendButton(
                            enabled: _hasInput &&
                                !sending &&
                                !_sessionDeleted &&
                                !_sessionMissing,
                            sending: sending,
                            onSend: _sendAndCollapse,
                          ),
                ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickMode(BuildContext context) async {
    final sid = sessionId;
    final value = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(tr(context, 'chat.sheet.mode')),
        children: [
          RadioGroup<String>(
            groupValue: _modeValue,
            onChanged: (v) =>
                Navigator.pop(context, v ?? _modeValue),
            child: Column(
              children: [
                for (final m in const ['build', 'edit', 'plan', 'yolo'])
                  RadioListTile<String>(
                    dense: true,
                    value: m,
                    title: Text(tr(context, 'chat.mode.$m')),
                    subtitle: Text(tr(context, 'chat.mode.$m.desc')),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (value == null || value == _modeValue) return;
    if (isDraft || sid == null) return; // draft chips go through the sheet
    conversation.conversationCommands.switchCollaborationMode(sid, value);
  }

  Future<void> _pickThought(BuildContext context) async {
    final sid = sessionId;
    final choices = _thoughtChoices;
    if (choices.isEmpty) {
      onModelSheet();
      return;
    }
    final value = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(tr(context, 'chat.sheet.thought')),
        children: [
          RadioGroup<String>(
            groupValue: _thoughtLabel,
            onChanged: (v) =>
                Navigator.pop(context, v ?? _thoughtLabel),
            child: Column(
              children: [
                for (final t in choices)
                  RadioListTile<String>(
                    dense: true,
                    value: t,
                    title: Text(t),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (value == null || value == _thoughtLabel) return;
    if (isDraft || sid == null) return; // draft chips go through the sheet
    // Pass the config's bare values straight through (the desktop's
    // switchModelConfig wants provider+model, not a composite string — the
    // old join-then-split round trip re-broke model ids containing '/').
    // Config not landed yet → nothing legal to switch; send nothing.
    final provider = '${state?.config?['provider'] ?? ''}';
    final model = '${state?.config?['model'] ?? ''}';
    if (provider.isEmpty || model.isEmpty) return;
    conversation.conversationCommands.switchModelConfig(
      sid,
      provider: provider,
      model: model,
      thought: value,
    );
  }

  void _stop(BuildContext context) {
    final sid = sessionId;
    if (sid == null) return;
    final st = state;
    // Re-entrancy guard (official web has no stopping UI, research A-2):
    // taps while the wire reports `stopping` or the local optimistic
    // projection is still un-calibrated send nothing.
    if (st != null && (st.stopProjected || st.stopState == 'stopping')) {
      return;
    }
    // Optimistic projection (official click behavior, bundle @~1427647):
    // hide the stop button immediately; the next authoritative control
    // frame recalibrates (canStop back to true restores it).
    st?.optimisticStop();
    conversation.conversationCommands.stop(sid);
  }
}

/// Label-chip width cap (R5, 10-10): server-controlled labels (model /
/// thought option names) are ellipsized past this so the label-mode (≥640)
/// tool row closes its worst-case budget — fixed clusters (~287dp) + two
/// capped chips + the bounded pill stay under the 604dp row at 640. The
/// chips stay rigid in the row (no Flexible shares): loose flex shares
/// leave unused share as trailing space after the stop button, detaching
/// the right cluster from the row edge even when nothing overflows.
const double _kControlChipMaxWidth = 150;

class _ControlChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  /// Mobile: below the sm breakpoint the composer controls
  /// are icon-only 28×28 buttons; labels appear on wider layouts.
  final bool showLabel;

  const _ControlChip({
    required this.label,
    required this.icon,
    required this.onTap,
    this.showLabel = true,
  });

  @override
  Widget build(BuildContext context) {
    if (!showLabel) {
      return InkWell(
        borderRadius: BorderRadius.circular(ZRadius.tile),
        onTap: onTap,
        child: SizedBox(
          width: 28,
          height: 28,
          child: Icon(icon, size: 16, color: ZInk.muted(context)),
        ),
      );
    }
    return InkWell(
      borderRadius: BorderRadius.circular(ZRadius.tile),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: ZInk.tile(context),
          borderRadius: BorderRadius.circular(ZRadius.tile),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: ZInk.muted(context)),
            const SizedBox(width: 4),
            // Loose so the built-in ellipsis engages whenever a caller caps
            // the chip (_kControlChipMaxWidth); inert at intrinsic width.
            Flexible(
              fit: FlexFit.loose,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ZType.caption.copyWith(color: ZInk.soft(context)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Single composer entry for running background tasks (bash + workflow +
/// subagents). Shows the count of all three kinds (tabular-nums) + a
/// breathing dot on a faint brand wash; the tooltip and the Semantics
/// label are the official three-category wording (renderer @314278500,
/// i18n @297628008/@298039652).
///
/// Visibility: total running count 0 → hidden, but once everything went
/// terminal the pill must hold that state for [confirmWindow] before it is
/// destroyed (the same anti-replay window as the turn footer). The
/// SubagentFeed's regression hysteresis absorbs replayed running subagent
/// reports against a terminal, so this window guards genuine empty↔non-empty
/// flips only.
class _BackgroundTasksPill extends StatefulWidget {
  final ConversationState state;
  final SubagentFeed feed;
  final Duration confirmWindow;
  final VoidCallback onTap;

  const _BackgroundTasksPill({
    required this.state,
    required this.feed,
    required this.confirmWindow,
    required this.onTap,
  });

  @override
  State<_BackgroundTasksPill> createState() => _BackgroundTasksPillState();
}

class _BackgroundTasksPillState extends State<_BackgroundTasksPill> {
  bool _visible = false;

  /// Fires at the end of the destroy-confirm window to re-render (an
  /// external notify usually won't arrive once everything is terminal);
  /// the still-empty re-check lives in the callback.
  late final ConfirmGate _destroyGate = ConfirmGate(
    window: widget.confirmWindow,
    onConfirmed: () {
      if (!mounted) return;
      if (_currentTotal == 0) setState(() => _visible = false);
    },
  );

  int get _currentTotal => _runningWorkTotal(
    _runningWorkCounts(
      widget.state,
      subagentsRunningView(widget.state, widget.feed),
    ),
  );

  @override
  void dispose() {
    _destroyGate.dispose();
    super.dispose();
  }

  /// Derived inside the AnimatedBuilder (its notifications are what drive
  /// rebuilds); plain field writes only — observe is strictly idempotent
  /// (same argument, zero behavior), the gate's own completion calls
  /// setState.
  void _reconcile(int total) {
    if (total > 0) {
      _destroyGate.observe(false);
      _visible = true;
      return;
    }
    // `_visible` starts false: the initial empty view must not arm the
    // destroy window (same as the old `if (!_visible) return`).
    if (_visible) _destroyGate.observe(true);
  }

  /// Official tooltip pick: more than one non-empty kind → mixed; else the
  /// single present kind (ariaLabel is the Semantics label separately).
  String _tooltip(
    BuildContext context,
    ({int bash, int workflow, int subagent}) counts,
  ) {
    final kinds = [
      counts.bash > 0,
      counts.workflow > 0,
      counts.subagent > 0,
    ].where((present) => present).length;
    if (kinds > 1) return tr(context, 'chat.bgSheet.tooltipMixed');
    if (counts.bash > 0) return tr(context, 'chat.bgSheet.tooltipTerminal');
    if (counts.workflow > 0) {
      return tr(context, 'chat.bgSheet.tooltipWorkflow');
    }
    return tr(context, 'chat.bgSheet.tooltipAgent');
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([widget.state, widget.feed]),
      builder: (context, _) {
        final running = subagentsRunningView(widget.state, widget.feed);
        final counts = _runningWorkCounts(widget.state, running);
        final total = _runningWorkTotal(counts);
        _reconcile(total);
        if (!_visible) return const SizedBox.shrink();
        final aria = trP(context, 'chat.bgSheet.aria', [
          '${counts.bash}',
          '${counts.workflow}',
          '${counts.subagent}',
          '$total',
        ]);
        return Tooltip(
          message: _tooltip(context, counts),
          child: Semantics(
            label: aria,
            button: true,
            child: InkWell(
              onTap: widget.onTap,
              borderRadius: BorderRadius.circular(ZRadius.field),
              child: Container(
                height: 30,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: ZColors.sky400.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(ZRadius.field),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.smart_toy_outlined,
                      size: 14,
                      color: ZColors.sky400,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '$total',
                      style: ZType.sub.copyWith(
                        color: ZInk.soft(context),
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 4),
                    const _BreathingDot(),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The pill's pulsing brand dot (mock: 5px, 1.2s ease-in-out, 50% @ .25).
class _BreathingDot extends StatefulWidget {
  const _BreathingDot();

  @override
  State<_BreathingDot> createState() => _BreathingDotState();
}

class _BreathingDotState extends State<_BreathingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  )..repeat(reverse: true);

  late final Animation<double> _opacity = Tween(
    begin: 1.0,
    end: 0.25,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: Container(
        width: 5,
        height: 5,
        decoration: const BoxDecoration(
          color: ZColors.sky400,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// Circular context-usage indicator (环形用量).
class _UsageRing extends StatelessWidget {
  final double ratio;
  final VoidCallback onTap;

  const _UsageRing({required this.ratio, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = ratio > 0.8 ? ZColors.warning : ZColors.sky500;
    return IconButton(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.all(6),
      constraints: const BoxConstraints(),
      tooltip: tr(context, 'chat.more.usage'),
      onPressed: onTap,
      icon: SizedBox(
        width: 18,
        height: 18,
        child: CustomPaint(
          painter: _RingPainter(ratio: ratio, color: color),
          child: Center(
            child: Text(
              '${(ratio * 100).round()}',
              // Deliberate off-scale size: the label has to fit the digits
              // inside an 18px ring; ZType.caption would overflow it.
              style: TextStyle(
                fontSize: 6.5,
                fontWeight: FontWeight.w600,
                fontFamily: zFontFamily,
                fontFamilyFallback: zFontFallback,
                color: color,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double ratio;
  final Color color;

  _RingPainter({required this.ratio, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.14;
    final rect = Offset.zero & size;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    // background ring
    canvas.drawArc(
      rect.deflate(stroke / 2),
      0,
      2 * 3.1415926,
      false,
      paint..color = color.withValues(alpha: 0.2),
    );
    // value arc
    canvas.drawArc(
      rect.deflate(stroke / 2),
      -3.1415926 / 2,
      2 * 3.1415926 * ratio,
      false,
      paint..color = color,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.ratio != ratio || old.color != color;
}

class _SendButton extends StatelessWidget {
  final bool enabled;
  final bool sending;
  final VoidCallback onSend;

  const _SendButton({
    required this.enabled,
    required this.sending,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    // ~30px squircle (ZRadius.mini) with the arrow glyph.
    // The InkWell spans 48px so the touch target stays ≥48.
    return SizedBox(
      width: 48,
      height: 48,
      child: InkWell(
        borderRadius: BorderRadius.circular(ZRadius.mini),
        onTap: enabled ? onSend : null,
        child: Center(
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color:
                  enabled ? ZColors.sky500 : ZColors.sky500.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(ZRadius.mini),
            ),
            child: Center(
              child: sending
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Icon(
                      Icons.arrow_upward,
                      size: 18,
                      color: enabled
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.7),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StopButton extends StatelessWidget {
  final VoidCallback onStop;

  const _StopButton({required this.onStop});

  @override
  Widget build(BuildContext context) {
    // Same squircle as the send button (they swap in place).
    return SizedBox(
      width: 48,
      height: 48,
      child: Tooltip(
        message: tr(context, 'tasks.stop'),
        child: InkWell(
          borderRadius: BorderRadius.circular(ZRadius.mini),
          onTap: onStop,
          child: Center(
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: ZColors.danger.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(ZRadius.mini),
              ),
              child: Center(
                child: Icon(Icons.stop, color: ZInk.dangerTone(context), size: 20),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
