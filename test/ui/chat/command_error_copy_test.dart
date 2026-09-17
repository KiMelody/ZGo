import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/ui/chat/chat_page.dart';

void main() {
  // Callers pass `'$e'` (the raw error text), exactly like the snack-bar
  // injection points do.
  test('StateError / not connected maps to the reconnect copy', () {
    expect(
      commandErrorCopy('${StateError('not connected')}', 'zh-CN'),
      '连接已断开，请返回重连后再试',
    );
    expect(
      commandErrorCopy('${StateError('socket closed')}', 'zh-CN'),
      '连接已断开，请返回重连后再试',
      reason: 'any Bad state: shape is a StateError',
    );
    expect(
      commandErrorCopy('Bridge not connected', 'zh-CN'),
      '连接已断开，请返回重连后再试',
      reason: 'matching is case-insensitive on the raw text',
    );
  });

  test('TimeoutException / timed out maps to the timeout copy', () {
    expect(
      commandErrorCopy(
          '${TimeoutException('idle', Duration(seconds: 45))}', 'zh-CN'),
      '连接超时，请检查网络或桌面端后重试',
    );
    // ChannelRpcError probes answer `Channel name '…' timed out after …`.
    expect(
      commandErrorCopy(
          "ChannelRpcError: Channel name 'task' timed out after 1000ms",
          'zh-CN'),
      '连接超时，请检查网络或桌面端后重试',
    );
  });

  test('en locale renders en copy and never falls back to Chinese', () {
    final notConnected =
        commandErrorCopy('${StateError('not connected')}', 'en-US');
    expect(notConnected, isNotNull);
    expect(
      RegExp(r'[\u4e00-\u9fff]').hasMatch(notConnected!),
      isFalse,
      reason: 'leaked zh copy: $notConnected',
    );
    final timeout = commandErrorCopy(
        '${TimeoutException("Channel name 'x' timed out")}', 'en-US');
    expect(timeout, isNotNull);
    expect(
      RegExp(r'[\u4e00-\u9fff]').hasMatch(timeout!),
      isFalse,
      reason: 'leaked zh copy: $timeout',
    );
  });

  test('not connected wins over timeout when both shapes appear', () {
    expect(
      commandErrorCopy('Bad state: not connected (request timed out)', 'zh-CN'),
      '连接已断开，请返回重连后再试',
    );
  });

  test('unmatched errors return null so the raw text is shown', () {
    expect(commandErrorCopy('connection reset by peer', 'zh-CN'), isNull);
    expect(
        commandErrorCopy(
            'remote workspace is not in the current window', 'zh-CN'),
        isNull);
  });
}
