import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/connection_params.dart';
import 'package:zgo/protocol/window_controller.dart';
import 'package:zgo/state/task_directory.dart';

import '../helpers/fake_device_session.dart';

/// State-layer wiring of the three-phase archived delete (design 11-11 §2-§3):
/// lazy degrade verdict, per-task preview (no data-level dedup), tombstones
/// only for `status == "deleted"`.
void main() {
  final params = RemoteConnectionParams.parse(
    'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1'
    '&name=songsong&app_version=3.18.0',
  )!;

  Map<String, dynamic> archivedRow(String id) => {
    'taskId': id,
    'title': '归档 $id',
    'workspacePath': '/repo/app',
    'workspaceIdentity': 'app-id',
    'displayStatus': 'idle',
    'archived': true,
  };

  FakeDeviceSession sessionWith(
    Future<dynamic> Function(String channel, String method, List<Object?> args)
    handler, {
    List<Map<String, dynamic>> relayTasks = const [],
  }) =>
      FakeDeviceSession(
        deviceId: 'd1',
        params: params,
        relayTasks: relayTasks,
        workspaces: [
          {'workspacePath': '/repo/app', 'workspaceIdentity': 'app-id'},
        ],
        channelHandler: handler,
      );

  const previewAnswer = {
    'sessionId': 'a1',
    'revision': 'rev-7',
    'sessionIds': ['a1', 'a1-fork'],
    'forks': <Object?>[],
    'retainedArtifacts': <Object?>[],
    'deletedFiles': 2,
    'incomplete': false,
    'completed': true,
  };

  test('unknown-method on the first call pins the degrade verdict; every '
      'later call short-circuits without a wire round', () async {
    final calls = <(String, String)>[];
    final session = sessionWith((channel, method, args) async {
      calls.add((channel, method));
      throw ChannelRpcError('Method not found: $method', null);
    });

    expect(session.windowControllerAvailable, isTrue);
    await expectLater(
      session.previewArchiveDeletion('a1'),
      throwsA(isA<ArchivalPreviewUnavailable>()),
    );
    expect(session.windowControllerAvailable, isFalse);
    expect(calls, hasLength(1));

    // Short-circuit: no second wire call, same degrade signal.
    await expectLater(
      session.previewArchiveDeletion('a1'),
      throwsA(isA<ArchivalPreviewUnavailable>()),
    );
    await expectLater(
      session.executeArchiveDeletion(
        const ArchivalDeletionPreview(
          revision: 'r',
          sessionIds: ['a1'],
          blockedReason: null,
          incomplete: false,
          deletedFiles: 0,
        ),
        'a1',
      ),
      throwsA(isA<ArchivalPreviewUnavailable>()),
    );
    expect(calls, hasLength(1), reason: 'boolean short-circuit, no dedup');
  });

  test('preview called for two different tasks is NEVER deduplicated: one '
      'wire call each and each answer keeps its own revision', () async {
    // Design §2 P1-1 red line: a shared in-flight future would hand task A's
    // revision to task B's execute.
    var n = 0;
    final revisions = <String>[];
    final session = sessionWith((channel, method, args) async {
      final address = ((args.single as Map)['address'] as Map)
          .cast<String, dynamic>();
      n++;
      final revision = 'rev-${address['taskId']}';
      revisions.add(revision);
      return {
        ...previewAnswer,
        'sessionId': address['taskId'],
        'revision': revision,
        'sessionIds': [address['taskId']],
      };
    });

    final results = await Future.wait([
      session.previewArchiveDeletion('a1'),
      session.previewArchiveDeletion('b2'),
    ]);
    expect(n, 2);
    expect(revisions, ['rev-a1', 'rev-b2']);
    expect(results.map((p) => p.revision), ['rev-a1', 'rev-b2']);
    expect(results.map((p) => p.sessionIds.single), ['a1', 'b2']);
  });

  test('execute: only status=deleted tombstones — every reported session id '
      '(fork cascade included) — and notifies once', () async {
    final deletes = <Map<String, dynamic>>[];
    final session = sessionWith(
      (channel, method, args) async {
        deletes.add((args.single as Map).cast<String, dynamic>());
        return {
          'sessionId': 'a1',
          'status': 'deleted',
          'sessionIds': ['a1', 'a1-fork', 'a1-fork-2'],
          'retainedArtifacts': 0,
        };
      },
      relayTasks: [archivedRow('a1')],
    );

    var notified = 0;
    session.addListener(() => notified++);
    final res = await session.executeArchiveDeletion(
      ArchivalDeletionPreview.fromMap(previewAnswer),
      'a1',
    );

    expect(res.status, 'deleted');
    expect(deletes.single['revision'], 'rev-7');
    expect(deletes.single['operationId'], isA<String>());
    expect((deletes.single['operationId'] as String), isNotEmpty);
    // The persisted tombstone (what rememberLocalDelete writes and the
    // merged directory filters on) covers the whole cascade.
    expect(
      session.taskHome.store.locallyDeletedTaskIds,
      containsAll(['a1', 'a1-fork', 'a1-fork-2']),
    );
    expect(notified, 1);
    // The merged directory drops the rows immediately — the 30 s overview
    // poll cannot resurrect them.
    expect(
      TaskDirectory(
        relayTasks: session.relayTasks,
        locallyDeletedTaskIds: session.taskHome.store.locallyDeletedTaskIds,
      ).allEntries().where((r) => r.$1.sessionId == 'a1'),
      isEmpty,
    );
  });

  test('execute: blocked / incomplete answers tombstone NOTHING and leave '
      'the rows in the merged directory', () async {
    for (final status in ['blocked', 'incomplete']) {
      final session = sessionWith(
        (channel, method, args) async => {
          'sessionId': 'a1',
          'status': status,
          'sessionIds': ['a1', 'a1-fork'],
          'retainedArtifacts': 1,
          'reason': 'whatever',
        },
        relayTasks: [archivedRow('a1')],
      );

      final res = await session.executeArchiveDeletion(
        ArchivalDeletionPreview.fromMap(previewAnswer),
        'a1',
      );
      expect(res.status, status);
      expect(
        session.taskHome.store.locallyDeletedTaskIds,
        isEmpty,
        reason: 'no tombstone for $status',
      );
      expect(
        TaskDirectory.bestRelayRow(session.relayTasks, 'a1'),
        isNotNull,
        reason: 'still listed ($status)',
      );
    }
  });

  test('execute: an unknown-method reply mid-flow flips the verdict AND '
      'surfaces the degrade signal', () async {
    final session = sessionWith(
      (channel, method, args) async {
        if (method == 'previewArchivedTaskDeletion') return previewAnswer;
        throw ChannelRpcError('Method not found: $method', null);
      },
    );
    final preview = await session.previewArchiveDeletion('a1');
    expect(session.windowControllerAvailable, isTrue);

    await expectLater(
      session.executeArchiveDeletion(preview, 'a1'),
      throwsA(isA<ArchivalPreviewUnavailable>()),
    );
    expect(session.windowControllerAvailable, isFalse);
  });

  test('non unknown-method failures do NOT pin the verdict — network / '
      'validation / session-data.unavailable stay retryable', () async {
    var calls = 0;
    final session = sessionWith((channel, method, args) async {
      calls++;
      throw ChannelRpcError('session-data.unavailable', null);
    });

    await expectLater(
      session.previewArchiveDeletion('a1'),
      throwsA(
        isA<ChannelRpcError>().having(
          (e) => e.message,
          'message',
          contains('session-data.unavailable'),
        ),
      ),
    );
    expect(session.windowControllerAvailable, isTrue);
    expect(
      isArchiveDeletionUnavailableError(
        ChannelRpcError('session-data.unavailable', null),
      ),
      isTrue,
      reason: 'UI maps this to the archives.reason.unavailable toast',
    );

    // Next trigger hits the wire again (nothing cached).
    await expectLater(
      session.previewArchiveDeletion('a1'),
      throwsA(isA<ChannelRpcError>()),
    );
    expect(calls, 2);

    // A bare "not found" wording is NOT the tightened unknown-method shape.
    final bare = sessionWith(
      (channel, method, args) async =>
          throw ChannelRpcError('not found: previewArchivedTaskDeletion', null),
    );
    await expectLater(
      bare.previewArchiveDeletion('a1'),
      throwsA(isA<ChannelRpcError>()),
    );
    expect(bare.windowControllerAvailable, isTrue);
  });
}