import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/state/task_directory.dart';

/// 3.16.2 relay row shape (live probe ITEM0): `status` replaces
/// `displayStatus`; pinned/archived/unreadAt/workspaceIdentity are absent.
Map<String, dynamic> newRow({
  String id = 't1',
  String status = 'completed',
  String? workspacePath = '/repo',
  String? workspaceIdentity,
  bool? pinned,
  int updatedAt = 10,
}) =>
    {
      'taskId': id,
      'traceId': 'trace-$id',
      'title': 'task $id',
      'titleOverridden': false,
      'workspacePath': workspacePath,
      if (workspaceIdentity != null) 'workspaceIdentity': workspaceIdentity,
      'createdAt': 5,
      'updatedAt': updatedAt,
      'mode': 'build',
      'model': 'm',
      'thoughtLevel': 'max',
      'provider': 'glm',
      'status': status,
      'target': null,
      if (pinned != null) 'pinned': pinned,
    };

void main() {
  group('SessionEntry.fromRelayTask dual-read', () {
    test('3.16.2 `status` maps onto the phase vocabulary', () {
      final running = SessionEntry.fromRelayTask(newRow(status: 'running'));
      expect(running.phase, 'running');
      final done = SessionEntry.fromRelayTask(newRow(status: 'completed'));
      expect(done.phase, 'completedSuccess');
      final failed = SessionEntry.fromRelayTask(newRow(status: 'error'));
      expect(failed.phase, 'error');
    });

    test('legacy `displayStatus` still wins when both fields exist', () {
      final entry = SessionEntry.fromRelayTask({
        ...newRow(status: 'completed'),
        'displayStatus': 'running',
      });
      expect(entry.phase, 'running');
    });

    test('missing status -> idle (running-class default)', () {
      final raw = newRow()..remove('status');
      final entry = SessionEntry.fromRelayTask(raw);
      expect(entry.phase, 'idle');
    });

    test('new-row fields do not break the entry (no pinned/unreadAt)', () {
      final entry = SessionEntry.fromRelayTask(newRow());
      expect(entry.sessionId, 't1');
      expect(entry.raw['pinned'], isNull);
      expect(entry.raw['unreadAt'], isNull);
      expect(entry.lastErrorTraceId, isNull);
    });

    test('relay `archived` bit survives into the entry raw', () {
      // The archived leg tags rows on merge (device_session) and the
      // action sheet reads `entry.raw['archived']`; the whitelist rebuild
      // must carry it — a dropped bit offers 「归档」 on an archived row.
      final archived = SessionEntry.fromRelayTask({
        ...newRow(),
        'archived': true,
      });
      expect(archived.raw['archived'], isTrue);

      // Timeline/pinned rows carry no bit → null (not archived).
      final timeline = SessionEntry.fromRelayTask(newRow());
      expect(timeline.raw['archived'], isNull);
    });
  });

  group('TaskDirectory with 3.16.2 rows', () {
    test('displayStatusWinner reads `status`; taskDisplayStatus equivalent',
        () {
      expect(
        TaskDirectory.displayStatusWinner([newRow(status: 'completed')], 't1'),
        'completed',
      );
      expect(
        TaskDirectory.displayStatusWinner([newRow(status: 'running')], 't1'),
        'running',
      );
    });

    test('merged row synthesizes the status field for the phase pill', () {
      final directory = TaskDirectory(relayTasks: [newRow(status: 'running')]);
      final rows = directory.allEntries();
      expect(rows.single.$1.phase, 'running');
      expect(rows.single.$2, '/repo',
          reason: 'identity missing -> path is the key');
    });

    test('injected identity outranks the path as the workspace key', () {
      final directory = TaskDirectory(
        relayTasks: [
          newRow(status: 'completed', workspaceIdentity: 'repo-id'),
        ],
      );
      expect(directory.allEntries().single.$2, 'repo-id');
    });

    test('pinned flag drives pinnedEntries (merged from listPinnedTaskIds)',
        () {
      final pinnedDirectory = TaskDirectory(
        relayTasks: [newRow(pinned: true)],
      );
      expect(pinnedDirectory.pinnedEntries().single.$1.sessionId, 't1');

      final unpinnedDirectory = TaskDirectory(
        relayTasks: [newRow(pinned: false)],
      );
      expect(unpinnedDirectory.pinnedEntries(), isEmpty);

      final missingDirectory = TaskDirectory(relayTasks: [newRow()]);
      expect(missingDirectory.pinnedEntries(), isEmpty,
          reason: 'absent pinned is not pinned (pre-merge)');
    });

    test('a null status winner erases the home copy status (P2-7)', () {
      // The newer copy has no status at all; the older copy says 'running'.
      // The M1 winner is the newer (status-less) copy, so the synthesized
      // row must stay status-less — the dual-read fallback would otherwise
      // resurrect the home copy's `status`.
      final staleRunning =
          newRow(status: 'running', updatedAt: 10, pinned: true);
      final freshNoStatus =
          newRow(updatedAt: 100, pinned: true)..remove('status');
      final rows = [staleRunning, freshNoStatus];

      expect(TaskDirectory.displayStatusWinner(rows, 't1'), isNull,
          reason: 'the newer, status-less copy wins the display-status pick');

      final merged = TaskDirectory(relayTasks: rows).allEntries().single.$1;
      expect(merged.phase, 'idle',
          reason: 'a null winner must not fall back to the other copy status');
      expect(merged.raw.containsKey('status'), isFalse);
      expect(merged.raw['displayStatus'], isNull);

      // `pinnedEntries` runs the same synthesis — lock it there too.
      final pinned =
          TaskDirectory(relayTasks: rows).pinnedEntries().single.$1;
      expect(pinned.phase, 'idle');
      expect(pinned.raw.containsKey('status'), isFalse);
    });

    test('archived authority: absent archived means live row', () {
      final directory = TaskDirectory(relayTasks: [newRow()]);
      expect(directory.allEntries(), hasLength(1));
    });
  });
}
