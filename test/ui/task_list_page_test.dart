import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/state/device_session.dart';
import 'package:zgo/state/device_store.dart';
import 'package:zgo/state/task_directory.dart';
import 'package:zgo/ui/chat/chat_page.dart';
import 'package:zgo/ui/task_list_page.dart';
import 'package:zgo/ui/task_search_page.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';
import 'package:zgo/ui/widgets/swipe_actions.dart';

import '../helpers/fake_device_session.dart';

export '../helpers/fake_device_session.dart' show FakeDeviceSession;

/// Counts refreshTaskOverview pulls: the cadence driver is the thing under
/// test, and the base fake never connects, so the real method would no-op
/// invisibly.
class _CountingSession extends FakeDeviceSession {
  _CountingSession({
    required super.deviceId,
    required super.params,
    super.workspaces,
  });

  int overviewRefreshes = 0;

  @override
  Future<void> refreshTaskOverview() async {
    overviewRefreshes += 1;
  }
}

Future<(DeviceStore, Device)> setupDevice() async {
  SharedPreferences.setMockInitialValues({});
  final store = DeviceStore();
  await store.load();
  await store.addUrl(
      'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1&name=songsong&app_version=3.8.1');
  return (store, store.devices.single);
}

/// Reload whose RPC round-trip the test controls — the replace-window
/// (pointer-dead list) test holds the gate open mid-reload.
class _GatedReloadSession extends FakeDeviceSession {
  _GatedReloadSession({
    required super.deviceId,
    required super.params,
    super.entries,
    super.workspaces,
  });

  final Completer<void> gate = Completer<void>();

  @override
  Future<void> reloadTasks() => gate.future;
}

Widget wrap(Widget child) => MaterialApp(
      theme: buildDarkTheme(),
      darkTheme: buildDarkTheme(),
      builder: (context, child) =>
          UiSettingsProvider(settings: UiSettings(), child: child!),
      home: child,
    );

/// Logical 390×844 phone viewport (below the 768 dual-pane breakpoint).
void usePhone(WidgetTester tester) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.reset);
}

/// Logical 1280×900 desktop viewport (dual-pane layout).
void useDesktop(WidgetTester tester) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1280, 900);
  addTearDown(tester.view.reset);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders workspace card with tasks and phase pills',
      (tester) async {
    usePhone(tester);
    final (store, device) = await setupDevice();
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
      entries: [
        {
          'sessionId': 's1',
          'title': '修复登录',
          'phase': 'running',
          'lastActivityAt': DateTime.now().millisecondsSinceEpoch,
        },
        {
          'sessionId': 's2',
          'title': '写周报',
          'phase': 'completedSuccess',
          'lastActivityAt': DateTime.now().millisecondsSinceEpoch,
        },
      ],
      workspaces: [
        {'workspacePath': '/repo/app', 'workspaceIdentity': 'app-id'},
      ],
    );
    await tester.pumpWidget(wrap(TaskListPage(
      store: store,
      hub: DeviceSessionHub(nativeListEnabled: () => false),
      device: device,
      sessionOverride: session,
    )));
    // finite pumps: the running pill's spinner never settles
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('当前设备上的工作区和任务'), findsOneWidget);
    expect(find.text('app'), findsWidgets); // workspace title from path
    expect(find.text('本地'), findsOneWidget);
    // R6: the header's second line merges 路径 · 时间 into one caption.
    expect(find.textContaining('/repo/app'), findsOneWidget);
    expect(find.text('修复登录'), findsOneWidget);
    expect(find.text('运行中'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
    expect(find.textContaining('1 个工作区 · 2 个任务'), findsOneWidget);
  });

  testWidgets('tapping a task pushes the native ChatPage (no suspend)',
      (tester) async {
    usePhone(tester);
    final (store, device) = await setupDevice();
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
      entries: [
        {
          'sessionId': 's1',
          'title': '修复登录',
          'phase': 'running',
          'lastActivityAt': 1,
        },
      ],
      workspaces: [
        {'workspacePath': '/repo/app'},
      ],
    );
    final hub = DeviceSessionHub(nativeListEnabled: () => true);
    await tester.pumpWidget(wrap(TaskListPage(
      store: store,
      hub: hub,
      device: device,
      sessionOverride: session,
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('修复登录'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(ChatPage), findsOneWidget);
    expect(find.text('任务会话'), findsOneWidget);
    expect(find.text('修复登录'), findsOneWidget); // chat app-bar title
  });

  testWidgets('＋ starts a draft ChatPage', (tester) async {
    usePhone(tester);
    final (store, device) = await setupDevice();
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
      entries: const [],
      workspaces: [
        {'workspacePath': '/repo/app'},
      ],
    );
    await tester.pumpWidget(wrap(TaskListPage(
      store: store,
      hub: DeviceSessionHub(nativeListEnabled: () => false),
      device: device,
      sessionOverride: session,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('新建任务'));
    await tester.pumpAndSettle();

    expect(find.byType(ChatPage), findsOneWidget);
    expect(find.text('新建任务'), findsWidgets); // title + tooltip
    expect(find.text('输入消息开始新任务'), findsOneWidget); // draft hint
  });

  testWidgets('empty workspace shows the empty hint', (tester) async {
    usePhone(tester);
    final (store, device) = await setupDevice();
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
      entries: const [],
      workspaces: [
        {'workspacePath': '/repo/app'},
      ],
    );
    await tester.pumpWidget(wrap(TaskListPage(
      store: store,
      hub: DeviceSessionHub(nativeListEnabled: () => false),
      device: device,
      sessionOverride: session,
    )));
    await tester.pumpAndSettle();
    expect(find.text('暂无任务'), findsOneWidget);
  });

  testWidgets('online connection banner is always visible', (tester) async {
    usePhone(tester);
    final (store, device) = await setupDevice();
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
      entries: const [],
      workspaces: [
        {'workspacePath': '/repo/app'},
      ],
    );
    await tester.pumpWidget(wrap(TaskListPage(
      store: store,
      hub: DeviceSessionHub(nativeListEnabled: () => false),
      device: device,
      sessionOverride: session,
    )));
    await tester.pumpAndSettle();
    expect(find.text('ZCode 远程控制'), findsOneWidget);
    expect(find.text('已连接到当前桌面窗口'), findsOneWidget);
    expect(find.textContaining('本次连接可以查看当前设备上已打开的项目'), findsOneWidget);
  });

  testWidgets('long-press a task row opens the action sheet', (tester) async {
    usePhone(tester);
    final (store, device) = await setupDevice();
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
      entries: [
        {
          'sessionId': 's1',
          'title': '修复登录',
          'phase': 'running',
          'lastActivityAt': DateTime.now().millisecondsSinceEpoch,
        },
      ],
      workspaces: [
        {'workspacePath': '/repo/app'},
      ],
    );
    await tester.pumpWidget(wrap(TaskListPage(
      store: store,
      hub: DeviceSessionHub(nativeListEnabled: () => false),
      device: device,
      sessionOverride: session,
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.longPress(find.text('修复登录'));
    // finite pumps: the running pill's spinner never settles
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('停止'), findsOneWidget);
    expect(find.text('暂停'), findsOneWidget);
    expect(find.text('恢复'), findsOneWidget);
  });

  testWidgets('the latest running task row gets the official highlight',
      (tester) async {
    usePhone(tester);
    final (store, device) = await setupDevice();
    final now = DateTime.now().millisecondsSinceEpoch;
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
      entries: [
        {
          'sessionId': 's1',
          'title': '旧任务',
          'phase': 'completedSuccess',
          'lastActivityAt': now - 100000,
        },
        {
          'sessionId': 's2',
          'title': '正在跑',
          'phase': 'running',
          'lastActivityAt': now,
        },
      ],
      workspaces: [
        {'workspacePath': '/repo/app'},
      ],
    );
    await tester.pumpWidget(wrap(TaskListPage(
      store: store,
      hub: DeviceSessionHub(nativeListEnabled: () => false),
      device: device,
      sessionOverride: session,
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final row = tester.widget<InkWell>(find.ancestor(
      of: find.text('正在跑'),
      matching: find.byType(InkWell),
    ));
    final material = tester.widget<Material>(find.ancestor(
      of: find.text('正在跑'),
      matching: find.byType(Material),
    ).first);
    expect(material.color, Colors.white.withValues(alpha: 0.1));
    expect(row.onLongPress, isNotNull);

    final oldRow = tester.widget<Material>(find.ancestor(
      of: find.text('旧任务'),
      matching: find.byType(Material),
    ).first);
    expect(oldRow.color, Colors.transparent);
  });

  testWidgets('dual-pane at ≥768: IDE sidebar + divider, tap opens in pane',
      (tester) async {
    useDesktop(tester);
    final (store, device) = await setupDevice();
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
      entries: [
        {
          'sessionId': 's1',
          'title': '修复登录',
          'phase': 'completedSuccess',
          'lastActivityAt': DateTime.now().millisecondsSinceEpoch,
        },
      ],
      workspaces: [
        {'workspacePath': '/repo/app'},
      ],
    );
    await tester.pumpWidget(wrap(TaskListPage(
      store: store,
      hub: DeviceSessionHub(nativeListEnabled: () => false),
      device: device,
      sessionOverride: session,
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // IDE sidebar chrome — not the mobile card list.
    expect(find.text('新建任务'), findsWidgets);
    expect(find.text('搜索'), findsOneWidget);
    expect(find.text('项目'), findsOneWidget);
    expect(find.text('选择左侧任务查看会话'), findsOneWidget);
    expect(find.text('当前设备上的工作区和任务'), findsNothing);

    await tester.tap(find.text('修复登录'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(ChatPage), findsOneWidget);
    expect(find.text('任务会话'), findsOneWidget);
    final chatPage = tester.widget<ChatPage>(find.byType(ChatPage));
    expect(chatPage.embedded, isTrue);
    // Sidebar still visible side by side.
    expect(find.text('项目'), findsOneWidget);
  });

  testWidgets('desktop sidebar workspace rows carry the group palette dot '
      '(C2 parity)', (tester) async {
    useDesktop(tester);
    final (store, device) = await setupDevice();
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
      entries: [
        {
          'sessionId': 's1',
          'title': '修复登录',
          'phase': 'completedSuccess',
          'lastActivityAt': DateTime.now().millisecondsSinceEpoch,
        },
        {
          'sessionId': 's2',
          'title': '另一个任务',
          'phase': 'completedSuccess',
          'lastActivityAt': DateTime.now().millisecondsSinceEpoch,
        },
      ],
      workspaces: [
        {'workspacePath': '/repo/app'},
      ],
      channelHandler: (c, m, a) async => m == 'listGroupedTaskViewStructure'
          ? {
              'groups': [
                {
                  'id': 'g1',
                  'title': '重点任务组',
                  'color': 'blue',
                  'createdAt': 5,
                },
              ],
              'members': [
                {
                  'groupId': 'g1',
                  'taskId': 's1',
                  'workspaceKey': null,
                  'sortOrder': null,
                  'addedAt': 3,
                },
              ],
              'topLevelOrders': <dynamic>[],
            }
          : null,
    );
    await tester.pumpWidget(wrap(TaskListPage(
      store: store,
      hub: DeviceSessionHub(nativeListEnabled: () => false),
      device: device,
      sessionOverride: session,
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // The grouped task's sidebar row carries the group's palette dot; the
    // ungrouped row stays plain. Same palette mapping as the mobile card.
    Finder dotIn(String title) => find.descendant(
          of: find.ancestor(of: find.text(title), matching: find.byType(Row)).first,
          matching: find.byWidgetPredicate(
            (w) =>
                w is Container &&
                w.decoration is BoxDecoration &&
                (w.decoration! as BoxDecoration).shape == BoxShape.circle,
          ),
        );

    final dot = tester.widget<Container>(dotIn('修复登录').first);
    final deco = dot.decoration! as BoxDecoration;
    expect(deco.color, ZColors.sky500);
    expect(deco.shape, BoxShape.circle);
    expect(dotIn('另一个任务'), findsNothing);
  });

  testWidgets('reload window: the list is pointer-dead until the reload RPC '
      'returns (D1)', (tester) async {
    usePhone(tester);
    final (store, device) = await setupDevice();
    final session = _GatedReloadSession(
      deviceId: device.id,
      params: device.params!,
      entries: [
        {
          'sessionId': 's1',
          'title': '修复登录',
          'phase': 'completedSuccess',
          'lastActivityAt': DateTime.now().millisecondsSinceEpoch,
        },
      ],
      workspaces: [
        {'workspacePath': '/repo/app'},
      ],
    );
    await tester.pumpWidget(wrap(TaskListPage(
      store: store,
      hub: DeviceSessionHub(nativeListEnabled: () => false),
      device: device,
      sessionOverride: session,
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    IgnorePointer listGate() => tester.widget<IgnorePointer>(
        find.ancestor(
            of: find.byType(RefreshIndicator), matching: find.byType(IgnorePointer)).first);
    expect(listGate().ignoring, isFalse);

    // Refresh button → the reload RPC hangs on the gate: the window is
    // open and the list ignores pointers.
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    expect(listGate().ignoring, isTrue);

    // A row tap inside the window must not open the chat.
    await tester.tap(find.text('修复登录'), warnIfMissed: false);
    await tester.pump();
    expect(find.byType(ChatPage), findsNothing);

    // RPC returns → the gate lifts and the same row opens the chat.
    session.gate.complete();
    await tester.pumpAndSettle();
    expect(listGate().ignoring, isFalse);
    await tester.tap(find.text('修复登录'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(ChatPage), findsOneWidget);
  });

  testWidgets(
      'dual-pane landscape consumes cutout insets once (853×384, left 45/top 40)',
      (tester) async {
    // Real-device landscape surface (25019PNF3C @600dpi): MIUI top status
    // strip ~40 + punch-hole left inset ~45. Regression lock for the
    // dual-pane SafeArea: sidebar header clears the status strip, the tree
    // is not pushed right by the raw inset, and the embedded composer moves
    // with the pane instead of eating the inset a second time.
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(853, 384);
    addTearDown(tester.view.reset);

    Future<void> pumpPane({required bool cutout}) async {
      // Unmount the previous phase first: pumping a same-type root updates
      // the Element in place and the pane would keep the previously opened
      // session (its breadcrumb title duplicates the tree row).
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      tester.view.padding = cutout
          ? const FakeViewPadding(left: 45, top: 40)
          : const FakeViewPadding();
      final (store, device) = await setupDevice();
      final session = FakeDeviceSession(
        deviceId: device.id,
        params: device.params!,
        entries: [
          {
            'sessionId': 's1',
            'title': '修复登录',
            'phase': 'completedSuccess',
            'lastActivityAt': DateTime.now().millisecondsSinceEpoch,
          },
        ],
        workspaces: [
          {'workspacePath': '/repo/app'},
        ],
      );
      await tester.pumpWidget(wrap(TaskListPage(
        store: store,
        hub: DeviceSessionHub(nativeListEnabled: () => false),
        device: device,
        sessionOverride: session,
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    Future<void> openSession() async {
      await tester.tap(find.text('修复登录'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 100));
    }

    // Cutout surface: the sidebar header starts below the status strip.
    await pumpPane(cutout: true);
    expect(
      tester.getRect(find.byIcon(Icons.arrow_back)).top,
      greaterThanOrEqualTo(40),
    );
    final treeInset = tester.getTopLeft(find.text('app')).dx;
    final navInset = tester.getTopLeft(find.text('搜索')).dx;

    await openSession();
    final fieldInset = tester.getTopLeft(find.byType(TextField).first).dx;
    // C6 landscape compact header: the caption is gone on this surface;
    // anchor on the pane app-bar title instead (scoped to AppBar — the same
    // session title also exists as the sidebar tree row).
    Finder paneTitle() => find.descendant(
      of: find.byType(AppBar),
      matching: find.text('修复登录'),
    );
    final titleInset = tester.getTopLeft(paneTitle()).dx;

    // Control surface: same size, zero insets.
    await pumpPane(cutout: false);
    final treeControl = tester.getTopLeft(find.text('app')).dx;
    final navControl = tester.getTopLeft(find.text('搜索')).dx;
    await openSession();
    final fieldControl = tester.getTopLeft(find.byType(TextField).first).dx;
    final titleControl = tester.getTopLeft(paneTitle()).dx;

    // Tree-vs-nav offset back to the inset-free geometry: the tree must not
    // be pushed right by the raw horizontal inset.
    expect(treeInset - navInset, closeTo(treeControl - navControl, 2));
    // Composer offset vs the pane (title) identical on both surfaces, and
    // its absolute shift equals the pane's: the inset is consumed once for
    // the whole pane, never by the composer alone.
    expect(fieldInset - titleInset, closeTo(fieldControl - titleControl, 2));
    expect(fieldInset - fieldControl, closeTo(titleInset - titleControl, 2));
  });

  testWidgets(
      'dual-pane immersive cutout: color blocks reach the screen edge '
      '(853×384, §7.1)', (tester) async {
    // Same real-device landscape surface as above, but locking the
    // immersive form: SafeArea lives inside each column, so the sidebar
    // color block and the divider extend behind the cutout / status strip
    // (no scaffold-background color seam) while each column consumes only
    // its own screen-edge inset (left/right explicitly interleaved false).
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(853, 384);
    addTearDown(tester.view.reset);

    // Unique by construction: the only darkSidebar ColoredBox, and the
    // rounded chat card measured as the DecoratedBox inside the only
    // fromLTRB(0, 8, 8, 8) margin (getRect on the Padding itself would
    // include its own padding — the card's visual edge is the child).
    Finder sidebarBlock() => find.byWidgetPredicate(
        (w) => w is ColoredBox && w.color == ZColors.darkSidebar);
    Finder card() => find
        .descendant(
          of: find.byWidgetPredicate((w) =>
              w is Padding &&
              w.padding == const EdgeInsets.fromLTRB(0, 8, 8, 8)),
          matching: find.byType(DecoratedBox),
        )
        .first;

    Future<void> pumpPane(FakeViewPadding padding) async {
      // Unmount the previous phase first (same reason as above: in-place
      // root updates would keep the previous pane state around).
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      tester.view.padding = padding;
      final (store, device) = await setupDevice();
      final session = FakeDeviceSession(
        deviceId: device.id,
        params: device.params!,
        workspaces: [
          {'workspacePath': '/repo/app'},
        ],
      );
      await tester.pumpWidget(wrap(TaskListPage(
        store: store,
        hub: DeviceSessionHub(nativeListEnabled: () => false),
        device: device,
        sessionOverride: session,
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
    }

    // Control: zero insets — card hugs the right edge (8px margin), block
    // at x=0.
    await pumpPane(const FakeViewPadding());
    expect(tester.getRect(sidebarBlock()).left, 0);
    final controlCard = tester.getRect(card());
    expect(controlCard.right, 853 - 8);

    // Measured device form (left 45 / top 40): the sidebar block extends to
    // the screen edge behind the punch hole, the header clears the status
    // strip, and the card still hugs the right edge — a zero right inset
    // must not be inflated by the sidebar column's SafeArea.
    await pumpPane(const FakeViewPadding(left: 45, top: 40));
    expect(tester.getRect(sidebarBlock()).left, 0);
    expect(
      tester.getRect(find.byIcon(Icons.arrow_back)).top,
      greaterThanOrEqualTo(40),
    );
    expect(tester.getRect(card()).right, 853 - 8);

    // Flipped form (right 45): the right pane consumes the right inset on
    // its own — card pulled in by exactly 45 — while its left edge (and the
    // sidebar block) stay untouched by the left column.
    await pumpPane(const FakeViewPadding(right: 45, top: 40));
    expect(tester.getRect(sidebarBlock()).left, 0);
    final flippedCard = tester.getRect(card());
    expect(flippedCard.right, 853 - 45 - 8);
    expect(flippedCard.left, controlCard.left);
  });

  testWidgets('single column below 768: official mobile header, no sidebar',
      (tester) async {
    usePhone(tester);
    final (store, device) = await setupDevice();
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
      entries: const [],
      workspaces: [
        {'workspacePath': '/repo/app'},
      ],
    );
    await tester.pumpWidget(wrap(TaskListPage(
      store: store,
      hub: DeviceSessionHub(nativeListEnabled: () => false),
      device: device,
      sessionOverride: session,
    )));
    await tester.pumpAndSettle();

    expect(find.text('ZCode 远程控制'), findsOneWidget);
    expect(find.text('已连接到当前桌面窗口'), findsOneWidget);
    expect(find.text('当前设备上的工作区和任务'), findsOneWidget);
    expect(find.text('项目'), findsNothing);
    expect(find.text('选择左侧任务查看会话'), findsNothing);
  });

  testWidgets('desktop search nav opens the unified search page (actions '
      'tab) and picks a slash', (tester) async {
    useDesktop(tester);
    final (store, device) = await setupDevice();
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
      entries: const [],
      workspaces: [
        {'workspacePath': '/repo/app'},
      ],
    );
    await tester.pumpWidget(wrap(TaskListPage(
      store: store,
      hub: DeviceSessionHub(nativeListEnabled: () => false),
      device: device,
      sessionOverride: session,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();

    // D6: the command sheet is retired — the sidebar entry pushes the
    // unified search page, landing on the actions tab.
    expect(find.byType(TaskSearchPage), findsOneWidget);
    expect(find.text('/compact'), findsOneWidget);
    await tester.tap(find.text('/compact'));
    await tester.pumpAndSettle();

    expect(find.byType(ChatPage), findsOneWidget);
    // The action pre-fills a NEW chat with the insert text (`/name `).
    expect(find.textContaining('/compact'), findsWidgets);
  });

  testWidgets('767 stays single column, 768 goes dual-pane', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(767, 844);
    addTearDown(tester.view.reset);
    final (store, device) = await setupDevice();
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
      entries: const [],
      workspaces: [
        {'workspacePath': '/repo/app'},
      ],
    );
    await tester.pumpWidget(wrap(TaskListPage(
      store: store,
      hub: DeviceSessionHub(nativeListEnabled: () => false),
      device: device,
      sessionOverride: session,
    )));
    await tester.pump();
    expect(find.text('项目'), findsNothing);

    tester.view.physicalSize = const Size(768, 844);
    await tester.pump();
    expect(find.text('项目'), findsOneWidget);
  });

  // ---- collapse model (web) ----

  Future<(DeviceStore, Device, FakeDeviceSession)> setupTwoWorkspaces(
      WidgetTester tester) async {
    usePhone(tester);
    final (store, device) = await setupDevice();
    final now = DateTime.now().millisecondsSinceEpoch;
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
      entries: [
        {
          'sessionId': 's1',
          'title': '任务甲',
          'phase': 'completedSuccess',
          'lastActivityAt': now - 1000,
          'createdAt': now - 500000,
        },
        {
          'sessionId': 's2',
          'title': '任务乙',
          'phase': 'completedSuccess',
          'lastActivityAt': now,
          'createdAt': now - 1000,
        },
      ],
      workspaces: [
        {'workspacePath': '/repo/alpha', 'workspaceIdentity': 'alpha'},
        {'workspacePath': '/repo/beta', 'workspaceIdentity': 'beta'},
      ],
      // relay overview row for beta — the merged-source data non-active
      // workspace cards render.
      relayTasks: [
        {
          'taskId': 'rb1',
          'title': '中继任务乙',
          'workspacePath': '/repo/beta',
          'workspaceIdentity': 'beta',
          'displayStatus': 'idle',
          'updatedAt': now,
        },
      ],
    );
    await tester.pumpWidget(wrap(TaskListPage(
      store: store,
      hub: DeviceSessionHub(nativeListEnabled: () => false),
      device: device,
      sessionOverride: session,
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    return (store, device, session);
  }

  Finder cardOf(String title) => find.ancestor(
        of: find.text(title),
        matching: find.byType(Card),
      );

  testWidgets('default: only the active workspace is expanded', (tester) async {
    await setupTwoWorkspaces(tester);
    // alpha (first workspace) is active → expanded with task rows.
    expect(find.text('任务甲'), findsOneWidget);
    expect(find.text('任务乙'), findsOneWidget);
    expect(
      find.descendant(
          of: cardOf('alpha'), matching: find.byIcon(Icons.keyboard_arrow_up)),
      findsOneWidget,
    );
    // beta is collapsed by default (chevron down, no task rows inside).
    expect(
      find.descendant(
          of: cardOf('beta'), matching: find.byIcon(Icons.keyboard_arrow_down)),
      findsOneWidget,
    );
    expect(
      find
          .descendant(of: cardOf('beta'), matching: find.text('任务甲'))
          .evaluate()
          .isEmpty,
      isTrue,
    );
  });

  testWidgets('tapping the expanded active card collapses it (both ways)',
      (tester) async {
    await setupTwoWorkspaces(tester);

    await tester.tap(find.text('alpha'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('任务甲'), findsNothing);
    expect(
      find.descendant(
          of: cardOf('alpha'), matching: find.byIcon(Icons.keyboard_arrow_down)),
      findsOneWidget,
    );

    // …and tapping again re-expands it.
    await tester.tap(find.text('alpha'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('任务甲'), findsOneWidget);
  });

  testWidgets('tapping a collapsed workspace expands it without switching',
      (tester) async {
    // Mobile home: the header tap expands/collapses only —
    // switching workspaces happens when opening a task (bridge-open rides
    // the taskId).
    final (_, _, session) = await setupTwoWorkspaces(tester);

    await tester.tap(find.text('beta'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // beta expanded and shows its relay-sourced row…
    expect(
      find.descendant(of: cardOf('beta'), matching: find.text('中继任务乙')),
      findsOneWidget,
    );
    // …but the active workspace did NOT change.
    expect(session.activeWorkspace?['workspaceIdentity'], 'alpha');
  });

  testWidgets('live-ready active workspace still renders relay-only rows',
      (tester) async {
    // TaskDirectory merge anchor (CONTEXT.md「Task Directory」): relay 打底、
    // live 按 id 胜出 —— live-ready 不得把索引里没有的 relay 任务挤掉卡片。
    // 旧卡片实现是 live-ready 整面替换，曾把这样的行藏掉（C2）。
    usePhone(tester);
    final (store, device) = await setupDevice();
    final now = DateTime.now().millisecondsSinceEpoch;
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
      entries: [
        {
          'sessionId': 's1',
          'title': '任务甲',
          'phase': 'completedSuccess',
          'lastActivityAt': now,
        },
      ],
      workspaces: [
        {'workspacePath': '/repo/alpha', 'workspaceIdentity': 'alpha'},
        {'workspacePath': '/repo/beta', 'workspaceIdentity': 'beta'},
      ],
      // Relay-only row of the ACTIVE workspace: live index (ready, has s1)
      // does not contain ra1 — the card must still render it.
      relayTasks: [
        {
          'taskId': 'ra1',
          'title': '中继任务甲',
          'workspacePath': '/repo/alpha',
          'workspaceIdentity': 'alpha',
          'displayStatus': 'idle',
          'updatedAt': now,
        },
      ],
    );
    await tester.pumpWidget(wrap(TaskListPage(
      store: store,
      hub: DeviceSessionHub(nativeListEnabled: () => false),
      device: device,
      sessionOverride: session,
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.descendant(of: cardOf('alpha'), matching: find.text('任务甲')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: cardOf('alpha'), matching: find.text('中继任务甲')),
      findsOneWidget,
    );
  });

  testWidgets('default ordering sorts merged card rows by recency',
      (tester) async {
    // The directory's source order is the relay overview's with live-only
    // rows appended at the tail — the 默认(更新时间) sort must actively
    // order by lastActivityAt so a live-only row lands mid-list.
    usePhone(tester);
    final (store, device) = await setupDevice();
    final now = DateTime.now().millisecondsSinceEpoch;
    final hour = 3600000;
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
      // Live-only row (no relay counterpart), 13h old — must sort between
      // the fresh and the 2-day-old relay rows, not after them.
      entries: [
        {
          'sessionId': 's1',
          'title': '中位任务',
          'phase': 'completedSuccess',
          'lastActivityAt': now - 13 * hour,
        },
      ],
      workspaces: [
        {'workspacePath': '/repo/alpha', 'workspaceIdentity': 'alpha'},
      ],
      relayTasks: [
        {
          'taskId': 'r1',
          'title': '新中继',
          'workspacePath': '/repo/alpha',
          'workspaceIdentity': 'alpha',
          'displayStatus': 'idle',
          'updatedAt': now,
        },
        {
          'taskId': 'r2',
          'title': '旧中继',
          'workspacePath': '/repo/alpha',
          'workspaceIdentity': 'alpha',
          'displayStatus': 'idle',
          'updatedAt': now - 48 * hour,
        },
      ],
    );
    await tester.pumpWidget(wrap(TaskListPage(
      store: store,
      hub: DeviceSessionHub(nativeListEnabled: () => false),
      device: device,
      sessionOverride: session,
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final order = tester
        .widgetList<Text>(find.byWidgetPredicate((w) =>
            w is Text &&
            const ['新中继', '中位任务', '旧中继'].contains(w.data)))
        .map((t) => t.data)
        .toList();
    expect(order, ['新中继', '中位任务', '旧中继']);
  });

  testWidgets('收起全部 collapses everything, then active re-expands alone',
      (tester) async {
    await setupTwoWorkspaces(tester);

    await tester.tap(find.byTooltip('收起全部工作区'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('任务甲'), findsNothing);
    expect(find.text('任务乙'), findsNothing);
    expect(
      find.descendant(
          of: cardOf('alpha'), matching: find.byIcon(Icons.keyboard_arrow_down)),
      findsOneWidget,
    );

    // Tapping the (collapsed) active workspace expands just that one.
    await tester.tap(find.text('alpha'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('任务甲'), findsOneWidget);
  });

  testWidgets('desktop sidebar folders share the same toggle', (tester) async {
    useDesktop(tester);
    final (store, device) = await setupDevice();
    final now = DateTime.now().millisecondsSinceEpoch;
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
      entries: [
        {
          'sessionId': 's1',
          'title': '侧栏任务',
          'phase': 'completedSuccess',
          'lastActivityAt': now,
        },
      ],
      workspaces: [
        {'workspacePath': '/repo/alpha', 'workspaceIdentity': 'alpha'},
      ],
    );
    await tester.pumpWidget(wrap(TaskListPage(
      store: store,
      hub: DeviceSessionHub(nativeListEnabled: () => false),
      device: device,
      sessionOverride: session,
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('侧栏任务'), findsOneWidget);

    await tester.tap(find.text('alpha'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('侧栏任务'), findsNothing);

    await tester.tap(find.text('alpha'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('侧栏任务'), findsOneWidget);
  });

  testWidgets('整理任务 panel: timeline grouping and created-time sorting',
      (tester) async {
    await setupTwoWorkspaces(tester);

    await tester.tap(find.byTooltip('整理任务'));
    await tester.pumpAndSettle();
    expect(find.text('按工作区'), findsOneWidget);
    expect(find.text('按时间线'), findsOneWidget);
    expect(find.text('创建时间'), findsOneWidget);
    expect(find.text('更新时间'), findsOneWidget);

    await tester.tap(find.text('按时间线'));
    await tester.pumpAndSettle();
    // Timeline buckets appear with the workspace name in each row.
    expect(find.text('今天'), findsOneWidget);
    expect(find.text('alpha · 刚刚'), findsWidgets);

    // Sort by created time: 任务乙 (newer createdAt) now comes first.
    await tester.tap(find.text('创建时间'));
    await tester.pumpAndSettle();
    final order = tester
        .widgetList<Text>(find.byWidgetPredicate((w) =>
            w is Text &&
            (w.data == '任务甲' || w.data == '任务乙')))
        .map((t) => t.data)
        .toList();
    expect(order, ['任务乙', '任务甲']);
  });

  group('providers entry capability gate (3.12.3 model-provider removal)', () {
    Future<(DeviceStore, Device, FakeDeviceSession)> setupGateSession(
      WidgetTester tester, {
      required Future<dynamic> Function(
              String channel, String method, List<Object?> args)
          channelHandler,
    }) async {
      usePhone(tester);
      final (store, device) = await setupDevice();
      final session = FakeDeviceSession(
        deviceId: device.id,
        params: device.params!,
        workspaces: [
          {'workspacePath': '/repo/app'},
        ],
        channelHandler: channelHandler,
      );
      await tester.pumpWidget(wrap(TaskListPage(
        store: store,
        hub: DeviceSessionHub(nativeListEnabled: () => false),
        device: device,
        sessionOverride: session,
      )));
      await tester.pump();
      return (store, device, session);
    }

    Future<void> openOverflowMenu(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
    }

    PopupMenuItem<String> providersItem(WidgetTester tester) =>
        tester.widget<PopupMenuItem<String>>(
          find.widgetWithText(PopupMenuItem<String>, '模型设置'),
        );

    testWidgets('failed probe disables the entry with the placeholder copy',
        (tester) async {
      var getAllCalls = 0;
      final (_, _, session) = await setupGateSession(
        tester,
        channelHandler: (channel, method, args) async {
          if (channel == 'model-provider') {
            getAllCalls += 1;
            throw ChannelRpcError(
                "Channel name '$channel' timed out after 1000ms", null);
          }
          return null;
        },
      );
      // The menu itself fires this fire-and-forget; awaiting it up front
      // makes the disabled verdict deterministic for the first open.
      expect(await session.probeModelProvider(), isFalse);

      await openOverflowMenu(tester);
      expect(providersItem(tester).enabled, isFalse);
      expect(find.text('当前桌面端版本不支持'), findsOneWidget);

      // Session-lifetime cache: a re-probe (second menu open) must not
      // re-issue the channel call.
      expect(await session.probeModelProvider(), isFalse);
      expect(getAllCalls, 1);
    });

    testWidgets('successful probe keeps the entry tappable (old desktops)',
        (tester) async {
      var getAllCalls = 0;
      final (_, _, session) = await setupGateSession(
        tester,
        channelHandler: (channel, method, args) async {
          if (channel == 'model-provider') {
            getAllCalls += 1;
            return <Map<String, dynamic>>[];
          }
          return null;
        },
      );
      expect(await session.probeModelProvider(), isTrue);

      await openOverflowMenu(tester);
      expect(providersItem(tester).enabled, isTrue);
      expect(find.text('当前桌面端版本不支持'), findsNothing);

      // Success is cached for the session lifetime too.
      expect(await session.probeModelProvider(), isTrue);
      expect(getAllCalls, 1);
    });

    testWidgets('non-channel-level failure stays unknown (not cached)',
        (tester) async {
      final (_, _, session) = await setupGateSession(
        tester,
        channelHandler: (channel, method, args) async => throw StateError('boom'),
      );
      // An unrelated error proves nothing about the channel — the probe
      // reports unknown-as-available and must NOT cache it.
      expect(await session.probeModelProvider(), isTrue);
      expect(session.modelProviderAvailable, isNull);
      expect(await session.probeModelProvider(), isTrue);
    });
  });

  group('timeline task groups (3.12.3 read-only)', () {
    Future<FakeDeviceSession> setupTimeline(
      WidgetTester tester, {
      required Future<dynamic> Function(
              String channel, String method, List<Object?> args)
          channelHandler,
    }) async {
      usePhone(tester);
      final (store, device) = await setupDevice();
      final now = DateTime.now().millisecondsSinceEpoch;
      final session = FakeDeviceSession(
        deviceId: device.id,
        params: device.params!,
        entries: [
          {
            'sessionId': 's1',
            'title': '未分组任务',
            'phase': 'completedSuccess',
            'lastActivityAt': now,
          },
          {
            'sessionId': 's2',
            'title': '组内任务',
            'phase': 'completedSuccess',
            'lastActivityAt': now - 10,
          },
        ],
        workspaces: [
          {'workspacePath': '/repo/app', 'workspaceIdentity': 'app-id'},
        ],
        channelHandler: channelHandler,
      );
      await tester.pumpWidget(wrap(TaskListPage(
        store: store,
        hub: DeviceSessionHub(nativeListEnabled: () => false),
        device: device,
        sessionOverride: session,
      )));
      await tester.pump();
      // Switch to the timeline grouping (the only grouped surface).
      await tester.tap(find.byTooltip('整理任务'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('按时间线'));
      await tester.pumpAndSettle();
      return session;
    }

    Object groupedView() => {
      'groups': [
        {'id': 'g1', 'title': '重点任务组', 'color': 'blue', 'createdAt': 5},
      ],
      'members': [
        {
          'groupId': 'g1',
          'taskId': 's2',
          'workspaceKey': 'app-id',
          'sortOrder': null,
          'addedAt': 3,
        },
      ],
      'topLevelOrders': [
        {'type': 'group', 'groupId': 'g1', 'sortOrder': 4},
      ],
    };

    testWidgets('grouped tasks render under a title header, rest stays flat',
        (tester) async {
      await setupTimeline(
        tester,
        channelHandler: (c, m, a) async =>
            m == 'listGroupedTaskViewStructure' ? groupedView() : null,
      );
      expect(find.text('重点任务组'), findsOneWidget);
      expect(find.text('组内任务'), findsOneWidget);
      // The ungrouped task keeps its day bucket — no second header set.
      expect(find.text('今天'), findsOneWidget);
      expect(find.text('未分组任务'), findsOneWidget);
    });

    testWidgets('empty groups keep the flat timeline', (tester) async {
      await setupTimeline(
        tester,
        channelHandler: (c, m, a) async =>
            m == 'listGroupedTaskViewStructure'
                ? {
                    'groups': <dynamic>[],
                    'members': <dynamic>[],
                    'topLevelOrders': <dynamic>[],
                  }
                : null,
      );
      expect(find.text('今天'), findsOneWidget);
      expect(find.text('未分组任务'), findsOneWidget);
      expect(find.text('组内任务'), findsOneWidget);
    });

    testWidgets('a desktop without the method keeps the flat timeline',
        (tester) async {
      await setupTimeline(
        tester,
        channelHandler: (c, m, a) async {
          if (m == 'listGroupedTaskViewStructure') {
            throw ChannelRpcError('Method not found: $m', null);
          }
          return null;
        },
      );
      expect(find.text('今天'), findsOneWidget);
      expect(find.text('未分组任务'), findsOneWidget);
    });
  });

  group('task sheet token usage line (3.12.3)', () {
    Future<FakeDeviceSession> setupSheet(
      WidgetTester tester, {
      required Future<dynamic> Function(
              String channel, String method, List<Object?> args)
          channelHandler,
    }) async {
      usePhone(tester);
      final (store, device) = await setupDevice();
      final session = FakeDeviceSession(
        deviceId: device.id,
        params: device.params!,
        entries: [
          {
            'sessionId': 's1',
            'title': '修复登录',
            'phase': 'completedSuccess',
            'lastActivityAt': DateTime.now().millisecondsSinceEpoch,
          },
        ],
        workspaces: [
          {'workspacePath': '/repo/app', 'workspaceIdentity': 'app-id'},
        ],
        channelHandler: channelHandler,
      );
      await tester.pumpWidget(wrap(TaskListPage(
        store: store,
        hub: DeviceSessionHub(nativeListEnabled: () => false),
        device: device,
        sessionOverride: session,
      )));
      await tester.pump();
      await tester.longPress(find.text('修复登录'));
      await tester.pumpAndSettle();
      return session;
    }

    testWidgets('shows compacted total tokens and request count',
        (tester) async {
      final session = await setupSheet(
        tester,
        channelHandler: (c, m, a) async =>
            m == 'getTaskTokenUsage'
                ? {'totalTokens': 123456, 'modelRequestCount': 12}
                : null,
      );
      expect(find.textContaining('12.3万'), findsOneWidget);
      expect(find.textContaining('12 次请求'), findsOneWidget);
      // One-shot: exactly one usage RPC fired for the sheet.
      expect(
        session.channelCalls.where((c) => c.$2 == 'getTaskTokenUsage'),
        hasLength(1),
      );
    });

    testWidgets('hides the row when the desktop rejects the call',
        (tester) async {
      await setupSheet(
        tester,
        channelHandler: (c, m, a) async {
          if (m == 'getTaskTokenUsage') {
            throw ChannelRpcError('Method not found: $m', null);
          }
          return null;
        },
      );
      expect(find.textContaining('Token 用量'), findsNothing);
      // The sheet itself still opens.
      expect(find.byType(BottomSheet), findsOneWidget);
    });

    testWidgets('a reload re-issues the usage query (cache invalidation)',
        (tester) async {
      var usage = <String, dynamic>{
        'totalTokens': 123456,
        'modelRequestCount': 12,
      };
      final session = await setupSheet(
        tester,
        channelHandler: (c, m, a) async =>
            m == 'getTaskTokenUsage' ? usage : null,
      );
      expect(find.textContaining('12.3万'), findsOneWidget);

      // Close the sheet, grow the desktop-side number, refresh the list:
      // the reload must drop the cached future, not pin the first answer.
      await tester.tapAt(const Offset(20, 30));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      usage = {'totalTokens': 234567, 'modelRequestCount': 24};
      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pumpAndSettle();

      // Re-open: a fresh RPC fires and the new value lands on the sheet.
      await tester.longPress(find.text('修复登录'));
      await tester.pumpAndSettle();
      expect(find.textContaining('23.5万'), findsOneWidget);
      expect(find.textContaining('24 次请求'), findsOneWidget);
      expect(
        session.channelCalls.where((c) => c.$2 == 'getTaskTokenUsage'),
        hasLength(2),
      );
    });
  });

  testWidgets('archive view follows the relay archived bit only (R1)',
      (tester) async {
    usePhone(tester);
    final (store, device) = await setupDevice();
    final now = DateTime.now().millisecondsSinceEpoch;
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
      entries: [
        {
          // Live frame carrying the legacy archived field WITHOUT a relay
          // counterpart — must stay visible (relay is the sole authority).
          'sessionId': 'live1',
          'title': 'live归档假象',
          'phase': 'completedSuccess',
          'lastActivityAt': now,
          'archived': true,
        },
      ],
      workspaces: [
        {'workspacePath': '/repo/app', 'workspaceIdentity': 'app-id'},
      ],
      relayTasks: [
        {
          'taskId': 'r1',
          'title': '真归档任务',
          'workspacePath': '/repo/app',
          'workspaceIdentity': 'app-id',
          'displayStatus': 'idle',
          'updatedAt': now - 5,
          'archived': true,
        },
      ],
    );
    await tester.pumpWidget(wrap(TaskListPage(
      store: store,
      hub: DeviceSessionHub(nativeListEnabled: () => false),
      device: device,
      sessionOverride: session,
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('live归档假象'), findsOneWidget);
    expect(find.text('真归档任务'), findsNothing);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看归档'));
    await tester.pumpAndSettle();
    expect(find.text('真归档任务'), findsOneWidget);
    expect(find.text('live归档假象'), findsNothing);
  });

  group("task open scope follows the task's true workspace (09-19)", () {
    Future<FakeDeviceSession> setupScopeSession(
      WidgetTester tester, {
      required List<Map<String, dynamic>> workspaces,
      required List<Map<String, dynamic>> relayTasks,
      bool timeline = true,
    }) async {
      usePhone(tester);
      final (store, device) = await setupDevice();
      final session = FakeDeviceSession(
        deviceId: device.id,
        params: device.params!,
        entries: const [],
        workspaces: workspaces,
        relayTasks: relayTasks,
      );
      await tester.pumpWidget(wrap(TaskListPage(
        store: store,
        hub: DeviceSessionHub(nativeListEnabled: () => false),
        device: device,
        sessionOverride: session,
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      if (timeline) {
        await tester.tap(find.byTooltip('整理任务'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('按时间线'));
        await tester.pumpAndSettle();
        // The tidy sheet stays open on selection (existing behavior) —
        // dismiss it via the modal barrier so the rows are tappable.
        await tester.tapAt(const Offset(20, 30));
        await tester.pumpAndSettle();
      }
      return session;
    }

    Future<void> tapTask(WidgetTester tester, String title) async {
      await tester.tap(find.text(title));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('active=A + task of unlisted B: openWorkspace keyed B',
        (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final session = await setupScopeSession(tester, workspaces: [
        {'workspacePath': '/repo/alpha', 'workspaceIdentity': 'alpha'},
      ], relayTasks: [
        {
          'taskId': 'tb1',
          'title': '整理记忆',
          'workspacePath': '/repo/beta',
          'displayStatus': 'idle',
          'updatedAt': now,
        },
      ]);

      await tapTask(tester, '整理记忆');

      expect(session.openWorkspaceCalls, hasLength(1));
      final (ws, taskId) = session.openWorkspaceCalls.single;
      expect(workspaceKeyOf(ws), '/repo/beta');
      expect(taskId, 'tb1');
      expect(find.byType(ChatPage), findsOneWidget);
    });

    testWidgets('pinned card of a foreign workspace no longer rides active',
        (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final session = await setupScopeSession(tester,
          timeline: false,
          workspaces: [
            {'workspacePath': '/repo/alpha', 'workspaceIdentity': 'alpha'},
          ],
          relayTasks: [
            {
              'taskId': 'tp1',
              'title': '置顶跨区',
              'workspacePath': '/repo/beta',
              'pinned': true,
              'displayStatus': 'idle',
              'updatedAt': now,
            },
          ]);
      // The card labels the TRUE workspace (used to show the active one).
      expect(find.textContaining('beta'), findsWidgets);

      await tapTask(tester, '置顶跨区');

      expect(session.openWorkspaceCalls, hasLength(1));
      final (ws, taskId) = session.openWorkspaceCalls.single;
      expect(workspaceKeyOf(ws), '/repo/beta');
      expect(taskId, 'tp1');
      expect(find.byType(ChatPage), findsOneWidget);
    });

    testWidgets('key semantics: task identity survives the fallback map',
        (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final session = await setupScopeSession(tester, workspaces: [
        {'workspacePath': '/repo/alpha', 'workspaceIdentity': 'alpha'},
        // Listed by path only, while the task row carries an identity: the
        // directory key ('beta-id') matches no entry and the fallback map
        // must keep the identity so the bridge opens with the same key.
        {'workspacePath': '/repo/beta'},
      ], relayTasks: [
        {
          'taskId': 'ti1',
          'title': '跨区任务',
          'workspacePath': '/repo/beta',
          'workspaceIdentity': 'beta-id',
          'displayStatus': 'idle',
          'updatedAt': now,
        },
      ]);

      await tapTask(tester, '跨区任务');

      expect(session.openWorkspaceCalls, hasLength(1));
      final (ws, taskId) = session.openWorkspaceCalls.single;
      expect(workspaceKeyOf(ws), 'beta-id');
      expect(ws['workspaceIdentity'], 'beta-id');
      expect(ws['workspacePath'], '/repo/beta');
      expect(taskId, 'ti1');
    });

    testWidgets('key semantics: path-only task against identity-first entry',
        (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final session = await setupScopeSession(tester, workspaces: [
        {'workspacePath': '/repo/alpha', 'workspaceIdentity': 'alpha'},
        {'workspacePath': '/repo/beta', 'workspaceIdentity': 'beta-id'},
      ], relayTasks: [
        {
          'taskId': 'tj1',
          'title': '跨区任务',
          'workspacePath': '/repo/beta',
          'displayStatus': 'idle',
          'updatedAt': now,
        },
      ]);

      await tapTask(tester, '跨区任务');

      expect(session.openWorkspaceCalls, hasLength(1));
      final (ws, taskId) = session.openWorkspaceCalls.single;
      // No identity on the row — the fallback carries the path only and
      // workspaceKeyOf falls back to it (nothing fabricated).
      expect(workspaceKeyOf(ws), '/repo/beta');
      expect(ws.containsKey('workspaceIdentity'), isFalse);
      expect(taskId, 'tj1');
    });

    testWidgets('undeterminable ownership: SnackBar, no ChatPage, no reopen',
        (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final session = await setupScopeSession(tester, workspaces: [
        {'workspacePath': '/repo/alpha', 'workspaceIdentity': 'alpha'},
      ], relayTasks: [
        {
          'taskId': 'tx1',
          'title': '无主任务',
          'displayStatus': 'idle',
          'updatedAt': now,
        },
      ]);

      await tapTask(tester, '无主任务');

      expect(session.openWorkspaceCalls, isEmpty);
      expect(find.byType(ChatPage), findsNothing);
      expect(find.text('无法确定会话归属，未打开该任务'), findsOneWidget);

      // Drain the SnackBar auto-dismiss timer.
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });

    testWidgets('active-workspace card row: straight to chat, no reopen',
        (tester) async {
      usePhone(tester);
      final (store, device) = await setupDevice();
      final session = FakeDeviceSession(
        deviceId: device.id,
        params: device.params!,
        entries: [
          {
            'sessionId': 's1',
            'title': '区内任务',
            'phase': 'completedSuccess',
            'lastActivityAt': DateTime.now().millisecondsSinceEpoch,
          },
        ],
        workspaces: [
          {'workspacePath': '/repo/alpha', 'workspaceIdentity': 'alpha'},
        ],
      );
      await tester.pumpWidget(wrap(TaskListPage(
        store: store,
        hub: DeviceSessionHub(nativeListEnabled: () => false),
        device: device,
        sessionOverride: session,
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('区内任务'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // Identical-map judgment: the active workspace is NOT re-opened.
      expect(session.openWorkspaceCalls, isEmpty);
      expect(find.byType(ChatPage), findsOneWidget);
    });
  });

  group('task overview refresh cadence (Addendum 3)', () {
    /// Cadence page on a counting session; every caller ends its test by
    /// pumping a replacement widget so the periodic timer is disposed
    /// (flutter_test fails on pending timers otherwise).
    Future<_CountingSession> setupCadence(
      WidgetTester tester, {
      Duration interval = const Duration(milliseconds: 100),
    }) async {
      usePhone(tester);
      final (store, device) = await setupDevice();
      final session = _CountingSession(
        deviceId: device.id,
        params: device.params!,
        workspaces: [
          {'workspacePath': '/repo/app'},
        ],
      );
      await tester.pumpWidget(wrap(TaskListPage(
        store: store,
        hub: DeviceSessionHub(nativeListEnabled: () => false),
        device: device,
        sessionOverride: session,
        overviewInterval: interval,
      )));
      await tester.pump();
      return session;
    }

    testWidgets('pulls once on page entry', (tester) async {
      final session = await setupCadence(tester);
      expect(session.overviewRefreshes, 1);
      await tester.pumpWidget(wrap(const SizedBox.shrink()));
    });

    testWidgets('pulls periodically while visible (injected interval)',
        (tester) async {
      final session = await setupCadence(tester);
      await tester.pump(const Duration(milliseconds: 350));
      expect(session.overviewRefreshes, 4); // entry + ticks @100/200/300ms
      await tester.pumpWidget(wrap(const SizedBox.shrink()));
    });

    testWidgets('paused app stops the cadence; resumed pulls at once',
        (tester) async {
      final session = await setupCadence(tester);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(milliseconds: 250));
      expect(session.overviewRefreshes, 1,
          reason: 'paused must stop the periodic ticks');

      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(session.overviewRefreshes, 2,
          reason: 'resume must refresh at once, not wait out a tick');
      await tester.pump(const Duration(milliseconds: 100));
      expect(session.overviewRefreshes, 3, reason: 'the cadence re-arms');
      await tester.pumpWidget(wrap(const SizedBox.shrink()));
    });

    testWidgets('disposing the page cancels the cadence', (tester) async {
      final session = await setupCadence(tester);
      await tester.pumpWidget(wrap(const SizedBox.shrink()));
      final after = session.overviewRefreshes;
      await tester.pump(const Duration(milliseconds: 250));
      expect(session.overviewRefreshes, after);
    });
  });

  testWidgets('tidy panel opens scrollable on landscape without overflow',
      (tester) async {
    // Landscape phone surface (767 wide keeps the single-pane layout under
    // the 768 dual-pane breakpoint; 390 tall is the P0 height budget).
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(767, 390);
    addTearDown(tester.view.reset);
    final (store, device) = await setupDevice();
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
    );
    await tester.pumpWidget(wrap(TaskListPage(
      store: store,
      hub: DeviceSessionHub(nativeListEnabled: () => false),
      device: device,
      sessionOverride: session,
    )));
    await tester.pump();

    await tester.tap(find.byTooltip('整理任务').first);
    await tester.pumpAndSettle();

    // No RenderFlex overflow on the 390px-tall landscape surface, and the
    // sheet body rides the capped scrollable skeleton.
    expect(tester.takeException(), isNull);
    expect(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(SingleChildScrollView),
      ),
      findsOneWidget,
    );
    // The radio rows stay reachable through the scroll.
    await tester.scrollUntilVisible(
      find.text('排序方式'),
      200,
      scrollable: find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(Scrollable),
      ),
    );
  });

  // ---- C1 (10-05): draft-aware task list + delete routing ----
  //
  // A fork draft exists ONLY in the live sessions-index (no registry
  // anchor): task mutations can never resolve it (matches=0, live evidence
  // 12.png) while the V4 deleteSession command can (A-2). The sheet gates
  // the four registry ops on draft rows; the delete confirm routes drafts
  // straight to deleteSession and falls back to it once when a registered
  // row's registry resolve comes back empty.
  group('C1 draft-aware list: sheet gating + delete routing', () {
    // The session goes through hub.installForTesting (not sessionOverride)
    // so session notifications rebuild the page — the tombstone-driven
    // instant row removal is part of what these tests assert.
    Future<(DeviceStore, Device, FakeDeviceSession)> setupC1(
      WidgetTester tester, {
      required List<Map<String, dynamic>> relayTasks,
      Future<dynamic> Function(String channel, String method,
              List<Object?> args)?
          channelHandler,
    }) async {
      usePhone(tester);
      final (store, device) = await setupDevice();
      final now = DateTime.now().millisecondsSinceEpoch;
      final session = FakeDeviceSession(
        deviceId: device.id,
        params: device.params!,
        entries: [
          {
            'sessionId': 'fork1',
            'title': 'Fork 草稿',
            'phase': 'completedSuccess',
            'lastActivityAt': now,
          },
        ],
        workspaces: [
          {'workspacePath': '/repo/app', 'workspaceIdentity': 'app-id'},
        ],
        relayTasks: relayTasks,
        channelHandler: channelHandler,
      );
      final hub = DeviceSessionHub(nativeListEnabled: () => false)
        ..installForTesting(session);
      await tester.pumpWidget(wrap(TaskListPage(
        store: store,
        hub: hub,
        device: device,
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      return (store, device, session);
    }

    // Registered (relay-anchored) twin of the fixture row: same id, so the
    // directory merge anchors it and sessionOnlyIds must NOT contain it.
    Map<String, dynamic> registeredRelayRow() => {
          'taskId': 'fork1',
          'title': 'Fork 草稿',
          'workspacePath': '/repo/app',
          'workspaceIdentity': 'app-id',
          'displayStatus': 'idle',
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
        };

    Finder sheetTile(String label) => find.widgetWithText(ListTile, label);

    /// long-press → sheet → 删除 → confirm dialog → danger button.
    Future<void> deleteViaSheet(WidgetTester tester) async {
      await tester.longPress(find.text('Fork 草稿'));
      await tester.pumpAndSettle();
      await tester.tap(sheetTile('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();
    }

    testWidgets('draft row: the four registry ops are disabled, delete stays',
        (tester) async {
      // No relay row → the live-only row is a draft (sessionOnlyIds).
      final (_, _, session) = await setupC1(tester, relayTasks: const []);
      await tester.longPress(find.text('Fork 草稿'));
      await tester.pumpAndSettle();

      expect(tester.widget<ListTile>(sheetTile('置顶')).enabled, isFalse);
      expect(tester.widget<ListTile>(sheetTile('重命名')).enabled, isFalse);
      expect(tester.widget<ListTile>(sheetTile('归档')).enabled, isFalse);
      expect(
          tester.widget<ListTile>(sheetTile('标记为未读')).enabled, isFalse);
      expect(tester.widget<ListTile>(sheetTile('删除')).enabled, isTrue);

      // A disabled tile must not fire its registry mutation.
      await tester.tap(sheetTile('置顶'));
      await tester.pumpAndSettle();
      expect(
        session.channelCalls.where((c) => c.$2 == 'setTaskPinned'),
        isEmpty,
      );
    });

    testWidgets('registered row: the four ops stay enabled (unchanged)',
        (tester) async {
      await setupC1(tester, relayTasks: [registeredRelayRow()]);
      await tester.longPress(find.text('Fork 草稿'));
      await tester.pumpAndSettle();

      expect(tester.widget<ListTile>(sheetTile('置顶')).enabled, isTrue);
      expect(tester.widget<ListTile>(sheetTile('重命名')).enabled, isTrue);
      expect(tester.widget<ListTile>(sheetTile('归档')).enabled, isTrue);
      expect(tester.widget<ListTile>(sheetTile('标记为未读')).enabled, isTrue);
    });

    // The swipe tray has no disabled state to lean on (Step 3 check P2-1):
    // draft rows OMIT archive/unread outright — a dead tap could only end
    // in the matches=0 error. Delete stays on both row kinds.
    testWidgets('draft row: swipe tray keeps delete only, no archive/unread',
        (tester) async {
      await setupC1(tester, relayTasks: const []);

      final labels = tester
          .widget<SwipeActionsRow>(find.byType(SwipeActionsRow))
          .actions
          .map((a) => a.label)
          .toList();

      expect(labels, ['删除']);
      expect(find.text('归档'), findsNothing);
      expect(find.text('标记为未读'), findsNothing);
    });

    testWidgets('registered row: swipe tray keeps all three actions',
        (tester) async {
      await setupC1(tester, relayTasks: [registeredRelayRow()]);

      final labels = tester
          .widget<SwipeActionsRow>(find.byType(SwipeActionsRow))
          .actions
          .map((a) => a.label)
          .toList();

      expect(labels, containsAll(['归档', '标记为未读', '删除']));
      expect(labels, hasLength(3));
    });

    testWidgets(
        'draft row delete: routes to the V4 session command, never deleteTask',
        (tester) async {
      final (_, _, session) = await setupC1(tester, relayTasks: const []);

      await deleteViaSheet(tester);

      expect(
        session.conversationCalls.where((c) => c.$1 == 'deleteSession'),
        hasLength(1),
      );
      expect(session.conversationCalls.last.$2, ['fork1']);
      expect(
        session.channelCalls.where((c) => c.$2 == 'deleteTask'),
        isEmpty,
        reason: 'the registry op can never resolve a draft (matches=0)',
      );
      // The tombstone must drop the row at once — no resurrection window.
      expect(find.text('Fork 草稿'), findsNothing);
    });

    testWidgets(
        'registered row delete: deleteTask success path keeps working '
        '(no regression, no fallback)', (tester) async {
      final (_, _, session) =
          await setupC1(tester, relayTasks: [registeredRelayRow()]);

      await deleteViaSheet(tester);

      expect(
        session.channelCalls.where((c) => c.$2 == 'deleteTask'),
        hasLength(1),
      );
      expect(
        session.conversationCalls.where((c) => c.$1 == 'deleteSession'),
        isEmpty,
      );
      expect(find.text('Fork 草稿'), findsNothing);
    });

    testWidgets(
        'registered row delete hitting matches=0 falls back to deleteSession '
        'once and presents success', (tester) async {
      final (_, _, session) = await setupC1(
        tester,
        relayTasks: [registeredRelayRow()],
        channelHandler: (channel, method, args) async {
          if (method == 'deleteTask') {
            // The live matches=0 shape (research-emulator.md A-1).
            throw ChannelRpcError(
                '列表 mutation 无法解析唯一 source, taskId=fork1', null);
          }
          return null;
        },
      );

      await deleteViaSheet(tester);

      expect(
        session.conversationCalls.where((c) => c.$1 == 'deleteSession'),
        hasLength(1),
        reason: 'the registry row vanished under the tap — one session-'
            'command fallback (design D4)',
      );
      expect(find.textContaining('操作失败'), findsNothing);
      expect(find.text('Fork 草稿'), findsNothing);
    });

    testWidgets(
        'unrelated deleteTask failure: no fallback, the error surfaces '
        'humanized (busy maps via businessErrorCopy)', (tester) async {
      final (_, _, session) = await setupC1(
        tester,
        relayTasks: [registeredRelayRow()],
        channelHandler: (channel, method, args) async {
          if (method == 'deleteTask') {
            throw ChannelRpcError('会话正在进行中，稍后再试', null);
          }
          return null;
        },
      );

      await deleteViaSheet(tester);

      expect(
        session.conversationCalls.where((c) => c.$1 == 'deleteSession'),
        isEmpty,
        reason: 'only the resolve-failure shape may fall back',
      );
      // _runOp routes through businessErrorCopy: the busy wire text
      // maps to tasks.error.sessionBusy instead of surfacing raw.
      expect(find.textContaining('会话正在处理中，请稍后重试'), findsOneWidget);
      expect(find.textContaining('ChannelRpcError'), findsNothing);

      // Drain the SnackBar auto-dismiss timer.
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });
  });

  // ---- C2 (10-05): task-list UX batch — B2 radio freeze / B7 empty group /
  // B8 group dot / B9 sheet object title ----
  group('C2 task-list UX: radio sync, empty group, group dot, sheet title', () {
    testWidgets('tidy panel radio switches its visual at once, sheet stays '
        'open (B2)', (tester) async {
      await setupTwoWorkspaces(tester);

      await tester.tap(find.byTooltip('整理任务'));
      await tester.pumpAndSettle();

      // Both radio groups live in the sheet; the sheet is its own route, so
      // their groupValue only moves when the SHEET rebuilds (the B2 freeze).
      Finder groupOf() => find.byType(RadioGroup<String>).first;
      Finder sortOf() => find.byType(RadioGroup<String>).last;
      expect(tester.widget<RadioGroup<String>>(groupOf()).groupValue,
          'workspace');
      expect(tester.widget<RadioGroup<String>>(sortOf()).groupValue,
          'updated');

      await tester.tap(find.text('按时间线'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(tester.widget<RadioGroup<String>>(groupOf()).groupValue,
          'timeline');

      await tester.tap(find.text('创建时间'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(tester.widget<RadioGroup<String>>(sortOf()).groupValue,
          'created');
    });

    testWidgets('0-task workspace shows the 0 count; expanding shows the '
        'empty hint (B7)', (tester) async {
      usePhone(tester);
      final (store, device) = await setupDevice();
      final now = DateTime.now().millisecondsSinceEpoch;
      // beta carries no relay rows and is not active — the empty group.
      final session = FakeDeviceSession(
        deviceId: device.id,
        params: device.params!,
        entries: [
          {
            'sessionId': 's1',
            'title': '任务甲',
            'phase': 'completedSuccess',
            'lastActivityAt': now,
          },
        ],
        workspaces: [
          {'workspacePath': '/repo/alpha', 'workspaceIdentity': 'alpha'},
          {'workspacePath': '/repo/beta', 'workspaceIdentity': 'beta'},
        ],
      );
      await tester.pumpWidget(wrap(TaskListPage(
        store: store,
        hub: DeviceSessionHub(nativeListEnabled: () => false),
        device: device,
        sessionOverride: session,
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Collapsed header already says 「0 个任务」 (hidden before B7).
      expect(
        find.descendant(
            of: cardOf('beta'), matching: find.text('0 个任务')),
        findsOneWidget,
      );

      await tester.tap(find.text('beta'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.descendant(
            of: cardOf('beta'), matching: find.text('暂无任务')),
        findsOneWidget,
      );
    });

    testWidgets('workspace-view rows carry the task group dot (B8)',
        (tester) async {
      usePhone(tester);
      final (store, device) = await setupDevice();
      final now = DateTime.now().millisecondsSinceEpoch;
      final session = FakeDeviceSession(
        deviceId: device.id,
        params: device.params!,
        entries: [
          {
            'sessionId': 's1',
            'title': '未分组任务',
            'phase': 'completedSuccess',
            'lastActivityAt': now,
          },
          {
            'sessionId': 's2',
            'title': '组内任务',
            'phase': 'completedSuccess',
            'lastActivityAt': now - 10,
          },
        ],
        workspaces: [
          {'workspacePath': '/repo/app', 'workspaceIdentity': 'app-id'},
        ],
        channelHandler: (c, m, a) async => m == 'listGroupedTaskViewStructure'
            ? {
                'groups': [
                  {
                    'id': 'g1',
                    'title': 'cron',
                    'color': 'blue',
                    'createdAt': 5,
                  },
                ],
                'members': [
                  {'groupId': 'g1', 'taskId': 's2', 'addedAt': 3},
                ],
                'topLevelOrders': <dynamic>[],
              }
            : null,
      );
      await tester.pumpWidget(wrap(TaskListPage(
        store: store,
        hub: DeviceSessionHub(nativeListEnabled: () => false),
        device: device,
        sessionOverride: session,
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // Let the once-per-session grouped-view RPC land and the page rebuild.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Default (workspace) grouping: the grouped row carries the group's
      // blue palette dot — the same marker the timeline header renders.
      // No unread/pill noise in this fixture, so the dot count is exact.
      Finder skyDot() => find.byWidgetPredicate((w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration! as BoxDecoration).color == ZColors.sky500 &&
          (w.decoration! as BoxDecoration).shape == BoxShape.circle);
      expect(skyDot(), findsOneWidget);
      // The dot sits on the grouped row (its InkWell), not the sibling's.
      Finder dotRow() => find.ancestor(of: skyDot(), matching: find.byType(InkWell));
      expect(
        find.descendant(of: dotRow(), matching: find.text('组内任务')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dotRow(), matching: find.text('未分组任务')),
        findsNothing,
      );
    });

    testWidgets('long-press sheet opens with the task title and workspace '
        'chip; a long title ellipsizes (B9)', (tester) async {
      usePhone(tester);
      final (store, device) = await setupDevice();
      final longTitle = '一个特别特别长的任务标题' * 12;
      final session = FakeDeviceSession(
        deviceId: device.id,
        params: device.params!,
        entries: [
          {
            'sessionId': 's1',
            'title': longTitle,
            'phase': 'completedSuccess',
            'lastActivityAt': DateTime.now().millisecondsSinceEpoch,
          },
        ],
        workspaces: [
          {'workspacePath': '/repo/app', 'workspaceIdentity': 'app-id'},
        ],
      );
      await tester.pumpWidget(wrap(TaskListPage(
        store: store,
        hub: DeviceSessionHub(nativeListEnabled: () => false),
        device: device,
        sessionOverride: session,
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.longPress(find.text(longTitle));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      // Object title row is the sheet's first row (no usage line in this
      // fixture), carrying the workspace chip beside it.
      final titleText = tester.widget<Text>(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text(longTitle),
        ),
      );
      expect(titleText.maxLines, 1);
      expect(titleText.overflow, TextOverflow.ellipsis);
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text('app'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('archived rows keep the sheet workspace chip via the raw '
        'origin fallback (B9 P2)', (tester) async {
      usePhone(tester);
      final (store, device) = await setupDevice();
      final session = FakeDeviceSession(
        deviceId: device.id,
        params: device.params!,
        entries: [],
        workspaces: [
          {'workspacePath': '/repo/app', 'workspaceIdentity': 'app-id'},
          // The archived row's workspace must be listed for the archive
          // view to render its group; the sheet's wsKey lookup still
          // misses (allEntries filters archived), so the chip rides the
          // raw origin fallback.
          {'workspacePath': '/repo/gone', 'workspaceIdentity': 'gone-id'},
        ],
        // Archived rows are filtered out of allEntries, so the sheet's
        // wsKey lookup misses — the chip must survive on the row's own
        // origin fields, even for a workspace no longer in the list.
        relayTasks: [
          {
            'taskId': 'ra1',
            'title': '归档任务',
            'workspacePath': '/repo/gone',
            'workspaceIdentity': 'gone-id',
            'displayStatus': 'idle',
            'archived': true,
            'updatedAt': DateTime.now().millisecondsSinceEpoch,
          },
        ],
      );
      await tester.pumpWidget(wrap(TaskListPage(
        store: store,
        hub: DeviceSessionHub(nativeListEnabled: () => false),
        device: device,
        sessionOverride: session,
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Mobile reaches the archived view through the overflow menu.
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看归档'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.longPress(find.text('归档任务'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text('gone'),
        ),
        findsOneWidget,
        reason: 'archived row keeps its workspace chip via raw fallback',
      );
    });
  });

  group('default group title fallback (D5, official B3)', () {
    Future<FakeDeviceSession> pumpGrouped(
      WidgetTester tester, {
      required String groupId,
      required String title,
    }) async {
      usePhone(tester);
      final (store, device) = await setupDevice();
      final now = DateTime.now().millisecondsSinceEpoch;
      final session = FakeDeviceSession(
        deviceId: device.id,
        params: device.params!,
        entries: [
          {
            'sessionId': 's2',
            'title': '组内任务',
            'phase': 'completedSuccess',
            'lastActivityAt': now,
          },
        ],
        workspaces: [
          {'workspacePath': '/repo/app', 'workspaceIdentity': 'app-id'},
        ],
        channelHandler: (c, m, a) async => m == 'listGroupedTaskViewStructure'
            ? {
                'groups': [
                  {'id': groupId, 'title': title, 'color': 'blue', 'createdAt': 5},
                ],
                'members': [
                  {
                    'groupId': groupId,
                    'taskId': 's2',
                    'workspaceKey': 'app-id',
                    'sortOrder': null,
                    'addedAt': 3,
                  },
                ],
                'topLevelOrders': [
                  {'type': 'group', 'groupId': groupId, 'sortOrder': 4},
                ],
              }
            : null,
      );
      await tester.pumpWidget(wrap(TaskListPage(
        store: store,
        hub: DeviceSessionHub(nativeListEnabled: () => false),
        device: device,
        sessionOverride: session,
      )));
      await tester.pump();
      await tester.tap(find.byTooltip('整理任务'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('按时间线'));
      await tester.pumpAndSettle();
      return session;
    }

    testWidgets('empty wire title of the cron default group localizes',
        (tester) async {
      await pumpGrouped(
        tester,
        groupId: 'zcode-default-group-cron',
        title: '',
      );
      expect(find.text('定时任务'), findsOneWidget);
      expect(find.text('组内任务'), findsOneWidget);
    });

    testWidgets('id-equal wire title falls back too; off-peak group maps '
        'to its own lexicon key', (tester) async {
      await pumpGrouped(
        tester,
        groupId: 'zcode-default-group-off-peak',
        title: 'zcode-default-group-off-peak',
      );
      expect(find.text('闲时任务'), findsOneWidget);
    });

    testWidgets('named groups keep their wire title untouched',
        (tester) async {
      await pumpGrouped(tester, groupId: 'g1', title: '自定义组');
      expect(find.text('自定义组'), findsOneWidget);
    });
  });

  group('mobile search entry (D6)', () {
    testWidgets('the header search button opens the unified search page',
        (tester) async {
      usePhone(tester);
      final (store, device) = await setupDevice();
      final session = FakeDeviceSession(
        deviceId: device.id,
        params: device.params!,
        entries: const [],
        workspaces: [
          {'workspacePath': '/repo/app'},
        ],
      );
      await tester.pumpWidget(wrap(TaskListPage(
        store: store,
        hub: DeviceSessionHub(nativeListEnabled: () => false),
        device: device,
        sessionOverride: session,
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();

      expect(find.byType(TaskSearchPage), findsOneWidget);
      // Lands on the 全部 tab with the search hint visible.
      expect(find.text('搜索任务、命令与文件'), findsOneWidget);
    });
  });
}
