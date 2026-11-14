import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/conversation_quote.dart';

/// Selection quote model + official limits + capability-gate helpers (task
/// 11-13-quote-comment-lite). Shapes and limits mirror the runtime validator
/// (zcode.cjs @749223); gate semantics are PRD R4: version gate primary,
/// probe verdict negative-only.
void main() {
  group('ConversationQuote.toWire', () {
    test('required text only omits every empty optional', () {
      const quote = ConversationQuote(text: '选中的一段');
      expect(quote.toWire(), {'text': '选中的一段'});
    });

    test('maps every official field 1:1', () {
      const quote = ConversationQuote(
        text: '选中的一段',
        comment: '我的批注',
        path: 'lib/main.dart',
        senderName: 'Melody',
        senderId: 'u1',
        messageId: 'm1',
        sentAt: 1760000000000,
        agent: 'general-purpose',
      );
      expect(quote.toWire(), {
        'text': '选中的一段',
        'comment': '我的批注',
        'path': 'lib/main.dart',
        'senderName': 'Melody',
        'senderId': 'u1',
        'messageId': 'm1',
        'sentAt': 1760000000000,
        'agent': 'general-purpose',
      });
    });

    test('empty optional strings are omitted (no noise on the wire)', () {
      const quote = ConversationQuote(
        text: 'x',
        comment: '',
        path: '',
        senderName: '',
        senderId: '',
        messageId: '',
        agent: '',
      );
      expect(quote.toWire(), {'text': 'x'});
    });
  });

  group('conversationQuoteLimitErrorKey (four runtime limits)', () {
    List<ConversationQuote> quotesOf(int count, {int textLength = 10}) => [
          for (var i = 0; i < count; i++)
            ConversationQuote(text: 'x' * textLength),
        ];

    test('8 quotes fit; 9 answer the count key', () {
      expect(conversationQuoteLimitErrorKey(quotesOf(8)), isNull);
      expect(
        conversationQuoteLimitErrorKey(quotesOf(9)),
        'chat.selections.limit.count',
      );
    });

    test('8,000 chars fit; 8,001 answer the single key', () {
      expect(
        conversationQuoteLimitErrorKey([
          ConversationQuote(text: 'x' * ConversationQuoteLimits.maxTextLength),
        ]),
        isNull,
      );
      expect(
        conversationQuoteLimitErrorKey([
          ConversationQuote(
            text: 'x' * (ConversationQuoteLimits.maxTextLength + 1),
          ),
        ]),
        'chat.selections.limit.single',
      );
    });

    test('16,000 total chars fit; 16,001 answer the total key', () {
      expect(
        conversationQuoteLimitErrorKey(quotesOf(2, textLength: 8000)),
        isNull,
      );
      expect(
        conversationQuoteLimitErrorKey([
          ...quotesOf(2, textLength: 8000),
          const ConversationQuote(text: 'x'),
        ]),
        'chat.selections.limit.total',
      );
    });

    test('2,000-char comment fits; 2,001 answer the comment key', () {
      expect(
        conversationQuoteLimitErrorKey([
          ConversationQuote(
            text: 'x',
            comment: 'c' * ConversationQuoteLimits.maxCommentLength,
          ),
        ]),
        isNull,
      );
      expect(
        conversationQuoteLimitErrorKey([
          ConversationQuote(
            text: 'x',
            comment: 'c' * (ConversationQuoteLimits.maxCommentLength + 1),
          ),
        ]),
        'chat.selections.limit.comment',
      );
    });

    test('agent names cap at 200 (runtime schema, no ZGo UI path)', () {
      expect(
        conversationQuoteLimitErrorKey([
          ConversationQuote(text: 'x', agent: 'a' * 200),
        ]),
        isNull,
      );
      expect(
        conversationQuoteLimitErrorKey([
          ConversationQuote(text: 'x', agent: 'a' * 201),
        ]),
        'chat.selections.limit.agent',
      );
    });
  });

  group('parseQuoteSupportVerdict', () {
    test('plain booleans pass through', () {
      expect(parseQuoteSupportVerdict(true), isTrue);
      expect(parseQuoteSupportVerdict(false), isFalse);
    });

    test('map shapes are tolerated', () {
      expect(parseQuoteSupportVerdict({'supported': true}), isTrue);
      expect(parseQuoteSupportVerdict({'enabled': false}), isFalse);
      expect(parseQuoteSupportVerdict({'available': true}), isTrue);
    });

    test('anything else is unknown (never a negative verdict)', () {
      expect(parseQuoteSupportVerdict(null), isNull);
      expect(parseQuoteSupportVerdict('true'), isNull);
      expect(parseQuoteSupportVerdict(1), isNull);
      expect(parseQuoteSupportVerdict(<String, dynamic>{}), isNull);
      expect(
        parseQuoteSupportVerdict({'supported': 'yes'}),
        isNull,
      );
    });
  });

  group('conversationQuoteProbeArgs (live-captured wire shape)', () {
    test('no workspace path answers null (never probe without scope)', () {
      expect(conversationQuoteProbeArgs(null), isNull);
      expect(conversationQuoteProbeArgs(<String, dynamic>{}), isNull);
      expect(
        conversationQuoteProbeArgs({'workspacePath': ''}),
        isNull,
      );
    });

    test('path-only scope is one map element (live 3.18.2 shape)', () {
      expect(
        conversationQuoteProbeArgs({'workspacePath': '/repo'}),
        [
          {'workspacePath': '/repo'},
        ],
      );
    });

    test('identity rides along when present', () {
      expect(
        conversationQuoteProbeArgs({
          'workspacePath': '/repo',
          'workspaceIdentity': 'id-1',
        }),
        [
          {'workspacePath': '/repo', 'workspaceIdentity': 'id-1'},
        ],
      );
    });
  });

  group('selectionQuoteEntryAllowed (PRD R4 three states)', () {
    test('version gate closed hides the entry regardless of the probe', () {
      for (final verdict in <bool?>[null, true, false]) {
        expect(
          selectionQuoteEntryAllowed(versionOk: false, probeVerdict: verdict),
          isFalse,
        );
      }
    });

    test('version open + unknown verdict stays visible', () {
      expect(
        selectionQuoteEntryAllowed(versionOk: true, probeVerdict: null),
        isTrue,
      );
    });

    test('version open + true stays visible', () {
      expect(
        selectionQuoteEntryAllowed(versionOk: true, probeVerdict: true),
        isTrue,
      );
    });

    test('version open + explicit false hides (negative evidence only)', () {
      expect(
        selectionQuoteEntryAllowed(versionOk: true, probeVerdict: false),
        isFalse,
      );
    });
  });
}
