import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/ui/chat/timeline.dart';

/// Task 10-19-timeline-row-order-repair: the desktop's persisted-event
/// materialization replays a message's parts in persist order — tool
/// parts (written at call start) before the reasoning/text parts (flushed
/// later) — so cold-resumed (and force-rehydrated live) snapshots carry
/// [toolCall, reasoning, assistantText] where the live order was
/// [reasoning, assistantText, toolCall]. The wire rows of one message
/// share `assistantResponseId` (live-probed 2026-10-19, desktop
/// 3.15.3.8237); [repairInvertedToolOrder] class-sorts each message run.

Map<String, dynamic> _row(
  int rowId,
  String kind, {
  String? ar,
  String tool = '',
}) => {
  'rowId': rowId,
  'kind': kind,
  if (ar != null) 'assistantResponseId': ar,
  if (tool.isNotEmpty) 'toolName': tool,
};

List<int> _ids(List<Map<String, dynamic>> rows) =>
    [for (final r in rows) r['rowId'] as int];

void main() {
  test('inverted message run is repaired to reasoning → text → tool', () {
    final rows = [
      _row(1, 'toolCall', ar: 'm1', tool: 'Read'),
      _row(2, 'reasoning', ar: 'm1'),
      _row(3, 'assistantText', ar: 'm1'),
    ];
    expect(_ids(repairInvertedToolOrder(rows)), [2, 3, 1]);
  });

  test('canonical live order is a no-op (single and multi message)', () {
    final rows = [
      _row(1, 'reasoning', ar: 'm1'),
      _row(2, 'assistantText', ar: 'm1'),
      _row(3, 'toolCall', ar: 'm1', tool: 'Bash'),
      _row(4, 'reasoning', ar: 'm2'),
      _row(5, 'assistantText', ar: 'm2'),
      _row(6, 'toolCall', ar: 'm2', tool: 'Edit'),
    ];
    expect(_ids(repairInvertedToolOrder(rows)), [1, 2, 3, 4, 5, 6]);
  });

  test('cross-message order is never touched', () {
    // tool of m1 legitimately precedes m2's reasoning on the wire.
    final rows = [
      _row(1, 'toolCall', ar: 'm1', tool: 'Bash'),
      _row(2, 'reasoning', ar: 'm2'),
      _row(3, 'assistantText', ar: 'm2'),
    ];
    expect(_ids(repairInvertedToolOrder(rows)), [1, 2, 3]);
  });

  test('keyless attachments follow their host tool call', () {
    final rows = [
      _row(1, 'toolCall', ar: 'm1', tool: 'Agent'),
      _row(2, 'subagent'), // mirror row: no assistantResponseId
      _row(3, 'reasoning', ar: 'm1'),
      _row(4, 'assistantText', ar: 'm1'),
    ];
    final repaired = repairInvertedToolOrder(rows);
    expect(_ids(repaired), [3, 4, 1, 2]);
    // mirror stays glued right after its Agent call.
    expect(_ids(repaired).indexOf(2), _ids(repaired).indexOf(1) + 1);
  });

  test('turn boundaries pass through and never attach to the prior run', () {
    final rows = [
      _row(1, 'toolCall', ar: 'm1', tool: 'Bash'),
      _row(2, 'turnHeader'),
      _row(3, 'userInput'),
      _row(4, 'reasoning', ar: 'm2'),
      _row(5, 'toolCall', ar: 'm2', tool: 'Read'),
    ];
    expect(_ids(repairInvertedToolOrder(rows)), [1, 2, 3, 4, 5]);
  });

  test('rows without any key come back unchanged (shape-drift fallback)', () {
    final rows = [
      _row(1, 'toolCall', tool: 'Bash'),
      _row(2, 'reasoning'),
      _row(3, 'assistantText'),
    ];
    expect(_ids(repairInvertedToolOrder(rows)), [1, 2, 3]);
  });

  test('keyless rows before any run pass through in place', () {
    // A marker between a turn boundary and the message run stays put —
    // keyless rows outside a run never move (shape-drift fallback).
    final rows = [
      _row(1, 'turnHeader'),
      _row(2, 'timelineMarker'),
      _row(3, 'toolCall', ar: 'm1', tool: 'Read'),
      _row(4, 'reasoning', ar: 'm1'),
    ];
    expect(_ids(repairInvertedToolOrder(rows)), [1, 2, 4, 3]);
  });

  test('empty and single-row inputs return unchanged', () {
    expect(repairInvertedToolOrder(const []), isEmpty);
    expect(
      _ids(repairInvertedToolOrder([_row(1, 'reasoning', ar: 'm1')])),
      [1],
    );
  });

  test('repair is idempotent', () {
    final rows = [
      _row(1, 'toolCall', ar: 'm1', tool: 'Read'),
      _row(2, 'subagent'),
      _row(3, 'reasoning', ar: 'm1'),
      _row(4, 'toolCall', ar: 'm1', tool: 'Edit'),
      _row(5, 'assistantText', ar: 'm1'),
    ];
    final once = repairInvertedToolOrder(rows);
    expect(_ids(repairInvertedToolOrder(once)), _ids(once));
  });

  test('tool-only inverted pair repairs; marker mid-run follows its preceding row', () {
    final rows = [
      _row(1, 'toolCall', ar: 'm1', tool: 'Read'),
      _row(2, 'assistantText', ar: 'm1'),
      _row(3, 'timelineMarker'), // keyless marker inside the run
      _row(4, 'toolCall', ar: 'm1', tool: 'Edit'),
    ];
    // The marker inherits the class of the row before it (assistantText),
    // so it stays between the text and the tool pair.
    expect(_ids(repairInvertedToolOrder(rows)), [2, 3, 1, 4]);
  });
}
