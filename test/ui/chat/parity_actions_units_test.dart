import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/ui/chat/chat_page.dart';
import 'package:zgo/ui/chat/timeline.dart';

/// Pure-function units of the 10-08 parity chat-actions batch:
/// attachmentErrorCopy (D6), hookRunStatus (D4), anchoredInteractionPlan
/// (D9). No widgets — direct table/predicate assertions.
void main() {
  // ---- D6: server media-budget size rejections ----
  group('attachmentErrorCopy', () {
    test('MEDIA_BUDGET_* code names map to the oversize copy', () {
      const expected = '附件不能超过 30 MB';
      expect(
        attachmentErrorCopy(
          'ChannelRpcError: MEDIA_BUDGET_CURRENT_ATTACHMENT_TOO_LARGE',
          'zh-CN',
        ),
        expected,
      );
      expect(
        attachmentErrorCopy(
          'rpc failed (MEDIA_BUDGET_CURRENT_IMAGE_TOO_LARGE)',
          'zh-CN',
        ),
        expected,
      );
      expect(
        attachmentErrorCopy(
          'MEDIA_BUDGET_CURRENT_VIDEO_TOO_LARGE',
          'en-US',
        ),
        'Attachments must be 30 MB or smaller',
      );
    });

    test('other errors stay null (raw passthrough)', () {
      expect(
        attachmentErrorCopy('ChannelRpcError: Method not found', 'zh-CN'),
        isNull,
      );
      expect(attachmentErrorCopy('TimeoutException after 30s', 'en-US'), isNull);
    });
  });

  // ---- D4: hook execution status projection ----
  group('hookRunStatus', () {
    test('outcome wins when present (official chat.hooks.state.* merge)', () {
      expect(
        hookRunStatus({'state': 'completed', 'outcome': 'success'}),
        'completed',
      );
      expect(
        hookRunStatus({'state': 'completed', 'outcome': 'blocked'}),
        'blocked',
      );
      expect(
        hookRunStatus({'state': 'failed', 'outcome': 'timed_out'}),
        'timedOut',
      );
      expect(
        hookRunStatus({'state': 'failed', 'outcome': 'cancelled'}),
        'cancelled',
      );
      expect(hookRunStatus({'state': 'failed'}), 'failed');
    });

    test('running rows carry no outcome yet', () {
      expect(hookRunStatus({'state': 'running'}), 'running');
      expect(hookRunStatus({}), '');
    });
  });

  // ---- D9: anchorRowId anchor plan ----
  group('anchoredInteractionPlan', () {
    // Two turn groups (the shape _groupRows produces; the grouper itself is
    // covered by assistant_turn_parts_test).
    final groups = [
      [
        {'rowId': 1, 'kind': 'userInput', 'text': 'q1'},
        {'rowId': 2, 'kind': 'assistantText', 'text': 'a1'},
      ],
      [
        {'rowId': 3, 'kind': 'userInput', 'text': 'q2'},
        {'rowId': 4, 'kind': 'assistantText', 'text': 'a2'},
      ],
    ];

    test('anchor inside the window → byGroup hit + id excluded from bottom',
        () {
      final interaction = {
        'interactionId': 'perm_1',
        'anchorRowId': 3,
        'payload': <String, dynamic>{},
      };
      final plan = anchoredInteractionPlan(groups, [interaction]);

      expect(plan.anchoredIds, {'perm_1'});
      expect(plan.byGroup[1], [interaction]); // row 3 lives in group 1
      expect(plan.byGroup.containsKey(0), isFalse);
    });

    test('no anchor / anchor outside the window → not in the plan', () {
      final plan = anchoredInteractionPlan(groups, [
        {'interactionId': 'perm_none', 'payload': const {}},
        {'interactionId': 'perm_far', 'anchorRowId': 999, 'payload': const {}},
        {'anchorRowId': 2, 'payload': const {}}, // no id — ignored entirely
      ]);

      expect(plan.anchoredIds, isEmpty);
      expect(plan.byGroup, isEmpty);
    });

    test('same-anchor interactions order by interactionId', () {
      final plan = anchoredInteractionPlan(groups, [
        {'interactionId': 'perm_b', 'anchorRowId': 1, 'payload': const {}},
        {'interactionId': 'perm_a', 'anchorRowId': 1, 'payload': const {}},
      ]);

      expect(
        (plan.byGroup[0]!.map((i) => i['interactionId'])).toList(),
        ['perm_a', 'perm_b'],
      );
      expect(plan.anchoredIds, {'perm_a', 'perm_b'});
    });
  });
}
