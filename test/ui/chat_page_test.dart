import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show MethodChannel, SystemChannels, Uint8List;
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/i18n/lexicon.dart';
import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/protocol/remote_client.dart';
import 'package:zgo/state/device_session.dart';
import 'package:zgo/state/entitlement_poller.dart';
import 'package:zgo/state/quota_reset.dart';
import 'package:zgo/state/side_chat_registry.dart';
import 'package:zgo/ui/chat/chat_page.dart';
import 'package:zgo/ui/chat/subagent_detail_page.dart';
import 'package:zgo/ui/chat/timeline.dart';
import 'package:zgo/ui/chat/workflow_run_page.dart';
import 'package:zgo/ui/quota_reset_dialog.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../helpers/chat_role_fakes.dart';

/// Chat-page fake: everything rides the shared loose-default recording
/// bundle — real [ConversationState] frame injection via
/// [ChatGatewayBundle.feedSnapshot], command calls recorded in `calls` and
/// answered `accepted` (the conversation command surface goes through
/// `conversationCommands`). The class itself lives in
/// `helpers/chat_role_fakes.dart` and is shared with the sibling page
/// tests.

/// Transport that never answers `resolveInteraction` — holds the questions
/// card in its busy state for assertions (the real gateway ack is a passing
/// instant no frame can catch). Unrelated members are never exercised.
class _HoldTransport implements ConversationTransport {
  @override
  Future<dynamic> resolveInteraction(
    String sessionId,
    String interactionId, {
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  }) async => Completer<dynamic>().future;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _HoldResolveGateway extends FakeChatGateway {
  final _hold = _HoldTransport();

  @override
  ConversationTransport get conversationCommands => _hold;
}

/// Transport whose `resolveInteraction` / `respondWorkspaceHookReview` throw
/// — the D-01 failure path (an RPC error must surface copy, not a silent
/// catch).
class _ThrowingInteractionTransport implements ConversationTransport {
  @override
  Future<dynamic> resolveInteraction(
    String sessionId,
    String interactionId, {
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  }) async =>
      throw StateError('resolve failed');

  @override
  Future<dynamic> respondWorkspaceHookReview(
    String sessionId,
    Map<String, dynamic> frame,
    List<String> reviewItemIds,
  ) async =>
      throw StateError('trust failed');

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _ThrowingInteractionGateway extends FakeChatGateway {
  final _throwing = _ThrowingInteractionTransport();

  @override
  ConversationTransport get conversationCommands => _throwing;
}

/// Programmable `switchModelConfig` for the sheet `_apply` tests (PRD
/// 09-19): records the named args (the shared recording transport only
/// keeps positional ones) and answers from [results] — an Exception/Error
/// entry is thrown (lost-ack path), anything else is returned verbatim
/// (e.g. a `{'status': …}` rejection); exhausted list → accepted.
class _SwitchTransport implements ConversationTransport {
  _SwitchTransport({this.results = const []});

  final List<Object?> results;
  int _consumed = 0;
  final List<({String provider, String model, String thought})> switches = [];

  /// Ledger terminal settlements for the AC8 coexistence assertion.
  final StreamController<CommandLedgerOutcome> _outcomes =
      StreamController<CommandLedgerOutcome>.broadcast();

  @override
  Stream<CommandLedgerOutcome> get commandOutcomes => _outcomes.stream;

  void emitCommandOutcome(CommandLedgerOutcome outcome) => _outcomes.add(outcome);

  @override
  Future<dynamic> switchModelConfig(
    String sessionId, {
    required String provider,
    required String model,
    required String thought,
  }) async {
    switches.add((provider: provider, model: model, thought: thought));
    if (_consumed < results.length) {
      final next = results[_consumed++];
      if (next is Exception) throw next;
      if (next is Error) throw next;
      return next;
    }
    return const {'status': 'accepted'};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _SwitchGateway extends FakeChatGateway {
  _SwitchGateway(this.transport, {WorkspacePrep? prep}) : _prep = prep;

  final _SwitchTransport transport;
  final WorkspacePrep? _prep;

  /// prepareWorkspace answers served in order; the last one repeats. Lets a
  /// test hand the page a stale prep first and a fresh one after the switch
  /// (design 11-09 §3: the B re-fetch).
  final List<WorkspacePrep> prepAnswers = [];
  int prepareWorkspaceCalls = 0;

  @override
  ConversationTransport get conversationCommands => transport;

  @override
  Future<WorkspacePrep> prepareWorkspace() async {
    prepareWorkspaceCalls++;
    if (prepAnswers.isNotEmpty) {
      final index = (prepareWorkspaceCalls - 1).clamp(0, prepAnswers.length - 1);
      return prepAnswers[index];
    }
    return _prep ?? await super.prepareWorkspace();
  }
}

/// prepareWorkspace with the desktop's `goal` and `workflow` commands: with
/// the builtin `/side` `/btw` aliases the `/` popup lists four entries — the
/// F 终验 overflow scenario.
class _FullSlashGateway extends FakeChatGateway {
  @override
  Future<WorkspacePrep> prepareWorkspace() async =>
      WorkspacePrep.fromMap(const {
        'configOptions': <Map<String, dynamic>>[],
        'slashCommands': [
          {
            'name': 'goal',
            'description': 'Show or set the current session goal.',
          },
          {
            'name': 'workflow',
            'description':
                'Design and launch a dynamic workflow for a session.',
          },
        ],
      });
}

/// prepareWorkspace that ships no config options — the sheet-fallback
/// scenario (desktop answered but carried no model/thought selects).
WorkspacePrep barePrep() => WorkspacePrep.fromMap(const {
  'configOptions': <Map<String, dynamic>>[],
  'slashCommands': <Map<String, dynamic>>[],
});

/// prepareWorkspace with the research §5 plan catalog — four `account:*`
/// plan groups plus the personal provider (幻城), every option carrying the
/// wire `modelProviderId` the entitlement filter keys on.
WorkspacePrep planCatalogPrep() {
  Map<String, dynamic> option(
    String providerId,
    String providerName,
    String model,
  ) => {
    'value': '$providerId/$model',
    'name': model,
    'modelProviderId': providerId,
    'modelProviderName': providerName,
  };
  return WorkspacePrep.fromMap({
    'configOptions': [
      {
        'id': 'model',
        'name': 'Model',
        'currentValue': 'account:zai-start-plan/GLM-5.3',
        'options': [
          option('account:zai-individual-coding-plan',
              'Z.AI Individual Coding Plan', 'GLM-5.3'),
          option('account:zai-individual-coding-plan',
              'Z.AI Individual Coding Plan', 'GLM-5.3-Flash'),
          option('account:zai-start-plan', 'Start Plan', 'GLM-5.3'),
          option('account:zai-start-plan', 'Start Plan', 'GLM-5.3-Flash'),
          option('account:zai-off-peak', 'Z.AI Idle plan', 'GLM-5.3'),
          option('account:zai-off-peak', 'Z.AI Idle plan', 'GLM-5.3-Flash'),
          option('account:zai-highspeed-card', 'Z.AI Highspeed card', 'GLM-5.3'),
          option('account:zai-highspeed-card', 'Z.AI Highspeed card',
              'GLM-5.3-Flash'),
          option('personal-huancheng', '幻城', 'deepseek-v4-flash'),
        ],
      },
    ],
    'slashCommands': <Map<String, dynamic>>[],
  });
}

/// Snapshot-level `config` for the live-session model sheet tests — the
/// current provider drives the entitlement filter's exemption.
Map<String, dynamic> snapshotModelConfig(String provider) => {
  'config': {
    'provider': provider,
    'model': 'GLM-5.3',
    'thought': 'enabled',
    'mode': 'build',
  },
};

/// prepareWorkspace with a thought option but NO currentValue — the cold
/// fallback scenario (nothing to inherit, createSession must ship 'max').
WorkspacePrep prepWithoutThoughtCurrent() => WorkspacePrep.fromMap(const {
  'configOptions': [
    {
      'id': 'model',
      'name': '模型',
      'currentValue': 'builtin/glm-5.2',
      'options': [
        {'value': 'builtin/glm-5.2', 'name': 'GLM-5.2'},
      ],
    },
    {
      'id': 'thought_level',
      'name': '思考等级',
      'options': [
        {'value': 'max', 'name': '最高'},
        {'value': 'low', 'name': '低'},
      ],
    },
  ],
  'slashCommands': <Map<String, dynamic>>[],
});

/// prepareWorkspace carrying the desktop's per-model thought tables (design
/// 11-09 §1): `high-only` has [low, high], `wide` has [low, high, max] with
/// max as the wire default, `plain` has no table (the whole key absent, the
/// conditional-spread form). The global `thought_level` option deliberately
/// describes `high-only` only — the stale-levels situation a switch creates.
WorkspacePrep perModelThoughtPrep() => WorkspacePrep.fromMap(const {
  'configOptions': [
    {
      'id': 'model',
      'name': 'Model',
      'currentValue': 'builtin/$kHighOnlyModel',
      'options': [
        {
          'value': 'builtin/$kHighOnlyModel',
          'name': 'High Only',
          'modelProviderId': 'builtin',
          'modelProviderName': 'Builtin',
          'modelThoughtLevels': ['low', 'high'],
        },
        {
          'value': 'builtin/$kWideModel',
          'name': 'Wide',
          'modelProviderId': 'builtin',
          'modelProviderName': 'Builtin',
          'modelThoughtLevels': ['low', 'high', 'max'],
          'modelDefaultThoughtLevel': 'max',
        },
        {
          'value': 'builtin/$kPlainModel',
          'name': 'Plain',
          'modelProviderId': 'builtin',
          'modelProviderName': 'Builtin',
        },
      ],
    },
    {
      'id': 'thought_level',
      'name': 'Thought level',
      'currentValue': 'high',
      'options': [
        {'value': 'low', 'name': '低'},
        {'value': 'high', 'name': '高'},
      ],
    },
  ],
  'slashCommands': <Map<String, dynamic>>[],
});

const kHighOnlyModel = 'high-only';
const kWideModel = 'wide';
const kPlainModel = 'plain';

/// prepareWorkspace for the re-fetch gate test (design 11-09 §3): a
/// personal current model plus Start-plan and coding-plan options. Opening
/// the page judges nothing (the personal provider never matches the Start
/// plan regex), so the auto switch's one-shot guard stays unset — manually
/// switching INTO the Start plan is then exactly the new trigger surface an
/// ungated re-fetch would fire on (terminal snapshot + entitled target).
WorkspacePrep startPlanSwitchPrep() => WorkspacePrep.fromMap(const {
  'configOptions': [
    {
      'id': 'model',
      'name': 'Model',
      'currentValue': 'personal-huancheng/deepseek-v4-flash',
      'options': [
        {
          'value': 'personal-huancheng/deepseek-v4-flash',
          'name': 'Deepseek',
          'modelProviderId': 'personal-huancheng',
          'modelProviderName': '幻城',
        },
        {
          'value': 'account:zai-start-plan/glm-flash',
          'name': 'Start Flash',
          'modelProviderId': 'account:zai-start-plan',
          'modelProviderName': 'Start Plan',
        },
        {
          'value': 'account:zai-individual-coding-plan/glm-pro',
          'name': 'Coding Pro',
          'modelProviderId': 'account:zai-individual-coding-plan',
          'modelProviderName': 'Z.AI Individual Coding Plan',
        },
      ],
    },
  ],
  'slashCommands': <Map<String, dynamic>>[],
});

/// Snapshot `config` for a live session on the personal model above — the
/// re-fetch gate test's starting point (a provider the auto switch ignores).
Map<String, dynamic> personalModelConfig() => {
  'config': {
    'provider': 'personal-huancheng',
    'model': 'deepseek-v4-flash',
    'thought': 'enabled',
    'mode': 'build',
  },
};

/// Snapshot `config` for a live session pinned to [model] of the fixture
/// above — the starting point for switch tests.
Map<String, dynamic> thoughtModelConfig(String model, {String thought = 'high'}) => {
  'config': {
    'provider': 'builtin',
    'model': model,
    'thought': thought,
    'mode': 'build',
    'thoughtLevels': ['low', 'high'],
  },
};

/// FakeChatGateway with an injected prepareWorkspace answer (the shared
/// default keeps recording createSession — the payload assertions below
/// ride [FakeChatGateway.calls]).
class _PrepGateway extends FakeChatGateway {
  _PrepGateway(this.prep);

  final WorkspacePrep prep;

  @override
  Future<WorkspacePrep> prepareWorkspace() async => prep;
}

/// prepareWorkspace that fails (prep unreachable) — the draft-explicit test
/// reaches the model sheet through the provider-catalog fallback instead.
class _FailingPrepGateway extends FakeChatGateway {
  @override
  Future<WorkspacePrep> prepareWorkspace() async =>
      throw StateError('prep unavailable');
}

/// The composer TextField of one tab slot, default (visible-side) finder:
/// it resolves only while that tab is on screen — the activation assertion
/// of the creation-flow tests.
Finder visibleComposerOf(String sessionId) => find.descendant(
  of: find.byKey(ValueKey('chat-tab-$sessionId'), skipOffstage: false),
  matching: find.byType(TextField),
);

/// Composer text of one tab slot, hidden tabs included (the host composer
/// stays mounted offstage after a switch). Scoped to the composer's
/// [TextField]: the transcript's [SelectableText]s also build EditableTexts.
String tabComposerText(WidgetTester tester, String sessionId) =>
    tester
        .widget<TextField>(
          find.descendant(
            of: find.byKey(
              ValueKey('chat-tab-$sessionId'),
              skipOffstage: false,
            ),
            matching: find.byType(TextField, skipOffstage: false),
            skipOffstage: false,
          ),
        )
        .controller!
        .text;

Widget wrap(Widget child, {String locale = 'zh-CN'}) => MaterialApp(
  theme: buildDarkTheme(),
  darkTheme: buildDarkTheme(),
  builder: (context, child) => UiSettingsProvider(
    settings: UiSettings()..locale = locale,
    child: child!,
  ),
  home: child,
);

/// Locale-true copy for a lexicon key: the sheet assertions pin whatever the
/// zh table resolves to, so a key that has no entry yet (the i18n step lands
/// later) matches its key echo instead of a stale hard-coded string.
String chatLabel(String key, [List<String> args = const []]) =>
    trByKeyP('zh-CN', key, args);

/// The message list's ListView — the FIRST one in the message-area Stack.
/// The turn navigator strip (task 10-14) mounts its own scrollable as a
/// later sibling, so unqualified `find.byType(ListView)` now matches two.
Finder messageList() => find.byType(ListView).first;

/// Snapshot for one running subagent (`subagents.running[]` entry + its
/// `kind=='subagent'` works entry, live-probed 2026-09-13), optionally plus a
/// plain bash work. The composer button counts all three kinds, so the
/// auto-close/destroy gates (aggregate running count) must not be fed the
/// bash work unless a test wants it.
Map<String, dynamic> _subagentWorkSnapshot({bool withBash = false}) => {
      'subagents': {
        'revision': 1,
        'childSessionIds': ['sess_child_1'],
        'running': [
          {
            'childSessionId': 'sess_child_1',
            'agentId': 'agent_1',
            'toolCallId': 'call_1',
            'subagentType': 'general-purpose',
            'title': '实现加固',
            'status': 'running',
            'startedAt': 1789279676224,
          },
        ],
      },
      'backgroundWorks': [
        if (withBash)
          {
            'workId': 'bash_1',
            'kind': 'bash',
            'title': 'Download Flutter SDK',
            'status': 'running',
            'cancellable': true,
          },
        {
          'workId': 'agent_1',
          'kind': 'subagent',
          'title': '实现加固',
          'status': 'running',
          'startedAt': 1789279676224,
          'cancellable': true,
          'anchorRowId': null,
          'childSessionId': 'sess_child_1',
        },
      ],
    };

FakeChatGateway _gatewayWithSubagentWork() =>
    FakeChatGateway()..snapshotExtra = _subagentWorkSnapshot(withBash: true);

/// Subagent-only variant (no live bash work): the sheet/pill aggregate gate
/// reaches zero once the subagent goes terminal.
FakeChatGateway _gatewayWithSubagentOnlyWork() =>
    FakeChatGateway()..snapshotExtra = _subagentWorkSnapshot();

Future<void> _pumpWithRunningSubagent(
  WidgetTester tester,
  FakeChatGateway gateway,
) async {
  await tester.pumpWidget(
    wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
  );
  gateway.feedSnapshot([
    {
      'rowId': 9,
      'kind': 'subagent',
      'childSessionId': 'sess_child_1',
      'subagentType': 'general-purpose',
      'status': 'running',
      'summaryText': '实现加固，正在读取 a.dart',
      'workId': 'agent_1',
    },
    {'rowId': 10, 'kind': 'assistantText', 'text': 'done'},
  ]);
  // finite pumps: the works-bar spinner animates forever, pumpAndSettle
  // would time out on it.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders user bubble, assistant markdown and turn footer', (
    tester,
  ) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: '修复登录')),
    );
    // subscribe resolves on the next microtask; feed before settle
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '帮我修复登录'},
      {'rowId': 2, 'kind': 'assistantText', 'text': '已修复 **登录** 问题'},
      {
        'rowId': 3,
        'kind': 'turnHeader',
        'state': 'completedSuccess',
        'activeMs': 65000,
        'fileChanges': {'files': 2, 'additions': 10, 'deletions': 3},
      },
    ]);
    await tester.pumpAndSettle();

    expect(find.text('帮我修复登录'), findsOneWidget);
    expect(find.textContaining('已修复'), findsOneWidget);
    expect(find.text('任务会话'), findsOneWidget); // app bar caption
    expect(find.text('修复登录'), findsOneWidget); // app bar title
    // turn footer: worked duration + phase pill
    expect(find.textContaining('已工作'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
  });

  testWidgets('tool call renders summary + expandable diff', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '改一下'},
      {
        'rowId': 2,
        'kind': 'toolCall',
        'toolName': 'Edit',
        'status': 'success',
        'input': {
          'filePath': 'lib/a.dart',
          'old_string': 'a',
          'new_string': 'b',
        },
        'inputText':
            '{"filePath": "lib/a.dart", "old_string": "a", "new_string": "b"}',
      },
    ]);
    await tester.pumpAndSettle();

    expect(find.byType(ExpansionTile), findsOneWidget);
    expect(find.textContaining('已写入'), findsOneWidget);
    // Collapsed header shows basename title + directory subtitle.
    expect(find.textContaining('a.dart'), findsOneWidget);
    expect(find.text('lib'), findsOneWidget);
    // Collapsed by default: the diff body is absent until the header opens.
    expect(find.textContaining('-a'), findsNothing);
    expect(find.textContaining('+b'), findsNothing);

    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();
    expect(find.textContaining('-a'), findsWidgets);
    expect(find.textContaining('+b'), findsWidgets);
    // File edits carry the diff only — no raw parameter/output JSON dump.
    expect(find.textContaining('old_string'), findsNothing);
    expect(find.textContaining('filePath'), findsNothing);
  });

  testWidgets('permission interaction resolves through the gateway', (
    tester,
  ) async {
    final gateway = FakeChatGateway();
    gateway.snapshotExtra = {
      'pendingInteractions': [
        {
          'interactionId': 'i1',
          'payload': {
            'kind': 'permission',
            'toolName': 'Bash',
            'summary': 'rm -rf build',
            'options': [
              {'optionId': 'o1', 'kind': 'allowOnce'},
              {'optionId': 'o2', 'kind': 'deny'},
            ],
          },
        },
      ],
    };
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    expect(find.textContaining('权限请求'), findsOneWidget);
    expect(find.text('允许一次'), findsOneWidget);

    await tester.tap(find.text('允许一次'));
    await tester.pumpAndSettle();
    final call = gateway.calls
        .where((c) => c.$1 == 'resolveInteraction')
        .toList()
        .single;
    expect(call.$2[1], 'i1');
    expect(call.$2[2], 'o1');
  });

  testWidgets('permission option labels localize over the wire label', (
    tester,
  ) async {
    final gateway = FakeChatGateway();
    gateway.snapshotExtra = {
      'pendingInteractions': [
        {
          'interactionId': 'i1',
          'payload': {
            'kind': 'permission',
            'toolName': 'Bash',
            'summary': 'rm -rf build',
            'options': [
              // Live wire shape: schema-required kind + canonical English
              // label — kind wins.
              {'optionId': 'o1', 'kind': 'allowOnce', 'label': 'Allow once'},
              {'optionId': 'o3', 'kind': 'deny', 'label': 'Deny'},
              // Drift guard: kind gone, canonical label still localizes.
              {
                'optionId': 'o2',
                'label': 'Always allow in this project',
              },
              {'optionId': 'o5', 'label': 'Allow once'},
              // Unknown labels stay verbatim (drift / locale variance).
              {'optionId': 'o4', 'label': '再试一次'},
            ],
          },
        },
      ],
    };
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    expect(find.text('允许一次'), findsNWidgets(2));
    expect(find.text('拒绝'), findsOneWidget);
    expect(find.text('总是允许'), findsOneWidget);
    expect(find.text('再试一次'), findsOneWidget);
    expect(find.text('Allow once'), findsNothing);
    expect(find.text('Always allow in this project'), findsNothing);
  });

  /// Form-style `userInput` interaction (the `questions` payload) using the
  /// field names: `label`/`question` question text, `multiSelect`
  /// flag and `value`/`label` options.
  Map<String, dynamic> questionsInteraction(
    List<Map<String, dynamic>> questions,
  ) => {
    'interactionId': 'iq',
    'payload': {'kind': 'userInput', 'questions': questions},
  };

  const envQuestion = {
    'value': 'env',
    'label': '选择环境',
    'multiSelect': false,
    'options': [
      {'value': 'dev', 'label': '开发'},
      {'value': 'prod', 'label': '生产'},
    ],
  };

  const extrasQuestion = {
    'value': 'extras',
    'label': '附加组件',
    'multiSelect': true,
    'options': [
      {'value': 'lint', 'label': 'Lint'},
      {'value': 'test', 'label': '测试'},
    ],
  };

  Future<FakeChatGateway> pumpQuestions(
    WidgetTester tester,
    List<Map<String, dynamic>> questions, {
    FakeChatGateway? gateway,
  }) async {
    final gw = gateway ?? FakeChatGateway();
    gw.snapshotExtra = {
      'pendingInteractions': [questionsInteraction(questions)],
    };
    await tester.pumpWidget(
      wrap(ChatPage(host: gw, sessionId: 's1', title: 't')),
    );
    gw.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();
    return gw;
  }

  Finder chipOf(String label) =>
      find.ancestor(of: find.text(label), matching: find.byType(FilterChip));

  Finder customField(int index) => find.byKey(ValueKey('askq-custom-$index'));

  final submitKey = find.byTooltip('提交回答');

  testWidgets(
      'question option labels stay verbatim even when they collide with a '
      'canonical permission label', (tester) async {
    await pumpQuestions(tester, [
      const {
        'value': 'q',
        'label': '是否拒绝',
        'multiSelect': false,
        'options': [
          {'value': 'd', 'label': 'Deny'},
        ],
      },
    ]);
    // Questions render through _QuestionsView, never _optionLabel — a
    // model-authored choice spelled like the desktop's canonical English
    // permission label must not be localized.
    expect(find.text('Deny'), findsOneWidget);
    expect(find.text('拒绝'), findsNothing);
  });

  testWidgets(
    'IME up: strip floats over the list, composer touches the viewport '
    'bottom (09-20 真机 blank-band regression)', (tester) async {
      final gateway = FakeChatGateway();
      await tester.pumpWidget(
        wrap(
          MediaQuery(
            data: const MediaQueryData(viewInsets: EdgeInsets.only(bottom: 344)),
            child: ChatPage(host: gateway, sessionId: 's1', title: 't'),
          ),
        ),
      );
      gateway.feedSnapshot([
        {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
        {'rowId': 2, 'kind': 'assistant', 'text': 'done'},
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      const hint = '提出后续修改要求';
      expect(find.text(hint), findsOneWidget);
      final composerRect = tester.getRect(find.byType(TextField).first);
      final viewportH = tester.view.physicalSize.height /
          tester.view.devicePixelRatio;
      const inset = 344.0;
      // The composer rides above the keyboard (its toolbar row sits below
      // the field), and — the regression this pins — the status strip
      // renders inside the message Stack (bottom-anchored) instead of a
      // loose Flexible column child, whose unused flex share pooled at the
      // Column tail as a blank band between composer and keyboard.
      expect(
        composerRect.bottom,
        greaterThan(viewportH - inset - 100),
      );
      final stackStrip = find.descendant(
        of: find.byType(Stack),
        matching: find.byType(SingleChildScrollView),
      );
      expect(stackStrip, findsOneWidget);
    },
  );

  testWidgets(
    'IME inset rising keeps composer focus alive (09-20 真机 hide '
    'regression: letting the strip slot leave the Column shifted every '
    'later child, remounted the composer on the first inset frame and '
    'cancelled the keyboard ~130ms after show)', (tester) async {
      final gateway = FakeChatGateway();
      Widget page(double inset) => wrap(
        MediaQuery(
          data: MediaQueryData(viewInsets: EdgeInsets.only(bottom: inset)),
          child: ChatPage(host: gateway, sessionId: 's1', title: 't'),
        ),
      );
      await tester.pumpWidget(page(0));
      gateway.feedSnapshot([
        {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
        {'rowId': 2, 'kind': 'assistant', 'text': 'done'},
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Tap to focus the composer — step one of the real IME dance.
      await tester.tap(find.byType(TextField).first);
      await tester.pump();
      final focusedBefore = FocusManager.instance.primaryFocus;
      expect(focusedBefore, isNotNull);

      // The inset arrives and the page rebuilds in place (same root widget
      // type → same Element). This is the frame where the old code let the
      // composer remount, dropping focus and auto-hiding the just-shown IME.
      await tester.pumpWidget(page(344));
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, same(focusedBefore));
      // And the composer's Element is the same one — text typed during the
      // keyboard-up rebuild survives another rebuild.
      await tester.enterText(find.byType(TextField).first, 'abc');
      await tester.pumpWidget(page(344));
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, same(focusedBefore));
      expect(find.widgetWithText(TextField, 'abc'), findsOneWidget);
      // The real IME animates through many intermediate insets (one rebuild
      // per frame); the focus must survive the whole dance.
      for (final next in <double>[250, 120]) {
        await tester.pumpWidget(page(next));
        await tester.pump();
        expect(FocusManager.instance.primaryFocus, same(focusedBefore));
      }
      // And the boolean flip back to closed — the one frame where the two
      // strip slots swap places (Column slot expands, Stack slot collapses).
      await tester.pumpWidget(page(0));
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, same(focusedBefore));
    },
  );

  testWidgets(
    'keyboard shrink keeps the pinned list on the newest row (09-20 真机: '
    'the viewport shrank, the offset stayed and the latest messages were '
    'cut off below the composer)', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      addTearDown(tester.view.resetDevicePixelRatio);
      final gateway = FakeChatGateway();
      // The keyboard's effect is simulated as the physical viewport
      // shrinking (844 → 500), the same end state the real IME resize
      // produces. Tree-injected MediaQuery(viewInsets:…) looked right but
      // never shrank the list viewport in the test env (dim stayed put, no
      // ScrollMetricsNotification ever fired), and an explicit MediaQuery
      // without a size zeroes heightOf (the landscape branch would run
      // instead of the portrait dance this test pins) — the fixed size
      // keeps the portrait branch regardless of window height.
      Widget page() => wrap(
        MediaQuery(
          data: const MediaQueryData(size: Size(390, 844)),
          child: ChatPage(host: gateway, sessionId: 's1', title: 't'),
        ),
      );
      await tester.pumpWidget(page());
      gateway.feedSnapshot([
        for (var i = 0; i < 60; i++) ...[
          {'rowId': i * 2, 'kind': 'userInput', 'text': '问题 $i'},
          {
            'rowId': i * 2 + 1,
            'kind': 'assistantText',
            'text': '回答 $i，足够长以保证内容远超视口高度。',
          },
        ],
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 300));

      // The message ListView is the only one on a resting page.
      ScrollController controller() =>
          tester.widget<ListView>(messageList()).controller!;
      final pinned = controller();
      // Steady state: pin to the bottom explicitly (the launch animation
      // targets the SliverList's ESTIMATED max; its revision lands a frame
      // later, and pinning is the baseline the shrink dance starts from).
      pinned.jumpTo(pinned.position.maxScrollExtent);
      await tester.pump();
      expect(
        pinned.position.pixels,
        closeTo(pinned.position.maxScrollExtent, 1),
      );

      // IME up: the viewport shrinks (maxScrollExtent grows), and a pinned
      // list must ride along to the newest row instead of keeping its old
      // offset while the content stays anchored to the viewport top.
      tester.view.physicalSize = const Size(390, 500);
      await tester.pumpWidget(page());
      await tester.pump();
      final shrunk = controller();
      expect(
        shrunk.position.pixels,
        closeTo(shrunk.position.maxScrollExtent, 1),
      );

      // Unpinned list: the shrink must NOT pull it back down — following is
      // a pinned-state privilege.
      shrunk.jumpTo(shrunk.position.maxScrollExtent - 500);
      await tester.pump();
      tester.view.physicalSize = const Size(390, 844); // keyboard collapses
      await tester.pumpWidget(page());
      await tester.pump();
      final relaxed = controller();
      expect(
        relaxed.position.pixels,
        lessThan(relaxed.position.maxScrollExtent - 40),
      );
      tester.view.physicalSize = const Size(390, 500);
      await tester.pumpWidget(page()); // IME up again, still unpinned
      await tester.pump();
      final still = controller();
      expect(
        still.position.pixels,
        lessThan(still.position.maxScrollExtent - 40),
      );
    },
  );

  testWidgets('composer stays put while an interaction awaits', (tester) async {
    final gateway = await pumpQuestions(tester, [envQuestion]);

    // The interaction card is up and the composer coexists with it: answers
    // live inside the card, the composer only ever sends new messages.
    expect(submitKey, findsOneWidget);
    expect(find.text('提出后续修改要求'), findsOneWidget);

    // Once the interaction clears (desktop pushes a snapshot without it),
    // the card goes away and the composer is still there.
    gateway.snapshotExtra = const {};
    gateway.feedSnapshot(const [
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
      {'rowId': 2, 'kind': 'assistant', 'text': 'done'},
    ]);
    await tester.pumpAndSettle();
    expect(find.text('提出后续修改要求'), findsOneWidget);
    expect(submitKey, findsNothing);
  });

  testWidgets('reload snapshot (summary form) rebuilds the ask card', (
    tester,
  ) async {
    final gateway = FakeChatGateway();
    // 3.12.3 relay snapshot: the summary count object stands in for the
    // interaction list — the card must rebuild from the pendingApproval
    // tool call row instead.
    gateway.snapshotExtra = {
      'pendingInteractions': {'permissionCount': 0, 'userInputCount': 1},
    };
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
      {
        'rowId': 2,
        'kind': 'toolCall',
        'toolCallId': 'call_7',
        'toolName': 'AskUserQuestion',
        'status': 'pendingApproval',
        'approvalInteractionId': 'perm-call_7',
        'input': {
          'questions': [
            {
              'question': '选择环境',
              'header': '环境',
              'options': [
                {'value': 'dev', 'label': '开发'},
                {'value': 'prod', 'label': '生产'},
              ],
            },
          ],
        },
      },
    ]);
    await tester.pumpAndSettle();

    // Card is up (chips + submit key) and the composer coexists with it.
    expect(find.text('开发'), findsOneWidget);
    expect(submitKey, findsOneWidget);
    expect(find.text('提出后续修改要求'), findsOneWidget);

    await tester.tap(find.text('开发'));
    await tester.pump();
    await tester.tap(submitKey);
    await tester.pump();
    final call = gateway.calls
        .where((c) => c.$1 == 'resolveInteraction')
        .toList()
        .single;
    // The rebuilt card resolves under the row's approvalInteractionId —
    // the exact id the desktop derived (`perm-<toolCallId>`).
    expect(call.$2[1], 'perm-call_7');
    expect(call.$2[3], {
      'answers': {'选择环境': '开发'},
      'answer_0': 'dev',
      'answer': 'dev',
    });
  });

  testWidgets('questions card renders no free-text reply row', (tester) async {
    final gateway = FakeChatGateway();
    gateway.snapshotExtra = {
      'pendingInteractions': [
        {
          'interactionId': 'iq',
          'payload': {
            'kind': 'userInput',
            'freeText': true,
            'questions': [envQuestion],
          },
        },
      ],
    };
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    // AskUserQuestion payloads carry freeText=true, yet the questions form
    // (with its per-question custom input) replaces the reply row.
    expect(find.text('开发'), findsOneWidget);
    expect(find.text('输入回复…'), findsNothing);
  });

  testWidgets('freeText-only interaction keeps the reply input row', (
    tester,
  ) async {
    final gateway = FakeChatGateway();
    gateway.snapshotExtra = {
      'pendingInteractions': [
        {
          'interactionId': 'if',
          'payload': {'kind': 'userInput', 'prompt': '说说想法', 'freeText': true},
        },
      ],
    };
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    // No questions form → the reply row is the answering channel (the
    // composer coexists for new messages, so target the reply field).
    expect(find.text('输入回复…'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, '输入回复…'), '就这样');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    final call = gateway.calls
        .where((c) => c.$1 == 'resolveInteraction')
        .toList()
        .single;
    expect(call.$2[1], 'if');
  });

  testWidgets('custom input takes focus on the frame after expanding', (
    tester,
  ) async {
    await pumpQuestions(tester, [envQuestion]);

    await tester.tap(chipOf('自定义回答'));
    await tester.pump();
    await tester.pump();
    // Explicit next-frame focus — `autofocus` loses the race against slow
    // OEM IME startup (Xiaomi/HyperOS): the show-keyboard request lands
    // before the IME is ready and is dropped.
    expect(
      tester.widget<TextField>(customField(0)).focusNode!.hasFocus,
      isTrue,
    );
  });

  testWidgets('busy disables chips and input; submit arrow becomes a spinner', (
    tester,
  ) async {
    await pumpQuestions(
      tester,
      [extrasQuestion],
      gateway: _HoldResolveGateway(),
    );

    await tester.tap(chipOf('Lint'));
    await tester.pump();
    await tester.tap(chipOf('自定义回答'));
    await tester.pump();
    await tester.enterText(customField(0), '冒烟');
    await tester.tap(submitKey);
    await tester.pump(); // resolve never answers → busy frame

    // The ↑ key swapped its arrow for a spinner.
    expect(
      find.descendant(
        of: submitKey,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: submitKey,
        matching: find.byIcon(Icons.arrow_upward),
      ),
      findsNothing,
    );
    // Every control is disabled while the resolve is in flight.
    expect(tester.widget<FilterChip>(chipOf('Lint')).onSelected, isNull);
    expect(tester.widget<FilterChip>(chipOf('自定义回答')).onSelected, isNull);
    expect(tester.widget<TextField>(customField(0)).enabled, isFalse);
  });

  Map<String, dynamic> hookReviewInteraction() => {
    'interactionId': 'i1',
    'payload': {
      'kind': 'workspaceHookReview',
      'sessionId': 's1',
      'taskId': 't1',
      'runId': 'r1',
      'workspaceIdentity': 'wid',
      'workspaceLabel': 'my-repo',
      'bundleDigest':
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'reviewFlowId': 'rf1',
      'generation': 2,
      'interactionId': 'i1',
      'summary': {'eventCount': 3, 'hookCount': 2, 'pendingCount': 2},
      'items': [
        {
          'reviewItemId': 'r1',
          'event': 'SessionStart',
          'displayName': '启动检查',
          'displayCommand': 'bash startup.sh',
          'trustState': 'pending_trust',
        },
        {
          'reviewItemId': 'r2',
          'event': 'PreToolUse',
          'displayName': '守卫脚本',
          'displayCommand': 'python guard.py',
          'trustState': 'revoked',
        },
      ],
    },
  };

  Future<FakeChatGateway> pumpHookReview(WidgetTester tester) async {
    final gateway = FakeChatGateway();
    gateway.snapshotExtra = {
      'pendingInteractions': [hookReviewInteraction()],
    };
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();
    return gateway;
  }

  testWidgets('hook review card renders label, summary, items and badges', (
    tester,
  ) async {
    await pumpHookReview(tester);

    expect(find.text('my-repo'), findsOneWidget);
    expect(find.textContaining('3 个事件'), findsOneWidget);
    // items: name, event, mono command, trustState badges.
    expect(find.text('启动检查'), findsOneWidget);
    expect(find.text('SessionStart'), findsOneWidget);
    expect(find.textContaining('bash startup.sh'), findsOneWidget);
    expect(find.text('守卫脚本'), findsOneWidget);
    expect(find.text('待信任'), findsOneWidget);
    expect(find.text('已撤销'), findsOneWidget);
    expect(find.text('信任勾选项'), findsOneWidget);
  });

  testWidgets('trust button sends the checked reviewItemIds subset', (
    tester,
  ) async {
    final gateway = await pumpHookReview(tester);

    // All checked by default; uncheck the second hook, then trust.
    await tester.tap(find.byType(Checkbox).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('信任勾选项'));
    await tester.pumpAndSettle();

    final call = gateway.calls
        .where((c) => c.$1 == 'respondWorkspaceHookReview')
        .toList()
        .single;
    expect(call.$2[0], 's1');
    expect(call.$2[2], ['r1']);
  });

  testWidgets('unknown interaction kind keeps the generic fallback', (
    tester,
  ) async {
    final gateway = FakeChatGateway();
    gateway.snapshotExtra = {
      'pendingInteractions': [
        {
          'interactionId': 'i9',
          'payload': {'kind': 'mysteryCard'},
        },
      ],
    };
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    expect(find.textContaining('等待你的输入'), findsOneWidget);
    expect(
      gateway.calls.where((c) => c.$1 == 'respondWorkspaceHookReview'),
      isEmpty,
    );
  });

  // D-01: a failed resolve/trust used to vanish into an empty catch — the
  // card snapped back to idle with zero copy and the user retried blindly.
  testWidgets('a failed interaction resolve surfaces copy and resets busy',
      (tester) async {
    final gateway = _ThrowingInteractionGateway();
    gateway.snapshotExtra = {
      'pendingInteractions': [
        {
          'interactionId': 'i1',
          'payload': {
            'kind': 'permission',
            'toolName': 'Bash',
            'summary': 'rm -rf build',
            'options': [
              {'optionId': 'o1', 'kind': 'allowOnce'},
            ],
          },
        },
      ],
    };
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('允许一次'));
    await tester.pumpAndSettle();

    expect(find.text('提交失败，请重试'), findsOneWidget);
    // Busy reset: the option is tappable again (the finally block ran).
    expect(
      tester.widget<OutlinedButton>(find.ancestor(
        of: find.text('允许一次'),
        matching: find.byType(OutlinedButton),
      )).onPressed,
      isNotNull,
    );
  });

  testWidgets('a failed interaction resolve localizes the copy (en)',
      (tester) async {
    final gateway = _ThrowingInteractionGateway();
    gateway.snapshotExtra = {
      'pendingInteractions': [
        {
          'interactionId': 'i1',
          'payload': {
            'kind': 'permission',
            'toolName': 'Bash',
            'summary': 'rm -rf build',
            'options': [
              {'optionId': 'o1', 'kind': 'allowOnce'},
            ],
          },
        },
      ],
    };
    await tester.pumpWidget(
      wrap(
        ChatPage(host: gateway, sessionId: 's1', title: 't'),
        locale: 'en-US',
      ),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Allow once'));
    await tester.pumpAndSettle();

    expect(find.text('Submit failed, please try again'), findsOneWidget);
  });

  testWidgets('a failed hook trust surfaces copy and resets busy',
      (tester) async {
    final gateway = _ThrowingInteractionGateway();
    gateway.snapshotExtra = {
      'pendingInteractions': [hookReviewInteraction()],
    };
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('信任勾选项'));
    await tester.pumpAndSettle();

    expect(find.text('提交失败，请重试'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.ancestor(
        of: find.text('信任勾选项'),
        matching: find.byType(FilledButton),
      )).onPressed,
      isNotNull,
    );
  });

  testWidgets('queue bar deletes a queued item', (tester) async {
    final gateway = FakeChatGateway();
    gateway.snapshotExtra = {
      'queue': {
        'autoDrain': true,
        'items': [
          {'queueItemId': 'q1', 'text': '排队消息 A'},
        ],
      },
    };
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    expect(find.textContaining('排队消息 1'), findsOneWidget);
    await tester.tap(find.byTooltip('删除'));
    await tester.pumpAndSettle();
    // confirm dialog
    await tester.tap(find.text('删除').last);
    await tester.pump();
    final call = gateway.calls
        .where((c) => c.$1 == 'deleteQueueItem')
        .toList()
        .single;
    expect(call.$2, ['s1', 'q1']);
  });

  testWidgets('icon-only control chip owns a 44×48 touch box while the '
      'painted icon stays 16 (A-01)', (tester) async {
    // Below the 640 composer breakpoint the chips drop their labels — the
    // form the audit flagged as a 28×28 target.
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    final tuneInk = find
        .ancestor(
          of: find.byIcon(Icons.tune),
          matching: find.byType(InkWell),
        )
        .first;
    final size = tester.getSize(tuneInk);
    expect(size.width, greaterThanOrEqualTo(zTouchWidth));
    expect(size.height, greaterThanOrEqualTo(zTouchHeight));
    // Hit area only — the glyph keeps the tile icon size.
    expect(
      tester.widget<Icon>(find.byIcon(Icons.tune)).size,
      ZTile.iconSize,
    );
  });

  testWidgets('composer hint switches to the queue wording when queued',
      (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();
    expect(find.text('提出后续修改要求'), findsOneWidget);

    gateway.snapshotExtra = {
      'queue': {
        'autoDrain': true,
        'items': [
          {'queueItemId': 'q1', 'text': '排队消息 A'},
        ],
      },
    };
    gateway.feedSnapshot([
      {'rowId': 2, 'kind': 'userInput', 'text': 'hi again'},
    ]);
    await tester.pumpAndSettle();
    expect(find.text('继续输入以排队后续修改'), findsOneWidget);
  });

  testWidgets('queue bar drag-to-reorder issues reorderQueueItem with web shape',
      (tester) async {
    final gateway = FakeChatGateway();
    gateway.snapshotExtra = {
      'queue': {
        'autoDrain': true,
        'items': [
          {'queueItemId': 'q1', 'text': '排队消息 A'},
          {'queueItemId': 'q2', 'text': '排队消息 B'},
        ],
      },
    };
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    // Rows reorder via the drag handle, no arrow buttons.
    expect(find.byIcon(Icons.drag_indicator), findsNWidgets(2));
    expect(find.byTooltip('上移'), findsNothing);
    expect(find.byTooltip('下移'), findsNothing);

    // Drag q2 (bottom) above q1: it should be inserted before q1.
    final q2handle = find.byIcon(Icons.drag_indicator).last;
    final gesture = await tester.startGesture(tester.getCenter(q2handle));
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(0, -12));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();

    final up = gateway.calls
        .where((c) => c.$1 == 'reorderQueueItem')
        .toList()
        .single;
    expect(up.$2, ['s1', 'q2', 'q1']);
  });

  testWidgets('@ trigger opens mention picker; picking inserts reference',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final gateway = FakeChatGateway();
    gateway.searchWorkspaceFilesResult = [
      {
        'name': 'chat_page.dart',
        'relativePath': 'lib/ui/chat/chat_page.dart',
        'type': 'file',
      },
    ];
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '看一下 @');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // category list appears (ensure the tile is on-screen first).
    // Fixed pumps: the sheet's autofocus caret never lets pumpAndSettle
    // settle.
    expect(find.text('文件'), findsOneWidget);
    await tester.ensureVisible(find.text('文件'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('文件'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }

    expect(find.text('chat_page.dart'), findsOneWidget);
    await tester.tap(find.text('chat_page.dart'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }

    final tf = tester.widget<TextField>(find.byType(TextField).first);
    expect(
      tf.controller!.text,
      '看一下 [chat_page.dart](./lib/ui/chat/chat_page.dart) ',
    );
  });

  testWidgets('draft mode: first send issues createSession with firstText '
      'and the prep-currentValue thought', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(wrap(ChatPage(host: gateway, title: '新任务')));
    await tester.pumpAndSettle();
    expect(find.text('输入消息开始新任务'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '开始分析');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    // finite pumps: after createSession the page stays on the connect
    // spinner until the (fake) snapshot arrives, so pumpAndSettle hangs.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final call = gateway.calls
        .where((c) => c.$1 == 'createSession')
        .toList()
        .single;
    expect(call.$2[0], 'ws-1');
    expect(call.$2[1], '开始分析');
    // No explicit draft pick → the config still carries a legal thought
    // (prep's thought_level currentValue; cold runtimes fail model
    // creation without it).
    expect(call.$2[2], {'thought': 'enabled'});
  });

  testWidgets('draft first send anchors the ACTIVE workspace path (not the '
      'draft page path) and pulls the overview once', (tester) async {
    final gateway = FakeChatGateway();
    // The bridge's real landing point differs from the path the draft page
    // was opened in — the anchor must follow the ACTIVE workspace (spec
    // source ①), because `_openWorkspaceNow` prefers the bridge's own key.
    gateway.workspaceContext.workspacePath = '/repo/active';
    await tester.pumpWidget(wrap(ChatPage(
      host: gateway,
      title: '新任务',
      draftWorkspacePath: '/repo/captured-draft',
    )));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '开始分析');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(gateway.taskMeta.anchoredCreatedTasks, [
      ('new-s1', '/repo/active'),
    ], reason: 'write source ① anchors the active workspace, never the '
        'draft page path');
    expect(gateway.taskMeta.overviewRefreshes, 1,
        reason: 'the create trigger pulls the overview immediately — the '
            'new row is listed ~230 ms after the ack (run8)');
    expect(gateway.taskMeta.overviewRefreshBypasses, [true],
        reason: 'a user create action bypasses the cadence throttle');
  });

  testWidgets('a turn leaving the running class pulls the overview exactly '
      'once (terminal trigger)', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot(const [
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    // Finite pumps: streaming/turn animations keep the tree busy.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(gateway.taskMeta.overviewRefreshes, 0,
        reason: 'opening an idle session is not a terminal edge');

    // Turn starts: control.phase enters the running class.
    gateway.snapshotExtra = {
      'control': {'phase': 'running'},
    };
    gateway.feedSnapshot(const [
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
      {
        'rowId': 2,
        'kind': 'assistantText',
        'text': 'working',
        'streaming': true,
      },
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(gateway.taskMeta.overviewRefreshes, 0,
        reason: 'a running turn is not a terminal edge');

    // Turn terminal: control.phase leaves the running class.
    gateway.snapshotExtra = {
      'control': {'phase': 'idle'},
    };
    gateway.feedSnapshot(const [
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
      {'rowId': 2, 'kind': 'assistantText', 'text': 'done'},
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(gateway.taskMeta.overviewRefreshes, 1,
        reason: 'the status-correction net fires once on the terminal edge');
    expect(gateway.taskMeta.overviewRefreshBypasses, [true],
        reason: 'the terminal edge is a user-action trigger → bypass');

    // Repeated terminal frames never re-trigger: no running edge remains.
    gateway.feedSnapshot(const [
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
      {'rowId': 2, 'kind': 'assistantText', 'text': 'done'},
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(gateway.taskMeta.overviewRefreshes, 1);
  });

  testWidgets('draft with no thought source ships the max fallback and the '
      'sheet preselects it', (tester) async {
    final gateway = _PrepGateway(prepWithoutThoughtCurrent());
    await tester.pumpWidget(wrap(ChatPage(host: gateway, title: '新任务')));
    await tester.pumpAndSettle();

    // Sheet display walks the same chain the payload ships: prep has a
    // thought option but no currentValue → the 'max' chip is preselected.
    await tester.tap(find.text('glm-5.2')); // composer model chip
    await tester.pumpAndSettle();
    expect(
      tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '最高')).selected,
      isTrue,
    );
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '开始分析');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final call = gateway.calls
        .where((c) => c.$1 == 'createSession')
        .toList()
        .single;
    expect(call.$2[2], {'thought': 'max'});
  });

  testWidgets('draft explicit thought pick ships as selected', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(wrap(ChatPage(host: gateway, title: '新任务')));
    await tester.pumpAndSettle();

    // Pick a thought in the draft sheet (prep options: 开启/关闭).
    await tester.tap(find.text('glm-5.2')); // composer model chip
    await tester.pumpAndSettle();
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '开始分析');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final call = gateway.calls
        .where((c) => c.$1 == 'createSession')
        .toList()
        .single;
    expect(call.$2[2], {'thought': 'off'});
  });

    testWidgets('draft first send verifies the captured workspace before '
        'createSession', (tester) async {
      final gateway = FakeChatGateway();
      await tester.pumpWidget(
        wrap(
          ChatPage(
            host: gateway,
            title: '新任务',
            draftWorkspacePath: '/repo/app',
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '开始分析');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(gateway.ensuredDraftWorkspaces, ['/repo/app']);
      expect(
        gateway.calls.where((c) => c.$1 == 'createSession'),
        hasLength(1),
        reason: 'a reachable target proceeds to the normal create path',
      );
    });

  testWidgets('a stalled draft guard keeps the creating progress visible '
      '(2026-10-27 P1)', (tester) async {
    final gateway = FakeChatGateway()
      ..ensureDraftWorkspaceGate = Completer<void>();
    await tester.pumpWidget(
      wrap(
        ChatPage(
          host: gateway,
          title: '新任务',
          draftWorkspacePath: '/repo/app',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '开始分析');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();

    // The guard is parked (bridge-jitter window): the page must say it is
    // creating instead of sitting silent, and no session may be created.
    expect(
      find.text(trLocale('zh-CN', 'chat.creating')),
      findsOneWidget,
      reason: 'the progress state covers the guard/handshake wait, not '
          'just the createSession rpc',
    );
    expect(gateway.calls.where((c) => c.$1 == 'createSession'), isEmpty);

    gateway.ensureDraftWorkspaceGate!.complete();
    // Fixed pumps, not pumpAndSettle: the creating progress may keep an
    // animation alive while the fake createSession has long completed.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      gateway.calls.where((c) => c.$1 == 'createSession'),
      hasLength(1),
      reason: 'once the guard resolves the send proceeds normally',
    );
  });

  testWidgets('a dead-end draft target blocks the send and keeps the draft',
      (tester) async {
    final gateway = FakeChatGateway()
      ..ensureDraftWorkspaceResult =
          const WorkspaceOpenUnreachable('window gate dead end');
    await tester.pumpWidget(
      wrap(
        ChatPage(
          host: gateway,
          title: '新任务',
          draftWorkspacePath: '/repo/chat',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '开始分析');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(gateway.ensuredDraftWorkspaces, ['/repo/chat']);
    expect(
      gateway.calls.where((c) => c.$1 == 'createSession'),
      isEmpty,
      reason: 'creating now would land the task in the wrong workspace',
    );
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      '开始分析',
      reason: 'the draft text survives the blocked send',
    );
    expect(
      find.text(trLocale('zh-CN', 'tasks.workspaceUnreachable')),
      findsOneWidget,
    );
  });

  testWidgets('a cold-runtime draft target says the runtime is not running',
      (tester) async {
    // Same blocked-send guard, different dead end: the bridge attached but
    // the workspace runtime is cold, so the toast must give the desktop
    // instruction instead of "workspace is not open".
    final gateway = FakeChatGateway()
      ..ensureDraftWorkspaceResult = const WorkspaceOpenRuntimeNotRunning(
          'ZCode Agent runtime is not running.');
    await tester.pumpWidget(
      wrap(
        ChatPage(
          host: gateway,
          title: '新任务',
          draftWorkspacePath: '/repo/chat',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '开始分析');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(gateway.ensuredDraftWorkspaces, ['/repo/chat']);
    expect(
      gateway.calls.where((c) => c.$1 == 'createSession'),
      isEmpty,
      reason: 'a cold runtime blocks the send exactly like a wrong scope',
    );
    expect(
      find.text(trLocale('zh-CN', 'tasks.agentRuntimeNotRunning')),
      findsOneWidget,
    );
    expect(
      find.text(trLocale('zh-CN', 'tasks.workspaceUnreachable')),
      findsNothing,
    );
  });

  testWidgets('existing session: send goes through sendTextOrQueue', (
    tester,
  ) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '继续');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();

    expect(
      gateway.ensuredDraftWorkspaces,
      isEmpty,
      reason: 'an existing session never re-runs the draft guard',
    );
    final call = gateway.calls
        .where((c) => c.$1 == 'sendTextOrQueue')
        .toList()
        .single;
    expect(call.$2, ['s1', '继续', null]);
  });

  group('suspended send (task 11-13): chip + composer lock', () {
    /// Pumps a live page and arms one suspended send result.
    Future<FakeChatGateway> pumpSuspended(
      WidgetTester tester, {
      bool chromeless = false,
      bool isActive = true,
    }) async {
      final gateway = FakeChatGateway();
      gateway.sendTextOrQueueResults.add(
        const SendTextSuspended('cmd-1'),
      );
      await tester.pumpWidget(
        wrap(ChatPage(
          host: gateway,
          sessionId: 's1',
          title: 't',
          chromeless: chromeless,
          isActive: isActive,
        )),
      );
      gateway.feedSnapshot([
        {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
      ]);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '挂起中的消息');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pump();
      return gateway;
    }

    testWidgets('the chip keeps the input in place, locks the whole input, '
        'and a delivered outcome on the resend chain clears it', (tester) async {
      final gateway = await pumpSuspended(tester);

      expect(find.byKey(const ValueKey('chat-suspend-chip')), findsOneWidget);
      expect(find.byIcon(Icons.arrow_upward), findsNothing);
      expect(find.text('确认中'), findsOneWidget);
      expect(find.text('命令确认中，暂不可发送'), findsOneWidget);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.readOnly, isTrue,
          reason: 'editing the text must not reopen the send path');
      expect(field.controller!.text, '挂起中的消息',
          reason: 'the suspended message stays in the composer');
      expect(
        gateway.calls.where((c) => c.$1 == 'sendTextOrQueue'),
        hasLength(1),
      );

      // The chip is not a second send entry.
      await tester.tap(find.byKey(const ValueKey('chat-suspend-chip')));
      await tester.pump();
      expect(
        gateway.calls.where((c) => c.$1 == 'sendTextOrQueue'),
        hasLength(1),
      );

      // A resend gets a fresh commandId; the outcome binds the original
      // root, so the chip upgrades and the normal sent flow resumes.
      gateway.emitCommandOutcome(
        const CommandLedgerOutcome(
          commandId: 'cmd-2',
          rootCommandId: 'cmd-1',
          sessionId: 's1',
          kind: 'sendText',
          settlement: CommandLedgerSettlement.delivered,
        ),
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('chat-suspend-chip')), findsNothing);
      expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
      final after = tester.widget<TextField>(find.byType(TextField));
      expect(after.controller!.text, isEmpty);
      expect(after.readOnly, isFalse);
    });

    testWidgets('a rejected outcome clears the chip, keeps the text and '
        'shows the existing failure copy family', (tester) async {
      final gateway = await pumpSuspended(tester);

      gateway.emitCommandOutcome(
        const CommandLedgerOutcome(
          commandId: 'cmd-1',
          rootCommandId: 'cmd-1',
          sessionId: 's1',
          kind: 'sendText',
          settlement: CommandLedgerSettlement.rejected,
          decision: CommandDecision(
            status: CommandDecisionStatus.rejected,
            wireStatus: 'rejected',
            raw: {'status': 'rejected', 'reasonCode': 'NO_ACTIVE_TURN'},
            reasonCode: 'NO_ACTIVE_TURN',
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('chat-suspend-chip')), findsNothing);
      expect(
        find.text(chatLabel('chat.send.failed', ['NO_ACTIVE_TURN'])),
        findsOneWidget,
      );
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, '挂起中的消息',
          reason: 'a failed send keeps the text for a retry');
      expect(field.readOnly, isFalse);
    });

    testWidgets('a failed outcome clears the chip and routes the decision '
        'reason through the failure prefix', (tester) async {
      final gateway = await pumpSuspended(tester);

      gateway.emitCommandOutcome(
        const CommandLedgerOutcome(
          commandId: 'cmd-1',
          rootCommandId: 'cmd-1',
          sessionId: 's1',
          kind: 'sendText',
          settlement: CommandLedgerSettlement.failed,
          decision: CommandDecision(
            status: CommandDecisionStatus.failed,
            wireStatus: 'failed',
            raw: {'status': 'failed', 'reasonCode': 'DESK_BUSY'},
            reasonCode: 'DESK_BUSY',
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('chat-suspend-chip')), findsNothing);
      expect(
        find.text(chatLabel('chat.send.failed', ['DESK_BUSY'])),
        findsOneWidget,
      );
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, '挂起中的消息',
          reason: 'a failed send keeps the text for a retry');
      expect(field.readOnly, isFalse);
    });

    testWidgets('a timedOut outcome clears the chip and routes the timeout '
        'copy through the same failure prefix', (tester) async {
      final gateway = await pumpSuspended(tester);

      gateway.emitCommandOutcome(
        const CommandLedgerOutcome(
          commandId: 'cmd-1',
          rootCommandId: 'cmd-1',
          sessionId: 's1',
          kind: 'sendText',
          settlement: CommandLedgerSettlement.timedOut,
        ),
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('chat-suspend-chip')), findsNothing);
      expect(
        find.text(
          chatLabel('chat.send.failed', [chatLabel('chat.error.timeout')]),
        ),
        findsOneWidget,
      );
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, '挂起中的消息',
          reason: 'a timed-out send keeps the text for a retry');
      expect(field.readOnly, isFalse);
    });

    testWidgets('switching the side-chat tab away drops the chip', (
      tester,
    ) async {
      final gateway = await pumpSuspended(
        tester,
        chromeless: true,
        isActive: true,
      );
      expect(find.byKey(const ValueKey('chat-suspend-chip')), findsOneWidget);

      await tester.pumpWidget(
        wrap(ChatPage(
          host: gateway,
          sessionId: 's1',
          title: 't',
          chromeless: true,
          isActive: false,
        )),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('chat-suspend-chip')), findsNothing);
    });

    testWidgets('an operation command suspended inside _run shows the '
        'pending notice, not the failure prefix', (tester) async {
      final gateway = FakeChatGateway();
      gateway.conversation.commandErrors['compact'] =
          CommandSuspendedException(commandId: 'cmp-1', sessionId: 's1');
      await tester.pumpWidget(
        wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
      );
      gateway.feedSnapshot([
        {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
      ]);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '/compact');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pumpAndSettle();

      expect(find.text(chatLabel('chat.suspend.pending')), findsOneWidget);
      expect(find.textContaining(chatLabel('chat.compact.failed')), findsNothing);
      expect(
        gateway.calls.where((c) => c.$1 == 'compact'),
        hasLength(1),
      );
    });

    testWidgets('setAssistantFeedback suspended: the added catch shows the '
        'pending notice (non-chat entry)', (tester) async {
      final gateway = FakeChatGateway();
      gateway.conversation.commandErrors['setAssistantFeedback'] =
          CommandSuspendedException(commandId: 'fb-1', sessionId: 's1');
      await tester.pumpWidget(
        wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
      );
      gateway.feedSnapshot([
        {'rowId': 1, 'kind': 'assistantText', 'text': '回答完毕'},
      ]);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.thumb_up_alt_outlined), findsOneWidget);

      await tester.tap(find.byIcon(Icons.thumb_up_alt_outlined));
      await tester.pump();

      expect(find.text(chatLabel('chat.suspend.pending')), findsOneWidget);
      expect(
        gateway.calls.where((c) => c.$1 == 'setAssistantFeedback'),
        hasLength(1),
      );
    });
  });

  testWidgets('attachment upload failure: snack retry action re-runs _send '
      '(regression: canRetry must NOT read _sending — inside the catch it '
      'is still true, the finally resets it only after)', (tester) async {
    final transport = _AttachRecordingTransport();
    final gateway = _AttachGateway(transport);
    // file_picker method-channel fake: one small file, data inline.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('miguelruivo.flutter.plugins.filepicker'),
      (call) async => call.method == 'any'
          ? [
              {
                'name': 'a.txt',
                'size': 3,
                'bytes': Uint8List.fromList([1, 2, 3]),
              },
            ]
          : null,
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('miguelruivo.flutter.plugins.filepicker'),
        null,
      );
    });
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    // `＋` opens the add-context panel; 附件 hands back the attach action,
    // which re-runs the file picker (D4).
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    await tester.tap(find.text('附件'));
    await tester.pumpAndSettle();
    expect(find.text('a.txt'), findsOneWidget); // pending bar chip

    // Empty text + pending files is a valid send (the :1139 guard allows
    // it, the composer's send button counts attachments as input).
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();

    // First attempt died in the upload — before sendTextOrQueue; the snack
    // carries the retry action because the files are still pending.
    expect(transport.attachmentPutCalls, 1);
    expect(transport.sendCalls, 0);
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    // Retry re-uploads and then sends; the pending bar drains.
    expect(transport.attachmentPutCalls, 2);
    expect(transport.sendCalls, 1);
    expect(find.text('a.txt'), findsNothing);
  });

  testWidgets('official swap: empty composer + running shows stop, typing '
      'brings the send back (pre-3.15 fallback: no canStop key)',
      (tester) async {
    final gateway = FakeChatGateway();
    gateway.snapshotExtra = {
      'control': {'phase': 'running'},
    };
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    // Empty composer: the slot is the stop button, no send beside it
    // (bundle cn = en && !nn; no canStop key → isRunning fallback).
    expect(find.byIcon(Icons.stop), findsOneWidget);
    expect(find.byIcon(Icons.arrow_upward), findsNothing);

    await tester.enterText(find.byType(TextField), '排队消息 A');
    await tester.pump();
    // With input the send button owns the slot; follow-ups still queue.
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    expect(find.byIcon(Icons.stop), findsNothing);

    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();
    final call = gateway.calls
        .where((c) => c.$1 == 'sendTextOrQueue')
        .toList()
        .single;
    expect(call.$2[1], '排队消息 A');
  });

  testWidgets('stop tap projects optimistically: button vanishes at once '
      'and a double tap sends exactly one stop command', (tester) async {
    final gateway = FakeChatGateway();
    gateway.snapshotExtra = {
      'control': {'phase': 'running', 'canStop': true},
    };
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.stop), findsOneWidget);
    // Same-frame double tap: the first projects optimistically, the
    // second is eaten by the re-entrancy guard.
    await tester.tap(find.byIcon(Icons.stop));
    await tester.tap(find.byIcon(Icons.stop));
    await tester.pump();
    expect(find.byIcon(Icons.stop), findsNothing);
    expect(
      gateway.calls.where((c) => c.$1 == 'stop'),
      hasLength(1),
    );

    // Optimistic false-kill convergence (A2): an authoritative frame that
    // still reports canStop=true restores the button.
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.stop), findsOneWidget);
  });

  testWidgets('stopState=stopping drops taps silently (no command, no '
      'invented UI form)', (tester) async {
    final gateway = FakeChatGateway();
    gateway.snapshotExtra = {
      'control': {
        'phase': 'running',
        'canStop': true,
        'stopState': 'stopping',
      },
    };
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    // Official web has no stopping form: the plain canStop button remains.
    expect(find.byIcon(Icons.stop), findsOneWidget);
    await tester.tap(find.byIcon(Icons.stop));
    await tester.pumpAndSettle();
    expect(gateway.calls.where((c) => c.$1 == 'stop'), isEmpty);
    expect(find.byIcon(Icons.stop), findsOneWidget);
  });

  testWidgets('kicked gateway shows the takeover overlay', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    gateway.kicked = true;
    gateway.notifyListeners();
    await tester.pumpAndSettle();

    expect(find.text('已被其他设备接管'), findsOneWidget);
    expect(find.text('重新连接'), findsOneWidget);
  });

  testWidgets('kicked takeover overlay blocks the send path (D1 revert '
      'lock: the full-screen overlay, not a banner/gray-out, owns the '
      'kicked UX)', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '下一条消息');
    await tester.pump();

    gateway.kicked = true;
    gateway.notifyListeners();
    await tester.pumpAndSettle();

    // The overlay absorbs the tap: nothing reaches the wire while kicked,
    // and no duplicate banner shows under the 92% scrim.
    await tester.tap(find.text('已被其他设备接管'), warnIfMissed: false);
    await tester.tap(find.byIcon(Icons.arrow_upward), warnIfMissed: false);
    await tester.pump();
    expect(gateway.calls.where((c) => c.$1 == 'sendTextOrQueue'), isEmpty);
    expect(
      find.text('其他终端占用了此设备连接，可等待其退出后重试'),
      findsNothing,
    );
  });

  testWidgets('subscribe failure surfaces the retry banner', (tester) async {
    final gateway = FakeChatGateway()
      ..failSubscribeWith = (m) => StateError('bridge down');
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    // finite pumps: the page shows an endless connect spinner on failure,
    // pumpAndSettle would time out on it.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('订阅失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('a not-connected subscribe failure reads as connection copy '
      '(R6)', (tester) async {
    // The reconnect window: the bridge is not attached yet, so subscribe
    // throws StateError('not connected'). The banner must not print
    // 「Bad state: not connected」.
    final gateway = FakeChatGateway()
      ..failSubscribeWith = (m) => StateError('not connected');
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('Bad state'), findsNothing);
    expect(find.textContaining('连接已断开'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('a cold-runtime subscribe failure shows the actionable runtime '
      'copy (R6)', (tester) async {
    final gateway = FakeChatGateway()
      ..failSubscribeWith = (m) =>
          ChannelRpcError('ZCode Agent runtime is not running', null);
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('该工作区的智能体运行时未启动'), findsOneWidget);
    expect(find.textContaining('runtime is not running'), findsNothing);
  });

  testWidgets('an unclassified subscribe failure keeps its raw text (R6)',
      (tester) async {
    // Not a StateError: its `Bad state:` prefix is itself a known
    // transport shape and maps to the connection copy above.
    final gateway = FakeChatGateway()
      ..failSubscribeWith = (m) => Exception('provider exploded');
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('provider exploded'), findsOneWidget);
  });

  testWidgets('reasoning rows collapse into the 思考过程 strip', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
      {'rowId': 2, 'kind': 'reasoning', 'text': '让我想想'},
      {'rowId': 3, 'kind': 'assistantText', 'text': '答案'},
    ]);
    await tester.pumpAndSettle();

    expect(find.text('思考过程'), findsOneWidget);
    // collapsed by default
    expect(find.text('让我想想'), findsNothing);
  });

  testWidgets('short viewport: composer collapse toggle lives in the suffix',
      (tester) async {
    // Real-device landscape surface (853×384 + cutout insets): the tool row
    // starts collapsed and the ⇅ toggle is the TextField suffixIcon — no
    // dedicated toolbar row stealing scarce input height.
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(853, 384);
    tester.view.padding = const FakeViewPadding(left: 45, top: 40);
    addTearDown(tester.view.reset);
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    // finite pumps: the page keeps a connecting spinner alive on this
    // surface, pumpAndSettle would time out on it.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Collapsed: no tool icons in the row, toggle inside the input's
    // InputDecorator.
    expect(find.byIcon(Icons.add_circle_outline), findsNothing);
    final toggle = find.byIcon(Icons.unfold_more);
    expect(toggle, findsOneWidget);
    expect(
      find.ancestor(of: toggle, matching: find.byType(InputDecorator)),
      findsOneWidget,
    );

    // Tap to expand: tools appear, suffix flips to the collapse icon.
    await tester.tap(toggle);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byIcon(Icons.add_circle_outline), findsOneWidget);
    expect(find.byIcon(Icons.unfold_less), findsOneWidget);
    expect(find.byIcon(Icons.unfold_more), findsNothing);

    // Tap again to collapse.
    await tester.tap(find.byIcon(Icons.unfold_less));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byIcon(Icons.add_circle_outline), findsNothing);
    expect(find.byIcon(Icons.unfold_more), findsOneWidget);

    // Portrait (short=false): no suffix toggle, the tool row stays put —
    // zero-change lock for tall viewports.
    tester.view.physicalSize = const Size(390, 844);
    tester.view.padding = const FakeViewPadding();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byIcon(Icons.unfold_more), findsNothing);
    expect(find.byIcon(Icons.unfold_less), findsNothing);
    expect(find.byIcon(Icons.add_circle_outline), findsOneWidget);
  });

  group('C6 landscape density (915×412 + device insets, mock 方案 B)', () {
    // Real-device landscape surface (记忆 zlinker-device-acceptance: top 40
    // status strip + left 45 punch hole; the simulator's all-zero insets
    // make the problem invisible). Probe-measured baseline before C6:
    // appBar 96 + second header row 32 + composer ≈130 → list 154 (37.4%).
    Future<void> pumpLandscape(
      WidgetTester tester, {
      FakeChatGateway? gateway,
    }) async {
      tester.view.physicalSize = const Size(915, 412);
      tester.view.devicePixelRatio = 1.0;
      tester.view.padding = const FakeViewPadding(left: 45, top: 40);
      addTearDown(tester.view.reset);
      final gw = gateway ?? FakeChatGateway();
      await tester.pumpWidget(
        wrap(ChatPage(
          host: gw,
          sessionId: 's1',
          title: 't',
          workspaceLabel: 'my-repo',
        )),
      );
      gw.feedSnapshot(const [
        {'rowId': 1, 'kind': 'userInput', 'text': 'hi', 'state': 'done'},
        {
          'rowId': 2,
          'kind': 'assistantText',
          'text': 'hello',
          'state': 'done',
        },
        {'rowId': 3, 'kind': 'userInput', 'text': 'q2', 'state': 'done'},
        {'rowId': 4, 'kind': 'assistantText', 'text': 'a2', 'state': 'done'},
      ]);
      // finite pumps: a connecting spinner keeps animating on this
      // surface — pumpAndSettle would time out on it.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('message viewport clears 40% of screen height', (tester) async {
      await pumpLandscape(tester);
      final listH = tester.getSize(messageList()).height;
      final appBarH = tester.getSize(find.byType(AppBar)).height;
      // C6 acceptance line (≥40%); the shipped state measures 198px ≈ 48%.
      expect(
        listH / 412,
        greaterThanOrEqualTo(0.40),
        reason: 'message viewport ${listH}px of 412 '
            '((${(listH / 412 * 100).toStringAsFixed(1)}%), appBar '
            '${appBarH}px) — below the 40% density line',
      );
    });

    testWidgets('header compact: chip visible, caption dropped, ⋮ menu', (
      tester,
    ) async {
      await pumpLandscape(tester);
      expect(find.text('my-repo'), findsOneWidget); // chip survives landscape
      expect(find.text('任务会话'), findsNothing); // caption line dropped
      expect(find.text('更多'), findsNothing); // text button became ⋮
      expect(find.byIcon(Icons.more_vert), findsOneWidget);
    });

    testWidgets('composer chips hidden until the input focuses, blur takes '
        'them back', (tester) async {
      await pumpLandscape(
        tester,
        gateway: _PrepGateway(prepWithoutThoughtCurrent()),
      );
      // Collapsed default: no model/thought chips (icon probes the row —
      // labels vary with state/prep).
      expect(find.byIcon(Icons.memory_outlined), findsNothing);
      expect(find.byIcon(Icons.psychology_alt_outlined), findsNothing);

      // Focus reveals the chips.
      await tester.tap(find.byType(TextField).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byIcon(Icons.memory_outlined), findsOneWidget);
      expect(find.byIcon(Icons.psychology_alt_outlined), findsOneWidget);

      // Blur reclaims the row.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byIcon(Icons.memory_outlined), findsNothing);
      expect(find.byIcon(Icons.psychology_alt_outlined), findsNothing);
    });

    testWidgets('rotating portrait→landscape mid-typing keeps the chips with '
        'the retained focus', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      final gateway = _PrepGateway(prepWithoutThoughtCurrent());
      await tester.pumpWidget(
        wrap(ChatPage(
          host: gateway,
          sessionId: 's1',
          title: 't',
          workspaceLabel: 'my-repo',
        )),
      );
      gateway.feedSnapshot(const [
        {'rowId': 1, 'kind': 'userInput', 'text': 'hi', 'state': 'done'},
        {
          'rowId': 2,
          'kind': 'assistantText',
          'text': 'hello',
          'state': 'done',
        },
      ]);
      await tester.pumpAndSettle();

      // Focus in portrait, then rotate onto the landscape surface — the
      // focus listener only fires on focus events, so the short-viewport
      // flip must adopt the retained focus (方案 B: focused ⇒ chips shown).
      await tester.tap(find.byType(TextField).first);
      await tester.pump();
      tester.view.physicalSize = const Size(915, 412);
      tester.view.padding = const FakeViewPadding(left: 45, top: 40);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byIcon(Icons.memory_outlined), findsOneWidget);
      expect(find.byIcon(Icons.psychology_alt_outlined), findsOneWidget);
    });
  });

  testWidgets('portrait lock: caption + second-row chip + text 更多 + chips '
      'unaffected (C6 zero-change guard)', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final gateway = _PrepGateway(prepWithoutThoughtCurrent());
    await tester.pumpWidget(
      wrap(ChatPage(
        host: gateway,
        sessionId: 's1',
        title: 't',
        workspaceLabel: 'my-repo',
      )),
    );
    gateway.feedSnapshot(const [
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi', 'state': 'done'},
      {'rowId': 2, 'kind': 'assistantText', 'text': 'hello', 'state': 'done'},
    ]);
    await tester.pumpAndSettle();

    expect(find.text('任务会话'), findsOneWidget); // caption app bar
    expect(find.text('my-repo'), findsOneWidget); // second-row chip
    expect(find.text('更多'), findsOneWidget); // text menu button
    expect(find.byIcon(Icons.more_vert), findsNothing);
    expect(find.byIcon(Icons.memory_outlined), findsOneWidget); // model chip
    expect(find.byIcon(Icons.unfold_more), findsNothing); // no suffix toggle

    // Focusing the input toggles nothing in portrait.
    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byIcon(Icons.memory_outlined), findsOneWidget);
  });

  testWidgets('timeline markers render as centered capsules', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
      {
        'rowId': 2,
        'kind': 'timelineMarker',
        'marker': {
          'type': 'modelChange',
          'fromModel': 'glm-5.2',
          'toModel': 'glm-5.2-air',
        },
      },
      {'rowId': 3, 'kind': 'assistantText', 'text': 'ok'},
    ]);
    await tester.pumpAndSettle();

    expect(find.textContaining('模型已切换 glm-5.2 → glm-5.2-air'), findsOneWidget);
  });

  testWidgets('user bubble hugs short text (no maxLines inflation)', (
    tester,
  ) async {
    // Regression: SelectableText(maxLines: 14) inflated short bubbles to
    // 14 lines inside the unbounded ListView; the bubble must hug content.
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '你好', 'state': 'done'},
      {'rowId': 2, 'kind': 'assistantText', 'text': '回复', 'state': 'done'},
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getSize(find.text('你好')).height, lessThan(30));
  });

  testWidgets('long user text collapses to 14 lines, 展开 reveals all', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    final longText = List.filled(30, '一行长文本内容').join('\n');
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': longText, 'state': 'done'},
      {'rowId': 2, 'kind': 'assistantText', 'text': '回复', 'state': 'done'},
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final bubbleText = find.textContaining('一行长文本内容');
    final clip = find.ancestor(
      of: bubbleText,
      matching: find.byType(SingleChildScrollView),
    );
    expect(clip, findsOneWidget);
    expect(tester.getSize(clip).height, lessThanOrEqualTo(14 * 21.0 + 1));

    await tester.tap(find.text('展开'));
    await tester.pump();
    expect(
      find.ancestor(
        of: bubbleText,
        matching: find.byType(SingleChildScrollView),
      ),
      findsNothing,
    );
    expect(tester.getSize(bubbleText).height, greaterThan(14 * 21.0));
  });

  testWidgets('send button disabled while the composer is empty', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi', 'state': 'done'},
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // The send button is a squircle visual (32) inside a 48px InkWell target.
    InkWell buttonOf() => tester.widget<InkWell>(
      find
          .ancestor(
            of: find.byIcon(Icons.arrow_upward),
            matching: find.byType(InkWell),
          )
          .first,
    );
    expect(buttonOf().onTap, isNull); // empty input → disabled

    await tester.enterText(find.byType(TextField), '继续');
    await tester.pump();
    expect(buttonOf().onTap, isNotNull);
  });

  group('cross-terminal deletion tombstone (10-06)', () {
    Future<FakeChatGateway> pumpChat(WidgetTester tester,
        {required FakeChatGateway gateway}) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
      );
      gateway.feedSnapshot([
        {'rowId': 1, 'kind': 'userInput', 'text': 'hi', 'state': 'done'},
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      return gateway;
    }

    InkWell sendButtonOf(WidgetTester tester) => tester.widget<InkWell>(
          find
              .ancestor(
                of: find.byIcon(Icons.arrow_upward),
                matching: find.byType(InkWell),
              )
              .first,
        );

    testWidgets('tombstoned id: banner shows and send greys out; forgetting '
        'the id recovers the composer', (tester) async {
      final gateway = await pumpChat(
        tester,
        gateway: FakeChatGateway()..deletedSessionIds.add('s1'),
      );

      // Banner + greyed send (input present, but tombstoned).
      expect(find.text('会话已在其他位置删除'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '继续');
      await tester.pump();
      expect(sendButtonOf(tester).onTap, isNull);

      // The id leaving the set (production: never mid-life; the page
      // re-reads on the gateway notify either way) recovers the composer.
      gateway.deletedSessionIds.remove('s1');
      gateway.notifyListeners();
      await tester.pump();
      expect(find.text('会话已在其他位置删除'), findsNothing);
      expect(sendButtonOf(tester).onTap, isNotNull);
    });

    testWidgets('live session: no tombstone banner, send stays enabled',
        (tester) async {
      await pumpChat(tester, gateway: FakeChatGateway());

      expect(find.text('会话已在其他位置删除'), findsNothing);
      await tester.enterText(find.byType(TextField), '继续');
      await tester.pump();
      expect(sendButtonOf(tester).onTap, isNotNull);
    });

    testWidgets('dispose forgets the page-held tombstone id', (tester) async {
      final gateway = await pumpChat(
        tester,
        gateway: FakeChatGateway()..deletedSessionIds.add('s1'),
      );
      expect(gateway.forgottenSessions, isEmpty);
      expect(gateway.isSessionDeleted('s1'), isTrue);

      // Unmount the page (dispose path) — the id must leave the set.
      await tester.pumpWidget(wrap(const SizedBox.shrink()));
      expect(gateway.forgottenSessions, ['s1']);
      expect(gateway.isSessionDeleted('s1'), isFalse);
    });
  });

  group('sessionNotFound terminal (10-11)', () {
    Future<FakeChatGateway> pumpChat(WidgetTester tester,
        {required FakeChatGateway gateway}) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
      );
      gateway.feedSnapshot([
        {'rowId': 1, 'kind': 'userInput', 'text': 'hi', 'state': 'done'},
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      return gateway;
    }

    InkWell sendButtonOf(WidgetTester tester) => tester.widget<InkWell>(
          find
              .ancestor(
                of: find.byIcon(Icons.arrow_upward),
                matching: find.byType(InkWell),
              )
              .first,
        );

    testWidgets('missing id: banner shows and send greys out', (tester) async {
      final gateway = await pumpChat(
        tester,
        gateway: FakeChatGateway()..missingSessionIds.add('s1'),
      );

      // Banner + greyed send (input present, but refused).
      expect(find.text('会话不存在'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '继续');
      await tester.pump();
      expect(sendButtonOf(tester).onTap, isNull);

      // The id leaving the set (production: never mid-life; the page
      // re-reads on the gateway notify either way) recovers the composer.
      gateway.missingSessionIds.remove('s1');
      gateway.notifyListeners();
      await tester.pump();
      expect(find.text('会话不存在'), findsNothing);
      expect(sendButtonOf(tester).onTap, isNotNull);
    });

    testWidgets('tombstone and refusal both hold: the authoritative '
        'refusal wins the banner (PRD R1)', (tester) async {
      await pumpChat(
        tester,
        gateway: FakeChatGateway()
          ..deletedSessionIds.add('s1')
          ..missingSessionIds.add('s1'),
      );

      expect(find.text('会话不存在'), findsOneWidget);
      expect(find.text('会话已在其他位置删除'), findsNothing);
      await tester.enterText(find.byType(TextField), '继续');
      await tester.pump();
      expect(sendButtonOf(tester).onTap, isNull);
    });

    testWidgets('dispose forgets the page-held missing id', (tester) async {
      final gateway = await pumpChat(
        tester,
        gateway: FakeChatGateway()..missingSessionIds.add('s1'),
      );
      expect(gateway.forgottenMissingSessions, isEmpty);
      expect(gateway.isSessionMissing('s1'), isTrue);

      // Unmount the page (dispose path) — the id must leave the set.
      await tester.pumpWidget(wrap(const SizedBox.shrink()));
      expect(gateway.forgottenMissingSessions, ['s1']);
      expect(gateway.isSessionMissing('s1'), isFalse);
    });
  });

  // ---- chat-page delete routing (10-11 chat-delete-task-routing) ----

  group('chat-page delete routing (10-11)', () {
    /// Pushes the chat page over a launcher route so the delete's
    /// `maybePop` is observable (on the home route it is a silent no-op).
    /// Returns the gateway for programming / assertions.
    Future<FakeChatGateway> pumpPushedChat(WidgetTester tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      final gateway = FakeChatGateway();
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      ChatPage(host: gateway, sessionId: 's1', title: 't'),
                ),
              ),
              child: const Text('open chat'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open chat'));
      // One turn so the page leaves the loading spinner (state.ready) —
      // pumpAndSettle would time out on it otherwise.
      gateway.feedSnapshot([
        {'rowId': 1, 'kind': 'userInput', 'text': 'hi', 'state': 'done'},
      ]);
      await tester.pumpAndSettle();
      return gateway;
    }

    /// Opens the 更多 menu and confirms the delete dialog (both the menu
    /// entry and the confirm button carry the same 删除 copy).
    Future<void> confirmDelete(WidgetTester tester) async {
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle(); // menu closes, dialog opens
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle(); // dialog closes, RPC settles
    }

    testWidgets('registered row: delete routes through deleteTask, never '
        'the deleteSession command, and pops on success', (tester) async {
      final gateway = await pumpPushedChat(tester);

      await confirmDelete(tester);

      expect(
        gateway.calls.where((c) => c.$1 == 'deleteTask').single.$2,
        ['s1'],
      );
      expect(gateway.calls.where((c) => c.$1 == 'deleteSession'), isEmpty);
      expect(find.byType(ChatPage), findsNothing);
    });

    testWidgets('draft row: deleteTask resolve failure falls back to '
        'deleteSession exactly once, then pops', (tester) async {
      final gateway = await pumpPushedChat(tester);
      gateway.deleteTaskResults.add(
        ChannelRpcError('列表 mutation 无法解析唯一 source, taskId=s1', null),
      );

      await confirmDelete(tester);

      expect(gateway.calls.where((c) => c.$1 == 'deleteTask'), hasLength(1));
      final fallback =
          gateway.calls.where((c) => c.$1 == 'deleteSession').toList();
      expect(fallback, hasLength(1));
      expect(fallback.single.$2, ['s1']);
      expect(find.byType(ChatPage), findsNothing);
    });

    testWidgets('RPC failure: no fallback, the toast is _run\'s and the '
        'page stays put (no pop on a failed delete)', (tester) async {
      final gateway = await pumpPushedChat(tester);
      gateway.deleteTaskResults.add(ChannelRpcError('bridge is down', null));

      await confirmDelete(tester);

      expect(gateway.calls.where((c) => c.$1 == 'deleteTask'), hasLength(1));
      expect(gateway.calls.where((c) => c.$1 == 'deleteSession'), isEmpty);
      expect(find.textContaining('bridge is down'), findsOneWidget);
      expect(find.byType(ChatPage), findsOneWidget);
    });

    testWidgets('failed ack: no fallback, no pop — locks the '
        '_ackOk/_run verdict mirror on one input', (tester) async {
      final gateway = await pumpPushedChat(tester);
      gateway.deleteTaskResults.add(
        const {'status': 'failed', 'reasonCode': 'x'},
      );

      await confirmDelete(tester);

      expect(gateway.calls.where((c) => c.$1 == 'deleteTask'), hasLength(1));
      expect(gateway.calls.where((c) => c.$1 == 'deleteSession'), isEmpty);
      // Both sides of the mirror on the same input: _run's verdict toasts...
      expect(find.textContaining('操作失败'), findsOneWidget);
      // ...and _ackOk's copy of that verdict refuses the pop.
      expect(find.byType(ChatPage), findsOneWidget);
    });
  });

  testWidgets('更多 menu: official order and pin toggle flips label', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi', 'state': 'done'},
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();

    // Menu order: pin first, then rename / archive / unread,
    // then the copy actions.
    String itemText(PopupMenuItem<String> i) {
      final w = i.child;
      if (w is Text) return w.data ?? '';
      if (w is Row) {
        for (final c in w.children) {
          if (c is Text) return c.data ?? '';
        }
      }
      return '';
    }

    final texts = tester
        .widgetList<PopupMenuItem<String>>(find.byType(PopupMenuItem<String>))
        .map(itemText)
        .toList();
    expect(texts.first, '置顶任务');
    expect(texts.indexOf('重命名任务'), lessThan(texts.indexOf('归档任务')));
    expect(texts.indexOf('归档任务'), lessThan(texts.indexOf('标记为未读')));
    expect(texts.indexOf('复制路径'), lessThan(texts.indexOf('复制会话 ID')));

    await tester.tap(find.text('置顶任务'));
    await tester.pumpAndSettle();
    final pin = gateway.calls
        .where((c) => c.$1 == 'setTaskPinned')
        .toList()
        .single;
    expect(pin.$2, ['s1', true]);

    // The label flips to the unpinned wording after toggling.
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('取消置顶任务'), findsOneWidget);
  });

  // ------------------------------------- jump-to-bottom button

  testWidgets('jump-to-bottom: hidden at the newest message, appears after '
      'scrolling up, jumps back and hides', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    // 24 turns: enough history to scroll through.
    gateway.feedSnapshot([
      for (var i = 1; i <= 24; i++) ...[
        {
          'rowId': i * 2 - 1,
          'kind': 'userInput',
          'text': '提问 $i',
          'state': 'done',
        },
        {
          'rowId': i * 2,
          'kind': 'assistantText',
          'text': '回答 $i',
          'state': 'done',
        },
      ],
    ]);
    await tester.pumpAndSettle();

    final controller =
        tester.widget<ListView>(messageList()).controller!;
    // The control stays mounted and cross-fades, so its target opacity is the
    // visibility signal (IgnorePointer blocks taps while transparent).
    double opacity() => tester
        .widget<AnimatedOpacity>(
          find
              .ancestor(
                of: find.byIcon(Icons.arrow_downward),
                matching: find.byType(AnimatedOpacity),
              )
              .first,
        )
        .opacity;

    // Precondition: the 24 turns really do overflow the viewport.
    expect(controller.position.maxScrollExtent, greaterThan(100));

    // Opening a session lands on the newest message → no button. The list is
    // laid out lazily, so assert the app's own pinned window instead of an
    // exact pixel.
    expect(
      controller.position.maxScrollExtent - controller.position.pixels,
      lessThan(40),
    );
    expect(opacity(), 0);

    // The reader scrolls up into the history: the button appears.
    controller.jumpTo(controller.position.maxScrollExtent - 200);
    await tester.pump();
    expect(opacity(), 1);

    await tester.tap(find.byTooltip('回到底部'));
    await tester.pumpAndSettle();

    // It lands on the newest message and hides itself again.
    expect(
      controller.position.pixels,
      moreOrLessEquals(controller.position.maxScrollExtent, epsilon: 0.5),
    );
    expect(opacity(), 0);
  });

  testWidgets('single background-tasks button carries the three-kind total; '
      'the works bar is retired', (tester) async {
    final gateway = _gatewayWithSubagentWork();
    await _pumpWithRunningSubagent(tester, gateway);

    // One button right of the mode chip: two live kinds (bash + subagent)
    // → the official mixed tooltip; the badge is the three-kind total.
    expect(find.byTooltip('打开运行中的终端与智能体'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byTooltip('打开运行中的终端与智能体'),
        matching: find.text('2'),
      ),
      findsOneWidget,
    );
    // Official ariaLabel template, per-kind counts interpolated.
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is Semantics &&
            w.properties.label ==
                '打开运行中的后台任务：Bash 1 个，工作流 0 个，子智能体 1 个，共 2 个',
      ),
      findsOneWidget,
    );

    // The retired works bar left the message flow with its 3 i18n keys.
    expect(find.textContaining('后台任务 1 个运行中'), findsNothing);
    expect(find.byTooltip('取消此后台任务'), findsNothing);
    expect(find.text('实现加固 · 正在读取 a.dart'), findsNothing);

    // goal=null: the goal panel stays hidden.
    expect(find.text('目标'), findsNothing);
  });

  testWidgets('background-tasks button switches tooltip per kind shape',
      (tester) async {
    Future<void> pumpWorks(List<Map<String, dynamic>> works) async {
      // Unmount any previous page first: pumpWidget reuses the State when the
      // widget type matches, which would keep the old gateway's live state.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      final gateway = FakeChatGateway()
        ..snapshotExtra = {'backgroundWorks': works};
      await tester.pumpWidget(
        wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
      );
      gateway.feedSnapshot([
        {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    Map<String, dynamic> work(String kind) => {
      'workId': '${kind}_1',
      'kind': kind,
      'title': kind,
      'status': 'running',
      'cancellable': true,
    };

    await pumpWorks([work('bash')]);
    expect(find.byTooltip('运行中的终端'), findsOneWidget);
    expect(find.byTooltip('打开运行中的终端与智能体'), findsNothing);

    await pumpWorks([work('workflow')]);
    expect(find.byTooltip('打开运行中的工作流'), findsOneWidget);

    await pumpWorks([work('bash'), work('workflow')]);
    expect(find.byTooltip('打开运行中的终端与智能体'), findsOneWidget);
  });

  testWidgets('agent tool call renders launch state and opens the detail page', (
    tester,
  ) async {
    final gateway = FakeChatGateway();
    // The inline Agent expansion subscribes the child session; seed a
    // separate (never-fed) child state so the parent rows don't leak into
    // the expansion's transcript.
    gateway.childStates['sess_child_1'] = ConversationState();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '去调研'},
      {
        'rowId': 2,
        'kind': 'toolCall',
        'toolName': 'Agent',
        'toolCallId': 'call_1',
        'status': 'success',
        // Live-probed shape (2026-09-16): description/subagent_type in the
        // input JSON, outputText empty — the result lives in the child.
        'inputText':
            '{"description":"调研通知层","prompt":"调研 lib/notifications 的结构","run_in_background":true,"subagent_type":"Explore"}',
      },
      {
        'rowId': 3,
        'kind': 'subagent',
        'parentToolCallId': 'call_1',
        'childSessionId': 'sess_child_1',
        'subagentType': 'Explore',
        'status': 'success',
        'summaryText': '调研通知层',
        'workId': 'agent_1',
      },
    ]);
    await tester.pumpAndSettle();

    // 启动状态词 + description 标题，subagentType 作副标题（
    // chat.toolCall.agent.backgroundLaunch* 文案对等）。
    expect(find.textContaining('已启动 · 调研通知层'), findsOneWidget);
    expect(find.text('Explore'), findsOneWidget);
    // 流内 subagent 行状态词本地化。
    expect(find.textContaining('已完成  调研通知层'), findsOneWidget);

    // 展开显示派发的提示词而非原始 JSON；展开体挂上订阅池的子会话
    // 时间线（此处子会话无快照 → 常驻 spinner，用有限 pump）。
    await tester.tap(find.textContaining('已启动 · 调研通知层'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(gateway.subscribedSessions, contains('sess_child_1'));
    expect(find.text('提示词'), findsOneWidget);
    expect(find.textContaining('调研 lib/notifications 的结构'), findsWidgets);
    expect(find.textContaining('run_in_background'), findsNothing);

    // 行尾箭头进入只读子会话详情页（首个箭头属于 Agent 行，
    // 第二个是流内 subagent 行的）。
    await tester.tap(find.byIcon(Icons.chevron_right).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(SubagentDetailPage), findsOneWidget);
    expect(gateway.subscribedSessions, contains('sess_child_1'));
  });

  testWidgets('running agent tool call shows 启动中 state', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '去调研'},
      {
        'rowId': 2,
        'kind': 'toolCall',
        'toolName': 'Agent',
        'toolCallId': 'call_9',
        'status': 'running',
        'inputText': '{"description":"调研通知层","prompt":"p","subagent_type":"Explore"}',
      },
      {
        'rowId': 3,
        'kind': 'subagent',
        'parentToolCallId': 'call_9',
        'childSessionId': 'sess_child_9',
        'subagentType': 'Explore',
        'status': 'running',
        'summaryText': '调研通知层',
        'workId': 'agent_9',
      },
    ]);
    await tester.pumpAndSettle();

    expect(find.textContaining('启动中 · 调研通知层'), findsOneWidget);
    expect(find.textContaining('运行中  调研通知层'), findsOneWidget);
  });

  // --------------------------------- subagent feed / terminal hysteresis

  /// Feeds a child-session state with the same frame shape the real
  /// subscription snapshot arrives in.
  void feedChildState(
    ConversationState child,
    String sessionId,
    List<Map<String, dynamic>> rows,
  ) {
    child.applyFrame({
      'toSeq': child.seq + 1,
      'payload': {
        'kind': 'snapshot',
        'snapshot': {
          'sessionId': sessionId,
          'logEpoch': 'ce1',
          'revision': 1,
          'rows': {
            'window': rows,
            'totalCount': rows.length,
            'firstRowId': (rows.first['rowId'] as num?)?.toInt(),
          },
        },
      },
    }, onGap: () => fail('unexpected gap'));
  }

  /// A full `kind=='subagent'` stream row (row.upserted replaces the whole
  /// row, so tests build it completely every time).
  Map<String, dynamic> subagentRow({
    required num rowId,
    required String status,
    String childSessionId = 'sess_child_1',
    String summaryText = '调研通知层',
  }) =>
      {
        'rowId': rowId,
        'kind': 'subagent',
        'childSessionId': childSessionId,
        'subagentType': 'Explore',
        'parentToolCallId': 'call_1',
        'status': status,
        'summaryText': summaryText,
        'workId': 'agent_1',
      };

  void upsertRows(FakeChatGateway gateway, List<Map<String, dynamic>> rows) {
    gateway.state.applyFrame({
      'toSeq': gateway.state.seq + 1,
      'payload': {
        'kind': 'deltas',
        'deltas': [
          for (final row in rows) {'op': 'row.upserted', 'row': row},
        ],
      },
    }, onGap: () => fail('unexpected gap'));
  }

  /// Patches the snapshot (state.updated) with a replayed `subagents.running`
  /// entry + matching works entry — the bridge-recovery replay shape.
  void pushRunningReplay(FakeChatGateway gateway) {
    final runningEntry = {
      'childSessionId': 'sess_child_1',
      'agentId': 'agent_1',
      'subagentType': 'Explore',
      'title': '调研通知层',
      'status': 'running',
      'startedAt': 1789279676224,
    };
    gateway.state.applyFrame({
      'toSeq': gateway.state.seq + 1,
      'payload': {
        'kind': 'deltas',
        'deltas': [
          {
            'op': 'state.updated',
            'patch': {
              'subagents': {
                'revision': 2,
                'childSessionIds': ['sess_child_1'],
                'running': [runningEntry],
              },
              'backgroundWorks': [
                {
                  ...runningEntry,
                  'kind': 'subagent',
                  'workId': 'agent_1',
                },
              ],
            },
          },
        ],
      },
    }, onGap: () => fail('unexpected gap'));
  }

  /// Opens the management sheet from the composer pill (finite pumps: the
  /// pill's breathing dot and sheet spinners never let pumpAndSettle settle).
  /// Opens the management sheet from the single background-tasks button.
  /// The button's tooltip varies with the live kind mix (terminal/agent/
  /// workflow/mixed), so match the official aria Semantics label instead.
  Future<void> openSubagentSheet(WidgetTester tester) async {
    await tester.tap(
      find.byWidgetPredicate(
        (w) =>
            w is Semantics &&
            (w.properties.label ?? '').startsWith('打开运行中的后台任务'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  testWidgets('management sheet streams the pooled child tail and opens the '
      'detail page', (tester) async {
    final gateway = _gatewayWithSubagentWork();
    final child = ConversationState();
    gateway.childStates['sess_child_1'] = child;
    await _pumpWithRunningSubagent(tester, gateway);

    // The sheet holds the pooled child subscription for its lifetime.
    await openSubagentSheet(tester);
    expect(
      gateway.subscribedSessions.where((s) => s == 'sess_child_1'),
      hasLength(1),
    );

    // Running section (official-aligned form): 2-line title row with the
    // whole row opening the detail page, red icon-only stop in its own
    // right column; no child toolCall yet → no tail line.
    expect(find.text('实现加固'), findsOneWidget);
    expect(find.text('详情'), findsNothing); // text buttons retired (D5)
    expect(find.byTooltip('停止'), findsOneWidget);
    expect(find.text('终端 · flutter test'), findsNothing);

    // Child tool progress streams into the live tail.
    feedChildState(child, 'sess_child_1', [
      {
        'rowId': 1,
        'kind': 'toolCall',
        'toolName': 'Bash',
        'status': 'running',
        'inputText': '{"command":"flutter test"}',
      },
    ]);
    await tester.pump();
    expect(find.text('终端 · flutter test'), findsOneWidget);

    // The whole running row opens the read-only child-session detail page.
    await tester.tap(find.text('实现加固'));
    await tester.pump(); // route push + subscribe microtask
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(SubagentDetailPage), findsOneWidget);
  });

  testWidgets('sheet stop confirms then cancels the parent background work', (
    tester,
  ) async {
    final gateway = _gatewayWithSubagentWork();
    await _pumpWithRunningSubagent(tester, gateway);

    await openSubagentSheet(tester);

    // Icon-only stop button (own right column) opens the confirm dialog.
    await tester.tap(find.byTooltip('停止'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('确定停止这个子智能体吗？'), findsOneWidget);

    // Cancelling the dialog must not fire the command.
    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // exit animation
    expect(
      gateway.calls.where((c) => c.$1 == 'cancelBackgroundWork'),
      isEmpty,
    );

    // Reopen the confirm dialog and go through with it.
    await tester.tap(find.byTooltip('停止'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.widgetWithText(FilledButton, '停止'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Parent session + the running entry's agentId (= workId, live-probed).
    final call = gateway.calls
        .where((c) => c.$1 == 'cancelBackgroundWork')
        .toList()
        .single;
    expect(call.$2, ['s1', 'agent_1']);
  });

  testWidgets('closing the management sheet releases the held child '
      'subscription (dispose-symmetric, chat-conventions §7)', (tester) async {
    final gateway = _gatewayWithSubagentWork();
    gateway.childStates['sess_child_1'] = ConversationState();
    await _pumpWithRunningSubagent(tester, gateway);

    await openSubagentSheet(tester);
    expect(
      gateway.subscribedSessions.where((s) => s == 'sess_child_1'),
      hasLength(1),
    );

    await tester.tap(find.byTooltip('关闭'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 50));

    // The sheet's dispose released its acquire (refcount 0 → async close).
    expect(gateway.closedSessions, contains('sess_child_1'));
    // The pill is untouched by the sheet close.
    expect(find.byTooltip('打开运行中的终端与智能体'), findsOneWidget);
  });

  testWidgets('inputStreaming child shows the 准备执行… tail in the sheet', (
    tester,
  ) async {
    final gateway = _gatewayWithSubagentWork();
    final child = ConversationState();
    gateway.childStates['sess_child_1'] = child;
    await _pumpWithRunningSubagent(tester, gateway);

    await openSubagentSheet(tester);
    feedChildState(child, 'sess_child_1', [
      {
        'rowId': 1,
        'kind': 'toolCall',
        'toolName': 'Bash',
        'status': 'inputStreaming',
        'inputText': '',
      },
    ]);
    await tester.pump();
    expect(find.text('准备执行…'), findsOneWidget);
  });

  testWidgets('sheet lists ended window rows and pages older subagent rows '
      'until hasMore is false', (tester) async {
    final gateway = FakeChatGateway()
      ..snapshotExtra = {
        'subagents': {
          'revision': 1,
          'childSessionIds': ['sess_child_1', 'sess_child_2', 'sess_child_9'],
          'running': [
            {
              'childSessionId': 'sess_child_1',
              'agentId': 'agent_1',
              'subagentType': 'general-purpose',
              'title': '实现加固',
              'status': 'running',
              'startedAt': 1789279676224,
            },
          ],
        },
      }
      ..rowsRangeResults.addAll([
        // Page 1 (cursor = oldest held row, 60): one more subagent + noise.
        {
          'hasMore': true,
          'atLogEpoch': 'e1',
          'rows': {
            'window': [
              {
                'rowId': 50,
                'kind': 'subagent',
                'childSessionId': 'sess_child_9',
                'subagentType': 'general-purpose',
                'status': 'stopped',
                'summaryText': '用量统计采集',
                'workId': 'agent_9',
              },
              {
                'rowId': 45,
                'kind': 'assistantText',
                'text': 'noise',
              },
            ],
          },
        },
        // Page 2 (cursor followed to 50): exhausted.
        {
          'hasMore': false,
          'atLogEpoch': 'e1',
          'rows': {'window': <Map<String, dynamic>>[]},
        },
      ]);
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 100, 'kind': 'userInput', 'text': '开工', 'state': 'done'},
      subagentRow(rowId: 101, status: 'running'),
      subagentRow(
        rowId: 60,
        status: 'failed',
        childSessionId: 'sess_child_2',
        summaryText: '索引重建',
      ),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await openSubagentSheet(tester);

    // Ended section: the in-window failed row (status word + title).
    expect(find.text('失败'), findsOneWidget);
    expect(find.text('索引重建'), findsOneWidget);

    // 「加载更早」 pages with the held-rows cursor.
    await tester.tap(find.text('加载更早'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已停止'), findsOneWidget);
    expect(find.text('用量统计采集'), findsOneWidget);

    await tester.tap(find.text('加载更早'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Cursors: the window head, then the collected page head — never the
    // placeholder.
    final rangeCalls =
        gateway.calls.where((c) => c.$1 == 'rowsRange').toList();
    expect(rangeCalls, hasLength(2));
    expect(rangeCalls[0].$2[1], 60);
    expect(rangeCalls[1].$2[1], 50);

    // Exhausted: the button collapses into the total line
    // (N = subagents.childSessionIds).
    expect(find.text('加载更早'), findsNothing);
    expect(find.text('已全部加载 · 共 3 个'), findsOneWidget);
  });

  testWidgets('sheet applies an epoch-drifted older page and toasts stale '
      '(round 23 generalized)', (tester) async {
    final gateway = FakeChatGateway()
      ..snapshotExtra = {
        'subagents': {
          'revision': 1,
          'childSessionIds': ['sess_child_1', 'sess_child_9'],
          'running': [
            {
              'childSessionId': 'sess_child_1',
              'agentId': 'agent_1',
              'subagentType': 'general-purpose',
              'title': '实现加固',
              'status': 'running',
              'startedAt': 1789279676224,
            },
          ],
        },
      }
      ..rowsRangeResults.addAll([
        // The page was answered on the OLD log epoch; the live state has
        // since advanced (streaming snapshot replay below).
        {
          'hasMore': false,
          'atLogEpoch': 'e1',
          'rows': {
            'window': [
              {
                'rowId': 50,
                'kind': 'subagent',
                'childSessionId': 'sess_child_9',
                'subagentType': 'general-purpose',
                'status': 'stopped',
                'summaryText': '用量统计采集',
                'workId': 'agent_9',
              },
            ],
          },
        },
      ]);
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 100, 'kind': 'userInput', 'text': '开工', 'state': 'done'},
      subagentRow(rowId: 101, status: 'running'),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await openSubagentSheet(tester);

    // The desktop advances the log epoch while streaming: a fresh snapshot
    // replay (same content, new epoch) lands while the page sits queued.
    gateway.state.applyFrame({
      'toSeq': gateway.state.seq + 1,
      'payload': {
        'kind': 'snapshot',
        'snapshot': {
          'sessionId': 's1',
          'logEpoch': 'e2',
          'revision': 4,
          'rows': {
            'window': [
              {
                'rowId': 100,
                'kind': 'userInput',
                'text': '开工',
                'state': 'done',
              },
              subagentRow(rowId: 101, status: 'running'),
            ],
            'totalCount': 2,
          },
          ...gateway.snapshotExtra,
        },
      },
    }, onGap: () => fail('unexpected gap'));
    await tester.pump();

    await tester.tap(find.text('加载更早'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // The drifted page still lands (rows are immutable log entries)…
    expect(find.text('已停止'), findsOneWidget);
    expect(find.text('用量统计采集'), findsOneWidget);
    expect(find.text('已全部加载 · 共 2 个'), findsOneWidget);
    // …and the drift leaves a toast trace.
    expect(find.text('会话数据已刷新，请重试'), findsOneWidget);
  });

  testWidgets('sheet drops the in-flight page silently when the sheet is '
      'torn down mid-fetch (state replaced / unmounted)', (tester) async {
    final transport = _SequencedRowsTransport();
    final held = Completer<dynamic>();
    transport.queue.add(held);
    final gateway = _SequencedRowsGateway(transport)
      ..snapshotExtra = {
        'subagents': {
          'revision': 1,
          'childSessionIds': ['sess_child_1'],
          'running': [
            {
              'childSessionId': 'sess_child_1',
              'agentId': 'agent_1',
              'subagentType': 'general-purpose',
              'title': '实现加固',
              'status': 'running',
              'startedAt': 1789279676224,
            },
          ],
        },
      };
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 100, 'kind': 'userInput', 'text': '开工', 'state': 'done'},
      subagentRow(rowId: 101, status: 'running'),
      subagentRow(
        rowId: 60,
        status: 'failed',
        childSessionId: 'sess_child_2',
        summaryText: '索引重建',
      ),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await openSubagentSheet(tester);
    await tester.tap(find.text('加载更早'));
    await tester.pump();
    expect(transport.calls, [60], reason: 'fetch is parked on the held page');

    // The sheet closes while the fetch hangs (the user navigates away /
    // the host swaps state underneath) — the page belongs to nobody now.
    await tester.tap(find.byTooltip('关闭'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    held.complete({
      'hasMore': false,
      'atLogEpoch': 'e1',
      'rows': {
        'window': [
          {
            'rowId': 50,
            'kind': 'subagent',
            'childSessionId': 'sess_child_9',
            'subagentType': 'general-purpose',
            'status': 'stopped',
            'summaryText': '用量统计采集',
            'workId': 'agent_9',
          },
        ],
      },
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // Silent: no toast fires from the dead sheet.
    expect(find.text('会话数据已刷新，请重试'), findsNothing);
    expect(find.text('用量统计采集'), findsNothing);
  });

  testWidgets('sheet auto-closes after all-terminal holds past the confirm '
      'window', (tester) async {
    final gateway = _gatewayWithSubagentOnlyWork();
    await tester.pumpWidget(
      wrap(ChatPage(
        host: gateway,
        sessionId: 's1',
        title: 't',
        turnFooterConfirmWindow: const Duration(milliseconds: 150),
      )),
    );
    gateway.feedSnapshot([subagentRow(rowId: 3, status: 'running')]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await openSubagentSheet(tester);
    expect(find.text('运行中的后台任务'), findsOneWidget); // sheet header

    // Everything goes terminal: the running section empties immediately,
    // but the sheet itself holds through the confirm window…
    upsertRows(gateway, [subagentRow(rowId: 3, status: 'success')]);
    await tester.pump();
    expect(find.text('运行中的后台任务'), findsOneWidget); // header still up
    expect(find.text('实现加固'), findsNothing); // running section emptied

    // …then it closes itself (and the composer button dies with it).
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('运行中的后台任务'), findsNothing);
    expect(find.byTooltip('打开运行中的智能体'), findsNothing);
  });

  testWidgets('pill is destroyed after all-terminal holds past the confirm '
      'window', (tester) async {
    final gateway = _gatewayWithSubagentOnlyWork();
    await tester.pumpWidget(
      wrap(ChatPage(
        host: gateway,
        sessionId: 's1',
        title: 't',
        turnFooterConfirmWindow: const Duration(milliseconds: 150),
      )),
    );
    gateway.feedSnapshot([subagentRow(rowId: 3, status: 'running')]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byTooltip('打开运行中的智能体'), findsOneWidget);

    // All terminal: the button survives the anti-replay window…
    upsertRows(gateway, [subagentRow(rowId: 3, status: 'success')]);
    await tester.pump();
    expect(find.byTooltip('打开运行中的智能体'), findsOneWidget);

    // …and is destroyed once the window has passed.
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byTooltip('打开运行中的智能体'), findsNothing);
  });

  testWidgets('management sheet renders 终端/工作流/子智能体 partitions',
      (tester) async {
    final gateway = FakeChatGateway()
      ..snapshotExtra = {
        'subagents': {
          'revision': 1,
          'childSessionIds': ['sess_child_1'],
          'running': [
            {
              'childSessionId': 'sess_child_1',
              'agentId': 'agent_1',
              'subagentType': 'general-purpose',
              'title': '实现加固',
              'status': 'running',
              'startedAt': 1789279676224,
            },
          ],
        },
        'backgroundWorks': [
          {
            'workId': 'bash_1',
            'kind': 'bash',
            'title': 'Download Flutter SDK',
            'status': 'running',
            'cancellable': true,
          },
          {
            'workId': 'wf_1',
            'kind': 'workflow',
            'title': '审计依赖',
            'status': 'running',
            'cancellable': true,
          },
          {
            'workId': 'agent_1',
            'kind': 'subagent',
            'title': '实现加固',
            'status': 'running',
            'childSessionId': 'sess_child_1',
          },
        ],
        // The workflow row's progress joins the background work to its run
        // (best-effort via workId → runId: the wire carries no explicit link).
        'workflowRuns': {
          'revision': 4,
          'runs': [
            {
              'runId': 'wf_1',
              'status': 'running',
              'usage': {'spentTokens': 0, 'nodesUsed': 2},
              'lastEventSequence': 7,
              'actors': [
                {'siteId': 's', 'ordinal': 0, 'status': 'running'},
              ],
              'nodes': [
                {'siteId': 's', 'ordinal': 0, 'phase': 'settled'},
                {'siteId': 's', 'ordinal': 1, 'phase': 'executing'},
              ],
            },
          ],
        },
      };
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      subagentRow(rowId: 9, status: 'running'),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await openSubagentSheet(tester);

    // Three partition labels, each with its running count.
    expect(find.text('终端 · 1'), findsOneWidget);
    expect(
      find.text('${chatLabel('chat.bgSheet.sectionWorkflow')} · 1'),
      findsOneWidget,
    );
    expect(find.text('子智能体 · 1'), findsOneWidget);
    // One row per partition.
    expect(find.text('Download Flutter SDK'), findsOneWidget);
    expect(find.text('审计依赖'), findsOneWidget);
    expect(find.text('实现加固'), findsOneWidget);
    // workflowRuns mirror → progress line (nodesSettled/nodesTotal · actors).
    expect(find.text('1/2 节点 · 1 个智能体'), findsOneWidget);
    // The retired works bar is not part of the management surface.
    expect(find.textContaining('后台任务 1 个运行中'), findsNothing);
  });

  testWidgets('management sheet lists ended workflow runs after running '
      'works (wire order, deduped against live works)', (tester) async {
    final gateway = FakeChatGateway()
      ..snapshotExtra = {
        'backgroundWorks': [
          {
            'workId': 'wf_live',
            'kind': 'workflow',
            'title': '审计依赖',
            'status': 'running',
            'cancellable': true,
            'startedAt': 1789279676224,
          },
          {
            // The run behind this work is terminal, but the work itself is
            // live: the live row owns it (toolCallId join), no ended repeat.
            'workId': 'call_joined',
            'kind': 'workflow',
            'title': '会话内运行',
            'status': 'running',
            'cancellable': true,
          },
        ],
        'workflowRuns': {
          'revision': 6,
          'runs': [
            {
              'runId': 'wf_live',
              'status': 'running',
              'nodes': [
                {'siteId': 's', 'ordinal': 0, 'phase': 'settled'},
                {'siteId': 's', 'ordinal': 1, 'phase': 'executing'},
              ],
              'actors': [
                {'siteId': 's', 'ordinal': 0, 'status': 'running'},
              ],
            },
            {
              'runId': 'wf_joined',
              'toolCallId': 'call_joined',
              'status': 'completed',
            },
            {
              'runId': 'wf_done',
              'toolCallId': 'call_done',
              'status': 'completed',
              'nodes': [
                {'siteId': 's', 'ordinal': 0, 'phase': 'settled'},
                {'siteId': 's', 'ordinal': 1, 'phase': 'settled'},
              ],
              'actors': [
                {'siteId': 's', 'ordinal': 0, 'status': 'completed'},
                {'siteId': 's', 'ordinal': 1, 'status': 'completed'},
              ],
            },
            {
              'runId': 'wf_err',
              'toolCallId': 'call_err',
              'status': 'errored',
              'nodes': [
                {'siteId': 's', 'ordinal': 0, 'phase': 'settled'},
                {'siteId': 's', 'ordinal': 1, 'phase': 'executing'},
              ],
            },
            {'runId': 'wf_stop', 'status': 'stopped'},
            // Neither running nor terminal → neither partition.
            {'runId': 'wf_pending', 'status': 'pending'},
          ],
        },
      };
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '跑工作流'},
      {
        'rowId': 2,
        'kind': 'toolCall',
        'toolName': 'CreateWorkflow',
        'toolCallId': 'call_done',
        'status': 'success',
        'inputText': '{"name":"依赖审计收尾"}',
      },
      {
        'rowId': 3,
        'kind': 'toolCall',
        'toolName': 'CreateWorkflow',
        'toolCallId': 'call_err',
        'status': 'success',
        'inputText': '{"name":"构建发布"}',
      },
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await openSubagentSheet(tester);
    final sheet = find.byType(BottomSheet);

    // Section count = running + ended; the deduped and pending runs are in
    // neither partition.
    expect(
      find.text('${chatLabel('chat.bgSheet.sectionWorkflow')} · 5'),
      findsOneWidget,
    );
    expect(
      find.text(chatLabel('chat.subagentSheet.sectionEnded')),
      findsOneWidget,
    );

    // Running rows first, in the works order.
    final live = find.descendant(of: sheet, matching: find.text('审计依赖'));
    final joined = find.descendant(of: sheet, matching: find.text('会话内运行'));
    expect(live, findsOneWidget);
    expect(joined, findsOneWidget);
    expect(tester.getTopLeft(live).dy, lessThan(tester.getTopLeft(joined).dy));

    // Ended rows follow in mirror wire order (never re-sorted: run
    // snapshots carry no timestamp).
    final done = find.descendant(of: sheet, matching: find.text('依赖审计收尾'));
    final err = find.descendant(of: sheet, matching: find.text('构建发布'));
    final stop = find.descendant(
      of: sheet,
      matching: find.text(chatLabel('chat.workflowDetail.titleFallback')),
    );
    expect(done, findsOneWidget);
    expect(err, findsOneWidget);
    // Exactly one fallback title = the deduped joined run was excluded.
    expect(stop, findsOneWidget);
    expect(tester.getTopLeft(joined).dy, lessThan(tester.getTopLeft(done).dy));
    expect(tester.getTopLeft(done).dy, lessThan(tester.getTopLeft(err).dy));
    expect(tester.getTopLeft(err).dy, lessThan(tester.getTopLeft(stop).dy));

    // Status glyphs + progress caption (zero-valued parts omitted).
    expect(
      find.descendant(of: sheet, matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sheet, matching: find.byIcon(Icons.stop)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: sheet,
        matching: find.text(
          '${chatLabel('chat.workflowCard.steps', ['2', '2'])} · '
          '${chatLabel('chat.workflowCard.agents', ['2'])}',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: sheet,
        matching: find.text(chatLabel('chat.workflowCard.steps', ['1', '2'])),
      ),
      findsOneWidget,
    );
  });

  testWidgets('clicking a running workflow row opens the detail page',
      (tester) async {
    final gateway = FakeChatGateway()
      ..snapshotExtra = {
        'backgroundWorks': [
          {
            'workId': 'wf_live',
            'kind': 'workflow',
            'title': '审计依赖',
            'status': 'running',
            'cancellable': true,
            'startedAt': 1789279676224,
          },
        ],
        'workflowRuns': {
          'revision': 1,
          'runs': [
            {'runId': 'wf_live', 'status': 'running'},
          ],
        },
      };
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '跑工作流'},
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await openSubagentSheet(tester);
    await tester.tap(find.text('审计依赖'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(WorkflowRunPage), findsOneWidget);
  });

  testWidgets('auto-close behind the detail page removes only the sheet', (
    tester,
  ) async {
    final gateway = FakeChatGateway()
      ..snapshotExtra = {
        'backgroundWorks': [
          {
            'workId': 'wf_live',
            'kind': 'workflow',
            'title': '审计依赖',
            'status': 'running',
            'cancellable': true,
            'startedAt': 1789279676224,
          },
        ],
        'workflowRuns': {
          'revision': 1,
          'runs': [
            {'runId': 'wf_live', 'status': 'running'},
          ],
        },
      };
    await tester.pumpWidget(
      wrap(
        ChatPage(
          host: gateway,
          sessionId: 's1',
          title: 't',
          turnFooterConfirmWindow: const Duration(milliseconds: 150),
        ),
      ),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '跑工作流'},
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await openSubagentSheet(tester);
    final sheetRoute = ModalRoute.of(
      tester.element(find.byType(BottomSheet)),
    )!;
    await tester.tap(find.text('审计依赖'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(WorkflowRunPage), findsOneWidget);

    // Every running work goes terminal while the detail page sits above the
    // sheet; the auto-close timer fires behind it.
    gateway.state.applyFrame({
      'toSeq': gateway.state.seq + 1,
      'payload': {
        'kind': 'deltas',
        'deltas': [
          {
            'op': 'state.updated',
            'patch': {
              'backgroundWorks': [
                {
                  'workId': 'wf_live',
                  'kind': 'workflow',
                  'title': '审计依赖',
                  'status': 'completed',
                  'endedAt': 1789279677999,
                },
              ],
            },
          },
        ],
      },
    }, onGap: () => fail('unexpected gap'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 350));

    // pop() would have closed the detail page; only the sheet route is gone.
    expect(find.byType(WorkflowRunPage), findsOneWidget);
    expect(sheetRoute.isActive, isFalse);
    expect(find.byType(BottomSheet, skipOffstage: false), findsNothing);

    // Back from the detail page returns to the chat — the sheet must not
    // reappear from under it.
    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(WorkflowRunPage), findsNothing);
    expect(find.byType(BottomSheet, skipOffstage: false), findsNothing);
  });

  testWidgets('clicking an ended workflow row opens the detail page',
      (tester) async {
    final gateway = FakeChatGateway()
      ..snapshotExtra = {
        // A live bash work keeps the management entry visible; the ended
        // workflow run itself must not be what opens the sheet.
        'backgroundWorks': [
          {
            'workId': 'bash_1',
            'kind': 'bash',
            'title': 'flutter test',
            'status': 'running',
            'cancellable': true,
          },
        ],
        'workflowRuns': {
          'revision': 2,
          'runs': [
            {
              'runId': 'wf_done',
              'toolCallId': 'call_done',
              'status': 'completed',
            },
          ],
        },
      };
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '跑工作流'},
      {
        'rowId': 2,
        'kind': 'toolCall',
        'toolName': 'CreateWorkflow',
        'toolCallId': 'call_done',
        'status': 'success',
        'inputText': '{"name":"依赖审计收尾"}',
      },
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await openSubagentSheet(tester);
    // The chat tool card carries the same name — tap the sheet row.
    await tester.tap(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text('依赖审计收尾'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(WorkflowRunPage), findsOneWidget);
  });

  testWidgets('ended workflow rows never keep the sheet alive', (tester) async {
    final gateway = FakeChatGateway()
      ..snapshotExtra = {
        'backgroundWorks': [
          {
            'workId': 'bash_1',
            'kind': 'bash',
            'title': 'flutter test',
            'status': 'running',
            'cancellable': true,
          },
        ],
        'workflowRuns': {
          'revision': 2,
          'runs': [
            {
              'runId': 'wf_done',
              'status': 'completed',
              'nodes': [
                {'siteId': 's', 'ordinal': 0, 'phase': 'settled'},
              ],
            },
          ],
        },
      };
    await tester.pumpWidget(
      wrap(ChatPage(
        host: gateway,
        sessionId: 's1',
        title: 't',
        turnFooterConfirmWindow: const Duration(milliseconds: 150),
      )),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '跑工作流'},
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await openSubagentSheet(tester);
    expect(
      find.text(chatLabel('chat.subagentSheet.sectionEnded')),
      findsOneWidget,
    );

    // Every running work goes terminal; the ended run stays mirrored.
    gateway.state.applyFrame({
      'toSeq': gateway.state.seq + 1,
      'payload': {
        'kind': 'deltas',
        'deltas': [
          {
            'op': 'state.updated',
            'patch': {
              'backgroundWorks': [
                {
                  'workId': 'bash_1',
                  'kind': 'bash',
                  'title': 'flutter test',
                  'status': 'completed',
                  'endedAt': 1789279677999,
                },
              ],
            },
          },
        ],
      },
    }, onGap: () => fail('unexpected gap'));
    await tester.pump();
    expect(find.text('运行中的后台任务'), findsOneWidget);

    // The ended rows do not hold the sheet: the running-count gate closes
    // it after the confirm window.
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('运行中的后台任务'), findsNothing);
    expect(gateway.state.workflowRuns.views.single.status, 'completed');
  });

  testWidgets('workflow row ✕ still cancels the work without opening details',
      (tester) async {
    final gateway = FakeChatGateway()
      ..snapshotExtra = {
        'backgroundWorks': [
          {
            'workId': 'wf_live',
            'kind': 'workflow',
            'title': '审计依赖',
            'status': 'running',
            'cancellable': true,
            'startedAt': 1789279676224,
          },
        ],
        'workflowRuns': {
          'revision': 1,
          'runs': [
            {'runId': 'wf_live', 'status': 'running'},
          ],
        },
      };
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '跑工作流'},
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await openSubagentSheet(tester);
    // The inner ✕ owns the tap (gesture-arena inner win) — no detail push.
    await tester.tap(find.byTooltip('取消此后台任务'));
    await tester.pump();

    final call = gateway.calls
        .where((c) => c.$1 == 'cancelBackgroundWork')
        .toList()
        .single;
    expect(call.$2, ['s1', 'wf_live']);
    expect(find.byType(WorkflowRunPage), findsNothing);
  });

  testWidgets('slash bar folds subagents in as @name entries', (tester) async {
    final gateway = FakeChatGateway()
      ..mentionSubagentsResult = [
        {'name': 'explore', 'description': '调研代码'},
      ];
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '/exp');
    await tester.pump();

    // The shared capability list renders the subagent entry with its `@`
    // sigil (official `/` panel mixes commands/skills/subagents).
    expect(find.text('@explore'), findsOneWidget);
    await tester.tap(find.text('@explore'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final tf = tester.widget<TextField>(find.byType(TextField).first);
    expect(tf.controller!.text, '@explore ');
  });

  testWidgets('a replayed running subagent inside the hysteresis window '
      'never revives the pill', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(
        host: gateway,
        sessionId: 's1',
        title: 't',
        subagentHysteresis: const Duration(milliseconds: 150),
        turnFooterConfirmWindow: const Duration(milliseconds: 150),
      )),
    );
    gateway.feedSnapshot([subagentRow(rowId: 3, status: 'success')]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    // Terminal from the start: no pill, even after the confirm window.
    expect(find.byTooltip('打开运行中的终端与智能体'), findsNothing);

    // Bridge-recovery replay: subagents.running (+ the matching works
    // entry) reports the finished subagent as running again. The hysteresis
    // view keeps the terminal status → no pill.
    pushRunningReplay(gateway);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byTooltip('打开运行中的终端与智能体'), findsNothing);
    // The expiry side (persisted running believed after the window) is
    // covered by the SubagentFeed unit test — Future.delayed cannot advance
    // real time inside testWidgets.
  });

  testWidgets('load-older pages from the oldest held row, not the placeholder '
      'snapshot firstRowId', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    // Snapshot carries the placeholder firstRowId=1 while the window sits
    // at rows 100+ (live-probed trap).
    gateway.feedSnapshot(
      [
        {'rowId': 100, 'kind': 'userInput', 'text': '近期消息', 'state': 'done'},
        {'rowId': 101, 'kind': 'assistantText', 'text': '回复', 'state': 'done'},
      ],
      firstRowId: 1,
      totalCount: 160,
    );
    gateway.rowsRangeResults.addAll([
      {
        'hasMore': true,
        'atLogEpoch': 'e1',
        'rows': {
          'window': [
            for (var id = 40; id <= 99; id++)
              {'rowId': id, 'kind': 'assistantText', 'text': '更早 $id'},
          ],
          'firstRowId': 1, // placeholder again — must be ignored
        },
      },
      {
        'hasMore': false,
        'atLogEpoch': 'e1',
        'rows': {
          'window': [
            {'rowId': 39, 'kind': 'userInput', 'text': '最早', 'state': 'done'},
          ],
        },
      },
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final controller =
        tester.widget<ListView>(messageList()).controller!;
    // Trigger via the pull gesture rather than a button tap: the tap's
    // gesture-arena routing is unreliable in this fixture's frame schedule
    // (armed → prepend post-frame → landing), while the pull drives the
    // same _loadOlder entry the tap's onPressed would.
    Future<void> loadOlderViaPull() async {
      controller.jumpTo(0);
      await tester.pump();
      final gesture = await tester.startGesture(
        tester.getCenter(messageList()),
      );
      await tester.pump();
      await gesture.moveBy(const Offset(0, 300));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      await tester.pumpAndSettle();
    }

    await loadOlderViaPull();
    await loadOlderViaPull();

    // Cursors: the oldest HELD row (100), then the prepended window head
    // (40) — strictly older pages, placeholder firstRowId never used.
    final rangeCalls =
        gateway.calls.where((c) => c.$1 == 'rowsRange').toList();
    expect(rangeCalls, hasLength(2));
    expect(rangeCalls[0].$2[1], 100);
    expect(rangeCalls[1].$2[1], 40);

    // hasMore=false collapsed the affordance.
    expect(find.text('加载更早消息'), findsNothing);
    // The last page's row landed in the list (the compensation anchors the
    // view wherever the reader was, so check at the top where it's built).
    controller.jumpTo(0);
    await tester.pump();
    expect(find.text('最早'), findsOneWidget);
  });

  testWidgets('subagent tile holds 已完成 across a replayed running report '
      'inside the hysteresis window', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(
        host: gateway,
        sessionId: 's1',
        title: 't',
        subagentHysteresis: const Duration(milliseconds: 150),
      )),
    );
    gateway.feedSnapshot([subagentRow(rowId: 3, status: 'success')]);
    await tester.pumpAndSettle();
    expect(find.textContaining('已完成  调研通知层'), findsOneWidget);

    // Bridge-recovery replay: the finished subagent reports running again.
    // The hysteresis is real-time based (notification_hub semantics), so
    // inside the window the tile keeps the terminal caption. The expiry
    // (persisted running is believed) is covered by the SubagentFeed unit
    // test — Future.delayed cannot advance real time inside testWidgets.
    upsertRows(gateway, [subagentRow(rowId: 3, status: 'running')]);
    await tester.pump();
    expect(find.textContaining('已完成  调研通知层'), findsOneWidget);
    expect(find.textContaining('运行中  调研通知层'), findsNothing);
  });

  testWidgets('agent expansion renders the pooled child transcript inline', (
    tester,
  ) async {
    final gateway = FakeChatGateway();
    final child = ConversationState();
    gateway.childStates['sess_child_1'] = child;
    feedChildState(child, 'sess_child_1', [
      // Spawn-time model switch the desktop logs into the child log —
      // the inline window drops it (acceptance fix: the model is the
      // detail page's subtitle, not a transcript row).
      {
        'rowId': 0,
        'kind': 'timelineMarker',
        'marker': {
          'type': 'modelChange',
          'fromModel': 'glm-5.2',
          'toModel': 'glm-5.2-air',
        },
      },
      {'rowId': 1, 'kind': 'userInput', 'text': '子任务提示'},
      {'rowId': 2, 'kind': 'assistantText', 'text': '子会话结论：完成'},
    ]);
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '去调研'},
      {
        'rowId': 2,
        'kind': 'toolCall',
        'toolName': 'Agent',
        'toolCallId': 'call_1',
        'status': 'success',
        'inputText':
            '{"description":"调研通知层","prompt":"p","subagent_type":"Explore"}',
      },
      {
        'rowId': 3,
        'kind': 'subagent',
        'parentToolCallId': 'call_1',
        'childSessionId': 'sess_child_1',
        'subagentType': 'Explore',
        'status': 'success',
        'summaryText': '调研通知层',
        'workId': 'agent_1',
      },
    ]);
    await tester.pumpAndSettle();

    // Expansion mounts the inline transcript: pooled subscription (ONE for
    // the whole tree) + child rows + 「输出」preview of the last text.
    await tester.tap(find.textContaining('已启动 · 调研通知层'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      gateway.subscribedSessions.where((s) => s == 'sess_child_1'),
      hasLength(1),
    );
    expect(find.text('子任务提示'), findsOneWidget);
    expect(find.textContaining('子会话结论'), findsWidgets);
    expect(find.text('输出'), findsOneWidget);
    expect(find.textContaining('模型已切换'), findsNothing); // marker dropped
  });

  testWidgets('agent expansion stays at the window over a grown pooled state',
      (tester) async {
    // The detail page's loadOlder prepends older rows into the POOLED child
    // state; the inline timeline must keep rendering only the tail window
    // (60 = snapshot/rowsRange window) — official parity, live-certified
    // 2026-10-08 (the web inline shows parent-window mirror rows only).
    final gateway = FakeChatGateway();
    final child = ConversationState();
    gateway.childStates['sess_child_1'] = child;
    feedChildState(child, 'sess_child_1', [
      for (var i = 1; i <= 80; i++)
        {'rowId': i, 'kind': 'assistantText', 'text': 'row$i'},
    ]);
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '去调研'},
      {
        'rowId': 2,
        'kind': 'toolCall',
        'toolName': 'Agent',
        'toolCallId': 'call_1',
        'status': 'success',
        'inputText':
            '{"description":"调研通知层","prompt":"p","subagent_type":"Explore"}',
      },
      {
        'rowId': 3,
        'kind': 'subagent',
        'parentToolCallId': 'call_1',
        'childSessionId': 'sess_child_1',
        'subagentType': 'Explore',
        'status': 'success',
        'summaryText': '调研通知层',
        'workId': 'agent_1',
      },
    ]);
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('已启动 · 调研通知层'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // 80 rows in the pooled state, 60 in the inline window: the oldest 20
    // stay detail-page-only. Boundary asserted by text (the shared ChatRow
    // also renders the page's own rows, so a type count is brittle).
    expect(find.text('row1'), findsNothing);
    expect(find.text('row21'), findsOneWidget); // oldest in-window row
    expect(find.text('row80'), findsWidgets);
  });

  testWidgets('turn terminal footer waits for the confirm window', (
    tester,
  ) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(
        host: gateway,
        sessionId: 's1',
        title: 't',
        turnFooterConfirmWindow: const Duration(milliseconds: 150),
      )),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
      {
        'rowId': 2,
        'kind': 'assistantText',
        'text': '回答中',
        'state': 'streaming',
      },
      {'rowId': 3, 'kind': 'turnHeader', 'state': 'running'},
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('已完成'), findsNothing);

    // Terminal blip: the header flips completed and the text stops
    // streaming — inside the window neither the pill nor the feedback row
    // may appear (user-reported flash of 「已结束」+ buttons mid-session).
    upsertRows(gateway, [
      {'rowId': 2, 'kind': 'assistantText', 'text': '回答完毕'},
      {
        'rowId': 3,
        'kind': 'turnHeader',
        'state': 'completedSuccess',
        'activeMs': 65000,
      },
    ]);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已完成'), findsNothing);
    expect(find.byIcon(Icons.thumb_up_alt_outlined), findsNothing);

    // Persisted past the window → footer + feedback render.
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('已完成'), findsOneWidget);
    expect(find.byIcon(Icons.thumb_up_alt_outlined), findsOneWidget);
  });

  testWidgets('a terminal blip that reverts inside the window never renders '
      'the footer', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(
        host: gateway,
        sessionId: 's1',
        title: 't',
        turnFooterConfirmWindow: const Duration(milliseconds: 150),
      )),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
      {
        'rowId': 2,
        'kind': 'assistantText',
        'text': '回答中',
        'state': 'streaming',
      },
      {'rowId': 3, 'kind': 'turnHeader', 'state': 'running'},
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    upsertRows(gateway, [
      {
        'rowId': 3,
        'kind': 'turnHeader',
        'state': 'completedSuccess',
        'activeMs': 65000,
      },
    ]);
    await tester.pump(const Duration(milliseconds: 50));
    // The session lives on: the header reverts to running inside the window.
    upsertRows(gateway, [
      {'rowId': 3, 'kind': 'turnHeader', 'state': 'running'},
    ]);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('已完成'), findsNothing);
    expect(find.text('运行中'), findsOneWidget);
    expect(find.byIcon(Icons.thumb_up_alt_outlined), findsNothing);
  });

  // ---------------------------------------------- plan quota warning

  /// Entitlement snapshot with the top-level `remaining` block plus an
  /// optional token-class quota limit (the only limit kind that drives the
  /// banner — TIME_LIMIT is the monthly MCP quota and must not).
  EntitlementView okQuota(
    Map<String, dynamic> remaining, {
    double? tokenPercentage,
  }) =>
      EntitlementView(
        phase: EntitlementPhase.ok,
        data: {
          'authenticated': true,
          'provider': {'id': 'prov-1', 'name': 'BigModel'},
          'remaining': remaining,
          'quota': tokenPercentage == null
              ? null
              : {
                  'limits': [
                    {
                      'type': 'TOKENS_LIMIT',
                      'unit': 3,
                      'number': 5,
                      'percentage': tokenPercentage,
                    },
                  ],
                },
          'subscription': null,
        },
      );

  /// Start-plan snapshot (task 10-24 C, research §7): the normalized Start
  /// row carries the USED percent, so a drained bucket reads `exhausted`.
  EntitlementView startPlanExhausted() => EntitlementView(
        phase: EntitlementPhase.ok,
        data: {
          'authenticated': true,
          'provider': {'id': 'account:zai-start-plan', 'name': 'Start Plan'},
          'remaining': {'count': 0, 'isShow': true, 'percentage': 0},
          'quota': {
            'level': 'Start',
            'limits': [
              {'type': 'ent-start-1', 'percentage': 100},
            ],
          },
        },
      );

  /// Expired Start-plan shape: provider stays, quota/remaining are empty and
  /// `startPlanExpired` is the only terminal marker.
  EntitlementView startPlanExpired() => EntitlementView(
        phase: EntitlementPhase.ok,
        data: {
          'authenticated': true,
          'provider': {'id': 'account:zai-start-plan', 'name': 'Start Plan'},
          'remaining': null,
          'quota': null,
          'subscription': null,
          'unavailableReason': 'no_plan',
          'startPlanExpired': true,
        },
      );

  /// Snapshot-level config for a live Start-plan session (auto switch input).
  Map<String, dynamic> startPlanConfig({String model = 'GLM-5.3'}) => {
        'config': {
          'provider': 'account:zai-start-plan',
          'model': model,
          'thought': 'enabled',
          'mode': 'build',
        },
      };

  Future<void> pumpWithQuota(
    WidgetTester tester,
    FakeChatGateway gateway, {
    void Function()? onOpenUsage,
  }) async {
    await tester.pumpWidget(wrap(ChatPage(
      host: gateway,
      sessionId: 's1',
      title: 't',
      onOpenUsage: onOpenUsage,
    )));
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();
  }

  testWidgets('monthly MCP TIME_LIMIT exhaustion does not raise the banner '
      '(bug 09-15)', (tester) async {
    // Reported symptom: TIME_LIMIT (search-prime 100/101) topped out and
    // `remaining` matching it at 0, token window at 51% → no banner.
    final gateway = FakeChatGateway()
      ..entitlementResult = EntitlementView(
        phase: EntitlementPhase.ok,
        data: {
          'authenticated': true,
          'provider': {'id': 'prov-1', 'name': 'BigModel'},
          'remaining': {'count': 0, 'percentage': 100, 'isShow': true},
          'quota': {
            'limits': [
              {'type': 'TIME_LIMIT', 'unit': 5, 'number': 1, 'percentage': 100},
              {'type': 'TOKENS_LIMIT', 'unit': 3, 'number': 5, 'percentage': 51},
            ],
          },
          'subscription': null,
        },
      );
    await pumpWithQuota(tester, gateway);

    expect(gateway.entitlementCalls, 1);
    expect(find.text('套餐额度已用尽'), findsNothing);
    expect(find.text('切换模型'), findsNothing);
  });

  testWidgets('top-level remaining at 100% alone does not raise the banner', (
    tester,
  ) async {
    final gateway = FakeChatGateway()
      ..entitlementResult = okQuota({
        'count': 0,
        'percentage': 100,
        'isShow': true,
      });
    await pumpWithQuota(tester, gateway);

    expect(gateway.entitlementCalls, 1);
    expect(find.text('套餐额度已用尽'), findsNothing);
  });

  testWidgets('exhausted token limit shows the warning banner with actions', (
    tester,
  ) async {
    var openedUsage = false;
    final gateway = FakeChatGateway()
      ..entitlementResult = okQuota(
        {'count': 0, 'percentage': 100, 'isShow': true},
        tokenPercentage: 100,
      );
    await pumpWithQuota(
      tester,
      gateway,
      onOpenUsage: () => openedUsage = true,
    );
    expect(find.text('套餐额度已用尽'), findsOneWidget);
    expect(find.textContaining('已用尽或受限'), findsOneWidget);

    // 查看用量 jumps through the injected callback.
    await tester.tap(find.text('查看用量'));
    await tester.pump();
    expect(openedUsage, isTrue);

    // 切换模型 opens the existing model sheet.
    await tester.tap(find.text('切换模型'));
    await tester.pumpAndSettle();
    expect(find.textContaining('GLM-5.2'), findsWidgets);
  });

  testWidgets('expired Start-plan snapshot lights the warning banner with '
      'expiry copy (previously silent)', (tester) async {
    final gateway = FakeChatGateway()..entitlementResult = startPlanExpired();
    await pumpWithQuota(tester, gateway);

    expect(find.text('套餐已到期'), findsOneWidget);
    expect(find.text('当前套餐已到期，可切换模型继续'), findsOneWidget);
    // The exhausted wording would be wrong for an expiry.
    expect(find.text('套餐额度已用尽'), findsNothing);
    expect(find.textContaining('已用尽或受限'), findsNothing);
    // Manual entries stay.
    expect(find.text('切换模型'), findsOneWidget);
  });

  testWidgets('healthy quota snapshot clears the banner on the next open', (
    tester,
  ) async {
    final gateway = FakeChatGateway()
      ..entitlementResult = okQuota(
        {'count': 0, 'percentage': 100, 'isShow': true},
        tokenPercentage: 100,
      );
    await pumpWithQuota(tester, gateway);
    expect(find.text('套餐额度已用尽'), findsOneWidget);

    // Shared poller refreshed to healthy; the page reopens (fresh state).
    gateway.entitlementResult = okQuota(
      {'count': 12, 'percentage': 40, 'isShow': true},
      tokenPercentage: 40,
    );
    await tester.pumpWidget(wrap(ChatPage(
      key: UniqueKey(),
      host: gateway,
      sessionId: 's1',
      title: 't',
    )));
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    expect(find.text('套餐额度已用尽'), findsNothing);
  });

  // ------------------------------------------ banner reset action (R2)

  testWidgets('exhausted banner hides the reset action without '
      'opportunities', (tester) async {
    final gateway = FakeChatGateway()
      ..entitlementResult = okQuota(
        {'count': 0, 'percentage': 100, 'isShow': true},
        tokenPercentage: 100,
      );
    // Default quotaStatusResult: null → no usable pools data.
    await pumpWithQuota(tester, gateway);

    expect(find.text('套餐额度已用尽'), findsOneWidget);
    expect(find.text('使用重置券'), findsNothing);
  });

  testWidgets('exhausted banner is warning-only: no「使用重置券」even with '
      'opportunities (entry moved to the usage sheet)', (tester) async {
    final gateway = FakeChatGateway()
      ..entitlementResult = okQuota(
        {'count': 0, 'percentage': 100, 'isShow': true},
        tokenPercentage: 100,
      )
      ..quotaStatusResult = {
        'availableFiveHourResets': [
          {
            'expireAt':
                DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
          },
        ],
        'availableWeekResets': <Map<String, dynamic>>[],
      };
    await pumpWithQuota(tester, gateway);

    expect(find.text('套餐额度已用尽'), findsOneWidget);
    expect(find.text('使用重置券'), findsNothing);
    expect(gateway.useQuotaCalls, isEmpty);
  });

  testWidgets('usage sheet reset entry consumes one opportunity and flips '
      'the banner off with the refreshed entitlement', (tester) async {
    final gateway = FakeChatGateway()
      ..entitlementResult = okQuota(
        {'count': 0, 'percentage': 100, 'isShow': true},
        tokenPercentage: 100,
      )
      ..quotaStatusResult = {
        'availableFiveHourResets': [
          {
            'expireAt':
                DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
          },
        ],
        'availableWeekResets': <Map<String, dynamic>>[],
      };
    await pumpWithQuota(tester, gateway);

    // More menu → 用量统计 opens the upgraded usage sheet.
    await tester.tap(find.text('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('用量统计'));
    await tester.pumpAndSettle();
    // Remaining-quota block (R4): the aggregated reset-credit row is the
    // single reset entry (the per-pool lines were dropped in the restyle).
    // 2026-09-16 semantics: the row carries the earliest coupon expiry.
    expect(find.text('剩余额度'), findsOneWidget);
    expect(find.textContaining('可用 1 张'), findsOneWidget);
    expect(find.textContaining('最早'), findsOneWidget);
    expect(find.text('使用重置券'), findsOneWidget);

    await tester.tap(find.text('使用重置券'));
    await tester.pumpAndSettle();
    // Dialog shape: pool rows + counts + expiry + cancel/reset.
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining('1 张'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('取消'),
      ),
      findsOneWidget,
    );

    // Fresh entitlement for the post-reset confirmation refresh.
    gateway.entitlementResult = okQuota(
      {'count': 12, 'percentage': 40, 'isShow': true},
      tokenPercentage: 40,
    );
    final entitlementCallsBefore = gateway.entitlementCalls;
    await tester.tap(find.text('重置'));
    await tester.pumpAndSettle();

    expect(gateway.useQuotaCalls, hasLength(1));
    final (type, providerId, key) = gateway.useQuotaCalls.single;
    expect(type, 'FIVE_HOUR');
    expect(providerId, 'prov-1');
    expect(key, isNotEmpty);
    // The controller's success chain + the banner re-read both hit the
    // entitlement gateway.
    expect(
      gateway.entitlementCalls,
      greaterThanOrEqualTo(entitlementCallsBefore + 2),
    );
    // Banner flips off with the refreshed healthy snapshot.
    expect(find.text('套餐额度已用尽'), findsNothing);
  });

  // The usage-sheet / dialog pool rules (V1 weekly hiding, untouched-window
  // hiding, inline window clock + earliest coupon expiry) are asserted
  // against the projection in test/state/entitlement_projection_test.dart;
  // the test above stays as the wiring smoke (sheet → dialog → use →
  // refresh → banner flip).

  testWidgets('reset dialog degrades to the「暂无可用机会」copy when the '
      'caller finds no resettable pool (defensive)', (tester) async {
    final gateway = FakeChatGateway()
      ..quotaStatusResult = {
        'availableFiveHourResets': [
          {
            'expireAt': DateTime.now()
                .add(const Duration(hours: 1))
                .millisecondsSinceEpoch,
          },
        ],
        'availableWeekResets': <Map<String, dynamic>>[],
      };
    final controller = QuotaResetController(gateway: gateway);
    addTearDown(controller.dispose);
    controller.updateScope('prov-1');
    await controller.refresh();

    await tester.pumpWidget(wrap(Builder(
      builder: (context) => TextButton(
        onPressed: () => showQuotaResetDialog(
          context,
          controller: controller,
          resettable: const {},
        ),
        child: const Text('open'),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('暂无可用机会')),
        findsOneWidget);
    expect(find.text('重置'), findsNothing);
  });

  // ------------------- edit & resend dialog + keyboard overflow
  // (PRD internal-task R1/R2)

  testWidgets('edit-resend goes inline: pencil and long-press entries both '
      'swap the bubble for the edit card (D1)', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '帮我修复登录', 'state': 'done'},
    ]);
    await tester.pumpAndSettle();

    // Pencil beside the bubble → the card replaces the bubble IN PLACE
    // (no dialog route), prefilled with the original text.
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    final editField = find.byKey(const ValueKey('inline-edit-input'));
    expect(editField, findsOneWidget);
    expect(find.text('帮我修复登录'), findsOneWidget);
    // R1 regression: the button must read the table copy, never the raw
    // (dotted) key.
    expect(find.widgetWithText(FilledButton, '发送'), findsOneWidget);
    expect(find.text('chat.action.edit.resend'), findsNothing);
    expect(gateway.calls.where((c) => c.$1 == 'editUserQuery'), isEmpty);

    // 取消 returns the bubble without sending anything.
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(editField, findsNothing);
    expect(gateway.calls.where((c) => c.$1 == 'editUserQuery'), isEmpty);

    // Long-press bottom sheet entry. Pre-M0 recipe kept as a regression
    // guard: press the bubble padding just outside the text.
    final textTopLeft = tester.getTopLeft(find.text('帮我修复登录'));
    await tester.longPressAt(textTopLeft - const Offset(8, 4));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑并重发'));
    await tester.pumpAndSettle();
    expect(editField, findsOneWidget);
  });

  testWidgets('pending questions card under the keyboard: the status strip '
      'compresses instead of overflowing, composer stays on screen',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await pumpQuestions(tester, [envQuestion]);

    // No keyboard: card and composer render at intrinsic heights.
    expect(find.text('开发'), findsOneWidget);
    expect(find.text('提出后续修改要求'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Simulate the IME: the viewport shrinks and the min-height status
    // strip (goal/works/queue/interactions) must turn into a scrollable
    // area instead of pushing the composer off screen (was: RenderFlex
    // overflowed by 344 pixels).
    tester.view.viewInsets = const FakeViewPadding(bottom: 550);
    await tester.pumpAndSettle();

    final keyboardTop = 844.0 - 550.0;
    final composer = find.text('提出后续修改要求');
    expect(composer, findsOneWidget);
    expect(
      tester.getBottomRight(composer).dy,
      lessThanOrEqualTo(keyboardTop + 0.5),
    );
    expect(tester.takeException(), isNull);
  });

  // ------------------- chat config fixes (PRD internal-task)

  testWidgets('composer model chip: an official account-plan draft value '
      'splits into the bare model id', (tester) async {
    final prep = WorkspacePrep.fromMap(const {
      'configOptions': [
        {
          'id': 'model',
          'name': 'Model',
          'currentValue': 'account:zai-start-plan/GLM-5.3',
          'options': [
            {'value': 'account:zai-start-plan/GLM-5.3', 'name': 'GLM-5.3'},
          ],
        },
      ],
      'slashCommands': <Map<String, dynamic>>[],
    });
    await tester.pumpWidget(
      wrap(ChatPage(host: _PrepGateway(prep), title: '新任务')),
    );
    await tester.pumpAndSettle();

    expect(find.text('GLM-5.3'), findsOneWidget);
    expect(find.text('account:zai-start-plan/GLM-5.3'), findsNothing);
  });

  testWidgets('composer model chip follows the shared label rule: the draft '
      'composite and the live config render the same string, equal to '
      'chatModelLabel(state)', (tester) async {
    // The draft path receives the prep's composite value; the live path
    // receives the config's split provider/model pair. Same provider and
    // model → same chip copy (10-31 model-label unify, plan A).
    final prep = WorkspacePrep.fromMap(const {
      'configOptions': [
        {
          'id': 'model',
          'name': '模型',
          'currentValue': 'personal-huancheng/deepseek-v4-flash',
          'options': [
            {
              'value': 'personal-huancheng/deepseek-v4-flash',
              'name': 'DeepSeek V4 Flash',
            },
          ],
        },
        {
          'id': 'thought_level',
          'name': '思考等级',
          'currentValue': 'enabled',
          'options': [
            {'value': 'enabled', 'name': '开启'},
          ],
        },
      ],
      'slashCommands': <Map<String, dynamic>>[],
    });

    await tester.pumpWidget(
      wrap(ChatPage(host: _PrepGateway(prep), title: '新任务')),
    );
    await tester.pumpAndSettle();
    expect(find.text('personal-huancheng/deepseek-v4-flash'), findsOneWidget);

    final gateway = FakeChatGateway()
      ..snapshotExtra = {
        'config': {
          'provider': 'personal-huancheng',
          'model': 'deepseek-v4-flash',
          'thought': 'enabled',
        },
      };
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    expect(find.text('personal-huancheng/deepseek-v4-flash'), findsOneWidget);
    expect(
      chatModelLabel(gateway.state),
      'personal-huancheng/deepseek-v4-flash',
    );
  });

  testWidgets('composer model chip: a three-part draft value keeps the model '
      'id intact (first-slash split)', (tester) async {
    // Command Code's model id is itself "deepseek/deepseek-v4.1-flash", so
    // the prep option value carries three segments. Splitting on the last
    // slash would read provider="uuid/deepseek" and shorten the model id.
    const provider = 'ee6c256c-d8fa-4419-9ed4-bead8bf652bd';
    const value = '$provider/deepseek/deepseek-v4.1-flash';
    final prep = WorkspacePrep.fromMap(const {
      'configOptions': [
        {
          'id': 'model',
          'name': '模型',
          'currentValue': value,
          'options': [
            {'value': value, 'name': 'deepseek/deepseek-v4.1-flash'},
          ],
        },
      ],
      'slashCommands': <Map<String, dynamic>>[],
    });
    await tester.pumpWidget(
      wrap(ChatPage(host: _PrepGateway(prep), title: '新任务')),
    );
    await tester.pumpAndSettle();

    expect(find.text(value), findsOneWidget);
  });

  testWidgets('draft: an explicit slashy model pick ships the full model id '
      'in createSession (first-slash split)', (tester) async {
    const provider = 'ee6c256c-d8fa-4419-9ed4-bead8bf652bd';
    const value = '$provider/deepseek/deepseek-v4.1-flash';
    final prep = WorkspacePrep.fromMap(const {
      'configOptions': [
        {
          'id': 'model',
          'name': '模型',
          'currentValue': 'builtin/glm-5.2',
          'options': [
            {'value': 'builtin/glm-5.2', 'name': 'GLM-5.2'},
            {'value': value, 'name': 'deepseek/deepseek-v4.1-flash'},
          ],
        },
        {
          'id': 'thought_level',
          'name': '思考等级',
          'currentValue': 'enabled',
          'options': [
            {'value': 'enabled', 'name': '开启'},
          ],
        },
      ],
      'slashCommands': <Map<String, dynamic>>[],
    });
    final gateway = _PrepGateway(prep);
    await tester.pumpWidget(wrap(ChatPage(host: gateway, title: '新任务')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('glm-5.2')); // composer model chip
    await tester.pumpAndSettle();
    await tester.tap(find.text('deepseek/deepseek-v4.1-flash'));
    await tester.pumpAndSettle();
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '开始分析');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final call = gateway.calls
        .where((c) => c.$1 == 'createSession')
        .toList()
        .single;
    expect(call.$2[2], {
      'provider': provider,
      'model': 'deepseek/deepseek-v4.1-flash',
      'thought': 'enabled',
    });
  });

  testWidgets('draft: an explicit catalog pick survives a missing prep at '
      'send time (no silent drop)', (tester) async {
    const provider = 'ee6c256c-d8fa-4419-9ed4-bead8bf652bd';
    const model = 'deepseek/deepseek-v4.1-flash';
    final settings = UiSettings()..newTaskModel = 'builtin/glm-5.2';
    final gateway = _FailingPrepGateway()
      ..modelProviderCatalogResult = [
        {
          'id': provider,
          'name': 'Command Code',
          'models': [
            {'id': model},
          ],
        },
      ];
    await tester.pumpWidget(MaterialApp(
      theme: buildDarkTheme(),
      darkTheme: buildDarkTheme(),
      builder: (context, child) =>
          UiSettingsProvider(settings: settings, child: child!),
      home: ChatPage(host: gateway, title: '新任务'),
    ));
    await tester.pumpAndSettle();

    // The seeded global default keeps the chip visible; prep is unreachable,
    // so the sheet lists the provider catalog and the pick is a first-class
    // user choice that must ship (sanitize's silent drop is for seeds only).
    await tester.tap(find.text('glm-5.2'));
    await tester.pumpAndSettle();
    expect(find.text('Command Code'), findsWidgets);
    await tester.tap(find.text(model));
    await tester.pumpAndSettle();
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '开始分析');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final call = gateway.calls
        .where((c) => c.$1 == 'createSession')
        .toList()
        .single;
    expect(call.$2[2], {'provider': provider, 'model': model, 'thought': 'max'});
  });

  testWidgets('empty model config keeps the composer model/thought chips '
      'with placeholder labels', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    // The snapshot carries no config: currentModel/currentThought are both
    // empty. Visibility keys off prep option availability (prep lands
    // asynchronously), so the chips render with placeholders.
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    expect(find.text('模型'), findsOneWidget);
    expect(find.text('思考'), findsOneWidget);

    // The sheet opens from the placeholder chip and lists the prep options
    // (option-name provider header falls back to the name — 2 hits).
    await tester.tap(find.text('模型'));
    await tester.pumpAndSettle();
    expect(find.text('GLM-5.2'), findsNWidgets(2));
  });

  testWidgets('thought chip: live switch sends the config bare provider/model '
      'pair (slashy model id intact)', (tester) async {
    final transport = _SwitchTransport();
    final gateway = _SwitchGateway(transport)
      ..snapshotExtra = {
        'config': {
          'provider': 'ee6c256c-d8fa-4419-9ed4-bead8bf652bd',
          'model': 'deepseek/deepseek-v4.1-flash',
          'thought': 'enabled',
          'mode': 'build',
        },
      };
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    // The chip label is the prep option name for the current value.
    await tester.tap(find.text('开启'));
    await tester.pumpAndSettle();
    // The dialog lists the raw option values.
    await tester.tap(find.text('off'));
    await tester.pumpAndSettle();

    expect(transport.switches, hasLength(1));
    expect(
      transport.switches.single.provider,
      'ee6c256c-d8fa-4419-9ed4-bead8bf652bd',
    );
    expect(
      transport.switches.single.model,
      'deepseek/deepseek-v4.1-flash',
    );
    expect(transport.switches.single.thought, 'off');
  });

  testWidgets('thought chip: config not landed → no command is sent',
      (tester) async {
    final transport = _SwitchTransport();
    final gateway = _SwitchGateway(transport);
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    expect(find.text('思考'), findsOneWidget); // placeholder chip
    await tester.tap(find.text('思考'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('off'));
    await tester.pumpAndSettle();

    expect(
      transport.switches,
      isEmpty,
      reason: 'provider/model are empty without a config — the guard keeps '
          'the empty pair off the wire',
    );
  });

  // ------------------- per-model thought levels (11-09)

  testWidgets('thought levels follow the current model: the chain prefers the '
      'model option own table over the stale prep thought option', (tester) async {
    // Design 11-09 test plan 1: the fixture's global thought_level lists
    // [low, high] (high-only's table), while `wide` carries [low, high,
    // max]. Opening the picker on `wide` must show max even though the prep
    // thought option never mentions it.
    final transport = _SwitchTransport();
    final gateway = _SwitchGateway(transport, prep: perModelThoughtPrep())
      ..snapshotExtra = thoughtModelConfig(kWideModel, thought: 'max');
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('max')); // composer thought chip
    await tester.pumpAndSettle();
    expect(find.text('low'), findsOneWidget); // wide's full table renders
    expect(find.text('high'), findsOneWidget);
    // The level-1 marker: `max` is in wide's own table but never in the
    // prep thought option — without the lookup the picker would drop it.
    expect(
      find.descendant(
        of: find.byType(RadioListTile<String>),
        matching: find.text('max'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('thought levels fall back to the prep option when the model '
      'option carries no table', (tester) async {
    // Design 11-09 test plan 2 (level 2): `plain` has no modelThoughtLevels
    // key → the prep thought option answers. The picker lists raw values
    // (official behavior), so the assertions use them, not the prep names.
    final gateway = _SwitchGateway(
      _SwitchTransport(),
      prep: perModelThoughtPrep(),
    )..snapshotExtra = thoughtModelConfig(kPlainModel);
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('高'));
    await tester.pumpAndSettle();
    expect(find.text('low'), findsOneWidget);
    expect(find.text('max'), findsNothing);
  });

  testWidgets('thought levels fall back to the config snapshot when even the '
      'prep thought option is absent', (tester) async {
    // Design 11-09 test plan 2 (level 3): prep ships no thought option, so
    // the session config's thoughtLevels is the last resort.
    final gateway = _SwitchGateway(_SwitchTransport(), prep: barePrep())
      ..snapshotExtra = thoughtModelConfig(kPlainModel);
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('high')); // raw live label (no prep names)
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(RadioListTile<String>),
        matching: find.text('low'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(RadioListTile<String>),
        matching: find.text('high'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('draft model switch re-renders the sheet thought list against '
      'the new model table (close and reopen the sheet)', (tester) async {
    // Design 11-09 test plan 6 (P2-5): the sheet is a separate route, so a
    // page setState does not rebuild it — assert after closing and reopening.
    // (The default recording transport answers createSession; the switch
    // recording one is only needed for live-session cases.)
    final gateway = _PrepGateway(perModelThoughtPrep());
    await tester.pumpWidget(wrap(ChatPage(host: gateway, title: '新任务')));
    await tester.pumpAndSettle();

    // Draft starts on the prep currentValue model: high-only's [low, high].
    // (The composer chip renders the same "高" label, so scope to the sheet.)
    await tester.tap(find.text('high-only')); // composer model chip
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ChoiceChip, '高'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'max'), findsNothing);

    // Pick `wide` in the draft sheet. The sheet re-renders in place
    // (StatefulBuilder wrapper): wide's table — and its default `max`
    // selection — appear without closing.
    await tester.tap(find.text('Wide'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ChoiceChip, 'max'), findsOneWidget);
    expect(
      tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'max')).selected,
      isTrue,
      reason: 'the open sheet follows the pick in place',
    );
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('wide')); // composer chip follows the pick
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ChoiceChip, 'max'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '高'), findsOneWidget);
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'max'))
          .selected,
      isTrue,
      reason: 'the selection falls to the target table default (max)',
    );
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '开始分析');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final call = gateway.calls
        .where((c) => c.$1 == 'createSession')
        .toList()
        .single;
    expect(call.$2[2], {
      'provider': 'builtin',
      'model': kWideModel,
      'thought': 'max',
    }, reason: 'the direct-send default lands inside the target table');
  });

  testWidgets('config-sheet fallback: no prep options renders the '
      'model-provider catalog', (tester) async {
    final gateway = _SwitchGateway(_SwitchTransport(), prep: barePrep())
      ..entitlementResult = okQuota(
        {'count': 0, 'percentage': 100, 'isShow': true},
        tokenPercentage: 100,
      )
      ..modelProviderCatalogResult = [
        {
          'id': 'builtin:zai-coding-plan',
          'name': 'BigModel',
          'enabled': true,
          'models': [
            {'id': 'GLM-5.3'},
            'GLM-5.3-Air',
          ],
        },
      ];
    await pumpWithQuota(tester, gateway);
    // Entry path: prep has no model options → the composer chip is hidden,
    // the quota banner's 切换模型 still opens the sheet.
    expect(find.byIcon(Icons.memory_outlined), findsNothing);
    expect(find.text('切换模型'), findsOneWidget);

    await tester.tap(find.text('切换模型'));
    await tester.pumpAndSettle();
    expect(gateway.modelProviderCatalogCalls, 1);
    expect(find.text('GLM-5.3'), findsOneWidget);
    // Provider group header + one subtitle per catalog entry.
    expect(find.text('BigModel'), findsNWidgets(3));

    // Picking a catalog entry issues the switch with the split ids; the
    // sheet closes (the composer chip stays hidden — visibility keys off
    // the prep option, which this session lacks).
    await tester.tap(find.text('GLM-5.3'));
    await tester.pumpAndSettle();
    expect(
        gateway.transport.switches.single.provider, 'builtin:zai-coding-plan');
    expect(gateway.transport.switches.single.model, 'GLM-5.3');
    expect(find.text('GLM-5.3'), findsNothing); // sheet closed
  });

  testWidgets('model sheet section header rides the local lexicon, not the '
      'desktop English option name (B4)', (tester) async {
    // Wire 定证 (3.14 workspace-config research): desktop ships config
    // option names in English — `{id: "model", name: "Model"}`. The
    // section header must show the local lexicon copy (「模型」), never
    // the raw desktop name.
    final gateway = _SwitchGateway(
      _SwitchTransport(),
      prep: WorkspacePrep.fromMap(const {
        'configOptions': [
          {
            'id': 'model',
            'name': 'Model',
            'currentValue': 'builtin/glm-5.2',
            'options': [
              {'value': 'builtin/glm-5.2', 'name': 'GLM-5.2'},
            ],
          },
        ],
        'slashCommands': <Map<String, dynamic>>[],
      }),
    )..entitlementResult = okQuota(
        {'count': 0, 'percentage': 100, 'isShow': true},
        tokenPercentage: 100,
      );
    await pumpWithQuota(tester, gateway);

    await tester.tap(find.text('切换模型'));
    await tester.pumpAndSettle();
    // Local lexicon header (plus another 模型 label in the sheet); the
    // desktop's English option name is gone.
    expect(find.text('模型'), findsAtLeastNWidgets(1));
    expect(find.text('Model'), findsNothing);
  });

  testWidgets('thought sheet section header rides the local lexicon, not '
      'the desktop English option name (D1)', (tester) async {
    // Same wire discipline as the model header (B4): desktop ships
    // `{id: "thought_level", name: "Thought level"}` in English — the
    // section title must be the lexicon copy (「思考等级」), never the raw
    // desktop name. Chip labels stay the desktop originals.
    final gateway = _SwitchGateway(
      _SwitchTransport(),
      prep: WorkspacePrep.fromMap(const {
        'configOptions': [
          {
            'id': 'thought_level',
            'name': 'Thought level',
            'currentValue': 'enabled',
            'options': [
              {'value': 'enabled', 'name': 'Enabled'},
              {'value': 'off', 'name': 'Off'},
            ],
          },
        ],
        'slashCommands': <Map<String, dynamic>>[],
      }),
    )..entitlementResult = okQuota(
        {'count': 0, 'percentage': 100, 'isShow': true},
        tokenPercentage: 100,
      );
    await pumpWithQuota(tester, gateway);

    await tester.tap(find.text('切换模型'));
    await tester.pumpAndSettle();
    expect(find.text('思考等级'), findsOneWidget);
    expect(find.text('Thought level'), findsNothing);
  });

  testWidgets('config-sheet fallback: empty catalog keeps the degraded '
      'current-model text', (tester) async {
    final gateway = _SwitchGateway(_SwitchTransport(), prep: barePrep())
      ..entitlementResult = okQuota(
        {'count': 0, 'percentage': 100, 'isShow': true},
        tokenPercentage: 100,
      );
    await pumpWithQuota(tester, gateway);

    await tester.tap(find.text('切换模型'));
    await tester.pumpAndSettle();
    // Catalog probed but empty → the sheet keeps the degraded text.
    expect(gateway.modelProviderCatalogCalls, 1);
    expect(find.textContaining('当前模型'), findsOneWidget);
    expect(find.textContaining('GLM-5.3'), findsNothing);
  });

  // ------------------------------------ model catalog entitlement (10-24 B)

  testWidgets('model sheet hides unentitled account groups, keeps the '
      'personal provider and the group order', (tester) async {
    final gateway = _SwitchGateway(_SwitchTransport(), prep: planCatalogPrep())
      ..entitlementResult = okQuota(
        {'count': 0, 'percentage': 100, 'isShow': true},
        tokenPercentage: 100,
      )
      ..entitledProviderIdsResult = {'account:zai-start-plan'}
      ..snapshotExtra = snapshotModelConfig('account:zai-start-plan');
    await pumpWithQuota(tester, gateway);

    await tester.tap(find.byIcon(Icons.memory_outlined));
    await tester.pumpAndSettle();

    // One read at page open (the Start-plan auto switch hook, 10-24 C) plus
    // the sheet's own prefetch on open.
    expect(gateway.entitledProviderIdsCalls, 2);
    // One header + one subtitle per option in the surviving groups.
    expect(find.text('Start Plan'), findsNWidgets(3));
    expect(find.text('幻城'), findsNWidgets(2));
    expect(find.text('Z.AI Individual Coding Plan'), findsNothing);
    expect(find.text('Z.AI Idle plan'), findsNothing);
    expect(find.text('Z.AI Highspeed card'), findsNothing);
    // Order: Start Plan renders above 幻城 (first hit = the group header).
    expect(
      tester.getTopLeft(find.text('Start Plan').first).dy,
      lessThan(tester.getTopLeft(find.text('幻城').first).dy),
    );
  });

  testWidgets('model sheet keeps the group holding the current model even '
      'when the account is not entitled to it', (tester) async {
    final gateway = _SwitchGateway(_SwitchTransport(), prep: planCatalogPrep())
      ..entitlementResult = okQuota(
        {'count': 0, 'percentage': 100, 'isShow': true},
        tokenPercentage: 100,
      )
      ..entitledProviderIdsResult = {'account:zai-start-plan'}
      // The session currently runs a model of an unentitled idle plan —
      // the exemption keeps that group visible (PRD §2 exception).
      ..snapshotExtra = snapshotModelConfig('account:zai-off-peak');
    await pumpWithQuota(tester, gateway);

    await tester.tap(find.byIcon(Icons.memory_outlined));
    await tester.pumpAndSettle();

    expect(find.text('Start Plan'), findsNWidgets(3));
    expect(find.text('Z.AI Idle plan'), findsNWidgets(3));
    expect(find.text('Z.AI Individual Coding Plan'), findsNothing);
    expect(find.text('Z.AI Highspeed card'), findsNothing);
  });

  testWidgets('model sheet degrades to the full catalog when the provider '
      'view cannot be read (PRD §3)', (tester) async {
    final gateway = _SwitchGateway(_SwitchTransport(), prep: planCatalogPrep())
      ..entitlementResult = okQuota(
        {'count': 0, 'percentage': 100, 'isShow': true},
        tokenPercentage: 100,
      )
      ..entitledProviderIdsError = StateError('provider-settings unavailable')
      ..snapshotExtra = snapshotModelConfig('account:zai-start-plan');
    await pumpWithQuota(tester, gateway);

    await tester.tap(find.byIcon(Icons.memory_outlined));
    await tester.pumpAndSettle();

    // Page-open auto-switch read + the sheet's own prefetch; both see the
    // failing view and degrade to no filtering.
    expect(gateway.entitledProviderIdsCalls, 2);
    for (final header in const [
      'Z.AI Individual Coding Plan',
      'Start Plan',
      'Z.AI Idle plan',
      'Z.AI Highspeed card',
    ]) {
      expect(find.text(header), findsNWidgets(3));
    }
    expect(find.text('幻城'), findsNWidgets(2));
  });

  // ------------------------- Start-plan auto switch (10-24 C)

  testWidgets('Start-plan auto switch: a drained Start plan switches the '
      'live session to the entitled coding plan (same modelId preferred) and '
      'toasts once', (tester) async {
    final transport = _SwitchTransport();
    final gateway = _SwitchGateway(transport, prep: planCatalogPrep())
      ..entitlementResult = startPlanExhausted()
      ..entitledProviderIdsResult = {
        'account:zai-start-plan',
        'account:zai-individual-coding-plan',
      }
      // The live session runs GLM-5.3-Flash under the Start plan: the target
      // must prefer the coding plan's SAME model over its first option.
      ..snapshotExtra = startPlanConfig(model: 'GLM-5.3-Flash');
    await pumpWithQuota(tester, gateway);

    expect(transport.switches, hasLength(1));
    expect(
      transport.switches.single.provider,
      'account:zai-individual-coding-plan',
    );
    expect(transport.switches.single.model, 'GLM-5.3-Flash');
    expect(transport.switches.single.thought, 'enabled');
    // One auto-switch toast; the sheet's pending toast is sheet-only and
    // must not fire here.
    expect(
      find.text('Start 套餐已不可用，已切换到 Z.AI Individual Coding Plan'),
      findsOneWidget,
    );
    expect(find.text('已切换，下一条消息生效'), findsNothing);
    // The exhausted banner stays as the manual fallback.
    expect(find.text('套餐额度已用尽'), findsOneWidget);
  });

  testWidgets('Start-plan auto switch: an expired Start plan uses the same '
      'chain', (tester) async {
    final transport = _SwitchTransport();
    final gateway = _SwitchGateway(transport, prep: planCatalogPrep())
      ..entitlementResult = startPlanExpired()
      ..entitledProviderIdsResult = {
        'account:zai-start-plan',
        'account:zai-individual-coding-plan',
      }
      ..snapshotExtra = startPlanConfig();
    await pumpWithQuota(tester, gateway);

    expect(transport.switches, hasLength(1));
    expect(transport.switches.single.model, 'GLM-5.3');
    expect(
      find.text('Start 套餐已不可用，已切换到 Z.AI Individual Coding Plan'),
      findsOneWidget,
    );
    // Expiry copy, not the exhausted copy.
    expect(find.text('套餐已到期'), findsOneWidget);
  });

  testWidgets('Start-plan auto switch: no entitled coding plan leaves the '
      'session alone and keeps the banner', (tester) async {
    final transport = _SwitchTransport();
    final gateway = _SwitchGateway(transport, prep: planCatalogPrep())
      ..entitlementResult = startPlanExhausted()
      ..entitledProviderIdsResult = {'account:zai-start-plan'}
      ..snapshotExtra = startPlanConfig();
    await pumpWithQuota(tester, gateway);

    expect(transport.switches, isEmpty);
    expect(find.text('套餐额度已用尽'), findsOneWidget);
  });

  testWidgets('Start-plan auto switch failure is not retried on the next '
      'entitlement refresh', (tester) async {
    final transport = _SwitchTransport(results: [
      const {'status': 'rejected', 'reasonCode': 'proto.staleRevision'},
    ]);
    final gateway = _SwitchGateway(transport, prep: planCatalogPrep())
      ..entitlementResult = startPlanExhausted()
      ..entitledProviderIdsResult = {
        'account:zai-start-plan',
        'account:zai-individual-coding-plan',
      }
      ..snapshotExtra = startPlanConfig();
    await pumpWithQuota(tester, gateway);

    expect(transport.switches, hasLength(1));
    // A rejected command is not a switch: no success toast, banner stays.
    expect(find.textContaining('Start 套餐已不可用'), findsNothing);
    expect(find.text('套餐额度已用尽'), findsOneWidget);

    // The usage sheet re-runs `_loadEntitlement`; the session-level marker
    // must suppress a second command even though the trigger still holds.
    await tester.tap(find.text('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('用量统计'));
    await tester.pumpAndSettle();
    expect(gateway.entitlementCalls, 2);
    expect(transport.switches, hasLength(1));
  });

  testWidgets('draft pages never auto-switch (no live session to rewrite)', (
    tester,
  ) async {
    final transport = _SwitchTransport();
    final gateway = _SwitchGateway(transport, prep: planCatalogPrep())
      ..entitlementResult = startPlanExhausted()
      ..entitledProviderIdsResult = {
        'account:zai-start-plan',
        'account:zai-individual-coding-plan',
      };
    await tester.pumpWidget(wrap(ChatPage(host: gateway, title: 't')));
    await tester.pumpAndSettle();

    expect(transport.switches, isEmpty);
  });

  testWidgets('sheet switch: lost ack lands the optimistic patch and closes '
      'the sheet with the pending toast', (tester) async {
    final transport = _SwitchTransport(results: [
      TimeoutException('switchModelConfig'),
    ]);
    final gateway = _SwitchGateway(transport);
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('模型')); // placeholder chip
    await tester.pumpAndSettle();
    await tester.tap(find.text('GLM-5.2 Air'));
    await tester.pumpAndSettle();

    // Not a rejection: the switch went out (thought fell back to the prep
    // currentValue) and the patch landed anyway — the chip reads the
    // optimistic (raw, prep-unmatched) model and the sheet closed.
    expect(transport.switches.single.model, 'glm-5.2-air');
    expect(transport.switches.single.thought, 'enabled');
    expect(find.text('已切换，下一条消息生效'), findsOneWidget);
    expect(find.text('glm-5.2-air'), findsOneWidget); // chip
    expect(find.text('GLM-5.2 Air'), findsNothing); // sheet list gone
  });

  testWidgets('sheet switch: explicit status rejection keeps the rejection '
      'snackbar and patches nothing', (tester) async {
    final transport = _SwitchTransport(results: [
      {
        'status': 'rejected',
        'reasonCode': 'model_locked',
      },
    ]);
    final gateway = _SwitchGateway(transport);
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('模型'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('GLM-5.2 Air'));
    await tester.pumpAndSettle();

    expect(find.textContaining('被拒绝: model_locked'), findsOneWidget);
    // No optimistic patch (chip stays placeholder) and no sheet close.
    expect(find.text('GLM-5.2 Air'), findsOneWidget); // sheet list
    expect(find.text('模型'), findsNWidgets(2)); // chip + sheet section head
  });

  testWidgets('model switch falls back to the target table default when the '
      'current thought is not in it', (tester) async {
    // Design 11-09 test plan 3: switching high-only → wide with a thought
    // (`ultra`) that neither table can name. The stale prep option carries
    // 'high' as its currentValue, which the pre-11-09 chain would ship; the
    // target table's default must win.
    final transport = _SwitchTransport();
    final gateway = _SwitchGateway(transport, prep: perModelThoughtPrep())
      ..snapshotExtra = thoughtModelConfig(kHighOnlyModel, thought: 'ultra');
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('high-only')); // composer model chip
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wide'));
    await tester.pumpAndSettle();

    expect(transport.switches.single.model, kWideModel);
    expect(
      transport.switches.single.thought,
      'max',
      reason: 'the target table default outranks the stale prep currentValue',
    );
  });

  testWidgets('model switch keeps the current thought when the target table '
      'contains it', (tester) async {
    // Design 11-09 test plan 3 (keep branch).
    final transport = _SwitchTransport();
    final gateway = _SwitchGateway(transport, prep: perModelThoughtPrep())
      ..snapshotExtra = thoughtModelConfig(kHighOnlyModel);
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('high-only'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wide'));
    await tester.pumpAndSettle();

    expect(transport.switches.single.thought, 'high');
  });

  testWidgets('model switch with no target table keeps the pre-11-09 chain '
      'verbatim: a listed current thought is kept (regression lock)',
      (tester) async {
    // Design 11-09 test plan 4 (P2-6): a model whose option carries no
    // modelThoughtLevels must walk the original branch unchanged.
    final transport = _SwitchTransport();
    final gateway = _SwitchGateway(transport, prep: perModelThoughtPrep())
      ..snapshotExtra = thoughtModelConfig(kHighOnlyModel);
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('high-only'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Plain'));
    await tester.pumpAndSettle();

    // currentThought 'high' IS in the stale prep options → kept as-is.
    expect(transport.switches.single.model, kPlainModel);
    expect(transport.switches.single.thought, 'high');
  });

  testWidgets('model switch with no target table falls back to the prep '
      'currentValue when the current thought is unlisted (regression lock)',
      (tester) async {
    // Design 11-09 test plan 4, second half of the verbatim branch.
    final transport = _SwitchTransport();
    final gateway = _SwitchGateway(transport, prep: perModelThoughtPrep())
      ..snapshotExtra = thoughtModelConfig(kPlainModel, thought: 'ultra');
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('plain'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('High Only'));
    await tester.pumpAndSettle();

    expect(transport.switches.single.thought, 'high');
  });

  testWidgets('accepted model switch re-fetches prep exactly once and never '
      'runs the Start-plan auto switch', (tester) async {
    // Design 11-09 test plan 5 (P2-4): the re-fetch fires on accepted only,
    // and it must not hand _maybeAutoSwitchStartPlan a new trigger surface.
    // The fixture makes that surface real: the session sits on a personal
    // model (opening judges nothing — the provider never matches, so the
    // one-shot guard stays unset), then the user manually picks a Start-plan
    // model with the entitlement snapshot terminal and an entitled
    // coding-plan target in the pool. An ungated re-fetch would fire the
    // auto switch and rewrite the pick; the gate is locked by the absence
    // of a second command.
    final transport = _SwitchTransport();
    final gateway = _SwitchGateway(transport, prep: startPlanSwitchPrep())
      ..snapshotExtra = personalModelConfig()
      ..entitlementResult = startPlanExhausted()
      ..entitledProviderIdsResult = {
        'account:zai-individual-coding-plan',
        'account:zai-start-plan',
      };
    await pumpWithQuota(tester, gateway);
    expect(transport.switches, isEmpty); // no opening-page auto switch
    final callsBeforeSwitch = gateway.prepareWorkspaceCalls;
    expect(callsBeforeSwitch, greaterThanOrEqualTo(1));

    await tester.tap(find.text('personal-huancheng/deepseek-v4-flash'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start Flash'));
    await tester.pumpAndSettle();

    expect(transport.switches.single.model, 'glm-flash');
    expect(
      gateway.prepareWorkspaceCalls,
      callsBeforeSwitch + 1,
      reason: 'one re-fetch per accepted switch',
    );
    expect(
      transport.switches,
      hasLength(1),
      reason: 'the gated re-fetch triggered no auto switch — the manual '
          'Start-plan pick stands',
    );
    expect(find.textContaining('Start 套餐已不可用'), findsNothing);
  });

  testWidgets('a lost-ack model switch does not re-fetch prep', (tester) async {
    // Design 11-09 §3: the command may be swallowed; a re-fetch would read
    // an unchanged prep and pollute the revert trace.
    final transport = _SwitchTransport(results: [
      TimeoutException('switchModelConfig'),
    ]);
    final gateway = _SwitchGateway(transport, prep: perModelThoughtPrep())
      ..snapshotExtra = thoughtModelConfig(kHighOnlyModel);
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();
    final callsBeforeSwitch = gateway.prepareWorkspaceCalls;

    await tester.tap(find.text('high-only'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wide'));
    await tester.pumpAndSettle();

    expect(transport.switches, hasLength(1));
    expect(gateway.prepareWorkspaceCalls, callsBeforeSwitch);
  });

  testWidgets('reverse switch (max model → high-only) backtracks the list and '
      'never leaves an out-of-table selection', (tester) async {
    // Design 11-09 test plan 7: the picker drops `max` again and the chip
    // falls back inside [low, high].
    final transport = _SwitchTransport();
    final gateway = _SwitchGateway(transport, prep: perModelThoughtPrep())
      ..snapshotExtra = thoughtModelConfig(kWideModel, thought: 'max');
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('max'));
    await tester.pumpAndSettle();
    expect(find.text('low'), findsOneWidget); // wide's table
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('wide'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('High Only'));
    await tester.pumpAndSettle();

    // The switch itself lands inside the target table (max is absent).
    expect(transport.switches.single.model, kHighOnlyModel);
    expect(transport.switches.single.thought, 'high');

    // The picker follows: no `max` left once the config carries high-only.
    // (The switch snackbar covers the composer, so let it expire first.)
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    gateway.snapshotExtra = thoughtModelConfig(kHighOnlyModel, thought: 'high');
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('高'));
    await tester.pumpAndSettle();
    expect(find.text('low'), findsOneWidget);
    expect(find.text('max'), findsNothing);
  });

  testWidgets('AC1: high-only → max model makes max appear in the picker '
      'without reopening the page', (tester) async {
    final transport = _SwitchTransport();
    final gateway = _SwitchGateway(transport, prep: perModelThoughtPrep())
      ..snapshotExtra = thoughtModelConfig(kHighOnlyModel);
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('高'));
    await tester.pumpAndSettle();
    expect(find.text('max'), findsNothing);
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('high-only'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wide'));
    await tester.pumpAndSettle();

    // Same page, no re-open: the picker now lists `wide`'s table, max
    // included (high stayed selected — it is inside both tables). The
    // switch snackbar sits over the composer, so let it expire first.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.tap(find.text('高'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(RadioListTile<String>),
        matching: find.text('max'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('AC1: entering a model with a table from a table-less one keeps '
      'the thought entry visible', (tester) async {
    // Design 11-09 test plan 8 (P1-1 visibility): prep has no thought_level
    // option and the config snapshot has no thoughtLevels, so the old
    // two-condition gate hid the entry; the chain's level 1 restores it.
    final transport = _SwitchTransport();
    final gateway = _SwitchGateway(
      transport,
      prep: WorkspacePrep.fromMap(const {
        'configOptions': [
          {
            'id': 'model',
            'currentValue': 'builtin/$kPlainModel',
            'options': [
              {'value': 'builtin/$kPlainModel', 'name': 'Plain'},
              {
                'value': 'builtin/$kWideModel',
                'name': 'Wide',
                'modelThoughtLevels': ['low', 'high', 'max'],
                'modelDefaultThoughtLevel': 'max',
              },
            ],
          },
        ],
        'slashCommands': <Map<String, dynamic>>[],
      }),
    )..snapshotExtra = {
        'config': {
          'provider': 'builtin',
          'model': kPlainModel,
          'thought': 'high',
          'mode': 'build',
        },
      };
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    // No table anywhere yet → no thought chip (unchanged behavior).
    expect(find.byIcon(Icons.psychology_alt_outlined), findsNothing);

    await tester.tap(find.text('plain'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wide'));
    await tester.pumpAndSettle();

    // The chain's level 1 makes the entry render (the old gate stayed false).
    expect(find.byIcon(Icons.psychology_alt_outlined), findsOneWidget);
  });

  testWidgets('loading placeholder: degraded bridge line + slow hint after 5s', (
    tester,
  ) async {
    final session = _DegradedBridgeSession()
      ..degraded.value = 'rpc-transport-fault';
    final gateway = _StalledGateway(_DegradedTransport(session));
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    await tester.pump();

    // Subscribe parked → no state: spinner plus the bridge-degraded copy,
    // but the slow hint is not due yet (fake clock).
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('与桌面端的连接正在恢复…'), findsOneWidget);
    expect(find.text('正在建立连接，可能需要一点时间…'), findsNothing);

    await tester.pump(const Duration(seconds: 6));
    expect(find.text('正在建立连接，可能需要一点时间…'), findsOneWidget);

    // Recovery clears the bridge line while the slow hint stays.
    session.degraded.value = null;
    await tester.pump();
    expect(find.text('与桌面端的连接正在恢复…'), findsNothing);
    expect(find.text('正在建立连接，可能需要一点时间…'), findsOneWidget);

    await _releaseStalledPage(tester, gateway);
  });

  testWidgets('loading placeholder: healthy bridge shows only the slow hint', (
    tester,
  ) async {
    final gateway = _StalledGateway(_DegradedTransport(_DegradedBridgeSession()));
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    await tester.pump();
    expect(find.text('与桌面端的连接正在恢复…'), findsNothing);

    await tester.pump(const Duration(seconds: 6));
    expect(find.text('正在建立连接，可能需要一点时间…'), findsOneWidget);
    expect(find.text('与桌面端的连接正在恢复…'), findsNothing);

    await _releaseStalledPage(tester, gateway);
  });

  // ------------------- history prefetch / pull gesture (09-21) -------------

  /// Uniform one-line user turns: one row per group, no time dividers
  /// (rows carry no timestamps) → identical heights, so the anchor
  /// arithmetic (offset shifted by exactly Δmax) is exact in assertions.
  List<Map<String, dynamic>> historyRows(int from, int to) => [
    for (var i = from; i <= to; i++)
      {'rowId': i, 'kind': 'userInput', 'text': '历史消息 $i'},
  ];

  /// A `rowsRange` answer body `_loadOlder` parses (window + hasMore + the
  /// epoch the live subscription matches).
  Map<String, dynamic> olderPage(int from, int to, {required bool hasMore}) => {
    'atLogEpoch': 'e1',
    'hasMore': hasMore,
    'rows': {'window': historyRows(from, to)},
  };

  /// A prepended page whose OLDEST row is a ~60-line message (row height
  /// far beyond the test viewport): the row-height variance the SliverList
  /// extent estimate cannot capture — the guardrail fixture for the
  /// measured-delta anchor compensation.
  Map<String, dynamic> tallHeadPage(int from, int to, {required bool hasMore}) => {
    'atLogEpoch': 'e1',
    'hasMore': hasMore,
    'rows': {
      'window': [
        {
          'rowId': from,
          'kind': 'userInput',
          'text': List.generate(60, (i) => '长消息行 $i').join('\n'),
        },
        ...historyRows(from + 1, to),
      ],
    },
  };

  /// Long-history page: held window rows 100..111 with older pages queued
  /// on the gateway — entry 0 always goes to the open auto-load. The
  /// snapshot is fed BEFORE mounting: the open auto-load reads
  /// `canLoadOlder` inside the subscribe continuation, which runs before a
  /// post-mount feed would land.
  Future<FakeChatGateway> pumpHistory(
    WidgetTester tester, {
    required List<Object?> pages,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final gateway = FakeChatGateway();
    gateway.rowsRangeResults.addAll(pages);
    gateway.feedSnapshot(
      historyRows(100, 111),
      firstRowId: 1,
      totalCount: 111,
    );
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    await tester.pumpAndSettle();
    return gateway;
  }

  ScrollController historyController(WidgetTester tester) =>
      tester.widget<ListView>(messageList()).controller!;

  int rowsRangeCalls(FakeChatGateway gateway) =>
      gateway.calls.where((c) => c.$1 == 'rowsRange').length;

  /// Drag depth landing mid-window (past the max(64, 2×viewport) prefetch
  /// threshold, still in range so the anchor offset stays positive).
  double inWindowDrag(ScrollController controller) =>
      controller.offset -
      math.max(64.0, controller.position.viewportDimension * 2) / 2;

  /// Message texts currently built inside the list viewport — the
  /// "what the reader sees" set for the anchor assertions. User bubbles and
  /// assistant prose render as [Text] since M0 (quote-comment-lite);
  /// [SelectableText] survives only in expanded code blocks, and is matched
  /// too. The compensation jump approximates the exact offset within
  /// SliverList's trailing-extent estimate, so anchoring is asserted
  /// semantically: the visible set must survive the load (a teleport to
  /// the page top or bottom would show none of the old messages).
  Set<String> visibleMessages(WidgetTester tester) {
    final texts = <String>{};
    for (final w in tester.widgetList<Text>(
      find.descendant(of: messageList(), matching: find.byType(Text)),
    )) {
      final data = w.data ?? w.textSpan?.toPlainText();
      if (data != null) texts.add(data);
    }
    for (final w in tester.widgetList<SelectableText>(
      find.descendant(
        of: messageList(),
        matching: find.byType(SelectableText),
      ),
    )) {
      final data = w.data ?? w.textSpan?.toPlainText();
      if (data != null) texts.add(data);
    }
    return texts;
  }

  /// The topmost visible history message: (text, screen Y of its top) —
  /// the reading anchor for pixel-level displacement assertions.
  (String, double) topmostHistoryMessage(WidgetTester tester) {
    final entries = <(String, double)>[];
    void collect(Widget widget, String? text) {
      final data = text ?? '';
      if (!data.startsWith('历史消息')) return;
      final box = tester.renderObject(find.byWidget(widget)) as RenderBox;
      entries.add((data, box.localToGlobal(Offset.zero).dy));
    }

    for (final w in tester.widgetList<Text>(
      find.descendant(of: messageList(), matching: find.byType(Text)),
    )) {
      collect(w, w.data ?? w.textSpan?.toPlainText());
    }
    for (final w in tester.widgetList<SelectableText>(
      find.descendant(
        of: messageList(),
        matching: find.byType(SelectableText),
      ),
    )) {
      collect(w, w.data ?? w.textSpan?.toPlainText());
    }
    entries.sort((a, b) => a.$2.compareTo(b.$2));
    return entries.first;
  }

  testWidgets('history: dragging toward the top prefetches the older page '
      '(official web parity)', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    // The prefetch fetch is held open so the pre-load viewport (laid out
    // mid-window) is stable to capture before the compensation lands.
    final held = Completer<dynamic>();
    final transport = _SequencedRowsTransport()
      ..queue.add(
        Completer<dynamic>()..complete(olderPage(60, 99, hasMore: true)),
      )
      ..queue.add(held);
    final gateway = _SequencedRowsGateway(transport);
    gateway.feedSnapshot(historyRows(100, 111), firstRowId: 1, totalCount: 111);
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    await tester.pumpAndSettle();
    final controller = historyController(tester);
    // Exactly one call despite the open animation sweeping the window —
    // programmatic positioning parks the trigger.
    expect(transport.calls.length, 1, reason: 'open auto-load consumed page 1');

    final gesture = await tester.startGesture(
      tester.getCenter(messageList()),
    );
    await tester.pump();
    await gesture.moveBy(Offset(0, inWindowDrag(controller)));
    await tester.pump(); // laid out mid-window; the fetch is still held
    final visibleBefore = visibleMessages(tester);
    expect(visibleBefore, isNotEmpty);
    // Release before the load lands: the anchor compensation defers while a
    // finger is down (a jumpTo under an active drag kills the gesture), and
    // the bounce+landing then run inside the settle below.
    await gesture.up();
    await tester.pump();
    held.complete(olderPage(20, 59, hasMore: false));
    await tester.pumpAndSettle();

    expect(transport.calls.length, 2, reason: 'prefetch fired once');
    expect(transport.calls[1], 60, reason: 'cursor = oldest held row');
    // Anchored (semantic): the reader's messages survive the load, and the
    // view moved off the page top without teleporting to an edge (see
    // [visibleMessages] for why this is not an exact-pixel assertion).
    expect(visibleMessages(tester).intersection(visibleBefore), isNotEmpty);
    expect(controller.offset, greaterThan(0.0));
  });

  testWidgets('history: reading mid-list does not prefetch', (tester) async {
    final gateway = await pumpHistory(
      tester,
      pages: [olderPage(60, 99, hasMore: true), olderPage(20, 59, hasMore: false)],
    );
    final controller = historyController(tester);
    final threshold = math.max(64.0, controller.position.viewportDimension * 2);
    // Well outside the window: depth from the bottom stays below
    // maxScrollExtent - threshold even after a short upward drag.
    controller.jumpTo(
      controller.position.maxScrollExtent - threshold - 500,
    );
    await tester.pumpAndSettle();
    expect(rowsRangeCalls(gateway), 1);

    final gesture = await tester.startGesture(
      tester.getCenter(messageList()),
    );
    await tester.pump();
    await gesture.moveBy(const Offset(0, 100));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(rowsRangeCalls(gateway), 1, reason: 'still outside the window');
  });

  testWidgets('history: an upward fling prefetches during the coast',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final gateway = FakeChatGateway();
    gateway.rowsRangeResults.addAll([
      olderPage(60, 99, hasMore: true),
      olderPage(20, 59, hasMore: false),
    ]);
    // Tall history (140 rows after the open auto-load): maxScrollExtent sits
    // far above the window edge, so the fling's drag phase stays outside the
    // prefetch window and only the ballistic coast crosses into it.
    gateway.feedSnapshot(historyRows(100, 199), firstRowId: 1, totalCount: 199);
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    await tester.pumpAndSettle();
    final controller = historyController(tester);
    final threshold = math.max(64.0, controller.position.viewportDimension * 2);
    // Park just above the window; the jump itself must not prefetch.
    controller.jumpTo(threshold + 400);
    await tester.pumpAndSettle();
    expect(rowsRangeCalls(gateway), 1);

    // Fling upward: the ~282px applied drag keeps every drag frame above the
    // window edge; the release hands over to a ballistic coast (frames with
    // dragDetails == null, not parked) — its crossing into the window is
    // what must trigger the prefetch. AC: 快速上翻 approaching the top loads
    // once without needing to touch the top.
    await tester.fling(
      messageList(),
      const Offset(0, 300),
      2000,
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(rowsRangeCalls(gateway), 2, reason: 'coast frames prefetch');
  });

  testWidgets('history: the prefetch trigger parks while a load is in flight',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final held = Completer<dynamic>();
    final transport = _SequencedRowsTransport()
      ..queue.add(held) // open auto-load: held in flight
      ..queue.add(
        Completer<dynamic>()..complete(olderPage(20, 59, hasMore: true)),
      );
    final gateway = _SequencedRowsGateway(transport);
    // Feed before mounting so the open auto-load engages (see pumpHistory).
    // 30 held rows: taller than the viewport, so the window arithmetic has
    // a real mid-window to drag into while the open load is still pending.
    gateway.feedSnapshot(historyRows(100, 129), firstRowId: 1, totalCount: 129);
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    // Finite pumps: the held load keeps the top button's spinner animating,
    // pumpAndSettle would time out on it. 400ms: the open follow's 200ms
    // ease must finish first — arming waits out any programmatic scroll
    // (see _armLoadOlder), so the auto-load's request only leaves after
    // the view has settled at the bottom.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(transport.calls.length, 1, reason: 'open auto-load in flight');

    final controller = historyController(tester);
    // Drag into the window: the in-flight load keeps the trigger parked.
    final gesture = await tester.startGesture(
      tester.getCenter(messageList()),
    );
    await tester.pump();
    await gesture.moveBy(Offset(0, inWindowDrag(controller)));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(transport.calls.length, 1, reason: '_loadingOlder blocks the retrigger');

    // The load completes (still hasMore — keep the trigger armed); the
    // prepend's anchor compensation lands with a FRESH measure (round 18:
    // the anchor is measured at the prepend, not armed pre-fetch — whatever
    // the reader drifted to during the round trip IS the anchored position),
    // so the viewport is pinned at the drag's resting offset: the reading
    // position survives, and the re-entry gate releases once the chain
    // settles. The pin leaves the viewport FAR from the window (a full page
    // of older rows now sits above it), so the re-fire must first bring the
    // offset back into the window — a programmatic jump does not count as
    // user-driven (by design), then a small in-window drag prefetches.
    held.complete(olderPage(60, 99, hasMore: true));
    await tester.pumpAndSettle();

    // Park back INSIDE the window (a programmatic jump does not count as
    // user-driven — by design), then a small in-window drag prefetches.
    controller.jumpTo(600);
    await tester.pumpAndSettle();
    final gesture2 = await tester.startGesture(
      tester.getCenter(messageList()),
    );
    await tester.pump();
    await gesture2.moveBy(const Offset(0, 50)); // inside the window
    await tester.pump();
    await gesture2.up();
    await tester.pumpAndSettle();
    expect(transport.calls.length, 2);
  });

  testWidgets('history: no elasticity and no prefetch once all history is '
      'loaded', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot(historyRows(1, 40)); // no firstRowId → nothing older
    await tester.pumpAndSettle();
    final controller = historyController(tester);
    controller.jumpTo(0);
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getCenter(messageList()),
    );
    await tester.pump();
    await gesture.moveBy(const Offset(0, 300));
    await tester.pump();
    expect(controller.offset, 0.0,
        reason: 'platform clamp: no rubber-band without older history');
    await gesture.up();
    await tester.pumpAndSettle();
    expect(rowsRangeCalls(gateway), 0);
  });

  testWidgets('history: pulling past the threshold loads and lands reading '
      'the fresh page at the top', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    // The release-frame load is held open so the button's spinner is stable
    // to assert — an instant answer flips _loadingOlder back before a
    // frame renders it.
    final held = Completer<dynamic>();
    final transport = _SequencedRowsTransport()
      ..queue.add(
        Completer<dynamic>()..complete(olderPage(60, 99, hasMore: true)),
      )
      ..queue.add(held);
    final gateway = _SequencedRowsGateway(transport);
    gateway.feedSnapshot(historyRows(100, 111), firstRowId: 1, totalCount: 111);
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    await tester.pumpAndSettle();

    final controller = historyController(tester);
    controller.jumpTo(0);
    await tester.pumpAndSettle();
    final visibleBefore = visibleMessages(tester);
    expect(visibleBefore, isNotEmpty);

    final gesture = await tester.startGesture(
      tester.getCenter(messageList()),
    );
    await tester.pump();
    await gesture.moveBy(const Offset(0, 300));
    await tester.pump();
    expect(controller.offset, lessThan(-64.0),
        reason: 'content follows the finger past the threshold');
    await gesture.up();
    // The first pump after up() only starts the ballistic activity (its
    // first tick runs at t=0, no movement); a second, time-advancing pump
    // produces the first real spring tick — the release frame.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    // Release-frame load: the top button flips to its spinner at once.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    held.complete(olderPage(20, 59, hasMore: false));
    await tester.pumpAndSettle();

    expect(transport.calls.length, 2);
    expect(transport.calls[1], 60, reason: 'cursor = oldest held row');
    // Anchored from the tail (round 23 reinstated): the reader keeps their
    // position — the pre-load messages stay on screen and the offset moves
    // by exactly the prepended height, so reading continues UP INTO the
    // fresh page's newest end. (Round 22 briefly showed the fresh page's
    // HEAD at offset 0; the reader reported the discontinuity — "不是按照
    // 历史的尾部进入".)
    expect(visibleMessages(tester).intersection(visibleBefore), isNotEmpty);
    expect(controller.offset, greaterThan(0.0));
  });

  testWidgets('history: shallow pull springs back without loading',
      (tester) async {
    final gateway = await pumpHistory(
      tester,
      pages: [olderPage(60, 99, hasMore: true), olderPage(20, 59, hasMore: false)],
    );
    final controller = historyController(tester);
    controller.jumpTo(0);
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getCenter(messageList()),
    );
    await tester.pump();
    await gesture.moveBy(const Offset(0, 50)); // one step: no damping yet
    await tester.pump();
    expect(controller.offset, lessThan(0.0));
    expect(controller.offset, greaterThan(-64.0), reason: 'below the threshold');
    await gesture.up();
    await tester.pumpAndSettle();

    expect(controller.offset, 0.0, reason: 'springs back without loading');
    expect(rowsRangeCalls(gateway), 1);
  });

  testWidgets('history: nested scrollables do not trigger the prefetch',
      (tester) async {
    // A collapsed long bubble clips behind its own scrollable inside the
    // list subtree; dragging it must not fire the history trigger (the
    // notification bubbles through _onListScroll, which routes by position
    // identity — same pattern as _onListMetrics).
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final gateway = FakeChatGateway();
    gateway.rowsRangeResults.addAll([
      olderPage(60, 99, hasMore: true),
      olderPage(20, 59, hasMore: false),
    ]);
    final longText = List.filled(30, '一行长文本内容').join('\n');
    gateway.feedSnapshot(
      [
        ...historyRows(100, 111),
        {'rowId': 112, 'kind': 'userInput', 'text': longText, 'state': 'done'},
      ],
      firstRowId: 1,
      totalCount: 113,
    );
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    await tester.pumpAndSettle();
    // Baseline: only the open auto-load fired.
    expect(rowsRangeCalls(gateway), 1);

    final clip = find.ancestor(
      of: find.textContaining('一行长文本内容'),
      matching: find.byType(SingleChildScrollView),
    );
    expect(clip, findsOneWidget);
    // Nested pixels sit at 0 — squarely inside the prefetch window — so an
    // unrouted notification would fire the fetch (P1 from the 09-21 check).
    await tester.drag(clip, const Offset(0, -40));
    await tester.pump();
    expect(rowsRangeCalls(gateway), 1, reason: 'nested drag is not the list');
  });

  testWidgets('history: page-boundary turn regroup keeps the anchor '
      '(rowId fallback)', (tester) async {
    // Real-device bug shape (09-21 round 2): rowsRange pages cut turns
    // arbitrarily. Page 1 OPENS with an assistant row (unstable data-head
    // group); page 2 CLOSES with one. When page 2 prepends, both merge into
    // the group above — the old head group's key ('turn-59') vanishes — and
    // the compensation used to lose the anchor and crawl to the list end
    // ("yanked to the bottom"). The rowId fallback must land the reader
    // back on the regrouped content instead.
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    Map<String, dynamic> assistant(int id, String text) => {
      'rowId': id,
      'kind': 'assistantText',
      'text': text,
      'state': 'done',
    };
    final gateway = FakeChatGateway();
    gateway.rowsRangeResults.addAll([
      {
        'atLogEpoch': 'e1',
        'hasMore': true,
        'rows': {
          'window': [assistant(59, '页1首段'), ...historyRows(60, 98)],
        },
      },
      {
        'atLogEpoch': 'e1',
        'hasMore': false,
        'rows': {
          'window': [...historyRows(20, 57), assistant(58, '页2尾段')],
        },
      },
    ]);
    gateway.feedSnapshot(historyRows(100, 111), firstRowId: 1, totalCount: 111);
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    await tester.pumpAndSettle();
    final controller = historyController(tester);
    expect(rowsRangeCalls(gateway), 1, reason: 'open auto-load took page 1');

    // Reader reads near the top: the first visible group is the unstable
    // data-head group 'turn-59' — exactly the anchor the regroup will
    // orphan. Fire the load by a small in-window drag (the prefetch path):
    // R22 split the semantics — AT the very head (offset < 1) a load means
    // "read the fresh page" and never anchors, but from mid-window it is a
    // reading-position anchor and the full chain (rowId fallback included)
    // must run. A tap on the button is unusable here: it only exists at
    // offset 0.
    controller.jumpTo(0);
    await tester.pumpAndSettle();
    // Markdown bubbles render as Text.rich (data == null), so the
    // visible-messages helper skips them — assert on the widget directly.
    expect(find.textContaining('页1首段'), findsOneWidget);

    final gesture = await tester.startGesture(
      tester.getCenter(messageList()),
    );
    await tester.pump();
    await gesture.moveBy(const Offset(0, -50)); // into the window, not the head
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(rowsRangeCalls(gateway), 2);
    // Not yanked: the viewport stays far off the list end…
    expect(
      controller.offset,
      lessThan(controller.position.maxScrollExtent - 844),
      reason: 'regrouped anchor must not strand the view at the bottom',
    );
    // …and the reader is still ON the anchor content: '页1首段' (row 59,
    // regrouped into 57..59 by the page-boundary merge) must sit at the
    // viewport top again — the rowId fallback lands the merged group a few
    // lines deep, well inside the first screenful. Bare existence in the
    // built window is NOT enough (the estimate crawl can park mid-list and
    // still have it mounted near the window edge).
    final seg1Top =
        tester.renderObject(find.textContaining('页1首段')) as RenderBox;
    final seg1Dy = seg1Top.localToGlobal(Offset.zero).dy;
    expect(seg1Dy, inInclusiveRange(-50, 400), reason: 'dy=$seg1Dy');
  });

  testWidgets('history: the load-older button lands reading the fresh page '
      'at the top (round 22)', (tester) async {
    final gateway = await pumpHistory(
      tester,
      pages: [
        olderPage(60, 99, hasMore: true),
        olderPage(20, 59, hasMore: true),
        olderPage(1, 19, hasMore: false),
      ],
    );
    final controller = historyController(tester);
    // Reach the top by a jump (programmatic): it must not prefetch, the
    // button is row 0 and visible there.
    controller.jumpTo(0);
    await tester.pumpAndSettle();
    expect(rowsRangeCalls(gateway), 1);
    final visibleBefore = visibleMessages(tester);

    await tester.tap(find.text('加载更早消息'));
    await tester.pumpAndSettle();

    expect(rowsRangeCalls(gateway), 2);
    final buttonLoad =
        gateway.calls.where((c) => c.$1 == 'rowsRange').toList().last;
    expect(buttonLoad.$2[1], 60);
    // Anchored from the tail (round 23 reinstated — same semantics as the
    // pull gesture and the prefetch): the reading position at the top
    // survives; reading continues up into the fresh page's newest end.
    expect(visibleMessages(tester).intersection(visibleBefore), isNotEmpty);
    expect(controller.offset, greaterThan(0.0));
  });

  testWidgets('history: anchor compensation is immune to extent-estimate '
      'error (tall prepended rows)', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    // The second page is held in flight so the mid-window viewport is
    // stable to measure before the prepend lands.
    final held = Completer<dynamic>();
    final transport = _SequencedRowsTransport()
      ..queue.add(
        Completer<dynamic>()..complete(olderPage(60, 99, hasMore: true)),
      )
      ..queue.add(held);
    final gateway = _SequencedRowsGateway(transport);
    gateway.feedSnapshot(historyRows(100, 111), firstRowId: 1, totalCount: 111);
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    await tester.pumpAndSettle();
    final controller = historyController(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(messageList()),
    );
    await tester.pump();
    await gesture.moveBy(Offset(0, inWindowDrag(controller)));
    await tester.pump(); // laid out mid-window; the fetch is still held
    final (anchorText, anchorTopBefore) = topmostHistoryMessage(tester);
    // Release before the load lands (the compensation defers under a finger
    // — see the prefetch test above).
    await gesture.up();
    await tester.pump();
    // The prepended page leads with a 60-line row: the SliverList extent
    // past the built window misses the real prepended height by a wide
    // margin. The old Δmax anchor arithmetic jumped by exactly that error
    // (device bug 2026-09-21); the measured group delta must land within
    // float noise of the reading position.
    held.complete(tallHeadPage(20, 59, hasMore: false));
    await tester.pumpAndSettle();

    final anchorTopAfter = tester.getTopLeft(find.text(anchorText)).dy;
    expect((anchorTopAfter - anchorTopBefore).abs(), lessThan(8.0),
        reason: 'reading anchor stays put through the load');
    expect(controller.offset,
        lessThanOrEqualTo(controller.position.maxScrollExtent + 0.5),
        reason: 'no overshoot into the unpainted region');
  });

  testWidgets('history: open auto-load with a tall page lands pinned on the '
      'true bottom (no overshoot)', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final gateway = FakeChatGateway();
    gateway.rowsRangeResults.addAll([tallHeadPage(20, 59, hasMore: false)]);
    // Fed before mounting so the open auto-load engages (see pumpHistory):
    // the stick prepend path must re-land on the REAL newest end instead of
    // riding an extent estimate that a tall row can skew.
    gateway.feedSnapshot(historyRows(100, 111), firstRowId: 1, totalCount: 111);
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    await tester.pumpAndSettle();

    final controller = historyController(tester);
    // Pinned at the TRUE bottom: offset == max means the content end (last
    // group + bottom padding) fills the viewport exactly — no blank tail
    // past the end (the overshoot bug), no undershoot (the estimate bug).
    expect(controller.offset, closeTo(controller.position.maxScrollExtent, 0.5));
    final listBox = tester.renderObject(messageList()) as RenderBox;
    final viewportTop = listBox.localToGlobal(Offset.zero).dy;
    final viewportBottom = viewportTop + listBox.size.height;
    // The newest message text is on screen, just above the viewport bottom
    // (its group bottom plus the list padding IS the content end).
    final lastBottom = tester.getBottomRight(find.text('历史消息 111')).dy;
    expect(lastBottom, lessThanOrEqualTo(viewportBottom));
    expect(lastBottom, greaterThanOrEqualTo(viewportTop));
  });

  testWidgets('history: the open auto-load stays pinned through its own '
      'follow — a stale extent estimate must not turn the first landing into '
      'the reading anchor (A7 device acceptance)', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    // Tail window with a tall row AFTER the first screenful: the SliverList
    // extent estimate at the top is short, the open follow's 200ms descent
    // grows it, and the animation ends at its stale target — the exact
    // device shape behind A7. Once that mid-flight `stick=false` sample
    // stuck, the prepend anchored to the reading position and the viewport
    // parked mid-history with the jump button up.
    final tail = [
      ...historyRows(100, 139),
      {
        'rowId': 140,
        'kind': 'userInput',
        'text': ['历史消息 140', ...List.generate(60, (i) => '长尾行 $i')]
            .join('\n'),
      },
      ...historyRows(141, 144),
    ];
    final held = Completer<dynamic>();
    final transport = _SequencedRowsTransport()..queue.add(held);
    final gateway = _SequencedRowsGateway(transport);
    gateway.feedSnapshot(tail, firstRowId: 1, totalCount: 144);
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    await tester.pump(); // subscribe lands: the list mounts, the follow posts
    await tester.pumpAndSettle(); // the glide finishes on its stale target
    final controller = historyController(tester);
    expect(transport.calls, hasLength(1),
        reason: 'the open auto-load is the page in flight');
    // Fixture precondition (the device shape): the follow's 200ms descent
    // itself revises the extent estimate upward, so it ends short of the
    // real max — its mid-flight samples read `pixels < max - 40`.
    expect(
      controller.position.maxScrollExtent - controller.offset,
      greaterThan(40),
      reason: 'the follow ends at its stale target while the estimate grew',
    );

    held.complete(olderPage(60, 99, hasMore: true));
    await tester.pumpAndSettle();

    expect(
      controller.position.maxScrollExtent - controller.offset,
      lessThanOrEqualTo(40),
      reason: 'the open must land on the newest content — the pin the follow '
          'animation is carrying must survive the prepend chain',
    );
    expect(find.text('历史消息 144'), findsOneWidget,
        reason: 'the newest message is on screen after the open settles');
  });

  testWidgets('history: the prepend veil hides the guess frame and lifts on '
      'landing (never a frozen blank list)', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final held = Completer<dynamic>();
    final transport = _SequencedRowsTransport()..queue.add(held);
    final gateway = _SequencedRowsGateway(transport);
    gateway.feedSnapshot(historyRows(100, 129), firstRowId: 1, totalCount: 129);
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    await tester.pumpAndSettle();

    // Fire the load with a user-driven drag inside the prefetch window
    // (programmatic jumps don't arm it by design).
    final controller = historyController(tester);
    controller.jumpTo(600);
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(messageList()),
    );
    await tester.pump();
    await gesture.moveBy(const Offset(0, 50));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(transport.calls.length, 1);

    // Round 21: between the prepend's first frame and the measured landing
    // the list paints TRANSPARENT (the landing offset is a guess until the
    // prepend's layout runs — showing the guess was the load-point jump),
    // then the landing lifts the veil. A veil that never lifts is a frozen
    // blank list, so both ends are pinned here.
    held.complete(olderPage(60, 99, hasMore: true));
    await tester.pump(); // arrival microtask resumes; prepend post-frames
    await tester.pump(); // prepend applies: veil setState lands
    await tester.pump(); // veiled frame renders; post-frame chain lands
    final veil = find
        .ancestor(of: messageList(), matching: find.byType(Opacity))
        .first;
    expect(tester.widget<Opacity>(veil).opacity, 0.0,
        reason: 'the prepend frame must paint behind the veil');
    await tester.pumpAndSettle();
    expect(tester.widget<Opacity>(veil).opacity, 1.0,
        reason: 'the measured landing must lift the veil');
  });

  testWidgets('shell session: error displayStatus + zero rows shows the '
      'start-failed card', (tester) async {
    final gateway = FakeChatGateway()..taskDisplayStatuses['s1'] = 'error';
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    // A shell session: the subscription lands with zero rows.
    gateway.feedSnapshot([]);
    await tester.pump();
    await tester.pump();

    expect(find.text('会话未能启动'), findsOneWidget);
    expect(find.text('会话未能启动，请重试或检查模型/思考档配置。'),
        findsOneWidget);
  });

  group('start-failed card two states (11-08-error-detail AC3)', () {
    testWidgets('with a task lastError the body is the real message and the '
        'card opens the sheet', (tester) async {
      final gateway = FakeChatGateway()
        ..taskDisplayStatuses['s1'] = 'error'
        ..taskLastErrors['s1'] = const {
          'message': 'createSession rejected: no available model',
          'code': 'no_model',
          'traceId': 'tr-9',
          'attribution': 'relay',
        };
      await tester.pumpWidget(
        wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
      );
      gateway.feedSnapshot([]);
      await tester.pump();
      await tester.pump();

      expect(find.text('会话未能启动'), findsOneWidget);
      expect(find.text('createSession rejected: no available model'),
          findsOneWidget);
      // The generic advice is REPLACED, not stacked under the real error.
      expect(find.text('会话未能启动，请重试或检查模型/思考档配置。'),
          findsNothing);

      await tester.tap(find.text('createSession rejected: no available '
          'model'));
      await tester.pumpAndSettle();
      expect(find.text('最近一次错误'), findsOneWidget);
      expect(find.text('tr-9'), findsOneWidget);
      expect(find.text('复制完整报错'), findsOneWidget);
    });

    testWidgets('without a lastError the generic advice stays and the card is '
        'inert', (tester) async {
      final gateway = FakeChatGateway()
        ..taskDisplayStatuses['s1'] = 'error';
      await tester.pumpWidget(
        wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
      );
      gateway.feedSnapshot([]);
      await tester.pump();
      await tester.pump();

      expect(find.text('会话未能启动，请重试或检查模型/思考档配置。'),
          findsOneWidget);
      // Tapping the advice must NOT raise a sheet (a dead end otherwise).
      await tester.tap(find.text('会话未能启动'));
      await tester.pumpAndSettle();
      expect(find.text('最近一次错误'), findsNothing);
    });

    testWidgets('the error meta is re-read when the task list notifies '
        '(host listener, not the conversation state)', (tester) async {
      final gateway = FakeChatGateway()
        ..taskDisplayStatuses['s1'] = 'error';
      await tester.pumpWidget(
        wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
      );
      gateway.feedSnapshot([]);
      await tester.pump();
      await tester.pump();
      expect(find.text('会话未能启动，请重试或检查模型/思考档配置。'),
          findsOneWidget);

      // The relay overview lands later: the row now carries the error, and
      // the only notification is the HOST's (the state never changes).
      gateway.taskLastErrors['s1'] = const {'message': 'late relay error'};
      gateway.notifyListeners();
      await tester.pump();
      await tester.pump();

      expect(find.text('late relay error'), findsOneWidget);
    });

    testWidgets('a failed turn renders the preview line and keeps the empty '
        'card out of the way', (tester) async {
      final gateway = FakeChatGateway()
        ..taskLastErrors['s1'] = const {
          'message': '429 Rate limit exceeded',
          'traceId': 'trc_1',
        };
      await tester.pumpWidget(
        wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
      );
      gateway.feedSnapshot([
        {'rowId': 1, 'kind': 'userInput', 'text': '帮我修复登录'},
        {'rowId': 2, 'kind': 'turnHeader', 'state': 'error'},
      ]);
      await tester.pump();
      await tester.pump();

      expect(find.text('出错'), findsOneWidget);
      expect(find.text('429 Rate limit exceeded'), findsOneWidget);
      expect(find.text('会话未能启动'), findsNothing);
    });

    testWidgets('the draft page (no session id) never shows the preview — '
        'there is no task row to read', (tester) async {
      final gateway = FakeChatGateway()
        ..taskLastErrors['s1'] = const {'message': 'ghost error'};
      await tester.pumpWidget(
        wrap(ChatPage(host: gateway, title: 'new task')),
      );
      await tester.pump();
      expect(find.text('ghost error'), findsNothing);
    });
  });

  testWidgets('shell session: error displayStatus with rows keeps the normal '
      'list — no card', (tester) async {
    final gateway = FakeChatGateway()..taskDisplayStatuses['s1'] = 'error';
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '帮我修复登录'},
    ]);
    await tester.pump();
    await tester.pump();

    expect(find.text('会话未能启动'), findsNothing);
    expect(find.text('帮我修复登录'), findsOneWidget);
  });

  testWidgets('shell session: mirror miss renders the plain empty hint and a '
      'late displayStatus error flip raises the card live', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([]);
    await tester.pump();
    await tester.pump();

    // Relay overview not arrived (lookup miss → null): plain empty hint.
    expect(find.text('暂无消息'), findsOneWidget);
    expect(find.text('会话未能启动'), findsNothing);

    // The refresh rides the gateway's notifier, not the state's —
    // the double-listen must re-evaluate the gate without a state change.
    gateway.taskDisplayStatuses['s1'] = 'error';
    gateway.notifyListeners();
    await tester.pump();
    await tester.pump();

    expect(find.text('会话未能启动'), findsOneWidget);
  });

  testWidgets('config revert: an authoritative snapshot overriding an '
      'armed lost-ack trace surfaces the switchReverted snack', (tester) async {
    final gateway = FakeChatGateway()
      ..snapshotExtra = {
        'config': {
          'provider': 'builtin',
          'model': 'builtin/glm-5.2',
          'thought': 'enabled',
        },
      };
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '帮我修复登录'},
    ]);
    await tester.pump();
    await tester.pump();

    // The switch timed out and the sheet landed the patch AND armed the
    // revert trace (the lost-ack path, design 10-02 Step 3). No sheet
    // record exists in this direct injection, so the flag lands straight
    // on the revert snack instead of the auto-retry.
    gateway.state.optimisticPatch({
      'config': {
        'provider': 'builtin',
        'model': 'builtin/glm-5.2-air',
        'thought': 'enabled',
      },
    });
    gateway.state.armConfigRevertTrace({
      'config': {
        'provider': 'builtin',
        'model': 'builtin/glm-5.2-air',
        'thought': 'enabled',
      },
    });
    await tester.pump();

    // The command was lost in a bridge swing; the resubscribe snapshot
    // replays the desktop's old config → one-shot revert flag → snack.
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '帮我修复登录'},
    ]);
    await tester.pump();
    await tester.pump();

    expect(find.text('模型/思考切换未生效，已恢复为桌面当前设置'), findsOneWidget);
  });

  // ---------------- bridge-lost switch auto-retry (design 10-01) -----------

  /// Desktop config the authoritative snapshots keep replaying (the switch
  /// command died in the bridge swing, so the desktop never saw it).
  Map<String, dynamic> desktopBaselineConfig() => {
    'provider': 'builtin',
    'model': 'builtin/glm-5.2',
    'thought': 'enabled',
  };

  /// Pumps a chat page, walks the config sheet to switch GLM-5.2 → Air,
  /// and hands back the gateway + transport for the revert choreography.
  /// [results] feeds [_SwitchTransport]: empty = the switch is accepted
  /// (sheet closes with the pending toast「已切换，下一条消息生效」); a
  /// TimeoutException entry = lost ack (patch lands, trace arms, same
  /// pending toast).
  Future<(_SwitchGateway, _SwitchTransport)> pumpSheetSwitch(
    WidgetTester tester, {
    List<Object?> results = const [],
  }) async {
    final transport = _SwitchTransport(results: results);
    final gateway = _SwitchGateway(transport);
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '帮我修复登录'},
    ]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('模型')); // placeholder chip
    await tester.pumpAndSettle();
    await tester.tap(find.text('GLM-5.2 Air'));
    await tester.pumpAndSettle();
    expect(transport.switches, hasLength(1));
    return (gateway, transport);
  }

  /// Lets the SnackBar currently on stage expire so a queued one takes
  /// the stage: first let it finish entering (its 4s dismiss timer only
  /// starts at entrance-complete), then advance past its expiry —
  /// pumpAndSettle alone never reaches the dismiss timer (fc7b03b).
  Future<void> advancePastShowingToast(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }

  testWidgets('switch retry: after a lost-ack timeout, an in-window '
      'authoritative override re-sends the same switch once, shows the '
      'retrying toast, and a confirming frame raises no revert notice',
      (tester) async {
    final (gateway, transport) = await pumpSheetSwitch(
      tester,
      results: [TimeoutException('switchModelConfig')],
    );
    final first = transport.switches.single;
    // The lost-ack path landed the patch: the chip reads the switch...
    expect(find.text('glm-5.2-air'), findsOneWidget);
    // ...and closed the sheet with the pending toast.
    expect(find.text('已切换，下一条消息生效'), findsOneWidget);

    // The resubscribe snapshot replays the desktop's old config → the
    // armed trace fires → the page auto-retries with the same parameters.
    gateway.snapshotExtra = {'config': desktopBaselineConfig()};
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '帮我修复登录'},
    ]);
    await tester.pump();
    await tester.pump();

    expect(transport.switches, hasLength(2));
    expect(transport.switches.last, first);
    // The retrying toast queues behind the still-showing pending toast.
    await advancePastShowingToast(tester);
    expect(find.text('切换未生效，正在重试…'), findsOneWidget);
    // The retry re-landed the optimistic patch: the chip reads the
    // switched model again (it was rolled back by the old-config
    // snapshot in between).
    expect(find.text('glm-5.2-air'), findsOneWidget);

    // A later authoritative frame CONFIRMING the switch is no override —
    // no revert notice, no further sends.
    gateway.snapshotExtra = {
      'config': {
        'provider': 'builtin',
        'model': 'glm-5.2-air',
        'thought': 'enabled',
      },
    };
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '帮我修复登录'},
    ]);
    await tester.pump();
    expect(find.text('模型/思考切换未生效，已恢复为桌面当前设置'), findsNothing);
    expect(transport.switches, hasLength(2));
  });

  testWidgets('switch retry: a retry that dies too falls back to the '
      'revert notice — no retry loop', (tester) async {
    final (gateway, transport) = await pumpSheetSwitch(
      tester,
      results: [
        TimeoutException('switchModelConfig'),
        TimeoutException('retry also lost'),
      ],
    );

    gateway.snapshotExtra = {'config': desktopBaselineConfig()};
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '帮我修复登录'},
    ]);
    await tester.pump();
    await tester.pump();
    expect(transport.switches, hasLength(2)); // exactly the one auto-retry

    // The retry's transport call threw: the honest revert notice queues
    // behind the still-showing pending toast.
    await advancePastShowingToast(tester);
    expect(find.text('模型/思考切换未生效，已恢复为桌面当前设置'), findsOneWidget);
    expect(find.text('切换未生效，正在重试…'), findsNothing);

    // A further old-config snapshot finds no armed trace (the flag
    // consumed the arm; the failed retry never re-arms) — no third send.
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '帮我修复登录'},
    ]);
    await tester.pump();
    await tester.pump();
    expect(transport.switches, hasLength(2));
  });

  testWidgets('switch retry: an override past the 15s window reverts '
      'directly with zero re-sends', (tester) async {
    final (gateway, transport) = await pumpSheetSwitch(
      tester,
      results: [TimeoutException('switchModelConfig')],
    );

    // Stale past the retry window (still inside the state's 60s trace
    // freshness, so the revert flag does fire): straight to the notice.
    await tester.pump(const Duration(seconds: 16));
    gateway.snapshotExtra = {'config': desktopBaselineConfig()};
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '帮我修复登录'},
    ]);
    await tester.pump();

    expect(transport.switches, hasLength(1));
    expect(find.text('切换未生效，正在重试…'), findsNothing);
    // The 16s advance already expired the pending toast, so the revert
    // notice takes the stage directly — just let its entrance settle
    // (advancing past ANOTHER 4s cycle would dismiss it again).
    await tester.pumpAndSettle();
    expect(find.text('模型/思考切换未生效，已恢复为桌面当前设置'), findsOneWidget);
  });

  testWidgets('accepted switch: a stale old-config snapshot is the desktop '
      'pending semantics — the switch confirmation toast only, zero '
      're-sends (AC8)', (tester) async {
    final (gateway, transport) = await pumpSheetSwitch(tester); // accepted

    // The sheet closed with the confirmation toast aligned to the
    // pending semantics (design 10-02 Step 3).
    expect(find.text('已切换，下一条消息生效'), findsOneWidget);

    // The authoritative snapshot still replays the OLD config (the
    // desktop applies the switch on the next message). Without an armed
    // trace this must stay silent: no revert notice, no auto-retry.
    gateway.snapshotExtra = {'config': desktopBaselineConfig()};
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '帮我修复登录'},
    ]);
    await tester.pump();
    await tester.pump();

    expect(transport.switches, hasLength(1));
    expect(find.text('切换未生效，正在重试…'), findsNothing);
    expect(find.text('模型/思考切换未生效，已恢复为桌面当前设置'), findsNothing);
  });

  testWidgets('switchModelConfig suspension coexists with a ledger terminal: '
      'the suspension copy is switchPending and §12 owns the visible '
      'terminal (auto retry → revert notice), with no suspension chip',
      (tester) async {
    final (gateway, transport) = await pumpSheetSwitch(
      tester,
      results: [
        CommandSuspendedException(commandId: 'sw-1', sessionId: 's1'),
        TimeoutException('retry also lost'),
      ],
    );

    // The sentinel rides the existing lost-ack §12 path: optimistic patch
    // landed and the sheet's pending copy is the suspension notice.
    expect(find.text('已切换，下一条消息生效'), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-suspend-chip')), findsNothing);
    expect(find.text(chatLabel('chat.suspend.pending')), findsNothing);

    // The ledger's terminal for this kind is recorded but never rendered
    // (step-3 kind gate): it must not clear anything or add copy.
    transport.emitCommandOutcome(
      const CommandLedgerOutcome(
        commandId: 'sw-2',
        rootCommandId: 'sw-1',
        sessionId: 's1',
        kind: 'switchModelConfig',
        settlement: CommandLedgerSettlement.failed,
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('chat-suspend-chip')), findsNothing);
    expect(find.text(chatLabel('chat.suspend.pending')), findsNothing);
    expect(transport.switches, hasLength(1));

    // §12 still owns the terminal: the old-config snapshot triggers the one
    // auto retry, whose failure falls back to the honest revert notice.
    gateway.snapshotExtra = {'config': desktopBaselineConfig()};
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '帮我修复登录'},
    ]);
    await tester.pump();
    await tester.pump();
    expect(transport.switches, hasLength(2));
    await advancePastShowingToast(tester);
    expect(find.text('模型/思考切换未生效，已恢复为桌面当前设置'), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-suspend-chip')), findsNothing);
  });

  // ---- fork lands the new session (10-05-fork-session-lifecycle C1) ----

  /// The fork bundle's ack union (research.md R1): accepted/duplicate both
  /// carry `result:{type:'forkAssistant', sessionId}`; other statuses (and
  /// a missing result) must NOT navigate.
  Map<String, dynamic> forkAck({
    String status = 'accepted',
    Object? result = const {
      'type': 'forkAssistant',
      'sessionId': 'sess_fork',
    },
  }) =>
      {'status': status, if (result != null) 'result': result};

  /// One turn (user + assistant text) so the feedback row renders; the
  /// phone viewport keeps the sheet path tappable like the edit-resend
  /// tests. Returns the gateway for ack programming / assertions.
  Future<FakeChatGateway> pumpForkSource(
    WidgetTester tester, {
    String? workspaceLabel,
    ThemeController? theme,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(
        ChatPage(
          host: gateway,
          sessionId: 's1',
          title: 't',
          workspaceLabel: workspaceLabel,
          theme: theme,
        ),
      ),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '帮我修复登录', 'state': 'done'},
      {'rowId': 2, 'kind': 'assistantText', 'text': '已修复'},
    ]);
    await tester.pumpAndSettle();
    return gateway;
  }

  testWidgets('feedback-row fork pushes the acked session: new page with '
      'the sessionId, same gateway/workspace, draft title (official '
      'onFork parity — the landing is the feedback)', (tester) async {
    final gateway = await pumpForkSource(tester, workspaceLabel: 'ZLinker');
    gateway.forkAssistantResults.add(forkAck());

    await tester.tap(find.byIcon(Icons.fork_right));
    await tester.pumpAndSettle();

    // The command went out addressed to the source row...
    final call = gateway.calls.firstWhere((c) => c.$1 == 'forkAssistant');
    expect(call.$2[0], 's1');
    expect(call.$2[1], {'rowId': 2});

    // ...and the ack's sessionId became the pushed page.
    expect(gateway.subscribedSessions, contains('sess_fork'));
    // The source page stays mounted underneath (offstage behind the opaque
    // route) — both must exist.
    expect(find.byType(ChatPage, skipOffstage: false), findsNWidgets(2));
    final pushed = tester.widget<ChatPage>(find.byType(ChatPage).last);
    expect(pushed.sessionId, 'sess_fork');
    expect(pushed.host, same(gateway));
    expect(pushed.workspaceLabel, 'ZLinker');
    expect(find.text('新建任务'), findsOneWidget);
  });

  testWidgets('fork hands the theme controller to the pushed page — the '
      'forked session keeps the theme toggle (D1)', (tester) async {
    final theme = ThemeController();
    final gateway = await pumpForkSource(tester, theme: theme);
    gateway.forkAssistantResults.add(forkAck());

    await tester.tap(find.byIcon(Icons.fork_right));
    await tester.pumpAndSettle();

    // The controller rides the fork: the pushed page carries the same
    // instance, so its app bar renders the toggle (dark mode → dark_mode
    // glyph; the source page is offstage behind the opaque route).
    final pushed = tester.widget<ChatPage>(find.byType(ChatPage).last);
    expect(pushed.theme, same(theme));
    expect(find.byIcon(Icons.dark_mode_outlined), findsOneWidget);
  });

  testWidgets('message-sheet fork pushes the acked session too — the row '
      'context survives the sheet pop', (tester) async {
    final gateway = await pumpForkSource(tester);
    gateway.forkAssistantResults.add(forkAck());

    // Pre-M0 long-press recipe (regression guard): press just outside the
    // bubble text. Glyph presses now reach the sheet too (M0 tests).
    final textTopLeft = tester.getTopLeft(find.text('帮我修复登录'));
    await tester.longPressAt(textTopLeft - const Offset(8, 4));
    await tester.pumpAndSettle();
    await tester.tap(find.text('分叉对话'));
    await tester.pumpAndSettle();

    expect(gateway.subscribedSessions, contains('sess_fork'));
    final pushed = tester.widget<ChatPage>(find.byType(ChatPage).last);
    expect(pushed.sessionId, 'sess_fork');
    expect(pushed.workspaceLabel, isNull);
    expect(find.text('已创建分支会话'), findsNothing);
  });

  testWidgets('created ack without a usable sessionId snacks the fallback '
      'copy and stays put (the row surfaces via sessions-index)',
      (tester) async {
    final gateway = await pumpForkSource(tester);
    gateway.forkAssistantResults.add(forkAck(result: null));

    await tester.tap(find.byIcon(Icons.fork_right));
    await tester.pumpAndSettle();

    expect(find.text('已创建分支会话'), findsOneWidget);
    expect(find.byType(ChatPage), findsOneWidget);
    expect(gateway.subscribedSessions, isNot(contains('sess_fork')));
  });

  testWidgets('rejected fork keeps the status failure copy — sheet path, '
      'no navigation', (tester) async {
    final gateway = await pumpForkSource(tester);
    gateway.forkAssistantResults.add(forkAck(status: 'rejected'));

    final textTopLeft = tester.getTopLeft(find.text('帮我修复登录'));
    await tester.longPressAt(textTopLeft - const Offset(8, 4));
    await tester.pumpAndSettle();
    await tester.tap(find.text('分叉对话'));
    await tester.pumpAndSettle();

    expect(find.text('分叉失败: rejected'), findsOneWidget);
    expect(find.byType(ChatPage), findsOneWidget);
    expect(gateway.subscribedSessions, isNot(contains('sess_fork')));
  });

  testWidgets('a thrown fork (the live session_busy shape) surfaces the '
      'plain-language busy copy, not the raw desktop error', (tester) async {
    final gateway = await pumpForkSource(tester);
    gateway.forkAssistantResults
        .add(Exception('ChannelRpcError: 会话正在进行中，稍后再试'));

    await tester.tap(find.byIcon(Icons.fork_right));
    await tester.pumpAndSettle();

    expect(find.text('会话正在处理中，请稍后重试'), findsOneWidget);
    expect(find.textContaining('稍后再试'), findsNothing);
    expect(find.byType(ChatPage), findsOneWidget);
  });

  // ---- selection side chat (parity-reference D2) ----

  /// One turn so the long-press action sheet renders (fork-test viewport).
  Future<FakeChatGateway> pumpSideChatSource(
    WidgetTester tester, {
    String? workspaceLabel,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(
        ChatPage(
          host: gateway,
          sessionId: 's1',
          title: 't',
          workspaceLabel: workspaceLabel,
        ),
      ),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '帮我修复登录', 'state': 'done'},
      {'rowId': 2, 'kind': 'assistantText', 'text': '已修复'},
    ]);
    await tester.pumpAndSettle();
    return gateway;
  }

  /// Long-press just outside the first bubble's text — the pre-M0 recipe,
  /// kept as a regression guard — then the action sheet is up.
  Future<void> openRowActions(WidgetTester tester) async {
    final textTopLeft = tester.getTopLeft(find.text('帮我修复登录'));
    await tester.longPressAt(textTopLeft - const Offset(8, 4));
    await tester.pumpAndSettle();
  }

  /// The direct-ask dialog's TextField (the composer has one too, so scope
  /// to the dialog).
  Finder askField() => find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );

  testWidgets('action sheet 「在辅助对话中提问」 creates and activates a side '
      'tab through the shared tab flow (no pushed page)', (tester) async {
    final gateway = await pumpSideChatSource(tester);

    await openRowActions(tester);
    await tester.tap(find.text('在辅助对话中提问'));
    await tester.pumpAndSettle();

    // The direct-ask dialog is up (title + input + confirm).
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(askField(), findsOneWidget);
    await tester.enterText(askField(), '  为什么要这样  ');
    await tester.tap(find.text('提问'));
    await tester.pumpAndSettle();

    // Same host port as the /side /btw aliases (R6): the trimmed question
    // is the first message, and the page never issues the command itself.
    expect(gateway.createdSideChatRequests.single, ('s1', '为什么要这样'));
    expect(
      gateway.calls.where((c) => c.$1 == 'createSelectionSideSession'),
      isEmpty,
      reason: 'the ask entry must ride SideChatPort.createSideChatTab',
    );

    // The tab appeared and activated in place; nothing was pushed over the
    // main conversation.
    expect(gateway.sideChatTabsByParent['s1']!.single.sessionId, 'sess_side');
    expect(visibleComposerOf('sess_side'), findsOneWidget);
    final sidePages = tester
        .widgetList<ChatPage>(find.byType(ChatPage, skipOffstage: false))
        .where((page) => page.sessionId == 'sess_side');
    expect(
      sidePages.single.chromeless,
      isTrue,
      reason: 'the side chat is a tab child, not a pushed full-screen page',
    );
    expect(find.text(chatLabel('sideChat.tab.title', ['1'])), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('empty ask input creates nothing and stays put (no silent '
      'first message)', (tester) async {
    final gateway = await pumpSideChatSource(tester);

    await openRowActions(tester);
    await tester.tap(find.text('在辅助对话中提问'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('提问'));
    await tester.pumpAndSettle();

    expect(
      gateway.calls.where((c) => c.$1 == 'createSelectionSideSession'),
      isEmpty,
    );
    expect(
      gateway.createdSideChatRequests,
      isEmpty,
      reason: 'blank input must create NOTHING (no first message the user '
          'did not type)',
    );
    expect(find.byType(ChatPage), findsOneWidget);
  });

  testWidgets('cancelling the ask dialog creates nothing', (tester) async {
    final gateway = await pumpSideChatSource(tester);

    await openRowActions(tester);
    await tester.tap(find.text('在辅助对话中提问'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(
      gateway.calls.where((c) => c.$1 == 'createSelectionSideSession'),
      isEmpty,
    );
    expect(gateway.createdSideChatRequests, isEmpty);
    expect(find.byType(ChatPage), findsOneWidget);
  });

  testWidgets('a thrown ask-entry creation surfaces the operation copy, no '
      'tab', (tester) async {
    final gateway = await pumpSideChatSource(tester);
    gateway.createSideChatTabResults.add(
      StateError(
        'createSelectionSideSession rejected: '
        'guard.selectionSideChatRestrictedCommand '
        'selection_side_chat 不允许执行 createSelectionSideSession',
      ),
    );

    await openRowActions(tester);
    await tester.tap(find.text('在辅助对话中提问'));
    await tester.pumpAndSettle();
    await tester.enterText(askField(), '问题');
    await tester.tap(find.text('提问'));
    await tester.pumpAndSettle();

    expect(gateway.createdSideChatRequests.single, ('s1', '问题'));
    expect(
      find.textContaining(chatLabel('tasks.opFailed', ['Bad state'])),
      findsOneWidget,
    );
    expect(find.byType(ChatPage), findsOneWidget);
    expect(gateway.sideChatTabsByParent, isEmpty);
    expect(gateway.subscribedSessions, isNot(contains('sess_side')));
  });

  testWidgets('the row actions still fork as before (side-chat entry is '
      'additive, not a fork replacement)', (tester) async {
    final gateway = await pumpSideChatSource(tester);
    gateway.forkAssistantResults.add(forkAck());

    await openRowActions(tester);
    await tester.tap(find.text('分叉对话'));
    await tester.pumpAndSettle();

    expect(gateway.subscribedSessions, contains('sess_fork'));
    expect(
      gateway.calls.where((c) => c.$1 == 'createSelectionSideSession'),
      isEmpty,
    );
  });

  // ---- side-chat slash aliases (11-11 C1) ----

  /// Types into the composer and pumps one frame (the slash popup follows
  /// the controller's listener synchronously).
  Future<void> typeComposer(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField).first, text);
    await tester.pump();
  }

  testWidgets('an existing conversation composer offers the builtin /side '
      'and /btw aliases with the shared description', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot(const []);
    await tester.pumpAndSettle();

    await typeComposer(tester, '/');
    expect(find.text('/side'), findsOneWidget);
    expect(find.text('/btw'), findsOneWidget);
    expect(find.text('新建并打开一个辅助对话'), findsNWidgets(2));

    // Prefix hits mirror the popup filter: /si → /side only, /bt → /btw only.
    await typeComposer(tester, '/si');
    expect(find.text('/side'), findsOneWidget);
    expect(find.text('/btw'), findsNothing);

    await typeComposer(tester, '/bt');
    expect(find.text('/btw'), findsOneWidget);
    expect(find.text('/side'), findsNothing);
  });

  testWidgets(
      'a four-item slash popup fits the keyboard-shrunk body instead of '
      'overflowing the composer (F 终验: BOTTOM OVERFLOWED BY 20 PIXELS)',
      (tester) async {
    // Keyboard shrink as the physical window shrinking (844 → 390), the
    // documented recipe: injecting viewInsets alone never shrinks the test
    // viewport. A bare `/` then lists four entries (the builtin aliases plus
    // goal/workflow), whose fixed 260dp cap pushed the composer 20dp past
    // the body bottom on the PMA110 debug build.
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 390);
    addTearDown(tester.view.reset);
    addTearDown(tester.view.resetDevicePixelRatio);
    final gateway = _FullSlashGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot(const []);
    await tester.pumpAndSettle();

    await typeComposer(tester, '/');
    expect(find.text('/side'), findsOneWidget);
    expect(find.text('/btw'), findsOneWidget);
    expect(
      tester.takeException(),
      isNull,
      reason: 'the popup caps to the laid-out body and the list scrolls '
          'instead of pushing the composer past the viewport',
    );

    // The cap keeps the list scrollable: the overflow items stay reachable.
    await tester.drag(
      find.ancestor(of: find.text('/side'), matching: find.byType(ListView)),
      const Offset(0, -120),
    );
    await tester.pump();
    expect(find.text('/workflow'), findsOneWidget);
  });

  testWidgets('side-chat alias description locks the English copy',
      (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(
        ChatPage(host: gateway, sessionId: 's1', title: 't'),
        locale: 'en-US',
      ),
    );
    gateway.feedSnapshot(const []);
    await tester.pumpAndSettle();

    await typeComposer(tester, '/');
    expect(find.text('Create and open a side conversation'), findsNWidgets(2));
  });

  testWidgets('picking /side only pre-fills the composer — the static item '
      'path never sends on its own', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot(const []);
    await tester.pumpAndSettle();

    await typeComposer(tester, '/si');
    await tester.tap(find.text('/side'));
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField).first);
    expect(field.controller!.text, '/side ');
    expect(
      gateway.calls.where((c) => c.$1 == 'sendTextOrQueue'),
      isEmpty,
      reason: 'selection inserts text only (the /compact special case is the '
          'sole auto-send); the /side interception consumes the submit, not '
          'the popup pick',
    );
  });

  testWidgets('a draft composer keeps the aliases out (the draft guard '
      'would dead-end an empty-argument creation)', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(wrap(ChatPage(host: gateway, title: '新任务')));
    await tester.pumpAndSettle();

    await typeComposer(tester, '/');
    expect(find.text('/compact'), findsOneWidget);
    expect(find.text('/side'), findsNothing);
    expect(find.text('/btw'), findsNothing);
  });

  testWidgets('a side-chat composer keeps the aliases out (no nesting)',
      (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(
        ChatPage(
          host: gateway,
          sessionId: 's1',
          title: '辅助对话 1',
          chromeless: true,
        ),
      ),
    );
    gateway.feedSnapshot(const []);
    await tester.pumpAndSettle();

    await typeComposer(tester, '/');
    expect(find.text('/compact'), findsOneWidget);
    expect(find.text('/side'), findsNothing);
    expect(find.text('/btw'), findsNothing);
  });

  // ---- side-chat /side /btw interception (11-11 C2) ----

  Finder sendButton() => find.byIcon(Icons.arrow_upward);

  testWidgets('alias submissions ride the side-chat port with the parsed '
      'first input — the slash text never lands in any conversation',
      (tester) async {
    for (final (text, expected) in [
      ('/btw 你好', '你好'), // argument
      ('/SIDE 你好', '你好'), // case-insensitive
      ('/side', null), // empty argument
      ('/btw 第一行\n第二行', '第一行\n第二行'), // multi-line first message
    ]) {
      // Fresh page per case: each submission opens a side tab of its own.
      await tester.pumpWidget(const SizedBox.shrink());
      final gateway = FakeChatGateway();
      await tester.pumpWidget(
        wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
      );
      gateway.feedSnapshot(const []);
      await tester.pumpAndSettle();

      await typeComposer(tester, text);
      await tester.tap(sendButton());
      await tester.pumpAndSettle();

      expect(
        gateway.createdSideChatRequests,
        [('s1', expected)],
        reason: '"$text" must create its side chat with the parsed first '
            'input',
      );
      expect(
        gateway.calls.where((c) => c.$1 == 'sendTextOrQueue'),
        isEmpty,
        reason: '"$text" must never be sent to any conversation',
      );
      expect(
        find.text(text, skipOffstage: false),
        findsNothing,
        reason: 'the slash literal must not survive in any composer or row',
      );
      expect(find.byType(SnackBar), findsNothing);
    }
  });

  testWidgets('non-alias lookalikes still send normally', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot(const []);
    await tester.pumpAndSettle();

    for (final text in ['/sidex 你好', '/side1 2']) {
      await typeComposer(tester, text);
      await tester.tap(sendButton());
      await tester.pumpAndSettle();

      final call = gateway.calls
          .where((c) => c.$1 == 'sendTextOrQueue')
          .last;
      expect(call.$2, ['s1', text, null]);
      expect(gateway.createdSideChatRequests, isEmpty);
    }
  });

  testWidgets('a side chat sends /side as a plain message (nesting leg 2)',
      (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(
        ChatPage(
          host: gateway,
          sessionId: 's1',
          title: '辅助对话 1',
          chromeless: true,
        ),
      ),
    );
    gateway.feedSnapshot(const []);
    await tester.pumpAndSettle();

    await typeComposer(tester, '/side 你好');
    await tester.tap(sendButton());
    await tester.pumpAndSettle();

    final call = gateway.calls
        .where((c) => c.$1 == 'sendTextOrQueue')
        .single;
    expect(call.$2, ['s1', '/side 你好', null]);
    expect(gateway.createdSideChatRequests, isEmpty);
  });

  testWidgets('a manual /btw in a draft is refused with the first-message '
      'guard', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(wrap(ChatPage(host: gateway, title: '新任务')));
    await tester.pumpAndSettle();

    await typeComposer(tester, '/btw 你好');
    await tester.tap(sendButton());
    await tester.pump();

    expect(find.text(chatLabel('sideChat.draftGuard')), findsOneWidget);
    expect(
      gateway.calls.where((c) => c.$1 == 'sendTextOrQueue'),
      isEmpty,
    );
    expect(gateway.createdSideChatRequests, isEmpty);
    expect(
      gateway.ensuredDraftWorkspaces,
      isEmpty,
      reason: 'the guard answers before the draft workspace RPC',
    );
  });

  testWidgets('attachments refuse a side-chat command instead of dropping '
      'them', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('miguelruivo.flutter.plugins.filepicker'),
      (call) async => call.method == 'any'
          ? [
              {
                'name': 'a.txt',
                'size': 3,
                'bytes': Uint8List.fromList([1, 2, 3]),
              },
            ]
          : null,
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('miguelruivo.flutter.plugins.filepicker'),
        null,
      );
    });
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot(const []);
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add_circle_outline));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    await tester.tap(find.text('附件'));
    await tester.pumpAndSettle();
    expect(find.text('a.txt'), findsOneWidget); // pending bar chip

    await typeComposer(tester, '/side 你好');
    await tester.tap(sendButton());
    await tester.pump();

    expect(
      find.text(chatLabel('sideChat.attachmentsUnsupported')),
      findsOneWidget,
    );
    expect(
      gateway.calls.where((c) => c.$1 == 'sendTextOrQueue'),
      isEmpty,
    );
    expect(gateway.createdSideChatRequests, isEmpty);
    expect(
      find.text('a.txt'),
      findsOneWidget,
      reason: 'the refusal must keep the pending files (no silent drop)',
    );
  });

  // ---- side-chat creation flow (11-11 C3) ----

  testWidgets('/btw <text> creates a side tab, activates it and ships the '
      'text as its first input (the main timeline gains no row)',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '已有消息', 'state': 'done'},
    ]);
    await tester.pumpAndSettle();

    await typeComposer(tester, '/btw 你好');
    await tester.tap(sendButton());
    await tester.pumpAndSettle();

    // AC2 core: the text rode the create command's firstText via the host
    // port; nothing was sent to the main conversation.
    expect(gateway.createdSideChatRequests.single, ('s1', '你好'));
    expect(
      gateway.calls.where((c) => c.$1 == 'sendTextOrQueue'),
      isEmpty,
      reason: 'the main timeline must gain no row',
    );
    expect(
      find.text('/btw 你好', skipOffstage: false),
      findsNothing,
      reason: 'the slash literal must never land in a conversation',
    );

    // The acked tab appeared and the container switched to it.
    expect(gateway.sideChatTabsByParent['s1']!.single.sessionId, 'sess_side');
    expect(find.text(chatLabel('sideChat.tab.title', ['1'])), findsOneWidget);
    expect(
      visibleComposerOf('sess_side'),
      findsOneWidget,
      reason: 'the created tab must be the visible one',
    );
    expect(
      tabComposerText(tester, 's1'),
      isEmpty,
      reason: 'the host composer is cleared only after the ack',
    );
    expect(gateway.subscribedSessions, contains('sess_side'));
  });

  testWidgets('/side with no argument still creates and activates the side '
      'tab (AC1)', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot(const []);
    await tester.pumpAndSettle();

    await typeComposer(tester, '/side');
    await tester.tap(sendButton());
    await tester.pumpAndSettle();

    expect(gateway.createdSideChatRequests.single, ('s1', null));
    expect(visibleComposerOf('sess_side'), findsOneWidget);
    expect(tabComposerText(tester, 's1'), isEmpty);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('a failed create toasts the operation copy, keeps the typed '
      'text and adds no tab', (tester) async {
    final gateway = FakeChatGateway();
    gateway.createSideChatTabResults.add(Exception('boom'));
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot(const []);
    await tester.pumpAndSettle();

    await typeComposer(tester, '/btw 你好');
    await tester.tap(sendButton());
    await tester.pumpAndSettle();

    expect(gateway.createdSideChatRequests.single, ('s1', '你好'));
    expect(
      find.text(chatLabel('tasks.opFailed', ['Exception: boom'])),
      findsOneWidget,
    );
    expect(gateway.sideChatTabsByParent, isEmpty);
    expect(
      find.byKey(const ValueKey('chat-tab-sess_side'), skipOffstage: false),
      findsNothing,
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '/btw 你好',
      reason: 'a failed create must keep the text for a retry',
    );
    expect(
      gateway.calls.where((c) => c.$1 == 'sendTextOrQueue'),
      isEmpty,
      reason: 'a failed create must not fall through to a conversation send',
    );
  });

  testWidgets('a double submit inside the create RPC is swallowed (the busy '
      'window spans the ack)', (tester) async {
    final gateway = FakeChatGateway();
    final gate = Completer<SideChatTab>();
    gateway.createSideChatTabResults.add(gate.future);
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot(const []);
    await tester.pumpAndSettle();

    await typeComposer(tester, '/btw 你好');
    await tester.tap(sendButton());
    await tester.pump();
    expect(gateway.createdSideChatRequests, hasLength(1));

    // The composer still holds the slash text (cleared only on the ack), so
    // the send button is live — the second tap must be absorbed.
    await tester.tap(sendButton());
    await tester.pump();
    expect(
      gateway.createdSideChatRequests,
      hasLength(1),
      reason: 'the busy window must debounce the second submit',
    );
    expect(gateway.calls.where((c) => c.$1 == 'sendTextOrQueue'), isEmpty);

    gate.complete(const SideChatTab(sessionId: 'sess_side', ordinal: 1));
    await tester.pumpAndSettle();

    expect(gateway.createdSideChatRequests, hasLength(1));
    expect(visibleComposerOf('sess_side'), findsOneWidget);
    expect(tabComposerText(tester, 's1'), isEmpty);
  });

  testWidgets('assistant copy feedback morphs copy → check with no toast, '
      'reverts after 1200ms; re-tap restarts the window', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'assistantText', 'text': '回答正文'},
    ]);
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.copy_outlined));
    await tester.pump();
    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(find.byIcon(Icons.copy_outlined), findsNothing);
    // Icon morph is the only feedback — no "已复制" toast.
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('已复制'), findsNothing);

    // Re-tap mid-window restarts the 1200ms clock: tap again at +600ms, so
    // the restarted deadline (+1800ms) must outlive the original (+1200ms).
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.byIcon(Icons.check));
    await tester.pump(const Duration(milliseconds: 700));
    // +1300ms: the un-restarted timer would have reverted by now.
    expect(find.byIcon(Icons.check), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
    expect(find.byIcon(Icons.check), findsNothing);
  });

  testWidgets('composer cursor always rides the theme default (blinks in '
      'empty state too — focus signal beats placeholder overlap, matching '
      'the official web/desktop input)', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'assistantText', 'text': '回答正文'},
    ]);
    await tester.pumpAndSettle();

    final field = find.byType(TextField);
    expect(field, findsOneWidget); // the composer
    // Empty composer: cursor must still be theme-resolved (null), never a
    // conditional hide — an invisible cursor reads as "no focus".
    expect(tester.widget<TextField>(field).cursorColor, isNull);

    await tester.enterText(field, '你好');
    await tester.pump();
    expect(tester.widget<TextField>(field).cursorColor, isNull);
  });

  // ------------------- parity chat actions (10-08-parity-chat-actions)

  group('inline edit-resend (D1)', () {
    Future<_EditGateway> pumpEditable(tester) async {
      final gateway = _EditGateway();
      await tester.pumpWidget(
        wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
      );
      gateway.feedSnapshot([
        {'rowId': 1, 'kind': 'userInput', 'text': '原始消息', 'state': 'done'},
      ]);
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      return gateway;
    }

    testWidgets('rewind direct-send → workspaceMode:"rewind" on the wire, '
        'editor closes', (tester) async {
      final gateway = await pumpEditable(tester);

      await tester.enterText(
        find.byKey(const ValueKey('inline-edit-input')),
        '改后的消息',
      );
      await tester.tap(
        find.widgetWithText(OutlinedButton, '对话 + 文件重置'),
      );
      await tester.pumpAndSettle();

      final edit = gateway.transport.edits.single;
      expect(edit.sessionId, 's1');
      expect(edit.target, {'rowId': 1});
      expect(edit.newText, '改后的消息');
      expect(edit.workspaceMode, 'rewind');
      // Success closes the editor.
      expect(find.byKey(const ValueKey('inline-edit-input')), findsNothing);
    });

    testWidgets('preserve send → the field stays OFF the wire '
        '(preserve is the desktop default)', (tester) async {
      final gateway = await pumpEditable(tester);

      await tester.enterText(
        find.byKey(const ValueKey('inline-edit-input')),
        '保留对话',
      );
      await tester.tap(find.widgetWithText(FilledButton, '发送'));
      await tester.pumpAndSettle();

      expect(gateway.transport.edits.single.workspaceMode, isNull);
      expect(gateway.transport.edits.single.newText, '保留对话');
    });

    testWidgets('running session: the rewind button is disabled but a '
        'preserve edit still sends', (tester) async {
      final gateway = _EditGateway();
      gateway.snapshotExtra = {
        'control': {'phase': 'running'},
      };
      await tester.pumpWidget(
        wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
      );
      gateway.feedSnapshot([
        {'rowId': 1, 'kind': 'userInput', 'text': '原始消息', 'state': 'done'},
      ]);
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, '对话 + 文件重置'),
            )
            .onPressed,
        isNull, // grey state
      );

      await tester.enterText(
        find.byKey(const ValueKey('inline-edit-input')),
        '运行中编辑',
      );
      await tester.tap(find.widgetWithText(FilledButton, '发送'));
      await tester.pumpAndSettle();

      expect(gateway.transport.edits.single.workspaceMode, isNull);
    });

    testWidgets('a thrown edit keeps the editor open for retry and snacks '
        'the failure copy', (tester) async {
      final gateway = await pumpEditable(tester);
      gateway.transport.error = StateError('not connected');

      await tester.enterText(
        find.byKey(const ValueKey('inline-edit-input')),
        '失败的编辑',
      );
      await tester.tap(find.widgetWithText(FilledButton, '发送'));
      await tester.pumpAndSettle();

      expect(find.textContaining('编辑失败'), findsOneWidget);
      expect(find.byKey(const ValueKey('inline-edit-input')), findsOneWidget);
    });
  });

  group('hook runs entry (D4)', () {
    testWidgets('a turn with hookInvocation rows renders the webhook button '
        'and the read-only sheet lists executions', (tester) async {
      final gateway = FakeChatGateway();
      await tester.pumpWidget(
        wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
      );
      gateway.feedSnapshot([
        {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
        {
          'rowId': 2,
          'kind': 'assistantText',
          'text': 'done',
          'state': 'done',
        },
        {
          'rowId': 3,
          'kind': 'turnHeader',
          'state': 'completedSuccess',
          'activeMs': 1000,
        },
        {
          'rowId': 4,
          'kind': 'hookInvocation',
          'hookEventName': 'PostToolUse',
          'executions': [
            {
              'hookRunId': 'h1',
              'state': 'completed',
              'outcome': 'success',
              'sourceKind': 'user',
              'displayName': 'format-check',
              'durationMs': 1234,
            },
          ],
        },
      ]);
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.webhook));
      await tester.pumpAndSettle();

      expect(find.text('钩子'), findsOneWidget);
      expect(find.text('PostToolUse'), findsOneWidget);
      expect(find.text('用户 · format-check · 已完成'), findsOneWidget);
    });

    testWidgets('a hookless turn renders no webhook button', (tester) async {
      final gateway = FakeChatGateway();
      await tester.pumpWidget(
        wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
      );
      gateway.feedSnapshot([
        {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
        {'rowId': 2, 'kind': 'assistantText', 'text': 'done'},
      ]);
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.webhook), findsNothing);
    });
  });

  group('sensitive input masking (D8)', () {
    testWidgets('payload sensitive → the free-text input is obscured',
        (tester) async {
      final gateway = FakeChatGateway();
      gateway.snapshotExtra = {
        'pendingInteractions': [
          {
            'interactionId': 'i1',
            'payload': {
              'kind': 'userInput',
              'freeText': true,
              'sensitive': true,
            },
          },
        ],
      };
      await tester.pumpWidget(
        wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
      );
      gateway.feedSnapshot([
        {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
      ]);
      await tester.pumpAndSettle();

      // The interaction card's input (not the composer) is obscured.
      Finder replyField() => find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == '输入回复…',
      );
      expect(replyField(), findsOneWidget);
      expect(tester.widget<TextField>(replyField()).obscureText, isTrue);
    });

    testWidgets('non-sensitive payload keeps plain input', (tester) async {
      final gateway = FakeChatGateway();
      gateway.snapshotExtra = {
        'pendingInteractions': [
          {
            'interactionId': 'i1',
            'payload': {'kind': 'userInput', 'freeText': true},
          },
        ],
      };
      await tester.pumpWidget(
        wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
      );
      gateway.feedSnapshot([
        {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
      ]);
      await tester.pumpAndSettle();

      Finder replyField() => find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == '输入回复…',
      );
      expect(replyField(), findsOneWidget);
      expect(tester.widget<TextField>(replyField()).obscureText, isFalse);
    });
  });

  group('anchored interactions (D9)', () {
    Future<FakeChatGateway> pumpAnchored(
      WidgetTester tester, {
      required Object? anchorRowId,
    }) async {
      final gateway = FakeChatGateway();
      gateway.snapshotExtra = {
        'pendingInteractions': [
          {
            'interactionId': 'i1',
            'anchorRowId': anchorRowId,
            'payload': {
              'kind': 'permission',
              'toolName': 'Bash',
              'summary': 'rm -rf build',
              'options': [
                {'optionId': 'o1', 'kind': 'allowOnce'},
              ],
            },
          },
        ],
      };
      await tester.pumpWidget(
        wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
      );
      gateway.feedSnapshot([
        {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
        {'rowId': 2, 'kind': 'assistantText', 'text': 'done'},
      ]);
      await tester.pumpAndSettle();
      return gateway;
    }

    testWidgets('anchor inside the window renders exactly ONE card '
        '(bottom strip excluded)', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      await pumpAnchored(tester, anchorRowId: 1);

      expect(find.textContaining('权限请求'), findsOneWidget);
      // Anchored → renders in the stream, right after the turn group near
      // the TOP half of the screen — not in the bottom status strip.
      expect(
        tester.getTopLeft(find.textContaining('权限请求')).dy,
        lessThan(844 / 2),
      );
    });

    testWidgets('anchor outside the window stays in the bottom strip',
        (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      await pumpAnchored(tester, anchorRowId: 999);

      expect(find.textContaining('权限请求'), findsOneWidget);
      expect(
        tester.getTopLeft(find.textContaining('权限请求')).dy,
        greaterThan(844 / 2),
      );
    });
  });

  group('copy task path (D2)', () {
    testWidgets('复制任务路径 copies the desktop session-file path formula',
        (tester) async {
      String? clipboard;
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (message) async {
            if (message.method == 'Clipboard.setData') {
              clipboard =
                  (message.arguments as Map)['text'] as String?;
            }
            return null;
          });
      addTearDown(() {
        TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      final gateway = FakeChatGateway();
      await tester.pumpWidget(
        wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
      );
      gateway.feedSnapshot([
        {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
      ]);
      await tester.pumpAndSettle();

      await tester.tap(find.text('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('复制任务路径'));
      await tester.pumpAndSettle();

      expect(clipboard, '/repo/app/s1.zcode-session');
    });
  });

  group('git panel wiring (D2/D3)', () {
    testWidgets('the status group renders in a repository workspace and the '
        'message capsule falls back to the turn summary', (tester) async {
      final gateway = FakeChatGateway()
        ..gitCallHandler = (method, args) async => switch (method) {
              'getRepositorySummary' => <String, Object?>{
                  'isRepository': true,
                  'branchName': 'main',
                  'isDirty': true,
                  'headRefType': 'branch',
                },
              'refresh' => <String, Object?>{'summary': <String, Object?>{}},
              'getChanges' => <Object?>[],
              'getLocalBranches' => <String, Object?>{
                  'headRefType': 'branch',
                  'currentBranchName': 'main',
                  'branches': [
                    {'name': 'main', 'isCurrent': true},
                  ],
                },
              'getIdentity' =>
                <String, Object?>{'userName': 'Ada', 'userEmail': 'a@b.c'},
              _ => <String, Object?>{},
            };
      await tester.pumpWidget(
        wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
      );
      gateway.feedSnapshot([
        {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
        {'rowId': 2, 'kind': 'assistantText', 'text': 'done'},
        {
          'rowId': 3,
          'kind': 'turnHeader',
          'state': 'completedSuccess',
          'fileChanges': {'files': 1, 'additions': 10, 'deletions': 3},
        },
      ]);
      await tester.pumpAndSettle();

      expect(find.text('Git 工具'), findsOneWidget);
      expect(find.text('提交或推送'), findsOneWidget);
      // No workspace changes → the capsule shows the turn's own summary.
      expect(find.textContaining('+10'), findsWidgets);
    });

    testWidgets('a non-repository workspace hides the whole Git group',
        (tester) async {
      final gateway = FakeChatGateway()
        ..gitCallHandler = (method, args) async =>
            <String, Object?>{'kind': 'not-repository', 'isGitAvailable': true};
      await tester.pumpWidget(
        wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
      );
      gateway.feedSnapshot([
        {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
      ]);
      await tester.pumpAndSettle();

      expect(find.text('Git 工具'), findsNothing);
      expect(find.text('提交或推送'), findsNothing);
    });
  });

  // ---- side-chat restricted closure (11-11 E1: R5/AC6) ----

  group('side-chat restricted closure (R5/AC6)', () {
    /// The chromeless tab child the host container builds, over `s1`.
    Future<FakeChatGateway> pumpSideTab(
      WidgetTester tester, {
      Map<String, dynamic> snapshotExtra = const {},
      List<Map<String, dynamic>> rows = const [],
    }) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      final gateway = FakeChatGateway()..snapshotExtra = snapshotExtra;
      await tester.pumpWidget(
        wrap(
          ChatPage(
            host: gateway,
            sessionId: 's1',
            title: '辅助对话 1',
            chromeless: true,
          ),
        ),
      );
      gateway.feedSnapshot(rows);
      await tester.pumpAndSettle();
      return gateway;
    }

    Map<String, dynamic> goalSnapshot() => {
          'goal': {
            'summaryTitle': '侧聊目标',
            'objective': '侧聊目标',
            'status': 'active',
          },
        };

    testWidgets('the goal process panel (pause/resume) stays off a side tab '
        'while the host page keeps it', (tester) async {
      // Control: the same goal snapshot renders the panel on the main tab.
      final host = FakeChatGateway()..snapshotExtra = goalSnapshot();
      await tester.pumpWidget(
        wrap(ChatPage(host: host, sessionId: 's1', title: '主会话')),
      );
      host.feedSnapshot(const []);
      await tester.pumpAndSettle();
      expect(find.text(chatLabel('goalPanel.title')), findsOneWidget);
      expect(find.byIcon(Icons.pause), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      final side = await pumpSideTab(tester, snapshotExtra: goalSnapshot());
      expect(side.state.snapshot?['goal'], isNotNull,
          reason: 'the gate must hide a live goal, not just an absent one');
      expect(find.text(chatLabel('goalPanel.title')), findsNothing);
      expect(find.byIcon(Icons.pause), findsNothing);
    });

    testWidgets('/goal pause|resume|prefix reach no restricted command in a '
        'side tab — they go out as plain messages', (tester) async {
      final gateway = await pumpSideTab(tester);

      for (final text in ['/goal pause', '/goal resume', '/goal 做点什么']) {
        await typeComposer(tester, text);
        await tester.tap(sendButton());
        await tester.pumpAndSettle();

        expect(
          gateway.calls.where((c) =>
              c.$1 == 'pauseGoal' ||
              c.$1 == 'resumeGoal' ||
              c.$1 == 'sendGoalCommand'),
          isEmpty,
          reason: '"$text" must not reach a restricted goal command',
        );
        final call = gateway.calls
            .where((c) => c.$1 == 'sendTextOrQueue')
            .last;
        expect(call.$2, ['s1', text, null]);
      }
    });

    testWidgets('the host page still intercepts /goal pause (no over-gating)',
        (tester) async {
      final gateway = FakeChatGateway();
      await tester.pumpWidget(
        wrap(ChatPage(host: gateway, sessionId: 's1', title: '主会话')),
      );
      gateway.feedSnapshot(const []);
      await tester.pumpAndSettle();

      await typeComposer(tester, '/goal pause');
      await tester.tap(sendButton());
      await tester.pumpAndSettle();

      expect(gateway.calls.where((c) => c.$1 == 'pauseGoal'), hasLength(1));
      expect(gateway.calls.where((c) => c.$1 == 'sendTextOrQueue'), isEmpty);
    });

    testWidgets('row actions: edit-resend / retry / fork / side-ask stay '
        'hidden; the browsing entries stay', (tester) async {
      await pumpSideTab(
        tester,
        rows: [
          {'rowId': 1, 'kind': 'userInput', 'text': '侧聊提问', 'state': 'done'},
          {'rowId': 2, 'kind': 'assistantText', 'text': '侧聊回答'},
        ],
      );

      // Feedback row keeps copy/like, loses the fork button; the user
      // bubble loses its edit affordance.
      expect(find.byIcon(Icons.fork_right), findsNothing);
      expect(find.byIcon(Icons.thumb_up_alt_outlined), findsOneWidget);
      expect(find.byIcon(Icons.copy_outlined), findsWidgets);
      expect(find.byIcon(Icons.edit_outlined), findsNothing);

      final textTopLeft = tester.getTopLeft(find.text('侧聊提问'));
      await tester.longPressAt(textTopLeft - const Offset(8, 4));
      await tester.pumpAndSettle();

      expect(find.text(chatLabel('chat.action.editResend')), findsNothing);
      expect(find.text(chatLabel('chat.action.retry')), findsNothing);
      expect(find.text(chatLabel('chat.action.fork')), findsNothing);
      expect(
        find.text(chatLabel('chat.selections.askInSideChat')),
        findsNothing,
      );
      expect(find.text(chatLabel('chat.action.fileChanges')), findsOneWidget);
    });

    testWidgets('the add-context panel offers no 目标 item in a side tab '
        '(side chats are never drafts)', (tester) async {
      await pumpSideTab(tester);
      await tester.tap(find.byIcon(Icons.add_circle_outline));
      await tester.pumpAndSettle();

      expect(find.text(chatLabel('chat.composer.attachment')), findsOneWidget);
      expect(find.text(chatLabel('chat.goalBanner.label')), findsNothing);
    });
  });
}

/// Unmounts the page, then unblocks a [_StalledGateway] subscribe: the
/// completed future cancels the 60s `.timeout` timer, leaving no pending
/// timer in the test zone.
Future<void> _releaseStalledPage(
  WidgetTester tester,
  _StalledGateway gateway,
) async {
  await tester.pumpWidget(const SizedBox());
  gateway.release();
  await tester.pump();
}

/// Bridge stand-in carrying only the degraded flag — the loading
/// placeholder's status source (`session.degraded`).
class _DegradedBridgeSession implements BridgeSession {
  @override
  final ValueNotifier<String?> degraded = ValueNotifier(null);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Transport stand-in that only exposes the bridge degraded flag (the
/// loading path's status source); everything else is never exercised.
class _DegradedTransport implements ConversationTransport {
  _DegradedTransport(this.session);

  @override
  final BridgeSession session;

  @override
  ValueListenable<String?> get degraded => session.degraded;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Gateway whose subscribe never completes on its own — pins the page on
/// the `state == null` loading placeholder. [release] unblocks it at
/// teardown.
class _StalledGateway extends FakeChatGateway {
  _StalledGateway(this.transport);

  final ConversationTransport transport;
  final Completer<ChatHandle> _pending = Completer<ChatHandle>();

  @override
  Future<ChatHandle> subscribe(String sessionId) => _pending.future;

  @override
  ConversationTransport get conversationCommands => transport;

  void release() {
    if (!_pending.isCompleted) {
      _pending.complete(
        ChatHandle(state: ConversationState(), close: () async {}),
      );
    }
  }
}

/// Transport whose `rowsRange` answers come from a queue of completers —
/// the in-flight-load test holds a call open across further triggers.
class _SequencedRowsTransport implements ConversationTransport {
  final List<Completer<dynamic>> queue = [];

  /// Recorded `beforeRowId` cursors, one per call.
  final List<int?> calls = [];

  @override
  Future<dynamic> rowsRange(
    String sessionId, {
    int? beforeRowId,
    int limit = 60,
  }) async {
    calls.add(beforeRowId);
    return queue.removeAt(0).future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _SequencedRowsGateway extends FakeChatGateway {
  _SequencedRowsGateway(this.transport);

  final _SequencedRowsTransport transport;

  @override
  ConversationTransport get conversationCommands => transport;
}

/// Records the inline edit send (D1): named args never ride noSuchMethod's
/// positional recording, so the wire shape assertions use a real override.
class _EditRecordingTransport implements ConversationTransport {
  final List<
      ({
        String sessionId,
        Map<String, dynamic> target,
        String newText,
        String? workspaceMode,
      })>
  edits = [];

  Object? error;

  @override
  Future<dynamic> editUserQuery(
    String sessionId,
    Map<String, dynamic> target,
    String newText, {
    String? workspaceMode,
  }) async {
    edits.add((
      sessionId: sessionId,
      target: target,
      newText: newText,
      workspaceMode: workspaceMode,
    ));
    final err = error;
    if (err != null) throw err;
    return const {'status': 'accepted'};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      Future.value(const {'status': 'accepted'});
}

class _EditGateway extends FakeChatGateway {
  final transport = _EditRecordingTransport();

  @override
  ConversationTransport get conversationCommands => transport;
}

/// Records the attachment upload retry (D6): the FIRST attachmentPut throws
/// (media-budget style), later ones succeed; sendTextOrQueue counts sends.
class _AttachRecordingTransport implements ConversationTransport {
  int attachmentPutCalls = 0;
  int sendCalls = 0;

  @override
  Future<Map<String, dynamic>> attachmentPut(
    String sessionId, {
    required String fileName,
    required String mime,
    required Uint8List bytes,
    void Function(double progress)? onProgress,
  }) async {
    attachmentPutCalls++;
    if (attachmentPutCalls == 1) {
      throw Exception('MEDIA_BUDGET_CURRENT_ATTACHMENT_TOO_LARGE: a.txt');
    }
    return {'ref': 'r1', 'fileName': fileName, 'mime': mime, 'bytes': 1};
  }

  @override
  Future<SendTextResult> sendTextOrQueue(
    String sessionId,
    String text, {
    List<Map<String, dynamic>>? attachments,
    List<Map<String, dynamic>>? conversationQuotes,
    String? heldQueueDisposition,
  }) async {
    sendCalls++;
    return SendTextSent(const {'status': 'accepted'});
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      Future.value(const {'status': 'accepted'});
}

class _AttachGateway extends FakeChatGateway {
  _AttachGateway(this.transport);

  final _AttachRecordingTransport transport;

  @override
  ConversationTransport get conversationCommands => transport;
}
