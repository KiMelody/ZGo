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

  group('cold-runtime copy (10-28 C)', () {
    test('both locales carry the actionable runtime copy verbatim', () {
      expect(
        zhTable['tasks.agentRuntimeNotRunning'],
        '该工作区的智能体运行时未启动。请在桌面端打开该工作区（或其中任一任务）'
        '以启动运行时，然后重试。',
      );
      expect(
        enTable['tasks.agentRuntimeNotRunning'],
        'The agent runtime for this workspace is not running. Open this '
        'workspace (or any task in it) on the desktop to start it, then '
        'retry.',
      );
    });
  });

  group('usage primary-left copy (10-25)', () {
    test('the template carries no percent sign — the argument already has one',
        () {
      // The call site passes `_fmtPct` (e.g. '94.9%'); a '%' in the template
      // renders '剩 94.9%%' (the acceptance report's double-percent bug).
      expect(zhTable['usageRpc.primaryLeft'], '剩 \$0');
      expect(enTable['usageRpc.primaryLeft'], '\$0 left');
    });
  });

  group('Start-plan quota copy (10-24 C)', () {
    test('the auto-switch toast and the expiry banner are bilingual', () {
      expect(zhTable['chat.quota.autoSwitched'], 'Start 套餐已不可用，已切换到 \$0');
      expect(
        enTable['chat.quota.autoSwitched'],
        'Start plan is no longer available — switched to \$0',
      );
      expect(zhTable['chat.quota.expiredTitle'], '套餐已到期');
      expect(enTable['chat.quota.expiredTitle'], 'Plan expired');
      expect(zhTable['chat.quota.expiredBody'], '当前套餐已到期，可切换模型继续');
      expect(
        enTable['chat.quota.expiredBody'],
        'Your current plan has expired — switch model to continue',
      );
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
  group('archive permanent-delete copy (11-11, official asar surface)', () {
    test('the checking / deleteItem / incomplete keys carry the official values verbatim', () {
      expect(zhTable['tasks.archive.checking'], '正在检查 \$0/\$1 个会话…');
      expect(enTable['tasks.archive.checking'], 'Checking sessions: \$0/\$1…');
      expect(
        zhTable['tasks.archive.deleteItem'],
        '“\$0”：对话、\$1 个所属子会话、输入历史与索引、\$2 个私有附件或执行记录文件',
      );
      expect(
        enTable['tasks.archive.deleteItem'],
        '“\$0”: conversation, \$1 owned child sessions, input history and '
        'indexes, \$2 private attachment or execution record files',
      );
      expect(
        zhTable['tasks.archive.incomplete'],
        '删除尚未确认完成，请重试；已删除的内容无法恢复。',
      );
      expect(
        enTable['tasks.archive.incomplete'],
        'Deletion has not been confirmed complete. Retry; removed content '
        'cannot be restored.',
      );
    });

    // The dynamic reason family is built as 'tasks.archive.reason.$key' in
    // the UI (i18n_key_guard skips interpolated keys) — lock all six here.
    test('the six reason values are bilingual and non-empty', () {
      for (final r in const [
        'running',
        'in-use',
        'not-found',
        'not-archived',
        'changed',
        'unavailable',
      ]) {
        final key = 'tasks.archive.reason.$r';
        expect(zhTable[key]?.trim(), isNotEmpty, reason: 'zh $key');
        expect(enTable[key]?.trim(), isNotEmpty, reason: 'en $key');
      }
      // Facet spot checks against the official asar copy.
      expect(
        zhTable['tasks.archive.reason.running'],
        '任务仍在运行或有待处理输入，请先停止任务并处理队列。',
      );
      expect(
        enTable['tasks.archive.reason.unavailable'],
        'Cannot safely inspect or delete: the host is unavailable, its '
        'version is unsupported, or reading failed. Resolve the issue and retry.',
      );
    });
  });
}
