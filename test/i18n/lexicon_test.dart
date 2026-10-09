import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/i18n/lexicon.dart';

void main() {
  group('table parity', () {
    test('zh and en share the exact same key set', () {
      final zh = zhTable.keys.toSet();
      final en = enTable.keys.toSet();
      expect(
        en.difference(zh),
        isEmpty,
        reason: 'keys missing from the zh table',
      );
      expect(
        zh.difference(en),
        isEmpty,
        reason: 'keys missing from the en table',
      );
      expect(zhTable.length, enTable.length);
    });

    test('no table value is empty', () {
      for (final entry in {...zhTable, ...enTable}.entries) {
        expect(
          entry.value.trim(),
          isNotEmpty,
          reason: '${entry.key} has an empty value',
        );
      }
    });
  });

  group('off-peak official key family (D5)', () {
    test('the 11 official keys carry the desktop values verbatim', () {
      const zh = {
        'offPeak.badge.queuePosition': '排队第 \$0 位',
        'offPeak.badge.pausedPosition': '#\$0 已暂停',
        'offPeak.status.queued': '等待闲时算力',
        'offPeak.status.completed': '已完成',
        'offPeak.chatCreated.defaultTitle': '闲时任务',
        'offPeak.chatCreated.queued': '已加入闲时队列',
        'offPeak.chatCreated.queuedAt': '排队第 \$0 位',
        'offPeak.chatCreated.open': '去到闲时任务',
        'offPeak.chatCreated.boundHint': '将在本会话中运行',
        'offPeak.boundSession.label': '运行会话：\$0',
        'offPeak.boundSession.hint': '任务将在该会话中执行；执行期间停止会话会取消任务。',
      };
      const en = {
        'offPeak.badge.queuePosition': '#\$0 in queue',
        'offPeak.badge.pausedPosition': '#\$0 Paused',
        'offPeak.status.queued': 'Waiting for idle compute',
        'offPeak.status.completed': 'Succeeded',
        'offPeak.chatCreated.defaultTitle': 'Idle-time task',
        'offPeak.chatCreated.queued': 'Queued for idle-time compute',
        'offPeak.chatCreated.queuedAt': '#\$0 in queue',
        'offPeak.chatCreated.open': 'Go to idle-time tasks',
        'offPeak.chatCreated.boundHint': 'Runs in this session',
        'offPeak.boundSession.label': 'Runs in: \$0',
        'offPeak.boundSession.hint':
            'Runs in that session; stopping the session while the task runs cancels it.',
      };
      for (final entry in zh.entries) {
        expect(zhTable[entry.key], entry.value, reason: 'zh ${entry.key}');
      }
      for (final entry in en.entries) {
        expect(enTable[entry.key], entry.value, reason: 'en ${entry.key}');
      }
    });

    test('the three English drifts follow the official wording (D1)', () {
      expect(enTable['op.queue'], '#\$0 in queue');
      expect(enTable['op.status.queued'], 'Waiting for idle compute');
      expect(enTable['op.status.completed'], 'Succeeded');
    });
  });
}
