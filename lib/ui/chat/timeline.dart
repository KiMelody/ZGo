/// Shared conversation timeline renderer (task 10-10-subagent-render-align
/// D1): turn grouping + the row widget suite moved VERBATIM from
/// chat_page.dart — pure relocation, zero behavior change. The main chat
/// page (and, from D3 on, the subagent detail page) render through this
/// module; page-level logic (subscription, keyboard, composer, sheets)
/// stays in chat_page.dart.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../protocol/conversation.dart';
import '../../state/device_session.dart';
import '../phase_pill.dart';
import '../theme.dart';
import '../ui_settings.dart';
import '../widgets/sheet_scaffold.dart';
import 'chat_page.dart' show ChatPage, businessErrorCopy, commandErrorCopy;
import 'confirm_gate.dart';
import 'diff_view.dart';
import 'file_preview_page.dart';
import 'git_panel.dart';
import 'image_viewer_page.dart';
import 'markdown_view.dart';
import 'subagent_detail_page.dart';
import 'subagent_feed.dart';
import 'tool_row_semantics.dart';

/// Workspace-file preview plumbing for one chat page (design
/// 09-29-file-preview §4.4/§5): the markdown image resolver with a
/// session-scoped LRU (re-rendered rows must not re-fetch), the extension
/// dispatch into the preview surfaces, the markdown link split (http(s) →
/// system browser, scheme-less local path → dispatch) and the read
/// callbacks the HTML preview page assembles with. Paths resolve against
/// the chat's active workspace ([ChatGateway.workspacePath]); without one
/// the resolver returns null and the dispatch stays inert.
class ChatPreview {
  ChatPreview(this._gateway);

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

/// One ordered part of an assistant turn: either a merged text segment
/// (kind == 'text') or a non-text row (kind == 'row').
typedef AssistantPart = ({
  String kind,
  String? text,
  Map<String, dynamic>? row,
  List<Map<String, dynamic>>? group,
  bool streaming,
});

/// Display status of one hook execution (D4, F6): the projection row carries
/// `state` (running|completed|failed) plus an optional `outcome`
/// (success|blocked|failed|cancelled|timed_out); the official labels
/// (`chat.hooks.state.*`) merge the two — the outcome wins when present.
String hookRunStatus(Map exec) {
  final state = '${exec['state'] ?? ''}';
  return switch ('${exec['outcome'] ?? ''}') {
    'success' => 'completed',
    'blocked' => 'blocked',
    'cancelled' => 'cancelled',
    'timed_out' => 'timedOut',
    'failed' => 'failed',
    _ => state,
  };
}

/// Renders one hook execution line (F6 `KVt` projection): sourceKind label +
/// display name, status dot + label, optional block reason (warning) and
/// duration. Field names are defensively read — the projection shape may
/// drift between desktop versions.
Widget _hookRunTile(BuildContext context, Map exec) {
  final source = switch ('${exec['sourceKind'] ?? ''}') {
    'user' => 'chat.hooks.source.user',
    'project' => 'chat.hooks.source.project',
    'plugin' => 'chat.hooks.source.plugin',
    _ => null,
  };
  final name =
      '${exec['displayName'] ?? exec['commandDisplay'] ?? exec['toolName'] ?? ''}'
          .trim();
  final status = hookRunStatus(exec);
  final statusKey = 'chat.hooks.state.$status';
  final blockReason = '${exec['blockReason'] ?? ''}'.trim();
  final durationMs = (exec['durationMs'] as num?)?.toInt();
  return Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 6),
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: switch (status) {
              'completed' => ZColors.success,
              'blocked' || 'failed' || 'timedOut' => ZColors.danger,
              'cancelled' => ZColors.neutral500,
              _ => ZColors.warning, // running
            },
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name.isEmpty
                    ? tr(context, statusKey)
                    : (source == null
                          ? '$name · ${tr(context, statusKey)}'
                          : '${tr(context, source)} · $name · '
                              '${tr(context, statusKey)}'),
                style: ZType.sub.copyWith(color: ZInk.solid(context)),
              ),
              if (blockReason.isNotEmpty)
                Text(
                  blockReason,
                  style: ZType.caption.copyWith(
                    color: ZInk.warningTone(context),
                  ),
                ),
              if (durationMs != null)
                Text(
                  '$durationMs ms',
                  style: ZType.caption.copyWith(color: ZInk.faint(context)),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Read-only hook-run sheet (D4): the hookInvocation rows of one turn, each
/// listing its executions. Purely presentational — no commands, no trust
/// review (that is workspaceHookReview, a different thing).
class _HookRunsSheet extends StatelessWidget {
  final List<Map<String, dynamic>> hookRows;

  const _HookRunsSheet({required this.hookRows});

  @override
  Widget build(BuildContext context) {
    return zSheetScaffold(
      context,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.webhook, size: 18, color: ZInk.muted(context)),
              const SizedBox(width: 8),
              Text(
                tr(context, 'chat.hooks.label'),
                style: ZType.title.copyWith(color: ZInk.solid(context)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final row in hookRows) ...[
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '${row['hookEventName'] ?? ''}',
                style: ZType.caption.copyWith(color: ZInk.faint(context)),
              ),
            ),
            for (final exec in (row['executions'] as List? ?? const []))
              if (exec is Map) _hookRunTile(context, exec),
          ],
        ],
      ),
    );
  }
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
String localeOf(BuildContext context) =>
    UiSettingsProvider.of(context)?.locale ?? 'zh-CN';

/// Fork flow shared by the message-action sheet and the feedback row (task
/// C1, official parity): send `forkAssistant`, then — like the web's onFork
/// — push the ack's new sessionId as a fresh ChatPage (the landing IS the
/// feedback; no extra toast), or snack the fallback copy when the server
/// acked created without a usable id (the row surfaces via sessions-index).
/// Failures keep _run's snack shapes: a non-pass status reads
/// 「分叉失败: `reasonCode|status`」, a thrown error goes through
/// commandErrorCopy/businessErrorCopy (busy and resolve-failure map to
/// plain-language copy).
///
/// [context] must be a page-lifetime context (a row's element), not the
/// action sheet's — the sheet pops before the command round-trip. Navigator
/// and ScaffoldMessenger are captured up front, so post-await use is safe.
/// [theme] rides along so the forked page keeps the theme toggle (the
/// source page's controller — the pushed page renders under the same
/// controller-driven ThemeMode).
Future<void> _forkToNewSession(
  BuildContext context, {
  required ChatGateway gateway,
  required String sessionId,
  required Map<String, dynamic> target,
  String? workspaceLabel,
  ThemeController? theme,
}) async {
  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final locale = localeOf(context);
  final errorPrefix = tr(context, 'chat.action.fork.failed');
  final createdCopy = tr(context, 'chat.fork.created');
  final draftTitle = tr(context, 'tasks.new');
  dynamic ack;
  try {
    ack = await gateway.conversationCommands.forkAssistant(sessionId, target);
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
          gateway: gateway,
          sessionId: newId,
          title: draftTitle,
          workspaceLabel: workspaceLabel,
          theme: theme,
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

/// Side-chat flow behind the message-action sheet's 「在辅助对话中提问」 entry
/// (task parity-reference D2, official ask-in-side-chat parity): ask the user
/// what to send, then `createSelectionSideSession(firstInput:{text})` and push
/// the new sessionId as a fresh ChatPage (the fork-jump precedent, :_forkTo
/// NewSession — the landing is the feedback, no extra toast). Cancelled or
/// blank input creates NOTHING: ZGo never sends a first message the user did
/// not type (its menu entry stands in for the official desktop selection
/// tooltip, which stashes the selection and waits for the user's question).
///
/// [context] must be a page-lifetime context (a row's element), not the action
/// sheet's — the sheet pops before the ask dialog and the command round-trip.
/// Navigator and ScaffoldMessenger are captured up front; every user-facing
/// string is read before the async gaps, so post-await use is safe. Failures
/// keep _run's snack shapes (commandErrorCopy first — the protocol's side-chat
/// guard copy rides it — then businessErrorCopy, then the raw prefixed text).
Future<void> _startSelectionSideChat(
  BuildContext context, {
  required ChatGateway gateway,
  required String sessionId,
  String? workspaceLabel,
  ThemeController? theme,
}) async {
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
  if (text.isEmpty) return; // empty/cancel: create nothing, send no first message
  String newId;
  try {
    newId = await gateway.conversationCommands.createSelectionSideSession(
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
        gateway: gateway,
        sessionId: newId,
        title: pageTitle,
        workspaceLabel: workspaceLabel,
        theme: theme,
      ),
    ),
  );
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

/// turnHeader states whose footer (terminal pill + feedback row) is gated
/// behind the confirm window (see _ChatTurnGroupState).
const turnTerminalPhases = {
  'completedSuccess',
  'completedInterrupted',
  'failed',
  'error',
};

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
List<List<Map<String, dynamic>>> groupChatRows(List<Map<String, dynamic>> rows) {
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

/// Child-session (subagent) row view (acceptance fix): drops the
/// spawn-time `modelChange` timeline marker the desktop logs when the
/// subagent's configured model differs from the parent's. The child views
/// surface the model themselves (the detail page's AppBar subtitle /
/// [chatModelLabel]'s marker fallback), so the marker at the top of the
/// transcript reads as the model display instead of the transcript.
List<Map<String, dynamic>> childSessionRows(
  Iterable<Map<String, dynamic>> rows,
) {
  return rows.where((row) {
    if (row['kind'] != 'timelineMarker') return true;
    final marker = row['marker'];
    return marker is! Map || marker['type'] != 'modelChange';
  }).toList();
}

/// The row's display timestamp: the first positive numeric among the
/// usual alias keys (`createdAt`/`sentAt`/`at`). Moved verbatim from
/// `_ChatPageState` — the assistant feedback row and the page's time
/// divider share it.
int? rowTimestamp(Map<String, dynamic>? row) {
  if (row == null) return null;
  for (final key in const ['createdAt', 'sentAt', 'at']) {
    final v = row[key];
    if (v is num && v > 0) return v.toInt();
  }
  return null;
}

/// Model label for the subagent detail page's AppBar subtitle (design D4):
/// the official web's provider display rule (`JMe` semantics) — a bare
/// model id for the default/official provider, `provider/model` for
/// third-party providers. Empty when the snapshot carries no model.
///
/// Official providers: empty, `glm`, and the coding-plan account ids
/// `account:(zai|bigmodel)-*` (the repo's [parsePlanAccess] family rule,
/// live-probed session config carries e.g. `account:zai-individual-coding-
/// plan`) — everything else is a custom provider and prefixes the id.
String chatModelLabel(ConversationState state) {
  var model = state.currentModel;
  if (model.isEmpty) {
    // Child-session snapshots may land without config; the transcript's
    // newest `modelChange` marker still carries the model in force — the
    // desktop logs it at spawn time even when the snapshot is bare.
    for (final row in state.rows.reversed) {
      if (row['kind'] != 'timelineMarker') continue;
      final marker = row['marker'];
      if (marker is Map && '${marker['type'] ?? ''}' == 'modelChange') {
        model = '${marker['toModel'] ?? ''}';
        break;
      }
    }
  }
  if (model.isEmpty) return '';
  final provider = '${state.config?['provider'] ?? ''}'.trim();
  final official = provider.isEmpty ||
      provider == 'glm' ||
      RegExp(r'^account:(zai|bigmodel)-').hasMatch(provider);
  if (official) return model;
  if (model.startsWith('$provider/')) return model;
  return '$provider/$model';
}

class ChatTurnGroup extends StatefulWidget {
  final List<Map<String, dynamic>> rows;
  final ChatGateway gateway;
  final String sessionId;
  final Future<void> Function(String, Future<dynamic> Function()) onAction;
  final ConversationState state;
  final SubagentFeed feed;

  /// Workspace file-preview plumbing (markdown images, tappable file
  /// entries) — shared across all turn groups of the page.
  final ChatPreview preview;

  /// Terminal-footer confirm window (see [_ChatTurnGroupState]).
  final Duration confirmWindow;

  /// Inline edit-resend (D1): the page-level editing-row notifier + the
  /// send callback (target is derived from the user row; the command itself
  /// converges on the page).
  final ValueNotifier<String?>? editingRowId;
  final Future<void> Function(
    Map<String, dynamic> target,
    String newText,
    bool rewind,
  )? onEditSend;

  /// Source page's workspace chip label — carried so the fork flow can open
  /// the new session's page with the same chip (same workspace, fork parity).
  final String? workspaceLabel;

  /// Source page's theme controller — the fork flow hands it to the pushed
  /// page so the forked session keeps the theme toggle.
  final ThemeController? theme;

  /// Page-shared workspace Git controller — feeds the message change
  /// capsule (D3) and the review panel it opens. Optional so tests can omit
  /// it; the capsule then never renders.
  final GitWorkspaceController? gitController;

  /// Read-only boundary (design D2): true on the subagent detail page.
  /// Hides every send-shaped affordance the turn renders — the feedback
  /// row (copy/like/dislike/fork/hooks), the user bubble's edit-resend
  /// plumbing and the file-changes 撤销 button. Pure browsing (tool
  /// drill-in, previews, diff/collapse) stays.
  final bool readOnly;

  const ChatTurnGroup({
    super.key,
    required this.rows,
    required this.gateway,
    required this.sessionId,
    required this.onAction,
    required this.state,
    required this.feed,
    required this.preview,
    required this.confirmWindow,
    required this.workspaceLabel,
    this.editingRowId,
    this.onEditSend,
    this.theme,
    this.gitController,
    this.readOnly = false,
  });

  @override
  State<ChatTurnGroup> createState() => _ChatTurnGroupState();
}

/// One turn group: user bubble (if any) → turn header (已工作 N + pill,
/// rendered at the TOP of the turn) → ordered assistant parts →
/// file-changes card (always-visible rounded bar with 撤销).
class _ChatTurnGroupState extends State<ChatTurnGroup> {
  bool _showChanges = true;

  /// Terminal-footer gate (F) — the hold window itself; the footer's
  /// business flag stays in [_terminalConfirmed].
  late final ConfirmGate _terminalGate = ConfirmGate(
    window: widget.confirmWindow,
    onConfirmed: () {
      if (mounted && turnTerminalPhases.contains(_headerPhase ?? '')) {
        setState(() => _terminalConfirmed = true);
      }
    },
  );

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
  void didUpdateWidget(ChatTurnGroup oldWidget) {
    super.didUpdateWidget(oldWidget);
    _reconcileTerminal();
  }

  @override
  void dispose() {
    _terminalGate.dispose();
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
      _terminalGate.observe(false);
      if (_terminalConfirmed) setState(() => _terminalConfirmed = false);
      return;
    }
    // First-frame terminal (history / snapshot) was preset in initState —
    // arm nothing, same as the old `_terminalConfirmed ||` guard did.
    if (_terminalConfirmed) return;
    _terminalGate.observe(true);
  }

  @override
  Widget build(BuildContext context) {
    final rows = widget.rows;
    final gateway = widget.gateway;
    final sessionId = widget.sessionId;
    final onAction = widget.onAction;
    final workspaceLabel = widget.workspaceLabel;
    // single timeline marker
    if (rows.length == 1 && rows.first['kind'] == 'timelineMarker') {
      return _TimelineMarkerWidget(row: rows.first);
    }
    final first = rows.first;
    final isUserTurn = first['kind'] == 'userInput';

    // The header row moves out of the stream so it renders at the top;
    // for user turns the bubble itself is rendered separately below.
    // hookInvocation rows likewise never render inline (D4: the official UI
    // lifts them into the footer's hooks entry).
    Map<String, dynamic>? header;
    final bodyRows = <Map<String, dynamic>>[];
    for (var i = 0; i < rows.length; i++) {
      if (isUserTurn && i == 0) continue;
      final row = rows[i];
      if (row['kind'] == 'turnHeader') {
        header = row;
      } else if (row['kind'] != 'hookInvocation') {
        bodyRows.add(row);
      }
    }

    final children = <Widget>[];

    // Hook-invocation rows (D4, F6): delivered in the V4 rows stream, the
    // official UI lifts them out of the stream into the turn footer's hooks
    // entry — same lift site as the turnHeader above, so the parts split
    // ([assistantTurnParts]) stays untouched.
    final hookRows = [
      for (final row in rows)
        if (row['kind'] == 'hookInvocation') row,
    ];

    if (isUserTurn) {
      children.add(
        ChatRow(
          key: ValueKey('row-${first['rowId']}'),
          row: first,
          gateway: gateway,
          sessionId: sessionId,
          onAction: onAction,
          state: widget.state,
          preview: widget.preview,
          feed: widget.feed,
          editingRowId: widget.editingRowId,
          onEditSend: widget.onEditSend,
          workspaceLabel: workspaceLabel,
          theme: widget.theme,
          readOnly: widget.readOnly,
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
          ChatRow(
            key: p.row == null ? null : ValueKey('row-${p.row!['rowId']}'),
            row: {
              ...?p.row,
              'kind': 'assistantText',
              'text': p.text,
              if (p.streaming) 'state': 'streaming',
            },
            showFeedback: i == lastTextIdx,
            hookRows: i == lastTextIdx ? hookRows : const [],
            gateway: gateway,
            sessionId: sessionId,
            onAction: onAction,
            state: widget.state,
            preview: widget.preview,
            feed: widget.feed,
            turnFeedbackLocked: _feedbackLocked,
            workspaceLabel: workspaceLabel,
            theme: widget.theme,
            readOnly: widget.readOnly,
          ),
        );
      } else if (p.kind == 'rowGroup') {
        children.add(
          ToolGroupCard(
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
            workspaceLabel: workspaceLabel,
            theme: widget.theme,
            readOnly: widget.readOnly,
          ),
        );
      } else {
        children.add(
          ChatRow(
            key: ValueKey('row-${p.row!['rowId']}'),
            row: p.row!,
            showFeedback: false,
            gateway: gateway,
            sessionId: sessionId,
            onAction: onAction,
            state: widget.state,
            preview: widget.preview,
            feed: widget.feed,
            theme: widget.theme,
            readOnly: widget.readOnly,
          ),
        );
      }
    }

    // Message-level change capsule (D3), adjacent to and above the
    // file-changes card. Workspace-level git summary wins over the turn's
    // own fileChanges (design decision 3); neither → nothing renders.
    final gitController = widget.gitController;
    final headerRow = header;
    if (gitController != null && headerRow != null) {
      children.add(
        AnimatedBuilder(
          animation: gitController,
          builder: (context, _) {
            final stats = gitController.workspaceStats;
            return ChangeCapsule(
              gitWorktree: stats.fileCount > 0 ? stats : null,
              activeTask: statsFromFileChanges(headerRow['fileChanges']),
              onOpen: () => showGitReviewPanel(context, gitController),
            );
          },
        ),
      );
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
          readOnly: widget.readOnly,
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

class ChatRow extends StatelessWidget {
  final Map<String, dynamic> row;
  final ChatGateway gateway;
  final String sessionId;
  final Future<void> Function(String, Future<dynamic> Function()) onAction;
  final ConversationState state;
  final bool showFeedback;

  /// Shared child-session subscription pool (Agent tile expansion).
  final SubagentFeed? feed;

  /// Workspace file-preview plumbing (markdown images, tappable entries).
  final ChatPreview preview;

  /// Whether the turn's feedback row stays hidden (running turn or terminal
  /// confirm window — see [_ChatTurnGroupState._feedbackLocked]).
  final bool turnFeedbackLocked;

  /// Hook-invocation rows of the turn (D4) — rendered as the hooks entry on
  /// the last text segment's feedback row; empty elsewhere.
  final List<Map<String, dynamic>> hookRows;

  /// Inline edit-resend plumbing (D1) — user rows only; see
  /// [ChatTurnGroup].
  final ValueNotifier<String?>? editingRowId;
  final Future<void> Function(
    Map<String, dynamic> target,
    String newText,
    bool rewind,
  )? onEditSend;

  /// Source page's workspace chip label — the fork flow opens the new
  /// session's page with the same chip (fork parity with the web panel).
  final String? workspaceLabel;

  /// Source page's theme controller — rides the fork flow to the new page.
  final ThemeController? theme;

  /// Read-only boundary (design D2): masks [showFeedback] (the whole
  /// feedback row — copy/like/dislike/fork/hooks — stays unrendered) and
  /// nulls the user bubble's edit-resend plumbing.
  final bool readOnly;

  const ChatRow({
    super.key,
    required this.row,
    required this.gateway,
    required this.sessionId,
    required this.onAction,
    required this.state,
    required this.preview,
    this.showFeedback = true,
    this.hookRows = const [],
    this.feed,
    this.turnFeedbackLocked = false,
    this.editingRowId,
    this.onEditSend,
    this.workspaceLabel,
    this.theme,
    this.readOnly = false,
  });

  Map<String, dynamic> get _target => {
    'rowId': row['rowId'],
    if (row['entityId'] != null) 'entityId': row['entityId'],
  };

  void _showActions(BuildContext context) {
    final kind = row['kind'];
    if (kind != 'userInput' && kind != 'assistantText') return;
    HapticFeedback.mediumImpact();
    // The row's own element outlives the sheet — the fork flow navigates and
    // snacks after the command round-trip, when the sheet context is gone.
    final rowContext = context;
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
                  // Inline edit (D1): the card replaces the bubble in place;
                  // the old dialog is retired.
                  editingRowId?.value = '${row['rowId']}';
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
                _forkToNewSession(
                  rowContext,
                  gateway: gateway,
                  sessionId: sessionId,
                  target: _target,
                  workspaceLabel: workspaceLabel,
                  theme: theme,
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.forum_outlined, size: 20),
              title: Text(tr(context, 'chat.selections.askInSideChat')),
              onTap: () {
                Navigator.pop(context);
                _startSelectionSideChat(
                  rowContext,
                  gateway: gateway,
                  sessionId: sessionId,
                  workspaceLabel: workspaceLabel,
                  theme: theme,
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
            ? JsonSheet(
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
                commandErrorCopy('$e', localeOf(context)) ?? '$e',
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
        // Read-only boundary (D2): null plumbing keeps the legacy static
        // bubble (no edit affordance, no inline edit card).
        editingRowId: readOnly ? null : editingRowId,
        // The page callback carries the target; the bubble passes it on.
        onEditSend: readOnly || onEditSend == null
            ? null
            : (newText, rewind) => onEditSend!(_target, newText, rewind),
        rewindRunning: state.isRunning,
      ),
      'assistantText' => _AssistantBubble(
        row: row,
        gateway: gateway,
        sessionId: sessionId,
        state: state,
        preview: preview,
        // Read-only boundary (D2): the feedback row — copy included — is
        // not rendered at all, so masking showFeedback (not just the
        // buttons) is exactly the required shape.
        showFeedback: showFeedback && !readOnly,
        hookRows: hookRows,
        turnFeedbackLocked: turnFeedbackLocked,
        workspaceLabel: workspaceLabel,
        theme: theme,
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
      // turnHeader rows are lifted out of the stream by ChatTurnGroup
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
    // Read-only boundary (D2): the long-press sheet is all send-shaped
    // actions (edit-resend/fork/side-ask/rewind/file changes) — suppressed
    // wholesale on the subagent detail page.
    if (readOnly) return widget_;
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

  /// Inline edit-resend (D1): the page-level editing notifier + send
  /// callback. Null (non-chat callers) keeps the legacy static bubble.
  final ValueNotifier<String?>? editingRowId;
  final Future<void> Function(String newText, bool rewind)? onEditSend;

  /// Whether the conversation is running — the rewind toggle's disabled
  /// state (official 09: 「对话 + 文件重置」运行中置灰).
  final bool rewindRunning;

  const _UserBubble({
    required this.row,
    required this.gateway,
    required this.sessionId,
    this.editingRowId,
    this.onEditSend,
    this.rewindRunning = false,
  });

  @override
  State<_UserBubble> createState() => _UserBubbleState();
}

class _UserBubbleState extends State<_UserBubble> {
  bool _expanded = false;

  static const _collapsedLines = 14;

  @override
  Widget build(BuildContext context) {
    final editing = widget.editingRowId;
    if (editing != null && widget.onEditSend != null) {
      // ValueListenableBuilder keeps the flip surgical: only this bubble
      // swaps bubble↔card, the rest of the list never rebuilds (the
      // turn-group key stays stable so the TextField's element survives
      // streaming rebuilds — no focus loss).
      return ValueListenableBuilder<String?>(
        valueListenable: editing,
        builder: (context, editingRowId, _) {
          if (editingRowId == '${widget.row['rowId']}') {
            return _InlineEditCard(
              initialText: widget.row['text'] as String? ?? '',
              rewindDisabled: widget.rewindRunning,
              onCancel: () => editing.value = null,
              onSend: widget.onEditSend!,
            );
          }
          return _bubble(context);
        },
      );
    }
    return _bubble(context);
  }

  Widget _bubble(BuildContext context) {
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
              // Mock ruling 09-19 (10-05 closeout D4): the light bubble is
              // a white card on the #f8f8f8 page, separated by the official
              // --color-card-border (10% black) — the weaker 8% tile
              // hairline read as too little contrast. Dark keeps the bare
              // darkCard surface (zero dark delta).
              border: ZInk.isDark(context)
                  ? null
                  : Border.all(color: ZInk.cardBorder(context)),
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
            if (widget.editingRowId != null && widget.onEditSend != null)
              _MiniAction(
                icon: Icons.edit_outlined,
                tooltip: tr(context, 'chat.action.editResend'),
                onTap: () =>
                    widget.editingRowId!.value = '${widget.row['rowId']}',
              ),
          ],
        ),
      ],
    );
  }
}

/// Inline edit-resend card (D1, official 09 shoot): the user bubble becomes
/// an edit area with a `×取消` / `对话 + 文件重置`（rewind 开关，运行中禁用）/
/// `↑发送` tool row. Holds its own controller; the send action rides the
/// page callback ([_ChatPageState._sendUserEdit]) — the card never touches
/// gateway commands. Replaces the bubble INSIDE its turn group, so the
/// Scaffold Column structure is untouched (keyboard contract §8-1) and the
/// stable `turn-<rowId>` key keeps this State alive across rebuilds.
class _InlineEditCard extends StatefulWidget {
  final String initialText;

  /// True while the conversation runs — the rewind switch greys out
  /// (official) while the send stays available for a preserve edit.
  final bool rewindDisabled;
  final VoidCallback onCancel;
  final Future<void> Function(String newText, bool rewind) onSend;

  const _InlineEditCard({
    required this.initialText,
    required this.rewindDisabled,
    required this.onCancel,
    required this.onSend,
  });

  @override
  State<_InlineEditCard> createState() => _InlineEditCardState();
}

class _InlineEditCardState extends State<_InlineEditCard> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialText,
  );
  bool _rewind = false;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    // Live send-button enablement while typing.
    _controller.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.onSend(text, _rewind);
    } finally {
      // The page closes the editor on success (notifier → null); on failure
      // the edit state stays so the user can retry — just un-busy.
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 56, top: 8, bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: ZInk.card(context),
        borderRadius: BorderRadius.circular(ZRadius.tile),
        border: Border.all(color: ZColors.sky500.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('inline-edit-input'),
            controller: _controller,
            autofocus: true,
            minLines: 1,
            maxLines: 8,
            style: ZType.body,
            enabled: !_sending,
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextButton(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  minimumSize: Size.zero,
                ),
                onPressed: _sending ? null : widget.onCancel,
                child: Text(
                  tr(context, 'common.cancel'),
                  style: ZType.sub,
                ),
              ),
              // The chip + send wrap to a second line on narrow screens
              // (390px zh: three labels on one row overflow ~10px).
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilterChip(
                        label: Text(
                          tr(context, 'chat.action.rewindToggle'),
                          style: ZType.caption,
                        ),
                        selected: _rewind,
                        // Running turns refuse the rewind (official grey
                        // state).
                        onSelected: widget.rewindDisabled || _sending
                            ? null
                            : (v) => setState(() => _rewind = v),
                      ),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          minimumSize: Size.zero,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                        ),
                        onPressed:
                            _controller.text.trim().isEmpty || _sending
                            ? null
                            : _send,
                        icon: _sending
                            ? const SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.5,
                                ),
                              )
                            : const Icon(Icons.arrow_upward, size: 14),
                        label: Text(
                          tr(context, 'chat.action.editResend'),
                          style: ZType.sub,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
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

  /// Hook-invocation rows of this turn (D4) — non-empty renders the hooks
  /// entry beside the fork button (official `SVt(rows)` shape: rows →
  /// per-turn extraction, empty → no button).
  final List<Map<String, dynamic>> hookRows;

  /// Workspace file-preview plumbing (markdown images + link dispatch).
  final ChatPreview preview;

  /// Whether the turn's feedback row stays hidden; while the turn runs or
  /// the confirm window holds, the copy/like/dislike/fork row is replaced
  /// by the in-progress spinner (a blip back to running must not flash the
  /// feedback UI, see ChatTurnGroup).
  final bool turnFeedbackLocked;

  /// Source page's workspace chip label — carried for the fork flow's new
  /// page (same workspace, fork parity with the web panel).
  final String? workspaceLabel;

  /// Source page's theme controller — rides the fork flow to the new page.
  final ThemeController? theme;

  const _AssistantBubble({
    required this.row,
    required this.gateway,
    required this.sessionId,
    required this.state,
    required this.preview,
    this.showFeedback = true,
    this.hookRows = const [],
    this.turnFeedbackLocked = false,
    this.workspaceLabel,
    this.theme,
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

  /// Read-only hook run sheet (D4). Local navigator per the embedded/dual-
  /// pane contract (chat-conventions §6).
  void _showHookRuns(BuildContext context) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useRootNavigator: false,
      builder: (context) => _HookRunsSheet(hookRows: hookRows),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = row['text'] as String? ?? '';
    final streaming = row['state'] == 'streaming';
    final inProgress = streaming || turnFeedbackLocked;
    final feedback = row['feedback'] as String?;
    final timestamp = rowTimestamp(row);
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
                  _CopyFeedbackButton(text: text),
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
                    onTap: () => _forkToNewSession(
                      context,
                      gateway: gateway,
                      sessionId: sessionId,
                      target: {
                        'rowId': row['rowId'],
                        if (row['entityId'] != null)
                          'entityId': row['entityId'],
                      },
                      workspaceLabel: workspaceLabel,
                      theme: theme,
                    ),
                  ),
                  if (hookRows.isNotEmpty)
                    _FeedbackButton(
                      icon: Icons.webhook,
                      active: false,
                      onTap: () => _showHookRuns(context),
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

/// Assistant-copy button with the official web feedback: tap hard-switches
/// copy → check (no transition, no toast) and reverts after 1200ms
/// (measured on official 3.14.4 web, task 10-05
/// evidence/web-copy-morph-findings.md). Re-tapping during the morph just
/// restarts the window.
class _CopyFeedbackButton extends StatefulWidget {
  final String text;

  const _CopyFeedbackButton({required this.text});

  @override
  State<_CopyFeedbackButton> createState() => _CopyFeedbackButtonState();
}

class _CopyFeedbackButtonState extends State<_CopyFeedbackButton> {
  bool _copied = false;
  Timer? _revertTimer;

  @override
  void dispose() {
    _revertTimer?.cancel();
    super.dispose();
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.text));
    _revertTimer?.cancel();
    _revertTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _copied = false);
    });
    setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(
        _copied ? Icons.check : Icons.copy_outlined,
        size: 15,
        color: ZInk.ghost(context),
      ),
      onPressed: _copy,
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
  final ChatPreview preview;

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

    final summary = toolRowSemantics(row, locale: localeOf(context));

    final agentPrompt = isAgentTool(row) ? promptOf(inputText) : null;
    final childSessionId = widget.subagent?['childSessionId'] as String?;
    final canOpen = widget.gateway != null &&
        widget.feed != null &&
        (childSessionId ?? '').isNotEmpty;

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
              onTap: () => openSubagentDetail(
                context,
                widget.gateway!,
                feed: widget.feed!,
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
                      widget.gateway != null &&
                      (childSessionId ?? '').isNotEmpty)
                    _AgentChildTimeline(
                      feed: widget.feed!,
                      childSessionId: childSessionId!,
                      gateway: widget.gateway!,
                      preview: widget.preview,
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
    if (filePath == null || !ChatPreview.dispatchable(filePath)) {
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
    final tappable = openPath != null && ChatPreview.dispatchable(openPath);
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

  /// Shared-renderer plumbing (design D6): the inline rows render through
  /// the main-chat [ChatRow] — same boxes, same tokens — flat (no turn
  /// grouping; the nested expansion mirrors the child window like the
  /// official inline childToolCalls).
  final ChatGateway gateway;
  final ChatPreview preview;

  const _AgentChildTimeline({
    required this.feed,
    required this.childSessionId,
    required this.gateway,
    required this.preview,
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
        // Window view only (60 = snapshot tail window / rowsRange page):
        // the detail page's loadOlder prepends older rows into the
        // pooled state, but the inline timeline stays at the window —
        // official parity (the web's inline childToolCalls shows only
        // the parent-window mirror rows; live-certified 2026-10-08).
        // childSessionRows drops the spawn-time modelChange marker — the
        // model lives in the detail page's subtitle / label fallback, not
        // in the transcript.
        final window = childSessionRows(
          child.rows.length > 60
              ? child.rows.skip(child.rows.length - 60)
              : child.rows,
        );
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
            for (final row in window)
              ChatRow(
                row: row,
                gateway: widget.gateway,
                sessionId: widget.childSessionId,
                // Read-only inline rows: everything send-shaped is gated
                // off inside ChatRow; nothing here dispatches writes.
                onAction: (label, action) async {
                  await action();
                },
                state: child,
                preview: widget.preview,
                feed: widget.feed,
                readOnly: true,
              ),
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

  /// Whether the terminal phase pill may render (see ChatTurnGroup's
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

  /// Read-only boundary (design D2): hides the 撤销 button — a write
  /// command against the session; the bar itself (file count / ± counters)
  /// stays.
  final bool readOnly;

  const _FileChangesBar({
    required this.changes,
    required this.gateway,
    required this.sessionId,
    required this.row,
    required this.onAction,
    this.readOnly = false,
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
          if (!readOnly)
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
    final pooledFeed = feed;
    return InkWell(
      // Whole tile opens the read-only child-session detail page.
      onTap: pooledFeed == null
          ? null
          : () => openSubagentDetail(
                context,
                gateway,
                feed: pooledFeed,
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

/// Opens the read-only subagent child-session detail page (works bar row,
/// subagent stream tile, goal panel running tile). [feed] is the chat
/// page's shared child-subscription pool — the page joins it instead of
/// opening a private subscription. [confirmWindow] rides along where the
/// caller knows the chat page's terminal-footer window; callers that don't
/// (the drill-in points inside this module) omit it and the detail page
/// falls back to the chat default.
void openSubagentDetail(
  BuildContext context,
  ChatGateway gateway, {
  required SubagentFeed feed,
  required String? childSessionId,
  String? title,
  String? subagentType,
  String? workId,
  String? parentSessionId,
  bool running = false,
  Duration? confirmWindow,
}) {
  final sid = childSessionId ?? '';
  if (sid.isEmpty) return;
  Navigator.of(context).push(
    zRoute(
      (_) => SubagentDetailPage(
        gateway: gateway,
        feed: feed,
        childSessionId: sid,
        title: title,
        subagentType: subagentType,
        workId: workId,
        parentSessionId: parentSessionId,
        running: running,
        confirmWindow: confirmWindow,
      ),
    ),
  );
}

/// Collapsed run of consecutive execute-family tool rows:
/// 「终端 · N 个命令」 — tap expands the individual tool cards.
class ToolGroupCard extends StatefulWidget {
  final List<Map<String, dynamic>> rows;
  final ChatGateway gateway;
  final String sessionId;
  final Future<void> Function(String, Future<dynamic> Function()) onAction;
  final ConversationState state;
  final SubagentFeed? feed;

  /// Workspace file-preview plumbing (tappable file entries).
  final ChatPreview preview;

  /// Fork parity: the source page's workspace chip label for the fork flow.
  final String? workspaceLabel;

  /// Source page's theme controller — rides the fork flow to the new page.
  final ThemeController? theme;

  /// Read-only boundary (design D2) — forwarded to the expanded rows.
  final bool readOnly;

  const ToolGroupCard({
    super.key,
    required this.rows,
    required this.gateway,
    required this.sessionId,
    required this.onAction,
    required this.state,
    required this.preview,
    required this.workspaceLabel,
    this.theme,
    this.feed,
    this.readOnly = false,
  });

  @override
  State<ToolGroupCard> createState() => _ToolGroupCardState();
}

class _ToolGroupCardState extends State<ToolGroupCard> {
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
                    ChatRow(
                      row: r,
                      showFeedback: false,
                      gateway: widget.gateway,
                      sessionId: widget.sessionId,
                      onAction: widget.onAction,
                      state: widget.state,
                      preview: widget.preview,
                      feed: widget.feed,
                      workspaceLabel: widget.workspaceLabel,
                      theme: widget.theme,
                      readOnly: widget.readOnly,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class JsonSheet extends StatelessWidget {
  final String title;
  final Object? data;

  const JsonSheet({super.key, required this.title, required this.data});

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
/// [JsonSheet], which is never worse than the previous behavior.
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
  final ChatPreview preview;

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
