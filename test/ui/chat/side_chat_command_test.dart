import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/ui/chat/side_chat_command.dart';

/// Step C2 unit matrix (R2/R5, design §5/D7): the alias regex and the guard
/// order are pure, so every branch is pinned here; the page-level wiring
/// (toasts, no send, no create) lives in chat_page_test.dart.
void main() {
  group('SideChatCommand.parse — alias regex', () {
    test('empty argument: both aliases create without a first message', () {
      expect(SideChatCommand.parse('/side')?.firstInput, isNull);
      expect(SideChatCommand.parse('/btw')?.firstInput, isNull);
    });

    test('an argument becomes the first message verbatim', () {
      expect(SideChatCommand.parse('/side 你好')?.firstInput, '你好');
      expect(SideChatCommand.parse('/btw 解释这个函数')?.firstInput, '解释这个函数');
    });

    test('case-insensitive: /SIDE and /Btw hit', () {
      expect(SideChatCommand.parse('/SIDE')?.firstInput, isNull);
      expect(SideChatCommand.parse('/Btw Hello')?.firstInput, 'Hello');
      expect(SideChatCommand.parse('/SiDe  x')?.firstInput, 'x');
    });

    test('multi-line arguments stay one first message', () {
      expect(
        SideChatCommand.parse('/btw 第一行\n第二行')?.firstInput,
        '第一行\n第二行',
      );
    });

    test('spacing around the argument collapses (trim), inner spaces stay', () {
      expect(
        SideChatCommand.parse('/side   spaced  arg ')?.firstInput,
        'spaced  arg',
      );
      // A trailing-space alias (what picking the popup item inserts) is the
      // empty form, not an empty-string first message.
      expect(SideChatCommand.parse('/side ')?.firstInput, isNull);
    });

    test('non-aliases do not match', () {
      for (final text in [
        '/sidex',
        '/side1',
        '/btwww',
        '/side-chat',
        '/side: hi',
        '/si', // popup prefix hit only — sending it is not an alias command
        '/bt',
        '//side',
        'le /side hi',
        'hello',
        '',
      ]) {
        expect(
          SideChatCommand.parse(text),
          isNull,
          reason: '"$text" must send normally',
        );
      }
    });

    test('a non-alias that merely starts like one stays a normal message', () {
      expect(SideChatCommand.parse('/sidex 你好'), isNull);
      expect(SideChatCommand.parse('/side1 2'), isNull);
      expect(SideChatCommand.parse('/bt.html'), isNull);
    });
  });

  group('sideChatVerdict — guard order (design §5)', () {
    SideChatVerdict verdict(
      String text, {
      bool sideChat = false,
      bool draft = false,
      bool hasAttachments = false,
      bool creating = false,
    }) =>
        sideChatVerdict(
          text: text,
          sideChat: sideChat,
          draft: draft,
          hasAttachments: hasAttachments,
          creating: creating,
        );

    test('ordinary text and non-aliases pass through', () {
      expect(verdict('继续'), SideChatVerdict.passThrough);
      expect(verdict('/sidex 你好'), SideChatVerdict.passThrough);
      expect(verdict('/compact'), SideChatVerdict.passThrough);
    });

    test('a side chat never intercepts — /side there is a normal message', () {
      expect(
        verdict('/side hi', sideChat: true),
        SideChatVerdict.passThrough,
      );
      expect(
        verdict('/btw hi', sideChat: true, draft: false, hasAttachments: true),
        SideChatVerdict.passThrough,
      );
    });

    test('draft: toast the first-message guard', () {
      expect(verdict('/side hi', draft: true), SideChatVerdict.draft);
      expect(verdict('/btw', draft: true), SideChatVerdict.draft);
    });

    test('attachments: refuse loudly', () {
      expect(
        verdict('/btw hi', hasAttachments: true),
        SideChatVerdict.attachments,
      );
    });

    test('creating: busy debounce wins over the state guards', () {
      expect(verdict('/side hi', creating: true), SideChatVerdict.creating);
      expect(
        verdict('/btw hi', draft: true, creating: true),
        SideChatVerdict.creating,
      );
      expect(
        verdict('/btw hi', hasAttachments: true, creating: true),
        SideChatVerdict.creating,
      );
    });

    test('a ready existing session creates', () {
      expect(verdict('/side hi'), SideChatVerdict.create);
      expect(verdict('/btw'), SideChatVerdict.create);
    });
  });
}
