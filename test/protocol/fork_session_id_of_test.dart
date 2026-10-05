import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/conversation.dart';

/// Matrix for [forkSessionIdOf] (task 10-05-fork-session-lifecycle Step 1):
/// the forkAssistant ack union is `{status, result:{type, sessionId}}` and
/// both `accepted` and `duplicate` carry the result (`duplicate` = the
/// server's commandId dedupe replaying the original result, same as
/// createSession) — evidence: asar command ack union + fork bundle ack
/// part, task research.md R1. Every other wire shape must answer null, not
/// throw — the ack is dynamic data (defensive read chain, no casts).
void main() {
  Map<String, dynamic> ack({
    String status = 'accepted',
    Object? result = const {
      'type': 'forkAssistant',
      'sessionId': 'sess_new',
    },
  }) =>
      {'status': status, if (result != null) 'result': result};

  group('recognized shapes', () {
    test('accepted carries the new sessionId', () {
      expect(forkSessionIdOf(ack()), 'sess_new');
    });

    test('duplicate (retryAck replay) carries the original result too', () {
      expect(
        forkSessionIdOf(ack(status: 'duplicate')),
        'sess_new',
        reason: 'the dedupe replay must navigate to the same session',
      );
    });
  });

  group('everything else answers null', () {
    test('non-pass statuses answer null', () {
      for (final status in ['rejected', 'stale', 'noop', '', 'ACCEPTED']) {
        expect(
          forkSessionIdOf(ack(status: status)),
          isNull,
          reason: 'status = $status',
        );
      }
    });

    test('missing / non-Map result answers null', () {
      expect(forkSessionIdOf(ack(result: null)), isNull);
      expect(forkSessionIdOf(ack(result: 'garbage')), isNull);
    });

    test('a non-forkAssistant result type answers null', () {
      // E.g. the createSession ack shares the result envelope.
      expect(
        forkSessionIdOf(ack(result: {
          'type': 'createSession',
          'sessionId': 'sess_new',
        })),
        isNull,
      );
    });

    test('sessionId must be a non-empty String', () {
      expect(
        forkSessionIdOf(ack(result: {'type': 'forkAssistant'})),
        isNull,
      );
      expect(
        forkSessionIdOf(ack(result: {
          'type': 'forkAssistant',
          'sessionId': 42,
        })),
        isNull,
      );
      expect(
        forkSessionIdOf(ack(result: {
          'type': 'forkAssistant',
          'sessionId': '',
        })),
        isNull,
      );
    });

    test('non-Map acks answer null without throwing', () {
      for (final res in [null, 'garbage', 42, <String, dynamic>{}]) {
        expect(forkSessionIdOf(res), isNull, reason: 'res = $res');
      }
    });
  });
}
