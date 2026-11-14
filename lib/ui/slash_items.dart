import '../protocol/conversation.dart';
import 'chat/mention_sheet.dart';

/// One slash/skill/subagent entry of the composer popup and the task-search
/// page's actions tab.
///
/// Why this exists: the synthesis (prepareWorkspace commands, desktop skills
/// with the `$` trigger prefix and subagents with `@`) used to live as
/// chat_page's private `_slashItems` while the task list's command search
/// re-implemented the command half only — the two surfaces drifted. One
/// builder, one item type, both consumers.
///
/// The official `/` capability panel merges [commands, skills, subagents]
/// (renderer `_9e` @314154200), which is why subagents moved out of the `@`
/// mention panel and into this list.
class SlashItem {
  final String name;
  final String description;

  /// Text written into the composer on selection: `/name ` for commands,
  /// `$name ` for skills, `@name ` for subagents.
  final String insert;
  final bool isSkill;
  final bool isSubagent;

  const SlashItem({
    required this.name,
    required this.description,
    required this.insert,
    this.isSkill = false,
    this.isSubagent = false,
  });
}

/// Builds the shared entries: builtin/custom commands from
/// `prepareWorkspace`, the desktop's enabled skills (`$name`) and its
/// subagents (`@name`). Semantics frozen from the former chat_page
/// `_slashItems`, extended with the subagent segment.
///
/// [sideChatDescription] enables the builtin side-chat aliases `/side` and
/// `/btw` (the desktop registers one builtin command under both names,
/// description key `chat.slash.app.side.description`): pass a localized
/// description only where the aliases are actually executable — an existing
/// conversation's composer. Null suppresses the segment entirely: no session
/// id yet (drafts have their own guard dead end), the task-search actions tab
/// (its selection merely pre-fills a new chat), and side-chat composers
/// (task 11-11 R5: no nesting, desktop hides the same entries).
///
/// Dedupe: a desktop-issued command with the same name wins — the builtin
/// alias is dropped so `/side` never appears twice.
List<SlashItem> buildSlashItems({
  List<SlashCommand>? commands,
  List<SkillEntry>? skills,
  List<Map<String, dynamic>>? subagents,
  String? sideChatDescription,
}) {
  final issued = {
    for (final c in commands ?? const <SlashCommand>[]) c.name.toLowerCase(),
  };
  return [
    if (sideChatDescription != null)
      for (final alias in const ['side', 'btw'])
        if (!issued.contains(alias))
          SlashItem(
            name: alias,
            description: sideChatDescription,
            insert: '/$alias ',
          ),
    for (final c in commands ?? const <SlashCommand>[])
      SlashItem(
        name: c.name,
        description: c.description,
        insert: '/${c.name} ',
      ),
    for (final s in skills ?? const <SkillEntry>[])
      SlashItem(
        name: s.name,
        description:
            s.description ?? (s.argumentHint != null ? '${s.argumentHint}' : ''),
        insert: '${mentionSkillToken(s.name)} ',
        isSkill: true,
      ),
    for (final a in subagents ?? const <Map<String, dynamic>>[])
      if ('${a['name'] ?? ''}'.isNotEmpty)
        SlashItem(
          name: '${a['name']}',
          description: '${a['description'] ?? ''}',
          insert: '${mentionSubagentToken('${a['name']}')} ',
          isSubagent: true,
        ),
  ];
}
