import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:zgo/plan/plan_account.dart';
import 'package:zgo/plan/plan_api.dart';
import 'package:zgo/plan/plan_local_memo.dart';
import 'package:zgo/ui/plan_page.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

class _Store implements PlanTokenStore {
  @override
  Future<String?> readToken() async => 'stored-token';

  @override
  Future<void> writeToken(String token) async {}

  @override
  Future<void> clearToken() async {}

  @override
  Future<String> deviceMid() async => 'mid-test';
}

class _Memo implements PlanLocalMemo {
  _Memo(this.expiry);

  DateTime? expiry;

  @override
  Future<DateTime?> readPlanExpiry() async => expiry;

  @override
  Future<void> writePlanExpiry(DateTime d) async {
    expiry = d;
  }

  @override
  Future<void> clearPlanExpiry() async {
    expiry = null;
  }
}

/// Wire epochs are seconds.
int _secs(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

Map<String, Object?> _planRow({
  String status = 'active',
  DateTime? effectiveAt,
  DateTime? endsAt,
  int grantUnits = 300000000,
}) =>
    {
      'plan_id': 'weekend-build',
      'name': 'Weekend Build',
      'status': status,
      if (endsAt != null) 'ends_at': _secs(endsAt),
      'entitlements': [
        {
          'entitlement_id': 'ent-1',
          'show_name': 'GLM-5.3-Flash',
          'grant_units': grantUnits,
          'capabilities': ['model:glm-5.3-flash'],
          if (effectiveAt != null) 'effective_at': _secs(effectiveAt),
        },
      ],
    };

Map<String, Object?> _data({
  List<Object?> plans = const [],
  List<Object?> balances = const [],
}) =>
    {
      'plans': plans,
      'balances': balances,
    };

/// Pre-loads the controller so the page renders a settled snapshot (no
/// spinner left for `pumpAndSettle` to chase).
Future<PlanController> _loaded(
  Map<String, Object?> data, {
  DateTime? memoExpiry,
}) async {
  final controller = PlanController(
    store: _Store(),
    api: PlanApi(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({'code': 0, 'msg': '', 'data': data}),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    ),
    memo: _Memo(memoExpiry),
  );
  await controller.ensureLoaded();
  addTearDown(controller.dispose);
  return controller;
}

Future<void> _pump(WidgetTester tester, PlanController controller) async {
  await tester.pumpWidget(MaterialApp(
    theme: buildDarkTheme(),
    builder: (context, child) => UiSettingsProvider(
      settings: UiSettings(),
      child: child!,
    ),
    home: PlanPage(controller: controller),
  ));
  await tester.pumpAndSettle();
}

String _date(DateTime t) => t.toLocal().toString().substring(0, 10);

String _dateTime(DateTime t) => t.toLocal().toString().substring(0, 16);

void main() {
  testWidgets(
      'active plan + empty balances + future effective_at: active card with '
      'the pending activation note', (tester) async {
    final effectiveAt = DateTime.now().add(const Duration(hours: 3));
    final endsAt = DateTime.now().add(const Duration(days: 20));
    final controller = await _loaded(_data(plans: [
      _planRow(effectiveAt: effectiveAt, endsAt: endsAt),
    ]));

    await _pump(tester, controller);

    expect(find.text('Weekend Build'), findsOneWidget);
    expect(find.text('GLM-5.3-Flash'), findsOneWidget);
    expect(find.text('授予 300,000,000'), findsOneWidget);
    expect(find.text('将于 ${_dateTime(effectiveAt)} 生效'), findsOneWidget);
    expect(find.text('到期 ${_date(endsAt)}'), findsOneWidget);
    expect(find.text('暂无套餐数据'), findsNothing);
    expect(find.textContaining('套餐已于'), findsNothing);
    // No bar: neither state has used/remaining facts to draw.
    expect(find.byType(FractionallySizedBox), findsNothing);
  });

  testWidgets(
      'active plan + empty balances + past effective_at: the quota-missing '
      'note instead of the empty state', (tester) async {
    final effectiveAt = DateTime.now().subtract(const Duration(hours: 1));
    final controller = await _loaded(_data(plans: [
      _planRow(effectiveAt: effectiveAt),
    ]));

    await _pump(tester, controller);

    expect(find.text('余量暂未生成，下拉刷新后显示'), findsOneWidget);
    expect(find.textContaining('将于'), findsNothing);
    expect(find.text('暂无套餐数据'), findsNothing);
    expect(find.text('授予 300,000,000'), findsOneWidget);
    expect(find.byType(FractionallySizedBox), findsNothing);
  });

  testWidgets(
      'active plan + empty balances + past memo: the active card outranks '
      'the memo-derived expired copy', (tester) async {
    final memo = DateTime.now().subtract(const Duration(days: 2));
    final effectiveAt = DateTime.now().subtract(const Duration(hours: 1));
    final controller = await _loaded(
      _data(plans: [_planRow(effectiveAt: effectiveAt)]),
      memoExpiry: memo,
    );
    // The controller still classifies the empty snapshot (semantics
    // unchanged); the page's branch order is what suppresses the copy.
    expect(controller.expiredOn, isNotNull);

    await _pump(tester, controller);

    expect(find.text('Weekend Build'), findsOneWidget);
    expect(find.text('余量暂未生成，下拉刷新后显示'), findsOneWidget);
    expect(find.textContaining('套餐已于'), findsNothing);
    expect(find.text('暂无套餐数据'), findsNothing);
  });

  testWidgets(
      'no active plan + empty balances: the plain empty state is unchanged',
      (tester) async {
    final controller = await _loaded(_data(plans: [
      _planRow(status: 'expired'),
    ]));

    await _pump(tester, controller);

    expect(find.text('暂无套餐数据'), findsOneWidget);
    expect(find.text('Weekend Build'), findsNothing);
    expect(find.textContaining('余量暂未生成'), findsNothing);
  });

  testWidgets(
      'non-active plan + empty balances + past memo: the expired copy is '
      'unchanged', (tester) async {
    final memo = DateTime.now().subtract(const Duration(days: 2));
    final controller = await _loaded(
      _data(plans: [_planRow(status: 'expired')]),
      memoExpiry: memo,
    );

    await _pump(tester, controller);

    expect(find.text('套餐已于 ${_date(memo)} 过期'), findsOneWidget);
    expect(find.text('暂无套餐数据'), findsNothing);
    expect(find.text('Weekend Build'), findsNothing);
  });

  testWidgets(
      'bucket snapshots keep the bucket card and never render plan cards',
      (tester) async {
    final expires = DateTime.now().add(const Duration(days: 10));
    final controller = await _loaded({
      'plans': [
        _planRow(effectiveAt: DateTime.now().subtract(const Duration(hours: 1))),
      ],
      'balances': [
        {
          'entitlement_id': 'ent-1',
          'show_name': 'GLM-5.3-Flash',
          'capabilities': ['model:glm-5.3-flash'],
          'total_units': 300000000,
          'used_units': 85095369,
          'remaining_units': 214904631,
          'expires_at': _secs(expires),
        },
      ],
    });

    await _pump(tester, controller);

    expect(find.text('GLM-5.3-Flash'), findsOneWidget);
    expect(find.text('剩余'), findsOneWidget);
    expect(find.text('214,904,631'), findsOneWidget);
    expect(find.text('85,095,369'), findsOneWidget);
    expect(find.text('300,000,000'), findsOneWidget);
    expect(find.text('到期 ${_date(expires)}'), findsOneWidget);
    expect(find.byType(FractionallySizedBox), findsOneWidget);
    // Plan cards exist only as the empty-bucket fallback.
    expect(find.text('Weekend Build'), findsNothing);
    expect(find.textContaining('余量暂未生成'), findsNothing);
  });
}
