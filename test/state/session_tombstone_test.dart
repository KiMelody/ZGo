import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/connection_params.dart';

import '../helpers/fake_device_session.dart';

/// Cross-terminal deletion tombstones (task 10-06 chat tombstone): session
/// ids that vanish from the live sessions-index while the subscription is
/// held are recorded by [DeviceSession.recordVanishedSessions] (wired in
/// the fake exactly like production `_onSessionsChanged`) and surface
/// through `isSessionDeleted`. The chat page drops its own id on dispose
/// (`forgetDeletedSession`).
void main() {
  final params = RemoteConnectionParams.parse(
    'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1'
    '&name=songsong&app_version=3.14.0',
  )!;

  Map<String, dynamic> liveRow(String id) =>
      {'sessionId': id, 'title': 'live-$id', 'phase': 'idle'};

  /// A fresh snapshot frame replacing the index contents wholesale.
  Map<String, dynamic> snapshot(List<Map<String, dynamic>> entries) => {
        'toSeq': 2,
        'payload': {
          'kind': 'snapshot',
          'snapshot': {'workspaceId': 'ws-1', 'sessions': entries},
        },
      };

  Map<String, dynamic> removedDelta(String id) => {
        'fromSeq': 1,
        'toSeq': 2,
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {'op': 'session.removed', 'sessionId': id},
          ],
        },
      };

  test('a snapshot without a previously held id records the tombstone', () {
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: params,
      entries: [liveRow('s1'), liveRow('s2')],
    );
    expect(session.isSessionDeleted('s1'), isFalse);

    session.sessions.applyFrame(snapshot([liveRow('s2')]), onGap: () {});

    expect(session.isSessionDeleted('s1'), isTrue);
    expect(session.isSessionDeleted('s2'), isFalse);
  });

  test('a session.removed delta records the tombstone', () {
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: params,
      entries: [liveRow('s1'), liveRow('s2')],
    );

    session.sessions.applyFrame(removedDelta('s1'), onGap: () {});

    expect(session.isSessionDeleted('s1'), isTrue);
    expect(session.isSessionDeleted('s2'), isFalse);
  });

  test('frames without vanishings record nothing (negative case)', () {
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: params,
      entries: [liveRow('s1')],
    );

    // An upsert frame with the same id set, then the same snapshot again.
    session.sessions.applyFrame(
      {
        'fromSeq': 1,
        'toSeq': 2,
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {
              'op': 'session.upserted',
              'session': {
                'sessionId': 's1',
                'title': 'renamed',
                'phase': 'idle',
              },
            },
          ],
        },
      },
      onGap: () {},
    );
    session.sessions.applyFrame(snapshot([liveRow('s1')]), onGap: () {});

    expect(session.isSessionDeleted('s1'), isFalse);
  });

  test('a fresh baseline does not mass-record: the first frame after a new '
      'subscription only establishes the diff base', () {
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: params,
      entries: [liveRow('s1'), liveRow('s2'), liveRow('s3')],
    );

    // Production resets the baseline on every workspace open (new
    // subscription): simulate by driving the frames a fresh subscription
    // would deliver — a full listing first, deletions only count from the
    // NEXT frame on. Here: empty seeding is the fresh-base shape.
    final fresh = FakeDeviceSession(
      deviceId: 'd1',
      params: params,
      entries: const [],
    );
    // First frame of the fresh subscription: a full listing without ids
    // the fake was seeded with — nothing held, nothing recorded.
    fresh.sessions.applyFrame(snapshot([liveRow('s2')]), onGap: () {});
    expect(fresh.isSessionDeleted('s1'), isFalse);
    expect(fresh.isSessionDeleted('s2'), isFalse);

    // Only the SECOND frame (ids vanish relative to a held baseline)
    // records.
    fresh.sessions.applyFrame(snapshot(const []), onGap: () {});
    expect(fresh.isSessionDeleted('s2'), isTrue);

    expect(session.isSessionDeleted('s3'), isFalse);
  });

  test('a frame under a different workspace key never records (second '
      'line of defense for the openWorkspace baseline reset)', () {
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: params,
      entries: [liveRow('s1')],
    );
    // Seeded frame established the baseline under the (null) key.
    expect(session.isSessionDeleted('s1'), isFalse);

    // Production resets the baseline on every openWorkspace, so a frame
    // from a different workspace normally arrives with a fresh baseline.
    // If it ever did not, the key check must refuse the cross-workspace
    // diff: ws-2's listing lacking ws-1's s1 is NOT a deletion.
    session.sessions.subscribedWorkspaceKey = 'ws-2';
    session.sessions.applyFrame(snapshot(const []), onGap: () {});

    expect(session.isSessionDeleted('s1'), isFalse);

    // The re-keyed baseline is now live: a later same-key frame diffs
    // against ws-2's (empty) ids, still nothing.
    session.sessions.applyFrame(snapshot(const []), onGap: () {});
    expect(session.isSessionDeleted('s1'), isFalse);
  });

  test('forgetDeletedSession drops the id (page-dispose recovery)', () {
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: params,
      entries: [liveRow('s1'), liveRow('s2')],
    );
    session.sessions.applyFrame(snapshot([liveRow('s2')]), onGap: () {});
    expect(session.isSessionDeleted('s1'), isTrue);

    session.forgetDeletedSession('s1');

    expect(session.isSessionDeleted('s1'), isFalse);
    // Other tombstones are untouched.
    session.sessions.applyFrame(snapshot(const []), onGap: () {});
    expect(session.isSessionDeleted('s2'), isTrue);
  });
}
