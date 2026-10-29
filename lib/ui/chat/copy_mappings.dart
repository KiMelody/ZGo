/// Wire marker → display copy mappings shared by the chat page, the
/// timeline, the Git panel and the goal panel (task
/// 10-29-copy-mappings-extract): the four copy functions and [localeOf]
/// moved out verbatim so the leaf consumers no longer import the whole chat
/// page. Pure relocation, zero behavior change.
///
/// ADR-0012: every line comes from the lexicon tables — no new keys, no CJK
/// literals. Data layers keep keys/original text; only this presentation
/// layer translates.
library;

import 'package:flutter/material.dart';

import '../../i18n/lexicon.dart';
import '../../protocol/channel_client.dart';
import '../../protocol/conversation.dart';
import '../ui_settings.dart';
import 'tool_row_semantics.dart';

/// Locale for the pure copy lookups (tool_row_semantics) at sites that
/// hold a BuildContext but render through the module, not `tr`.
String localeOf(BuildContext context) =>
    UiSettingsProvider.of(context)?.locale ?? 'zh-CN';

/// Provider business-error translation (web `zcode.error.providerBusiness.*`):
/// model-request failures carry a numeric code (1005 免费额度, 1006 登录失效,
/// 3002/429 限流, 3006 模型不在范围, 3007 验证码, 3008-3010 系统繁忙, 2007 服务端
/// 不可用). When the failure text mentions one, show the known line
/// instead of the raw transport error.
///
/// The 32xx family (3200-3215 minus 3202 — the provider-code union, runtime
/// @875474) is deliberately NOT mapped: the official i18n carries NO 32xx
/// copy (F4 forensics), those codes travel with the server's own `msg` and
/// the official client passes it through — inventing copy would drift from
/// the vendor wording (design D7's own fallback rule). Locked by the
/// negative assertion in chat_page_test.
///
/// Task-mutation shapes are checked first (C1 10-05 D5/D1): a registry
/// resolve failure means the session row is a registry-external draft
/// (tasks.error.unregistered), and the session-busy refusal means the
/// desktop declined a session-scoped command mid-turn
/// (tasks.error.sessionBusy). Both ride the string-level predicates in
/// channel_client so predicate and copy share one marker source.
///
/// Takes a locale (not a BuildContext) so it stays a pure function; the
/// `chat.bizErr.*` table entries supply the copy.
String? businessErrorCopy(String errorText, String locale) {
  if (isTaskResolveFailureText(errorText)) {
    return trLocale(locale, 'tasks.error.unregistered');
  }
  if (isSessionBusyErrorText(errorText)) {
    return trLocale(locale, 'tasks.error.sessionBusy');
  }
  final m = RegExp(r'\b(1006|1005|3006|3001|3007|3008|3009|3010|3002|2007|429)\b')
      .firstMatch(errorText);
  if (m == null) return null;
  final key = {
    '1006': 'chat.bizErr.loginExpired',
    '1005': 'chat.bizErr.quotaExhausted',
    '3006': 'chat.bizErr.modelNotInPlan',
    '3001': 'chat.bizErr.invalidParams',
    '3007': 'chat.bizErr.verificationRequired',
    '3008': 'chat.bizErr.serviceBusy',
    '3009': 'chat.bizErr.serviceBusy',
    '3010': 'chat.bizErr.serviceBusy',
    '3002': 'chat.bizErr.rateLimited',
    '2007': 'chat.bizErr.upstreamUnavailable',
    '429': 'chat.bizErr.rateLimited',
  }[m.group(1)];
  if (key == null) return null;
  final retryLater = trLocale(locale, 'common.retryLater');
  return '${trLocale(locale, key)} ($retryLater)';
}

/// Plain-language rewrite for command errors surfaced in snack bars: with
/// the link down / the bridge dead, commands throw
/// `StateError('not connected')` (toString: `Bad state: …`) or
/// `TimeoutException`, and the desktop answers with its raw
/// workspace-reconnect line — `'$e'` in a SnackBar reads like crash
/// output (PRD internal-task R3). Returns the mapped copy, or
/// null for unknown shapes so callers keep the raw text (logged via
/// debugPrint at each call site). Takes a locale (not a BuildContext) so
/// it stays a pure function, like [businessErrorCopy].
String? commandErrorCopy(String errorText, String locale) {
  final t = errorText.toLowerCase();
  // The protocol's side-chat command guard (`V4SelectionSideChatRestricted
  // CommandError`, reasonCode `guard.selectionSideChatRestrictedCommand`)
  // rejects the LKa command set (retry/fork/goal/…) inside a
  // `selection_side_chat` — checked FIRST: the thrown shape wraps the code
  // in `Bad state: …`, which would otherwise win the not-connected branch.
  if (t.contains('guard.selectionsidechatrestrictedcommand')) {
    return trLocale(locale, 'chat.selectionSideChat.restricted');
  }
  if (t.contains('bad state:') || t.contains('not connected')) {
    return trLocale(locale, 'chat.error.notConnected');
  }
  if (t.contains('timeoutexception') || t.contains('timed out')) {
    return trLocale(locale, 'chat.error.timeout');
  }
  return null;
}

/// Server-side attachment size rejections (D6, F5): the desktop's media
/// budget answers carry the `MEDIA_BUDGET_CURRENT_{ATTACHMENT,IMAGE,VIDEO}_
/// TOO_LARGE` code names in the error text — map them onto the same oversize
/// copy as the client precheck. Null for anything else (raw passthrough).
/// Pure like [businessErrorCopy]: takes a locale, not a BuildContext.
String? attachmentErrorCopy(String errorText, String locale) {
  final t = errorText.toUpperCase();
  const codes = [
    'MEDIA_BUDGET_CURRENT_ATTACHMENT_TOO_LARGE',
    'MEDIA_BUDGET_CURRENT_IMAGE_TOO_LARGE',
    'MEDIA_BUDGET_CURRENT_VIDEO_TOO_LARGE',
  ];
  if (codes.any(t.contains)) {
    return trByKeyP(locale, 'chat.attach.tooLarge', ['30']);
  }
  return null;
}

/// Live action text of a running subagent: the child session's LAST
/// toolCall — `inputStreaming` with empty input → 「准备执行…」, otherwise
/// the shared per-tool summary (已写入 x / 终端 · cmd / …, live-probed row
/// shapes 2026-09-16). null when the child snapshot hasn't landed or has no
/// toolCall yet — callers fall back to the title / parent-side summaryText.
String? subagentActionText(BuildContext context, ConversationState? child) {
  if (child == null || !child.ready) return null;
  for (final row in child.rows.reversed) {
    if (row['kind'] != 'toolCall') continue;
    if ('${row['status'] ?? ''}' == 'inputStreaming' &&
        '${row['inputText'] ?? ''}'.isEmpty) {
      return tr(context, 'chat.subagent.preparing');
    }
    return toolRowSemantics(row, locale: localeOf(context)).title;
  }
  return null;
}
