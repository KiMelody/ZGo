import 'dart:async';

import 'package:flutter/material.dart';

import '../state/device_session.dart';
import 'chat/chat_page.dart';
import 'theme.dart';
import 'ui_settings.dart';

/// Lightweight transition page between a notification tap and the chat page
/// (design 11-07 §数据流): waits for the device link to become usable,
/// resolves the task's workspace and warms it, then replaces itself with the
/// conversation.
///
/// Why a page instead of pushing [ChatPage] straight away: the tap happens
/// outside any page state, the link may still be reconnecting, and the task
/// may live in a workspace the bridge is not attached to. Pushing the chat
/// anyway meant `ChatPage._subscribe` fired against a not-ready bridge and
/// the user got a red 「订阅失败」 banner instead of their task. This page
/// turns that window into visible, retryable progress and never lands the
/// user on a chat that would fail to subscribe.
///
/// The state layer owns every decision ([TaskOpenHost.prepareTaskOpen]
/// resolves ownership and opens on demand); this page only sequences the
/// steps and maps the typed outcomes onto copy.
class TaskOpenPage extends StatefulWidget {
  const TaskOpenPage({
    super.key,
    required this.openHost,
    required this.chatHost,
    required this.sessionId,
    required this.title,
    this.theme,
    this.workspaceScope,
    this.offPeakHost,
    this.onOpenOffPeak,
    this.connectTimeout = const Duration(seconds: 60),
    this.resolveTimeout = const Duration(seconds: 15),
    this.slowHintAfter = const Duration(seconds: 5),
  });

  /// Connection readiness + the shared 「open this task」 entry.
  final TaskOpenHost openHost;

  /// The page boundary the landed chat page is built with (same session as
  /// [openHost]; this page holds the role interface, never the concrete
  /// session class).
  final ChatPageHost chatHost;

  /// The task to open (notification payload's `sessionId`).
  final String sessionId;

  /// App-bar title — the task title, or the device label when the payload
  /// carried none.
  final String title;

  final ThemeController? theme;

  /// The notification payload's ownership fields (`workspacePath` /
  /// `workspaceIdentity`, design 11-07 R1). Used only when the task
  /// directory cannot resolve the task's workspace — a cold-start tap
  /// arrives before the relay overview does.
  final Map<String, dynamic>? workspaceScope;

  /// Passed through to the landed chat page (queue-position card).
  final OffPeakHost? offPeakHost;
  final VoidCallback? onOpenOffPeak;

  /// Upper bound on the connection wait: a link that never turns
  /// `connected` fails into the retry state instead of spinning forever.
  final Duration connectTimeout;

  /// Upper bound on the transient-ownership wait (a null answer while the
  /// relay overview has not landed — see [TaskOpenHost.taskOverviewLoaded]).
  final Duration resolveTimeout;

  /// When the 「可能需要一点时间」 hint appears (the same window the chat
  /// page's loading placeholder uses).
  final Duration slowHintAfter;

  @override
  State<TaskOpenPage> createState() => _TaskOpenPageState();
}

class _TaskOpenPageState extends State<TaskOpenPage> {
  /// Waiting for the link.
  bool _preparing = false;

  /// Classified failure copy (a lexicon KEY, translated at render time so a
  /// later locale switch is not frozen in). Non-null = failure state.
  String? _failureKey;

  /// Set by [dispose]: every `await` continuation re-checks it, so a user
  /// who left the page never gets a page pushed on top of whatever they
  /// opened instead (AC5 — warm-up can finish long after the pop).
  bool _abandoned = false;

  Timer? _slowTimer;
  bool _slow = false;

  /// The live connection-wait timer (cancelled on dispose so a page that
  /// went away never leaves a pending timer behind).
  Timer? _connectTimer;

  /// The overview-wait timer of the transient-ownership re-resolve (same
  /// dispose discipline as [_connectTimer]).
  Timer? _resolveTimer;

  /// Ends an in-flight connection wait (dispose path): completes the future
  /// so its continuation unwinds instead of hanging on a dead page.
  VoidCallback? _abortWait;

  /// Guards against overlapping runs (retry during an in-flight wait).
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _restartSlowTimer();
    _run();
  }

  @override
  void dispose() {
    _abandoned = true;
    _slowTimer?.cancel();
    _connectTimer?.cancel();
    _resolveTimer?.cancel();
    _abortWait?.call();
    super.dispose();
  }

  /// Serial chain: wait for the link → resolve/warm the workspace → land.
  /// Every continuation re-checks [_abandoned] / `mounted`; the landing is a
  /// `pushReplacement` so this page never sits in the stack.
  ///
  /// A superseded ([WorkspaceOpenAborted]) open is re-run ONCE in place (the
  /// reconnect-window race); a second abort is a dead end. The loop keeps
  /// [_running] owned by one invocation — a nested `_run()` would clear the
  /// flag through its caller's `finally`.
  Future<void> _run() async {
    if (_running || _abandoned) return;
    _running = true;
    try {
      for (var attempt = 0;; attempt++) {
        _setWaiting();
        final connected = await _waitForConnection();
        if (_abandoned || !mounted) return;
        // A failed / kicked / timed-out wait already staged its copy.
        if (!connected) return;
        if (mounted) setState(() => _preparing = true);
        var result = await widget.openHost
            .prepareTaskOpen(widget.sessionId, workspaceHint: widget.workspaceScope);
        if (_abandoned || !mounted) return;
        // Null + overview not landed yet is TRANSIENT emptiness (cold start:
        // the directory has nothing until bootstrap ⊕ listTaskList land, and
        // the payload hint is absent for live-row notices). Waiting for the
        // overview and re-resolving turns the manual-retry success the
        // 2026-11-07 acceptance observed (AC4) into an automatic one.
        if (result == null && !widget.openHost.taskOverviewLoaded) {
          final landed = await _waitForOverview();
          if (_abandoned || !mounted) return;
          if (landed) {
            continue; // the directory can answer now — re-resolve.
          }
          _fail('tasks.scopeUnknown', 'overview did not land');
          return;
        }
        switch (result) {
          case WorkspaceOpenOpened():
            await _land();
            return;
          case WorkspaceOpenAborted():
            if (attempt >= 1) {
              _fail('tasks.open.failed', result);
              return;
            }
          case WorkspaceOpenRuntimeNotRunning():
            _fail('tasks.agentRuntimeNotRunning', result);
            return;
          case WorkspaceOpenProviderNotReady():
            _fail('tasks.providerNotReady', result);
            return;
          case WorkspaceOpenUnreachable() || WorkspaceOpenTransportFailure():
            _fail('tasks.workspaceUnreachable', result);
            return;
          case null:
            _fail('tasks.scopeUnknown', result);
            return;
        }
      }
    } finally {
      _running = false;
    }
  }

  void _setWaiting() {
    if (!mounted) return;
    setState(() {
      _preparing = false;
      _failureKey = null;
      _slow = false;
    });
    _restartSlowTimer();
  }

  void _restartSlowTimer() {
    _slowTimer?.cancel();
    _slowTimer = Timer(widget.slowHintAfter, () {
      if (mounted) setState(() => _slow = true);
    });
  }

  /// Waits for a usable link. `connected` proceeds at once, `kicked` is a
  /// terminal dead end (session-lifecycle §4 — a kick never self-heals), a
  /// timeout fails, and everything else (including `error`, which redials on
  /// its own backoff) keeps waiting.
  Future<bool> _waitForConnection() {
    final host = widget.openHost;
    if (host.status == DeviceStatus.connected && !host.kicked) {
      return Future.value(true);
    }
    final completer = Completer<bool>();
    late final void Function() listener;
    Timer? timer;
    void finish(bool ok) {
      if (completer.isCompleted) return;
      host.removeListener(listener);
      timer?.cancel();
      if (identical(_connectTimer, timer)) _connectTimer = null;
      if (identical(_abortWait, finish)) _abortWait = null;
      completer.complete(ok);
    }

    listener = () {
      if (host.status == DeviceStatus.connected && !host.kicked) {
        finish(true);
        return;
      }
      if (!host.kicked) return;
      _fail('remote.failure.kicked', 'kicked');
      finish(false);
    };

    // dispose() ends the wait through this (a page that went away must not
    // leave the future pending, nor the link listener attached).
    _abortWait = () => finish(false);
    host.addListener(listener);
    timer = Timer(widget.connectTimeout, () {
      _fail('chat.error.timeout', 'connection timeout');
      finish(false);
    });
    _connectTimer = timer;
    // A kick / connect that landed between the fast-path check and the
    // listener attach must not wait out the whole timeout.
    listener();
    return completer.future;
  }

  /// Waits for the relay overview to land (same shape as the connection
  /// wait: fast path, listener, dispose-abort, timeout — the timeout only
  /// fails the wait, the copy comes from the caller which knows it is the
  /// ownership answer that stayed null).
  Future<bool> _waitForOverview() {
    final host = widget.openHost;
    if (host.taskOverviewLoaded) return Future.value(true);
    final completer = Completer<bool>();
    late final void Function() listener;
    void finish(bool ok) {
      if (completer.isCompleted) return;
      host.removeListener(listener);
      _resolveTimer?.cancel();
      if (identical(_abortWait, finish)) _abortWait = null;
      completer.complete(ok);
    }

    listener = () {
      if (host.taskOverviewLoaded) finish(true);
    };
    _abortWait = () => finish(false);
    host.addListener(listener);
    _resolveTimer = Timer(widget.resolveTimeout, () => finish(false));
    // A landing between the fast-path check and the attach must not wait.
    listener();
    return completer.future;
  }

  void _fail(String key, Object? detail) {
    if (!mounted || _abandoned) return;
    debugPrint('[task-open] ${widget.sessionId} failed: $key ($detail)');
    setState(() => _failureKey = key);
  }

  /// Replaces this page with the conversation. The landed page mirrors the
  /// task list's own chat push, so a notification-opened chat is
  /// indistinguishable from one opened from the list. No push happens after
  /// a dispose (AC5).
  Future<void> _land() async {
    if (_abandoned || !mounted) return;
    final host = widget.chatHost;
    await Navigator.of(context).pushReplacement(
      zRoute(
        (_) => ChatPage(
          host: host,
          sessionId: widget.sessionId,
          title: widget.title,
          theme: widget.theme,
          workspaceLabel: _workspaceLabel(host),
          offPeakHost: widget.offPeakHost,
          onOpenOffPeak: widget.onOpenOffPeak,
        ),
      ),
    );
  }

  /// Workspace chip for the landed page: the active workspace's display
  /// name (path leaf) through the context port.
  static String? _workspaceLabel(ChatPageHost port) {
    final path = port.workspacePath;
    if (path == null || path.isEmpty) return null;
    final parts = path.split(RegExp(r'[\\/]'));
    return parts.lastWhere((p) => p.isNotEmpty, orElse: () => path);
  }

  /// A failed run's retry: a link that is neither connected nor mid-connect
  /// takes the documented manual recovery entry
  /// ([SessionLinkPort.reconnect] — the only way out of `kicked` too); a
  /// connecting link keeps its own backoff and is merely waited on again.
  void _retry() {
    final host = widget.openHost;
    if (host.kicked ||
        (host.status != DeviceStatus.connected &&
            host.status != DeviceStatus.connecting)) {
      unawaited(host.reconnect());
    }
    unawaited(_run());
  }

  @override
  Widget build(BuildContext context) {
    final failure = _failureKey;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: ZType.heading,
        ),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(
            horizontal: ZSpacing.screen,
            vertical: ZSpacing.emptyState,
          ),
          child: failure != null
              ? _FailedBody(
                  copy: tr(context, failure),
                  onRetry: _retry,
                  onBack: () => Navigator.of(context).maybePop(),
                )
              : _ProgressBody(
                  copy: tr(
                    context,
                    _preparing ? 'tasks.open.preparing' : 'tasks.open.connecting',
                  ),
                  slow: _slow,
                ),
        ),
      ),
    );
  }
}

/// Waiting state: spinner, stage copy, and the slow hint.
class _ProgressBody extends StatelessWidget {
  const _ProgressBody({required this.copy, required this.slow});

  final String copy;
  final bool slow;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
        const SizedBox(height: 16),
        Text(
          copy,
          textAlign: TextAlign.center,
          style: ZType.body.copyWith(color: ZInk.soft(context)),
        ),
        if (slow) ...[
          const SizedBox(height: 6),
          Text(
            tr(context, 'chat.load.slowHint'),
            textAlign: TextAlign.center,
            style: ZType.sub.copyWith(color: ZInk.faint(context)),
          ),
        ],
      ],
    );
  }
}

/// Failure state: the classified copy plus the two pinned actions (retry /
/// back). The page stays put — a chat push here would subscribe under a
/// scope the desktop just refused.
class _FailedBody extends StatelessWidget {
  const _FailedBody({
    required this.copy,
    required this.onRetry,
    required this.onBack,
  });

  final String copy;
  final VoidCallback onRetry;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.error_outline,
          size: 28,
          color: ZInk.dangerTone(context),
        ),
        const SizedBox(height: 12),
        Text(
          copy,
          textAlign: TextAlign.center,
          style: ZType.body.copyWith(color: ZInk.soft(context)),
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          alignment: WrapAlignment.center,
          children: [
            TextButton(
              onPressed: onBack,
              child: Text(tr(context, 'common.close')),
            ),
            FilledButton(
              onPressed: onRetry,
              child: Text(tr(context, 'tasks.retry')),
            ),
          ],
        ),
      ],
    );
  }
}
