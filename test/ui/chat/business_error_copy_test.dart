import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/ui/chat/chat_page.dart';

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
}
