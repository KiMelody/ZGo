import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/ui/chat/chat_page.dart';

void main() {
  // Codes carried in the raw provider failure text, in the order the web
  // `zcode.error.providerBusiness.*` table lists them.
  const zhCopy = {
    '1006': '登录状态已失效，请重新登录后再试。',
    '1005': '免费额度已用完，请升级套餐或稍后再试。',
    '3006': '当前模型不在你的套餐范围内，请更换模型。',
    '3001': '请求参数无效，请重试或更换模型。',
    '3007': '触发验证码校验，请在桌面端完成验证后重试。',
    '3008': '系统繁忙，请稍后重试或升级套餐。',
    '3009': '系统繁忙，请稍后重试或升级套餐。',
    '3010': '系统繁忙，请稍后重试或升级套餐。',
    '3002': '请求被限流，请稍后重试。',
    '2007': '上游服务暂不可用，请稍后重试。',
    '429': '请求被限流，请稍后重试。',
  };

  test('zh locale keeps the previous official copy verbatim', () {
    for (final entry in zhCopy.entries) {
      expect(
        businessErrorCopy('provider error ${entry.key} (rpc)', 'zh-CN'),
        '${entry.value} (稍后重试)',
        reason: 'code ${entry.key}',
      );
    }
  });

  test('en locale renders en copy and never falls back to Chinese', () {
    for (final code in zhCopy.keys) {
      final copy = businessErrorCopy('provider error $code (rpc)', 'en-US');
      expect(copy, isNotNull, reason: 'code $code');
      expect(copy, endsWith('(Retry later)'), reason: 'code $code');
      expect(
        RegExp(r'[\u4e00-\u9fff]').hasMatch(copy!),
        isFalse,
        reason: 'code $code leaked zh copy: $copy',
      );
    }
  });

  test('codes sharing one sentence share one key', () {
    String? copy(String code) => businessErrorCopy('e$code', 'zh-CN');
    expect(copy('3008'), copy('3010'));
    expect(copy('3002'), copy('429'));
  });

  test('unmatched errors return null so the raw text is shown', () {
    expect(businessErrorCopy('connection reset by peer', 'zh-CN'), isNull);
    expect(businessErrorCopy('code 4290', 'en-US'), isNull);
  });

  // ---- D7 (F4 forensics): the 32xx family stays UNMAPPED ----
  //
  // The provider-code union is [3001,3002,3200,3201,3203..3215] (runtime
  // @875474) but the official i18n table carries NO 32xx entries — those
  // codes travel with the server's own msg and the official client passes
  // it through. Negative lock: no invented copy, today and on refactors.
  test('32xx provider codes have no official copy → raw passthrough', () {
    for (final code in [
      '3200', '3201', '3203', '3208', '3210', '3215',
    ]) {
      expect(
        businessErrorCopy('provider business error $code: 服务端原始消息', 'zh-CN'),
        isNull,
        reason: 'code $code must not invent copy',
      );
    }
  });

  // ---- C1 (10-05 D5/D1): task-mutation mappings ----
  //
  // Checked before the numeric provider codes (a taskId can carry digits
  // that would false-match the \b-code regex); the markers come from
  // channel_client's string-level predicates, one source with the
  // error-level forms.
  group('task mutation mappings', () {
    test('registry resolve failure maps to the unregistered-draft copy', () {
      // Live desktop shape (research-emulator.md A-1).
      expect(
        businessErrorCopy(
          '操作失败: ChannelRpcError: 列表 mutation 无法解析唯一 source, '
              'taskId=fork1',
          'zh-CN',
        ),
        '该会话尚未在桌面任务目录登记（草稿），发送首条消息后即可管理',
      );
      expect(
        businessErrorCopy(
          'ChannelRpcError: 列表 mutation 无法解析唯一 source (matches=0)',
          'en-US',
        ),
        "This session isn't registered in the desktop task directory yet "
            '(draft) — send the first message to manage it',
      );
    });

    test('session-busy refusal maps to the retry-later copy', () {
      // Live desktop wording (research-emulator.md「busy 之谜」, four hits).
      expect(
        businessErrorCopy(
          '操作失败: ChannelRpcError: 会话正在进行中，稍后再试',
          'zh-CN',
        ),
        '会话正在处理中，请稍后重试',
      );
      expect(
        businessErrorCopy('ChannelRpcError: 会话正在进行中，稍后再试', 'en-US'),
        'The session is busy right now — please try again shortly',
      );
    });

    test('mapped en copy never leaks Chinese', () {
      for (final raw in [
        'ChannelRpcError: 列表 mutation 无法解析唯一 source, taskId=fork1',
        'ChannelRpcError: 会话正在进行中，稍后再试',
      ]) {
        final copy = businessErrorCopy(raw, 'en-US');
        expect(copy, isNotNull, reason: raw);
        expect(
          RegExp(r'[\u4e00-\u9fff]').hasMatch(copy!),
          isFalse,
          reason: 'leaked zh copy for $raw: $copy',
        );
      }
    });

    test('unrelated ChannelRpcError still returns null', () {
      expect(
        businessErrorCopy('操作失败: ChannelRpcError: Method not found', 'zh-CN'),
        isNull,
      );
      expect(
        businessErrorCopy(
          '操作失败: ChannelRpcError: 会话不存在',
          'zh-CN',
        ),
        isNull,
      );
    });
  });
}
