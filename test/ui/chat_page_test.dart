import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/protocol/remote_client.dart';
import 'package:zgo/state/device_session.dart';
import 'package:zgo/state/entitlement_poller.dart';
import 'package:zgo/state/quota_reset.dart';
import 'package:zgo/ui/chat/chat_page.dart';
import 'package:zgo/ui/chat/subagent_detail_page.dart';
import 'package:zgo/ui/quota_reset_dialog.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../helpers/recording_chat_gateway.dart';

/// Chat-page fake: everything rides the shared loose-default recording
/// gateway — real [ConversationState] frame injection via [RecordingChatGateway.feedSnapshot],
/// command calls recorded in `calls` and answered `accepted` (the
/// conversation command surface goes through `conversationCommands`).
class FakeChatGateway extends RecordingChatGateway {}

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

  @override
  ConversationTransport get conversationCommands => transport;

  @override
  Future<WorkspacePrep> prepareWorkspace() async =>
      _prep ?? await super.prepareWorkspace();
}

/// prepareWorkspace that ships no config options — the sheet-fallback
/// scenario (desktop answered but carried no model/thought selects).
WorkspacePrep barePrep() => WorkspacePrep.fromMap(const {
  'configOptions': <Map<String, dynamic>>[],
  'slashCommands': <Map<String, dynamic>>[],
});

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

/// FakeChatGateway with an injected prepareWorkspace answer (the shared
/// default keeps recording createSession — the payload assertions below
/// ride [FakeChatGateway.calls]).
class _PrepGateway extends FakeChatGateway {
  _PrepGateway(this.prep);

  final WorkspacePrep prep;

  @override
  Future<WorkspacePrep> prepareWorkspace() async => prep;
}

Widget wrap(Widget child) => MaterialApp(
  theme: buildDarkTheme(),
  darkTheme: buildDarkTheme(),
  builder: (context, child) =>
      UiSettingsProvider(settings: UiSettings(), child: child!),
  home: child,
);

/// Gateway seeded with one running subagent (`subagents.running[]` entry +
/// its `kind=='subagent'` works entry, live-probed 2026-09-13) plus one
/// plain bash work — the pill reads the former, the works bar the latter.
FakeChatGateway _gatewayWithSubagentWork() => FakeChatGateway()
  ..snapshotExtra = {
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

Future<void> _pumpWithRunningSubagent(
  WidgetTester tester,
  FakeChatGateway gateway,
) async {
  await tester.pumpWidget(
    wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: '修复登录')),
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
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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
      wrap(ChatPage(gateway: gw, sessionId: 's1', title: 't')),
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
    'IME up: strip floats over the list, composer touches the viewport '
    'bottom (09-20 真机 blank-band regression)', (tester) async {
      final gateway = FakeChatGateway();
      await tester.pumpWidget(
        wrap(
          MediaQuery(
            data: const MediaQueryData(viewInsets: EdgeInsets.only(bottom: 344)),
            child: ChatPage(gateway: gateway, sessionId: 's1', title: 't'),
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
          child: ChatPage(gateway: gateway, sessionId: 's1', title: 't'),
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
      final gateway = FakeChatGateway();
      Widget page(double inset) => wrap(
        MediaQuery(
          data: MediaQueryData(viewInsets: EdgeInsets.only(bottom: inset)),
          child: ChatPage(gateway: gateway, sessionId: 's1', title: 't'),
        ),
      );
      await tester.pumpWidget(page(0));
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
          tester.widget<ListView>(find.byType(ListView)).controller!;
      final pinned = controller();
      expect(
        pinned.position.pixels,
        closeTo(pinned.position.maxScrollExtent, 1),
      );

      // IME up: the viewport shrinks (maxScrollExtent grows), and a pinned
      // list must ride along to the newest row instead of keeping its old
      // offset while the content stays anchored to the viewport top.
      await tester.pumpWidget(page(344));
      await tester.pump();
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
      await tester.pumpWidget(page(0)); // keyboard collapses; clamp recovers
      await tester.pump();
      final relaxed = controller();
      expect(
        relaxed.position.pixels,
        lessThan(relaxed.position.maxScrollExtent - 40),
      );
      await tester.pumpWidget(page(344)); // IME up again, still unpinned
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
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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

  testWidgets('composer hint switches to the queue wording when queued',
      (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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
    gateway.mentionFilesResult = [
      {
        'name': 'chat_page.dart',
        'relativePath': 'lib/ui/chat/chat_page.dart',
        'type': 'file',
      },
    ];
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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
    expect(tf.controller!.text, '看一下 @lib/ui/chat/chat_page.dart ');
  });

  testWidgets('draft mode: first send issues createSession with firstText '
      'and the prep-currentValue thought', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(wrap(ChatPage(gateway: gateway, title: '新任务')));
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

  testWidgets('draft with no thought source ships the max fallback and the '
      'sheet preselects it', (tester) async {
    final gateway = _PrepGateway(prepWithoutThoughtCurrent());
    await tester.pumpWidget(wrap(ChatPage(gateway: gateway, title: '新任务')));
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
    await tester.pumpWidget(wrap(ChatPage(gateway: gateway, title: '新任务')));
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

  testWidgets('existing session: send goes through sendTextOrQueue', (
    tester,
  ) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '继续');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();

    final call = gateway.calls
        .where((c) => c.$1 == 'sendTextOrQueue')
        .toList()
        .single;
    expect(call.$2, ['s1', '继续', null]);
  });

  testWidgets('running keeps send beside stop so follow-ups can queue',
      (tester) async {
    final gateway = FakeChatGateway();
    gateway.snapshotExtra = {
      'control': {'phase': 'running'},
    };
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    // Stop sits at the far right, send stays available.
    expect(find.byIcon(Icons.stop), findsOneWidget);
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);

    await tester.enterText(find.byType(TextField), '排队消息 A');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();
    final call = gateway.calls
        .where((c) => c.$1 == 'sendTextOrQueue')
        .toList()
        .single;
    expect(call.$2[1], '排队消息 A');
  });

  testWidgets('kicked gateway shows the takeover overlay', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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

  testWidgets('subscribe failure surfaces the retry banner', (tester) async {
    final gateway = FakeChatGateway()
      ..failSubscribeWith = (m) => StateError('bridge down');
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    // finite pumps: the page shows an endless connect spinner on failure,
    // pumpAndSettle would time out on it.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('订阅失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('reasoning rows collapse into the 思考过程 strip', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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

  testWidgets('timeline markers render as centered capsules', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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

  testWidgets('更多 menu: official order and pin toggle flips label', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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
        tester.widget<ListView>(find.byType(ListView)).controller!;
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

  testWidgets('running subagent shows the composer pill; the works bar keeps '
      'only the bash row', (tester) async {
    final gateway = _gatewayWithSubagentWork();
    await _pumpWithRunningSubagent(tester, gateway);

    // Pill sits right of the mode chip: agent glyph + running count.
    expect(find.byTooltip('子智能体'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byTooltip('子智能体'),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );

    // Works bar: only the bash count line remains (subagent entries left
    // the bar — they live in the pill + management sheet now).
    expect(find.textContaining('后台任务 1 个运行中'), findsOneWidget);
    expect(find.byTooltip('取消此后台任务'), findsOneWidget);
    expect(find.text('实现加固 · 正在读取 a.dart'), findsNothing);

    // goal=null: the goal panel stays hidden.
    expect(find.text('目标'), findsNothing);
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
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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
  Future<void> openSubagentSheet(WidgetTester tester) async {
    await tester.tap(find.byTooltip('子智能体'));
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

    // Running section: title + 详情/停止 actions. No child toolCall yet →
    // no tail line.
    expect(find.text('实现加固'), findsOneWidget);
    expect(find.text('详情'), findsOneWidget);
    expect(find.text('停止'), findsOneWidget);
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

    // 详情 opens the read-only child-session detail page.
    await tester.tap(find.text('详情'));
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

    await tester.tap(find.text('停止'));
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
    await tester.tap(find.text('停止'));
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
    expect(find.byTooltip('子智能体'), findsOneWidget);
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
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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

  testWidgets('sheet auto-closes after all-terminal holds past the confirm '
      'window', (tester) async {
    final gateway = _gatewayWithSubagentWork();
    await tester.pumpWidget(
      wrap(ChatPage(
        gateway: gateway,
        sessionId: 's1',
        title: 't',
        turnFooterConfirmWindow: const Duration(milliseconds: 150),
      )),
    );
    gateway.feedSnapshot([subagentRow(rowId: 3, status: 'running')]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await openSubagentSheet(tester);
    expect(find.text('子智能体'), findsOneWidget); // sheet header

    // Everything goes terminal: the running section empties immediately,
    // but the sheet itself holds through the confirm window…
    upsertRows(gateway, [subagentRow(rowId: 3, status: 'success')]);
    await tester.pump();
    expect(find.text('子智能体'), findsOneWidget); // header still up
    expect(find.text('详情'), findsNothing); // running section emptied

    // …then it closes itself (and the pill dies with it).
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('子智能体'), findsNothing);
    expect(find.byTooltip('子智能体'), findsNothing);
  });

  testWidgets('pill is destroyed after all-terminal holds past the confirm '
      'window', (tester) async {
    final gateway = _gatewayWithSubagentWork();
    await tester.pumpWidget(
      wrap(ChatPage(
        gateway: gateway,
        sessionId: 's1',
        title: 't',
        turnFooterConfirmWindow: const Duration(milliseconds: 150),
      )),
    );
    gateway.feedSnapshot([subagentRow(rowId: 3, status: 'running')]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byTooltip('子智能体'), findsOneWidget);

    // All terminal: the pill survives the anti-replay window…
    upsertRows(gateway, [subagentRow(rowId: 3, status: 'success')]);
    await tester.pump();
    expect(find.byTooltip('子智能体'), findsOneWidget);

    // …and is destroyed once the window has passed.
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byTooltip('子智能体'), findsNothing);
  });

  testWidgets('a replayed running subagent inside the hysteresis window '
      'never revives the pill', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(
        gateway: gateway,
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
    expect(find.byTooltip('子智能体'), findsNothing);

    // Bridge-recovery replay: subagents.running (+ the matching works
    // entry) reports the finished subagent as running again. The hysteresis
    // view keeps the terminal status → no pill.
    pushRunningReplay(gateway);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byTooltip('子智能体'), findsNothing);
    // The expiry side (persisted running believed after the window) is
    // covered by the SubagentFeed unit test — Future.delayed cannot advance
    // real time inside testWidgets.
  });

  testWidgets('load-older pages from the oldest held row, not the placeholder '
      'snapshot firstRowId', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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
        tester.widget<ListView>(find.byType(ListView)).controller!;
    // Trigger via the pull gesture rather than a button tap: the tap's
    // gesture-arena routing is unreliable in this fixture's frame schedule
    // (armed → prepend post-frame → landing), while the pull drives the
    // same _loadOlder entry the tap's onPressed would.
    Future<void> loadOlderViaPull() async {
      controller.jumpTo(0);
      await tester.pump();
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(ListView)),
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
        gateway: gateway,
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
      {'rowId': 1, 'kind': 'userInput', 'text': '子任务提示'},
      {'rowId': 2, 'kind': 'assistantText', 'text': '子会话结论：完成'},
    ]);
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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
  });

  testWidgets('turn terminal footer waits for the confirm window', (
    tester,
  ) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(
        gateway: gateway,
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
        gateway: gateway,
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

  Future<void> pumpWithQuota(
    WidgetTester tester,
    FakeChatGateway gateway, {
    void Function()? onOpenUsage,
  }) async {
    await tester.pumpWidget(wrap(ChatPage(
      gateway: gateway,
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
      gateway: gateway,
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

  testWidgets('edit-resend dialog button shows the localized label from '
      'both the pencil and the long-press entry', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '帮我修复登录', 'state': 'done'},
    ]);
    await tester.pumpAndSettle();

    // Pencil beside the bubble.
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    // R1 regression: the button must read the table copy, never the raw
    // (dotted) key.
    expect(find.widgetWithText(FilledButton, '编辑并重发'), findsOneWidget);
    expect(find.text('chat.action.edit.resend'), findsNothing);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    // Long-press bottom sheet entry. The bubble is a SelectableText — its
    // long-press selection would win the gesture arena, so press the bubble
    // padding just outside the text where the row's GestureDetector owns
    // the press.
    final textTopLeft = tester.getTopLeft(find.text('帮我修复登录'));
    await tester.longPressAt(textTopLeft - const Offset(8, 4));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑并重发'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, '编辑并重发'), findsOneWidget);
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

  testWidgets('empty model config keeps the composer model/thought chips '
      'with placeholder labels', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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

  testWidgets('sheet switch: lost ack lands the optimistic patch and closes '
      'the sheet with the pending toast', (tester) async {
    final transport = _SwitchTransport(results: [
      TimeoutException('switchModelConfig'),
    ]);
    final gateway = _SwitchGateway(transport);
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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

  testWidgets('loading placeholder: degraded bridge line + slow hint after 5s', (
    tester,
  ) async {
    final session = _DegradedBridgeSession()
      ..degraded.value = 'rpc-transport-fault';
    final gateway = _StalledGateway(_DegradedTransport(session));
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    await tester.pumpAndSettle();
    return gateway;
  }

  ScrollController historyController(WidgetTester tester) =>
      tester.widget<ListView>(find.byType(ListView)).controller!;

  int rowsRangeCalls(FakeChatGateway gateway) =>
      gateway.calls.where((c) => c.$1 == 'rowsRange').length;

  /// Drag depth landing mid-window (past the max(64, 2×viewport) prefetch
  /// threshold, still in range so the anchor offset stays positive).
  double inWindowDrag(ScrollController controller) =>
      controller.offset -
      math.max(64.0, controller.position.viewportDimension * 2) / 2;

  /// Message texts currently built inside the list viewport — the
  /// "what the reader sees" set for the anchor assertions. User bubbles
  /// render as [SelectableText] (assistant markdown as [Text]), so match
  /// both. The compensation jump approximates the exact offset within
  /// SliverList's trailing-extent estimate, so anchoring is asserted
  /// semantically: the visible set must survive the load (a teleport to
  /// the page top or bottom would show none of the old messages).
  Set<String> visibleMessages(WidgetTester tester) => {
    for (final w in tester.widgetList<SelectableText>(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(SelectableText),
      ),
    ))
      w.data,
    for (final w in tester.widgetList<Text>(
      find.descendant(of: find.byType(ListView), matching: find.byType(Text)),
    ))
      w.data,
  }.whereType<String>().toSet();

  /// The topmost visible history message: (text, screen Y of its top) —
  /// the reading anchor for pixel-level displacement assertions.
  (String, double) topmostHistoryMessage(WidgetTester tester) {
    final entries = <(String, double)>[];
    for (final w in tester.widgetList<SelectableText>(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(SelectableText),
      ),
    )) {
      final data = w.data ?? '';
      if (!data.startsWith('历史消息')) continue;
      final box = tester.renderObject(find.byWidget(w)) as RenderBox;
      entries.add((data, box.localToGlobal(Offset.zero).dy));
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
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    await tester.pumpAndSettle();
    final controller = historyController(tester);
    // Exactly one call despite the open animation sweeping the window —
    // programmatic positioning parks the trigger.
    expect(transport.calls.length, 1, reason: 'open auto-load consumed page 1');

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
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
      tester.getCenter(find.byType(ListView)),
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
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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
      find.byType(ListView),
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
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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
      tester.getCenter(find.byType(ListView)),
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
      tester.getCenter(find.byType(ListView)),
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
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot(historyRows(1, 40)); // no firstRowId → nothing older
    await tester.pumpAndSettle();
    final controller = historyController(tester);
    controller.jumpTo(0);
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
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
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    await tester.pumpAndSettle();

    final controller = historyController(tester);
    controller.jumpTo(0);
    await tester.pumpAndSettle();
    final visibleBefore = visibleMessages(tester);
    expect(visibleBefore, isNotEmpty);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
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
      tester.getCenter(find.byType(ListView)),
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
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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
      tester.getCenter(find.byType(ListView)),
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
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    await tester.pumpAndSettle();
    final controller = historyController(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
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
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    await tester.pumpAndSettle();

    final controller = historyController(tester);
    // Pinned at the TRUE bottom: offset == max means the content end (last
    // group + bottom padding) fills the viewport exactly — no blank tail
    // past the end (the overshoot bug), no undershoot (the estimate bug).
    expect(controller.offset, closeTo(controller.position.maxScrollExtent, 0.5));
    final listBox = tester.renderObject(find.byType(ListView)) as RenderBox;
    final viewportTop = listBox.localToGlobal(Offset.zero).dy;
    final viewportBottom = viewportTop + listBox.size.height;
    // The newest message text is on screen, just above the viewport bottom
    // (its group bottom plus the list padding IS the content end).
    final lastBottom = tester.getBottomRight(find.text('历史消息 111')).dy;
    expect(lastBottom, lessThanOrEqualTo(viewportBottom));
    expect(lastBottom, greaterThanOrEqualTo(viewportTop));
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
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    await tester.pumpAndSettle();

    // Fire the load with a user-driven drag inside the prefetch window
    // (programmatic jumps don't arm it by design).
    final controller = historyController(tester);
    controller.jumpTo(600);
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
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
        .ancestor(of: find.byType(ListView), matching: find.byType(Opacity))
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
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    // A shell session: the subscription lands with zero rows.
    gateway.feedSnapshot([]);
    await tester.pump();
    await tester.pump();

    expect(find.text('会话未能启动'), findsOneWidget);
    expect(find.text('会话未能启动，请重试或检查模型/思考档配置。'),
        findsOneWidget);
  });

  testWidgets('shell session: error displayStatus with rows keeps the normal '
      'list — no card', (tester) async {
    final gateway = FakeChatGateway()..taskDisplayStatuses['s1'] = 'error';
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
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
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(
        ChatPage(
          gateway: gateway,
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
    expect(pushed.gateway, same(gateway));
    expect(pushed.workspaceLabel, 'ZLinker');
    expect(find.text('新建任务'), findsOneWidget);
  });

  testWidgets('message-sheet fork pushes the acked session too — the row '
      'context survives the sheet pop', (tester) async {
    final gateway = await pumpForkSource(tester);
    gateway.forkAssistantResults.add(forkAck());

    // Long-press just outside the bubble text: the row's GestureDetector
    // owns the press there (the SelectableText would win on the text).
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

/// Transport stand-in that only exposes the bridge session; everything
/// else is never exercised on the loading path.
class _DegradedTransport implements ConversationTransport {
  _DegradedTransport(this.session);

  @override
  final BridgeSession session;

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
