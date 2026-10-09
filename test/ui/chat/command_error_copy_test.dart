import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/ui/chat/chat_page.dart';

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

  test('side-chat guard reasonCode maps to friendly copy, and wins over the '
      'Bad state: wrapper', () {
    // The protocol throws V4SelectionSideChatRestrictedCommandError for the
    // LKa command set inside a selection_side_chat; the thrown StateError
    // wraps the reasonCode in `Bad state: …`, which would otherwise take the
    // not-connected branch.
    expect(
      commandErrorCopy('guard.selectionSideChatRestrictedCommand', 'zh-CN'),
      '辅助对话中不支持此操作',
    );
    expect(
      commandErrorCopy(
          'Bad state: retryTurn rejected: '
          'guard.selectionSideChatRestrictedCommand '
          'selection_side_chat 不允许执行 retryTurn',
          'zh-CN'),
      '辅助对话中不支持此操作',
      reason: 'the guard branch must precede the bad-state branch',
    );
    expect(
      commandErrorCopy('guard.selectionSideChatRestrictedCommand', 'en-US'),
      "This action isn't available in a side conversation",
    );
    // Unrelated reasonCodes still pass through untouched.
    expect(commandErrorCopy('model_locked', 'zh-CN'), isNull);
  });
}
