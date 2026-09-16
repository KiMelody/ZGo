import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../protocol/conversation.dart';
import '../../state/device_session.dart';
import '../../state/entitlement_poller.dart';
import '../../state/quota_reset.dart';
import '../phase_pill.dart';
import '../quota_reset_dialog.dart';
import '../theme.dart';
import '../ui_settings.dart';
import 'diff_view.dart';
import 'markdown_view.dart';
import 'goal_panel.dart';
import 'mention_sheet.dart';
import 'subagent_detail_page.dart';

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

  /// Optional workspace chip shown next to the task title (official chat
  /// second header row).
  final String? workspaceLabel;

  /// Pinned state of the opened task (from the list entry) so the 更多 menu
  /// can show 置顶任务 / 取消置顶任务 like the web and toggle it.
  final bool initialPinned;

  /// Opens the plan-usage page (quota warning banner / pill action). Left
  /// null where no usage route exists; the banner then shows the model
  /// switch only.
  final VoidCallback? onOpenUsage;

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

class _ChatPageState extends State<ChatPage> {
  ChatHandle? _handle;
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  String? _sessionId;
  String? _error;
  bool _sending = false;
  bool _loadingOlder = false;
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

  /// Content bottom seen by the last scroll-follow pass; null until the
  /// initial snapshot is positioned.
  double? _lastContentBottom;

  /// Mirrors [ChatPage.initialPinned]; flips when the 更多 pin toggle runs.
  bool _pinned = false;

  /// Plan-quota snapshot for the composer pill / warning banner. Fetched
  /// once per page open through the session-wide poller (staleness cached
  /// on the gateway side, no background timer); absence just hides the
  /// pill — quota problems never surface as chat errors.
  EntitlementView? _entitlement;

  ConversationState? get _state => _handle?.state;

  @override
  void initState() {
    super.initState();
    _sessionId = widget.sessionId;
    _pinned = widget.initialPinned;
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

  /// Web @-mention parity: typing `@` at word start opens the mention
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
    _stickToBottom = _scrollController.position.pixels >= max - 40;
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
    _inputController.dispose();
    _scrollController.dispose();
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
      // The server snapshot is a tail window (can be as few as 3 rows).
      // The official client shows the full history immediately, so
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
      if (!grew || !_stickToBottom) return;
      _scrollController.animateTo(
        max,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  void _toast(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
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
      _toast(businessErrorCopy('$e', locale) ?? '$errorPrefix: $e');
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
      final descriptor = await widget.gateway.attachmentPut(
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

    // Slash commands (mirrors the web composer).
    if (text == '/compact' || text.startsWith('/compact ')) {
      _inputController.clear();
      setState(() => _showSlash = false);
      await _run(
        tr(context, 'chat.compact.failed'),
        () => widget.gateway.compact(_requireSession()),
      );
      return;
    }
    if (text == '/goal pause') {
      _inputController.clear();
      setState(() => _showSlash = false);
      await _run(
        tr(context, 'chat.goal.pauseFailed'),
        () => widget.gateway.pauseGoal(_requireSession()),
      );
      return;
    }
    if (text == '/goal resume') {
      _inputController.clear();
      setState(() => _showSlash = false);
      await _run(
        tr(context, 'chat.goal.resumeFailed'),
        () => widget.gateway.resumeGoal(_requireSession()),
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
        // mirrors the official composer). This avoids a send-before-subscribe
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
        sessionId = await widget.gateway.createSession(
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
        final res = await widget.gateway.sendGoalCommand(
          sessionId,
          text.substring('/goal '.length).trim(),
          heldQueueDisposition: heldDisposition,
        );
        if (_ackRejected(res)) {
          if (mounted) {
            _toast(trP(context, 'chat.send.failed', [_ackReason(res)]));
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
      final res = await widget.gateway.sendText(
        sessionId,
        text,
        attachments: attachments,
        heldQueueDisposition: heldDisposition,
      );
      if (_ackRejected(res)) {
        if (mounted) {
          _toast(trP(context, 'chat.send.failed', [_ackReason(res)]));
        }
        return;
      }
      _inputController.clear();
      setState(() => _pendingFiles.clear());
    } catch (e) {
      if (mounted) _toast(trP(context, 'chat.send.failed', ['$e']));
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

  bool _ackRejected(dynamic res) =>
      res is Map &&
      res['status'] != null &&
      res['status'] != 'accepted' &&
      res['status'] != 'noop' &&
      res['status'] != 'duplicate';

  String _ackReason(dynamic res) {
    if (res is! Map) return '$res';
    return '${res['reasonCode'] ?? res['message'] ?? res['status']}';
  }

  String _requireSession() {
    final sessionId = _sessionId;
    if (sessionId == null) throw StateError(tr(context, 'chat.noSession'));
    return sessionId;
  }

  /// Builds the createSession `config` payload from the draft selection.
  Map<String, dynamic>? _buildDraftConfig() {
    if (_draftConfig.isEmpty) return null;
    final config = <String, dynamic>{};
    final modelValue = _draftConfig['model'];
    if (modelValue != null && modelValue.isNotEmpty) {
      final idx = modelValue.lastIndexOf('/');
      if (idx > 0) {
        config['provider'] = modelValue.substring(0, idx);
        config['model'] = modelValue.substring(idx + 1);
      }
    }
    if (_draftConfig['thought'] != null) {
      config['thought'] = _draftConfig['thought'];
    }
    if (_draftConfig['mode'] != null) {
      config['mode'] = _draftConfig['mode'];
    }
    return config.isEmpty ? null : config;
  }

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

  Future<void> _loadOlder() async {
    final state = _state;
    final sessionId = _sessionId;
    if (state == null || sessionId == null || _loadingOlder) return;
    setState(() => _loadingOlder = true);
    try {
      final res = await widget.gateway.rowsRange(
        sessionId,
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
        // Web parity: drop the whole result when the epoch moved — the
        // window no longer belongs to this subscription.
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
        final older =
            rows.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
              ..sort(
                (a, b) => ((a['rowId'] as num?) ?? 0).compareTo(
                  (b['rowId'] as num?) ?? 0,
                ),
              );
        state
          ..hasMore = hasMore
          ..prependOlderRows(older, firstRowId);
        // Prepending shifts the content above; keep the newest message in
        // view when the user is pinned to the bottom.
        if (_stickToBottom) _scrollToBottom();
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
      _syncResetScope(view);
    } catch (_) {
      // Gateways may reject; the banner then stays hidden and the chat is
      // not disturbed.
    }
  }

  /// Reset opportunities ride the same entitlement snapshot: inject the
  /// provider scope into the session-wide controller and refresh it (a
  /// no-op without a provider id — the banner action then never shows).
  void _syncResetScope(EntitlementView view) {
    final controller = widget.gateway.quotaResetController;
    final provider = view.data?['provider'];
    final id = provider is Map ? provider['id'] : null;
    controller.updateScope(id is String && id.isNotEmpty ? id : null);
    unawaited(controller.refresh());
  }

  /// Banner「使用重置券」入口 removed (PRD: the sheet is the single
  /// reset entry) — the dialog + success chain live in [_showResetDialog].
  Future<void> _showResetDialog() async {
    final type = await showQuotaResetDialog(
      context,
      controller: widget.gateway.quotaResetController,
    );
    if (!mounted || type == null) return;
    _toast(tr(context, 'usage.reset.success'));
    // The controller's success chain force-refreshed the poller; re-read
    // it so the exhausted banner flips immediately.
    await _loadEntitlement();
  }

  void _showModelSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _ModelModeSheet(
        gateway: widget.gateway,
        state: _state,
        prep: _prep,
        sessionId: _sessionId,
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

  Future<void> _showPlansSheet() async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    try {
      final plans = await widget.gateway.plans(sessionId);
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

  /// The "更多" dropdown actions (official second header row).
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
            () => widget.gateway.compact(sessionId),
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

  /// Official delete confirmation (confirmDialog.taskDelete*): the session
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
      () => widget.gateway.deleteSession(sessionId),
    );
    if (mounted) Navigator.of(context).maybePop();
  }

  /// Official web order: pin toggle / rename / archive / unread, then the
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

  /// Official content column: messages cap at 848px, the composer at 864px,
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

  @override
  Widget build(BuildContext context) {
    final state = _state;
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
      body: Column(
        children: [
          // Official second header row: task title + workspace chip + 更多.
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
                  if (widget.workspaceLabel != null &&
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
                        color: ZColors.danger,
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
            child: state == null
                ? Center(
                    child: _sessionId == null
                        ? Text(
                            tr(context, 'chat.draftHint'),
                            style: TextStyle(color: ZInk.faint(context)),
                          )
                        : const CircularProgressIndicator(),
                  )
                : !state.ready
                ? const Center(child: CircularProgressIndicator())
                : AnimatedBuilder(
                    animation: state,
                    builder: (context, _) {
                      final groups = _groupRows(state.rows);
                      final itemCount =
                          groups.length + (state.canLoadOlder ? 1 : 0);
                      if (groups.isEmpty && !state.canLoadOlder) {
                        return Center(
                          child: Text(
                            tr(context, 'chat.empty'),
                            style: TextStyle(color: ZInk.faint(context)),
                          ),
                        );
                      }
                      return _contentCol(
                        ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
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
                                            strokeWidth: 1.5,
                                          ),
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
                            final previous = groupIndex > 0
                                ? groups[groupIndex - 1]
                                : null;
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (_timeDividerLabel(previous, group) != null)
                                  _TimeDivider(
                                    label: _timeDividerLabel(previous, group)!,
                                  ),
                                _TurnGroupWidget(
                                  rows: group,
                                  gateway: widget.gateway,
                                  sessionId: _sessionId ?? '',
                                  onAction: _run,
                                  state: state,
                                ),
                              ],
                            );
                          },
                        ),
                      );
                    },
                  ),
          ),
          AnimatedBuilder(
            animation: widget.gateway,
            builder: (context, _) => _GatewayBanner(gateway: widget.gateway),
          ),
          if (state != null)
            AnimatedBuilder(
              animation: state,
              builder: (context, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _GoalBanner(state: state),
                  _GoalProcessPanel(state: state, gateway: widget.gateway),
                  _BackgroundWorksBar(
                    state: state,
                    gateway: widget.gateway,
                  ),
                  _QueueBar(state: state, gateway: widget.gateway),
                  _PendingInteractions(state: state, gateway: widget.gateway),
                ],
              ),
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
          AnimatedBuilder(
            animation: (state == null)
              ? widget.gateway
              : Listenable.merge([state, widget.gateway]),
            builder: (context, _) => _contentCol(
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
                onSend: _send,
                onAttach: _pickFiles,
                onSkills: _openSkillsPicker,
                onModelSheet: _showModelSheet,
                onUsage: _showUsageSheet,
              ),
              maxWidth: _kComposerColumnWidth,
            ),
          ),
        ],
      ),
    );
    return AnimatedBuilder(
      animation: widget.gateway,
      builder: (context, _) => widget.gateway.kicked
          ? Stack(children: [chat, _kickedOverlay(context)])
          : chat,
    );
  }

  Widget _kickedOverlay(BuildContext context) {
    return Positioned.fill(
      child: Material(
        color: ZColors.darkBackground.withValues(alpha: 0.92),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(ZSpacing.emptyState),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.phonelink_erase_outlined,
                  size: 44,
                  color: ZColors.danger,
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
  /// than 10 minutes apart (official timeline separators). Rows without a
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

/// ---------------------------------------------------------------- rows

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
/// 3002/429 限流, 3006 模型不在范围, 3007 验证码, 3008-3010 系统繁忙, 2007 上游
/// 不可用). When the failure text mentions one, show the official line
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

/// Splits an assistant-turn group into ORDERED parts — consecutive
/// assistantText rows merge into one text segment, while reasoning/tool/
/// subagent rows stay exactly where they occurred in the stream (so
/// "thinking → tool → answer" never renders as "answer → thinking").
typedef AssistantTurnParts = ({
  List<AssistantPart> parts,
  Map<String, dynamic>? header,
  bool streaming,
});

/// Execute-family tool rows (bash/terminal/exec/...) share one summary
/// card when consecutive — web executeGroup「终端 · N 个命令」parity.
bool _isExecuteTool(Map<String, dynamic> row) {
  if (row['kind'] != 'toolCall') return false;
  final t = '${row['toolName'] ?? ''}'.toLowerCase();
  return t.contains('bash') ||
      t.contains('terminal') ||
      t.contains('exec') ||
      t.contains('command');
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
    } else if (_isExecuteTool(row)) {
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

/// Groups rows into turns (mirrors the web timeline): a user message starts
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

  const _TurnGroupWidget({
    required this.rows,
    required this.gateway,
    required this.sessionId,
    required this.onAction,
    required this.state,
  });

  @override
  State<_TurnGroupWidget> createState() => _TurnGroupWidgetState();
}

/// One turn group: user bubble (if any) → turn header (已工作 N + pill,
/// official renders it at the TOP of the turn) → ordered assistant parts →
/// file-changes card (official always-visible rounded bar with 撤销).
class _TurnGroupWidgetState extends State<_TurnGroupWidget> {
  bool _showChanges = true;

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
          row: first,
          gateway: gateway,
          sessionId: sessionId,
          onAction: onAction,
          state: widget.state,
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
          ),
        );
      } else if (p.kind == 'rowGroup') {
        children.add(
          _ToolGroupCard(
            rows: p.group ?? [if (p.row != null) p.row!],
            gateway: gateway,
            sessionId: sessionId,
            onAction: onAction,
            state: widget.state,
          ),
        );
      } else {
        children.add(
          _RowWidget(
            row: p.row!,
            showFeedback: false,
            gateway: gateway,
            sessionId: sessionId,
            onAction: onAction,
            state: widget.state,
          ),
        );
      }
    }

    // Official file-changes card at the end of the turn.
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

  const _RowWidget({
    required this.row,
    required this.gateway,
    required this.sessionId,
    required this.onAction,
    required this.state,
    this.showFeedback = true,
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
      builder: (context) => SafeArea(
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
                  () => gateway.retryTurn(sessionId, _target),
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
                  () => gateway.forkAssistant(sessionId, _target),
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
            child: Text(tr(context, 'chat.action.edit.resend')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.isEmpty || !context.mounted) return;
    await onAction(
      tr(context, 'chat.action.edit.failed'),
      () => gateway.editUserQuery(sessionId, _target, text),
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
      () => gateway.applyFileRewind(sessionId, _target),
    );
  }

  Future<void> _showFileChanges(BuildContext context) async {
    try {
      final changes = await gateway.fileChanges(sessionId, target: _target);
      if (!context.mounted) return;
      showModalBottomSheet(
        context: context,
        showDragHandle: true,
        builder: (context) => _JsonSheet(
          title: tr(context, 'chat.action.fileChanges'),
          data: changes,
        ),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              trP(context, 'chat.action.fileChanges.failed', ['$e']),
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
        showFeedback: showFeedback,
      ),
      'reasoning' => _ReasoningTile(
        text: row['text'] as String? ?? '',
        streaming: row['state'] == 'streaming',
      ),
      'toolCall' => _ToolCallTile(row: row),
      // turnHeader rows are lifted out of the stream by _TurnGroupWidget
      'turnHeader' => const SizedBox.shrink(),
      'subagent' => _SubagentTile(
        row: row,
        gateway: gateway,
        sessionId: sessionId,
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
              color: ZColors.darkCard,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(ZRadius.tile),
                topRight: Radius.circular(ZRadius.tile),
                bottomLeft: Radius.circular(ZRadius.tile),
                bottomRight: Radius.circular(ZRadius.mini),
              ),
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
            child: Text(tr(context, 'chat.action.edit.resend')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newText == null || newText.isEmpty || !context.mounted) return;
    try {
      await widget.gateway.editUserQuery(widget.sessionId, {
        'rowId': widget.row['rowId'],
        if (widget.row['entityId'] != null) 'entityId': widget.row['entityId'],
      }, newText);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(trP(context, 'chat.action.edit.failed', ['$e'])),
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
      final res = await widget.gateway.attachmentRead(
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
      child: ClipRRect(
        borderRadius: BorderRadius.circular(ZRadius.field),
        child: Image.memory(_imageBytes!, width: 220, fit: BoxFit.cover),
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

  const _AssistantBubble({
    required this.row,
    required this.gateway,
    required this.sessionId,
    required this.state,
    this.showFeedback = true,
  });

  void _setFeedback(String? value) {
    if (sessionId.isEmpty) return;
    // Optimistic: update the icon instantly; server row.upserted confirms.
    state.optimisticRowUpdate(row['rowId'] as num?, {'feedback': value});
    gateway.setAssistantFeedback(sessionId, {
      'rowId': row['rowId'],
      if (row['entityId'] != null) 'entityId': row['entityId'],
    }, value);
  }

  @override
  Widget build(BuildContext context) {
    final text = row['text'] as String? ?? '';
    final streaming = row['state'] == 'streaming';
    final feedback = row['feedback'] as String?;
    final timestamp = _ChatPageState._rowTimestamp(row);
    return Container(
      margin: const EdgeInsets.only(right: 24, top: 8, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ZLinkerMarkdown(text),
          if (showFeedback)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (streaming)
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
                    onTap: () => gateway.forkAssistant(sessionId, {
                      'rowId': row['rowId'],
                      if (row['entityId'] != null) 'entityId': row['entityId'],
                    }),
                  ),
                ],
                const Spacer(),
                if (timestamp != null && !streaming)
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
              child: ZLinkerMarkdown(text, bodyStyle: ZType.sub),
            ),
          ],
        ),
      ),
    );
  }
}

/// Official-style tool summary: icon + "已写入 file +N" / "终端 · cmd" /
/// "探索 · N 文件", expandable to input/output/diff. The diff body lives
/// INSIDE the expansion (collapsed by default — long agent dumps must not
/// flood the chat); the live progress row stays always visible.
class _ToolCallTile extends StatelessWidget {
  final Map<String, dynamic> row;

  const _ToolCallTile({required this.row});

  @override
  Widget build(BuildContext context) {
    final status = row['status'] as String? ?? '';
    final inputText = row['inputText'] as String? ?? '';
    final output = row['output'];
    final outputText = output is Map ? output['text'] as String? ?? '' : '';
    final error = row['error'];
    final progress = row['progress'];
    final display = row['display'];
    final diff = extractDiff(row);

    final (icon, color) = switch (status) {
      'running' ||
      'inputStreaming' ||
      'pendingApproval' => (Icons.hourglass_top, ZColors.sky400),
      'success' => (Icons.check, ZColors.success),
      'error' => (Icons.error_outline, ZColors.danger),
      'cancelled' => (Icons.block, ZColors.warning),
      _ => (Icons.build_outlined, ZInk.faint(context)),
    };

    final images =
        display is Map &&
            display['kind'] == 'node_repl_images' &&
            display['images'] is List
        ? display['images'] as List
        : const [];

    final summary = _toolSummary(context, row, diff);

    // Official tool row: bold-ish first line (已写入 <file> / 终端 · cmd /
    // 探索 · N 文件) with +/- counts right-aligned; second line = directory
    // path (write/edit) or the tool name.
    final title = Row(
      children: [
        Expanded(
          child: Text(
            summary.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ZType.body.copyWith(
              fontWeight: FontWeight.w500,
              color: ZInk.solid(context),
            ),
          ),
        ),
        if (summary.additions > 0)
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Text(
              '+${summary.additions}',
              style: ZType.caption.copyWith(color: ZColors.success),
            ),
          ),
        if (summary.deletions > 0)
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              '-${summary.deletions}',
              style: ZType.caption.copyWith(color: ZColors.danger),
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
                onExpansionChanged: (_) => HapticFeedback.lightImpact(),
                tilePadding: ZTile.head,
                leading: Icon(icon, size: ZTile.iconSize, color: color),
                title: title,
                subtitle: subtitle,
                children: [
                  // File edits show only the diff: the raw input/output JSON
                  // of a write/edit call is noise the official web omits too.
                  if (diff == null && inputText.isNotEmpty)
                    _kv(context, tr(context, 'chat.tool.input'), inputText),
                  if (diff == null && outputText.isNotEmpty)
                    _kv(context, tr(context, 'chat.tool.output'), outputText),
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
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(ZRadius.field),
                          child: Image.memory(
                            base64Decode(image['base64'] as String),
                            fit: BoxFit.contain,
                            errorBuilder: (context, error, stackTrace) =>
                                const SizedBox.shrink(),
                          ),
                        ),
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

  /// Official tool summary: first line (已写入 `<file>` / 终端 · cmd /
  /// 探索 · N 文件), optional second line (directory path), +/- counts.
  static ({String title, String? subtitle, int additions, int deletions})
  _toolSummary(BuildContext context, Map<String, dynamic> row, DiffData? diff) {
    final toolNameRaw = row['toolName'] as String? ?? 'tool';
    final toolName = toolNameRaw.toLowerCase();
    final inputText = row['inputText'] as String? ?? '';

    if (toolName.contains('write') ||
        toolName.contains('edit') ||
        toolName.contains('notebook')) {
      final file = _filePath(inputText) ?? diff?.filePath ?? toolNameRaw;
      // title shows the basename; subtitle the directory (official style)
      final segs = file.split(RegExp(r'[\\/]'));
      final base = segs.last;
      final dir = segs.length > 1
          ? segs.sublist(0, segs.length - 1).join('/')
          : null;
      return (
        title: trP(context, 'chat.tool.wrote', [base]),
        subtitle: dir,
        additions: diff?.additions ?? 0,
        deletions: diff?.deletions ?? 0,
      );
    }
    if (toolName.contains('taskoutput')) {
      // Web chat.toolCall.taskOutput.* states, keyed off the row status
      // machine (pending/running/completed/failed/denied/stopped).
      final st = '${row['status'] ?? ''}';
      final title = switch (st) {
        'pending' => tr(context, 'chat.tool.taskOutput.fetching'),
        'running' => tr(context, 'chat.tool.taskOutput.running'),
        'failed' => tr(context, 'chat.tool.taskOutput.failed'),
        'denied' => tr(context, 'chat.tool.taskOutput.denied'),
        'stopped' => tr(context, 'chat.tool.taskOutput.stopped'),
        _ => tr(context, 'chat.tool.taskOutput.retrieved'),
      };
      return (
        title: '${tr(context, 'chat.tool.taskOutput.kind')} · $title',
        subtitle: null,
        additions: 0,
        deletions: 0,
      );
    }
    if (toolName.contains('taskstop')) {
      final st = '${row['status'] ?? ''}';
      final title = switch (st) {
        'pending' || 'running' =>
          tr(context, 'chat.tool.taskStop.stopping'),
        'failed' => tr(context, 'chat.tool.taskStop.failed'),
        'denied' => tr(context, 'chat.tool.taskStop.denied'),
        'stopped' => tr(context, 'chat.tool.taskStop.cancelled'),
        _ => tr(context, 'chat.tool.taskStop.stopped'),
      };
      return (
        title: '${tr(context, 'chat.tool.taskStop.kind')} · $title',
        subtitle: null,
        additions: 0,
        deletions: 0,
      );
    }
    if (toolName.contains('sendmessage')) {
      final st = '${row['status'] ?? ''}';
      final title = switch (st) {
        'pending' || 'running' => tr(context, 'chat.tool.send.sending'),
        'failed' => tr(context, 'chat.tool.send.failed'),
        'denied' => tr(context, 'chat.tool.send.denied'),
        'stopped' => tr(context, 'chat.tool.send.stopped'),
        _ => tr(context, 'chat.tool.send.sent'),
      };
      return (
        title: '${tr(context, 'chat.tool.send.kind')} · $title',
        subtitle: null,
        additions: 0,
        deletions: 0,
      );
    }
    if (toolName.contains('askuserquestion') ||
        toolName.contains('ask_user_question')) {
      // Web chat.askQuestion.* parity: asking → asked · N questions →
      // no-answer / auto-continued. Question count comes from the input
      // JSON's questions array when parseable (no guessed fields beyond
      // that); output text carries the auto-continue notice.
      final running = row['status'] == 'running' || row['status'] == 'pending';
      final outputText = row['outputText'] as String? ?? '';
      var count = 0;
      try {
        final input = jsonDecode(inputText);
        if (input is Map && input['questions'] is List) {
          count = (input['questions'] as List).length;
        }
      } catch (_) {}
      final noAnswer = outputText.isNotEmpty &&
          (outputText.contains('未提供回答') ||
              outputText.contains('No answer') ||
              outputText.contains('auto-continued') ||
              outputText.contains('自动继续'));
      return (
        title: running
            ? tr(context, 'chat.tool.askQuestion.asking')
            : noAnswer
                ? tr(context, 'chat.tool.askQuestion.autoContinued')
                : count > 0
                    ? trP(context, 'chat.tool.askQuestion.askedN',
                        ['$count'])
                    : tr(context, 'chat.tool.askQuestion.asked'),
        subtitle: null,
        additions: 0,
        deletions: 0,
      );
    }
    if (toolName.contains('bash') ||
        toolName.contains('terminal') ||
        toolName.contains('exec') ||
        toolName.contains('command')) {
      final cmd = _firstLine(inputText);
      return (
        title: cmd.isEmpty
            ? tr(context, 'chat.tool.terminal')
            : '${tr(context, 'chat.tool.terminal')} · $cmd',
        subtitle: toolNameRaw,
        additions: 0,
        deletions: 0,
      );
    }
    if (toolName.contains('read') ||
        toolName.contains('glob') ||
        toolName.contains('grep') ||
        toolName.contains('explore') ||
        toolName.contains('search')) {
      final count = _fileCount(inputText) ?? _fileCountFromText(inputText);
      final file = _filePath(inputText);
      if (count != null) {
        return (
          title: trP(context, 'chat.tool.exploreN', ['$count']),
          subtitle: toolNameRaw,
          additions: 0,
          deletions: 0,
        );
      }
      if (file != null) {
        return (
          title: '${tr(context, 'chat.tool.explore')} · $file',
          subtitle: toolNameRaw,
          additions: 0,
          deletions: 0,
        );
      }
      return (
        title: tr(context, 'chat.tool.explore'),
        subtitle: toolNameRaw,
        additions: 0,
        deletions: 0,
      );
    }
    return (
      title: toolNameRaw,
      subtitle: null,
      additions: diff?.additions ?? 0,
      deletions: diff?.deletions ?? 0,
    );
  }

  static String? _filePath(String inputText) {
    try {
      final decoded = jsonDecode(inputText);
      if (decoded is Map) {
        for (final key in const [
          'filePath',
          'file_path',
          'path',
          'file',
          'notebookPath',
        ]) {
          final v = decoded[key];
          if (v is String && v.isNotEmpty) return v;
        }
      }
    } catch (_) {}
    final match = RegExp(
      r'"(?:file_?[Pp]ath|path|file)"\s*:\s*"([^"]+)"',
    ).firstMatch(inputText);
    return match?.group(1);
  }

  static int? _fileCount(String inputText) {
    try {
      final decoded = jsonDecode(inputText);
      if (decoded is Map) {
        for (final key in const ['paths', 'files', 'filePaths']) {
          final v = decoded[key];
          if (v is List) return v.length;
          if (v is String && v.isNotEmpty) return 1;
        }
        for (final key in const ['path', 'filePath', 'file']) {
          if (decoded[key] is String) return 1;
        }
      }
    } catch (_) {}
    return null;
  }

  /// Fallback counter for streaming (not-yet-valid-JSON) input.
  static int? _fileCountFromText(String inputText) {
    final matches = RegExp(r'"(?:path|file)"\s*:').allMatches(inputText).length;
    return matches > 0 ? matches : null;
  }

  static String _firstLine(String inputText) {
    try {
      final decoded = jsonDecode(inputText);
      if (decoded is Map) {
        for (final key in const ['command', 'cmd', 'script']) {
          final v = decoded[key];
          if (v is String && v.isNotEmpty) {
            final line = v.split('\n').first.trim();
            return line.length > 60 ? line.substring(0, 60) : line;
          }
        }
      }
    } catch (_) {}
    if (inputText.isEmpty) return '';
    final line = inputText.split('\n').first.trim();
    return line.length > 60 ? line.substring(0, 60) : line;
  }

  Widget _kv(BuildContext context, String label, String value) {
    // Pretty-print JSON input when possible (official shows structured view)
    var display = value;
    try {
      final decoded = jsonDecode(value);
      display = const JsonEncoder.withIndent('  ').convert(decoded);
    } catch (_) {}
    return Padding(
      padding: ZTile.body,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: ZType.caption.copyWith(color: ZInk.faint(context)),
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
/// Turn header at the TOP of a turn (official): 「已工作 N 分 N 秒」灰字 +
/// chevron (toggles the file-changes card), status pill on the right.
class _TurnHeader extends StatelessWidget {
  final Map<String, dynamic> row;
  final bool hasChanges;
  final bool expanded;
  final VoidCallback onToggle;

  const _TurnHeader({
    required this.row,
    required this.hasChanges,
    required this.expanded,
    required this.onToggle,
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
          if (phaseKey != null)
            PhasePill(label: tr(context, phaseKey), phase: phase),
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
                      style: const TextStyle(color: ZColors.success),
                    ),
                  if (dels > 0)
                    TextSpan(
                      text: '  -$dels',
                      style: const TextStyle(color: ZColors.danger),
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
        final preview = await gateway.fileRewindPreview(sessionId,
            target: target);
        if (!context.mounted) return null;
        final ok = await _showPreviewDialog(context, preview);
        if (ok != true) return null;
        return gateway.applyFileRewind(sessionId, target);
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
                          style: ZType.body.copyWith(color: ZColors.danger),
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
        ZColors.warning,
      ),
      'goalSet' => (
        Icons.flag_outlined,
        trP(context, 'chat.marker.goalSet', ['${marker['objective'] ?? ''}']),
        ZColors.success,
      ),
      'goalVerify' => (
        Icons.fact_check_outlined,
        trP(context, 'chat.marker.goalVerify', [
          '${marker['iteration'] ?? '?'}',
          '${marker['outcome'] ?? ''}',
        ]),
        ZColors.success,
      ),
      'retryNotice' => (
        Icons.refresh,
        trP(context, 'chat.marker.retryNotice', [
          '${marker['attempt'] ?? '?'}',
          '${marker['reasonCode'] ?? ''}',
        ]),
        ZColors.warning,
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

class _SubagentTile extends StatelessWidget {
  final Map<String, dynamic> row;
  final ChatGateway gateway;
  final String sessionId;

  const _SubagentTile({
    required this.row,
    required this.gateway,
    required this.sessionId,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      // Whole tile opens the read-only child-session detail page.
      onTap: () => _openSubagentDetail(
        context,
        gateway,
        childSessionId: row['childSessionId'] as String?,
        subagentType: row['subagentType'] as String?,
        workId: row['workId'] as String?,
        parentSessionId: sessionId,
        running: row['status'] == 'running',
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
                      '${row['status'] ?? ''}  ${row['summaryText'] ?? ''}',
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
          const Icon(Icons.flag_outlined, size: 14, color: ZColors.success),
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
              style: ZType.caption.copyWith(color: ZColors.success),
            ),
        ],
      ),
    );
  }
}

/// Bridges the conversation snapshot's goal/subagent data to the
/// web 目标面板 parity widget (hidden when no goal is set — the plain
/// _GoalBanner covers that case).
class _GoalProcessPanel extends StatelessWidget {
  final ConversationState state;
  final ChatGateway gateway;

  const _GoalProcessPanel({required this.state, required this.gateway});

  @override
  Widget build(BuildContext context) {
    if (state.snapshot?['goal'] is! Map) return const SizedBox.shrink();
    return GoalPanel(
      state: state,
      onPauseGoal: (sid) => gateway.pauseGoal(sid),
      onResumeGoal: (sid) => gateway.resumeGoal(sid),
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

class _BackgroundWorksBar extends StatelessWidget {
  final ConversationState state;
  final ChatGateway gateway;

  const _BackgroundWorksBar({required this.state, required this.gateway});

  /// Live action stream of a subagent work: the `kind=='subagent'` row in
  /// [state.rows] matching [childSessionId] appends to `summaryText`
  /// (it starts as the title, streaming actions after — live-probed
  /// 2026-09-13). Returns the action text beyond [title], or '' when no
  /// matching row exists yet (backgrounding can precede the row).
  String _subagentTail(String? childSessionId, String title) {
    final sid = childSessionId ?? '';
    if (sid.isEmpty) return '';
    for (final row in state.rows) {
      if (row['kind'] != 'subagent' || row['childSessionId'] != sid) continue;
      final summary = row['summaryText'] as String? ?? '';
      if (summary.isEmpty || summary == title) return '';
      if (title.isNotEmpty && summary.startsWith(title)) {
        return summary
            .substring(title.length)
            .replaceFirst(RegExp(r'^[，,·:：/、\s]+'), '');
      }
      return summary;
    }
    return '';
  }

  Widget _cancelButton(BuildContext context, String sessionId, Map work) {
    return IconButton(
      icon: Icon(Icons.close, size: 14, color: ZInk.muted(context)),
      tooltip: tr(context, 'chat.bgWorks.cancel'),
      visualDensity: VisualDensity.compact,
      onPressed: () {
        final workId = "${work['workId'] ?? work['id'] ?? ''}";
        if (workId.isEmpty) return;
        gateway.cancelBackgroundWork(sessionId, workId);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final works = state.backgroundWorks
        .where((w) => w['status'] == 'running' && w['endedAt'] == null)
        .toList();
    if (works.isEmpty) return const SizedBox.shrink();
    final sessionId = state.snapshot?['sessionId'] as String? ?? '';
    // Subagent works get one live row each (summary stream + detail-page
    // entry); bash & co. keep the single compact count line.
    final subagentWorks = works.where((w) => w['kind'] == 'subagent').toList();
    final plainWorks = works.where((w) => w['kind'] != 'subagent').toList();
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: ZInk.tile(context),
        borderRadius: BorderRadius.circular(ZRadius.tile),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (plainWorks.isNotEmpty)
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
                  _cancelButton(context, sessionId, w),
              ],
            ),
          for (final w in subagentWorks)
            Builder(
              builder: (rowContext) {
                final title = '${w['title'] ?? w['subagentType'] ?? ''}';
                final tail = _subagentTail(
                  w['childSessionId'] as String?,
                  title,
                );
                return InkWell(
                  onTap: () => _openSubagentDetail(
                    rowContext,
                    gateway,
                    childSessionId: w['childSessionId'] as String?,
                    title: w['title'] as String?,
                    subagentType: w['subagentType'] as String?,
                    workId: w['workId'] as String?,
                    parentSessionId: sessionId,
                    running: w['status'] == 'running',
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
                          tail.isEmpty ? title : '$title · $tail',
                          style: ZType.caption.copyWith(
                            color: ZInk.soft(context),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      _cancelButton(context, sessionId, w),
                    ],
                  ),
                );
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
      // Official web: the queue is a neutral sub-surface inside the composer
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
                  gateway.setAutoDrain(sessionId, next);
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
          // Official web parity: each queued message is its own pill row with
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
                    color: Theme.of(context).brightness == Brightness.dark
                        ? ZColors.darkCard
                        : ZColors.lightCard,
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
                          gateway.sendQueuedNow(sessionId, id);
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
                          gateway.deleteQueueItem(sessionId, id);
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

  /// Web drag-to-reorder parity: the same `reorderQueueItem
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
    gateway.reorderQueueItem(sessionId, id, beforeId);
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
    await gateway.editQueueItem(sessionId, '${item['queueItemId']}', text);
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

  const _ToolGroupCard({
    required this.rows,
    required this.gateway,
    required this.sessionId,
    required this.onAction,
    required this.state,
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
          _InteractionCard(
            interaction: interaction,
            onResolve: ({optionId, freeText, action, content}) =>
                gateway.resolveInteraction(
                  sessionId,
                  interaction['interactionId'] as String? ?? '',
                  optionId: optionId,
                  freeText: freeText,
                  action: action,
                  content: content,
                ),
            onSnooze: () => gateway.snoozeInteraction(
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
              const Icon(
                Icons.privacy_tip_outlined,
                size: 14,
                color: ZColors.warning,
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
              onResolve: (question, selected) =>
                  _resolve(content: {question: selected}),
            ),
          if (freeText)
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

/// Renders a form-style `userInput` interaction (the `questions` payload):
/// the current question (by `currentQuestionIndex`) with its options.
class _QuestionsView extends StatelessWidget {
  final List<Map> questions;
  final bool busy;
  final void Function(String question, List<String> selected) onResolve;

  const _QuestionsView({
    required this.questions,
    required this.busy,
    required this.onResolve,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < questions.length; i++)
          _QuestionItem(
            index: i,
            question: questions[i],
            busy: busy,
            onSelect: (selected) =>
                onResolve('${questions[i]['value'] ?? 'answer_$i'}', selected),
          ),
      ],
    );
  }
}

class _QuestionItem extends StatefulWidget {
  final int index;
  final Map question;
  final bool busy;
  final void Function(List<String> selected) onSelect;

  const _QuestionItem({
    required this.index,
    required this.question,
    required this.busy,
    required this.onSelect,
  });

  @override
  State<_QuestionItem> createState() => _QuestionItemState();
}

class _QuestionItemState extends State<_QuestionItem> {
  final List<String> _selected = [];

  @override
  Widget build(BuildContext context) {
    final q = widget.question;
    final label = q['label'] ?? q['question'] ?? q['value'] ?? '';
    final options = q['options'];
    final multi = q['multiSelect'] == true;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${widget.index + 1}. $label',
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
          if (options is List && options.isNotEmpty)
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
                        selected: _selected.contains('${o['value']}'),
                        onSelected: widget.busy
                            ? null
                            : (on) {
                                setState(() {
                                  if (multi) {
                                    if (on) {
                                      _selected.add('${o['value']}');
                                    } else {
                                      _selected.remove('${o['value']}');
                                    }
                                  } else {
                                    _selected
                                      ..clear()
                                      ..add('${o['value']}');
                                  }
                                });
                                if (!multi) {
                                  widget.onSelect(List.of(_selected));
                                }
                              },
                      ),
                ],
              ),
            ),
          if (multi)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: widget.busy
                    ? null
                    : () => widget.onSelect(List.of(_selected)),
                child: Text(
                  tr(context, 'chat.interact.submit'),
                  style: ZType.sub,
                ),
              ),
            ),
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
  final Map<String, String>? draftConfig;
  final void Function(String key, String value)? onDraftChange;

  const _ModelModeSheet({
    required this.gateway,
    required this.state,
    required this.prep,
    required this.sessionId,
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
    final modeOption = prep?.option('mode');
    final thoughtOption = prep?.option('thought_level');
    final followup = '${config['followupMode'] ?? 'queue'}';

    // Current selection: prefer the LIVE session config (updates after a
    // switch), fall back to prepareWorkspace's currentValue / draft.
    final liveModelValue =
        '${config['provider'] ?? ''}/${config['model'] ?? ''}';
    final currentModelValue =
        _isDraft || config['model'] == null || '${config['model']}'.isEmpty
        ? (draftConfig?['model'] ?? '${modelOption?.currentValue ?? ''}')
        : liveModelValue;
    final currentThoughtValue = _isDraft
        ? (draftConfig?['thought'] ?? '${thoughtOption?.currentValue ?? ''}')
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
            if (modelOption != null && modelOption.options.isNotEmpty) ...[
              Text(
                modelOption.name,
                style: ZType.body.copyWith(color: ZInk.solid(context)),
              ),
              const SizedBox(height: 8),
              // Official web menu groups models by provider (BigModel /
              // tx / kimi_zz …): header whenever the provider changes.
              for (final (i, v) in modelOption.options.indexed) ...[
                if (i == 0 ||
                    v.modelProviderName !=
                        modelOption.options[i - 1].modelProviderName)
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
                      _apply(
                        context,
                        () => gateway.switchModelConfig(
                          sid,
                          provider: provider,
                          model: model,
                          thought: thought,
                        ),
                        onAccepted: () => state?.optimisticPatch({
                          'config': {
                            ...?state!.config,
                            'provider': provider,
                            'model': model,
                            'thought': thought,
                          },
                        }),
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
                          _apply(
                            context,
                            () => gateway.switchModelConfig(
                              sid,
                              provider: provider,
                              model: model,
                              thought: v.value,
                            ),
                            onAccepted: () => state?.optimisticPatch({
                              'config': {...?state!.config, 'thought': v.value},
                            }),
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
                        () => gateway.switchModelConfig(
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
                  title: Text(
                    v.name,
                    style: ZType.body.copyWith(color: ZInk.solid(context)),
                  ),
                  subtitle: v.description != null
                      ? Text(
                          v.description!,
                          style: ZType.caption.copyWith(
                            color: ZInk.faint(context),
                          ),
                        )
                      : null,
                  onTap: () {
                    if (_isDraft) {
                      onDraftChange?.call('mode', v.value);
                    } else {
                      _apply(
                        context,
                        () => gateway.switchCollaborationMode(sid, v.value),
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
                        () => gateway.switchCollaborationMode(sid, m),
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
                        () => gateway.setFollowupMode(sid, f),
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

  Future<void> _apply(
    BuildContext context,
    Future<dynamic> Function() run, {
    void Function()? onAccepted,
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
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(trP(context, 'chat.op.failed', ['$e']))),
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
  final VoidCallback onUseReset;

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
  /// below (track #353535; orange above the >0.8 high-ratio threshold).
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
                _fmtCompactTokens(context, view.used!),
                _fmtCompactTokens(context, view.max!),
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
          track: _usageTrackColor,
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
                      color: ZColors.usageBlue
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

  /// R4 — remaining quota: reset countdown and the 5-hour pill come from
  /// the `TOKENS_LIMIT(3,5)` window, the reset-credit row is the ZLinker
  /// entry point. Rows (and the whole block) hide when their data is
  /// absent; nothing renders as a placeholder.
  Widget _remainingSection(BuildContext context) {
    final limit = _entitlementLimit(
      entitlement,
      'TOKENS_LIMIT',
      unit: 3,
      number: 5,
    );
    // Official semantics: the panel shows what's LEFT of the window, not
    // what's used (bundle PF: clamp(100 - percentage)).
    final percent = _remainingPercent(limit);
    final countdown = _resetCountdown(context, limit?['nextResetTime']);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final pools = controller.pools;
        final credits =
            pools == null ? 0 : pools.fiveHour.count + pools.week.count;
        if (percent == null && countdown == null && credits == 0) {
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
              if (countdown != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    trP(context, 'chat.usage.remaining.resetsIn', [countdown]),
                    style: ZType.sub.copyWith(color: ZColors.usageGreen),
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
                          color: ZColors.usageGreen.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(ZRadius.field),
                        ),
                        child: Text(
                          tr(context, 'chat.usage.limit.fiveHour'),
                          style: ZType.caption.copyWith(
                            height: 1.2,
                            color: ZColors.usageGreen,
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
                      color: ZColors.usageGreen.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          trP(context, 'chat.usage.resetCredits', ['$credits']),
                          style: ZType.sub.copyWith(color: ZInk.muted(context)),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: onUseReset,
                        style: TextButton.styleFrom(
                          backgroundColor:
                              ZColors.usageGreen.withValues(alpha: 0.15),
                          foregroundColor: ZColors.usageGreen,
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

  /// R5 — three equal-width limit columns, all in official remaining
  /// semantics (bundle `PF`: `clamp(100 - percentage)`). 工具调用 is the
  /// monthly built-in tool quota (entitlementMonthlyMcpUsage), ZCode MCP
  /// the server-side aggregate (entitlementServerMcpUsage); a limit absent
  /// from the snapshot drops its column.
  Widget _limitsColumns(BuildContext context) {
    final fiveHour = _remainingPercent(
      _entitlementLimit(entitlement, 'TOKENS_LIMIT', unit: 3, number: 5),
    );
    final toolCalls = _remainingPercent(
      _entitlementLimit(entitlement, 'TIME_LIMIT', unit: 5, number: 1),
    );
    final zcodeMcp = _remainingPercent(_serverMcpLimit(entitlement));
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
  /// color is a fixed per-column tone (the official chart scale), not a
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
          track: ZColors.neutral700,
          orange: orange,
        ),
      ],
    );
  }
}

/// Reference-panel tones without a ZColors token: the capacity-bar track
/// and the gradient's deep stop (#353535 / #4185D5, pixel spec).
const _usageTrackColor = Color(0xFF353535);
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
    final fill = orange ? ZColors.usageOrange : ZColors.usageBlue;
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
                    ? const LinearGradient(
                        colors: [ZColors.usageBlue, _usageBlueDeep],
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
/// line up column-wise, mirroring the reference's tabular-nums). [base] picks
/// the tier — the panel uses [ZType.body], [ZType.sub] and [ZType.bodyStrong].
TextStyle _usageNumber(BuildContext context, TextStyle base) {
  return base.copyWith(
    color: ZInk.solid(context),
    fontFeatures: const [FontFeature.tabularFigures()],
  );
}

/// Official `kZe` mapping: breakdown source → i18n key. Unknown sources
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

/// Percent with at most one decimal (official maximumFractionDigits: 1).
String _fmtPercent(double ratio) => _fmtPercentValue(ratio * 100);

/// Same formatting for an already-percent value (entitlement percentages
/// arrive as 0..100).
String _fmtPercentValue(double percent) => percent == percent.roundToDouble()
    ? '${percent.round()}%'
    : '${percent.toStringAsFixed(1)}%';

/// Capacity-line token count: zh renders 万 with one decimal (19.4万),
/// en the k/M scale (194k); trailing `.0` is dropped on both (R1).
String _fmtCompactTokens(BuildContext context, int n) {
  final english =
      (UiSettingsProvider.of(context)?.locale ?? 'zh-CN').startsWith('en');
  if (!english) return '${_trimZero(n / 10000)}万';
  if (n >= 1000000) return '${_trimZero(n / 1000000)}M';
  if (n >= 1000) return '${_trimZero(n / 1000)}k';
  return '$n';
}

/// One decimal with a trailing `.0` removed (30万, not 30.0万).
String _trimZero(double v) {
  final s = v.toStringAsFixed(1);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

/// Exact `type`(+`unit`/`number`) lookup over the entitlement snapshot's
/// `quota.limits` (the official `MF`), same parsing idea as the usage page.
Map<String, dynamic>? _entitlementLimit(
  EntitlementView? view,
  String type, {
  int? unit,
  int? number,
}) {
  final quota = view?.data?['quota'];
  final limits = quota is Map ? quota['limits'] : null;
  if (limits is! List) return null;
  for (final e in limits) {
    if (e is! Map) continue;
    if (e['type'] != type) continue;
    if (unit != null && e['unit'] != unit) continue;
    if (number != null && e['number'] != number) continue;
    return e.cast<String, dynamic>();
  }
  return null;
}

double? _limitPercent(Map<String, dynamic>? limit) =>
    (limit?['percentage'] as num?)?.toDouble();

/// Official PF: remaining% = clamp(100 - percentage) — every quota metric
/// on the panel shows what is LEFT of the limit, never what is used.
double? _remainingPercent(Map<String, dynamic>? limit) {
  final used = _limitPercent(limit);
  if (used == null) return null;
  return (100 - used).clamp(0.0, 100.0);
}

/// Server MCP usage (`mcpQuota.aggregate`) as a limit-shaped map so the
/// columns can read it through the same remaining-percent path.
Map<String, dynamic>? _serverMcpLimit(EntitlementView? view) {
  final mcpQuota = view?.data?['mcpQuota'];
  final aggregate = mcpQuota is Map ? mcpQuota['aggregate'] : null;
  return aggregate is Map ? aggregate.cast<String, dynamic>() : null;
}

/// Reset countdown「20 小时 13 分钟」for a `nextResetTime` ms epoch; null
/// when the timestamp is absent or already past (the row then hides).
String? _resetCountdown(BuildContext context, Object? nextResetTime) {
  if (nextResetTime is! num) return null;
  final remaining = DateTime.fromMillisecondsSinceEpoch(nextResetTime.toInt())
      .difference(DateTime.now());
  if (remaining.isNegative) return null;
  final minutes = remaining.inMinutes % 60;
  return [
    if (remaining.inHours > 0)
      trP(context, 'chat.usage.duration.hours', ['${remaining.inHours}']),
    trP(context, 'chat.usage.duration.minutes', ['$minutes']),
  ].join(' ');
}

class _JsonSheet extends StatelessWidget {
  final String title;
  final Object? data;

  const _JsonSheet({required this.title, required this.data});

  @override
  Widget build(BuildContext context) {
    const encoder = JsonEncoder.withIndent('  ');
    return SafeArea(
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
          color: ZColors.darkCard,
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
        color: ZColors.darkCard,
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
                command.isSkill
                    ? Icons.auto_awesome_outlined
                    : (command.name == 'compact' ? Icons.compress : Icons.bolt),
                size: 16,
                color: command.isSkill ? ZColors.warning : ZColors.sky500,
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
                        leading: const Icon(
                          Icons.auto_awesome_outlined,
                          size: 18,
                          color: ZColors.warning,
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

/// Official composer: rounded container with the text field on top and a
/// control row underneath — left: add-context / mode chip; right: usage
/// ring, model chip, thought chip, send/stop button.
///
/// Stateful: listens to the text controller so the send button's
/// empty-input disabled state (official web) updates on every keystroke
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

  final VoidCallback onSend;
  final VoidCallback onAttach;
  final VoidCallback onSkills;
  final VoidCallback onModelSheet;
  final VoidCallback onUsage;

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
    required this.onSend,
    required this.onAttach,
    required this.onSkills,
    required this.onModelSheet,
    required this.onUsage,
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

  bool get _hasInput =>
      widget.controller.text.trim().isNotEmpty || widget.hasAttachments;

  // Field forwarders so the build/helpers below read like the original
  // stateless widget.
  TextEditingController get controller => widget.controller;
  bool get sending => widget.sending;
  bool get isDraft => widget.isDraft;
  ConversationState? get state => widget.state;
  WorkspacePrep? get prep => widget.prep;
  Map<String, String>? get draftConfig => widget.draftConfig;
  ChatGateway get gateway => widget.gateway;
  String? get sessionId => widget.sessionId;
  VoidCallback get onSend => widget.onSend;
  VoidCallback get onAttach => widget.onAttach;
  VoidCallback get onModelSheet => widget.onModelSheet;
  VoidCallback get onUsage => widget.onUsage;

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

  List<String> get _thoughtChoices {
    final fromPrep =
        prep?.option('thought_level')?.options.map((o) => o.value).toList() ??
        const <String>[];
    return fromPrep.isNotEmpty ? fromPrep : (state?.thoughtLevels ?? const []);
  }

  @override
  Widget build(BuildContext context) {
    final running = state?.isRunning ?? false;
    // Official web swaps the hint once messages are queued, so typing more
    // keeps appending to the queue instead of looking like a fresh message.
    final queued = state?.queueItems.isNotEmpty ?? false;
    // Official composer: icon-only buttons below sm (640), icon+label above.
    final wide = MediaQuery.sizeOf(context).width >= 640;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Container(
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
          decoration: BoxDecoration(
            color: ZColors.darkCard,
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
                ),
                textInputAction: TextInputAction.newline,
              ),
              Row(
                children: [
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
                  const Spacer(),
                  if (_usageRatio != null)
                    _UsageRing(ratio: _usageRatio!, onTap: onUsage),
                  if (_modelLabel.isNotEmpty)
                    _ControlChip(
                      label: _modelLabel,
                      icon: Icons.memory_outlined,
                      onTap: onModelSheet,
                      showLabel: wide,
                    ),
                  if (_thoughtLabel.isNotEmpty)
                    _ControlChip(
                      label: _thoughtLabel,
                      icon: Icons.psychology_alt_outlined,
                      onTap: () => _pickThought(context),
                      showLabel: wide,
                    ),
                  const SizedBox(width: 4),
                  // Official web keeps the composer sendable while a turn
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
          Column(
            children: [
              for (final m in const ['build', 'edit', 'plan', 'yolo'])
                RadioListTile<String>(
                  dense: true,
                  groupValue: _modeValue,
                  value: m,
                  onChanged: (v) =>
                      Navigator.pop(context, v ?? _modeValue),
                  title: Text(tr(context, 'chat.mode.$m')),
                  subtitle: Text(tr(context, 'chat.mode.$m.desc')),
                ),
            ],
          ),
        ],
      ),
    );
    if (value == null || value == _modeValue) return;
    if (isDraft || sid == null) return; // draft chips go through the sheet
    gateway.switchCollaborationMode(sid, value);
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
          Column(
            children: [
              for (final t in choices)
                RadioListTile<String>(
                  dense: true,
                  groupValue: _thoughtLabel,
                  value: t,
                  onChanged: (v) =>
                      Navigator.pop(context, v ?? _thoughtLabel),
                  title: Text(t),
                ),
            ],
          ),
        ],
      ),
    );
    if (value == null || value == _thoughtLabel) return;
    if (isDraft || sid == null) return; // draft chips go through the sheet
    final modelValue =
        '${state?.config?['provider'] ?? ''}/${state?.config?['model'] ?? ''}';
    final idx = modelValue.lastIndexOf('/');
    gateway.switchModelConfig(
      sid,
      provider: idx > 0 ? modelValue.substring(0, idx) : modelValue,
      model: idx > 0 ? modelValue.substring(idx + 1) : modelValue,
      thought: value,
    );
  }

  void _stop(BuildContext context) {
    final sid = sessionId;
    if (sid == null) return;
    gateway.stop(sid);
  }
}

class _ControlChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  /// Official mobile parity: below the sm breakpoint the composer controls
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

/// Circular context-usage indicator (official 环形用量).
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
    // Official web: ~30px squircle (ZRadius.mini) with the arrow glyph.
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
                child: Icon(Icons.stop, color: ZColors.danger, size: 20),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
