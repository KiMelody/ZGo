import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/ui/slash_items.dart';

/// Builds [SlashCommand]s through the same wire constructor the transport
/// uses (the class has no public one-off constructor).
List<SlashCommand> _commands(List<String> names) => WorkspacePrep.fromMap({
      'slashCommands': [
        for (final n in names) {'name': n, 'description': 'desk-$n'},
      ],
    }).slashCommands;

void main() {
  group('builtin side-chat aliases (task 11-11 C1)', () {
    test('a non-null description injects /side then /btw, sharing it', () {
      final items = buildSlashItems(
        commands: _commands(['compact']),
        sideChatDescription: '新建并打开一个辅助对话',
      );

      expect(items.map((i) => i.name).toList(), ['side', 'btw', 'compact']);
      final side = items.first;
      expect(side.insert, '/side ');
      expect(side.description, '新建并打开一个辅助对话');
      expect(side.isSkill, isFalse);
      expect(side.isSubagent, isFalse);
      expect(items[1].insert, '/btw ');
      expect(items[1].description, '新建并打开一个辅助对话');
    });

    test('null description suppresses the whole segment (draft, task '
        'search, side-chat composer)', () {
      final items = buildSlashItems(commands: _commands(['compact']));

      expect(items.map((i) => i.name).toList(), ['compact']);
    });

    test('a desktop command with the same name wins — no duplicate row', () {
      final items = buildSlashItems(
        commands: _commands(['side', 'compact']),
        sideChatDescription: 'builtin side',
      );

      final side = items.where((i) => i.name == 'side').toList();
      expect(side, hasLength(1));
      expect(side.single.description, 'desk-side',
          reason: 'the desktop-issued command keeps its own description');
      expect(items.map((i) => i.name).toList(), ['btw', 'side', 'compact']);
    });

    test('dedupe is case-insensitive and per alias', () {
      final items = buildSlashItems(
        commands: _commands(['Side', 'BTW']),
        sideChatDescription: 'builtin side',
      );

      expect(items.map((i) => i.name).toList(), ['Side', 'BTW']);
      expect(items.map((i) => i.description).toList(),
          ['desk-Side', 'desk-BTW']);
    });
  });
}
