import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/protocol/channel_client.dart';
import 'package:zlinker/protocol/connection_params.dart';
import 'package:zlinker/ui/model_providers_page.dart';
import 'package:zlinker/ui/theme.dart';
import 'package:zlinker/ui/ui_settings.dart';

import 'helpers/fake_device_session.dart';

/// Version routing of the model settings entry (09-28 providers-revival):
/// ≥3.14 → provider-settings page; known ≤3.14 → legacy `model-provider`
/// page verbatim (regression baseline: same channel calls, same
/// channel-unavailable fallback); unknown version → legacy until the old
/// channel is known-gone, then one new-channel getView probe.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(Widget child) => MaterialApp(
        theme: buildLightTheme(),
        darkTheme: buildDarkTheme(),
        builder: (context, child) =>
            UiSettingsProvider(settings: UiSettings(), child: child!),
        home: child,
      );

  RemoteConnectionParams paramsOf(String? version) =>
      RemoteConnectionParams.parse(
        'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=123&mid=m&name=test'
        '${version == null ? '' : '&app_version=$version'}',
      )!;

  Object? providerSettingsView() => {
        'revision': '[30,4]',
        'providerOrder': [],
        'providerTemplates': [],
        'providers': [
          {
            'providerId': 'account:zai-individual-coding-plan',
            'providerName': 'Z.ai',
            'enabled': true,
            'executable': true,
            'accountState': {'accountType': 'zai'},
            'effectiveConfig': {
              'access': {
                'type': 'zhipu-account',
                'accountType': 'zai',
                'mode': 'individual-coding-plan',
                'entitled': true,
              },
            },
            'issues': [],
            'models': [],
          },
          {
            'providerId': 'p1',
            'providerName': 'My Relay',
            'enabled': true,
            'executable': true,
            'personalConfig': {
              'group': 'standard-personal',
              'access': {'type': 'api-key'},
            },
            'effectiveConfig': {},
            'issues': [],
            'models': [],
          },
        ],
      };

  testWidgets('known ≥3.14 opens the provider-settings page',
      (WidgetTester tester) async {
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: paramsOf('3.14.3'),
      channelHandler: (channel, method, args) async =>
          channel == Channels.providerSettings && method == 'getView'
              ? providerSettingsView()
              : throw StateError('unexpected $channel.$method'),
    );
    addTearDown(() => session.dispose());
    await tester.pumpWidget(wrap(ModelProvidersPage(session: session)));
    await tester.pumpAndSettle();

    // Grouped list rendered from the new view.
    expect(find.text('智谱'), findsOneWidget);
    expect(find.text('自定义供应商'), findsOneWidget);
    expect(find.text('My Relay'), findsOneWidget);
    // The legacy channel was never touched.
    expect(session.channelCalls.map((c) => c.$1),
        everyElement(Channels.providerSettings));
  });

  testWidgets('known ≤3.12.2 keeps the legacy page and wire',
      (WidgetTester tester) async {
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: paramsOf('3.12.2'),
      channelHandler: (channel, method, args) async {
        expect(channel, Channels.modelProvider, reason: 'legacy wire only');
        expect(method, 'getAll');
        return [];
      },
    );
    addTearDown(() => session.dispose());
    await tester.pumpWidget(wrap(ModelProvidersPage(session: session)));
    await tester.pumpAndSettle();

    // Legacy empty list state (RefreshIndicator), not the new page and
    // not the unavailable fallback.
    expect(find.byType(RefreshIndicator), findsOneWidget);
    expect(find.text('桌面端通道不可用'), findsNothing);
    expect(find.text('自定义供应商'), findsNothing);
    expect(session.channelCalls, hasLength(1));
    expect(session.channelCalls.single.$1, Channels.modelProvider);
    expect(session.channelCalls.single.$2, 'getAll');
    expect(session.channelCalls.single.$3, isEmpty);
  });

  testWidgets('known 3.12.3–3.13 keeps the channel-unavailable fallback',
      (WidgetTester tester) async {
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: paramsOf('3.12.3'),
      channelHandler: (channel, method, args) async => throw ChannelRpcError(
          "Channel name '$channel' timed out after 1000ms", null),
    );
    addTearDown(() => session.dispose());
    await tester.pumpWidget(wrap(ModelProvidersPage(session: session)));
    await tester.pumpAndSettle();

    expect(find.text('桌面端通道不可用'), findsOneWidget);
    // The dead legacy channel never triggers a new-channel probe on a
    // known-old desktop.
    expect(
        session.channelCalls.map((c) => c.$1), everyElement('model-provider'));
  });

  testWidgets('unknown version: legacy page after the shell probes the old channel',
      (WidgetTester tester) async {
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: paramsOf(null),
      channelHandler: (channel, method, args) async =>
          channel == Channels.modelProvider
              ? []
              : throw StateError('unexpected $channel.$method'),
    );
    addTearDown(() => session.dispose());
    await tester.pumpWidget(wrap(ModelProvidersPage(session: session)));
    await tester.pumpAndSettle();

    // No cached verdict → the shell awaits the legacy probe itself, then
    // serves the legacy page. Two model-provider calls land: the probe and
    // the legacy page's getAll.
    expect(find.byType(RefreshIndicator), findsOneWidget);
    expect(session.channelCalls.map((c) => c.$1),
        everyElement(Channels.modelProvider));
    expect(session.channelCalls, hasLength(2));
    expect(session.channelCalls.every((c) => c.$2 == 'getAll'), isTrue);
  });

  testWidgets('unknown version + dead old channel probes the new one',
      (WidgetTester tester) async {
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: paramsOf(null),
      channelHandler: (channel, method, args) async =>
          channel == Channels.modelProvider
              ? throw ChannelRpcError(
                  "Channel name '$channel' timed out after 1000ms", null)
              : providerSettingsView(),
    );
    addTearDown(() => session.dispose());
    await tester.pumpWidget(wrap(ModelProvidersPage(session: session)));
    await tester.pumpAndSettle();

    // Legacy probe (awaited by the shell) fails → new-channel getView probe
    // succeeded → revived page. Three calls land in order: the failing
    // legacy probe, the shell's fallback probe, the page's load.
    expect(find.text('自定义供应商'), findsOneWidget);
    expect(find.text('My Relay'), findsOneWidget);
    expect(session.channelCalls, hasLength(3));
    expect(session.channelCalls[0].$1, Channels.modelProvider);
    expect(session.channelCalls[0].$2, 'getAll');
    expect(session.channelCalls[1].$1, Channels.providerSettings);
    expect(session.channelCalls[1].$2, 'getView');
    expect(session.channelCalls[2].$1, Channels.providerSettings);
    expect(session.channelCalls[2].$2, 'getView');
  });

  testWidgets('edit-model dialog renames via the wire and refreshes',
      (WidgetTester tester) async {
    final view = providerSettingsView() as Map;
    final providers = view['providers'] as List;
    (providers[1] as Map)['models'] = [
      {
        'modelId': 'm-old',
        'enabled': true,
        'executable': true,
        'useRecommendedConfig': true,
        'effectiveConfig': {
          'properties': {'contextWindow': 200000},
        },
        'issues': [],
      },
    ];
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: paramsOf('3.14.3'),
      channelHandler: (channel, method, args) async {
        if (method == 'getView') return view;
        if (method == 'renamePersonalModel') {
          expect(args, ['p1', 'm-old', 'm-new']);
          view['revision'] = '[31,4]';
          (providers[1] as Map)['models'] = [
            {
              'modelId': 'm-new',
              'enabled': true,
              'executable': true,
              'useRecommendedConfig': true,
              'effectiveConfig': const {},
              'issues': const [],
            },
          ];
          return view;
        }
        throw StateError('unexpected $method');
      },
    );
    addTearDown(() => session.dispose());
    await tester.pumpWidget(wrap(ModelProvidersPage(session: session)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('My Relay'));
    await tester.pumpAndSettle();
    // Detail page: model row + its edit button.
    expect(find.text('m-old'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.edit_outlined).first);
    await tester.pumpAndSettle();
    expect(find.text('编辑模型配置'), findsOneWidget);

    // Rename via the dialog's save action.
    await tester.enterText(
        find.widgetWithText(TextField, 'm-old'), 'm-new');
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('保存')));
    await tester.pumpAndSettle();

    // The dialog closed and the list reflects the desktop's reply.
    expect(find.text('编辑模型配置'), findsNothing);
    expect(find.text('m-new'), findsOneWidget);
    expect(
        session.channelCalls.any((c) =>
            c.$1 == Channels.providerSettings &&
            c.$2 == 'renamePersonalModel'),
        isTrue);
  });

  testWidgets('provider rename rides the overlay patch and retitles',
      (WidgetTester tester) async {
    final view = providerSettingsView() as Map;
    final providers = view['providers'] as List;
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: paramsOf('3.14.3'),
      channelHandler: (channel, method, args) async {
        if (method == 'getView') return view;
        if (method == 'savePersonalProviderOverlay') {
          expect(args, ['p1', {}, {'providerName': 'Renamed'}]);
          view['revision'] = '[31,4]';
          (providers[1] as Map)['providerName'] = 'Renamed';
          return view;
        }
        throw StateError('unexpected $method');
      },
    );
    addTearDown(() => session.dispose());
    await tester.pumpWidget(wrap(ModelProvidersPage(session: session)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('My Relay'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'My Relay'),
        'Renamed');
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('添加')));
    await tester.pumpAndSettle();

    // The detail page retitle comes from the desktop's reply view.
    expect(find.text('Renamed'), findsOneWidget);
    expect(
        session.channelCalls.any((c) =>
            c.$1 == Channels.providerSettings &&
            c.$2 == 'savePersonalProviderOverlay'),
        isTrue);
  });

  testWidgets('provider delete pops true and the list reloads',
      (WidgetTester tester) async {
    final view = providerSettingsView() as Map;
    final providers = view['providers'] as List;
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: paramsOf('3.14.3'),
      channelHandler: (channel, method, args) async {
        if (method == 'getView') return view;
        if (method == 'deletePersonalProvider') {
          expect(args, ['p1']);
          view['revision'] = '[31,4]';
          providers.removeAt(1);
          return view;
        }
        throw StateError('unexpected $method');
      },
    );
    addTearDown(() => session.dispose());
    await tester.pumpWidget(wrap(ModelProvidersPage(session: session)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('My Relay'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    // Confirm the danger dialog.
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('确认删除')));
    await tester.pumpAndSettle();

    // Back on the list, reloaded without the deleted provider.
    expect(find.text('自定义供应商'), findsOneWidget);
    expect(find.text('My Relay'), findsNothing);
    expect(
        session.channelCalls.any((c) =>
            c.$1 == Channels.providerSettings &&
            c.$2 == 'deletePersonalProvider'),
        isTrue);
    // getView ran twice: initial load + post-delete reload.
    expect(
        session.channelCalls
            .where((c) => c.$2 == 'getView')
            .length,
        greaterThanOrEqualTo(2));
  });

  /// The Switch of the dialog row carrying [label] — switches sit next to
  /// the label inside a shared Row. Scoped to the AlertDialog so the model
  /// row's 视觉 badge (page behind the dialog) never steals the match.
  Finder dialogRowSwitch(String label) {
    final row = find
        .ancestor(
          of: find.descendant(
              of: find.byType(AlertDialog), matching: find.text(label)),
          matching: find.byType(Row),
        )
        .first;
    return find.descendant(of: row, matching: find.byType(Switch)).first;
  }

  testWidgets('manual save writes the extractManualModelConfig whitelist',
      (WidgetTester tester) async {
    final view = providerSettingsView() as Map;
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: paramsOf('3.14.3'),
      channelHandler: (channel, method, args) async {
        if (method == 'getView') return view;
        if (method == 'addPersonalModel') {
          // Whitelist: contextWindow + three capability booleans (false
          // written even when off) + inputFormat as the official T0
          // three-key pick; no reasoning level, no maxOutputTokens (empty
          // field), useRecommendedConfig=false.
          expect(args, [
            'p1',
            'm1',
            {
              'properties': {
                'contextWindow': 128000,
                'supportsJsonSchemaOutput': false,
                'supportsNativeWebSearch': false,
                'supportsMidConversationSystem': false,
                'inputFormat': {
                  'supportsImage': true,
                  'supportsVideo': false,
                  'supportsPdf': false,
                },
              },
            },
            false,
          ]);
          view['revision'] = '[31,4]';
          (view['providers'] as List)[1]['models'] = [
            {
              'modelId': 'm1',
              'enabled': true,
              'executable': true,
              'useRecommendedConfig': false,
              'effectiveConfig': {
                'properties': {
                  'contextWindow': 128000,
                  'inputFormat': {'supportsImage': true},
                },
              },
              'issues': [],
            },
          ];
          return view;
        }
        throw StateError('unexpected $method');
      },
    );
    addTearDown(() => session.dispose());
    await tester.pumpWidget(wrap(ModelProvidersPage(session: session)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('My Relay'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加模型'));
    await tester.pumpAndSettle();

    // Manual mode: switch smart config off → the advanced toggle appears.
    await tester.tap(dialogRowSwitch('智能配置'));
    await tester.pumpAndSettle();
    expect(find.text('高级配置'), findsOneWidget);

    // Expand and flip vision on (collapsed by default).
    await tester.tap(find.text('高级配置'));
    await tester.pumpAndSettle();
    await tester.tap(dialogRowSwitch('视觉'));

    await tester.enterText(find.widgetWithText(TextField, '模型 ID'), 'm1');
    await tester.enterText(
        find.widgetWithText(TextField, '上下文窗口'), '128000');
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('保存')));
    await tester.pumpAndSettle();

    // Dialog closed, the reply view rendered the new model row.
    expect(find.text('高级配置'), findsNothing);
    expect(find.text('m1'), findsOneWidget);
  });

  testWidgets('smart config hides the advanced section and writes no fields',
      (WidgetTester tester) async {
    final view = providerSettingsView() as Map;
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: paramsOf('3.14.3'),
      channelHandler: (channel, method, args) async {
        if (method == 'getView') return view;
        if (method == 'addPersonalModel') {
          // Official addPersonalModel(pid, mid, {}, true): the desktop
          // fills in the recommended values.
          expect(args, ['p1', 'm2', {}, true]);
          view['revision'] = '[31,4]';
          (view['providers'] as List)[1]['models'] = [
            {
              'modelId': 'm2',
              'enabled': true,
              'executable': true,
              'useRecommendedConfig': true,
              'effectiveConfig': const {},
              'issues': const [],
            },
          ];
          return view;
        }
        throw StateError('unexpected $method');
      },
    );
    addTearDown(() => session.dispose());
    await tester.pumpWidget(wrap(ModelProvidersPage(session: session)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('My Relay'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加模型'));
    await tester.pumpAndSettle();

    // Smart (default on): no advanced copy anywhere in the dialog.
    expect(find.text('高级配置'), findsNothing);
    expect(find.text('视觉'), findsNothing);
    expect(find.text('结构化输出'), findsNothing);

    await tester.enterText(find.widgetWithText(TextField, '模型 ID'), 'm2');
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('保存')));
    await tester.pumpAndSettle();

    expect(find.text('m2'), findsOneWidget);
  });

  testWidgets('edit backfills capabilities and reasoning from effectiveConfig',
      (WidgetTester tester) async {
    final view = providerSettingsView() as Map;
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: paramsOf('3.14.3'),
      channelHandler: (channel, method, args) async {
        if (method == 'getView') return view;
        if (method == 'savePersonalModelDraft') {
          // Toggled 结构化输出 off → the boolean diff rode the whitelist
          // draft; reasoning level stays unwritten.
          expect(args, [
            {
              'providerId': 'p1',
              'originalModelId': 'm-vision',
              'nextModelId': 'm-vision',
              'personalConfig': {
                'properties': {
                  'supportsJsonSchemaOutput': false,
                  'supportsNativeWebSearch': false,
                  'supportsMidConversationSystem': false,
                  'inputFormat': {
                    'supportsImage': true,
                    'supportsVideo': false,
                    'supportsPdf': false,
                  },
                },
                'optionSpecs': {'maxOutputTokens': 8192},
              },
              'basedOnRevision': '[30,4]',
              'useRecommendedConfig': false,
            },
          ]);
          view['revision'] = '[31,4]';
          return view;
        }
        throw StateError('unexpected $method');
      },
    );
    addTearDown(() => session.dispose());
    (view['providers'] as List)[1]['models'] = [
      {
        'modelId': 'm-vision',
        'enabled': true,
        'executable': true,
        'useRecommendedConfig': false,
        'effectiveConfig': {
          'properties': {
            'inputFormat': {'supportsImage': true},
            'supportsJsonSchemaOutput': true,
          },
          'optionSpecs': {
            // Distinct from the fresh-create low/high/max default —
            // proves the chips read the effective config.
            'reasoningLevel': {'values': ['low', 'mid', 'high']},
            'maxOutputTokens': 8192,
          },
        },
        'issues': [],
      },
    ];
    await tester.pumpWidget(wrap(ModelProvidersPage(session: session)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('My Relay'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.edit_outlined).first);
    await tester.pumpAndSettle();

    // Manual model → the advanced toggle is there; expand it.
    await tester.tap(find.text('高级配置'));
    await tester.pumpAndSettle();

    // Backfill: vision + structured output on (?? false semantics).
    expect(
        tester.widget<Switch>(dialogRowSwitch('视觉')).value, isTrue);
    expect(tester.widget<Switch>(dialogRowSwitch('结构化输出')).value, isTrue);
    expect(tester.widget<Switch>(dialogRowSwitch('原生联网搜索')).value, isFalse);
    // Reasoning chips come from the effective values.
    expect(find.text('low'), findsOneWidget);
    expect(find.text('mid'), findsOneWidget);
    expect(find.text('high'), findsOneWidget);
    expect(find.text('max'), findsNothing);

    // Toggle 结构化输出 off and save → configChanged via the boolean diff.
    await tester.tap(dialogRowSwitch('结构化输出'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('保存')));
    await tester.pumpAndSettle();

    expect(find.text('高级配置'), findsNothing);
    expect(
        session.channelCalls.any((c) => c.$2 == 'savePersonalModelDraft'),
        isTrue);
  });

  testWidgets('vision model rows render the 视觉 badge',
      (WidgetTester tester) async {
    final view = providerSettingsView() as Map;
    (view['providers'] as List)[1]['models'] = [
      {
        'modelId': 'glm-4.7v-flash',
        'enabled': true,
        'executable': true,
        'useRecommendedConfig': true,
        'effectiveConfig': {
          'properties': {
            'inputFormat': {'supportsImage': true},
          },
        },
        'issues': [],
      },
      {
        'modelId': 'glm-4.7-flash',
        'enabled': true,
        'executable': true,
        'useRecommendedConfig': true,
        'effectiveConfig': const {},
        'issues': [],
      },
    ];
    final session = FakeDeviceSession(
      deviceId: 'd1',
      params: paramsOf('3.14.3'),
      channelHandler: (channel, method, args) async => view,
    );
    addTearDown(() => session.dispose());
    await tester.pumpWidget(wrap(ModelProvidersPage(session: session)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('My Relay'));
    await tester.pumpAndSettle();

    // One badge, next to the vision-capable model only.
    expect(find.text('glm-4.7v-flash'), findsOneWidget);
    expect(find.text('glm-4.7-flash'), findsOneWidget);
    expect(find.text('视觉'), findsOneWidget);
  });
}
