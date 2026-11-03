// Read-only projections for the workflow tool rows. Four pieces live here:
//
// - [workflowRunName]: the four-source title fallback (design §2.1). A wire
//   run snapshot carries no name/label, so the title must be recovered from a
//   `get_workflow_run` display, the launch tool row's input, the turnHeader
//   `workflowLaunch` metadata, or the parent background-work title.
// - [workflowProgressParts] / [workflowSummary]: compact summary parts as
//   raw numbers + a kind enum. Localization stays in the widget layer, so
//   these are reusable from plain Dart tests.
// - [WorkflowViewData]: mirror (`WorkflowRun`, live) + tool snapshot
//   (`WorkflowRunDisplay`) merge with the priorities from design §2.2.
// - [WorkflowToolCard]: the four chat-card forms (create/resume run,
//   `get_workflow_run` snapshot, `list_workflow_runs` list) rendered in place
//   of the bare tool row. [isWorkflowToolRow] gates the dispatch; the page
//   injects navigation through [OpenWorkflowRun] (null on read-only surfaces,
//   which hides the detail chevron but keeps local expansion).
//
// The projections stay fully defensive: rows and display payloads are
// optional wire data that drift between desktop versions, so malformed
// members read as absent instead of throwing.

import 'dart:convert';

import 'package:flutter/material.dart';

import '../../protocol/conversation_state.dart';
import '../../protocol/workflow_run_display.dart';
import '../theme.dart';
import '../ui_settings.dart';

/// Drill-in to the read-only workflow run page (design 11-03 §6). The page
/// owns the route; the card holds only this callback. Read-only surfaces
/// (subagent detail, inline transcript) omit it — the chevron disappears
/// while local expansion keeps working.
typedef OpenWorkflowRun = void Function(
  BuildContext context, {
  required String runId,
  Map<String, dynamic>? display,
  String? title,
  int? workStartedAt,
  int? workEndedAt,
});

/// Trimmed non-empty string or null.
String? _stringOrNull(Object? value) {
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.isNotEmpty) return trimmed;
  }
  return null;
}

/// First trimmed non-empty value, preserving priority order.
String? _firstNonEmpty(Iterable<String?> values) {
  for (final value in values) {
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}

final _toolNameNoise = RegExp(r'[_\-\s]');

/// Snake_case (`create_workflow`) and PascalCase (`CreateWorkflow`) are the
/// same tool for our purposes (research §2.6: display kinds are snake_case,
/// real tool names PascalCase).
String _normalizedToolName(Object? value) =>
    '${value ?? ''}'.replaceAll(_toolNameNoise, '').toLowerCase();

bool _isLaunchTool(Map<String, dynamic> row) {
  final name = _normalizedToolName(row['toolName']);
  return name == 'createworkflow' || name == 'resumeworkflowrun';
}

/// `input.name` from the wire `input` map, or the `inputText` JSON when the
/// map is absent/partial. Bad or still-streaming JSON reads as null.
String? _launchInputName(Map<String, dynamic> row) {
  final input = row['input'];
  if (input is Map) {
    final name = _stringOrNull(input['name']);
    if (name != null) return name;
  }
  final text = row['inputText'];
  if (text is! String || text.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map) return _stringOrNull(decoded['name']);
  } catch (_) {
    // Malformed/partial JSON is expected while inputText streams.
  }
  return null;
}

/// Launch-tool display title fallback: the matching row's own display first,
/// then the caller-supplied display unless it is a snapshot of a DIFFERENT
/// run (that label belongs to another run and must not leak).
String? _launchDisplayName(
  Map<String, dynamic> row,
  Map<String, dynamic>? display,
  String runId,
) {
  final rowDisplay = row['display'];
  if (rowDisplay is Map) {
    final name =
        _stringOrNull(rowDisplay['title']) ??
        _stringOrNull(rowDisplay['label']);
    if (name != null) return name;
  }
  if (display == null) return null;
  if (display['kind'] == 'get_workflow_run' &&
      runId.isNotEmpty &&
      '${display['runId'] ?? ''}' != runId) {
    return null;
  }
  return _stringOrNull(display['title']) ?? _stringOrNull(display['label']);
}

const _workflowDisplayKinds = {
  'create_workflow',
  'resume_workflow_run',
  'get_workflow_run',
  'list_workflow_runs',
};

const _workflowToolNames = {
  'createworkflow',
  'resumeworkflowrun',
  'getworkflowrun',
  'listworkflowruns',
};

/// The row's workflow display payload when its `kind` is one of the four
/// workflow families; null for every other tool display.
Map<String, dynamic>? _workflowDisplayOf(Map<String, dynamic> row) {
  final display = row['display'];
  if (display is! Map) return null;
  final typed = display.cast<String, dynamic>();
  return _workflowDisplayKinds.contains(typed['kind']) ? typed : null;
}

/// True when a tool row belongs to the workflow family — either it carries a
/// workflow `display.kind` or its tool name normalizes to one of the four
/// workflow tools (design §3).
bool isWorkflowToolRow(Map<String, dynamic> row) {
  if (_workflowDisplayOf(row) != null) return true;
  return _workflowToolNames.contains(_normalizedToolName(row['toolName']));
}

/// The `display.runId` for the kinds that carry one (`get_workflow_run` /
/// `resume_workflow_run`); null otherwise.
String? _displayRunId(Map<String, dynamic> display) {
  final kind = display['kind'];
  if (kind == 'get_workflow_run') {
    return WorkflowRunDisplay.tryParse(display)?.runId;
  }
  if (kind == 'resume_workflow_run') {
    return WorkflowResumeDisplay.tryParse(display)?.runId;
  }
  final raw = display['runId'];
  return raw is String && raw.trim().isNotEmpty ? raw.trim() : null;
}

/// Resolve the live mirror run behind a workflow tool row: the run joined by
/// `toolCallId` first, then `display.runId` (resume/get snapshots).
WorkflowRun? workflowRunForRow(
  ConversationState state,
  Map<String, dynamic> row,
) {
  final toolCallId = '${row['toolCallId'] ?? ''}'.trim();
  if (toolCallId.isNotEmpty) {
    final run = state.workflowRuns.byToolCallId(toolCallId);
    if (run != null) return run;
  }
  final display = _workflowDisplayOf(row);
  final runId = display == null ? null : _displayRunId(display);
  if (runId == null || runId.isEmpty) return null;
  return state.workflowRuns.byRunId(runId);
}

/// Whether the row renders as a [WorkflowToolCard]. [isWorkflowToolRow] alone
/// is too broad for old desktops where a workflow tool name appears but
/// neither a display payload nor a mirror run exists — those keep the bare
/// tool row (design §7).
bool hasWorkflowCard(ConversationState state, Map<String, dynamic> row) {
  if (!isWorkflowToolRow(row)) return false;
  if (_workflowDisplayOf(row) != null) return true;
  return workflowRunForRow(state, row) != null;
}

String? _toolCallIdOf(Map<String, dynamic> row) {
  final id = '${row['toolCallId'] ?? ''}'.trim();
  return id.isEmpty ? null : id;
}

/// Resolve a run's display name from all known wire sources (design §2.1):
///
/// 1. a `get_workflow_run` display whose `runId` matches (its `label`);
/// 2. the launch tool row joined by [toolCallId] (`CreateWorkflow` /
///    `ResumeWorkflowRun`): `input.name`, then that row's display
///    `title`/`label`;
/// 3. a row carrying `workflowLaunch` (`turnHeader`) with a matching
///    `runId` (`name`);
/// 4. [workTitle] (the management sheet's `backgroundWorks.title`).
///
/// Returns null when every source is absent; callers fall back to their own
/// localized placeholder.
String? workflowRunName({
  required List<Map<String, dynamic>> rows,
  required String runId,
  String? toolCallId,
  Map<String, dynamic>? display,
  String? workTitle,
}) {
  // 1. get_workflow_run snapshot label, only for this run.
  if (display != null && runId.isNotEmpty) {
    if (display['kind'] == 'get_workflow_run' &&
        '${display['runId'] ?? ''}' == runId) {
      final label = _stringOrNull(display['label']);
      if (label != null) return label;
    }
  }

  // 2. Launch tool row joined by toolCallId.
  if (toolCallId != null && toolCallId.isNotEmpty) {
    for (final row in rows) {
      if ('${row['toolCallId'] ?? ''}' != toolCallId) continue;
      if (!_isLaunchTool(row)) continue;
      final name = _launchInputName(row);
      if (name != null) return name;
      final displayName = _launchDisplayName(row, display, runId);
      if (displayName != null) return displayName;
    }
  }

  // 3. turnHeader workflowLaunch metadata.
  if (runId.isNotEmpty) {
    for (final row in rows) {
      final launch = row['workflowLaunch'];
      if (launch is! Map) continue;
      if ('${launch['runId'] ?? ''}' != runId) continue;
      final name = _stringOrNull(launch['name']);
      if (name != null) return name;
    }
  }

  // 4. Parent background-work title.
  return _stringOrNull(workTitle);
}

/// One numeric element of a workflow card summary line. The widget layer maps
/// [kind] to localized copy; this layer only carries the quantity.
enum WorkflowSummaryKind {
  /// Mirror progress: [WorkflowSummaryPart.value] settled nodes out of
  /// [WorkflowSummaryPart.total].
  nodesProgress,

  /// Snapshot counters from `get_workflow_run.usage`.
  nodesObserved,
  nodesCompleted,
  nodesRunning,
  nodesFailed,

  /// Live subagent roster (`actors[].status == 'running'`).
  agentsRunning,

  /// Any subagent count (snapshot roster).
  agents,

  tokens,
  artifacts,
  questions,
}

/// One summary part; [total] is only meaningful for
/// [WorkflowSummaryKind.nodesProgress].
class WorkflowSummaryPart {
  final WorkflowSummaryKind kind;
  final int value;
  final int? total;

  const WorkflowSummaryPart(this.kind, this.value, {this.total});
}

/// Run-card summary (design §3, create/resume cards):
/// `settled/total 节点 · N 个智能体运行中 · N tokens · N 个产物 · N 个待答问题`.
/// Zero-valued categories are omitted; a null/empty run yields no parts.
List<WorkflowSummaryPart> workflowProgressParts(WorkflowRun? run) {
  if (run == null) return const [];
  final parts = <WorkflowSummaryPart>[];
  if (run.nodesTotal > 0) {
    parts.add(
      WorkflowSummaryPart(
        WorkflowSummaryKind.nodesProgress,
        run.nodesSettled,
        total: run.nodesTotal,
      ),
    );
  }
  if (run.agentsRunning > 0) {
    parts.add(
      WorkflowSummaryPart(WorkflowSummaryKind.agentsRunning, run.agentsRunning),
    );
  } else if (run.actorsCount > 0) {
    // A terminal (or all-waiting) run has no running actor, but the roster
    // size is still the subagent count PRD R1 asks for.
    parts.add(WorkflowSummaryPart(WorkflowSummaryKind.agents, run.actorsCount));
  }
  if (run.spentTokens > 0) {
    parts.add(WorkflowSummaryPart(WorkflowSummaryKind.tokens, run.spentTokens));
  }
  final artifacts = run.artifacts.length;
  if (artifacts > 0) {
    parts.add(WorkflowSummaryPart(WorkflowSummaryKind.artifacts, artifacts));
  }
  final questions = run.pendingQuestions.length;
  if (questions > 0) {
    parts.add(WorkflowSummaryPart(WorkflowSummaryKind.questions, questions));
  }
  return parts;
}

/// Snapshot-card summary (design §3, `get_workflow_run`):
/// `observed 个节点 · done 已完成 · running 运行中 · failed 失败` plus the
/// subagent count. Zero-valued categories are omitted.
List<WorkflowSummaryPart> workflowSummary(WorkflowRunDisplay? display) {
  if (display == null) return const [];
  final parts = <WorkflowSummaryPart>[];
  final usage = display.usage;
  if (usage != null) {
    if (usage.nodesObserved > 0) {
      parts.add(
        WorkflowSummaryPart(
          WorkflowSummaryKind.nodesObserved,
          usage.nodesObserved,
        ),
      );
    }
    if (usage.nodesCompleted > 0) {
      parts.add(
        WorkflowSummaryPart(
          WorkflowSummaryKind.nodesCompleted,
          usage.nodesCompleted,
        ),
      );
    }
    if (usage.nodesRunning > 0) {
      parts.add(
        WorkflowSummaryPart(
          WorkflowSummaryKind.nodesRunning,
          usage.nodesRunning,
        ),
      );
    }
    if (usage.nodesFailed > 0) {
      parts.add(
        WorkflowSummaryPart(WorkflowSummaryKind.nodesFailed, usage.nodesFailed),
      );
    }
  }
  // The rich roster is authoritative; fall back to the identity list for
  // desktop versions that only send `actors`.
  final subagents = display.subagents;
  final agents = subagents.isNotEmpty
      ? subagents.length
      : display.actors.length;
  if (agents > 0) {
    parts.add(WorkflowSummaryPart(WorkflowSummaryKind.agents, agents));
  }
  return parts;
}

/// One merged phase row. `state` is the wire enum
/// (`done|current|ahead|unfinished`); [fromDisplay] says whether the state and
/// counters come from the official projection or from the local mirror
/// approximation (design §1.3).
class WorkflowPhaseView {
  final String name;
  final String state;
  final int rounds;
  final int nodesSettled;
  final int nodesRunning;
  final bool fromDisplay;

  const WorkflowPhaseView({
    required this.name,
    required this.state,
    required this.rounds,
    required this.nodesSettled,
    required this.nodesRunning,
    required this.fromDisplay,
  });
}

/// One merged subagent row: mirror identity/status first, snapshot rich
/// fields (`stepsSettled` / `tokens` / `lastTool` / `waitCause` …) when the
/// display carries them. The snapshot alone is used when the mirror lacks the
/// actor entirely.
class WorkflowActorView {
  final String siteId;
  final int ordinal;

  /// Live mirror member (`WorkflowRun.actors`), if any.
  final WorkflowActor? mirror;

  /// Rich snapshot member (`display.subagents`), if any.
  final WorkflowDisplaySubagent? snapshot;

  /// Identity-only snapshot member (`display.actors`) — only used when
  /// neither mirror nor rich snapshot exists for this key.
  final WorkflowDisplayActor? identity;

  const WorkflowActorView({
    required this.siteId,
    required this.ordinal,
    this.mirror,
    this.snapshot,
    this.identity,
  });

  String get key => '$siteId\u0000$ordinal';
  bool get fromMirror => mirror != null;
  bool get hasSnapshot => snapshot != null;

  String? get name =>
      _firstNonEmpty([mirror?.name, snapshot?.name, identity?.name]);

  /// Mirror status wins (live); the display state only fills a missing
  /// mirror member (design §2.2).
  String get status {
    final live = mirror?.status ?? '';
    return live.isNotEmpty ? live : (snapshot?.state ?? '');
  }

  String? get phaseName =>
      _firstNonEmpty([mirror?.phaseName, snapshot?.phaseName]);

  String? get model => mirror?.model;

  // Snapshot-only rich fields (null/0 when the snapshot is absent).
  String get snapshotState => snapshot?.state ?? '';
  String? get instructionsHead => snapshot?.instructionsHead;
  int? get startedAt => snapshot?.startedAt;
  int? get turn => snapshot?.turn;
  int? get toolCalls => snapshot?.toolCalls;
  WorkflowDisplayLastTool? get lastTool => snapshot?.lastTool;
  String? get waitCause => snapshot?.waitCause;
  int? get retryAfterMs => snapshot?.retryAfterMs;
  int? get waitSince => snapshot?.waitSince;
  String? get parkedOn => snapshot?.parkedOn;
  int get stepsSettled => snapshot?.stepsSettled ?? 0;
  int get stepsFailed => snapshot?.stepsFailed ?? 0;
  int get tokens => snapshot?.tokens ?? 0;
  int? get lastProgressAt => snapshot?.lastProgressAt;
}

const _terminalRunStatuses = {'completed', 'errored', 'stopped'};

const _runningNodePhases = {
  'dispatched',
  'executing',
  'waiting',
  'repairing',
  'nudged',
};

/// Official `get_workflow_run.display.phases` when present, else the mirror
/// approximation (design §1.3). The display projection carries state/counts,
/// so it wins even while live status still comes from the mirror.
List<WorkflowPhaseView> _mergePhases(
  WorkflowRun? run,
  WorkflowRunDisplay? display,
) {
  if (display != null) {
    final fromDisplay = [
      for (final p in display.phases)
        if (p.name.isNotEmpty)
          WorkflowPhaseView(
            name: p.name,
            state: p.state,
            rounds: p.rounds,
            nodesSettled: p.nodesSettled,
            nodesRunning: p.nodesRunning,
            fromDisplay: true,
          ),
    ];
    if (fromDisplay.isNotEmpty) return fromDisplay;
  }
  if (run == null) return const [];
  return _mirrorPhases(run);
}

List<WorkflowPhaseView> _mirrorPhases(WorkflowRun run) {
  final names = run.phaseNames;
  if (names.isEmpty) return const [];

  final terminal = _terminalRunStatuses.contains(run.status);
  final currentIndex = run.currentPhase == null
      ? -1
      : names.indexOf(run.currentPhase!);
  final roundsByName = {
    for (final p in run.phases)
      if (p.name.isNotEmpty) p.name: p.rounds,
  };
  final unlisted = {
    for (final u in run.unlistedByPhase)
      if (u.phaseName != null) u.phaseName!: u,
  };
  final nodes = run.nodesView;

  final out = <WorkflowPhaseView>[];
  for (var i = 0; i < names.length; i++) {
    final name = names[i];
    var observed = 0;
    var settled = 0;
    var running = 0;
    for (final node in nodes) {
      if (node.phaseName != name) continue;
      observed++;
      if (node.phase == 'settled') settled++;
      if (_runningNodePhases.contains(node.phase)) running++;
    }
    settled += unlisted[name]?.settled ?? 0;

    final String state;
    if (terminal) {
      state = settled < observed ? 'unfinished' : 'done';
    } else if (currentIndex < 0) {
      // No current phase yet: everything is still ahead.
      state = 'ahead';
    } else if (i < currentIndex) {
      state = 'done';
    } else if (i == currentIndex) {
      state = 'current';
    } else {
      state = 'ahead';
    }

    out.add(
      WorkflowPhaseView(
        name: name,
        state: state,
        rounds: roundsByName[name] ?? 0,
        nodesSettled: settled,
        nodesRunning: running,
        fromDisplay: false,
      ),
    );
  }
  return out;
}

/// Mirror actors first (identity/status live), snapshot subagents merged by
/// `siteId\0ordinal` for rich fields, identity-only snapshot actors appended
/// only when no other source has the key.
List<WorkflowActorView> _mergeActors(
  WorkflowRun? run,
  WorkflowRunDisplay? display,
) {
  final merged = <String, WorkflowActorView>{};
  if (run != null) {
    for (final actor in run.actors) {
      merged[actor.key] = WorkflowActorView(
        siteId: actor.siteId,
        ordinal: actor.ordinal,
        mirror: actor,
      );
    }
  }
  if (display == null) return merged.values.toList(growable: false);

  for (final subagent in display.subagents) {
    final existing = merged[subagent.key];
    merged[subagent.key] = WorkflowActorView(
      siteId: subagent.siteId,
      ordinal: subagent.ordinal,
      mirror: existing?.mirror,
      snapshot: subagent,
      identity: existing?.identity,
    );
  }
  for (final actor in display.actors) {
    final existing = merged[actor.key];
    merged[actor.key] = WorkflowActorView(
      siteId: actor.siteId,
      ordinal: actor.ordinal,
      mirror: existing?.mirror,
      snapshot: existing?.snapshot,
      identity: actor,
    );
  }
  return merged.values.toList(growable: false);
}

/// Merged read view for the workflow card and detail page (design §2.2).
///
/// Priority summary:
/// - status / stopReason / resumable / progress: mirror (live);
/// - phases: display projection when present, else mirror approximation;
/// - nodes / pendingQuestions / artifacts / reports: mirror (display has
///   none of these);
/// - actor status: mirror, display only fills missing actors; actor rich
///   fields always come from the display snapshot;
/// - result: display result (≤4000) then mirror `resultPreview`;
/// - error: display error message then mirror `error`;
/// - logTail / health: display only;
/// - truncated: either source.
///
/// [isDisplayOnly] marks the snapshot-only page badge; [generatedAt] is the
/// snapshot's relative-age anchor.
class WorkflowViewData {
  final WorkflowRun? run;
  final WorkflowRunDisplay? display;

  final String runId;
  final String status;
  final String? stopReason;
  final bool resumable;
  final bool possiblyInterrupted;
  final bool truncated;
  final int? generatedAt;

  final List<WorkflowPhaseView> phases;
  final List<WorkflowActorView> actors;
  final List<WorkflowNode> nodes;
  final List<WorkflowQuestion> pendingQuestions;
  final List<WorkflowArtifact> artifacts;
  final List<WorkflowReport> reports;
  final List<WorkflowDisplayLog> logTail;
  final WorkflowDisplayHealth? health;
  final String? result;
  final String? error;

  WorkflowViewData({this.run, this.display})
    : runId = _firstNonEmpty([run?.runId, display?.runId]) ?? '',
      status = _firstNonEmpty([run?.status, display?.status]) ?? '',
      stopReason = _firstNonEmpty([run?.stopReason, display?.stopReason]),
      resumable = run?.resumable ?? false,
      possiblyInterrupted = display?.possiblyInterrupted ?? false,
      truncated = (run?.truncated ?? false) || (display?.truncated ?? false),
      generatedAt = display?.generatedAt,
      phases = _mergePhases(run, display),
      actors = _mergeActors(run, display),
      nodes = run?.nodesView ?? const <WorkflowNode>[],
      pendingQuestions = run?.pendingQuestions ?? const <WorkflowQuestion>[],
      artifacts = run?.artifacts ?? const <WorkflowArtifact>[],
      reports = run?.reports ?? const <WorkflowReport>[],
      logTail = display?.logTail ?? const <WorkflowDisplayLog>[],
      health = display?.health,
      result = _firstNonEmpty([display?.result, run?.resultPreview]),
      error = _firstNonEmpty([display?.error?.message, run?.errorText]);

  /// True when only the tool snapshot is available (the run was evicted
  /// from the session mirror or predates this session).
  bool get isDisplayOnly => run == null && display != null;

  /// True when a `get_workflow_run` snapshot backs this view.
  bool get hasSnapshot => display != null;

  /// True when live mirror progress exists (display-only views have none).
  bool get hasProgress => (run?.nodesTotal ?? 0) > 0;

  int get nodesSettled => run?.nodesSettled ?? 0;
  int get nodesTotal => run?.nodesTotal ?? 0;
}

/// The four chat-card forms for a workflow tool row (design §3). Holds only
/// the row, the conversation state (mirror + `workflowRunName` row join) and
/// the optional page navigation callback; expansion is local state.
class WorkflowToolCard extends StatefulWidget {
  final Map<String, dynamic> row;
  final ConversationState state;
  final OpenWorkflowRun? openWorkflowRun;

  const WorkflowToolCard({
    super.key,
    required this.row,
    required this.state,
    this.openWorkflowRun,
  });

  @override
  State<WorkflowToolCard> createState() => _WorkflowToolCardState();
}

class _WorkflowToolCardState extends State<WorkflowToolCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final display = _workflowDisplayOf(widget.row);
    switch (display?['kind']) {
      case 'create_workflow':
        return _createCard(context, display!);
      case 'resume_workflow_run':
        return _resumeCard(context, display!);
      case 'get_workflow_run':
        return _getCard(context, display!);
      case 'list_workflow_runs':
        return _listCard(context, display!);
    }
    // Display-less rows: the mirror joined by toolCallId is the only source.
    final run = workflowRunForRow(widget.state, widget.row);
    if (run != null) return _runCard(context, run: run, display: null);
    return _messageCard(
      context,
      title: tr(context, 'chat.workflowCard.unavailable'),
    );
  }

  // ---------------------------------------------------------------- shapes

  Widget _createCard(BuildContext context, Map<String, dynamic> display) {
    final create = WorkflowCreateDisplay.tryParse(display);
    final name = workflowRunName(
      rows: widget.state.rows,
      runId: '',
      toolCallId: _toolCallIdOf(widget.row),
      display: display,
    );
    // Compile failure: no run exists, so no detail entry. The diagnostics
    // are the only useful surface (design §3).
    if (create != null && !create.ok) {
      final diagnostics = [
        for (final d in create.diagnostics)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '${d.line}:${d.column} ${d.message}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: ZType.caption.copyWith(
                color: ZInk.dangerTone(context),
              ),
            ),
          ),
      ];
      return _messageCard(
        context,
        title: tr(context, 'chat.workflowCard.notStarted'),
        titleColor: ZInk.dangerTone(context),
        subtitle: name,
        summary: [
          trP(context, 'chat.workflowCard.errorCount', ['${create.errorCount}']),
        ],
        body: diagnostics,
      );
    }
    final run = workflowRunForRow(widget.state, widget.row);
    if (run == null) {
      return _messageCard(
        context,
        title: tr(context, 'chat.workflowCard.runMissing'),
        titleColor: ZInk.warningTone(context),
        subtitle: name,
      );
    }
    return _runCard(context, run: run, display: display);
  }

  Widget _resumeCard(BuildContext context, Map<String, dynamic> display) {
    final runId = _displayRunId(display) ?? '';
    final name = workflowRunName(
      rows: widget.state.rows,
      runId: runId,
      toolCallId: _toolCallIdOf(widget.row),
      display: display,
    );
    final run = workflowRunForRow(widget.state, widget.row);
    if (run == null) {
      return _messageCard(
        context,
        title: tr(context, 'chat.workflowCard.runMissing'),
        titleColor: ZInk.warningTone(context),
        subtitle: name,
      );
    }
    return _runCard(context, run: run, display: display);
  }

  /// create / resume / display-less mirror card: live status, name, compact
  /// progress summary, detail chevron and a capped phase list.
  Widget _runCard(
    BuildContext context, {
    required WorkflowRun run,
    required Map<String, dynamic>? display,
  }) {
    final snapshot = display == null
        ? null
        : WorkflowRunDisplay.tryParse(display);
    final data = WorkflowViewData(run: run, display: snapshot);
    final name =
        workflowRunName(
          rows: widget.state.rows,
          runId: run.runId,
          toolCallId: _toolCallIdOf(widget.row),
          display: display,
        ) ??
        tr(context, 'chat.workflowDetail.titleFallback');
    final summary = [
      for (final part in workflowProgressParts(run))
        _summaryLabel(context, part),
    ];
    final phases = _phaseLines(context, data.phases, cap: 5);
    final open = widget.openWorkflowRun;
    return _card(context, [
      _header(
        context,
        title: _runTitle(context, run.status),
        titleColor: _statusColor(context, run.status),
        subtitle: name,
        summary: summary,
        onOpen: open == null
            ? null
            : () => open(
                context,
                runId: run.runId,
                display: snapshot?.raw,
                title: name,
              ),
        expandable: phases.isNotEmpty,
      ),
      if (phases.isNotEmpty) _expandedBody(phases),
    ]);
  }

  /// `get_workflow_run` snapshot card: display-only when the run was evicted
  /// from the mirror; expansion carries the official semantic sections.
  Widget _getCard(BuildContext context, Map<String, dynamic> display) {
    final snapshot = WorkflowRunDisplay.tryParse(display);
    if (snapshot == null) {
      final run = workflowRunForRow(widget.state, widget.row);
      if (run != null) return _runCard(context, run: run, display: null);
      return _messageCard(
        context,
        title: tr(context, 'chat.workflowCard.unavailable'),
      );
    }
    final run = widget.state.workflowRuns.byRunId(snapshot.runId);
    final data = WorkflowViewData(run: run, display: snapshot);
    final name = snapshot.label.isEmpty
        ? tr(context, 'chat.workflowDetail.titleFallback')
        : snapshot.label;
    final summary = [
      for (final part in workflowSummary(snapshot))
        _summaryLabel(context, part),
    ];
    final body = <Widget>[
      ..._phaseSection(context, data.phases),
      ..._actorSection(context, data.actors),
      ..._logSection(context, snapshot.logTail),
      ..._valueSection(
        context,
        'chat.workflowDetail.section.result',
        data.result,
      ),
      ..._valueSection(
        context,
        'chat.workflowDetail.section.error',
        data.error,
        tone: ZInk.dangerTone(context),
      ),
    ];
    final open = widget.openWorkflowRun;
    final generatedAt = snapshot.generatedAt;
    // The get-run card is, by definition, a tool snapshot; mark it so the
    // counters are not mistaken for live state (design §2.2).
    final snapshotCaption = [
      tr(context, 'chat.workflowCard.snapshot'),
      if (generatedAt != null)
        trP(context, 'chat.workflowDetail.snapshotAge', [
          relativeTime(context, generatedAt),
        ]),
    ].join(' · ');
    return _card(context, [
      _header(
        context,
        title: _runTitle(context, snapshot.status),
        titleColor: _statusColor(context, snapshot.status),
        subtitle: name,
        summary: summary,
        caption: snapshotCaption,
        onOpen: open == null
            ? null
            : () => open(
                context,
                runId: snapshot.runId,
                display: snapshot.raw,
                title: snapshot.label,
              ),
        expandable: body.isNotEmpty,
      ),
      if (body.isNotEmpty) _expandedBody(body),
    ]);
  }

  /// `list_workflow_runs` card: one row per run header; rows whose run is in
  /// the session mirror open the detail page, evicted runs toast instead.
  Widget _listCard(BuildContext context, Map<String, dynamic> display) {
    final list = WorkflowRunListDisplay.tryParse(display);
    if (list == null) {
      return _messageCard(
        context,
        title: tr(context, 'chat.workflowCard.unavailable'),
      );
    }
    final runs = list.runs;
    final body = <Widget>[
      for (final item in runs) _listRow(context, item),
      if (list.truncated)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            tr(context, 'chat.workflowDetail.truncated'),
            style: ZType.caption.copyWith(color: ZInk.faint(context)),
          ),
        ),
    ];
    return _card(context, [
      _header(
        context,
        title: tr(context, 'chat.workflowCard.listTitle'),
        summary: [
          trP(context, 'chat.workflowCard.listCount', ['${runs.length}']),
        ],
        expandable: body.isNotEmpty,
      ),
      if (body.isNotEmpty) _expandedBody(body),
    ]);
  }

  Widget _messageCard(
    BuildContext context, {
    required String title,
    Color? titleColor,
    String? subtitle,
    List<String> summary = const [],
    List<Widget> body = const [],
  }) {
    return _card(context, [
      _header(
        context,
        title: title,
        titleColor: titleColor,
        subtitle: subtitle,
        summary: summary,
        expandable: body.isNotEmpty,
      ),
      if (body.isNotEmpty) _expandedBody(body),
    ]);
  }

  // ------------------------------------------------------------- fragments

  Widget _card(BuildContext context, List<Widget> children) {
    return Padding(
      // Same turn-part rhythm as the bare tool tile.
      padding: const EdgeInsets.only(bottom: ZTile.seam),
      child: Material(
        color: ZInk.tile(context),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZRadius.tile),
          side: BorderSide(color: ZInk.hairline(context)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }

  Widget _header(
    BuildContext context, {
    required String title,
    Color? titleColor,
    String? subtitle,
    List<String> summary = const [],
    String? caption,
    VoidCallback? onOpen,
    required bool expandable,
  }) {
    final content = Padding(
      padding: ZTile.head,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: ZTile.headHeight),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ZType.body.copyWith(
                      fontWeight: FontWeight.w500,
                      color: titleColor ?? ZInk.solid(context),
                    ),
                  ),
                  if (subtitle != null && subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ZType.sub.copyWith(color: ZInk.soft(context)),
                    ),
                  ],
                  if (summary.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      summary.join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: ZType.caption.copyWith(
                        color: ZInk.faint(context),
                      ),
                    ),
                  ],
                  if (caption != null && caption.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ZType.caption.copyWith(
                        color: ZInk.faint(context),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (onOpen != null)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: IconButton(
                  icon: Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: ZInk.faint(context),
                  ),
                  iconSize: 18,
                  tooltip: tr(context, 'chat.workflowCard.openDetails'),
                  // A bare 18px glyph was a 18×18 hit target; keep the header
                  // compact but give the drill-in the zTouch box.
                  constraints: const BoxConstraints(
                    minWidth: zTouchWidth,
                    minHeight: zTouchHeight,
                  ),
                  onPressed: onOpen,
                ),
              ),
          ],
        ),
      ),
    );
    if (!expandable) return content;
    return InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      child: content,
    );
  }

  Widget _expandedBody(List<Widget> children) {
    if (!_expanded) return const SizedBox.shrink();
    return Padding(
      padding: ZTile.body,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String key) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 3),
      child: Text(
        tr(context, key),
        style: ZType.caption.copyWith(
          fontWeight: FontWeight.w600,
          color: ZInk.faint(context),
        ),
      ),
    );
  }

  List<Widget> _phaseLines(
    BuildContext context,
    List<WorkflowPhaseView> phases, {
    int? cap,
  }) {
    if (phases.isEmpty) return const [];
    final shown = cap == null || phases.length <= cap
        ? phases
        : phases.sublist(0, cap);
    return [
      for (final phase in shown) _phaseLine(context, phase),
      if (phases.length > shown.length)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            trP(context, 'chat.workflowCard.morePhases', [
              '${phases.length - shown.length}',
            ]),
            style: ZType.caption.copyWith(color: ZInk.faint(context)),
          ),
        ),
    ];
  }

  List<Widget> _phaseSection(
    BuildContext context,
    List<WorkflowPhaseView> phases,
  ) {
    if (phases.isEmpty) return const [];
    return [
      _sectionTitle(context, 'chat.workflowDetail.section.phases'),
      ..._phaseLines(context, phases),
    ];
  }

  Widget _phaseLine(BuildContext context, WorkflowPhaseView phase) {
    final meta = <String>[
      if (phase.state.isNotEmpty) _phaseStateLabel(context, phase.state),
      if (phase.rounds > 0)
        trP(context, 'chat.workflowCard.rounds', ['${phase.rounds}']),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              phase.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ZType.sub.copyWith(color: ZInk.soft(context)),
            ),
          ),
          if (meta.isNotEmpty)
            Flexible(
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  meta.join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ZType.caption.copyWith(color: ZInk.faint(context)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _actorSection(
    BuildContext context,
    List<WorkflowActorView> actors,
  ) {
    if (actors.isEmpty) return const [];
    return [
      _sectionTitle(context, 'chat.workflowDetail.section.agents'),
      for (final actor in actors) _actorLine(context, actor),
    ];
  }

  Widget _actorLine(BuildContext context, WorkflowActorView actor) {
    final name = actor.name ?? '${actor.siteId}#${actor.ordinal}';
    final meta = <String>[
      if (actor.status.isNotEmpty) _agentStateLabel(context, actor.status),
      if (actor.phaseName != null) actor.phaseName!,
      if (actor.lastTool != null) actor.lastTool!.name,
      if (actor.tokens > 0)
        trP(context, 'chat.workflowCard.tokens', [
          compactTokens(context, actor.tokens),
        ]),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ZType.sub.copyWith(color: ZInk.soft(context)),
            ),
          ),
          if (meta.isNotEmpty)
            Flexible(
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  meta.join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ZType.caption.copyWith(color: ZInk.faint(context)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _logSection(
    BuildContext context,
    List<WorkflowDisplayLog> logs,
  ) {
    if (logs.isEmpty) return const [];
    final tail = logs.length <= 6 ? logs : logs.sublist(logs.length - 6);
    return [
      _sectionTitle(context, 'chat.workflowDetail.section.logs'),
      for (final log in tail)
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text(
            log.message,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: ZType.caption.copyWith(
              color: ZInk.muted(context),
              fontFamily: 'monospace',
            ),
          ),
        ),
    ];
  }

  List<Widget> _valueSection(
    BuildContext context,
    String key,
    String? value, {
    Color? tone,
  }) {
    if (value == null || value.trim().isEmpty) return const [];
    return [
      _sectionTitle(context, key),
      Text(
        value,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: ZType.sub.copyWith(color: tone ?? ZInk.soft(context)),
      ),
    ];
  }

  Widget _listRow(BuildContext context, WorkflowRunListItem item) {
    final label = item.label.isNotEmpty ? item.label : item.runId;
    final ageMs = item.updatedAt > 0 ? item.updatedAt : item.createdAt;
    final meta = <String>[
      if (item.status.isNotEmpty) _statusLabel(context, item.status),
      if (ageMs > 0) relativeTime(context, ageMs),
    ];
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            _statusIcon(item.status),
            size: ZTile.iconSize,
            color: _statusColor(context, item.status),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ZType.sub.copyWith(color: ZInk.solid(context)),
                ),
                if (meta.isNotEmpty)
                  Text(
                    meta.join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ZType.caption.copyWith(
                      color: ZInk.faint(context),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    final open = widget.openWorkflowRun;
    if (open == null) return content;
    return InkWell(
      onTap: () {
        final run = widget.state.workflowRuns.byRunId(item.runId);
        if (run == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                tr(context, 'chat.workflowCard.runNotInSession'),
              ),
            ),
          );
          return;
        }
        open(
          context,
          runId: item.runId,
          title: item.label.isEmpty ? null : item.label,
        );
      },
      child: content,
    );
  }

  // ----------------------------------------------------------------- copy

  String _runTitle(BuildContext context, String status) {
    final suffix = switch (status) {
      'pending' => 'started',
      'running' => 'running',
      'completed' => 'completed',
      'errored' => 'errored',
      'stopped' => 'stopped',
      'superseded' => 'superseded',
      _ => 'ended',
    };
    return tr(context, 'chat.workflowCard.$suffix');
  }

  String _statusLabel(BuildContext context, String status) {
    if (status.isEmpty) return '';
    const known = {
      'pending',
      'running',
      'completed',
      'errored',
      'stopped',
      'superseded',
    };
    if (!known.contains(status)) return status;
    return tr(context, 'chat.workflowCard.status.$status');
  }

  String _phaseStateLabel(BuildContext context, String state) {
    return switch (state) {
      'done' => tr(context, 'chat.workflowDetail.phaseState.done'),
      'current' => tr(context, 'chat.workflowDetail.phaseState.current'),
      'ahead' => tr(context, 'chat.workflowDetail.phaseState.ahead'),
      'unfinished' => tr(context, 'chat.workflowDetail.phaseState.unfinished'),
      _ => state,
    };
  }

  String _agentStateLabel(BuildContext context, String state) {
    final normalized = switch (state) {
      'running' => 'executing',
      'completed' => 'done',
      _ => state,
    };
    const known = {
      'idle',
      'executing',
      'waiting',
      'parked',
      'done',
      'failed',
      'unfinished',
    };
    if (!known.contains(normalized)) return normalized;
    return tr(context, 'chat.workflowDetail.agentState.$normalized');
  }

  String _summaryLabel(BuildContext context, WorkflowSummaryPart part) {
    final value = '${part.value}';
    return switch (part.kind) {
      WorkflowSummaryKind.nodesProgress => trP(context, 'chat.workflowCard.steps', [
        value,
        '${part.total ?? 0}',
      ]),
      WorkflowSummaryKind.nodesObserved => trP(
        context,
        'chat.workflowCard.nodesObserved',
        [value],
      ),
      WorkflowSummaryKind.nodesCompleted => trP(
        context,
        'chat.workflowCard.nodesCompleted',
        [value],
      ),
      WorkflowSummaryKind.nodesRunning => trP(
        context,
        'chat.workflowCard.nodesRunning',
        [value],
      ),
      WorkflowSummaryKind.nodesFailed => trP(
        context,
        'chat.workflowCard.nodesFailed',
        [value],
      ),
      WorkflowSummaryKind.agentsRunning => trP(
        context,
        'chat.workflowCard.agentsWorking',
        [value],
      ),
      WorkflowSummaryKind.agents => trP(context, 'chat.workflowCard.agents', [
        value,
      ]),
      WorkflowSummaryKind.tokens => trP(context, 'chat.workflowCard.tokens', [
        compactTokens(context, part.value),
      ]),
      WorkflowSummaryKind.artifacts => trP(
        context,
        'chat.workflowCard.artifacts',
        [value],
      ),
      WorkflowSummaryKind.questions => trP(
        context,
        'chat.workflowCard.questions',
        [value],
      ),
    };
  }

  Color _statusColor(BuildContext context, String status) {
    return switch (status) {
      'completed' || 'done' => ZInk.successTone(context),
      'errored' || 'failed' => ZInk.dangerTone(context),
      'stopped' || 'superseded' || 'unfinished' => ZInk.warningTone(context),
      'running' || 'executing' => ZColors.sky400,
      _ => ZInk.faint(context),
    };
  }

  IconData _statusIcon(String status) {
    return switch (status) {
      'completed' => Icons.check_circle_outline,
      'errored' => Icons.error_outline,
      'stopped' || 'superseded' => Icons.cancel_outlined,
      'running' => Icons.sync,
      _ => Icons.radio_button_unchecked,
    };
  }
}
