import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show RenderRepaintBoundary, ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../protocol/conversation.dart';
import '../../state/device_session.dart';
import '../../state/entitlement_poller.dart';
import '../../state/new_task_defaults.dart';
import '../../state/quota_reset.dart';
import '../phase_pill.dart';
import '../quota_reset_dialog.dart';
import '../theme.dart';
import '../ui_settings.dart';
import '../widgets/sheet_scaffold.dart';
import 'diff_view.dart';
import 'file_preview_page.dart';
import 'history_pager.dart';
import 'image_viewer_page.dart';
import 'markdown_view.dart';
import 'goal_panel.dart';
import 'jump_to_bottom_button.dart';
import 'mention_sheet.dart';
import 'subagent_detail_page.dart';
import 'subagent_feed.dart';
import 'tool_row_semantics.dart';
import 'top_bounce_physics.dart';

/// Native chat view for one task (session), backed by Conversation V4 over
/// [ChatGateway]. Draft mode (no [sessionId]): the first message issues
/// `createSession` with the draft model/mode/thought config.
class ChatPage extends StatefulWidget {
  final ChatGateway gateway;
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

  /// Pinned state of the opened task (from the list entry) so the 更多 menu
  /// can show 置顶任务 / 取消置顶任务 like the web and toggle it.
  final bool initialPinned;

  /// Opens the plan-usage page (quota warning banner / pill action). Left
  /// null where no usage route exists; the banner then shows the model
  /// switch only.
  final VoidCallback? onOpenUsage;

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
    required this.gateway,
    this.sessionId,
    required this.title,
    this.theme,
    this.embedded = false,
    this.initialComposerText,
    this.workspaceLabel,
    this.initialPinned = false,
    this.onOpenUsage,
    this.turnFooterConfirmWindow = const Duration(seconds: 3),
    this.subagentHysteresis = const Duration(seconds: 15),
  });

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _PendingFile {
  final String fileName;
  final String mime;
  final Uint8List bytes;

  _PendingFile(this.fileName, this.mime, this.bytes);
}

/// Workspace-file preview plumbing for one chat page (design
/// 09-29-file-preview §4.4/§5): the markdown image resolver with a
/// session-scoped LRU (re-rendered rows must not re-fetch), the extension
/// dispatch into the preview surfaces, the markdown link split (http(s) →
/// system browser, scheme-less local path → dispatch) and the read
/// callbacks the HTML preview page assembles with. Paths resolve against
/// the chat's active workspace ([ChatGateway.workspacePath]); without one
/// the resolver returns null and the dispatch stays inert.
class _ChatPreview {
  _ChatPreview(this._gateway);

  final ChatGateway _gateway;

  /// Insertion-ordered LRU (re-inserted on hit); null results are cached
  /// too — a missing file stays a placeholder without hammering the
  /// desktop on every re-render.
  final Map<String, Uint8List?> _imageCache = {};
  static const _imageCacheCap = 32;

  /// In-flight fetches: simultaneously-mounted widgets for one path (a
  /// markdown answer with the same image twice) share a single RPC.
  final Map<String, Future<Uint8List?>> _pending = {};

  /// Per-extension dispatch caps (design §4.4): raster images open the
  /// fullscreen viewer, html/htm the dual-view preview page; everything
  /// else (svg/md/txt…, PRD non-goals) stays inert.
  static const _imageExts = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};

  /// Whether [path] opens a preview surface at all — entry points gate
  /// their tap affordances on this so nothing renders as a dead link.
  static bool dispatchable(String path) {
    final ext = _extOf(path);
    return _imageExts.contains(ext) || ext == 'html' || ext == 'htm';
  }

  /// Fallback mimes for data URLs when the desktop ships no mediaType.
  static const _mimeByExt = {
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'bmp': 'image/bmp',
    'ico': 'image/x-icon',
    'woff': 'font/woff',
    'woff2': 'font/woff2',
    'ttf': 'font/ttf',
    'otf': 'font/otf',
  };

  /// Guard value aligned with the assembler's per-file cap (html_assembly).
  static const _maxTextBytes = 2 * 1024 * 1024;

  String? get _workspace {
    final ws = _gateway.workspacePath;
    return (ws == null || ws.isEmpty) ? null : ws;
  }

  static String _baseName(String path) =>
      path.split(RegExp(r'[\\/]')).last;

  /// The desktop resolves relative paths against ITS OWN process CWD, not
  /// the workspace (live-certified, spec §1.2) — scheme-less relative
  /// references from markdown must be joined onto the workspace before they
  /// reach the wire.
  static String _absolute(String ws, String path) {
    final p = path.replaceAll('\\', '/');
    if (p.startsWith('/') ||
        p.startsWith('//') ||
        RegExp(r'^[A-Za-z]:/').hasMatch(p)) {
      return p;
    }
    final base = ws.replaceAll('\\', '/');
    return base.endsWith('/') ? '$base$p' : '$base/$p';
  }

  static String _extOf(String path) {
    final i = path.lastIndexOf('.');
    return i < 0 ? '' : path.substring(i + 1).toLowerCase();
  }

  /// Markdown image resolver (design §4.3). Null on any failure — the
  /// markdown side renders the placeholder row.
  Future<Uint8List?> resolveImage(String path) async {
    final ws = _workspace;
    if (ws == null) return null;
    final abs = _absolute(ws, path);
    if (_imageCache.containsKey(abs)) return _imageCache[abs];
    final future = _pending.putIfAbsent(abs, () => _fetchImage(ws, abs));
    try {
      return await future;
    } finally {
      _pending.remove(abs);
    }
  }

  Future<Uint8List?> _fetchImage(String ws, String path) async {
    try {
      final res = await _gateway.fileReadMedia(ws, path);
      return _remember(path, res.bytes);
    } catch (_) {
      return _remember(path, null);
    }
  }

  Uint8List? _remember(String path, Uint8List? bytes) {
    _imageCache.remove(path);
    _imageCache[path] = bytes;
    while (_imageCache.length > _imageCacheCap) {
      _imageCache.remove(_imageCache.keys.first);
    }
    return bytes;
  }

  /// Entry dispatch (design §4.4): images → fullscreen viewer (bytes
  /// fetched through the cache), html/htm → the preview page, other
  /// extensions → no-op.
  Future<void> open(BuildContext context, String path) async {
    final ws = _workspace;
    if (ws == null) return;
    final ext = _extOf(path);
    if (_imageExts.contains(ext)) {
      final bytes = await resolveImage(path);
      if (!context.mounted) return;
      if (bytes == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              trP(context, 'chat.img.loadFailed', [_baseName(path)]),
            ),
          ),
        );
        return;
      }
      Navigator.of(context).push(
        zRoute((_) => ImageViewerPage(bytes: bytes, fileName: path)),
      );
    } else if (ext == 'html' || ext == 'htm') {
      Navigator.of(context).push(
        zRoute(
          (_) => FilePreviewPage(
            path: _absolute(ws, path),
            readText: (p) => _readText(ws, p),
            readMediaDataUrl: (p) => _readMediaDataUrl(ws, p),
          ),
        ),
      );
    }
  }

  /// Markdown link split (design §4.4): http(s) → system browser
  /// (externalApplication), scheme-less local path → [open]; other schemes
  /// (data:, file:, mailto:…) stay inert. Windows drive paths (`C:\…`)
  /// parse as a single-letter scheme, hence the length check.
  void openLink(BuildContext context, String href) {
    final normalized = href.replaceAll('\\', '/');
    final uri = Uri.tryParse(normalized);
    if (uri == null) return;
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (uri.scheme.isEmpty || uri.scheme.length == 1) {
      open(context, normalized);
    }
  }

  Future<String?> _readText(String ws, String path) async {
    try {
      final res = await _gateway.fileReadText(
        ws,
        _absolute(ws, path),
        offset: 0,
        length: _maxTextBytes,
      );
      return res.text;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _readMediaDataUrl(String ws, String path) async {
    try {
      final abs = _absolute(ws, path);
      final res = await _gateway.fileReadMedia(ws, abs);
      final mime = res.mediaType ?? _mimeByExt[_extOf(abs)];
      return 'data:${mime ?? 'application/octet-stream'};base64,'
          '${base64Encode(res.bytes)}';
    } catch (_) {
      return null;
    }
  }
}

/// A measured reading anchor for the history prepend compensation (R3): the
/// turn group identified by [key] sat [dy] px from the viewport edge it is
/// anchored against (top for reading, bottom for the pinned state — unused
/// there, the pinned landing targets the true content end).
typedef _HistoryAnchor = ({
  Key key,
  Set<num> rowIds,
  double dy,
  bool stick,
  // Stick landing target: the TRUE newest group's key. Measured too (not
  // just [key]) because the pinned anchor also records a READING anchor —
  // if the user scrolled away from the bottom while the page was loading,
  // the landing demotes to the reading anchor instead of yanking them back
  // to the bottom (open auto-load + immediate swipe-up, 09-22 round 8).
  Key? endKey,
  double baseMax,
  Key? rowKey,
  double? rowDy,
  // Offset at measure time: lets the compensation derive the TRUE content
  // shift of the prepend (see the LAND note in _compensateAnchor), which
  // the next prepend's cache pre-widen consumes — raw "target - pixels" is
  // contaminated by everything that moved the viewport since (drags during
  // the chain's wait); subtracting this offset cancels it all.
  double measurePixels,
});

class _ChatPageState extends State<ChatPage> {
  ChatHandle? _handle;
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();

  /// Workspace file-preview plumbing (markdown images, entry dispatch) —
  /// one per page so the image cache spans the whole session view.
  late final _preview = _ChatPreview(widget.gateway);

  /// Marks the message list subtree for the history anchor-compensation
  /// measurements (see [_measureAnchor] / [_compensateAnchor]).
  final GlobalKey _listKey = GlobalKey();
  String? _sessionId;
  String? _error;
  bool _sending = false;

  /// History paging decisions (entry gate, fetch, identity guard, DRAG HOLD
  /// parking, prepend commit, chain generation) — a pure Dart command class
  /// (task 10-01-history-pager-extract). The measurement chain below
  /// ([_measureAnchor] / [_prependOlderPage] / [_compensateAnchor]) stays in
  /// this State; [_compensationPending] remains the shared re-entry gate,
  /// injected into the pager read/write so there is a single truth.
  late final HistoryPager _pager = HistoryPager(
    fetch: _fetchOlderRows,
    currentState: () => _state,
    isScrollIdle: () => !_userDragActive && _scrollSettled,
    isCompensationPending: () => _compensationPending,
    setCompensationPending: (value) => _compensationPending = value,
    // Every old post-frame callback started with `if (!mounted) return` —
    // the seam carries that guard so the pager's frame callbacks keep the
    // exact old semantics.
    postFrame: (callback) => WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) callback();
    }),
    onStep: _onHistoryStep,
    onGateChanged: () {
      if (mounted) setState(() {});
    },
  );

  /// Loading gate forwarded from the pager (the「加载更早」button spinner and
  /// the scroll bookkeeping read it; the pager owns the flips).
  bool get _loadingOlder => _pager.loadingOlder;

  /// The conversationRowsRangeV4 RPC behind [HistoryPager.settle].
  Future<dynamic> _fetchOlderRows(
    String sessionId, {
    int? beforeRowId,
    int limit = 60,
  }) =>
      widget.gateway.conversationCommands.rowsRange(
        sessionId,
        beforeRowId: beforeRowId,
        limit: limit,
      );

  /// Reactions to the pager's typed outcomes: toasts here, measurement-chain
  /// scheduling here, everything else already happened inside the pager.
  void _onHistoryStep(HistoryLoadStep step) {
    if (!mounted) return;
    switch (step) {
      case HistoryStale():
        _toast(tr(context, 'chat.loadOlder.stale'));
      case HistoryNoOlder():
        _toast(tr(context, 'chat.noOlder'));
      case HistoryFailed(:final error):
        _toast(trP(context, 'chat.loadOlder.failed', ['$error']));
      case HistoryProceed(:final state, :final older, :final hasMore):
        unawaited(_prependOlderPage(state, older, hasMore));
      case HistoryHold():
        break; // parked in the pager; flushed on ScrollEnd ([_flushPendingOlder])
      case HistoryDuplicateDropped():
        break; // the measurement chain saw inserted == 0 and released the gate
    }
  }

  /// Pull threshold (logical px) for the history pull gesture: releasing a
  /// top overscroll at least this deep loads the older page.
  static const double _kPullThreshold = 64.0;

  /// Pull-gesture arming: true while the current drag holds the list
  /// overscrolled past [_kPullThreshold] at the top; the first non-drag
  /// scroll update afterwards is the release frame (see [_onListScroll]).
  bool _pullArmed = false;

  /// True from a user drag's ScrollStart until its release frame: the anchor
  /// compensation ([_compensateAnchor]) must not jumpTo under an active
  /// finger — the jump replaces the position's drag activity and every later
  /// move event of that gesture dies silently. The chain defers frame by
  /// frame and resumes when the finger lifts.
  bool _userDragActive = false;

  /// False from the first scroll update of any session (drag, ballistic
  /// coast, release spring, programmatic animation) until its ScrollEnd —
  /// i.e. true only while the offset is AT REST. Ballistic and rebound
  /// frames carry no dragDetails and clear [_userDragActive] on their first
  /// frame, so neither flag alone can answer "is the viewport moving right
  /// now": a prepend landing mid-coast must not jumpTo (kills the user's
  /// momentum, "滑着也被拉", 09-22 round 15) — the fetched page is held
  /// (see the DRAG HOLD note in [HistoryPager.settle]) and flushed after the
  /// ScrollEnd, and the prepend gate ([_prependOlderPage]) requires it too.
  bool _scrollSettled = true;

  /// Prepend VEIL (round 21): between the prepend's first frame and the
  /// measured landing the list paints fully transparent (layout and the
  /// anchor measurement run normally under it). The landing offset is only
  /// knowable AFTER the prepend's layout — until then any offset shown is a
  /// GUESS (last page's height), and device logs put page-height variance at
  /// ±1300-3000px: the guessed intermediate frame plus the landing's
  /// corrective glide read as the load-point jump that no animation tuning
  /// hid (rounds 12-20). A blank frame displaces nothing. Lifted by the
  /// landing, the give-up fallback, a stale generation — and IMMEDIATELY by
  /// any user scroll notification: a misplaced list beats a blank one.
  /// See the VEIL note in [_prependOlderPage].
  bool _listVeiled = false;

  /// The frozen frame shown over the veiled list (round 24): the plain
  /// transparent veil read as a full-screen BLACK flash on device (dark
  /// theme, 1-2 frames — OLED makes it loud). The last painted frame of
  /// the list is captured right before the prepend applies and drawn over
  /// the veil instead: the reader sees the SAME pixels standing still for
  /// a frame or two, then the landed view — nothing ever goes blank and
  /// nothing ever teleports. Null while no prepend is in flight; a failed
  /// capture downgrades the chain to the visible-landing path (no veil).
  ui.Image? _frozenFrame;

  /// [RepaintBoundary] around the list — the capture source for
  /// [_frozenFrame].
  final GlobalKey _freezeKey = GlobalKey();

  /// Temporary oversize cacheExtent for the anchor compensation (null =
  /// platform default). A 60-row prepend pushes the anchor group several
  /// viewports below, beyond the ~250px layout cache — instead of JUMPING
  /// there by the extent estimate (which inflates without bound right
  /// after a prepend and overshot the true content end on device, parking
  /// the view at max = "yanked to the bottom", 09-21 round 3), the cache
  /// is widened for a frame so SliverList lays out down to the anchor and
  /// the landing is measured, never estimated.
  double? _anchorCacheExtent;

  /// Invalidation epoch for anchor-compensation chains: stored (and bumped
  /// per prepend commit) in the pager; forwarded here so the compensation
  /// chain ([_compensateAnchor]) reads it unchanged.
  int get _anchorGeneration => _pager.anchorGeneration;

  /// Last page's MEASURED content shift — pure prepend height with every
  /// viewport movement cancelled out (see the LAND note in
  /// [_compensateAnchor]): the best available predictor for the next page's
  /// prepend height — same page size, similar content. Drives the veil's
  /// cache-extent pre-widen ([_prependOlderPage]): the anchor's depth below
  /// the offset is predicted from it so the FIRST veiled frame already lays
  /// out deep enough to measure (round 21; hops still cover a bad guess),
  /// and the give-up fallback when even the widened cache can't find the
  /// anchor.
  double? _lastMeasuredDelta;

  /// True from a prepend until its anchor compensation chain settles
  /// (lands, gives up, or dies with no viewport). Between the prepend and
  /// the landing the viewport sits at the UN-compensated offset — still
  /// inside the prefetch/pull trigger window — and a re-fire there starts
  /// the next load before this page's compensation ran, so that chain is
  /// stale-dropped and its content shift goes UN-compensated entirely
  /// (09-22 log: three loads a second apart, two stale-dropped = content
  /// free-falls two screens). Gates [_loadOlder] re-entry until the view
  /// is stable again.
  bool _compensationPending = false;

  /// True while a programmatic scroll (jumpTo / animateTo — open
  /// positioning, keyboard shrink-follow, jump-to-bottom, anchor
  /// compensation) is in flight. Its pixel sweep crosses the history
  /// prefetch window without the user reading anywhere near it (the open
  /// animation starts at offset 0), so the prefetch trigger parks until
  /// ScrollEnd; a user drag clears it immediately (taking over is fine).
  /// See [_onListScroll] — controller listeners can't do this routing
  /// because jumpTo fires them before its Start notification.
  bool _positioning = false;
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

  /// Draft-mode (no session yet) model/mode/thought selection, passed as
  /// `config` to createSession on first send.
  final Map<String, String> _draftConfig = {};

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
    gateway: widget.gateway,
    regressionHysteresis: widget.subagentHysteresis,
  );

  ConversationState? get _state => _handle?.state;

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
    }
    _scrollController.addListener(_onScroll);
    if (_sessionId != null) {
      _subscribe();
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
    });
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
      final entry = await showMentionSheet(context, widget.gateway);
      _mentionOpen = false;
      if (!mounted || entry == null) return;
      final start =
          (_mentionTriggerEnd - 1).clamp(0, _inputController.text.length);
      final next = applyMentionInsert(
          _inputController.text, _mentionTriggerEnd, entry.insert);
      _inputController.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(
            offset: start + entry.insert.length + 2),
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
    debugPrint('[anchor] stick=$stick pixels='
        '${_scrollController.position.pixels.toStringAsFixed(1)} max=$max');
    if (mounted) setState(() => _stickToBottom = stick);
  }

  /// History triggers (prefetch + pull gesture). Both ride the notification
  /// path, not the controller listener: [ScrollPosition.jumpTo] notifies
  /// controller listeners from forcePixels BEFORE its Start/Update/End
  /// notifications, so a listener-side trigger cannot tell a programmatic
  /// jump from a user scroll. Here every pixel change is bracketed by
  /// [_onListScroll]'s Start/End bookkeeping.
  ///
  /// Release detection uses RefreshIndicator's pattern — the first scroll
  /// update after a drag whose dragDetails is null is the release frame;
  /// ScrollEndNotification only fires after the spring has settled (pixels
  /// back at 0, too late) and the freed top edge emits no
  /// OverscrollNotification at all (task research, physics §3).
  /// Lifts the prepend veil ([_listVeiled]) — idempotent, safe to call
  /// from every compensation exit and scroll notification. Also drops the
  /// frozen frame; its disposal waits one frame so the layer that already
  /// painted it lets go first.
  void _liftVeil() {
    if (!_listVeiled && _frozenFrame == null) return;
    final frame = _frozenFrame;
    setState(() {
      _listVeiled = false;
      _frozenFrame = null;
    });
    if (frame != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => frame.dispose());
    }
  }

  bool _onListScroll(ScrollNotification n) {
    // Identity routing (same pattern as [_onListMetrics]): the subtree has
    // sibling scrollables — diff cards and expanded code blocks scroll
    // horizontally — and their notifications bubble through here too. A
    // horizontal drag would otherwise almost always satisfy the prefetch
    // window and fire a 60-row history load the user never asked for.
    if (!_scrollController.hasClients) return false;
    final notificationContext = n.context;
    final scrollable = notificationContext == null
        ? null
        : Scrollable.maybeOf(notificationContext);
    if (scrollable == null ||
        !identical(scrollable.position, _scrollController.position)) {
      return false;
    }
    if (n is ScrollStartNotification) {
      // dragDetails != null → a user drag starts; null → programmatic
      // activity (jumpTo / animateTo, see [_positioning]).
      if (n.dragDetails != null && _listVeiled) _liftVeil();
      _pullArmed = false;
      _userDragActive = n.dragDetails != null;
      _positioning = n.dragDetails == null;
    } else if (n is ScrollUpdateNotification) {
      if (_listVeiled) _liftVeil();
      // Any update frame (drag, coast, rebound, animation) = in motion; only
      // ScrollEnd restores "at rest" (see [_scrollSettled]).
      _scrollSettled = false;
      final pixels = n.metrics.pixels;
      // The first non-drag update after a drag is the release frame
      // (RefreshIndicator's pattern) — the finger is up again, so deferred
      // anchor compensation may resume.
      if (n.dragDetails == null) _userDragActive = false;
      // History prefetch (main path: it
      // triggers at scrollTop <= max(64, 2×viewport) from the top).
      // Programmatic frames ([_positioning]) and the pull gesture don't
      // count: a jump's pixel sweep doesn't mean the user is reading near
      // the top, and a sub-threshold pull must release into a silent
      // bounce — its spring lands at 0 from below, so non-drag frames
      // require pixels > 0. Reentrancy and cursor guards live inside
      // [_loadOlder].
      final inWindow =
          pixels <= math.max(64.0, n.metrics.viewportDimension * 2);
      final userDriven = n.dragDetails != null
          ? pixels >= 0 // live drag: negative = mid-pull overscroll
          : pixels > 0 && !_positioning;
      if (inWindow && userDriven) {
        _prefetchOlder();
      }
      if (n.dragDetails != null) {
        // Dragging: re-arm live with the pull depth.
        _pullArmed = pixels <= -_kPullThreshold;
      } else if (_pullArmed && pixels <= -_kPullThreshold) {
        // Release frame: trigger once.
        _pullArmed = false;
        if (!_loadingOlder) _loadOlder();
      }
    } else if (n is ScrollEndNotification) {
      _positioning = false;
      _userDragActive = false;
      _scrollSettled = true;
      // The scroll has truly settled (drag released, spring/fling done):
      // a drag-held history page may now flush (see the DRAG HOLD note in
      // [HistoryPager.settle]).
      _flushPendingOlder();
    }
    return false;
  }

  /// Scroll-proximity history prefetch entry (guarded by the caller).
  void _prefetchOlder() {
    final state = _state;
    if (state == null || !state.canLoadOlder || _loadingOlder) return;
    _loadOlder();
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
      final prep = await widget.gateway.prepareWorkspace();
      if (mounted) setState(() => _prep = prep);
    } catch (_) {}
    if (mounted) setState(() => _skillsLoading = true);
    try {
      final skills = await widget.gateway.skills();
      if (mounted) setState(() => _skills = skills);
    } catch (_) {
      if (mounted) setState(() => _skills = const []);
    } finally {
      if (mounted) setState(() => _skillsLoading = false);
    }
  }

  @override
  void dispose() {
    // mobile-view-state back to workspace-only (the phone left this task).
    try {
      widget.gateway.sendViewState();
    } catch (_) {}
    _handle?.close();
    _feed.dispose();
    _inputController.dispose();
    _scrollController.dispose();
    _frozenFrame?.dispose();
    super.dispose();
  }

  Future<void> _subscribe() async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    try {
      final handle = await widget.gateway
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
      widget.gateway.sendViewState(taskId: sessionId);
      handle.state.addListener(_scrollToBottom);
      handle.state.addListener(_onConfigMaybeReverted);
      // Terminal-hysteresis memory rides the parent conversation (subagent
      // rows + backgroundWorks).
      _feed.observe(handle.state);
      // The server snapshot is a tail window (can be as few as 3 rows).
      // The client shows the full history immediately, so
      // auto-load the missing older rows once on open.
      if (handle.state.canLoadOlder) {
        await _loadOlder();
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
      if (!grew || !_stickToBottom || _compensationPending) {
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
  void _onConfigMaybeReverted() {
    final state = _handle?.state;
    if (state == null || !state.consumeConfigReverted()) return;
    if (!mounted) return;
    _toast(tr(context, 'chat.sheet.switchReverted'));
  }

  Future<void> _run(String errorPrefix, Future<dynamic> Function() run) async {
    // Read the locale before the async gap: [businessErrorCopy] needs it, and
    // it must not receive a BuildContext.
    final locale = UiSettingsProvider.of(context)?.locale ?? 'zh-CN';
    try {
      final res = await run();
      if (res is Map &&
          res['status'] != null &&
          res['status'] != 'accepted' &&
          res['status'] != 'noop') {
        _toast('$errorPrefix: ${res['reasonCode'] ?? res['status']}');
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

  Future<void> _pickFiles() async {
    try {
      final result = await FilePicker.pickFiles(
        withData: true,
        allowMultiple: true,
      );
      if (result == null) return;
      setState(() {
        for (final file in result.files) {
          final bytes = file.bytes;
          if (bytes == null) continue;
          _pendingFiles.add(
            _PendingFile(file.name, _guessMime(file.name), bytes),
          );
        }
      });
    } catch (e) {
      if (mounted) _toast(trP(context, 'chat.attach.pickFailed', ['$e']));
    }
  }

  Future<List<Map<String, dynamic>>> _uploadPending(String sessionId) async {
    final uploaded = <Map<String, dynamic>>[];
    for (var i = 0; i < _pendingFiles.length; i++) {
      final file = _pendingFiles[i];
      final descriptor = await widget.gateway.conversationCommands.attachmentPut(
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
    HapticFeedback.lightImpact();

    // Slash commands (as in the web composer).
    if (text == '/compact' || text.startsWith('/compact ')) {
      _inputController.clear();
      setState(() => _showSlash = false);
      await _run(
        tr(context, 'chat.compact.failed'),
        () => widget.gateway.conversationCommands.compact(_requireSession()),
      );
      return;
    }
    if (text == '/goal pause') {
      _inputController.clear();
      setState(() => _showSlash = false);
      await _run(
        tr(context, 'chat.goal.pauseFailed'),
        () => widget.gateway.conversationCommands.pauseGoal(_requireSession()),
      );
      return;
    }
    if (text == '/goal resume') {
      _inputController.clear();
      setState(() => _showSlash = false);
      await _run(
        tr(context, 'chat.goal.resumeFailed'),
        () => widget.gateway.conversationCommands.resumeGoal(_requireSession()),
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
      _progress = null;
    });
    try {
      var sessionId = _sessionId;
      if (sessionId == null) {
        // 1) create the session (can take a while when the runtime warms)
        setState(() => _progress = tr(context, 'chat.creating'));
        // Plain text first message is sent WITH createSession (firstInput,
        // as the composer does). This avoids a send-before-subscribe
        // race where the first command can be dropped on a fresh session.
        final canUseFirstInput =
            text.isNotEmpty &&
            _pendingFiles.isEmpty &&
            !text.startsWith('/goal ') &&
            heldDisposition == null;
        final workspaceId = widget.gateway.chatWorkspaceId;
        if (workspaceId == null || workspaceId.isEmpty) {
          throw StateError(tr(context, 'tasks.noWorkspaces.title'));
        }
        sessionId = await widget.gateway.conversationCommands.createSession(
          workspaceId,
          firstText: canUseFirstInput ? text : null,
          config: _buildDraftConfig(),
        );
        if (!mounted) return;
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
        final res = await widget.gateway.conversationCommands.sendGoalCommand(
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
      final result = await widget.gateway.conversationCommands
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
      if (mounted) {
        _toast(trP(context, 'chat.send.failed', ['$e']));
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
  Map<String, dynamic> _buildDraftConfig() =>
      sanitizeNewTaskConfig(_draftConfig, _prep);

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

  // ------------------------------------------------------------ history

  /// Loads one older history page — the single entry ALL four triggers
  /// (open auto-load / prefetch window / pull release / button) funnel
  /// into; the mutual-exclusion gate lives in the pager ([HistoryPager.beginLoad]).
  /// The fetch decisions themselves live in [HistoryPager.settle].
  Future<void> _loadOlder() async {
    final request = _pager.beginLoad(_sessionId);
    if (request == null) return;
    // Post-frame so the list has actually mounted (the subscribe microtask
    // chain can beat the first build) — the anchor itself is NOT measured
    // here anymore: since round 18 the prepend only runs with the viewport
    // at rest (see the DRAG HOLD note in [HistoryPager.settle]) and measures
    // fresh right before it applies the page, so the anchored position IS
    // the reader's settled position — no armed pre-fetch anchor to yank
    // them back to, and the SliverList's own retained-child stability does
    // the mid-list anchoring (see the VEIL note in [_prependOlderPage]).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_pager.settle(request));
    });
  }

  /// Applies a fetched history page. The anchor is ALWAYS measured here,
  /// right before the prepend — since round 17 the prepend only runs with
  /// the viewport at rest (see the DRAG HOLD note in [HistoryPager.settle]),
  /// so "now" is already the reader's settled position and a fresh measure
  /// is the correct anchor (the old pre-fetch armed anchor anchored the
  /// REQUEST-time position; whatever the reader drifted to during the ~1s
  /// round trip, the landing then yanked back — "向下跳动", 09-22 round 18).
  /// With the offset at rest the SliverList itself keeps the viewport
  /// content stable across the prepend (retained children keep their
  /// layoutOffsets and the new rows lay out above them — see the VEIL note
  /// below for the one exception), so the measured landing usually
  /// corrects nothing.
  Future<void> _prependOlderPage(
    ConversationState state,
    List<Map<String, dynamic>> older,
    bool? hasMore,
  ) async {
    // Hold re-check AT THE PREPEND FRAME (the park lives in the pager): the
    // arrival microtask's settled verdict can be one frame stale — a slow
    // reader's rhythm is stop-and-go, and a reply that lands in a pause
    // then prepends just as the NEXT drag starts would prepend into a
    // moving viewport (09-22 round 16 device log: give-up at pixels 320,
    // next landing 3616 -> 6581).
    if (_pager.parkPrependIfBusy(state, older, hasMore)) return;
    // FROZEN FRAME (round 24): capture the list's CURRENT paint before the
    // prepend applies — the plain transparent veil replaced the list with a
    // blank for 1-2 frames and read as a full-screen black flash on device
    // (dark theme; "每次加载的时候都会有一个闪屏, 界面短暂全黑"). Drawing
    // this capture over the veil shows the SAME pixels standing still until
    // the measured landing — nothing goes blank, nothing teleports. A
    // failed capture (no boundary / capture error) downgrades the chain to
    // the visible-landing path instead: a misplaced list beats a blank one.
    ui.Image? frozen;
    final boundary = _freezeKey.currentContext?.findRenderObject();
    if (boundary is RenderRepaintBoundary && !boundary.debugNeedsPaint) {
      final ratio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 3.0;
      try {
        frozen = await boundary.toImage(pixelRatio: ratio);
      } catch (_) {
        frozen = null;
      }
    }
    if (!mounted) {
      frozen?.dispose();
      return;
    }
    // The capture is async (GPU read-back): re-check the hold AFTER the
    // gap — a drag that started mid-capture must park the page, not
    // prepend under a moving finger (same remedy as the entry hold).
    if (_pager.parkPrependIfBusy(state, older, hasMore)) {
      frozen?.dispose();
      return;
    }
    // Viewport anchor (R3, shared by prefetch / gesture / button): measured
    // from real RenderBox positions before the prepend. Deliberately NOT the
    // old maxScrollExtent arithmetic (jumpTo(anchorPixels + Δmax)): past the
    // laid-out window the SliverList extent is an average-row estimate that
    // misses by hundreds of px under real row-height variance, and jumpTo
    // bypasses applyBoundaryConditions — an over-estimate parked the viewport
    // beyond the true content end: blank viewport, stuck scroll until the
    // next touch (2026-09-21 device acceptance). The measured group delta is
    // exact.
    final anchor = _measureAnchor(state);
    // Invalidation epoch: a faster reader fires the next load before this
    // page's compensation chain finished, and the chains would otherwise
    // interleave — each landing on a viewport the previous one already
    // moved, stacking misplaced jumps (the 09-22 log shows three chains
    // landing 796→7288→10134→8656 = yanked to the bottom). Only the newest
    // page's chain may still land. The bump and the data write-back live
    // in the pager commit.
    final outcome = _pager.commitPrepend(state, older, hasMore);
    final gen = outcome.generation;
    final inserted = outcome.inserted;
    if (inserted == 0) {
      // Duplicate page: a re-fire raced this chain's prepend window (same
      // beforeRowId cursor, e.g. a prefetch issued between the drag-hold
      // flush clearing the gate and its post-frame prepend). Nothing
      // shifted — anchoring a no-op prepend pre-jumps the view a full page
      // out and the landing drags it all the way back down ("向下被拉动",
      // 09-22 round 14: pre-jump 3317px out, LAND dragged 7273 -> 3955).
      debugPrint('[anchor] duplicate page dropped');
      _compensationPending = false;
      return;
    }
    // VEIL (round 21): the landing offset is only knowable AFTER the
    // prepend's layout — until then every offset shown is a guess, and
    // page-height variance (±1300-3000px in the round 16-20 device logs)
    // makes the guessed intermediate frame wrong by whole screens. A jump
    // to the guess (the pre-jump, rounds 5-18) plus the measured landing's
    // corrective glide read as the load-point jump that no animation
    // tuning ever hid. Instead the list paints TRANSPARENT from the
    // prepend's first frame until the measured landing a frame later —
    // layout and the anchor measurement run normally under the veil, so
    // the landing is exact and the reader sees one blank frame instead of
    // one wrong one. The veil never survives contact: any user scroll
    // notification lifts it (see [_onListScroll]), and every terminal
    // exit of [_compensateAnchor] lifts it too.
    // Prepending shifts the content above the reading position; both
    // modes compensate by re-measuring the anchor group's real position
    // next frame (the web does scrollTop += delta — this is the
    // measured variant): reading keeps the anchor's distance from the
    // viewport top, stick re-lands on the true newest end. The state
    // listener's follow still owns APPENDS; the old stick branch called
    // _scrollToBottom here, which rode the same extent estimate and
    // could fall short of (or mis-aim at) the true end on tall pages.
    if (anchor != null) {
      // Re-entry gate (see [_compensationPending]): from here until the
      // chain settles, the viewport sits at the un-compensated offset —
      // inside the prefetch window — and must not start another load.
      _compensationPending = true;
      final chainedAnchor = anchor;
      // Pre-widen the layout cache WITH the data change: the anchor sits
      // ~one page below the offset after the prepend, beyond the ~250px
      // default cache. Widening here (predicted from the last page's
      // measured height, ×2 headroom for its variance) lets the FIRST
      // veiled frame already lay out down to the anchor, so the landing
      // usually measures on hop 0; a bad guess costs one more veiled
      // frame via the hop chain, never a shown one.
      double? preWiden;
      if (!anchor.stick &&
          _lastMeasuredDelta != null &&
          _scrollController.hasClients) {
        final viewportHeight = _scrollController.position.viewportDimension;
        preWiden = math.min(
            _lastMeasuredDelta! * 2 + viewportHeight, 120000.0);
      }
      setState(() {
        _listVeiled = frozen != null;
        _frozenFrame = frozen;
        _anchorCacheExtent = preWiden;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!_scrollController.hasClients) {
          _compensationPending = false;
          _liftVeil();
          return;
        }
        _compensateAnchor(chainedAnchor, hop: 0, gen: gen, chainState: state);
      });
    } else {
      // No measurable anchor (unmounted list / empty groups): the fetch
      // path pre-closed the re-entry gate — release it, the prepend stands
      // uncompensated.
      _compensationPending = false;
    }
  }

  /// Flushes a drag-held history page once the scroll has truly ended (drag
  /// released AND the release spring / fling settled —
  /// [ScrollEndNotification]); the parked page and all flush decisions
  /// (identity drop, compensation wait, gate sequencing) live in the pager
  /// ([HistoryPager.flushHeld]) — this shim only contributes `mounted`.
  void _flushPendingOlder() {
    if (!mounted) return;
    _pager.flushHeld();
  }

  /// Reading anchor for the prepend compensation, measured from real
  /// RenderBox positions (never from maxScrollExtent as a landing target —
  /// see [_loadOlder]; the pre-fetch extent is kept only as the coarse-hop
  /// delta source).
  ///
  /// Reading (non-stick): the first group at/over the viewport top, then a
  /// retreat up to the nearest STABLE group (userInput / timelineMarker
  /// first) — see the retreat comment in the body for why the first visible
  /// group itself can orphan its key across a prepend.
  ///
  /// Pinned (stick): ALSO captures the true newest group ([_HistoryAnchor]'s
  /// endKey) as the landing target — but the reading anchor is measured
  /// regardless: if the user scrolls away from the bottom while the page
  /// loads, the landing demotes to the reading anchor instead of yanking
  /// them back to the end (open auto-load + immediate swipe-up, 09-22
  /// round 8).
  _HistoryAnchor? _measureAnchor(ConversationState state) {
    if (!_scrollController.hasClients) return null;
    final viewport = _listViewportBox();
    if (viewport == null) return null;
    final viewportTop = viewport.localToGlobal(Offset.zero).dy;
    final allGroups = _groupRows(state.rows);
    if (allGroups.isEmpty) return null;
    // Extent BEFORE the prepend (measured pre-fetch, hence converged): the
    // compensation's coarse first hop re-derives the estimate delta from it.
    final baseMax = _scrollController.position.maxScrollExtent;
    Set<num> rowIdsOf(List<Map<String, dynamic>> rows) => rows
        .map((r) => r['rowId'])
        .whereType<num>()
        .toSet();
    final stick = _stickToBottom;
    final groups = _builtGroups();
    if (groups.isEmpty) return null;
    var anchorIdx = -1;
    for (var i = 0; i < groups.length; i++) {
      if (groups[i].$2.localToGlobal(Offset.zero).dy >= viewportTop - 40) {
        anchorIdx = i;
        break;
      }
    }
    anchorIdx = anchorIdx < 0 ? groups.length - 1 : anchorIdx;
    // Retreat to the nearest STABLE group at/above the reading position: a
    // group keyed by a non-user first row merges away when a rowsRange page
    // boundary splits a turn (the prepend re-groups, the first rowId
    // changes, the key orphans and the compensation used to hop to the list
    // end — the 09-21 "yanked to the bottom" device report). A userInput
    // or timelineMarker first can only ever gain rows ABOVE its first row,
    // never lose it, so its key survives any prepend.
    var stableIdx = anchorIdx;
    while (stableIdx >= 0) {
      final firstKind = groups[stableIdx].$1.rows.first['kind'];
      if (firstKind == 'timelineMarker' || firstKind == 'userInput') break;
      stableIdx--;
    }
    final useIdx = stableIdx >= 0 ? stableIdx : anchorIdx;
    final (widget, box) = groups[useIdx];
    debugPrint('[anchor] measure stick=$stick key=${widget.key} '
        'rowIds=${widget.rows.map((r) => r['rowId']).toList()} '
        'retreated=${useIdx != anchorIdx}');
    // Row-level anchor (exact landing when the group's key orphans to a
    // page-boundary merge): measure the first row's own box now so the
    // compensation can land on IT instead of the merged group's top (which
    // sits the merged-in segment deeper every page — the cumulative
    // downward drift of 09-22 round 4).
    final rowKey = ValueKey('row-${widget.rows.first['rowId']}');
    final rowBox = _findRowBox(rowKey);
    return (
      key: widget.key!,
      rowIds: rowIdsOf(widget.rows),
      dy: box.localToGlobal(Offset.zero).dy - viewportTop,
      stick: stick,
      endKey: stick
          ? ValueKey('turn-${allGroups.last.first['rowId']}')
          : null,
      baseMax: baseMax,
      rowKey: rowKey,
      rowDy: rowBox == null
          ? null
          : rowBox.localToGlobal(Offset.zero).dy - viewportTop,
      measurePixels: _scrollController.position.pixels,
    );
  }

  /// The message list's viewport-sized render box (Listener/GestureDetector
  /// wrap the viewport exactly), or null when nothing is laid out.
  RenderBox? _listViewportBox() {
    final box = _listKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box;
  }

  /// Every currently-built turn group, in list order: (widget, box). The
  /// widget exposes both the key (stable iff the first row is a userInput /
  /// timelineMarker — such a first row can never lose group-lead position to
  /// a prepend re-group) and the rows themselves (the rowId fallback when a
  /// page-boundary re-group orphans the key). Only BUILT children exist
  /// here — SliverList keeps just the viewport plus its cacheExtent alive,
  /// which is exactly why the compensation sometimes has to hop, see
  /// [_compensateAnchor].
  List<(_TurnGroupWidget, RenderBox)> _builtGroups() {
    final groups = <(_TurnGroupWidget, RenderBox)>[];
    final listContext = _listKey.currentContext;
    if (listContext == null) return groups;
    void visit(Element element) {
      final widget = element.widget;
      if (widget is _TurnGroupWidget) {
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

  /// The render box of a single message row by its `ValueKey('row-<rowId>')`
  /// (rows carry keys in [_TurnGroupWidget]'s build), or null when that row
  /// isn't independently built (merged inside a text part / off-window).
  RenderBox? _findRowBox(Key rowKey) {
    RenderBox? found;
    final listContext = _listKey.currentContext;
    if (listContext == null) return null;
    void visit(Element element) {
      if (found != null) return;
      final widget = element.widget;
      if (widget is _RowWidget || widget is _ToolGroupCard) {
        if (widget.key == rowKey) {
          final box = element.findRenderObject();
          if (box is RenderBox && box.attached && box.hasSize) found = box;
        }
        return;
      }
      element.visitChildElements(visit);
    }

    listContext.visitChildElements(visit);
    return found;
  }

  /// Post-prepend compensation (R3): re-find the anchor group, measure its
  /// real position and jump by the measured delta — maxScrollExtent plays no
  /// part in the LANDING, so row-height variance cannot skew it.
  ///
  /// While a finger is down ([_userDragActive]) the chain only defers: a
  /// jumpTo replaces the position's drag activity and silently kills every
  /// later move event of that gesture. Once the finger lifts, the chain
  /// resumes.
  ///
  /// The prepend usually pushes the anchor out of the laid-out window (60
  /// rows span several viewports vs the 250px cacheExtent). The first hop is
  /// COARSE: one jump by the extent-estimate delta (wrong by row-height
  /// variance, but by hundreds of px — inside the viewport+cache window), so
  /// the anchor usually surfaces on the very next frame for the measured
  /// landing. If it still doesn't (orphaned key beyond the retreat, extreme
  /// variance), the view STAYS at the coarse landing: an estimate-grade
  /// anchor, never a guess-crawl — the old behavior's multi-screen sweep
  /// read as "yanked to the bottom" (device report 09-21).
  void _compensateAnchor(
    _HistoryAnchor anchor, {
    required int hop,
    int? gen,
    ConversationState? chainState,
  }) {
    // Stale chains die here: a newer load's measure already captured (and
    // the newest page's chain will land on) the CURRENT viewport — an older
    // chain landing later would stack a jump on top of it (09-22 log:
    // three interleaved chains 796→7288→10134→8656 = yanked to bottom).
    if (gen != null && gen != _anchorGeneration) {
      if (_anchorCacheExtent != null) {
        setState(() => _anchorCacheExtent = null);
      }
      _liftVeil();
      debugPrint('[anchor] stale gen=$gen dropped');
      return;
    }
    // No stale return below this point: every remaining exit is terminal for
    // this chain, so each clears the re-entry gate (a stale chain leaves it
    // to the newer chain that superseded it).
    if (_userDragActive) {
      // A drag arrived under the veil (its ScrollStart should have lifted
      // it already — belt and braces): show the list while the chain waits
      // the finger out; the landing's correction then runs visible and
      // eases (see the landing note).
      _liftVeil();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        _compensateAnchor(anchor, hop: hop, gen: gen, chainState: chainState);
      });
      return;
    }
    // Our own programmatic scroll ([_positioning]: the open-page follow, a
    // prior landing's ease) is carrying the viewport: its motion must not
    // read as user drift, or the landing surrenders off a phantom (the
    // open auto-load once surrendered off its own 575px follow and stranded
    // the view mid-content while the extent settled past it, 09-22 round
    // 15). A STICK chain does not wait — its measured endKey landing is
    // the authoritative bottom (the follow only animates toward a stale
    // extent estimate; landing kills it). A READING chain waits the motion
    // out and re-measures the anchor from the settled position — the same
    // fresh-measure the drag-hold flush uses; the armed baseline is
    // meaningless after a programmatic carry.
    if (chainState != null && _positioning && !anchor.stick) {
      _liftVeil();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        if (_positioning) {
          _compensateAnchor(anchor, hop: hop, gen: gen, chainState: chainState);
          return;
        }
        final fresh = _measureAnchor(chainState);
        _compensateAnchor(fresh ?? anchor, hop: hop, gen: gen);
      });
      return;
    }
    final viewport = _listViewportBox();
    if (viewport == null) {
      _compensationPending = false;
      _liftVeil();
      return;
    }
    final position = _scrollController.position;
    // Mid rubber-band rebound (pixels outside [0, max] right after the finger
    // lifted): landing from that moving baseline kills the rebound and reads
    // as a yank (09-22 log: -59.3 -> 2601 in one jump). The rebound converges
    // within a few frames — re-check then.
    if (position.pixels < 0 || position.pixels > position.maxScrollExtent) {
      // A rebound's baseline moves every frame: don't measure the landing
      // from it, and don't hold the veil across its (unbounded) frames.
      _liftVeil();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        _compensateAnchor(anchor, hop: hop, gen: gen, chainState: chainState);
      });
      return;
    }
    // Stick demotion: the anchor was captured pinned, but the user scrolled
    // while the page loaded (open auto-load + immediate swipe-up, 09-22
    // round 8) — land on the READING anchor captured at the same measure
    // instead of yanking them back to the end. Judged by the offset's drift
    // from measure time (any direction: up = reading, down = still chasing
    // the end), NOT by [_stickToBottom]: the prepend itself grows max and
    // flips that flag without any user movement. The drift test is skipped
    // while a PROGRAMMATIC scroll owns the viewport — that motion is ours,
    // not the reader's (round 15).
    final landingStick = anchor.stick &&
        (_positioning || // our own animation, not the reader's drift
            (position.pixels - anchor.measurePixels).abs() <= 40);
    final landingKey = landingStick ? anchor.endKey! : anchor.key;
    final groups = _builtGroups();
    RenderBox? box;
    for (final (widget, candidate) in groups) {
      if (widget.key == landingKey) {
        box = candidate;
        break;
      }
    }
    // Landing base: the anchor GROUP normally. When its key orphaned to a
    // page-boundary merge, land on the anchor ROW's own box (exact — rows
    // survive any re-group) if it was measurable at anchor time; only then
    // fall back to whatever group now contains the rows (sits the merged-in
    // segment deeper — the cumulative drift of 09-22 round 4).
    final bool rowLanding;
    if (box != null) {
      rowLanding = false;
    } else if (anchor.rowKey != null && anchor.rowDy != null) {
      final rowBox = _findRowBox(anchor.rowKey!);
      if (rowBox != null) {
        box = rowBox;
        rowLanding = true;
        debugPrint('[anchor] row landing ${anchor.rowKey}');
      } else {
        rowLanding = false;
      }
    } else {
      rowLanding = false;
    }
    if (box == null) {
      for (final (widget, candidate) in groups) {
        final ids = widget.rows
            .map((r) => r['rowId'])
            .whereType<num>();
        if (ids.any(anchor.rowIds.contains)) {
          box = candidate;
          debugPrint('[anchor] rowId fallback -> ${widget.key}');
          break;
        }
      }
    }
    if (box == null) {
      if (groups.isEmpty) {
        // Parked past the real content end (nothing laid out = blank
        // viewport): step back into range instead of staying stuck.
        _scrollController.jumpTo(math.max(0.0, position.maxScrollExtent));
        _compensationPending = false;
        _liftVeil();
        return;
      }
      if (hop == 0) {
        // Anchor not built: widen the cache for one frame so SliverList
        // lays out down to the anchor's expected depth (estimate ×2 headroom
        // — inflation is one-sided, under-estimate leaves the anchor short).
        // Measured landing follows; no pixel is ever jumped by estimate.
        final need = (position.maxScrollExtent - anchor.baseMax) * 2 +
            viewport.size.height;
        setState(() => _anchorCacheExtent = math.min(need, 120000.0));
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (!_scrollController.hasClients) {
            _compensationPending = false;
            _liftVeil();
            return;
          }
          _compensateAnchor(anchor, hop: hop + 1, gen: gen,
              chainState: chainState);
        });
        return;
      }
      // Still not found with the widened cache: the anchor's key orphaned
      // (page-boundary re-group) AND its row isn't an independently-keyed
      // widget (merged inside a text part — see [_findRowBox]) AND the
      // rowIds fallback matched nothing built. Not pathological — the
      // veiled layout puts the anchor several viewports below the offset
      // and the walk can still miss it. Land by the last page's MEASURED
      // height (a conservative 0.85-fold: an under-shot lands ~300px off
      // where a full-height guess missed by 1287, round 20) instead of
      // compounding an uncompensated prepend into the NEXT landing.
      // Skipped while the viewport is in motion (kills the gesture /
      // coast); the veil lifts either way — the reader must never be left
      // staring at a blank list.
      debugPrint('[anchor] give up hop=$hop pixels='
          '${position.pixels.toStringAsFixed(1)} builtGroups='
          '${groups.length}');
      setState(() => _anchorCacheExtent = null);
      // At the very head the reader is looking at the FRESH page — an
      // estimated jump there leaps somewhere they never chose (round 21
      // log: two head give-ups jumped to guess positions, "内容跳的非常
      // 厉害"). Stay put; the next chain lands measured.
      if (!anchor.stick &&
          _lastMeasuredDelta != null &&
          !_userDragActive &&
          _scrollSettled &&
          position.pixels >= 1.0) {
        _scrollController.jumpTo(
          (position.pixels + _lastMeasuredDelta! * 0.85)
              .clamp(0.0, position.maxScrollExtent),
        );
      }
      _compensationPending = false;
      _liftVeil();
      return;
    }
    final viewportTop = viewport.localToGlobal(Offset.zero).dy;
    final viewportBottom = viewportTop + viewport.size.height;
    final top = box.localToGlobal(Offset.zero).dy;
    final dy = rowLanding ? anchor.rowDy! : anchor.dy;
    // No drift surrender anymore (round 18 removed it): its job was to
    // catch the reader flinging away from the PRE-FETCH armed position —
    // but the anchor is now measured fresh at the prepend (whatever the
    // reader drifted to during the round trip IS the anchored position),
    // so there is no stale position left to defend. What the pixels-delta
    // check DID catch lately was the sliver's own scrollOffsetCorrection:
    // a pre-jump landing in never-laid-out estimate territory gets its
    // offset translated by thousands of px when the real layout walks in
    // (round 18 log: pre-jump to 4266, layout corrected the offset to
    // 10773, drift 6507 "surrendered" and the uncompensated prepend left
    // the reader lost mid-history). The landing formula below is
    // translation-invariant — correction moves `top` and `pixels` in the
    // same amount and cancels — so landing is correct either way.
    final double target;
    if (landingStick) {
      // Pinned: land the captured newest group exactly on the true content
      // end (the list's bottom padding above the viewport bottom) — derived
      // from measured boxes, so it can neither fall short the way
      // animateTo(max-estimate) does nor overshoot into the unpainted
      // region the way the old Δmax jumpTo did.
      final bottom = top + box.size.height;
      target =
          position.pixels + (bottom - viewportBottom) + _listPadding.bottom;
    } else {
      // Reading: keep the anchor's distance from the viewport top (row box
      // + row dy when landing on the row, group box + group dy otherwise).
      target = position.pixels + (top - viewportTop - dy);
    }
    debugPrint('[anchor] LAND hop=$hop stick=$landingStick veiled=$_listVeiled'
        ' key=$landingKey pixels=${position.pixels.toStringAsFixed(1)} -> '
        '${target.toStringAsFixed(1)}');
    if (!landingStick) {
      // TRUE content shift of this prepend: the anchor's screen displacement
      // plus the total pixel displacement since measure (finger drags,
      // ballistic scroll — everything that moved the viewport cancels out,
      // leaving pure content height). Feeds the NEXT prepend's cache-extent
      // pre-widen and the give-up fallback — never a pixel jump (round 21;
      // the pre-jump it used to drive is gone).
      _lastMeasuredDelta = (top - viewportTop - dy) +
          (position.pixels - anchor.measurePixels);
    }
    if (_anchorCacheExtent != null) {
      setState(() => _anchorCacheExtent = null);
    }
    _compensationPending = false;
    // Clamp to the content range: jumpTo bypasses applyBoundaryConditions,
    // and an un-clamped stale-baseline target once parked the viewport
    // past the true end (blank view + fake stick).
    final clamped = target.clamp(0.0, position.maxScrollExtent);
    if (_listVeiled) {
      // Veiled transit: the offset's trip to the landing happened off
      // screen, so land exactly and lift in the same frame — the reader
      // resumes on the settled view (round 21). The jumpTo's own scroll
      // notifications can't re-trigger anything here (its ScrollEnd just
      // re-marks the offset settled, which it is).
      _scrollController.jumpTo(clamped);
      _liftVeil();
      return;
    }
    // VISIBLE landing — the veil was interrupted (a drag, a rebound) or a
    // re-measured chain landed mid-stream: small reading corrections
    // ANIMATE instead of teleporting; a same-frame teleport is the visible
    // "content nudges DOWN a little" of 09-22 round 12 (logged 460px and
    // 1003px). Easing over ~100-180ms reads as the list settling instead;
    // the duration scales with the distance so a ~3k correction doesn't
    // glide at 5× the speed of a 400px one. Past the ceiling it still
    // snaps — half a screen of gliding is worse than one cut. A touch
    // cancels the animation naturally (ballistic), and any later chain's
    // jumpTo kills it outright.
    final correction = (clamped - position.pixels).abs();
    if (!landingStick && correction > 40 && correction <= 3200) {
      final ms = (96.0 + (correction - 800).clamp(0.0, 2400.0) * 84 / 2400)
          .clamp(96.0, 180.0);
      _scrollController.animateTo(
        clamped,
        duration: Duration(milliseconds: ms.round()),
        curve: Curves.easeOut,
      );
    } else {
      _scrollController.jumpTo(clamped);
    }
  }

  // ------------------------------------------------------------ sheets

  /// Quota warning (R3): the fetched plan snapshot reports exhausted or
  /// limited. The fetch happens once per page open, so the banner persists
  /// for the page's lifetime and the next open re-evaluates it against the
  /// shared poller's freshest ok snapshot.
  bool get _showQuotaWarning {
    final view = _entitlement;
    return view != null &&
        view.phase == EntitlementPhase.ok &&
        view.exhausted;
  }

  Future<void> _loadEntitlement() async {
    try {
      final view = await widget.gateway.entitlementSnapshot();
      if (!mounted) return;
      setState(() => _entitlement = view);
      // The reset scope rides the snapshot (injected by the session's
      // entitlementSnapshot); this plain refresh picks the pools up — a
      // no-op without a provider id (the banner action never shows).
      unawaited(widget.gateway.quotaResetController.refresh());
    } catch (_) {
      // Gateways may reject; the banner then stays hidden and the chat is
      // not disturbed.
    }
  }

  /// Banner「使用重置券」入口 removed (PRD: the sheet is the single
  /// reset entry) — the dialog + success chain live in [_showResetDialog].
  /// [resettable] comes from the EntitlementView projection
  /// (`resettablePools`, see the usage sheet), so the dialog lists exactly
  /// the pools the row credited.
  Future<void> _showResetDialog(Set<String> resettable) async {
    final type = await showQuotaResetDialog(
      context,
      controller: widget.gateway.quotaResetController,
      resettable: resettable,
    );
    if (!mounted || type == null) return;
    _toast(tr(context, 'usage.reset.success'));
    // The controller's success chain force-refreshed the poller; re-read
    // it so the exhausted banner flips immediately.
    await _loadEntitlement();
  }

  Future<void> _showModelSheet() async {
    // PRD 09-19: sessions created with an empty default model config can
    // ship no usable model options from prepareWorkspace — fetch the
    // model-provider catalog as the sheet's fallback selector data. Normal
    // sessions (options present) never trigger the extra RPC.
    var catalog = const <Map<String, dynamic>>[];
    final modelOption = _prep?.option('model');
    if (modelOption == null || modelOption.options.isEmpty) {
      catalog = await widget.gateway.modelProviderCatalog();
    }
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _ModelModeSheet(
        gateway: widget.gateway,
        state: _state,
        prep: _prep,
        sessionId: _sessionId,
        providerCatalog: catalog,
        draftConfig: _draftConfig,
        onDraftChange: (key, value) {
          setState(() => _draftConfig[key] = value);
        },
      ),
    );
  }

  /// Slash entries = builtin/custom commands from prepareWorkspace plus the
  /// desktop's skills (triggered as `$name` in the composer).
  List<_SlashItem> get _slashItems {
    final items = <_SlashItem>[];
    for (final c in _prep?.slashCommands ?? const <SlashCommand>[]) {
      items.add(
        _SlashItem(
          name: c.name,
          description: c.description,
          insert: '/${c.name} ',
          isSkill: false,
        ),
      );
    }
    for (final s in _skills) {
      items.add(
        _SlashItem(
          name: s.name,
          description:
              s.description ??
              (s.argumentHint != null ? '${s.argumentHint}' : ''),
          insert: '\$${s.name} ',
          isSkill: true,
        ),
      );
    }
    return items;
  }

  /// Dedicated skill picker so skills are one tap away (no `/` guessing).
  void _openSkillsPicker() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => _SkillsPickerSheet(
        skills: _skills,
        loading: _skillsLoading,
        onSelect: (skill) {
          _inputController.text = '\$${skill.name} ';
          _inputController.selection = TextSelection.collapsed(
            offset: _inputController.text.length,
          );
          Navigator.of(context).pop();
          setState(() => _showSlash = false);
        },
        onRefresh: _loadPrep,
      ),
    );
  }

  /// Usage sheet (R7): one fresh entitlement fetch per open feeds the limit
  /// columns and the reset countdown; the sheet then renders that snapshot
  /// without polling.
  Future<void> _showUsageSheet() async {
    final state = _state;
    if (state == null) return;
    final controller = widget.gateway.quotaResetController;
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

  /// Subagent management sheet (internal-task): running
  /// actions + ended rows + older-history paging. Anchored to the chat
  /// route's navigator (`useRootNavigator: false`) so it stays inside the
  /// dual-pane chat pane (chat-conventions §6).
  void _showSubagentSheet() {
    final state = _state;
    if (state == null || !mounted) return;
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: false,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => _SubagentSheet(
        state: state,
        gateway: widget.gateway,
        feed: _feed,
        confirmWindow: widget.turnFooterConfirmWindow,
      ),
    );
  }

  Future<void> _showPlansSheet() async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    try {
      final plans = await widget.gateway.conversationCommands.plans(sessionId);
      if (!mounted) return;
      showModalBottomSheet(
        context: context,
        showDragHandle: true,
        builder: (context) =>
            _JsonSheet(title: tr(context, 'chat.plans'), data: plans),
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
      tr(context, 'tasks.opFailed'),
      () => widget.gateway.renameTask(sessionId, text),
    );
  }

  void _copySessionId() {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    Clipboard.setData(ClipboardData(text: sessionId));
    _toast(tr(context, 'chat.more.idCopied'));
  }

  void _copyWorkspacePath() {
    final path = widget.gateway.workspacePath;
    if (path == null || path.isEmpty) {
      _toast(tr(context, 'chat.more.noPath'));
      return;
    }
    Clipboard.setData(ClipboardData(text: path));
    _toast(tr(context, 'chat.more.pathCopied'));
  }

  void _copyTaskLink() {
    final sessionId = _sessionId;
    final base = widget.gateway.remoteUrl;
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
            tr(context, 'tasks.opFailed'),
            () => widget.gateway.setTaskPinned(sessionId, target),
          );
          setState(() => _pinned = target);
        }
      case 'archive':
        if (sessionId != null) {
          _run(
            tr(context, 'tasks.opFailed'),
            () => widget.gateway.setTaskArchived(sessionId, true),
          );
        }
      case 'unread':
        if (sessionId != null) {
          _run(
            tr(context, 'tasks.opFailed'),
            () => widget.gateway.setTaskUnread(sessionId, true),
          );
        }
      case 'copyPath':
        _copyWorkspacePath();
      case 'copyId':
        _copySessionId();
      case 'copyLink':
        _copyTaskLink();
      case 'compact':
        if (sessionId != null) {
          _run(
            tr(context, 'chat.compact.failed'),
            () => widget.gateway.conversationCommands.compact(sessionId),
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

  /// Delete confirmation (confirmDialog.taskDelete*): the session
  /// is removed from the workspace and records cannot be recovered. Pops
  /// the chat page after success.
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
    await _run(
      tr(context, 'tasks.opFailed'),
      () => widget.gateway.conversationCommands.deleteSession(sessionId),
    );
    if (mounted) Navigator.of(context).maybePop();
  }

  /// Menu order: pin toggle / rename / archive / unread, then the
  /// copy actions; client-only extras (link, compact, usage, plans) trail.
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
          final groups = _groupRows(state.rows);
          final itemCount = groups.length + (state.canLoadOlder ? 1 : 0);
          if (groups.isEmpty && !state.canLoadOlder) {
            // Empty conversation — or the shell-session start-failure card
            // (design 09-25 D1/D2). The gate reads the task displayStatus
            // view, which refreshes on the gateway's notifier, not on
            // [state] — hence the double-listen (Listenable.merge).
            return AnimatedBuilder(
              animation: Listenable.merge([state, widget.gateway]),
              builder: (context, _) => _emptyOrStartFailed(context, state),
            );
          }
          return _contentCol(
            NotificationListener<ScrollNotification>(
              onNotification: _onListScroll,
              // Prepend veil (see [_listVeiled], round 21) + frozen frame
              // (round 24): the veil hides only the PAINT — layout and the
              // anchor measurement run normally underneath, so the measured
              // landing happens off-screen. The frozen capture of the last
              // pre-prepend frame is drawn OVER the veil (Stack): the same
              // pixels stand still until the landing lifts it — no blank
              // flash, no wrong-guess frame.
              child: Stack(
                fit: StackFit.passthrough,
                children: [
                  RepaintBoundary(
                    key: _freezeKey,
                    child: Opacity(
                      opacity: _listVeiled ? 0.0 : 1.0,
                      child: ListView.builder(
                        key: _listKey,
                        controller: _scrollController,
                        scrollCacheExtent: _anchorCacheExtent == null
                            ? null
                            : ScrollCacheExtent.pixels(_anchorCacheExtent!),
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
                                onPressed: _loadingOlder ? null : _loadOlder,
                                icon: _loadingOlder
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
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (divider != null) _TimeDivider(label: divider),
                              // Stable identity for the history anchor
                              // compensation: keyed by the turn's first row
                              // so [_compensateAnchor] can re-find the same
                              // group after a prepend remounts the window.
                              // The load-older button row stays unkeyed.
                              _TurnGroupWidget(
                                key: ValueKey('turn-${group.first['rowId']}'),
                                rows: group,
                                gateway: widget.gateway,
                                sessionId: _sessionId ?? '',
                                onAction: _run,
                                state: state,
                                feed: _feed,
                                preview: _preview,
                                confirmWindow: widget.turnFooterConfirmWindow,
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                  if (_frozenFrame != null)
                    Positioned.fill(
                      child: RawImage(
                        image: _frozenFrame,
                        fit: BoxFit.fill,
                      ),
                    ),
                ],
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
        widget.gateway.taskDisplayStatus(sessionId) == 'error';
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
          _GoalBanner(state: state),
          _GoalProcessPanel(
            state: state,
            gateway: widget.gateway,
            feed: _feed,
          ),
          _BackgroundWorksBar(state: state, gateway: widget.gateway),
          _QueueBar(state: state, gateway: widget.gateway),
          _PendingInteractions(state: state, gateway: widget.gateway),
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
      return widget.gateway.conversationCommands.session.degraded;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    // Short viewport (landscape phones, folding half-open): the second
    // header row drops its secondary workspace chip to keep the breadcrumb
    // title readable without stealing message height (portrait phones are
    // ~844 tall and never trigger).
    final short = MediaQuery.heightOf(context) < 480;
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
        title: Text(tr(context, 'chat.appBar')),
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
        ],
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: Column(
          children: [
            // Second header row: task title + workspace chip + 更多.
            _contentCol(
              Padding(
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
                    if (!short &&
                        widget.workspaceLabel != null &&
                        widget.workspaceLabel!.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
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
                                widget.workspaceLabel!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: ZType.sub.copyWith(
                                  color: ZInk.muted(context),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    PopupMenuButton<String>(
                      tooltip: tr(context, 'chat.more'),
                      onSelected: _onMoreMenu,
                      itemBuilder: _moreMenuItems,
                      position: PopupMenuPosition.under,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              tr(context, 'chat.more'),
                              style: ZType.body.copyWith(
                                color: ZColors.sky500,
                              ),
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
              ),
            ),
            if (_error != null)
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
                        tr(context, 'chat.quota.exhaustedTitle'),
                        style: ZType.sub.copyWith(
                          fontWeight: FontWeight.w600,
                          color: ZInk.dangerTone(context),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        tr(context, 'chat.quota.exhaustedBody'),
                        style: ZType.caption.copyWith(color: ZInk.muted(context)),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 8),
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
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 8),
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
              animation: widget.gateway,
              builder: (context, _) => _GatewayBanner(gateway: widget.gateway),
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
                onRemove: (i) => setState(() => _pendingFiles.removeAt(i)),
              ),
            // Locally-queued replayable messages (3.12.3): sits directly
            // above the composer like the pendingCommands cards.
            // Null queue (pre-3.12.3 desktop / not connected) renders nothing.
            AnimatedBuilder(
              animation: widget.gateway,
              builder: (context, _) {
                final replayable = widget.gateway.replayableQueue;
                if (replayable == null) return const SizedBox.shrink();
                return AnimatedBuilder(
                  animation: replayable,
                  builder: (context, _) => _ReplayableQueueBar(queue: replayable),
                );
              },
            ),
            AnimatedBuilder(
              animation: (state == null)
                ? widget.gateway
                : Listenable.merge([state, widget.gateway]),
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
                    gateway: widget.gateway,
                    sessionId: _sessionId,
                    feed: state == null ? null : _feed,
                    subagentConfirmWindow: widget.turnFooterConfirmWindow,
                    onSend: _send,
                    onAttach: _pickFiles,
                    onSkills: _openSkillsPicker,
                    onModelSheet: _showModelSheet,
                    onUsage: _showUsageSheet,
                    onSubagents: _showSubagentSheet,
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
      child: AnimatedBuilder(
        animation: widget.gateway,
        builder: (context, _) => widget.gateway.kicked
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
                    tr(context, 'tasks.opFailed'),
                    widget.gateway.reconnect,
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
    final prevAt = _rowTimestamp(previous?.first);
    final at = _rowTimestamp(group.first);
    if (at == null) return null;
    if (prevAt != null && at - prevAt < 10 * 60 * 1000) return null;
    final time = DateTime.fromMillisecondsSinceEpoch(at).toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}';
  }

  static int? _rowTimestamp(Map<String, dynamic>? row) {
    if (row == null) return null;
    for (final key in const ['createdAt', 'sentAt', 'at']) {
      final v = row[key];
      if (v is num && v > 0) return v.toInt();
    }
    return null;
  }
}

/// ------------------------------------------------------- keyboard scope

/// Publishes the keyboard-open state to the strip slots via [_KeyboardScope].
/// Deliberately the only widget in the page that depends on the IME inset
/// (besides the Scaffold's own layout): the animation delivers a fresh inset
/// every frame for ~300ms, and a dependency in ChatPage.build would rebuild
/// the whole page per frame (2026-09-20 真机掉帧). This probe rebuilds
/// instead and returns the identical child widget, so Element updates
/// short-circuit below it; the scope only notifies its dependents when the
/// boolean flips.
class _KeyboardProbe extends StatefulWidget {
  const _KeyboardProbe({required this.child});

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
    _open = MediaQuery.viewInsetsOf(context).bottom > 0;
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
class _GatewayBanner extends StatelessWidget {
  final ChatGateway gateway;

  const _GatewayBanner({required this.gateway});

  @override
  Widget build(BuildContext context) {
    if (gateway.kicked || gateway.status != DeviceStatus.connecting) {
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

/// One ordered part of an assistant turn: either a merged text segment
/// (kind == 'text') or a non-text row (kind == 'row').
typedef AssistantPart = ({
  String kind,
  String? text,
  Map<String, dynamic>? row,
  List<Map<String, dynamic>>? group,
  bool streaming,
});

/// Provider business-error translation (web `zcode.error.providerBusiness.*`):
/// model-request failures carry a numeric code (1005 免费额度, 1006 登录失效,
/// 3002/429 限流, 3006 模型不在范围, 3007 验证码, 3008-3010 系统繁忙, 2007 服务端
/// 不可用). When the failure text mentions one, show the known line
/// instead of the raw transport error.
///
/// Takes a locale (not a BuildContext) so it stays a pure function; the
/// `chat.bizErr.*` table entries supply the copy.
String? businessErrorCopy(String errorText, String locale) {
  final m = RegExp(r'\b(1006|1005|3006|3001|3007|3008|3009|3010|3002|2007|429)\b')
      .firstMatch(errorText);
  if (m == null) return null;
  final key = {
    '1006': 'chat.bizErr.loginExpired',
    '1005': 'chat.bizErr.quotaExhausted',
    '3006': 'chat.bizErr.modelNotInPlan',
    '3001': 'chat.bizErr.invalidParams',
    '3007': 'chat.bizErr.verificationRequired',
    '3008': 'chat.bizErr.serviceBusy',
    '3009': 'chat.bizErr.serviceBusy',
    '3010': 'chat.bizErr.serviceBusy',
    '3002': 'chat.bizErr.rateLimited',
    '2007': 'chat.bizErr.upstreamUnavailable',
    '429': 'chat.bizErr.rateLimited',
  }[m.group(1)];
  if (key == null) return null;
  final retryLater = trLocale(locale, 'common.retryLater');
  return '${trLocale(locale, key)} ($retryLater)';
}

/// Plain-language rewrite for command errors surfaced in snack bars: with
/// the link down / the bridge dead, commands throw
/// `StateError('not connected')` (toString: `Bad state: …`) or
/// `TimeoutException`, and the desktop answers with its raw
/// workspace-reconnect line — `'$e'` in a SnackBar reads like crash
/// output (PRD internal-task R3). Returns the mapped copy, or
/// null for unknown shapes so callers keep the raw text (logged via
/// debugPrint at each call site). Takes a locale (not a BuildContext) so
/// it stays a pure function, like [businessErrorCopy].
String? commandErrorCopy(String errorText, String locale) {
  final t = errorText.toLowerCase();
  if (t.contains('bad state:') || t.contains('not connected')) {
    return trLocale(locale, 'chat.error.notConnected');
  }
  if (t.contains('timeoutexception') || t.contains('timed out')) {
    return trLocale(locale, 'chat.error.timeout');
  }
  return null;
}

/// Splits an assistant-turn group into ORDERED parts — consecutive
/// assistantText rows merge into one text segment, while reasoning/tool/
/// subagent rows stay exactly where they occurred in the stream (so
/// "thinking → tool → answer" never renders as "answer → thinking").
typedef AssistantTurnParts = ({
  List<AssistantPart> parts,
  Map<String, dynamic>? header,
  bool streaming,
});

/// Locale for the pure copy lookups (tool_row_semantics) at sites that
/// hold a BuildContext but render through the module, not `tr`.
String _localeOf(BuildContext context) =>
    UiSettingsProvider.of(context)?.locale ?? 'zh-CN';

/// turnHeader states whose footer (terminal pill + feedback row) is gated
/// behind the confirm window (see _TurnGroupWidgetState).
const turnTerminalPhases = {
  'completedSuccess',
  'completedInterrupted',
  'failed',
  'error',
};

/// Live action text of a running subagent: the child session's LAST
/// toolCall — `inputStreaming` with empty input → 「准备执行…」, otherwise
/// the shared per-tool summary (已写入 x / 终端 · cmd / …, live-probed row
/// shapes 2026-09-16). null when the child snapshot hasn't landed or has no
/// toolCall yet — callers fall back to the title / parent-side summaryText.
String? subagentActionText(BuildContext context, ConversationState? child) {
  if (child == null || !child.ready) return null;
  for (final row in child.rows.reversed) {
    if (row['kind'] != 'toolCall') continue;
    if ('${row['status'] ?? ''}' == 'inputStreaming' &&
        '${row['inputText'] ?? ''}'.isEmpty) {
      return tr(context, 'chat.subagent.preparing');
    }
    return toolRowSemantics(row, locale: _localeOf(context)).title;
  }
  return null;
}

/// The `kind=='subagent'` stream row spawned by an Agent tool call, linked
/// via parentToolCallId ↔ toolCallId (live-probed 2026-09-16); carries the
/// childSessionId/workId needed for the detail-page entry.
Map<String, dynamic>? _subagentRowFor(
  List<Map<String, dynamic>> rows,
  Map<String, dynamic> toolRow,
) {
  final id = '${toolRow['toolCallId'] ?? ''}';
  if (id.isEmpty) return null;
  for (final r in rows) {
    if (r['kind'] == 'subagent' && '${r['parentToolCallId'] ?? ''}' == id) {
      return r;
    }
  }
  return null;
}

AssistantTurnParts assistantTurnParts(List<Map<String, dynamic>> rows) {
  final parts = <AssistantPart>[];
  Map<String, dynamic>? header;
  StringBuffer? buf;
  Map<String, dynamic>? template;
  var anyStream = false;
  var sawStreaming = false;
  final executeRun = <Map<String, dynamic>>[];

  void flushText() {
    if (template != null) {
      final text = buf!.toString().trim();
      if (text.isNotEmpty) {
        parts.add((
          kind: 'text',
          text: text,
          row: template,
          group: null,
          streaming: anyStream,
        ));
      }
      buf = null;
      template = null;
      anyStream = false;
    }
  }

  void flushExecuteRun() {
    if (executeRun.isEmpty) return;
    if (executeRun.length == 1) {
      parts.add((
        kind: 'row',
        text: null,
        row: executeRun.single,
        group: null,
        streaming: false,
      ));
    } else {
      parts.add((
        kind: 'rowGroup',
        text: null,
        row: executeRun.first,
        group: List.of(executeRun),
        streaming: false,
      ));
    }
    executeRun.clear();
  }

  for (final row in rows) {
    final kind = row['kind'];
    if (kind == 'assistantText') {
      flushExecuteRun();
      template ??= row;
      buf ??= StringBuffer();
      final t = row['text'] as String? ?? '';
      if (buf!.isNotEmpty) buf!.write('\n\n');
      buf!.write(t);
      if (row['state'] == 'streaming') {
        anyStream = true;
        sawStreaming = true;
      }
    } else if (kind == 'turnHeader') {
      header = row;
    } else if (isExecuteTool(row)) {
      flushText();
      executeRun.add(row);
    } else {
      flushExecuteRun();
      parts.add((
        kind: 'row',
        text: null,
        row: row,
        group: null,
        streaming: false,
      ));
    }
  }
  flushText();
  flushExecuteRun();
  return (parts: parts, header: header, streaming: sawStreaming);
}

/// Groups rows into turns (like the web timeline): a user message starts
/// a new group; assistant text/reasoning/tool rows that follow belong to
/// the same turn and render as ONE message instead of many bubbles.
///
/// A new group starts only on a user message (or the first assistant row
/// after one). Consecutive assistant rows are merged into a single group
/// EVEN IF the server bumps `turnId` mid-response, so one answer never
/// splits into several bubbles each carrying its own feedback buttons.
List<List<Map<String, dynamic>>> _groupRows(List<Map<String, dynamic>> rows) {
  final groups = <List<Map<String, dynamic>>>[];
  List<Map<String, dynamic>>? current;
  for (final row in rows) {
    final kind = row['kind'];
    if (kind == 'timelineMarker') {
      current = null;
      groups.add([row]);
      continue;
    }
    final isUser = kind == 'userInput';
    final startsGroup =
        isUser || current == null || current.first['kind'] == 'userInput';
    if (startsGroup) {
      current = [row];
      groups.add(current);
    } else {
      current.add(row);
    }
  }
  return groups;
}

class _TurnGroupWidget extends StatefulWidget {
  final List<Map<String, dynamic>> rows;
  final ChatGateway gateway;
  final String sessionId;
  final Future<void> Function(String, Future<dynamic> Function()) onAction;
  final ConversationState state;
  final SubagentFeed feed;

  /// Workspace file-preview plumbing (markdown images, tappable file
  /// entries) — shared across all turn groups of the page.
  final _ChatPreview preview;

  /// Terminal-footer confirm window (see [_TurnGroupWidgetState]).
  final Duration confirmWindow;

  const _TurnGroupWidget({
    super.key,
    required this.rows,
    required this.gateway,
    required this.sessionId,
    required this.onAction,
    required this.state,
    required this.feed,
    required this.preview,
    required this.confirmWindow,
  });

  @override
  State<_TurnGroupWidget> createState() => _TurnGroupWidgetState();
}

/// One turn group: user bubble (if any) → turn header (已工作 N + pill,
/// rendered at the TOP of the turn) → ordered assistant parts →
/// file-changes card (always-visible rounded bar with 撤销).
class _TurnGroupWidgetState extends State<_TurnGroupWidget> {
  bool _showChanges = true;

  Timer? _terminalTimer;

  /// Whether the turn's terminal footer (terminal phase pill + feedback
  /// row) may render — see [_reconcileTerminal].
  bool _terminalConfirmed = false;

  @override
  void initState() {
    super.initState();
    // A terminal phase observed on the FIRST build (history / snapshot) has
    // no running predecessor to protect — render its footer immediately.
    _terminalConfirmed =
        turnTerminalPhases.contains(_headerPhase ?? '');
  }

  @override
  void didUpdateWidget(_TurnGroupWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    _reconcileTerminal();
  }

  @override
  void dispose() {
    _terminalTimer?.cancel();
    super.dispose();
  }

  String? get _headerPhase {
    for (final row in widget.rows) {
      if (row['kind'] == 'turnHeader') return row['state'] as String? ?? '';
    }
    return null;
  }

  /// Whether the feedback row stays hidden: the turn has a header and is
  /// either still running or inside the terminal confirm window. Headerless
  /// groups keep the legacy not-streaming behavior (no header → no gate).
  bool get _feedbackLocked {
    final phase = _headerPhase;
    if (phase == null) return false;
    if (phase == 'running') return true;
    if (turnTerminalPhases.contains(phase)) return !_terminalConfirmed;
    return false;
  }

  /// Terminal-footer gate (F): a turnHeader going terminal mid-session must
  /// persist for [widget.confirmWindow] before the phase pill and feedback
  /// row render. Bridge degradations replay a finished turn as terminal for
  /// a few seconds while the session lives on, which flashed 「已结束」+
  /// feedback buttons on a running conversation (user report 2026-09-16).
  /// The window anchors once — repeated terminal frames don't postpone it.
  void _reconcileTerminal() {
    final terminal = turnTerminalPhases.contains(_headerPhase ?? '');
    if (!terminal) {
      _terminalTimer?.cancel();
      _terminalTimer = null;
      if (_terminalConfirmed) setState(() => _terminalConfirmed = false);
      return;
    }
    if (_terminalConfirmed || _terminalTimer != null) return;
    _terminalTimer = Timer(widget.confirmWindow, () {
      _terminalTimer = null;
      if (mounted && turnTerminalPhases.contains(_headerPhase ?? '')) {
        setState(() => _terminalConfirmed = true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final rows = widget.rows;
    final gateway = widget.gateway;
    final sessionId = widget.sessionId;
    final onAction = widget.onAction;
    // single timeline marker
    if (rows.length == 1 && rows.first['kind'] == 'timelineMarker') {
      return _TimelineMarkerWidget(row: rows.first);
    }
    final first = rows.first;
    final isUserTurn = first['kind'] == 'userInput';

    // The header row moves out of the stream so it renders at the top;
    // for user turns the bubble itself is rendered separately below.
    Map<String, dynamic>? header;
    final bodyRows = <Map<String, dynamic>>[];
    for (var i = 0; i < rows.length; i++) {
      if (isUserTurn && i == 0) continue;
      final row = rows[i];
      if (row['kind'] == 'turnHeader') {
        header = row;
      } else {
        bodyRows.add(row);
      }
    }

    final children = <Widget>[];

    if (isUserTurn) {
      children.add(
        _RowWidget(
          key: ValueKey('row-${first['rowId']}'),
          row: first,
          gateway: gateway,
          sessionId: sessionId,
          onAction: onAction,
          state: widget.state,
          preview: widget.preview,
          feed: widget.feed,
        ),
      );
    }
    if (header != null) {
      children.add(
        _TurnHeader(
          row: header,
          hasChanges: header['fileChanges'] is Map,
          expanded: _showChanges,
          onToggle: () => setState(() => _showChanges = !_showChanges),
          terminalConfirmed: _terminalConfirmed,
        ),
      );
    }

    // assistant parts in original order (reasoning → text → tool → text …);
    // feedback buttons appear only on the LAST text segment.
    final parts = assistantTurnParts(bodyRows);
    var lastTextIdx = -1;
    for (var i = 0; i < parts.parts.length; i++) {
      if (parts.parts[i].kind == 'text') lastTextIdx = i;
    }
    for (var i = 0; i < parts.parts.length; i++) {
      final p = parts.parts[i];
      if (p.kind == 'text') {
        children.add(
          _RowWidget(
            key: p.row == null ? null : ValueKey('row-${p.row!['rowId']}'),
            row: {
              ...?p.row,
              'kind': 'assistantText',
              'text': p.text,
              if (p.streaming) 'state': 'streaming',
            },
            showFeedback: i == lastTextIdx,
            gateway: gateway,
            sessionId: sessionId,
            onAction: onAction,
            state: widget.state,
            preview: widget.preview,
            feed: widget.feed,
            turnFeedbackLocked: _feedbackLocked,
          ),
        );
      } else if (p.kind == 'rowGroup') {
        children.add(
          _ToolGroupCard(
            key: ValueKey(
              'row-${(p.group ?? [if (p.row != null) p.row!]).first['rowId']}',
            ),
            rows: p.group ?? [if (p.row != null) p.row!],
            gateway: gateway,
            sessionId: sessionId,
            onAction: onAction,
            state: widget.state,
            preview: widget.preview,
            feed: widget.feed,
          ),
        );
      } else {
        children.add(
          _RowWidget(
            key: ValueKey('row-${p.row!['rowId']}'),
            row: p.row!,
            showFeedback: false,
            gateway: gateway,
            sessionId: sessionId,
            onAction: onAction,
            state: widget.state,
            preview: widget.preview,
            feed: widget.feed,
          ),
        );
      }
    }

    // File-changes card at the end of the turn.
    final fileChanges = header?['fileChanges'];
    if (fileChanges is Map && _showChanges) {
      children.add(
        _FileChangesBar(
          changes: fileChanges.cast<String, dynamic>(),
          gateway: gateway,
          sessionId: sessionId,
          row: header!,
          onAction: onAction,
        ),
      );
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

class _RowWidget extends StatelessWidget {
  final Map<String, dynamic> row;
  final ChatGateway gateway;
  final String sessionId;
  final Future<void> Function(String, Future<dynamic> Function()) onAction;
  final ConversationState state;
  final bool showFeedback;

  /// Shared child-session subscription pool (Agent tile expansion).
  final SubagentFeed? feed;

  /// Workspace file-preview plumbing (markdown images, tappable entries).
  final _ChatPreview preview;

  /// Whether the turn's feedback row stays hidden (running turn or terminal
  /// confirm window — see [_TurnGroupWidgetState._feedbackLocked]).
  final bool turnFeedbackLocked;

  const _RowWidget({
    super.key,
    required this.row,
    required this.gateway,
    required this.sessionId,
    required this.onAction,
    required this.state,
    required this.preview,
    this.showFeedback = true,
    this.feed,
    this.turnFeedbackLocked = false,
  });

  Map<String, dynamic> get _target => {
    'rowId': row['rowId'],
    if (row['entityId'] != null) 'entityId': row['entityId'],
  };

  void _showActions(BuildContext context) {
    final kind = row['kind'];
    if (kind != 'userInput' && kind != 'assistantText') return;
    HapticFeedback.mediumImpact();
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => zSheetScaffold(
        context,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (kind == 'userInput')
              ListTile(
                leading: const Icon(Icons.edit_outlined, size: 20),
                title: Text(tr(context, 'chat.action.editResend')),
                onTap: () {
                  Navigator.pop(context);
                  _editQuery(context);
                },
              ),
            ListTile(
              leading: const Icon(Icons.replay, size: 20),
              title: Text(tr(context, 'chat.action.retry')),
              onTap: () {
                Navigator.pop(context);
                onAction(
                  tr(context, 'chat.action.retry.failed'),
                  () => gateway.conversationCommands.retryTurn(sessionId, _target),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.fork_right, size: 20),
              title: Text(tr(context, 'chat.action.fork')),
              onTap: () {
                Navigator.pop(context);
                onAction(
                  tr(context, 'chat.action.fork.failed'),
                  () => gateway.conversationCommands.forkAssistant(sessionId, _target),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.history, size: 20),
              title: Text(tr(context, 'chat.action.rewind')),
              onTap: () {
                Navigator.pop(context);
                _confirmRewind(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.difference_outlined, size: 20),
              title: Text(tr(context, 'chat.action.fileChanges')),
              onTap: () {
                Navigator.pop(context);
                _showFileChanges(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editQuery(BuildContext context) async {
    final controller = TextEditingController(
      text: row['text'] as String? ?? '',
    );
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, 'chat.action.edit.title')),
        content: TextField(
          controller: controller,
          maxLines: 5,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr(context, 'devices.add.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(tr(context, 'chat.action.editResend')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.isEmpty || !context.mounted) return;
    await onAction(
      tr(context, 'chat.action.edit.failed'),
      () => gateway.conversationCommands.editUserQuery(sessionId, _target, text),
    );
  }

  Future<void> _confirmRewind(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, 'chat.action.rewind.title')),
        content: Text(tr(context, 'chat.action.rewind.body')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr(context, 'devices.add.cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: ZColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr(context, 'chat.action.rewind.confirm')),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await onAction(
      tr(context, 'chat.action.rewind.failed'),
      () => gateway.conversationCommands.applyFileRewind(sessionId, _target),
    );
  }

  Future<void> _showFileChanges(BuildContext context) async {
    try {
      final changes = await gateway.conversationCommands.fileChanges(sessionId, target: _target);
      if (!context.mounted) return;
      // Defensive parse → tappable file rows (design §4.4); anything not
      // file-row-shaped falls back to the raw JSON sheet (never worse than
      // before).
      final entries = parseFileChanges(changes);
      // Embedded/dual-pane contract: sheets stay on the local navigator
      // (chat-conventions §6 — root-navigator sheets render off-pane).
      showModalBottomSheet(
        context: context,
        showDragHandle: true,
        useRootNavigator: false,
        builder: (context) => entries == null
            ? _JsonSheet(
                title: tr(context, 'chat.action.fileChanges'),
                data: changes,
              )
            : _FileChangesSheet(
                title: tr(context, 'chat.action.fileChanges'),
                entries: entries,
                preview: preview,
              ),
      );
    } catch (e) {
      debugPrint('[chat] fileChanges: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              trP(context, 'chat.action.fileChanges.failed', [
                commandErrorCopy('$e', _localeOf(context)) ?? '$e',
              ]),
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final widget_ = switch (row['kind']) {
      'userInput' => _UserBubble(
        row: row,
        gateway: gateway,
        sessionId: sessionId,
      ),
      'assistantText' => _AssistantBubble(
        row: row,
        gateway: gateway,
        sessionId: sessionId,
        state: state,
        preview: preview,
        showFeedback: showFeedback,
        turnFeedbackLocked: turnFeedbackLocked,
      ),
      'reasoning' => _ReasoningTile(
        text: row['text'] as String? ?? '',
        streaming: row['state'] == 'streaming',
      ),
      'toolCall' => _ToolCallTile(
        row: row,
        preview: preview,
        gateway: gateway,
        sessionId: sessionId,
        // Agent rows drill into the subagent's child-session detail page.
        subagent: isAgentTool(row) ? _subagentRowFor(state.rows, row) : null,
        feed: feed,
      ),
      // turnHeader rows are lifted out of the stream by _TurnGroupWidget
      'turnHeader' => const SizedBox.shrink(),
      'subagent' => _SubagentTile(
        row: row,
        gateway: gateway,
        sessionId: sessionId,
        feed: feed,
      ),
      'timelineMarker' => _TimelineMarkerWidget(row: row),
      _ => const SizedBox.shrink(),
    };
    final kind = row['kind'];
    if (kind != 'userInput' && kind != 'assistantText') return widget_;
    return GestureDetector(
      onLongPress: () => _showActions(context),
      child: widget_,
    );
  }
}

class _UserBubble extends StatefulWidget {
  final Map<String, dynamic> row;
  final ChatGateway gateway;
  final String sessionId;

  const _UserBubble({
    required this.row,
    required this.gateway,
    required this.sessionId,
  });

  @override
  State<_UserBubble> createState() => _UserBubbleState();
}

class _UserBubbleState extends State<_UserBubble> {
  bool _expanded = false;

  static const _collapsedLines = 14;

  @override
  Widget build(BuildContext context) {
    final text = widget.row['text'] as String? ?? '';
    final attachments = widget.row['attachments'];
    final longText = '\n'.allMatches(text).length >= _collapsedLines;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.only(left: 56, top: 8, bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: ZInk.card(context),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(ZRadius.tile),
                topRight: Radius.circular(ZRadius.tile),
                bottomLeft: Radius.circular(ZRadius.tile),
                bottomRight: Radius.circular(ZRadius.mini),
              ),
              // Mock ruling 09-19: the light bubble is a white card and
              // needs the hairline to separate from the light background;
              // dark keeps the bare darkCard surface (zero dark delta).
              border: ZInk.isDark(context)
                  ? null
                  : Border.all(color: ZInk.hairline(context)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (attachments is List)
                  for (final a in attachments)
                    if (a is Map)
                      _AttachmentView(
                        attachment: a.cast<String, dynamic>(),
                        gateway: widget.gateway,
                        sessionId: widget.sessionId,
                      ),
                if (text.isNotEmpty)
                  // SelectableText with maxLines inflates to maxLines height
                  // inside unbounded parents (ListView) — cap collapsed long
                  // texts with a non-scrollable clip instead.
                  longText && !_expanded
                      ? ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxHeight: _collapsedLines * 21.0,
                          ),
                          child: SingleChildScrollView(
                            physics: const NeverScrollableScrollPhysics(),
                            child: SelectableText(
                              text,
                              style: ZType.body,
                            ),
                          ),
                        )
                      : SelectableText(
                          text,
                          style: ZType.body,
                        ),
                if (longText)
                  TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      minimumSize: Size.zero,
                    ),
                    onPressed: () {
                      HapticFeedback.lightImpact();
                      setState(() => _expanded = !_expanded);
                    },
                    child: Text(
                      _expanded
                          ? tr(context, 'chat.collapse')
                          : tr(context, 'chat.expand'),
                      style: ZType.caption,
                    ),
                  ),
              ],
            ),
          ),
        ),
        // copy / edit affordances sit OUTSIDE the bubble, bottom-right
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _MiniAction(
              icon: Icons.copy_outlined,
              tooltip: tr(context, 'chat.copy'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: text));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(tr(context, 'chat.copied')),
                    duration: const Duration(seconds: 1),
                  ),
                );
              },
            ),
            _MiniAction(
              icon: Icons.edit_outlined,
              tooltip: tr(context, 'chat.action.editResend'),
              onTap: () => _promptEdit(context),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _promptEdit(BuildContext context) async {
    final controller = TextEditingController(
      text: widget.row['text'] as String? ?? '',
    );
    final newText = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, 'chat.action.edit.title')),
        content: TextField(
          controller: controller,
          maxLines: 5,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr(context, 'devices.add.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(tr(context, 'chat.action.editResend')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newText == null || newText.isEmpty || !context.mounted) return;
    try {
      await widget.gateway.conversationCommands.editUserQuery(widget.sessionId, {
        'rowId': widget.row['rowId'],
        if (widget.row['entityId'] != null) 'entityId': widget.row['entityId'],
      }, newText);
    } catch (e) {
      debugPrint('[chat] editUserQuery: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              trP(context, 'chat.action.edit.failed', [
                commandErrorCopy('$e', _localeOf(context)) ?? '$e',
              ]),
            ),
          ),
        );
      }
    }
  }
}

class _MiniAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _MiniAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 14, color: ZInk.ghost(context)),
      tooltip: tooltip,
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
    );
  }
}

class _AttachmentView extends StatefulWidget {
  final Map<String, dynamic> attachment;
  final ChatGateway gateway;
  final String sessionId;

  const _AttachmentView({
    required this.attachment,
    required this.gateway,
    required this.sessionId,
  });

  @override
  State<_AttachmentView> createState() => _AttachmentViewState();
}

class _AttachmentViewState extends State<_AttachmentView> {
  Uint8List? _imageBytes;
  bool _failed = false;

  bool get _isImage =>
      '${widget.attachment['mime'] ?? ''}'.startsWith('image/');

  @override
  void initState() {
    super.initState();
    if (_isImage) _load();
  }

  Future<void> _load() async {
    final ref = widget.attachment['ref'] as String?;
    if (ref == null) return;
    try {
      final res = await widget.gateway.conversationCommands.attachmentRead(
        widget.sessionId,
        ref: ref,
      );
      if (mounted) setState(() => _imageBytes = res.bytes);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fileName = '${widget.attachment['fileName'] ?? ''}';
    if (!_isImage) {
      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: ZInk.tile(context),
          borderRadius: BorderRadius.circular(ZRadius.field),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.insert_drive_file_outlined,
              size: 16,
              color: ZInk.muted(context),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                fileName,
                style: ZType.sub.copyWith(color: ZInk.soft(context)),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }
    if (_failed) {
      return Text(
        trP(context, 'chat.attach.loadFailed', [fileName]),
        style: ZType.caption.copyWith(color: ZInk.faint(context)),
      );
    }
    if (_imageBytes == null) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 1.5),
        ),
      );
    }
    return Padding(
      // Gallery rhythm: consecutive image attachments in one bubble need a
      // clear seam (user feedback: 6px read as "glued together").
      padding: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          zRoute((_) =>
              ImageViewerPage(bytes: _imageBytes!, fileName: fileName)),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(ZRadius.field),
          child: Image.memory(_imageBytes!, width: 220, fit: BoxFit.cover),
        ),
      ),
    );
  }
}

/// Full-width assistant markdown (no bubble); feedback row (copy / like /
/// dislike / fork) hangs off the last text segment of a turn.
class _AssistantBubble extends StatelessWidget {
  final Map<String, dynamic> row;
  final ChatGateway gateway;
  final String sessionId;
  final ConversationState state;
  final bool showFeedback;

  /// Workspace file-preview plumbing (markdown images + link dispatch).
  final _ChatPreview preview;

  /// Whether the turn's feedback row stays hidden; while the turn runs or
  /// the confirm window holds, the copy/like/dislike/fork row is replaced
  /// by the in-progress spinner (a blip back to running must not flash the
  /// feedback UI, see _TurnGroupWidget).
  final bool turnFeedbackLocked;

  const _AssistantBubble({
    required this.row,
    required this.gateway,
    required this.sessionId,
    required this.state,
    required this.preview,
    this.showFeedback = true,
    this.turnFeedbackLocked = false,
  });

  void _setFeedback(String? value) {
    if (sessionId.isEmpty) return;
    // Optimistic: update the icon instantly; server row.upserted confirms.
    state.optimisticRowUpdate(row['rowId'] as num?, {'feedback': value});
    gateway.conversationCommands.setAssistantFeedback(sessionId, {
      'rowId': row['rowId'],
      if (row['entityId'] != null) 'entityId': row['entityId'],
    }, value);
  }

  @override
  Widget build(BuildContext context) {
    final text = row['text'] as String? ?? '';
    final streaming = row['state'] == 'streaming';
    final inProgress = streaming || turnFeedbackLocked;
    final feedback = row['feedback'] as String?;
    final timestamp = _ChatPageState._rowTimestamp(row);
    return Container(
      margin: const EdgeInsets.only(right: 24, top: 8, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppMarkdown(
            text,
            imageResolver: preview.resolveImage,
            onLinkTap: (href) => preview.openLink(context, href),
          ),
          if (showFeedback)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (inProgress)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    ),
                  )
                else ...[
                  _FeedbackButton(
                    icon: Icons.copy_outlined,
                    active: false,
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: text));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(tr(context, 'chat.copied')),
                          duration: const Duration(seconds: 1),
                        ),
                      );
                    },
                  ),
                  _FeedbackButton(
                    icon: Icons.thumb_up_alt_outlined,
                    active: feedback == 'like',
                    onTap: () =>
                        _setFeedback(feedback == 'like' ? null : 'like'),
                  ),
                  _FeedbackButton(
                    icon: Icons.thumb_down_alt_outlined,
                    active: feedback == 'dislike',
                    onTap: () =>
                        _setFeedback(feedback == 'dislike' ? null : 'dislike'),
                  ),
                  _FeedbackButton(
                    icon: Icons.fork_right,
                    active: false,
                    onTap: () => gateway.conversationCommands.forkAssistant(sessionId, {
                      'rowId': row['rowId'],
                      if (row['entityId'] != null) 'entityId': row['entityId'],
                    }),
                  ),
                ],
                const Spacer(),
                if (timestamp != null && !inProgress)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      _formatClock(timestamp),
                      style: ZType.caption.copyWith(color: ZInk.ghost(context)),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  static String _formatClock(int ms) {
    final time = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}';
  }
}

class _FeedbackButton extends StatelessWidget {
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  const _FeedbackButton({
    required this.icon,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(
        icon,
        size: 15,
        color: active ? ZColors.sky500 : ZInk.ghost(context),
      ),
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
    );
  }
}

/// Collapsible "思考过程" strip.
class _ReasoningTile extends StatelessWidget {
  final String text;
  final bool streaming;

  const _ReasoningTile({required this.text, this.streaming = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Turn-part rhythm: reasoning/tool/subagent blocks need a seam
      // between neighbours (0px margins read as glued together).
      padding: const EdgeInsets.only(bottom: ZTile.seam),
      child: Material(
        color: ZInk.tile(context),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZRadius.tile),
          side: BorderSide(color: ZInk.hairline(context)),
        ),
        child: ExpansionTile(
          dense: true,
          minTileHeight: ZTile.headHeight,
          onExpansionChanged: (_) => HapticFeedback.lightImpact(),
          tilePadding: ZTile.head,
          title: Row(
            children: [
              Icon(
                Icons.psychology_outlined,
                size: ZTile.iconSize,
                color: streaming ? ZColors.sky400 : ZInk.faint(context),
              ),
              const SizedBox(width: 8),
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
              padding: ZTile.body,
              child: AppMarkdown(text, bodyStyle: ZType.sub),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tool summary: icon + "已写入 file +N" / "终端 · cmd" /
/// "探索 · N 文件", expandable to input/output/diff. The diff body lives
/// INSIDE the expansion (collapsed by default — long agent dumps must not
/// flood the chat); the live progress row stays always visible.
class _ToolCallTile extends StatefulWidget {
  final Map<String, dynamic> row;

  /// Agent rows only: gateway/sessionId + [subagent] wire the tile's
  /// drill-in chevron to the child-session detail page.
  final ChatGateway? gateway;
  final String? sessionId;
  final Map<String, dynamic>? subagent;

  /// Agent rows only: the shared child-session pool backing the inline
  /// transcript in the expansion (see [_AgentChildTimeline]).
  final SubagentFeed? feed;

  /// Workspace file-preview plumbing (tappable file names).
  final _ChatPreview preview;

  const _ToolCallTile({
    required this.row,
    required this.preview,
    this.gateway,
    this.sessionId,
    this.subagent,
    this.feed,
  });

  @override
  State<_ToolCallTile> createState() => _ToolCallTileState();
}

class _ToolCallTileState extends State<_ToolCallTile> {
  /// Whether the ExpansionTile is open — the inline child transcript mounts
  /// only while expanded so its pooled subscription follows the expansion.
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final status = row['status'] as String? ?? '';
    final inputText = row['inputText'] as String? ?? '';
    final output = row['output'];
    final outputText = output is Map ? output['text'] as String? ?? '' : '';
    final error = row['error'];
    final progress = row['progress'];
    final display = row['display'];
    final diff = extractDiff(row);

    // Icon glyph comes from the module ([toolRowSemantics]); only the tint
    // stays here because it is theme-dependent.
    final color = switch (status) {
      'running' || 'inputStreaming' || 'pendingApproval' => ZColors.sky400,
      'success' => ZInk.successTone(context),
      'error' => ZInk.dangerTone(context),
      'cancelled' => ZInk.warningTone(context),
      _ => ZInk.faint(context),
    };

    final images =
        display is Map &&
            display['kind'] == 'node_repl_images' &&
            display['images'] is List
        ? display['images'] as List
        : const [];

    final summary = toolRowSemantics(row, locale: _localeOf(context));

    final agentPrompt = isAgentTool(row) ? promptOf(inputText) : null;
    final childSessionId = widget.subagent?['childSessionId'] as String?;
    final canOpen =
        widget.gateway != null && (childSessionId ?? '').isNotEmpty;

    // Tool row: bold-ish first line (已写入 <file> / 终端 · cmd /
    // 探索 · N 文件) with +/- counts right-aligned; second line = directory
    // path (write/edit) or the tool name. Previewable file names render as
    // a tappable span that dispatches into the preview surfaces (§4.4).
    final filePath = diff?.filePath ?? toolFilePath(inputText);
    final title = Row(
      children: [
        Expanded(
          child: _titleText(context, summary, filePath),
        ),
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
        if (canOpen)
          // chat.toolCall.agent.openInSidePane: on mobile the
          // drill-in affordance opens the child-session detail page. A
          // dedicated hit area keeps the header tap expanding the tile.
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _openSubagentDetail(
                context,
                widget.gateway!,
                childSessionId: childSessionId,
                title: widget.subagent?['summaryText'] as String?,
                subagentType: widget.subagent?['subagentType'] as String?,
                workId: widget.subagent?['workId'] as String?,
                parentSessionId: widget.sessionId,
                running: '${widget.subagent?['status'] ?? ''}' == 'running' ||
                    status == 'running' ||
                    status == 'pending',
              ),
              child: Icon(
                Icons.chevron_right,
                size: 18,
                color: ZInk.faint(context),
              ),
            ),
          ),
      ],
    );
    final subtitle = summary.subtitle == null
        ? null
        : Text(
            summary.subtitle!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ZType.caption.copyWith(
              color: ZInk.faint(context),
              fontFamily: 'monospace',
            ),
          );

    return Padding(
      // Turn-part rhythm: seam between neighbouring blocks (see _ReasoningTile).
      padding: const EdgeInsets.only(bottom: ZTile.seam),
      child: Material(
        color: ZInk.tile(context),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZRadius.tile),
          side: BorderSide(color: ZInk.hairline(context)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ListTile's defaults (40px leading box + 16px gap) would push the
            // title 36px further right than the other two tiles' headers.
            ListTileTheme.merge(
              horizontalTitleGap: 8,
              minLeadingWidth: ZTile.iconSize,
              child: ExpansionTile(
                dense: true,
                minTileHeight: ZTile.headHeight,
                onExpansionChanged: (value) {
                  HapticFeedback.lightImpact();
                  setState(() => _expanded = value);
                },
                tilePadding: ZTile.head,
                leading: Icon(summary.icon, size: ZTile.iconSize, color: color),
                title: title,
                subtitle: subtitle,
                children: [
                  // File edits show only the diff: the raw input/output JSON
                  // of a write/edit call is noise the web omits too.
                  // Agent rows expand to the dispatched prompt (web
                  // chat.toolCall.agent.prompt) instead of the raw JSON.
                  if (agentPrompt != null)
                    _kv(
                      context,
                      tr(context, 'chat.tool.agent.prompt'),
                      agentPrompt,
                    )
                  else if (diff == null && inputText.isNotEmpty)
                    _kv(
                      context,
                      tr(context, 'chat.tool.input'),
                      inputText,
                      openPath: toolFilePath(inputText),
                    ),
                  if (diff == null && outputText.isNotEmpty)
                    _kv(
                      context,
                      tr(context, 'chat.tool.output'),
                      outputText,
                      openPath: toolFilePath(outputText),
                    ),
                  if (error is Map)
                    _kv(
                      context,
                      tr(context, 'chat.tool.error'),
                      '${error['code'] ?? ''} ${error['message'] ?? ''}',
                    ),
                  // Diff/images live INSIDE the expansion so a collapsed
                  // tool call shows only the "已写入 file +N" summary line.
                  if (diff != null)
                    Padding(
                      padding: ZTile.body,
                      child: DiffView(diff: diff),
                    ),
                  for (final image in images)
                    if (image is Map && image['base64'] is String)
                      Padding(
                        padding: ZTile.body,
                        child: InkWell(
                          onTap: () => Navigator.of(context).push(
                            zRoute(
                              (_) => ImageViewerPage(
                                bytes: base64Decode(
                                    image['base64'] as String),
                              ),
                            ),
                          ),
                          child: ClipRRect(
                            borderRadius:
                                BorderRadius.circular(ZRadius.field),
                            // Same floor/cap as markdown images: a decode
                            // -pending or tiny intrinsic image still owns a
                            // real tap box; big screenshots stay tile-sized.
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                  minHeight: 48, maxHeight: 320),
                              child: Image.memory(
                                base64Decode(image['base64'] as String),
                                fit: BoxFit.contain,
                                width: double.infinity,
                                errorBuilder:
                                    (context, error, stackTrace) =>
                                        const SizedBox.shrink(),
                              ),
                            ),
                          ),
                        ),
                      ),
                  // Inline child transcript (web childToolCalls):
                  // mounted only while expanded so the pooled child
                  // subscription follows the expansion.
                  if (_expanded &&
                      widget.feed != null &&
                      (childSessionId ?? '').isNotEmpty)
                    _AgentChildTimeline(
                      feed: widget.feed!,
                      childSessionId: childSessionId!,
                    ),
                ],
              ),
            ),
            // Live progress stays visible while collapsed.
            if (progress is Map) _ProgressRow(progress: progress),
          ],
        ),
      ),
    );
  }

  /// The summary first line: plain text, or — when the row's file is
  /// previewable (raster image / html, the PRD's dispatch set) — the file
  /// name segment wrapped in a tappable span dispatching into the preview
  /// surfaces (design §4.4 工具行入口). Non-previewable rows keep the
  /// plain title (no dead links).
  Widget _titleText(
    BuildContext context,
    ToolRowSemantics summary,
    String? filePath,
  ) {
    final style = ZType.body.copyWith(
      fontWeight: FontWeight.w500,
      color: ZInk.solid(context),
    );
    final title = summary.title;
    if (filePath == null || !_ChatPreview.dispatchable(filePath)) {
      return Text(title,
          maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
    }
    final base = filePath.split(RegExp(r'[\\/]')).last;
    final i = title.indexOf(base);
    if (i < 0) {
      return Text(title,
          maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
    }
    return Text.rich(
      TextSpan(
        style: style,
        children: [
          TextSpan(text: title.substring(0, i)),
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: InkWell(
              onTap: () => widget.preview.open(context, filePath),
              child: Text(
                base,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style.copyWith(color: ZColors.sky500),
              ),
            ),
          ),
          TextSpan(text: title.substring(i + base.length)),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _kv(BuildContext context, String label, String value,
      {String? openPath}) {
    // Pretty-print JSON input when possible (structured view)
    var display = value;
    try {
      final decoded = jsonDecode(value);
      display = const JsonEncoder.withIndent('  ').convert(decoded);
    } catch (_) {}
    final tappable = openPath != null && _ChatPreview.dispatchable(openPath);
    final openBase =
        tappable ? openPath.split(RegExp(r'[\\/]')).last : null;
    return Padding(
      padding: ZTile.body,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: ZType.caption.copyWith(color: ZInk.faint(context)),
          ),
          if (tappable)
            // Expansion-entry variant of the §4.4 dispatch: the input kv's
            // path, rendered as an explicit open affordance above the raw
            // JSON (kept selectable below).
            InkWell(
              onTap: () => widget.preview.open(context, openPath),
              // Vertical padding lifts the 12px affordance to a ≥28px hit
              // area (dense-micro exception tier, design-tokens §6).
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                    children: [
                    Tooltip(
                      message: tr(context, 'chat.preview.openFile'),
                      child: Icon(
                        Icons.open_in_new,
                        size: 12,
                        color: ZColors.sky500,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        openBase!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ZType.caption.copyWith(
                          fontFamily: 'monospace',
                          color: ZColors.sky500,
                        ),
                      ),
                    ),
                    const SizedBox(width: 1),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 2),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: ZInk.codeBlockBg(context),
              borderRadius: BorderRadius.circular(ZRadius.field),
            ),
            child: SelectableText(
              display.length > 4000
                  ? '${display.substring(0, 4000)}…'
                  : display,
              style: ZType.caption.copyWith(
                fontFamily: 'monospace',
                color: ZInk.solid(context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Inline child-session transcript inside an expanded Agent tile: holds a
/// pooled child subscription for the mount duration ([SubagentFeed.acquire]
/// on init, [SubagentFeed.release] on dispose) and renders the simplified
/// timeline (same row renderer as the detail page) plus the 「输出」preview
/// = the child's last assistantText.
class _AgentChildTimeline extends StatefulWidget {
  final SubagentFeed feed;
  final String childSessionId;

  const _AgentChildTimeline({
    required this.feed,
    required this.childSessionId,
  });

  @override
  State<_AgentChildTimeline> createState() => _AgentChildTimelineState();
}

class _AgentChildTimelineState extends State<_AgentChildTimeline> {
  @override
  void initState() {
    super.initState();
    widget.feed.acquire(widget.childSessionId);
  }

  @override
  void didUpdateWidget(_AgentChildTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.childSessionId != widget.childSessionId) {
      oldWidget.feed.release(oldWidget.childSessionId);
      widget.feed.acquire(widget.childSessionId);
    }
  }

  @override
  void dispose() {
    widget.feed.release(widget.childSessionId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final feed = widget.feed;
    return AnimatedBuilder(
      animation: Listenable.merge([feed, feed.childState(widget.childSessionId)]),
      builder: (context, _) {
        final child = feed.childState(widget.childSessionId);
        if (child == null || !child.ready) {
          // Snapshot not in yet (subscribe ack → snapshot lands in well
          // under a second live) — a hairline spinner beats a blank body.
          return const Padding(
            padding: ZTile.body,
            child: SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            ),
          );
        }
        String? output;
        for (final row in child.rows.reversed) {
          if (row['kind'] == 'assistantText') {
            output = row['text'] as String? ?? '';
            break;
          }
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (output != null && output.trim().isNotEmpty)
              Padding(
                padding: ZTile.body,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr(context, 'chat.tool.output'),
                      style:
                          ZType.caption.copyWith(color: ZInk.faint(context)),
                    ),
                    const SizedBox(height: 2),
                    AppMarkdown(
                      output.length > 600
                          ? '${output.substring(0, 600)}…'
                          : output,
                      bodyStyle: ZType.sub,
                    ),
                  ],
                ),
              ),
            for (final row in child.rows) SubagentTimelineRow(row: row),
          ],
        );
      },
    );
  }
}

class _ProgressRow extends StatelessWidget {
  final Map progress;

  const _ProgressRow({required this.progress});

  @override
  Widget build(BuildContext context) {
    final bytes = (progress['bytes'] as num?)?.toInt() ?? 0;
    final preview = progress['previewLine'] as String? ?? '';
    return Padding(
      padding: ZTile.body,
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
              [
                if (preview.isNotEmpty) preview,
                '${(bytes / 1024).toStringAsFixed(1)} KB',
              ].join(' · '),
              style: ZType.caption.copyWith(color: ZInk.faint(context)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Turn footer: "已工作 N 分 N 秒" + chevron (expands file changes) and the
/// phase pill on the right.
/// Turn header at the TOP of a turn: 「已工作 N 分 N 秒」灰字 +
/// chevron (toggles the file-changes card), status pill on the right.
class _TurnHeader extends StatelessWidget {
  final Map<String, dynamic> row;
  final bool hasChanges;
  final bool expanded;
  final VoidCallback onToggle;

  /// Whether the terminal phase pill may render (see _TurnGroupWidget's
  /// confirm window); a running pill is never gated.
  final bool terminalConfirmed;

  const _TurnHeader({
    required this.row,
    required this.hasChanges,
    required this.expanded,
    required this.onToggle,
    this.terminalConfirmed = true,
  });

  @override
  Widget build(BuildContext context) {
    final phase = row['state'] as String? ?? '';
    final duration = _fmtDuration(context, (row['activeMs'] as num?)?.toInt());

    final phaseKey = switch (phase) {
      'running' => 'phase.running',
      'completedSuccess' => 'phase.completedSuccess',
      'completedInterrupted' => 'phase.completedInterrupted',
      'failed' || 'error' => 'phase.error',
      _ => null,
    };
    // Terminal pill only after the confirm window held (a blip back to
    // running inside the window must not flash 「已结束」).
    final showPill = phaseKey != null &&
        (terminalConfirmed || !turnTerminalPhases.contains(phase));

    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Row(
        children: [
          if (duration.isNotEmpty)
            Text(
              trP(context, 'chat.turn.worked', [duration]),
              style: ZType.caption.copyWith(color: ZInk.faint(context)),
            ),
          if (hasChanges)
            InkWell(
              onTap: () {
                HapticFeedback.lightImpact();
                onToggle();
              },
              child: SizedBox(
                width: zTouchWidth,
                height: zTouchHeight,
                child: Center(
                  child: Icon(
                    expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 16,
                    color: ZInk.ghost(context),
                  ),
                ),
              ),
            ),
          const Spacer(),
          if (showPill) PhasePill(label: tr(context, phaseKey), phase: phase),
        ],
      ),
    );
  }

  static String _fmtDuration(BuildContext context, int? ms) {
    if (ms == null || ms < 0) return '';
    final s = (ms / 1000).round();
    if (s < 60) return trP(context, 'chat.time.secOnly', ['$s']);
    return trP(context, 'chat.time.minSec', ['${s ~/ 60}', '${s % 60}']);
  }
}

/// "N 个文件已更改 +8 -12" card with a 撤销 (rewind) button.
class _FileChangesBar extends StatelessWidget {
  final Map<String, dynamic> changes;
  final ChatGateway gateway;
  final String sessionId;
  final Map<String, dynamic> row;
  final Future<void> Function(String, Future<dynamic> Function()) onAction;

  const _FileChangesBar({
    required this.changes,
    required this.gateway,
    required this.sessionId,
    required this.row,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final adds = (changes['additions'] as num?)?.toInt() ?? 0;
    final dels = (changes['deletions'] as num?)?.toInt() ?? 0;
    final files = (changes['files'] as num?)?.toInt() ?? 0;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: ZInk.tile(context),
        borderRadius: BorderRadius.circular(ZRadius.field),
        border: Border.all(color: ZInk.hairline(context)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text.rich(
              TextSpan(
                text: trP(context, 'chat.files.changed', ['$files']),
                style: ZType.sub.copyWith(color: ZInk.soft(context)),
                children: [
                  if (adds > 0)
                    TextSpan(
                      text: '  +$adds',
                      style: TextStyle(color: ZInk.successTone(context)),
                    ),
                  if (dels > 0)
                    TextSpan(
                      text: '  -$dels',
                      style: TextStyle(color: ZInk.dangerTone(context)),
                    ),
                ],
              ),
            ),
          ),
          TextButton(
            onPressed: () => _rewindWithPreview(context),
            child: Text(
              tr(context, 'chat.files.undo'),
              style: ZType.sub,
            ),
          ),
        ],
      ),
    );
  }

  /// Web rewind precheck: conversationFileRewindPreviewV4 runs before any
  /// write. The dialog reports what the desktop returned; a preview that
  /// reports unrewritable files (or errors) blocks the rewind entirely.
  Future<void> _rewindWithPreview(BuildContext context) async {
    final target = {
      'rowId': row['rowId'],
      if (row['entityId'] != null) 'entityId': row['entityId'],
    };
    final action = onAction(
      tr(context, 'chat.action.rewind.failed'),
      () async {
        final preview = await gateway.conversationCommands.fileRewindPreview(sessionId,
            target: target);
        if (!context.mounted) return null;
        final ok = await _showPreviewDialog(context, preview);
        if (ok != true) return null;
        return gateway.conversationCommands.applyFileRewind(sessionId, target);
      },
    );
    await action;
  }

  Future<bool?> _showPreviewDialog(
    BuildContext context,
    dynamic preview,
  ) {
    final files = _previewFiles(preview);
    final blocked = preview == null ||
        (preview is Map && preview['error'] != null) ||
        (preview is Map &&
            (preview['canRewind'] == false ||
                preview['rewritable'] == false));
    return showDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (dialogCtx) => AlertDialog(
        title: Text(
          tr(dialogCtx,
              blocked ? 'chat.rewind.unsafeTitle' : 'chat.rewind.safeTitle'),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: files.isEmpty && !blocked
              ? Text(tr(dialogCtx, 'chat.rewind.checking'),
                  style: ZType.body.copyWith(color: ZInk.soft(dialogCtx)))
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (blocked)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          tr(dialogCtx, 'chat.rewind.cannotApply'),
                          style: ZType.body.copyWith(
                              color: ZInk.dangerTone(dialogCtx)),
                        ),
                      ),
                    for (final f in files.take(12))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          f,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ZType.sub.copyWith(color: ZInk.soft(dialogCtx)),
                        ),
                      ),
                    if (files.length > 12)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '+${files.length - 12}',
                          style: ZType.sub.copyWith(
                              color: ZInk.muted(dialogCtx),
                          ),
                        ),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: Text(tr(dialogCtx, 'common.cancel')),
          ),
          if (!blocked)
            FilledButton(
              onPressed: () => Navigator.pop(dialogCtx, true),
              child: Text(tr(dialogCtx, 'chat.rewind.confirm')),
            ),
        ],
      ),
    );
  }

  /// Best-effort file list extraction from the preview payload — field
  /// names beyond the confirmed endpoint are not guessed further; an empty
  /// list simply renders the text-only dialog.
  static List<String> _previewFiles(dynamic preview) {
    if (preview is! Map) return const [];
    for (final key in const ['files', 'rewritableFiles', 'entries']) {
      final v = preview[key];
      if (v is List) {
        return [
          for (final e in v)
            e is Map
                ? '${e['path'] ?? e['filePath'] ?? e['name'] ?? ''}'
                : '$e',
        ].where((f) => f.isNotEmpty).toList();
      }
    }
    return const [];
  }
}

/// Centered timeline capsules (model switches, compaction, forks...).
class _TimelineMarkerWidget extends StatelessWidget {
  final Map<String, dynamic> row;

  const _TimelineMarkerWidget({required this.row});

  @override
  Widget build(BuildContext context) {
    final marker = row['marker'];
    if (marker is! Map) return const SizedBox.shrink();
    final type = '${marker['type'] ?? ''}';

    final (icon, text, color) = switch (type) {
      'compact' => (
        Icons.compress,
        trP(context, 'chat.marker.compact', [
          '${marker['status'] ?? ''}',
          if (marker['tokensBefore'] != null)
            trP(context, 'chat.marker.tokens', [
              '${marker['tokensBefore']}',
              '${marker['tokensAfter'] ?? '?'}',
            ])
          else
            '',
        ]),
        ZColors.sky500,
      ),
      'forkNotice' => (
        Icons.fork_right,
        tr(context, 'chat.marker.forkNotice'),
        ZInk.faint(context),
      ),
      'forkCreated' => (
        Icons.fork_right,
        tr(context, 'chat.marker.forkCreated'),
        ZInk.faint(context),
      ),
      'modelChange' => (
        Icons.swap_horiz,
        trP(context, 'chat.marker.modelChange', [
          '${marker['fromModel'] ?? ''}',
          '${marker['toModel'] ?? ''}',
        ]),
        ZInk.warningTone(context),
      ),
      'goalSet' => (
        Icons.flag_outlined,
        trP(context, 'chat.marker.goalSet', ['${marker['objective'] ?? ''}']),
        ZInk.successTone(context),
      ),
      'goalVerify' => (
        Icons.fact_check_outlined,
        trP(context, 'chat.marker.goalVerify', [
          '${marker['iteration'] ?? '?'}',
          '${marker['outcome'] ?? ''}',
        ]),
        ZInk.successTone(context),
      ),
      'retryNotice' => (
        Icons.refresh,
        trP(context, 'chat.marker.retryNotice', [
          '${marker['attempt'] ?? '?'}',
          '${marker['reasonCode'] ?? ''}',
        ]),
        ZInk.warningTone(context),
      ),
      'checkpointRestored' => (
        Icons.restore,
        tr(context, 'chat.marker.checkpointRestored'),
        ZInk.faint(context),
      ),
      _ => (Icons.info_outline, type, ZInk.faint(context)),
    };

    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(ZRadius.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                text,
                style: ZType.caption.copyWith(color: color),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Localized status word for `kind=='subagent'` captions (raw server
/// statuses are English; user-facing copy follows the chat phase words).
String _subagentStatusWord(BuildContext context, String status) {
  return switch (status) {
    'running' || 'pending' => tr(context, 'chat.subagent.status.running'),
    'error' || 'failed' => tr(context, 'chat.subagent.status.failed'),
    'success' => tr(context, 'chat.subagent.status.success'),
    _ => status,
  };
}

class _SubagentTile extends StatelessWidget {
  final Map<String, dynamic> row;
  final ChatGateway gateway;
  final String sessionId;

  /// Terminal-hysteresis view over the raw row status (a replayed running
  /// report within the window keeps the terminal caption).
  final SubagentFeed? feed;

  const _SubagentTile({
    required this.row,
    required this.gateway,
    required this.sessionId,
    this.feed,
  });

  @override
  Widget build(BuildContext context) {
    final rawStatus = '${row['status'] ?? ''}';
    final status = feed?.effectiveStatus(
          '${row['childSessionId'] ?? ''}',
          rawStatus,
        ) ??
        rawStatus;
    return InkWell(
      // Whole tile opens the read-only child-session detail page.
      onTap: () => _openSubagentDetail(
        context,
        gateway,
        childSessionId: row['childSessionId'] as String?,
        subagentType: row['subagentType'] as String?,
        workId: row['workId'] as String?,
        parentSessionId: sessionId,
        running: status == 'running',
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: ZTile.seam),
        padding: const EdgeInsets.all(ZTile.headPadding),
        decoration: BoxDecoration(
          color: ZInk.tile(context),
          borderRadius: BorderRadius.circular(ZRadius.tile),
          border: Border.all(color: ZInk.hairline(context)),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: ZTile.headHeight),
          child: Row(
            children: [
              Icon(Icons.smart_toy_outlined,
                  size: ZTile.iconSize, color: ZInk.muted(context)),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      trP(context, 'chat.subagent', [
                        '${row['subagentType'] ?? ''}',
                      ]),
                      style: ZType.sub.copyWith(color: ZInk.soft(context)),
                    ),
                    Text(
                      '${_subagentStatusWord(context, status)}  ${row['summaryText'] ?? ''}',
                      style: ZType.caption.copyWith(color: ZInk.faint(context)),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right,
                  size: ZTile.iconSize, color: ZInk.ghost(context)),
            ],
          ),
        ),
      ),
    );
  }
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
  final ChatGateway gateway;
  final SubagentFeed? feed;

  const _GoalProcessPanel({
    required this.state,
    required this.gateway,
    this.feed,
  });

  @override
  Widget build(BuildContext context) {
    if (state.snapshot?['goal'] is! Map) return const SizedBox.shrink();
    return GoalPanel(
      state: state,
      feed: feed,
      onPauseGoal: (sid) => gateway.conversationCommands.pauseGoal(sid),
      onResumeGoal: (sid) => gateway.conversationCommands.resumeGoal(sid),
      onOpenAgent: (agent) => _openSubagentDetail(
        context,
        gateway,
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

/// Background works bar, plain background tasks only (bash & co.): ONE
/// compact count line + per-task ✕. Subagent entries moved to the composer
/// pill + management sheet (task internal-task); the bar no
/// longer holds pooled child subscriptions — the Agent tile expansion, the
/// management sheet and the goal panel share those now.
class _BackgroundWorksBar extends StatelessWidget {
  final ConversationState state;
  final ChatGateway gateway;

  const _BackgroundWorksBar({required this.state, required this.gateway});

  @override
  Widget build(BuildContext context) {
    final plainWorks = state.backgroundWorks
        .where((w) =>
            w['kind'] != 'subagent' &&
            w['status'] == 'running' &&
            w['endedAt'] == null)
        .toList();
    if (plainWorks.isEmpty) return const SizedBox.shrink();
    final sessionId = state.snapshot?['sessionId'] as String? ?? '';
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: ZInk.tile(context),
        borderRadius: BorderRadius.circular(ZRadius.tile),
      ),
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
              trP(context, 'chat.bgWorks', [
                '${plainWorks.length}',
                plainWorks
                    .map((w) => w['title'] ?? w['kind'])
                    .join(tr(context, 'chat.bgWorks.sep')),
              ]),
              style: ZType.caption.copyWith(color: ZInk.soft(context)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          for (final w in plainWorks)
            IconButton(
              icon: Icon(Icons.close, size: 14, color: ZInk.muted(context)),
              tooltip: tr(context, 'chat.bgWorks.cancel'),
              visualDensity: VisualDensity.compact,
              onPressed: () {
                final workId = "${w['workId'] ?? w['id'] ?? ''}";
                if (workId.isEmpty) return;
                gateway.conversationCommands.cancelBackgroundWork(sessionId, workId);
              },
            ),
        ],
      ),
    );
  }
}

/// Opens the read-only subagent child-session detail page (works bar row,
/// subagent stream tile, goal panel running tile).
void _openSubagentDetail(
  BuildContext context,
  ChatGateway gateway, {
  required String? childSessionId,
  String? title,
  String? subagentType,
  String? workId,
  String? parentSessionId,
  bool running = false,
}) {
  final sid = childSessionId ?? '';
  if (sid.isEmpty) return;
  Navigator.of(context).push(
    zRoute(
      (_) => SubagentDetailPage(
        gateway: gateway,
        childSessionId: sid,
        title: title,
        subagentType: subagentType,
        workId: workId,
        parentSessionId: parentSessionId,
        running: running,
      ),
    ),
  );
}

/// Subagent management sheet (internal-task, mock C):
/// running section (live action tail + 详情/停止 actions) + ended rows from
/// the parent window + 「加载更早」 paging back through rowsRange.
///
/// Subscription lifecycle: the sheet holds pooled child subscriptions for
/// its own lifetime (acquire on rebuild sync, release ALL on dispose) —
/// closing the sheet must never leak a feed reference (chat-conventions §7
/// Common Mistake).
class _SubagentSheet extends StatefulWidget {
  final ConversationState state;
  final ChatGateway gateway;
  final SubagentFeed feed;

  /// Auto-close confirm window: once the running view stayed empty this
  /// long (all subagents terminal), the sheet closes itself.
  final Duration confirmWindow;

  const _SubagentSheet({
    required this.state,
    required this.gateway,
    required this.feed,
    required this.confirmWindow,
  });

  @override
  State<_SubagentSheet> createState() => _SubagentSheetState();
}

class _SubagentSheetState extends State<_SubagentSheet> {
  /// childSessionIds this sheet currently holds in the pooled subscription.
  final Set<String> _held = {};

  /// Older `kind=='subagent'` rows collected through rowsRange paging
  /// (kept locally — paging from the sheet must not reshape the chat list).
  final List<Map<String, dynamic>> _older = [];

  bool _paging = false;
  bool _noMore = false;
  Timer? _closeTimer;
  bool _seenRunning = false;

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
    _closeTimer?.cancel();
    // Symmetric release: every acquire made while the sheet lived is undone
    // here, early-exit or not.
    for (final id in _held) {
      widget.feed.release(id);
    }
    _held.clear();
    super.dispose();
  }

  /// All-terminal auto close (PRD: same 3s confirm semantics as the pill).
  void _reconcileAutoClose(List<Map<String, dynamic>> running) {
    if (running.isNotEmpty) {
      _seenRunning = true;
      _closeTimer?.cancel();
      _closeTimer = null;
      return;
    }
    if (!_seenRunning || _closeTimer != null) return;
    _closeTimer = Timer(widget.confirmWindow, () {
      _closeTimer = null;
      if (!mounted) return;
      if (subagentsRunningView(widget.state, widget.feed).isEmpty) {
        Navigator.of(context).pop();
      }
    });
  }

  // ------------------------------------------------------------ paging

  /// Pages older parent-session rows and collects their subagent rows.
  /// Cursor = the smallest collected rowId (window rows included) — never
  /// the snapshot's placeholder `firstRowId` (see [ConversationState.oldestRowId]).
  Future<void> _loadEarlier() async {
    if (_paging || _noMore || _sessionId.isEmpty) return;
    setState(() => _paging = true);
    try {
      int? cursor = widget.state.oldestRowId;
      for (final r in _older) {
        final id = (r['rowId'] as num?)?.toInt();
        if (id != null && (cursor == null || id < cursor)) cursor = id;
      }
      final res = await widget.gateway.conversationCommands.rowsRange(
        _sessionId,
        beforeRowId: cursor,
        limit: 60,
      );
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
        state: widget.state,
        sortOldestFirst: false,
      );
      if (!page.epochMatches) {
        if (mounted) _toast(tr(context, 'chat.loadOlder.stale'));
        return;
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
      await widget.gateway.conversationCommands.cancelBackgroundWork(_sessionId, workId);
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
        _reconcileAutoClose(running);
        final ended = _endedRows();
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
                  _buildHeader(context, running.length),
                  if (running.isNotEmpty) ...[
                    _buildSectionLabel(context, 'chat.subagentSheet.sectionRunning'),
                    for (final a in running)
                      _buildRunItem(context, a),
                  ],
                  if (ended.isNotEmpty) ...[
                    _buildSectionLabel(context, 'chat.subagentSheet.sectionEnded'),
                    for (final row in ended) _buildEndedItem(context, row),
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

  Widget _buildHeader(BuildContext context, int runningCount) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 6),
      child: Row(
        children: [
          Text(
            tr(context, 'chat.subagentSheet.title'),
            style: ZType.heading.copyWith(color: ZInk.solid(context)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              trP(context, 'chat.subagentSheet.count',
                  ['$runningCount', '$_totalCount']),
              style: ZType.caption.copyWith(color: ZInk.muted(context)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
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

  Widget _buildSectionLabel(BuildContext context, String key) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 2),
      child: Row(
        children: [
          Text(
            tr(context, key),
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

  /// One running row: spinner + title + elapsed, live action tail, then the
  /// 详情/停止 action row (mock .run-item).
  Widget _buildRunItem(BuildContext context, Map<String, dynamic> agent) {
    final title = '${agent['title'] ?? agent['subagentType'] ?? ''}';
    final sid = '${agent['childSessionId'] ?? ''}';
    final tail = subagentActionText(context, widget.feed.childState(sid));
    return Padding(
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
              _SheetElapsed(startedAt: agent['startedAt'] as num?),
            ],
          ),
          if (tail != null)
            Padding(
              padding: const EdgeInsets.only(left: 20, top: 2),
              child: Text(
                tail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ZType.caption.copyWith(color: ZInk.soft(context)),
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _SheetActionButton(
                label: tr(context, 'chat.subagentSheet.detail'),
                onTap: sid.isEmpty
                    ? null
                    : () => _openSubagentDetail(
                          context,
                          widget.gateway,
                          childSessionId: sid,
                          title: '${agent['title'] ?? ''}',
                          subagentType: agent['subagentType'] as String?,
                          workId: '${agent['agentId'] ?? agent['workId'] ?? ''}',
                          parentSessionId: _sessionId,
                          running: true,
                        ),
              ),
              const SizedBox(width: 8),
              _SheetActionButton(
                label: tr(context, 'chat.agents.stop'),
                danger: true,
                onTap: () => _confirmStop(agent),
              ),
            ],
          ),
        ],
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
      onTap: sid.isEmpty
          ? null
          : () => _openSubagentDetail(
                context,
                widget.gateway,
                childSessionId: sid,
                subagentType: row['subagentType'] as String?,
                workId: row['workId'] as String?,
                parentSessionId: _sessionId,
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
class _SheetActionButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool danger;

  const _SheetActionButton({
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = danger ? ZInk.dangerTone(context) : ZInk.soft(context);
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        foregroundColor: color,
        side: BorderSide(
          color: danger ? ZColors.danger.withValues(alpha: 0.45) : ZInk.hairline(context),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZRadius.field),
        ),
      ),
      onPressed: onTap,
      child: Text(label, style: ZType.caption.copyWith(color: color)),
    );
  }
}

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
  final ChatGateway gateway;

  const _QueueBar({required this.state, required this.gateway});

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
                  gateway.conversationCommands.setAutoDrain(sessionId, next);
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
                          gateway.conversationCommands.sendQueuedNow(sessionId, id);
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
                          gateway.conversationCommands.deleteQueueItem(sessionId, id);
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
    gateway.conversationCommands.reorderQueueItem(sessionId, id, beforeId);
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
    await gateway.conversationCommands.editQueueItem(sessionId, '${item['queueItemId']}', text);
  }
}

/// Collapsed run of consecutive execute-family tool rows:
/// 「终端 · N 个命令」 — tap expands the individual tool cards.
class _ToolGroupCard extends StatefulWidget {
  final List<Map<String, dynamic>> rows;
  final ChatGateway gateway;
  final String sessionId;
  final Future<void> Function(String, Future<dynamic> Function()) onAction;
  final ConversationState state;
  final SubagentFeed? feed;

  /// Workspace file-preview plumbing (tappable file entries).
  final _ChatPreview preview;

  const _ToolGroupCard({
    super.key,
    required this.rows,
    required this.gateway,
    required this.sessionId,
    required this.onAction,
    required this.state,
    required this.preview,
    this.feed,
  });

  @override
  State<_ToolGroupCard> createState() => _ToolGroupCardState();
}

class _ToolGroupCardState extends State<_ToolGroupCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final n = widget.rows.length;
    var failed = 0;
    var stopped = 0;
    var lastCmd = '';
    for (final r in widget.rows) {
      final st = '${r['status'] ?? ''}';
      if (st == 'failed') failed += 1;
      if (st == 'stopped' || st == 'denied') stopped += 1;
      final input = r['inputText'] as String? ?? '';
      if (lastCmd.isEmpty && input.isNotEmpty) {
        lastCmd = input.split('\n').first;
      }
    }
    final bits = [
      trP(context, 'chat.tool.group.count', ['$n']),
      if (failed > 0) trP(context, 'chat.tool.group.failed', ['$failed']),
      if (stopped > 0) trP(context, 'chat.tool.group.stopped', ['$stopped']),
    ].join(' · ');
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: ZInk.tile(context),
        borderRadius: BorderRadius.circular(ZRadius.field),
        border: Border.all(color: ZInk.hairline(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(ZRadius.field),
            onTap: () {
              HapticFeedback.lightImpact();
              setState(() => _expanded = !_expanded);
            },
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: zTouchHeight),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    Icon(Icons.terminal,
                        size: 14, color: ZInk.muted(context)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${tr(context, 'chat.tool.group.terminal')} · $bits'
                        '${lastCmd.isEmpty ? '' : '  ·  $lastCmd'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ZType.sub.copyWith(color: ZInk.soft(context)),
                      ),
                    ),
                    Icon(
                      _expanded
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                      size: 16,
                      color: ZInk.ghost(context),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Column(
                children: [
                  for (final r in widget.rows)
                    _RowWidget(
                      row: r,
                      showFeedback: false,
                      gateway: widget.gateway,
                      sessionId: widget.sessionId,
                      onAction: widget.onAction,
                      state: widget.state,
                      preview: widget.preview,
                      feed: widget.feed,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
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

class _PendingInteractions extends StatelessWidget {
  final ConversationState state;
  final ChatGateway gateway;

  const _PendingInteractions({required this.state, required this.gateway});

  @override
  Widget build(BuildContext context) {
    final interactions = state.pendingInteractions;
    if (interactions.isEmpty) return const SizedBox.shrink();
    final sessionId = state.snapshot?['sessionId'] as String? ?? '';
    return Column(
      children: [
        for (final interaction in interactions)
          if ((interaction['payload'] as Map?)?['kind'] == 'workspaceHookReview')
            _HookReviewCard(
              interaction: interaction,
              onTrust: (reviewItemIds) {
                final payload = interaction['payload'];
                return gateway.conversationCommands
                    .respondWorkspaceHookReview(
                      sessionId,
                      payload is Map
                          ? Map<String, dynamic>.from(payload)
                          : const {},
                      reviewItemIds,
                    );
              },
            )
          else
            _InteractionCard(
              interaction: interaction,
              onResolve: ({optionId, freeText, action, content}) =>
                  gateway.conversationCommands.resolveInteraction(
                    sessionId,
                    interaction['interactionId'] as String? ?? '',
                    optionId: optionId,
                    freeText: freeText,
                    action: action,
                    content: content,
                  ),
              onSnooze: () => gateway.conversationCommands.snoozeInteractionAutoResolution(
                    sessionId,
                    interaction['interactionId'] as String? ?? '',
                  ),
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

  const _InteractionCard({
    required this.interaction,
    required this.onResolve,
    this.onSnooze,
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
                      onPressed: _busy
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
              onResolve: (content) =>
                  _resolve(content: content, action: 'accept'),
            ),
          if (freeText && !hasQuestions)
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _freeTextController,
                    style: ZType.body,
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
          if (widget.onSnooze != null)
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

  String _optionLabel(Map option) {
    final label = option['label'] as String?;
    if (label != null && label.isNotEmpty) return label;
    final kind = option['kind'] as String?;
    return switch (kind) {
      'allowOnce' => tr(context, 'chat.interact.allowOnce'),
      'allowAlways' => tr(context, 'chat.interact.allowAlways'),
      'deny' => tr(context, 'chat.interact.deny'),
      'custom' => tr(context, 'chat.interact.custom'),
      _ => '${option['optionId'] ?? tr(context, 'chat.interact.pick')}',
    };
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

  const _HookReviewCard({required this.interaction, required this.onTrust});

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
              onChecked: (on) => setState(() {
                on == true
                    ? _checked.add('${item['reviewItemId']}')
                    : _checked.remove('${item['reviewItemId']}');
              }),
            ),
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
  final ValueChanged<bool?> onChecked;

  const _HookReviewItem({
    required this.item,
    required this.checked,
    required this.busy,
    required this.onChecked,
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
  final void Function(Map<String, dynamic> content) onResolve;

  const _QuestionsView({
    required this.questions,
    required this.busy,
    required this.onResolve,
  });

  @override
  State<_QuestionsView> createState() => _QuestionsViewState();
}

class _QuestionsViewState extends State<_QuestionsView> {
  /// Collected option values per question index — nothing resolves until
  /// the explicit submit.
  final Map<int, List<String>> _selections = {};

  /// Questions with the inline custom-answer input expanded.
  final Set<int> _customOpen = {};

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

  /// Unified toggle: tapping the picked option deselects it (single-select
  /// may return to "nothing picked"), tapping another single-select option
  /// re-chooses. Any option tap collapses the custom input and drops its
  /// text — single-select options and the custom answer are mutually
  /// exclusive.
  void _toggleOption(int index, Map question, String value) {
    setState(() {
      _closeCustom(index);
      final selected = _selections.putIfAbsent(index, () => []);
      if (question['multiSelect'] == true) {
        // Set semantics: a duplicate toggle must not grow the list.
        selected.contains(value) ? selected.remove(value) : selected.add(value);
      } else if (selected.contains(value)) {
        selected.remove(value);
      } else {
        selected
          ..clear()
          ..add(value);
      }
    });
  }

  /// Custom chip: expands the inline input and focuses it on the next frame
  /// (see [_customFocusNodes] for why not `autofocus`); tapping again
  /// collapses and clears. Multi-select keeps custom as an extra coexisting
  /// answer; single-select clears the picked option first.
  void _toggleCustom(int index, Map question) {
    setState(() {
      if (_customOpen.contains(index)) {
        _closeCustom(index);
        return;
      }
      if (question['multiSelect'] != true) _selections[index]?.clear();
      _customOpen.add(index);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _customOpen.contains(index)) {
        _customFocusNodes[index]?.requestFocus();
      }
    });
  }

  /// Collapse + clear in one place so every collapse path drops the text.
  void _closeCustom(int index) {
    if (_customOpen.remove(index)) _customControllers[index]?.clear();
  }

  /// A question's answer: selected option values ∪ (custom input open with
  /// non-blank text ? [text] : ∅) — blank text is not an answer.
  List<String> _answersOf(int index) {
    final answer = List<String>.of(_selections[index] ?? const []);
    if (_customOpen.contains(index)) {
      final text = _customControllers[index]!.text.trim();
      if (text.isNotEmpty) answer.add(text);
    }
    return answer;
  }

  /// `buildBotElicitationContent` shape: `answers` keyed by question
  /// text with comma-joined option labels, `answer_N` carrying option values
  /// (scalar for single-select, list for multiSelect), `answer` only for the
  /// single-question form. Custom text joins verbatim (it is its own label).
  /// Unanswered questions are silently skipped; nothing answered yields just
  /// the empty `answers` map (the explicit "no answer" submit).
  Map<String, dynamic> _buildContent() {
    final content = <String, dynamic>{};
    final answers = <String, String>{};
    for (var i = 0; i < widget.questions.length; i++) {
      final answer = _answersOf(i);
      if (answer.isEmpty) continue;
      final q = widget.questions[i];
      final multi = q['multiSelect'] == true;
      final options = (q['options'] as List?) ?? const [];
      String labelOf(String value) {
        for (final o in options) {
          if (o is Map && '${o['value']}' == value) {
            return '${o['label'] ?? o['value'] ?? value}';
          }
        }
        return value;
      }

      answers['${q['label'] ?? q['question'] ?? q['value'] ?? 'answer_$i'}'] =
          answer.map(labelOf).join(', ');
      content['answer_$i'] = multi ? answer : answer.first;
    }
    content['answers'] = answers;
    if (widget.questions.length == 1 && content.containsKey('answer_0')) {
      content['answer'] = content['answer_0'];
    }
    return content;
  }

  @override
  Widget build(BuildContext context) {
    final answered = [
      for (var i = 0; i < widget.questions.length; i++)
        if (_answersOf(i).isNotEmpty) i,
    ].length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < widget.questions.length; i++)
          _QuestionItem(
            index: i,
            question: widget.questions[i],
            busy: widget.busy,
            selected: _selections[i] ?? const [],
            customOpen: _customOpen.contains(i),
            customController: _customControllers[i]!,
            customFocusNode: _customFocusNodes[i]!,
            onToggleOption: (value) =>
                _toggleOption(i, widget.questions[i], value),
            onToggleCustom: () => _toggleCustom(i, widget.questions[i]),
          ),
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
  final List<String> selected;
  final bool customOpen;
  final TextEditingController customController;
  final FocusNode customFocusNode;
  final void Function(String value) onToggleOption;
  final void Function() onToggleCustom;

  const _QuestionItem({
    required this.index,
    required this.question,
    required this.busy,
    required this.selected,
    required this.customOpen,
    required this.customController,
    required this.customFocusNode,
    required this.onToggleOption,
    required this.onToggleCustom,
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
                        onSelected: busy
                            ? null
                            : (on) => onToggleOption('${o['value']}'),
                      ),
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
            if (customOpen)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: TextField(
                  key: ValueKey('askq-custom-$index'),
                  controller: customController,
                  focusNode: customFocusNode,
                  enabled: !busy,
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

class _ModelModeSheet extends StatelessWidget {
  final ChatGateway gateway;
  final ConversationState? state;
  final WorkspacePrep? prep;
  final String? sessionId;

  /// PRD 09-19 fallback: enabled providers from the `model-provider`
  /// channel, fetched by the page only when [prep] carries no model
  /// options. Empty when the channel is gone → the degraded text stays.
  final List<Map<String, dynamic>> providerCatalog;
  final Map<String, String>? draftConfig;
  final void Function(String key, String value)? onDraftChange;

  const _ModelModeSheet({
    required this.gateway,
    required this.state,
    required this.prep,
    required this.sessionId,
    required this.providerCatalog,
    this.draftConfig,
    this.onDraftChange,
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

  /// 'builtin:zai-coding-plan/GLM-5.2' → (provider, model)
  (String, String) _splitModelValue(String value) {
    final idx = value.lastIndexOf('/');
    if (idx <= 0) return (value, value);
    return (value.substring(0, idx), value.substring(idx + 1));
  }

  @override
  Widget build(BuildContext context) {
    final sid = sessionId ?? '';
    final config = state?.config ?? const {};
    final modelOption = prep?.option('model');
    // PRD 09-19: when prepareWorkspace ships no usable model options, the
    // model section renders the model-provider catalog instead; provider
    // ids never contain '/', so `_splitModelValue` still splits cleanly.
    final modelChoices =
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
                  modelProviderName: '${p['name'] ?? p['id'] ?? ''}',
                ),
          ];
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
              Text(
                modelOption?.name ??
                    tr(context, 'chat.composer.modelPlaceholder'),
                style: ZType.body.copyWith(color: ZInk.solid(context)),
              ),
              const SizedBox(height: 8),
              // The menu groups models by provider (BigModel /
              // tx / kimi_zz …): header whenever the provider changes.
              for (final (i, v) in modelChoices.indexed) ...[
                if (i == 0 ||
                    v.modelProviderName !=
                        modelChoices[i - 1].modelProviderName)
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
                      final (provider, model) = _splitModelValue(v.value);
                      // thought must be valid for the target model:
                      // keep current if supported, else fall back to the
                      // thought option's currentValue.
                      final currentThought = state?.currentThought ?? '';
                      final thoughtOpt = prep?.option('thought_level');
                      final thought =
                          currentThought.isNotEmpty &&
                              (thoughtOpt?.options.any(
                                    (o) => o.value == currentThought,
                                  ) ??
                                  false)
                          ? currentThought
                          : '${thoughtOpt?.currentValue ?? (currentThought.isNotEmpty ? currentThought : 'enabled')}';
                      void patch() => state?.optimisticPatch({
                        'config': {
                          ...?state!.config,
                          'provider': provider,
                          'model': model,
                          'thought': thought,
                        },
                      });
                      _apply(
                        context,
                        () => gateway.conversationCommands.switchModelConfig(
                          sid,
                          provider: provider,
                          model: model,
                          thought: thought,
                        ),
                        onAccepted: patch,
                        // PRD 09-19: a lost ack (bridge reconnect window)
                        // is not a rejection — land the patch anyway.
                        onTimeoutOptimistic: patch,
                      );
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
              Text(
                thoughtOption.name,
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
                          void patch() => state?.optimisticPatch({
                            'config': {
                              ...?state!.config,
                              'thought': v.value,
                            },
                          });
                          _apply(
                            context,
                            () => gateway.conversationCommands.switchModelConfig(
                              sid,
                              provider: provider,
                              model: model,
                              thought: v.value,
                            ),
                            onAccepted: patch,
                            // Same lost-ack optimism as the model switch.
                            onTimeoutOptimistic: patch,
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
                      onSelected: (_) => _apply(
                        context,
                        () => gateway.conversationCommands.switchModelConfig(
                          sid,
                          provider: '${config['provider'] ?? ''}',
                          model: '${config['model'] ?? ''}',
                          thought: level,
                        ),
                      ),
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
                        () => gateway.conversationCommands.switchCollaborationMode(sid, v.value),
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
                        () => gateway.conversationCommands.switchCollaborationMode(sid, m),
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
                        () => gateway.conversationCommands.setFollowupMode(sid, f),
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
  Future<void> _apply(
    BuildContext context,
    Future<dynamic> Function() run, {
    void Function()? onAccepted,
    void Function()? onTimeoutOptimistic,
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
        } else {
          onAccepted?.call();
          Navigator.pop(context);
        }
      }
    } catch (e) {
      debugPrint('[chat] sheet op: $e');
      if (onTimeoutOptimistic != null && context.mounted) {
        onTimeoutOptimistic();
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr(context, 'chat.sheet.switchPending'))),
        );
      } else if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              trP(context, 'chat.op.failed', [
                commandErrorCopy('$e', _localeOf(context)) ?? '$e',
              ]),
            ),
          ),
        );
      }
    }
  }
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

class _JsonSheet extends StatelessWidget {
  final String title;
  final Object? data;

  const _JsonSheet({required this.title, required this.data});

  @override
  Widget build(BuildContext context) {
    const encoder = JsonEncoder.withIndent('  ');
    return SafeArea(
      // Height cap so the sheet never grows past a readable strip even when
      // opened scroll-controlled (like _UsageSheet's 0.85 idiom, tighter).
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: ZSpacing.screen, vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: ZType.heading,
              ),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: SelectableText(
                    data == null
                        ? tr(context, 'chat.json.empty')
                        : encoder.convert(data),
                    style: ZType.caption.copyWith(fontFamily: 'monospace'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One parsed file-changes entry: the workspace path plus optional
/// added/removed line counts (absent when the payload only named files).
typedef FileChangeEntry = ({String path, int? added, int? removed});

/// Defensive parse of the `conversationFileChangesV4` payload into tappable
/// file rows (design §4.4 变更文件列表): a `files`/`changes`/`entries` list
/// (or a bare list) of maps — path from `path`/`file`/`filePath`, counts
/// from `additions`/`added` and `deletions`/`removed` — or plain path
/// strings. Null when the payload is not file-row-shaped (an empty list,
/// missing paths, foreign entry types): the caller falls back to the raw
/// [_JsonSheet], which is never worse than the previous behavior.
List<FileChangeEntry>? parseFileChanges(Object? data) {
  List? list;
  if (data is List) {
    list = data;
  } else if (data is Map) {
    for (final key in const ['files', 'changes', 'entries']) {
      if (data[key] is List) {
        list = data[key] as List;
        break;
      }
    }
  }
  if (list == null || list.isEmpty) return null;
  final rows = <FileChangeEntry>[];
  for (final entry in list) {
    if (entry is String && entry.isNotEmpty) {
      rows.add((path: entry, added: null, removed: null));
      continue;
    }
    if (entry is! Map) return null;
    String path = '';
    for (final key in const ['path', 'file', 'filePath']) {
      final v = entry[key];
      if (v is String && v.isNotEmpty) {
        path = v;
        break;
      }
    }
    if (path.isEmpty) return null;
    int? count(Object? v) => v is num ? v.toInt() : null;
    rows.add((
      path: path,
      added: count(entry['additions'] ?? entry['added']),
      removed: count(entry['deletions'] ?? entry['removed']),
    ));
  }
  return rows;
}

/// File-changes sheet (design §4.4): the file rows parsed by
/// [parseFileChanges] as tappable entries — basename + directory, +/- line
/// counts, tap dispatches into the preview surfaces. Tapping pushes the
/// preview over the sheet, so browsing several files keeps the list open.
class _FileChangesSheet extends StatelessWidget {
  final String title;
  final List<FileChangeEntry> entries;
  final _ChatPreview preview;

  const _FileChangesSheet({
    required this.title,
    required this.entries,
    required this.preview,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: ZSpacing.screen, vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: ZType.heading,
              ),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final entry in entries)
                        InkWell(
                          onTap: () => preview.open(context, entry.path),
                          borderRadius:
                              BorderRadius.circular(ZRadius.field),
                          child: Padding(
                            // 13+13 padding + 18px line ≈ 44: zTouch floor
                            // for sheet rows (mention_sheet ListTile).
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 13),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.insert_drive_file_outlined,
                                  size: 16,
                                  color: ZInk.muted(context),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    entry.path,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: ZType.sub
                                        .copyWith(color: ZInk.solid(context)),
                                  ),
                                ),
                                if (entry.added != null && entry.added! > 0)
                                  Padding(
                                    padding: const EdgeInsets.only(left: 8),
                                    child: Text(
                                      '+${entry.added}',
                                      style: ZType.caption.copyWith(
                                          color: ZInk.successTone(context)),
                                    ),
                                  ),
                                if (entry.removed != null && entry.removed! > 0)
                                  Padding(
                                    padding: const EdgeInsets.only(left: 4),
                                    child: Text(
                                      '-${entry.removed}',
                                      style: ZType.caption.copyWith(
                                          color: ZInk.dangerTone(context)),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// ---------------------------------------------------------------- input

/// One entry in the slash popup: a builtin/custom command or a skill.
class _SlashItem {
  final String name;
  final String description;
  final String insert;
  final bool isSkill;

  const _SlashItem({
    required this.name,
    required this.description,
    required this.insert,
    this.isSkill = false,
  });
}

class _SlashCommandBar extends StatelessWidget {
  final String query;
  final List<_SlashItem> items;
  final void Function(_SlashItem item) onSelect;

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
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final command in filtered)
            ListTile(
              dense: true,
              leading: Icon(
                command.isSkill ? ZSymbols.extension : ZSymbols.terminal,
                size: 16,
                color: ZInk.iconNeutral(context),
              ),
              title: Text(
                command.isSkill ? '\$${command.name}' : '/${command.name}',
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
  final ChatGateway gateway;
  final String? sessionId;

  /// Shared child-session pool backing the subagent pill's terminal
  /// hysteresis view (null in draft mode → no pill).
  final SubagentFeed? feed;

  /// Terminal destroy-confirm window for the subagent pill (same anti-replay
  /// window as the turn footer).
  final Duration subagentConfirmWindow;

  final VoidCallback onSend;
  final VoidCallback onAttach;
  final VoidCallback onSkills;
  final VoidCallback onModelSheet;
  final VoidCallback onUsage;

  /// Opens the subagent management sheet (wired only with a live session).
  final VoidCallback? onSubagents;

  const _InputBar({
    required this.controller,
    required this.sending,
    required this.hasAttachments,
    required this.isDraft,
    required this.state,
    required this.prep,
    required this.draftConfig,
    required this.gateway,
    required this.sessionId,
    required this.feed,
    required this.subagentConfirmWindow,
    required this.onSend,
    required this.onAttach,
    required this.onSkills,
    required this.onModelSheet,
    required this.onUsage,
    this.onSubagents,
  });

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onText);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onText);
    super.dispose();
  }

  void _onText() {
    if (mounted) setState(() {});
  }

  /// Short-viewport toggle: the tool row starts collapsed (landscape phones
  /// / folding half-open) and the expand button reveals it temporarily.
  bool _toolsExpanded = false;

  bool get _hasInput =>
      widget.controller.text.trim().isNotEmpty || widget.hasAttachments;

  // Field forwarders so the build/helpers below read like the original
  // stateless widget.
  TextEditingController get controller => widget.controller;
  bool get sending => widget.sending;
  bool get isDraft => widget.isDraft;
  ConversationState? get state => widget.state;
  SubagentFeed? get feed => widget.feed;
  WorkspacePrep? get prep => widget.prep;
  Map<String, String>? get draftConfig => widget.draftConfig;
  ChatGateway get gateway => widget.gateway;
  String? get sessionId => widget.sessionId;
  VoidCallback get onSend => widget.onSend;
  VoidCallback get onAttach => widget.onAttach;
  VoidCallback get onModelSheet => widget.onModelSheet;
  VoidCallback get onUsage => widget.onUsage;
  VoidCallback? get onSubagents => widget.onSubagents;

  String get _modeValue => isDraft
      ? (draftConfig?['mode'] ?? 'build')
      : (state?.currentMode ?? 'build');

  String get _modelLabel {
    if (isDraft) {
      final v = draftConfig?['model'];
      if (v != null && v.isNotEmpty) {
        final idx = v.lastIndexOf('/');
        return idx > 0 ? v.substring(idx + 1) : v;
      }
      final current = prep?.option('model')?.currentValue;
      if (current != null && '$current'.isNotEmpty) {
        final idx = '$current'.lastIndexOf('/');
        return idx > 0 ? '$current'.substring(idx + 1) : '$current';
      }
      return '';
    }
    final model = state?.currentModel ?? '';
    if (model.isEmpty) return '';
    // Friendly option name from workspace prep when available.
    for (final o
        in prep?.option('model')?.options ?? const <ConfigOptionValue>[]) {
      if (o.value == model) return o.name;
    }
    final idx = model.lastIndexOf('/');
    return idx > 0 ? model.substring(idx + 1) : model;
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
    final running = state?.isRunning ?? false;
    // The hint swaps once messages are queued, so typing more
    // keeps appending to the queue instead of looking like a fresh message.
    final queued = state?.queueItems.isNotEmpty ?? false;
    // Composer: icon-only buttons below sm (640), icon+label above.
    final wide = MediaQuery.sizeOf(context).width >= 640;
    // Short viewport (landscape phones, folding half-open; portrait phones
    // are ~844 tall and never trigger): collapse the tool row into an
    // expand toggle so the input line keeps the scarce vertical room.
    final short = MediaQuery.heightOf(context) < 480;
    final toolsVisible = !short || _toolsExpanded;
    // Horizontal insets are consumed once by the body-level SafeArea above
    // (aligned message flow and composer); this one only keeps its bottom
    // gesture-bar duty.
    return SafeArea(
      left: false,
      right: false,
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Container(
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
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
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  // Short viewports: the collapse toggle lives here instead
                  // of a dedicated toolbar row stealing scarce input height
                  // (sole entry when collapsed, collapse entry when shown).
                  suffixIcon: short
                      ? IconButton(
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
                        )
                      : null,
                ),
                textInputAction: TextInputAction.newline,
              ),
              Row(
                children: [
                  // Short viewports keep the tools collapsed (toggle moved
                  // into the TextField suffixIcon), so the whole left cluster
                  // is gated on visibility; the send cluster stays put.
                  if (toolsVisible) ...[
                    IconButton(
                      icon: Icon(
                        Icons.add_circle_outline,
                        size: 20,
                        color: ZInk.muted(context),
                      ),
                      tooltip: tr(context, 'chat.input.attach'),
                      onPressed: sending ? null : onAttach,
                    ),
                    _ControlChip(
                      label: tr(context, 'chat.mode.$_modeValue'),
                      icon: Icons.tune,
                      onTap: () => _pickMode(context),
                      showLabel: wide,
                    ),
                    // Subagent management entry (composer count
                    // button shape, subagents-only by design). Sits right of
                    // the mode chip; its appearance never shifts the other
                    // controls (Spacer keeps the right cluster in place).
                    if (state != null && feed != null && onSubagents != null)
                      _SubagentPill(
                        state: state!,
                        feed: feed!,
                        confirmWindow: widget.subagentConfirmWindow,
                        onTap: onSubagents!,
                      ),
                  ],
                  const Spacer(),
                  if (toolsVisible && _usageRatio != null)
                    _UsageRing(ratio: _usageRatio!, onTap: onUsage),
                  if (toolsVisible && _modelPickerVisible)
                    _ControlChip(
                      label: _modelLabel.isEmpty
                          ? tr(context, 'chat.composer.modelPlaceholder')
                          : _modelLabel,
                      icon: Icons.memory_outlined,
                      onTap: onModelSheet,
                      showLabel: wide,
                    ),
                  if (toolsVisible && _thoughtPickerVisible)
                    _ControlChip(
                      label: _thoughtLabel.isEmpty
                          ? tr(context, 'chat.composer.thoughtPlaceholder')
                          : _thoughtLabel,
                      icon: Icons.psychology_alt_outlined,
                      onTap: () => _pickThought(context),
                      showLabel: wide,
                    ),
                  const SizedBox(width: 4),
                  // The composer stays sendable while a turn
                  // runs — follow-ups queue mid-turn — with stop appearing
                  // at the far right.
                  _SendButton(
                    enabled: _hasInput && !sending,
                    sending: sending,
                    onSend: onSend,
                  ),
                  if (running) _StopButton(onStop: () => _stop(context)),
                ],
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
    gateway.conversationCommands.switchCollaborationMode(sid, value);
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
    final modelValue =
        '${state?.config?['provider'] ?? ''}/${state?.config?['model'] ?? ''}';
    final idx = modelValue.lastIndexOf('/');
    gateway.conversationCommands.switchModelConfig(
      sid,
      provider: idx > 0 ? modelValue.substring(0, idx) : modelValue,
      model: idx > 0 ? modelValue.substring(idx + 1) : modelValue,
      thought: value,
    );
  }

  void _stop(BuildContext context) {
    final sid = sessionId;
    if (sid == null) return;
    gateway.conversationCommands.stop(sid);
  }
}

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
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ZType.caption.copyWith(color: ZInk.soft(context)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Composer entry pill for running subagents (composer count
/// button shape, subagents-only by design — bash tasks stay on the works
/// bar). Shows the agent glyph + running count (tabular-nums) + a breathing
/// dot on a faint brand wash, per the confirmed design mock
/// (tool/design/subagent_entry_mock.html B).
///
/// Visibility: the `subagents.running[]` hysteresis view non-empty → shown;
/// once everything went terminal the pill must hold that state for
/// [confirmWindow] before it is destroyed (the same anti-replay window as
/// the turn footer). The SubagentFeed's regression hysteresis absorbs
/// replayed running reports against a terminal, so this window guards
/// genuine empty↔non-empty flips only.
class _SubagentPill extends StatefulWidget {
  final ConversationState state;
  final SubagentFeed feed;
  final Duration confirmWindow;
  final VoidCallback onTap;

  const _SubagentPill({
    required this.state,
    required this.feed,
    required this.confirmWindow,
    required this.onTap,
  });

  @override
  State<_SubagentPill> createState() => _SubagentPillState();
}

class _SubagentPillState extends State<_SubagentPill> {
  /// Fires at the end of the destroy-confirm window to re-render (an
  /// external notify usually won't arrive once everything is terminal).
  Timer? _destroyTimer;

  bool _visible = false;

  @override
  void dispose() {
    _destroyTimer?.cancel();
    super.dispose();
  }

  /// Derived inside the AnimatedBuilder (its notifications are what drive
  /// rebuilds); plain field writes only — the timer's own completion calls
  /// setState.
  void _reconcile(List<Map<String, dynamic>> running) {
    if (running.isNotEmpty) {
      _destroyTimer?.cancel();
      _destroyTimer = null;
      _visible = true;
      return;
    }
    if (!_visible) return;
    _destroyTimer ??= Timer(widget.confirmWindow, () {
      _destroyTimer = null;
      if (!mounted) return;
      if (subagentsRunningView(widget.state, widget.feed).isEmpty) {
        setState(() => _visible = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([widget.state, widget.feed]),
      builder: (context, _) {
        final running = subagentsRunningView(widget.state, widget.feed);
        _reconcile(running);
        if (!_visible) return const SizedBox.shrink();
        return Tooltip(
          message: tr(context, 'chat.subagentSheet.title'),
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
                    '${running.length}',
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
