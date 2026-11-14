import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/window_controller.dart';

void main() {
  const previewAnswer = {
    'sessionId': 'a1',
    'revision': 'rev-7',
    'sessionIds': ['a1', 'a1-fork', 'a1-fork-2'],
    'forks': [
      {'sessionId': 'a1-fork', 'title': 'fork'},
    ],
    'retainedArtifacts': [
      {
        'sessionId': 'a1-fork',
        'artifactId': 'file-1',
        'fileName': 'notes.md',
        'referrers': <Object?>[],
      },
    ],
    'deletedFiles': 4,
    'blockedReason': 'running',
    'incomplete': true,
    'completed': false,
  };

  test('preview: parses the official answer; forks/retainedArtifacts are '
      'ignored, deletedFiles is kept for the deleteItem copy', () async {
    final calls = <(String, String, List<Object?>)>[];
    final port = WindowControllerPort(
      (channel, method, args) async {
        calls.add((channel, method, args));
        return previewAnswer;
      },
      scope: (_) => {'workspacePath': '/repo/app', 'workspaceIdentity': 'app-id'},
    );

    final preview = await port.previewArchivedDeletion('a1');
    expect(calls.single.$1, 'window-controller');
    expect(calls.single.$2, 'previewArchivedTaskDeletion');
    expect(preview.revision, 'rev-7');
    expect(preview.sessionIds, ['a1', 'a1-fork', 'a1-fork-2']);
    expect(preview.blockedReason, 'running');
    expect(preview.incomplete, isTrue);
    expect(preview.deletedFiles, 4);
  });

  test('preview: strict address payload is exactly address{workspacePath, '
      'workspaceIdentity, taskId} — extra keys are rejected desktop-side, '
      'so the port must never send them', () async {
    final calls = <(String, List<Object?>)>[];
    final port = WindowControllerPort(
      (channel, method, args) async {
        calls.add((method, args));
        return previewAnswer;
      },
      scope: (_) => {'workspacePath': '/repo/app', 'workspaceIdentity': 'app-id'},
    );

    await port.previewArchivedDeletion('a1');
    final payload = (calls.single.$2.single as Map).cast<String, Object?>();
    expect(payload.keys.toSet(), {'address'});
    final address = (payload['address'] as Map).cast<String, Object?>();
    expect(address, {
      'workspacePath': '/repo/app',
      'workspaceIdentity': 'app-id',
      'taskId': 'a1',
    });
    expect(address.keys.toSet(), {'workspacePath', 'workspaceIdentity', 'taskId'});
    for (final forbidden in const [
      'sourceServerId',
      'remoteSessionId',
      'sessionId',
      'taskIds',
    ]) {
      expect(address.containsKey(forbidden), isFalse,
          reason: 'strict address rejects $forbidden');
    }
  });

  test('preview: scope identity is omitted (not null-filled) when the '
      'owning workspace has none', () async {
    Map? seen;
    final port = WindowControllerPort(
      (channel, method, args) async {
        seen = (args.single as Map).cast<String, Object?>();
        return previewAnswer;
      },
      scope: (_) => {'workspacePath': '/repo/app', 'workspaceIdentity': null},
    );
    await port.previewArchivedDeletion('a1');
    expect((seen!['address'] as Map).cast<String, Object?>(), {
      'workspacePath': '/repo/app',
      'taskId': 'a1',
    });
  });

  test('preview: tolerant parse — missing deletedFiles defaults to 0 and '
      'unknown fields do not throw', () async {
    final port = WindowControllerPort(
      (channel, method, args) async => const {
        'revision': 'rev-1',
        'sessionIds': ['a1'],
        'incomplete': false,
        'completed': true,
        'someFutureField': {'nested': true},
      },
    );
    final preview = await port.previewArchivedDeletion('a1');
    expect(preview.deletedFiles, 0);
    expect(preview.blockedReason, isNull);
    expect(preview.sessionIds, ['a1']);
  });

  test('execute: strict payload is address + revision + operationId', () async {
    final calls = <(String, List<Object?>)>[];
    final port = WindowControllerPort(
      (channel, method, args) async {
        calls.add((method, args));
        return const {
          'sessionId': 'a1',
          'status': 'deleted',
          'sessionIds': ['a1', 'a1-fork'],
          'retainedArtifacts': 0,
        };
      },
      scope: (_) => {'workspacePath': '/repo/app', 'workspaceIdentity': 'app-id'},
    );

    final res = await port.permanentlyDeleteArchived(
      'a1',
      revision: 'rev-7',
      operationId: 'op-1',
    );
    expect(calls.single.$1, 'permanentlyDeleteArchivedTask');
    final payload = (calls.single.$2.single as Map).cast<String, Object?>();
    expect(payload.keys.toSet(), {'address', 'revision', 'operationId'});
    expect(payload['revision'], 'rev-7');
    expect(payload['operationId'], 'op-1');
    expect((payload['address'] as Map).cast<String, Object?>(), {
      'workspacePath': '/repo/app',
      'workspaceIdentity': 'app-id',
      'taskId': 'a1',
    });
    expect(res.status, 'deleted');
    expect(res.sessionIds, ['a1', 'a1-fork']);
    expect(res.reason, isNull);
  });

  test('execute: blocked / incomplete answers parse with their free-form '
      'reason; a missing reason stays null', () async {
    final blocked = WindowControllerPort(
      (channel, method, args) async => const {
        'sessionId': 'a1',
        'status': 'blocked',
        'sessionIds': ['a1'],
        'retainedArtifacts': 0,
        'reason': 'not-archived',
      },
    );
    final blockedRes = await blocked.permanentlyDeleteArchived(
      'a1',
      revision: 'r',
      operationId: 'o',
    );
    expect(blockedRes.status, 'blocked');
    expect(blockedRes.reason, 'not-archived');
    expect(blockedRes.sessionIds, ['a1']);

    final incomplete = WindowControllerPort(
      (channel, method, args) async => const {
        'sessionId': 'a1',
        'status': 'incomplete',
        'sessionIds': <String>[],
        'retainedArtifacts': 1,
        'reason': 'disk busy',
      },
    );
    final incompleteRes = await incomplete.permanentlyDeleteArchived(
      'a1',
      revision: 'r',
      operationId: 'o',
    );
    expect(incompleteRes.status, 'incomplete');
    expect(incompleteRes.reason, 'disk busy');

    expect(
      ArchivalDeletionResult.fromMap(const {
        'status': 'blocked',
        'sessionIds': <String>[],
      }).reason,
      isNull,
    );
  });

  test('unknown method → ArchivalPreviewUnavailable on BOTH calls; the '
      'tightened verdict requires the exact desktop wording', () async {
    final failing = WindowControllerPort(
      (channel, method, args) async =>
          throw ChannelRpcError('Method not found: $method', null),
    );
    await expectLater(
      failing.previewArchivedDeletion('a1'),
      throwsA(isA<ArchivalPreviewUnavailable>()),
    );
    await expectLater(
      failing.permanentlyDeleteArchived('a1', revision: 'r', operationId: 'o'),
      throwsA(isA<ArchivalPreviewUnavailable>()),
    );

    bool missing(String message) => isArchivalDeletionMethodMissing(
        ChannelRpcError(message, null),
      );
    expect(missing('Method not found: previewArchivedTaskDeletion'), isTrue);
    expect(missing('Method not found: permanentlyDeleteArchivedTask'), isTrue);
    // relay/wrapper prefixes are tolerated
    expect(missing('Error invoking remote method: Method not found: '
        'previewArchivedTaskDeletion'), isTrue);
  });

  test('bare "not found" / validation / session-data.unavailable do NOT '
      'degrade — they surface as their own errors', () async {
    final bareNotFound = WindowControllerPort(
      (channel, method, args) async =>
          throw ChannelRpcError('not found: previewArchivedTaskDeletion', null),
    );
    await expectLater(
      bareNotFound.previewArchivedDeletion('a1'),
      throwsA(isA<ChannelRpcError>()),
    );

    final unavailable = WindowControllerPort(
      (channel, method, args) async =>
          throw ChannelRpcError('session-data.unavailable', null),
    );
    await expectLater(
      unavailable.previewArchivedDeletion('a1'),
      throwsA(isA<ChannelRpcError>()),
    );
    await expectLater(
      unavailable.permanentlyDeleteArchived('a1', revision: 'r',
          operationId: 'o'),
      throwsA(isA<ChannelRpcError>()),
    );
    expect(
      isArchiveDeletionUnavailableError(
        ChannelRpcError('session-data.unavailable', null),
      ),
      isTrue,
    );
  });
}