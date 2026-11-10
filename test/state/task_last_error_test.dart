import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zgo/protocol/connection_params.dart';

import '../helpers/fake_device_session.dart';

/// `TaskMetaPort.taskLastError` (task 11-08-error-detail): the chat error
/// preview / detail sheet's ONLY data path. The value must be the merged
/// directory's的选择 — the row the task list shows — not a raw relay scan:
/// a live sessions-index overlay rebuilds the row's raw and drops the relay
/// origin fields, and `TaskDirectory._withRelayMeta` is what carries
/// `lastError` back in (check P1-1). A relay-only read would show the error
/// exactly for the rows nothing else covers and miss every live-covered
/// task — the active one included.
void main() {
  final params = RemoteConnectionParams.parse(
    'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1'
    '&name=songsong&app_version=3.14.0',
  )!;

  Map<String, dynamic> relayTask(
    String id, {
    String workspacePath = '/repo/a',
    Map<String, dynamic>? lastError,
  }) =>
      {
        'taskId': id,
        'title': 'relay-$id',
        'workspacePath': workspacePath,
        'displayStatus': 'error',
        'createdAt': 1,
        'updatedAt': 1,
        if (lastError != null) 'lastError': lastError,
      };

  Map<String, dynamic> liveRow(String id) =>
      {'sessionId': id, 'title': 'live-$id', 'phase': 'running'};

  FakeDeviceSession sessionWith(
    List<Map<String, dynamic>> relayTasks, {
    List<Map<String, dynamic>> workspaces = const [],
  }) =>
      FakeDeviceSession(
        deviceId: 'd1',
        params: params,
        relayTasks: relayTasks,
        workspaces: workspaces,
      );

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a complete relay meta answers all four fields', () {
    final session = sessionWith([
      relayTask('t1', lastError: {
        'message': '429 Rate limit exceeded',
        'code': '429',
        'traceId': 'trc_9f2k',
        'attribution': 'provider',
        'taskId': 't1',
      }),
    ]);

    expect(session.taskLastError('t1'), {
      // `taskId` is not part of the surfaced view — the sheet already knows
      // which task it was opened for.
      'message': '429 Rate limit exceeded',
      'code': '429',
      'traceId': 'trc_9f2k',
      'attribution': 'provider',
    });
  });

  test('missing optional fields are omitted, not null-valued', () {
    final session = sessionWith([
      relayTask('t1', lastError: {'message': 'boom'}),
    ]);

    final error = session.taskLastError('t1');
    expect(error, {'message': 'boom'});
    expect(error!.containsKey('code'), isFalse, reason: 'AC5: the sheet '
        'gates a block on key presence — a null value would render an empty '
        'row');
    expect(error.containsKey('traceId'), isFalse);
    expect(error.containsKey('attribution'), isFalse);
  });

  test('a row without lastError answers null; an unknown id answers null', () {
    final session = sessionWith([relayTask('t1'), relayTask('t2')]);

    expect(session.taskLastError('t1'), isNull);
    expect(session.taskLastError('nope'), isNull);
  });

  test('a lastError carrying no usable field answers null, not an empty map',
      () {
    // `{code: null}` / `{}` are shape-drifted payloads — nothing to show, so
    // the caller must behave exactly as if the row had no error at all.
    for (final meta in [
      const <String, dynamic>{},
      const {'code': null, 'traceId': '   '},
    ]) {
      final session = sessionWith([relayTask('t1', lastError: meta)]);
      expect(session.taskLastError('t1'), isNull, reason: 'meta=$meta');
    }
  });

  test('the live overlay inherits the relay lastError (_withRelayMeta)', () {
    // The active workspace's live index covers t1: the merged row is built
    // from the LIVE frame, whose schema carries no lastError. Only the
    // relay-meta inheritance keeps the error reachable — this is the branch
    // the relay-only alternative would have missed for every live task.
    final session = sessionWith(
      [
        relayTask('t1', lastError: {'message': 'boom', 'traceId': 'tr-1'}),
      ],
      workspaces: [
        {'workspacePath': '/repo/a', 'workspaceIdentity': 'alpha'},
      ],
    );
    session.deliver({
      'toSeq': 2,
      'payload': {
        'kind': 'snapshot',
        'snapshot': {
          'workspaceId': 'ws-1',
          'sessions': [liveRow('t1')],
        },
      },
    });

    final row = session.taskDirectory.allEntries().single.$1;
    expect(row.phase, 'running', reason: 'the live frame owns the body');
    expect(session.taskLastError('t1'), {
      'message': 'boom',
      'traceId': 'tr-1',
    });
  });

  test('a live-provided lastError wins over the relay copy', () {
    // Gap-filling only: the overlay's own value is authoritative when it
    // has one (same precedence as pinned/unreadAt in _withRelayMeta).
    final session = sessionWith(
      [
        relayTask('t1', lastError: {'message': 'relay-boom'}),
      ],
      workspaces: [
        {'workspacePath': '/repo/a', 'workspaceIdentity': 'alpha'},
      ],
    );
    session.deliver({
      'toSeq': 2,
      'payload': {
        'kind': 'snapshot',
        'snapshot': {
          'workspaceId': 'ws-1',
          'sessions': [
            {
              ...liveRow('t1'),
              'lastError': {'message': 'live-boom', 'code': 'live-code'},
            },
          ],
        },
      },
    });

    expect(session.taskLastError('t1'), {
      'message': 'live-boom',
      'code': 'live-code',
    });
  });

  test('anchor-riding body carries the anchored copy lastError', () {
    // Multi-copy registry pollution: the body fields ride the anchored home
    // copy, so the error detail must follow the visible row rather than the
    // cold pick's copy.
    final session = sessionWith([
      relayTask('t1', workspacePath: '/repo/a'),
      {
        ...relayTask('t1', workspacePath: '/repo/b'),
        'lastError': {'message': 'home-copy-boom'},
      },
    ]);
    session.taskHomeStore.anchorHome('t1', '/repo/b');

    expect(session.taskDirectory.allEntries().single.$2, '/repo/b');
    expect(session.taskLastError('t1'), {'message': 'home-copy-boom'});
  });
}