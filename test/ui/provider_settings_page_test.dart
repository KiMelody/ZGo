import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/connection_params.dart';
import 'package:zgo/ui/provider_settings_page.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import 'overflow_smoke_test.dart' show loadBundledFonts;
import '../helpers/fake_device_session.dart';

/// Family disambiguation on the provider-settings page (PRD requirement 5):
/// the desktop names both 智谱 families' start-plan entries bare
/// "Start Plan" (`account:zai-start-plan` and `account:bigmodel-start-plan`),
/// so both rows gain their family prefix (Z.AI / BigModel) while wire names
/// that already carry one and personal rows keep their names verbatim.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Real glyph metrics (same helper the overflow smoke matrix uses): the
  // 1em-box test font is roughly twice as wide as the device font and turns
  // this page's form copy into phantom overflows.
  setUpAll(loadBundledFonts);

  Widget wrap(Widget child) => MaterialApp(
        theme: buildLightTheme(),
        darkTheme: buildDarkTheme(),
        builder: (context, child) =>
            UiSettingsProvider(settings: UiSettings(), child: child!),
        home: child,
      );

  RemoteConnectionParams paramsOf() => RemoteConnectionParams.parse(
        'https://zcode.zai/remote/v4?sid=s&hash=h&t=123&mid=m&name=test',
      )!;

  Map<String, Object?> accountProvider(String id, String name) => {
        'providerId': id,
        'providerName': name,
        'enabled': true,
        'executable': true,
        'accountState': {
          'access': {'type': 'zhipu-account'},
        },
        'effectiveConfig': {
          'access': {
            'type': 'zhipu-account',
            'mode': 'start-plan',
            'entitled': true,
          },
        },
        'issues': <Object>[],
        'models': <Object>[],
      };

  Map<String, Object?> personalProvider(String id, String name) => {
        'providerId': id,
        'providerName': name,
        'enabled': true,
        'executable': true,
        'personalConfig': {
          'access': {'type': 'api-key'},
        },
        'effectiveConfig': {
          'access': {'type': 'api-key'},
        },
        'issues': <Object>[],
        'models': <Object>[],
      };

  Map<String, Object?> viewOf(List<Map<String, Object?>> providers) => {
        'revision': '[1,1]',
        'providerTemplates': <Object>[],
        'providerOrder': [
          for (final p in providers)
            if (p['personalConfig'] != null) p['providerId'],
        ],
        'providers': providers,
      };

  FakeDeviceSession sessionOf(Object? view) => FakeDeviceSession(
        deviceId: 'd1',
        params: paramsOf(),
        channelHandler: (channel, method, args) async {
          if (channel == Channels.providerSettings && method == 'getView') {
            return view;
          }
          throw StateError('unexpected $channel.$method');
        },
      );

  testWidgets('bigmodel plan rows gain the brand prefix, others stay verbatim',
      (WidgetTester tester) async {
    final view = viewOf([
      accountProvider('account:zai-start-plan', 'Start Plan'),
      accountProvider('account:zai-individual-coding-plan',
          'Z.AI Individual Coding Plan'),
      accountProvider('account:bigmodel-start-plan', 'Start Plan'),
      accountProvider('account:bigmodel-individual-coding-plan',
          'BigModel Individual Coding Plan'),
      personalProvider('custom-x', '幻城'),
    ]);
    final session = sessionOf(view);
    addTearDown(() => session.dispose());
    await tester.pumpWidget(wrap(ProviderSettingsPage(session: session)));
    await tester.pumpAndSettle();

    // Both bare start-plan rows gain their family prefix.
    expect(find.text('BigModel Start Plan'), findsOneWidget);
    expect(find.text('Z.AI Start Plan'), findsOneWidget);
    expect(find.text('Start Plan'), findsNothing);
    // Already-prefixed wire names are not double-prefixed.
    expect(find.text('BigModel Individual Coding Plan'), findsOneWidget);
    expect(find.textContaining('BigModel BigModel'), findsNothing);
    expect(find.text('Z.AI Individual Coding Plan'), findsOneWidget);
    expect(find.textContaining('Z.AI Z.AI'), findsNothing);
    // Personal provider names are untouched.
    expect(find.text('幻城'), findsOneWidget);
  });

  testWidgets('detail account card shows the same disambiguated name',
      (WidgetTester tester) async {
    final view =
        viewOf([accountProvider('account:bigmodel-start-plan', 'Start Plan')]);
    final session = sessionOf(view);
    addTearDown(() => session.dispose());
    await tester.pumpWidget(wrap(ProviderSettingsPage(session: session)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('BigModel Start Plan'));
    await tester.pumpAndSettle();

    // The account card title (not just the list row) carries the prefix.
    expect(
      find.descendant(
        of: find.byType(Card),
        matching: find.text('BigModel Start Plan'),
      ),
      findsOneWidget,
    );
  });

  // ------------------------------------------------------ keyboard / focus

  /// Keyboard regression net beyond the chat page (task 11-06 IM-D-03): the
  /// personal-provider form's Base URL field must keep focus while the IME
  /// shrinks the viewport and typing runs the page's own setState — the
  /// remount-drops-focus shape chat-conventions §8 契约一 pins for the chat
  /// composer.
  ///
  /// Recipe = the repo's settled one (`composer_overflow_test.raiseKeyboard`
  /// shape): explicit `physicalSize` + `devicePixelRatio` so the layout has
  /// a real height, then `viewInsets` on the real view (a tree-injected
  /// MediaQuery does not resize the Scaffold). The SIZE PROBE comes first —
  /// an inset that never reached the tree would leave every focus assertion
  /// vacuously green.
  testWidgets(
      'keyboard shrink keeps the form field focused while typing',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final view = viewOf([
      accountProvider('account:zai-start-plan', 'Start Plan'),
      personalProvider('custom-x', '幻城'),
    ]);
    final session = sessionOf(view);
    addTearDown(() => session.dispose());
    await tester.pumpWidget(wrap(ProviderSettingsPage(session: session)));
    await tester.pumpAndSettle();

    // List → detail: the personal row opens the inline-edit form.
    await tester.tap(find.text('幻城'));
    await tester.pumpAndSettle();

    final field = find.widgetWithText(TextField, 'Base URL');
    expect(field, findsOneWidget);
    // The page owns no FocusNode; the live node is the inner EditableText's.
    FocusNode nodeOf() => tester
        .widget<EditableText>(
          find.descendant(of: field, matching: find.byType(EditableText)),
        )
        .focusNode;

    await tester.tap(field);
    await tester.pump();
    final focusedBefore = FocusManager.instance.primaryFocus;
    expect(nodeOf().hasFocus, isTrue);
    expect(focusedBefore, isNotNull);

    // Resting height of the form's scroll viewport (the Scaffold resizes
    // it; the field sits at the top so it never moves).
    Size formProbe() => tester.getSize(find.byType(ListView).last);
    final restingForm = formProbe();

    // Raise the IME (finite pumps — this page has no endless animation, but
    // the two-pump shape matches the chat precedent and settles the resize).
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // SIZE PROBE first: the keyboard branch provably ran.
    expect(restingForm.height - formProbe().height, greaterThan(100));

    // Typing drives the page's own setState cycles; the focus must survive.
    await tester.enterText(field, 'https://api.example.com/v2');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<TextField>(field).controller!.text,
        'https://api.example.com/v2');

    expect(FocusManager.instance.primaryFocus, same(focusedBefore));
    expect(nodeOf().hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  });
}
