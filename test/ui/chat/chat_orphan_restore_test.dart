import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/i18n/lexicon.dart';
import 'package:zgo/state/device_session.dart';
import 'package:zgo/ui/chat/chat_page.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../../helpers/chat_role_fakes.dart';

/// Cross-workspace orphan restore — page layer (task 11-08).
///
/// Drives ChatPage under a real [RouteObserver] (the composition-root
/// wiring) so `didPopNext` fires exactly as it does in production: page A is
/// pushed, page B is pushed over it, B pops back to A. The gateway fake
/// marks A's handle revoked the way the host does on a workspace switch.

/// Locale-true copy of a lexicon key (same helper shape as chat_page_test).
String chatLabel(String key) => trByKeyP('zh-CN', key, const []);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> setPhoneViewport(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
  }

  /// Finite pumps: the chat page's progress spinners animate forever, so
  /// `pumpAndSettle` times out (same discipline as chat_page_test).
  Future<void> settleFrames(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Pumps page A (session s1) on the home route, then pushes page B over it
  /// and pops B — the A→B→A shape the orphan re-entry produces.
  Future<FakeChatGateway> pumpAndPopBack(
    WidgetTester tester,
    FakeChatGateway gateway, {
    RouteObserver<PageRoute<dynamic>>? observer,
  }) async {
    await setPhoneViewport(tester);
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        navigatorObservers: [if (observer != null) observer],
        theme: buildDarkTheme(),
        darkTheme: buildDarkTheme(),
        builder: (context, child) => ChatRouteObserverScope(
          observer: observer ?? RouteObserver<PageRoute<dynamic>>(),
          child: UiSettingsProvider(
            settings: UiSettings()..locale = 'zh-CN',
            child: child!,
          ),
        ),
        home: ChatPage(host: gateway, sessionId: 's1', title: 'A'),
      ),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi', 'state': 'done'},
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // B: a plain route over A (no chat host needed — the page never renders
    // its state while covered).
    navKey.currentState!.push(
      zRoute((_) => const Scaffold(body: Text('B'))),
    );
    await settleFrames(tester);
    return gateway;
  }

  Finder sendButtonFinder() => find
      .ancestor(
        of: find.byIcon(Icons.arrow_upward),
        matching: find.byType(InkWell),
      )
      .first;

  testWidgets('didPopNext on a revoked handle resumes and clears the banner',
      (tester) async {
    final observer = RouteObserver<PageRoute<dynamic>>();
    final gateway = FakeChatGateway();
    await pumpAndPopBack(tester, gateway, observer: observer);

    // The workspace switch happened while A was covered.
    gateway.revoke('s1');
    await tester.pump();

    // Pop back to A.
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await settleFrames(tester);

    expect(gateway.resumedSessions, ['s1'],
        reason: 'didPopNext detected the orphan and asked the host to resume');
    expect(find.text(chatLabel('chat.banner.restoring')), findsNothing,
        reason: 'a completed resume removes the light banner');
  });

  testWidgets('the light banner shows for the resume window and blocks sends',
      (tester) async {
    final observer = RouteObserver<PageRoute<dynamic>>();
    final gateway = FakeChatGateway();
    // Park the resume so the window stays observable.
    final gate = Completer<void>();
    gateway.resumeSessionGate = gate;
    await pumpAndPopBack(tester, gateway, observer: observer);
    gateway.revoke('s1');
    await tester.pump();

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text(chatLabel('chat.banner.restoring')), findsOneWidget);

    // A send tap inside the window emits ZERO RPC (AC2: no queueing).
    await tester.enterText(find.byType(TextField).first, 'hello');
    await tester.pump();
    await tester.tap(sendButtonFinder());
    await tester.pump();
    expect(gateway.calls.where((c) => c.$1 == 'sendTextOrQueue'), isEmpty);
    expect(
      gateway.calls.where((c) => c.$1 == 'sendGoalCommand'),
      isEmpty,
    );

    gate.complete();
    await settleFrames(tester);
    expect(find.text(chatLabel('chat.banner.restoring')), findsNothing);
  });

  testWidgets('a classified resume failure renders its copy with retry, no '
      'raw English, no missing banner', (tester) async {
    final observer = RouteObserver<PageRoute<dynamic>>();
    final gateway = FakeChatGateway();
    gateway.resumeSessionResults.add(
      () => Future<ChatHandle>.error(
        const SessionResumeException(
          SessionResumeFailure.foreignWorkspace,
          cause: 'window gate',
        ),
      ),
    );
    await pumpAndPopBack(tester, gateway, observer: observer);
    gateway.revoke('s1');
    await tester.pump();

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await settleFrames(tester);

    expect(
      find.text(chatLabel('chat.resume.failed.foreignWorkspace')),
      findsOneWidget,
      reason: 'the failure lands as classified copy',
    );
    expect(find.textContaining('window gate'), findsNothing,
        reason: 'never the raw desktop text');
    expect(find.text(chatLabel('chat.banner.sessionMissing')), findsNothing,
        reason: 'a foreign-workspace scope problem is not a dead session');
    expect(find.text(chatLabel('tasks.retry')), findsOneWidget);
  });

  testWidgets('a non-revoked handle never resumes (normal page return)',
      (tester) async {
    final observer = RouteObserver<PageRoute<dynamic>>();
    final gateway = FakeChatGateway();
    await pumpAndPopBack(tester, gateway, observer: observer);

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await settleFrames(tester);

    expect(gateway.resumedSessions, isEmpty);
  });

  testWidgets('resuming the same id twice shares one host call (in-flight '
      'guard)', (tester) async {
    final observer = RouteObserver<PageRoute<dynamic>>();
    final gateway = FakeChatGateway();
    final gate = Completer<void>();
    gateway.resumeSessionGate = gate;
    await pumpAndPopBack(tester, gateway, observer: observer);
    gateway.revoke('s1');
    await tester.pump();

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump();
    // A second host notify while the resume is in flight must not start a
    // second chain.
    gateway.notifyListeners();
    await tester.pump();
    expect(gateway.resumedSessions, ['s1']);

    gate.complete();
    await settleFrames(tester);
    expect(gateway.resumedSessions, ['s1']);
  });

  testWidgets('AC3 terminal shape: a rerouted subscribe lands ready with no '
      'error banner and no missing banner', (tester) async {
    final observer = RouteObserver<PageRoute<dynamic>>();
    final gateway = FakeChatGateway();
    await pumpAndPopBack(tester, gateway, observer: observer);
    gateway.revoke('s1');
    await tester.pump();

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await settleFrames(tester);

    // The host answered a fresh handle (reroute success). Page state:
    // ready rows, no red subscribe banner, no missing banner.
    gateway.resumeState.applyFrame({
      'toSeq': 1,
      'payload': {
        'kind': 'snapshot',
        'snapshot': {
          'sessionId': 's1',
          'logEpoch': 'e1',
          'revision': 1,
          'rows': {'window': const [], 'totalCount': 0},
        },
      },
    }, onGap: () {});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text(chatLabel('chat.banner.sessionMissing')), findsNothing);
    expect(
      find.textContaining(chatLabel('chat.subscribe.failed').split(':').first),
      findsNothing,
      reason: 'no unclassified subscribe failure banner',
    );
    expect(find.text(chatLabel('chat.banner.restoring')), findsNothing);
  });

  testWidgets('AC5 retry on a connection-level failure goes through reconnect '
      'and re-runs the resume', (tester) async {
    final observer = RouteObserver<PageRoute<dynamic>>();
    final gateway = FakeChatGateway();
    gateway.resumeSessionResults.add(
      () => Future<ChatHandle>.error(
        const SessionResumeException(SessionResumeFailure.subscribe),
      ),
    );
    await pumpAndPopBack(tester, gateway, observer: observer);
    gateway.revoke('s1');
    await tester.pump();

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await settleFrames(tester);
    expect(
      find.text(chatLabel('chat.resume.failed.subscribe')),
      findsOneWidget,
    );

    // Connection-level failure: the link is down, so retry must reuse the
    // documented manual recovery (only way out of kicked too).
    gateway.status = DeviceStatus.error;
    await tester.tap(find.text(chatLabel('tasks.retry')));
    await settleFrames(tester);

    expect(
      gateway.calls.where((c) => c.$1 == 'reconnect'),
      isNotEmpty,
      reason: 'AC5: a dead link reconnects before re-running the resume',
    );
    expect(gateway.resumedSessions, ['s1', 's1'],
        reason: 'the retry re-runs the resume entry');
    expect(
      find.text(chatLabel('chat.resume.failed.subscribe')),
      findsNothing,
      reason: 'the successful retry clears the classified banner',
    );
  });
}
