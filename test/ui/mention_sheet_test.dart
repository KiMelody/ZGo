import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/ui/chat/mention_sheet.dart';

import '../helpers/recording_chat_gateway.dart';

void main() {
  group('insert formats (official renderer, verbatim)', () {
    test('files → [名称](./路径) with ./ prefix and directory slash', () {
      expect(
        mentionFileMarkdown(
          name: 'a.dart',
          relativePath: 'lib/a.dart',
          isDirectory: false,
        ),
        '[a.dart](./lib/a.dart)',
      );
      expect(
        mentionFileMarkdown(
          name: 'sub',
          relativePath: 'lib/sub',
          isDirectory: true,
        ),
        '[sub](./lib/sub/)',
      );
      // Already-relative / absolute paths keep their prefix.
      expect(
        mentionFileMarkdown(
          name: 'x',
          relativePath: './x',
          isDirectory: false,
        ),
        '[x](./x)',
      );
      // `\ [ ]` in the display name are escaped.
      expect(
        mentionFileMarkdown(
          name: r'a[b]',
          relativePath: 'a[b].dart',
          isDirectory: false,
        ),
        r'[a\[b\]](./a[b].dart)',
      );
    });

    test('sessions/skills/subagents use their bare tokens', () {
      expect(mentionSessionToken('sess_abc'), '#sess_abc');
      expect(mentionSkillToken('review'), r'$review');
      expect(mentionSubagentToken('explore'), '@explore');
    });
  });

  test('applyMentionInsert replaces the @ trigger and appends a space', () {
    // triggerEnd is the CURSOR offset (just after the typed @); the trigger
    // character itself is consumed — the official formats carry their own
    // sigil (`#`/`$`/`@`) or none (markdown link).
    expect(applyMentionInsert('看一下 @', 5, '[a.dart](./lib/a.dart)'),
        '看一下 [a.dart](./lib/a.dart) ');
    expect(applyMentionInsert('a @', 3, r'$review'), r'a $review ');
    expect(applyMentionInsert('@', 1, '@explore'), '@explore ');
    expect(applyMentionInsert('x\n@', 3, '#sess_1'), 'x\n#sess_1 ');
  });

  testWidgets('files category lists workspace files and returns the pick',
      (tester) async {
    final gateway = RecordingChatGateway()
      ..searchWorkspaceFilesResult = [
        {
          'name': 'chat_page.dart',
          'relativePath': 'lib/ui/chat/chat_page.dart',
          'type': 'file',
        },
      ];
    MentionEntry? picked;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: Builder(
            builder: (buttonCtx) => FilledButton(
              onPressed: () async {
                picked = await showMentionSheet(buttonCtx, gateway);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    // fixed pumps: the sheet's autofocus caret never settles
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }

    expect(find.text('文件'), findsOneWidget);
    await tester.tap(find.text('文件'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }

    expect(find.byType(TextField), findsOneWidget,
        reason: 'entered the files category');
    expect(find.text('chat_page.dart'), findsOneWidget);
    await tester.tap(find.text('chat_page.dart'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }

    expect(picked?.insert, '[chat_page.dart](./lib/ui/chat/chat_page.dart)');
  });

  testWidgets('add-context panel: 添加/文件/会话 sections, no plugins section',
      (tester) async {
    final gateway = RecordingChatGateway()
      ..mentionSessionsResult = const [(id: 'sess_1', title: 'Hello')];
    AddContextResult? result;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: Builder(
            builder: (buttonCtx) => FilledButton(
              onPressed: () async {
                result = await showAddContextSheet(
                  buttonCtx,
                  gateway: gateway,
                  isDraft: true,
                  workflowCommand: 'workflow',
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }

    // 添加 section: 附件 + 目标 (draft) + 工作流.
    // 添加上下文 shows twice: sheet title (actionMenu) + `@` footer chip.
    expect(find.text('添加上下文'), findsNWidgets(2));
    expect(find.text('附件'), findsOneWidget);
    expect(find.text('目标'), findsOneWidget);
    expect(find.text('工作流'), findsOneWidget);
    // Files section appears after the positive reachability probe.
    expect(find.widgetWithText(ListTile, '文件'), findsOneWidget);
    expect(find.widgetWithText(ListTile, '会话'), findsOneWidget);
    // 插件 has no ZGo channel → whole section (and its key) is absent.
    expect(find.text('插件'), findsNothing);

    await tester.tap(find.text('附件'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(result?.action, AddContextAction.attach);
  });

  testWidgets('add-context panel hides 目标 outside drafts', (tester) async {
    final gateway = RecordingChatGateway();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: Builder(
            builder: (buttonCtx) => FilledButton(
              onPressed: () => showAddContextSheet(
                buttonCtx,
                gateway: gateway,
                isDraft: false,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }

    expect(find.text('目标'), findsNothing);
    expect(find.text('工作流'), findsNothing);
    expect(find.text('附件'), findsOneWidget);
  });
}
