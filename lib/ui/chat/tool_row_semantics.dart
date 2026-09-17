import 'dart:convert';

import 'package:flutter/material.dart';

import '../ui_settings.dart';
import 'diff_view.dart';

/// Official-style per-tool row semantics for one `kind=='toolCall'` row:
/// first line (已写入 `<file>` / 终端 · cmd / 探索 · N 文件 …), optional
/// second line (write/edit: directory path), diff +/- counts and the
/// status icon — the chat tile, the works-bar tails and the subagent
/// timelines all render this, so it is encoded exactly once here (ADR-0006
/// parity discipline: the desktop copy is frozen verbatim; converging the
/// second subagent summary is not a redesign).
///
/// Pure module: takes a [locale], not a BuildContext, so plain Dart tests
/// pump rows straight through [toolRowSemantics] (no page widget needed).
class ToolRowSemantics {
  /// First line copy, already localized (see [toolRowSemantics]).
  final String title;

  /// Optional second line (write/edit: the file's directory).
  final String? subtitle;

  /// Diff +/- counts carried from the row's diff, 0 when there is none.
  final int additions;
  final int deletions;

  /// Status icon shared by every consumer (running / success / error /
  /// cancelled / fallback glyphs).
  final IconData icon;

  const ToolRowSemantics({
    required this.title,
    this.subtitle,
    required this.additions,
    required this.deletions,
    required this.icon,
  });
}

/// Execute-family tool rows (bash/terminal/exec/...) share one summary
/// card when consecutive — web executeGroup「终端 · N 个命令」parity.
bool isExecuteTool(Map<String, dynamic> row) {
  if (row['kind'] != 'toolCall') return false;
  final t = '${row['toolName'] ?? ''}'.toLowerCase();
  return t.contains('bash') ||
      t.contains('terminal') ||
      t.contains('exec') ||
      t.contains('command');
}

/// Agent tool calls dispatch a subagent: the input JSON carries
/// description / subagent_type / prompt while outputText stays empty — the
/// result lives in the child session (live-probed 2026-09-16).
bool isAgentTool(Map<String, dynamic> row) {
  if (row['kind'] != 'toolCall') return false;
  return '${row['toolName'] ?? ''}'.toLowerCase() == 'agent';
}

/// The agent input JSON's `prompt`, shown as the tile expansion body; null
/// when absent or unparsable.
String? promptOf(String inputText) {
  try {
    final input = jsonDecode(inputText);
    if (input is Map) {
      final prompt = input['prompt'] as String?;
      return (prompt == null || prompt.isEmpty) ? null : prompt;
    }
  } catch (_) {}
  return null;
}

/// Official tool summary: first line (已写入 `<file>` / 终端 · cmd /
/// 探索 · N 文件), optional second line (directory path), +/- counts.
ToolRowSemantics toolRowSemantics(
  Map<String, dynamic> row, {
  required String locale,
}) {
  final diff = extractDiff(row);
  final status = row['status'] as String? ?? '';
  final icon = switch (status) {
    'running' || 'inputStreaming' || 'pendingApproval' => Icons.hourglass_top,
    'success' => Icons.check,
    'error' => Icons.error_outline,
    'cancelled' => Icons.block,
    _ => Icons.build_outlined,
  };
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
    return ToolRowSemantics(
      icon: icon,
      title: trByKeyP(locale, 'chat.tool.wrote', [base]),
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
      'pending' => trByKey(locale, 'chat.tool.taskOutput.fetching'),
      'running' => trByKey(locale, 'chat.tool.taskOutput.running'),
      'failed' => trByKey(locale, 'chat.tool.taskOutput.failed'),
      'denied' => trByKey(locale, 'chat.tool.taskOutput.denied'),
      'stopped' => trByKey(locale, 'chat.tool.taskOutput.stopped'),
      _ => trByKey(locale, 'chat.tool.taskOutput.retrieved'),
    };
    return ToolRowSemantics(
      icon: icon,
      title: '${trByKey(locale, 'chat.tool.taskOutput.kind')} · $title',
      subtitle: null,
      additions: 0,
      deletions: 0,
    );
  }
  if (toolName.contains('taskstop')) {
    final st = '${row['status'] ?? ''}';
    final title = switch (st) {
      'pending' || 'running' =>
        trByKey(locale, 'chat.tool.taskStop.stopping'),
      'failed' => trByKey(locale, 'chat.tool.taskStop.failed'),
      'denied' => trByKey(locale, 'chat.tool.taskStop.denied'),
      'stopped' => trByKey(locale, 'chat.tool.taskStop.cancelled'),
      _ => trByKey(locale, 'chat.tool.taskStop.stopped'),
    };
    return ToolRowSemantics(
      icon: icon,
      title: '${trByKey(locale, 'chat.tool.taskStop.kind')} · $title',
      subtitle: null,
      additions: 0,
      deletions: 0,
    );
  }
  if (toolName.contains('sendmessage')) {
    final st = '${row['status'] ?? ''}';
    final title = switch (st) {
      'pending' || 'running' => trByKey(locale, 'chat.tool.send.sending'),
      'failed' => trByKey(locale, 'chat.tool.send.failed'),
      'denied' => trByKey(locale, 'chat.tool.send.denied'),
      'stopped' => trByKey(locale, 'chat.tool.send.stopped'),
      _ => trByKey(locale, 'chat.tool.send.sent'),
    };
    return ToolRowSemantics(
      icon: icon,
      title: '${trByKey(locale, 'chat.tool.send.kind')} · $title',
      subtitle: null,
      additions: 0,
      deletions: 0,
    );
  }
  if (toolName == 'agent') {
    // Web chat.toolCall.agent.backgroundLaunch* parity: 启动中 → 已启动 /
    // 启动失败. Description and subagent_type come from the input JSON;
    // outputText stays empty because the result lives in the child
    // session (live-probed 2026-09-16).
    String? description;
    String? type;
    try {
      final input = jsonDecode(inputText);
      if (input is Map) {
        description = input['description'] as String?;
        type = (input['subagent_type'] ?? input['subagentType']) as String?;
      }
    } catch (_) {}
    final stateWord = switch ('${row['status'] ?? ''}') {
      'pending' || 'running' => trByKey(locale, 'chat.tool.agent.launching'),
      'error' || 'failed' => trByKey(locale, 'chat.tool.agent.failed'),
      'denied' || 'stopped' || 'cancelled' =>
        trByKey(locale, 'chat.tool.agent.stopped'),
      _ => trByKey(locale, 'chat.tool.agent.launched'),
    };
    final subject = (description == null || description.isEmpty)
        ? (type ?? '')
        : description;
    return ToolRowSemantics(
      icon: icon,
      title: subject.isEmpty ? stateWord : '$stateWord · $subject',
      subtitle: subject == type ? null : type,
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
    return ToolRowSemantics(
      icon: icon,
      title: running
          ? trByKey(locale, 'chat.tool.askQuestion.asking')
          : noAnswer
              ? trByKey(locale, 'chat.tool.askQuestion.autoContinued')
              : count > 0
                  ? trByKeyP(locale, 'chat.tool.askQuestion.askedN', ['$count'])
                  : trByKey(locale, 'chat.tool.askQuestion.asked'),
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
    return ToolRowSemantics(
      icon: icon,
      title: cmd.isEmpty
          ? trByKey(locale, 'chat.tool.terminal')
          : '${trByKey(locale, 'chat.tool.terminal')} · $cmd',
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
      return ToolRowSemantics(
        icon: icon,
        title: trByKeyP(locale, 'chat.tool.exploreN', ['$count']),
        subtitle: toolNameRaw,
        additions: 0,
        deletions: 0,
      );
    }
    if (file != null) {
      return ToolRowSemantics(
        icon: icon,
        title: '${trByKey(locale, 'chat.tool.explore')} · $file',
        subtitle: toolNameRaw,
        additions: 0,
        deletions: 0,
      );
    }
    return ToolRowSemantics(
      icon: icon,
      title: trByKey(locale, 'chat.tool.explore'),
      subtitle: toolNameRaw,
      additions: 0,
      deletions: 0,
    );
  }
  return ToolRowSemantics(
    icon: icon,
    title: toolNameRaw,
    subtitle: null,
    additions: diff?.additions ?? 0,
    deletions: diff?.deletions ?? 0,
  );
}

String? _filePath(String inputText) {
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

int? _fileCount(String inputText) {
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
int? _fileCountFromText(String inputText) {
  final matches = RegExp(r'"(?:path|file)"\s*:').allMatches(inputText).length;
  return matches > 0 ? matches : null;
}

String _firstLine(String inputText) {
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
