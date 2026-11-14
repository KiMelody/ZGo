/// Composer-side recognition of the builtin side-chat aliases `/side` and
/// `/btw` (task 11-11-btw-side-chat R1/R2, design §5/D7).
///
/// The aliases are a client-side builtin: the desktop's `prepareWorkspace`
/// never lists them, and a matched submission must never reach any
/// conversation — `_send` consumes it into the side-chat creation flow
/// instead. The rules live here as pure logic so the regex matrix and the
/// guard order are unit-tested without pumping a page; `chat_page` keeps the
/// effects (toast / clear / create hook).
library;

/// One parsed alias submission.
class SideChatCommand {
  /// First message handed to `createSelectionSideSession`; null when the
  /// alias carried no argument (create and open an empty side chat).
  final String? firstInput;

  const SideChatCommand._(this.firstInput);

  /// `^\/(side|btw)(?:\s+([\s\S]*))?$` — case-insensitive (design §5). The
  /// `[\s\S]` class spans newlines, so a multi-line argument stays one first
  /// message.
  static final RegExp pattern = RegExp(
    r'^\/(side|btw)(?:\s+([\s\S]*))?$',
    caseSensitive: false,
  );

  /// Parses [text]; null when it is not an alias submission (the caller
  /// sends it normally). A blank argument collapses to no argument: `/btw`
  /// and `/btw   ` both create an empty side chat.
  static SideChatCommand? parse(String text) {
    final match = pattern.firstMatch(text);
    if (match == null) return null;
    final input = (match.group(2) ?? '').trim();
    return SideChatCommand._(input.isEmpty ? null : input);
  }
}

/// What `_send` does with an alias submission (design §5 guard matrix).
enum SideChatVerdict {
  /// Not an alias, or a side chat's own composer: send normally. A side chat
  /// must not nest (R5) — leg 2 of the protection, next to the hidden popup
  /// entry.
  passThrough,

  /// A creation is already in flight: swallow a double submit silently
  /// (the first toast/hand-off is still on screen).
  creating,

  /// A draft has no parent session to attach the side chat to. Toast the
  /// first-message guard instead of dead-ending on an empty parent id.
  draft,

  /// Attachments have no side-chat create payload. Refuse loudly — the
  /// plain send path would silently ship them along with the literal slash
  /// text.
  attachments,

  /// Consume the composer into the create flow.
  create,
}

/// The guard matrix for [text], in evaluation order (R2/R5, design §5):
/// side-chat pass-through, then busy debounce, then draft, then attachments.
///
/// `creating` sits ahead of the state guards so a double submit during the
/// create RPC cannot stack a second toast.
SideChatVerdict sideChatVerdict({
  required String text,
  required bool sideChat,
  required bool draft,
  required bool hasAttachments,
  required bool creating,
}) {
  if (sideChat || SideChatCommand.parse(text) == null) {
    return SideChatVerdict.passThrough;
  }
  if (creating) return SideChatVerdict.creating;
  if (draft) return SideChatVerdict.draft;
  if (hasAttachments) return SideChatVerdict.attachments;
  return SideChatVerdict.create;
}
