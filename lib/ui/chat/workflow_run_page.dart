// Read-only workflow run detail page (design 11-03 §4).
//
// Data priority: the live session mirror (`ConversationState.workflowRuns`)
// wins for status/progress/phases/nodes/actors/questions/artifacts/reports;
// the `get_workflow_run` tool display is the fallback snapshot (rich actor
// fields, logs, health, full result) and becomes the only source when the
// run was evicted from the mirror. The page is strictly read-only: no stop,
// resume, answer or artifact-open affordance — the AppBar back button is
// the only control. All copy goes through `tr`/`trP`; the lexicon entries
// land in the i18n step.

import 'package:flutter/material.dart';

import '../../protocol/conversation_state.dart';
import '../../protocol/workflow_run_display.dart';
import '../theme.dart';
import '../ui_settings.dart';
import 'workflow_card.dart';

String? _nonEmpty(String? value) {
  final trimmed = (value ?? '').trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// One workflow run, opened from a chat tool card (or the management
/// sheet). [display] is the raw tool payload when the entry point had one
/// (create/resume/get); [title] is the already-resolved run name and
/// [workStartedAt]/[workEndedAt] the parent background-work bounds when
/// known.
class WorkflowRunPage extends StatelessWidget {
  final ConversationState state;
  final String runId;
  final Map<String, dynamic>? display;
  final String? title;
  final int? workStartedAt;
  final int? workEndedAt;

  const WorkflowRunPage({
    super.key,
    required this.state,
    required this.runId,
    this.display,
    this.title,
    this.workStartedAt,
    this.workEndedAt,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        // Re-read the mirror on every notification: a `workflowRun.updated`
        // delta must repaint status/phases/nodes/actors without re-opening
        // the page.
        final run = state.workflowRuns.byRunId(runId);
        final snapshot = WorkflowRunDisplay.tryParse(display);
        final data = WorkflowViewData(run: run, display: snapshot);

        if (data.run == null && !data.hasSnapshot) {
          return Scaffold(
            appBar: AppBar(
              title: Text(
                _pageTitle(context, data),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(ZSpacing.emptyState),
                child: Text(
                  tr(context, 'chat.workflowDetail.notInSession'),
                  textAlign: TextAlign.center,
                  style: ZType.sub.copyWith(color: ZInk.faint(context)),
                ),
              ),
            ),
          );
        }

        return Scaffold(
          appBar: AppBar(
            title: Text(
              _pageTitle(context, data),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: zContentMaxWidth),
              child: ListView(
                padding: zScreenPadding(context, bottom: 32),
                children: [
                  if (data.isDisplayOnly) _snapshotBanner(context, data),
                  _statusHeader(context, data),
                  ..._progressSection(context, data),
                  ..._questionsSection(context, data),
                  ..._phasesSection(context, data),
                  ..._agentsSection(context, data),
                  ..._resultSection(context, data),
                  ..._artifactsSection(context, data),
                  ..._reportsSection(context, data),
                  ..._logsSection(context, data),
                  ..._healthSection(context, data),
                  if (data.truncated)
                    _caption(
                      context,
                      tr(context, 'chat.workflowDetail.truncated'),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------- header

  String _pageTitle(BuildContext context, WorkflowViewData data) {
    final given = _nonEmpty(title);
    if (given != null) return given;
    final label = _nonEmpty(data.display?.label);
    if (label != null) return label;
    return tr(context, 'chat.workflowDetail.titleFallback');
  }

  /// Snapshot-only badge: the mirror no longer holds the run (evicted or
  /// predating this session), so the whole page is a tool snapshot.
  Widget _snapshotBanner(BuildContext context, WorkflowViewData data) {
    final tone = ZInk.warningTone(context);
    final parts = <String>[
      tr(context, 'chat.workflowDetail.snapshotOnly'),
      if (data.generatedAt != null)
        trP(context, 'chat.workflowDetail.snapshotAge', [
          relativeTime(context, data.generatedAt!),
        ]),
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: ZTile.seam),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(ZRadius.field),
        border: Border.all(color: ZInk.hairline(context)),
      ),
      child: Row(
        children: [
          Icon(Icons.history, size: ZTile.iconSize, color: tone),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              parts.join(' · '),
              style: ZType.caption.copyWith(color: tone),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusHeader(BuildContext context, WorkflowViewData data) {
    final chips = <Widget>[
      if (data.status.isNotEmpty)
        _chip(
          context,
          _statusLabel(context, data.status),
          _statusColor(context, data.status),
        ),
      if (data.stopReason != null)
        _chip(
          context,
          _stopReasonLabel(context, data.stopReason!),
          ZInk.warningTone(context),
        ),
      if (data.resumable)
        _chip(
          context,
          tr(context, 'chat.workflowDetail.resumable'),
          ZInk.successTone(context),
        ),
      if (data.possiblyInterrupted)
        _chip(
          context,
          tr(context, 'chat.workflowDetail.possiblyInterrupted'),
          ZInk.warningTone(context),
        ),
    ];
    final run = data.run;
    final elapsedMs = _elapsedMs(data);
    final spentTokens = run != null && run.spentTokens > 0
        ? run.spentTokens
        : (data.display?.usage?.spentTokens ?? 0);
    final concurrency = _concurrencyLabel(context, data);
    final meta = <String>[
      if (elapsedMs != null)
        trP(context, 'chat.turn.worked', [
          _formatDuration(context, elapsedMs),
        ]),
      if (spentTokens > 0)
        trP(context, 'chat.workflowCard.tokens', [
          compactTokens(context, spentTokens),
        ]),
      if (concurrency != null) concurrency,
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: ZTile.seam),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (chips.isNotEmpty)
            Wrap(spacing: 6, runSpacing: 6, children: chips),
          if (meta.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              meta.join(' · '),
              style: ZType.caption.copyWith(color: ZInk.faint(context)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(ZRadius.pill),
      ),
      child: Text(
        text,
        style: ZType.caption.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  /// Elapsed time: the caller's work bounds first; the snapshot's phase
  /// windows (earliest `enteredAt` → latest `exitedAt`) are the fallback for
  /// chat-entry pages that carry no work timestamps (PRD R2.1). A span that
  /// is not positive renders nothing.
  int? _elapsedMs(WorkflowViewData data) {
    if (workStartedAt != null && workEndedAt != null) {
      final span = workEndedAt! - workStartedAt!;
      return span > 0 ? span : null;
    }
    final phases = data.display?.phases;
    if (phases == null || phases.isEmpty) return null;
    int? start;
    int? end;
    for (final phase in phases) {
      final enteredAt = phase.enteredAt;
      final exitedAt = phase.exitedAt;
      if (enteredAt != null && (start == null || enteredAt < start)) {
        start = enteredAt;
      }
      if (exitedAt != null && (end == null || exitedAt > end)) {
        end = exitedAt;
      }
    }
    if (start == null || end == null || end <= start) return null;
    return end - start;
  }

  /// Concurrency line: the official snapshot pair (`effective/cap`) first;
  /// mirror-only runs fall back to the run's `cap` (then `ceiling`/`limit`)
  /// counter. No field beyond the documented wire keys is inferred.
  String? _concurrencyLabel(BuildContext context, WorkflowViewData data) {
    final snapshot = data.health?.concurrency;
    if (snapshot != null && snapshot.cap > 0) {
      return trP(context, 'chat.workflowDetail.health.concurrency', [
        '${snapshot.effective}/${snapshot.cap}',
      ]);
    }
    final raw = data.run?.concurrency;
    if (raw == null) return null;
    for (final field in const ['cap', 'ceiling', 'limit']) {
      final value = raw[field];
      if (value is num && value > 0) {
        return trP(context, 'chat.workflowDetail.health.concurrency', [
          '${value.toInt()}',
        ]);
      }
    }
    return null;
  }

  // -------------------------------------------------------------- progress

  List<Widget> _progressSection(
    BuildContext context,
    WorkflowViewData data,
  ) {
    final out = <Widget>[];
    if (data.hasProgress) {
      final total = data.nodesTotal;
      final settled = data.nodesSettled;
      final ratio = total <= 0
          ? 0.0
          : (settled / total).clamp(0.0, 1.0).toDouble();
      final color = settled >= total
          ? ZInk.successTone(context)
          : ZInk.usageBlue(context);
      out.add(_sectionTitle(context, 'chat.workflowDetail.progress'));
      out.add(
        ClipRRect(
          borderRadius: BorderRadius.circular(ZRadius.mini),
          child: Stack(
            children: [
              Container(
                height: ZSpacing.progressBar,
                color: ZInk.barTrack(context),
              ),
              FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: ratio,
                child: Container(
                  height: ZSpacing.progressBar,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      );
      out.add(
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            trP(context, 'chat.workflowCard.steps', ['$settled', '$total']),
            style: ZType.caption.copyWith(color: ZInk.faint(context)),
          ),
        ),
      );
      return out;
    }

    // Snapshot-only runs have no mirror nodes; the official counters are
    // the progress line instead of a fake bar.
    final snapshot = data.display;
    if (snapshot == null) return out;
    final labels = [
      for (final part in workflowSummary(snapshot))
        _summaryLabel(context, part),
    ];
    if (labels.isEmpty) return out;
    out.add(_sectionTitle(context, 'chat.workflowDetail.progress'));
    out.add(
      Text(
        labels.join(' · '),
        style: ZType.caption.copyWith(color: ZInk.faint(context)),
      ),
    );
    return out;
  }

  // ------------------------------------------------------------- questions

  List<Widget> _questionsSection(
    BuildContext context,
    WorkflowViewData data,
  ) {
    final questions = data.pendingQuestions;
    if (questions.isEmpty) {
      // No mirror: the snapshot's health flag is the only "are they known"
      // signal. A known-empty list renders nothing.
      if (data.run == null && data.health?.pendingQuestionsKnown == false) {
        return [
          _sectionTitle(context, 'chat.workflowDetail.section.questions'),
          _caption(
            context,
            tr(context, 'chat.workflowDetail.questionsUnknown'),
          ),
        ];
      }
      return const [];
    }
    return [
      _sectionTitle(context, 'chat.workflowDetail.section.questions'),
      for (final question in questions)
        _questionCard(context, question, data.actors),
      // Strictly read-only: answering needs the desktop or the main chat.
      _caption(context, tr(context, 'chat.workflowDetail.questionReadonly')),
    ];
  }

  Widget _questionCard(
    BuildContext context,
    WorkflowQuestion question,
    List<WorkflowActorView> actors,
  ) {
    final actor =
        _actorNameFor(actors, question.actorSiteId, question.actorOrdinal) ??
        _nonEmpty(question.actorName);
    final contextText = _nonEmpty(question.context);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: ZInk.tile(context),
        borderRadius: BorderRadius.circular(ZRadius.field),
        border: Border.all(color: ZInk.hairline(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (actor != null)
            Text(
              actor,
              style: ZType.caption.copyWith(color: ZInk.faint(context)),
            ),
          if (_nonEmpty(question.question) != null)
            Padding(
              padding: EdgeInsets.only(top: actor == null ? 0 : 2),
              child: Text(
                question.question,
                style: ZType.body.copyWith(color: ZInk.solid(context)),
              ),
            ),
          if (contextText != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                contextText,
                style: ZType.sub.copyWith(color: ZInk.muted(context)),
              ),
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- phases

  List<Widget> _phasesSection(BuildContext context, WorkflowViewData data) {
    final phases = data.phases;
    final known = {for (final phase in phases) phase.name};
    final unphased = [
      for (final node in data.nodes)
        if (node.phaseName == null || !known.contains(node.phaseName)) node,
    ];
    if (phases.isEmpty && unphased.isEmpty) {
      return [
        _sectionTitle(context, 'chat.workflowDetail.section.phases'),
        _caption(context, tr(context, 'chat.workflowDetail.noPhases')),
      ];
    }
    return [
      _sectionTitle(context, 'chat.workflowDetail.section.phases'),
      for (final phase in phases)
        _phaseTile(
          context,
          tileKey: ValueKey('phase-${phase.name}'),
          title: phase.name,
          meta: _phaseMeta(context, phase),
          nodes: [
            for (final node in data.nodes)
              if (node.phaseName == phase.name) node,
          ],
          actors: data.actors,
        ),
      if (unphased.isNotEmpty)
        _phaseTile(
          context,
          tileKey: const ValueKey('phase-unphased'),
          title: tr(context, 'chat.workflowDetail.unphased'),
          meta: const [],
          nodes: unphased,
          actors: data.actors,
        ),
    ];
  }

  List<String> _phaseMeta(
    BuildContext context,
    WorkflowPhaseView phase,
  ) {
    return [
      if (phase.state.isNotEmpty) _phaseStateLabel(context, phase.state),
      if (phase.rounds > 0)
        trP(context, 'chat.workflowDetail.phaseRounds', ['${phase.rounds}']),
      if (phase.nodesSettled > 0)
        trP(context, 'chat.workflowDetail.phaseSettled', [
          '${phase.nodesSettled}',
        ]),
      if (phase.nodesRunning > 0)
        trP(context, 'chat.workflowDetail.phaseRunning', [
          '${phase.nodesRunning}',
        ]),
    ];
  }

  Widget _phaseTile(
    BuildContext context, {
    required Key tileKey,
    required String title,
    required List<String> meta,
    required List<WorkflowNode> nodes,
    required List<WorkflowActorView> actors,
  }) {
    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: ZType.sub.copyWith(
            color: ZInk.soft(context),
            fontWeight: FontWeight.w600,
          ),
        ),
        if (meta.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Text(
              meta.join(' · '),
              style: ZType.caption.copyWith(color: ZInk.faint(context)),
            ),
          ),
      ],
    );
    // Display-only phases carry no nodes: a plain row beats an
    // ExpansionTile that expands into nothing.
    if (nodes.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: header,
      );
    }
    return ExpansionTile(
      key: tileKey,
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(
        left: ZTile.headPadding,
        bottom: 6,
      ),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      shape: const Border(),
      collapsedShape: const Border(),
      title: header,
      children: [
        for (final node in nodes) _nodeRow(context, node, actors),
      ],
    );
  }

  Widget _nodeRow(
    BuildContext context,
    WorkflowNode node,
    List<WorkflowActorView> actors,
  ) {
    final head = <String>[
      if (node.kind != null) _nodeKindLabel(context, node.kind!),
      if (node.phase.isNotEmpty) _nodePhaseLabel(context, node.phase),
      if (node.outcome != null) _outcomeLabel(context, node.outcome!),
    ];
    final actor = _actorNameFor(actors, node.actorSiteId, node.actorOrdinal);
    final meta = <String>[
      if (actor != null) actor,
      if (node.turn != null)
        trP(context, 'chat.workflowDetail.nodeTurn', ['${node.turn}']),
      if (node.toolCalls != null)
        trP(context, 'chat.workflowDetail.nodeToolCalls', [
          '${node.toolCalls}',
        ]),
      if (node.lastToolName != null)
        trP(context, 'chat.workflowDetail.nodeLastTool', [
          node.lastToolTarget == null
              ? node.lastToolName!
              : '${node.lastToolName!} · ${node.lastToolTarget!}',
        ]),
    ];
    final instructions = _nonEmpty(node.instructionsHead);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (head.isNotEmpty)
            Text(
              head.join(' · '),
              style: ZType.sub.copyWith(color: ZInk.soft(context)),
            ),
          if (instructions != null)
            Text(
              instructions,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ZType.caption.copyWith(color: ZInk.muted(context)),
            ),
          if (meta.isNotEmpty)
            Text(
              meta.join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: ZType.caption.copyWith(color: ZInk.faint(context)),
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- agents

  List<Widget> _agentsSection(BuildContext context, WorkflowViewData data) {
    final actors = data.actors;
    if (actors.isEmpty) {
      return [
        _sectionTitle(context, 'chat.workflowDetail.section.agents'),
        _caption(context, tr(context, 'chat.workflowDetail.noAgents')),
      ];
    }
    return [
      _sectionTitle(context, 'chat.workflowDetail.section.agents'),
      for (final actor in actors) _agentRow(context, actor),
    ];
  }

  Widget _agentRow(BuildContext context, WorkflowActorView actor) {
    final name =
        actor.name ?? '${actor.siteId}#${actor.ordinal}';
    final stateLabel = actor.status.isEmpty
        ? ''
        : _agentStateLabel(context, actor.status);
    final instructions = _nonEmpty(actor.instructionsHead);
    final lastTool = actor.lastTool;
    final waitCause = actor.waitCause == null
        ? null
        : _waitCauseLabel(context, actor.waitCause!, actor.retryAfterMs);
    final meta = <String>[
      if (actor.phaseName != null) actor.phaseName!,
      if (actor.stepsSettled > 0 || actor.stepsFailed > 0)
        trP(context, 'chat.workflowDetail.agentSteps', [
          '${actor.stepsSettled}',
          '${actor.stepsFailed}',
        ]),
      if (actor.tokens > 0)
        trP(context, 'chat.workflowCard.tokens', [
          compactTokens(context, actor.tokens),
        ]),
      if (actor.toolCalls != null)
        trP(context, 'chat.workflowDetail.agentTools', [
          '${actor.toolCalls}',
        ]),
      if (waitCause != null) waitCause,
      if (actor.parkedOn != null)
        trP(context, 'chat.workflowDetail.agentParkedOn', [
          actor.parkedOn!,
        ]),
      if (lastTool != null && lastTool.name.isNotEmpty)
        lastTool.target == null
            ? lastTool.name
            : '${lastTool.name} · ${lastTool.target!}',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ZType.sub.copyWith(color: ZInk.soft(context)),
                ),
              ),
              if (stateLabel.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(
                    stateLabel,
                    style: ZType.caption.copyWith(
                      color: _statusColor(context, actor.status),
                    ),
                  ),
                ),
            ],
          ),
          if (actor.model != null)
            Text(
              actor.model!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ZType.caption.copyWith(color: ZInk.faint(context)),
            ),
          if (instructions != null)
            Text(
              instructions,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ZType.caption.copyWith(color: ZInk.muted(context)),
            ),
          if (meta.isNotEmpty)
            Text(
              meta.join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: ZType.caption.copyWith(color: ZInk.faint(context)),
            ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ result/error

  List<Widget> _resultSection(BuildContext context, WorkflowViewData data) {
    final result = _nonEmpty(data.result);
    final error = _nonEmpty(data.error);
    final out = <Widget>[];
    if (result != null) {
      out.add(_sectionTitle(context, 'chat.workflowDetail.section.result'));
      out.add(
        Text(
          result,
          style: ZType.sub.copyWith(color: ZInk.soft(context)),
        ),
      );
    }
    if (error != null) {
      out.add(_sectionTitle(context, 'chat.workflowDetail.section.error'));
      out.add(
        Text(
          error,
          style: ZType.sub.copyWith(color: ZInk.dangerTone(context)),
        ),
      );
    }
    if (result == null && error == null) {
      out.add(_sectionTitle(context, 'chat.workflowDetail.section.result'));
      out.add(_caption(context, tr(context, 'chat.workflowDetail.noResult')));
    }
    return out;
  }

  // ------------------------------------------------------------- artifacts

  List<Widget> _artifactsSection(
    BuildContext context,
    WorkflowViewData data,
  ) {
    if (data.artifacts.isEmpty) return const [];
    return [
      _sectionTitle(context, 'chat.workflowDetail.section.artifacts'),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final artifact in data.artifacts)
            _artifactChip(context, artifact),
        ],
      ),
    ];
  }

  /// Display-only chip: artifacts are never opened from this page (no
  /// artifact RPC), so there is deliberately no tap target.
  Widget _artifactChip(BuildContext context, WorkflowArtifact artifact) {
    final label =
        _nonEmpty(artifact.title) ??
        _nonEmpty(artifact.id) ??
        artifact.kind;
    final meta = <String>[
      if (artifact.itemCount != null)
        trP(context, 'chat.workflowDetail.artifactItems', [
          '${artifact.itemCount}',
        ]),
      if (artifact.bytes != null)
        trP(context, 'chat.workflowDetail.artifactBytes', [
          '${artifact.bytes}',
        ]),
      if (artifact.version > 0)
        trP(context, 'chat.workflowDetail.artifactVersion', [
          '${artifact.version}',
        ]),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: ZInk.tile(context),
        borderRadius: BorderRadius.circular(ZRadius.pill),
        border: Border.all(
          color: artifact.primary
              ? ZInk.successTone(context)
              : ZInk.hairline(context),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: ZType.caption.copyWith(
              color: ZInk.soft(context),
              fontWeight: FontWeight.w500,
            ),
          ),
          if (meta.isNotEmpty)
            Text(
              meta.join(' · '),
              style: ZType.caption.copyWith(color: ZInk.faint(context)),
            ),
        ],
      ),
    );
  }

  // --------------------------------------------------------------- reports

  List<Widget> _reportsSection(BuildContext context, WorkflowViewData data) {
    final reports = [
      for (final report in data.reports)
        if (_nonEmpty(report.preview) != null ||
            _nonEmpty(report.artifactId) != null)
          report,
    ];
    if (reports.isEmpty) return const [];
    return [
      _sectionTitle(context, 'chat.workflowDetail.section.reports'),
      for (final report in reports)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_nonEmpty(report.preview) != null)
                Text(
                  report.preview,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: ZType.sub.copyWith(color: ZInk.soft(context)),
                ),
              if (_nonEmpty(report.artifactId) != null)
                Text(
                  report.artifactId!,
                  style: ZType.caption.copyWith(color: ZInk.faint(context)),
                ),
            ],
          ),
        ),
    ];
  }

  // ------------------------------------------------------------------ logs

  List<Widget> _logsSection(BuildContext context, WorkflowViewData data) {
    // Logs exist only in the `get_workflow_run` snapshot; a mirror-only run
    // renders no empty log section.
    final logs = [
      for (final log in data.logTail)
        if (log.message.trim().isNotEmpty) log,
    ];
    if (logs.isEmpty) return const [];
    return [
      _sectionTitle(context, 'chat.workflowDetail.section.logs'),
      for (final log in logs)
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

  // ---------------------------------------------------------------- health

  List<Widget> _healthSection(BuildContext context, WorkflowViewData data) {
    final health = data.health;
    if (health == null) return const [];
    final parts = <String>[
      if (health.stalledSince != null)
        trP(context, 'chat.workflowDetail.health.stalled', [
          relativeTime(context, health.stalledSince!),
        ]),
      if (health.consecutiveFailures > 0)
        trP(context, 'chat.workflowDetail.health.failures', [
          '${health.consecutiveFailures}',
        ]),
      if (health.cachedSteps > 0)
        trP(context, 'chat.workflowDetail.health.cached', [
          '${health.cachedSteps}',
        ]),
      if ((health.leftoverRunning ?? 0) > 0)
        trP(context, 'chat.workflowDetail.health.leftover', [
          '${health.leftoverRunning}',
        ]),
    ];
    if (parts.isEmpty) return const [];
    return [
      _sectionTitle(context, 'chat.workflowDetail.section.health'),
      Text(
        parts.join(' · '),
        style: ZType.caption.copyWith(color: ZInk.faint(context)),
      ),
    ];
  }

  // ------------------------------------------------------------------ copy

  Widget _sectionTitle(BuildContext context, String key) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 6),
      child: Text(
        tr(context, key),
        style: ZType.heading.copyWith(color: ZInk.soft(context)),
      ),
    );
  }

  Widget _caption(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 6),
      child: Text(
        text,
        style: ZType.caption.copyWith(color: ZInk.faint(context)),
      ),
    );
  }

  String _formatDuration(BuildContext context, int ms) {
    final seconds = (ms / 1000).round();
    if (seconds < 60) {
      return trP(context, 'chat.time.secOnly', ['$seconds']);
    }
    return trP(context, 'chat.time.minSec', [
      '${seconds ~/ 60}',
      '${seconds % 60}',
    ]);
  }

  String _statusLabel(BuildContext context, String status) {
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

  String _stopReasonLabel(BuildContext context, String reason) {
    const known = {
      'user',
      'model',
      'provider',
      'interrupted',
      'superseded',
    };
    if (!known.contains(reason)) return reason;
    return tr(context, 'chat.workflowDetail.stopReason.$reason');
  }

  String _phaseStateLabel(BuildContext context, String state) {
    return switch (state) {
      'done' => tr(context, 'chat.workflowDetail.phaseState.done'),
      'current' => tr(context, 'chat.workflowDetail.phaseState.current'),
      'ahead' => tr(context, 'chat.workflowDetail.phaseState.ahead'),
      'unfinished' =>
        tr(context, 'chat.workflowDetail.phaseState.unfinished'),
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

  String _nodeKindLabel(BuildContext context, String kind) {
    return switch (kind) {
      'ask' => tr(context, 'chat.workflowDetail.nodeKind.ask'),
      'world-read' => tr(context, 'chat.workflowDetail.nodeKind.worldRead'),
      _ => kind,
    };
  }

  String _nodePhaseLabel(BuildContext context, String phase) {
    const known = {
      'queued',
      'dispatched',
      'executing',
      'waiting',
      'repairing',
      'nudged',
      'settled',
    };
    if (!known.contains(phase)) return phase;
    return tr(context, 'chat.workflowDetail.nodePhase.$phase');
  }

  String _outcomeLabel(BuildContext context, String outcome) {
    const known = {'ok', 'failed', 'cancelled'};
    if (!known.contains(outcome)) return outcome;
    return tr(context, 'chat.workflowDetail.outcome.$outcome');
  }

  String? _waitCauseLabel(
    BuildContext context,
    String cause,
    int? retryAfterMs,
  ) {
    if (cause == 'slot') {
      return tr(context, 'chat.workflowDetail.agentWaitingSlot');
    }
    if (cause == 'backoff') {
      if (retryAfterMs == null) return cause;
      final seconds = (retryAfterMs / 1000).ceil();
      return trP(context, 'chat.workflowDetail.agentBackoff', [
        '${seconds < 0 ? 0 : seconds}',
      ]);
    }
    return cause;
  }

  String? _actorNameFor(
    List<WorkflowActorView> actors,
    String? siteId,
    int? ordinal,
  ) {
    if (siteId == null) return null;
    for (final actor in actors) {
      if (actor.siteId != siteId) continue;
      if (ordinal != null && actor.ordinal != ordinal) continue;
      return actor.name ?? '${actor.siteId}#${actor.ordinal}';
    }
    return null;
  }

  Color _statusColor(BuildContext context, String status) {
    return switch (status) {
      'completed' || 'done' => ZInk.successTone(context),
      'errored' || 'failed' => ZInk.dangerTone(context),
      'stopped' || 'superseded' || 'unfinished' =>
        ZInk.warningTone(context),
      'running' || 'executing' => ZColors.sky400,
      'waiting' || 'parked' => ZInk.warningTone(context),
      _ => ZInk.faint(context),
    };
  }

  String _summaryLabel(BuildContext context, WorkflowSummaryPart part) {
    final value = '${part.value}';
    return switch (part.kind) {
      WorkflowSummaryKind.nodesProgress => trP(
        context,
        'chat.workflowCard.steps',
        [value, '${part.total ?? 0}'],
      ),
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
      WorkflowSummaryKind.agents => trP(
        context,
        'chat.workflowCard.agents',
        [value],
      ),
      WorkflowSummaryKind.tokens => trP(
        context,
        'chat.workflowCard.tokens',
        [compactTokens(context, part.value)],
      ),
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
}
