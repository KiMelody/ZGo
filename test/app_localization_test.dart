import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zgo/main.dart';
import 'package:zgo/ui/devices_page.dart';

/// Locks the B3 framework-localization wiring on the root MaterialApp: the
/// three Global delegates (Material + Widgets + Cupertino), zh-first
/// supportedLocales, and the zh-fallback resolution — unknown system locales
/// land on zh (the app's default UI language), never on the framework's en.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<MaterialApp> pumpApp(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ZGoApp());
    await tester.pumpAndSettle();
    return tester.widget<MaterialApp>(find.byType(MaterialApp));
  }

  testWidgets('MaterialApp carries the three Global delegates',
      (WidgetTester tester) async {
    final app = await pumpApp(tester);
    expect(app.localizationsDelegates, isNotNull);
    expect(
      app.localizationsDelegates!,
      containsAll(<LocalizationsDelegate<dynamic>>[
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ]),
    );
  });

  testWidgets('supportedLocales puts zh first with en alongside',
      (WidgetTester tester) async {
    final app = await pumpApp(tester);
    expect(app.supportedLocales.first, const Locale('zh'));
    expect(app.supportedLocales, contains(const Locale('en')));
  });

  testWidgets('locale resolution: zh*/en match, unknown falls back to zh',
      (WidgetTester tester) async {
    final app = await pumpApp(tester);
    final resolve = app.localeResolutionCallback!;
    final supported = app.supportedLocales;
    expect(resolve(const Locale('zh', 'CN'), supported), const Locale('zh'));
    expect(resolve(const Locale('zh', 'TW'), supported), const Locale('zh'));
    expect(resolve(const Locale('en', 'US'), supported), const Locale('en'));
    expect(resolve(const Locale('fr', 'FR'), supported), const Locale('zh'));
    expect(resolve(null, supported), const Locale('zh'));
  });

  testWidgets('zh system locale drives framework Localizations to zh',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    // Localizations resolves from platformDispatcher.locales (the list), so
    // the localesTestValue is the knob that matters here.
    tester.platformDispatcher.localesTestValue = const [Locale('zh', 'CN')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await tester.pumpWidget(const ZGoApp());
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(DevicesPage));
    expect(Localizations.localeOf(context), const Locale('zh'));
  });

  // The framework layer follows the app's UiSettings locale: with empty
  // persisted settings the app UI is Chinese (tr() default zh-CN), so an
  // English system must still get Chinese paste/copy menus — the two layers
  // must never split languages.
  testWidgets('en system + zh app settings keeps framework layer zh',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.platformDispatcher.localesTestValue = const [Locale('en', 'US')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await tester.pumpWidget(const ZGoApp());
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(DevicesPage));
    expect(Localizations.localeOf(context), const Locale('zh'));
  });
}
