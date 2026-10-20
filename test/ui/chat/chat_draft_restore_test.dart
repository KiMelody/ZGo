import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zgo/state/chat_draft_store.dart';
import 'package:zgo/ui/chat/chat_page.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../../helpers/recording_chat_gateway.dart';

class _Gw extends RecordingChatGateway {}

Widget wrap(Widget child) => MaterialApp(
  theme: buildDarkTheme(),
  darkTheme: buildDarkTheme(),
  builder: (context, child) =>
      UiSettingsProvider(settings: UiSettings(), child: child!),
  home: child,
);

/// Text-only store (no attachment root): everything it touches — mock
/// prefs and in-memory maps — completes inside the widget-test zone, so
/// no runAsync dance is needed. The file-IO paths live in
/// test/state/chat_draft_store_test.dart (plain `test()`, real IO).
ChatDraftStore textStore() => ChatDraftStore(deviceId: 'd1');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('stored draft restores into the composer', (tester) async {
    final gw = _Gw();
    final store = textStore();
    gw.chatDraftStore = store;
    await store.saveText('s1', 'hello draft', 0);

    await tester.pumpWidget(wrap(ChatPage(gateway: gw, sessionId: 's1', title: 't')));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('hello draft'), findsOneWidget);
  });

  testWidgets('initialComposerText prefill wins over a stored draft',
      (tester) async {
    final gw = _Gw();
    final store = textStore();
    gw.chatDraftStore = store;
    await store.saveText('s1', 'stored text', 0);

    await tester.pumpWidget(
      wrap(ChatPage(
        gateway: gw,
        sessionId: 's1',
        title: 't',
        initialComposerText: '/compact',
      )),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('/compact'), findsOneWidget);
    expect(find.text('stored text'), findsNothing);
  });

  testWidgets('typed text persists after the debounce window', (tester) async {
    final gw = _Gw();
    final store = textStore();
    gw.chatDraftStore = store;

    await tester.pumpWidget(wrap(ChatPage(gateway: gw, sessionId: 's1', title: 't')));
    await tester.enterText(find.byType(TextField).first, 'typing away');
    await tester.pump(const Duration(milliseconds: 600));

    expect((await store.restore('s1'))!.text, 'typing away');
  });

  testWidgets('a successful send kills the draft entry', (tester) async {
    final gw = _Gw();
    final store = textStore();
    gw.chatDraftStore = store;

    await tester.pumpWidget(wrap(ChatPage(gateway: gw, sessionId: 's1', title: 't')));
    await tester.enterText(find.byType(TextField).first, 'bye draft');
    await tester.pump(const Duration(milliseconds: 600));
    expect((await store.restore('s1'))!.text, 'bye draft');

    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('bye draft'), findsNothing);
    expect(await store.restore('s1'), isNull);
  });

  testWidgets('first send on a draft page kills the placeholder entry',
      (tester) async {
    final gw = _Gw();
    final store = textStore();
    gw.chatDraftStore = store;

    await tester.pumpWidget(wrap(ChatPage(gateway: gw, title: 't')));
    await tester.enterText(find.byType(TextField).first, 'new task text');
    await tester.pump(const Duration(milliseconds: 600));
    expect((await store.restore('draft.ws-1'))!.text, 'new task text');

    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump(const Duration(milliseconds: 600));

    // createSession carried the text (firstInput); the placeholder died
    // so it cannot resurface in the next new-task page.
    expect(await store.restore('draft.ws-1'), isNull);
    expect(
      gw.calls.where((c) => c.$1 == 'createSession').single.$2,
      contains('new task text'),
    );
  });

  testWidgets('dispose flushes a non-empty composer', (tester) async {
    final gw = _Gw();
    final store = textStore();
    gw.chatDraftStore = store;

    await tester.pumpWidget(wrap(ChatPage(gateway: gw, sessionId: 's1', title: 't')));
    await tester.enterText(find.byType(TextField).first, 'left mid-thought');
    // No debounce wait: page death itself must persist the text.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect((await store.restore('s1'))!.text, 'left mid-thought');
  });
}
