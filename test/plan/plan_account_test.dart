import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:zgo/plan/plan_account.dart';
import 'package:zgo/plan/plan_api.dart';
import 'package:zgo/plan/plan_local_memo.dart';
import 'package:zgo/plan/plan_oauth.dart';

String makeJwt({String userId = 'user-42'}) {
  final payload = base64Url.encode(utf8.encode(jsonEncode({
    'user_id': userId,
    'sub': userId,
    'token_version': 3,
    'iat': 1757836800,
  })));
  // header.payload.signature — signature unused by the app.
  return 'aaa.$payload.sig';
}

class FakeTokenStore implements PlanTokenStore {
  String? token;
  String? mid;
  int writes = 0;
  int clears = 0;

  @override
  Future<String?> readToken() async => token;

  @override
  Future<void> writeToken(String value) async {
    writes++;
    token = value;
  }

  @override
  Future<void> clearToken() async {
    clears++;
    token = null;
  }

  @override
  Future<String> deviceMid() async => mid ??= 'mid-fixed';
}

class FakePlanMemo implements PlanLocalMemo {
  DateTime? expiry;
  int writes = 0;
  int clears = 0;

  @override
  Future<DateTime?> readPlanExpiry() async => expiry;

  @override
  Future<void> writePlanExpiry(DateTime d) async {
    writes++;
    expiry = d;
  }

  @override
  Future<void> clearPlanExpiry() async {
    clears++;
    expiry = null;
  }
}

class FakeApi {
  final requests = <http.Request>[];
  var nextStatus = 200;

  /// When true the mock client throws a transport error instead of
  /// returning a response.
  var failTransport = false;
  Object? nextBody = {
    'code': 0,
    'msg': '',
    'data': {
      'balances': [
        {
          'entitlement_id': 'ent-1',
          'show_name': 'GLM-5.3-Flash',
          'total_units': 300000000,
          'used_units': 85095369,
          'remaining_units': 214904631,
        },
      ],
    },
  };

  PlanApi build() => PlanApi(client: MockClient((req) async {
        requests.add(req);
        if (failTransport) throw http.ClientException('offline');
        return http.Response(jsonEncode(nextBody), nextStatus,
            headers: {'content-type': 'application/json'});
      }));
}

/// `cli/init` frame for the OAuth flow (expiry safely in the future for
/// the real-clock default).
http.Response oauthInitRes() => http.Response(
      jsonEncode({
        'code': 0,
        'data': {
          'flow_id': 'flow-x',
          'poll_token': 'poll-x',
          'authorize_url': 'https://chat.z.ai/authorize?x=1',
          'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 600,
          'poll_interval_sec': 2,
        },
      }),
      200,
      headers: {'content-type': 'application/json'},
    );

/// `ready` terminal frame carrying the inlined token set (probe shape).
http.Response oauthReadyRes(String token) => http.Response(
      jsonEncode({
        'code': 0,
        'data': {
          'status': 'ready',
          'token': token,
          'user': {
            'user_id': 'u-oauth',
            'email': 'user@example.com',
            'name': 'U',
            'avatar': '',
          },
          'zai': {'access_token': 'zai-secret'},
        },
      }),
      200,
      headers: {'content-type': 'application/json'},
    );

http.Response oauthPendingRes() => http.Response(
      jsonEncode({
        'code': 0,
        'data': {'status': 'pending'},
      }),
      200,
      headers: {'content-type': 'application/json'},
    );

/// Fixed judging instant for the expiry-boundary tests (PRD R3).
final kNow = DateTime.fromMillisecondsSinceEpoch(1795000000000);

Map<String, Object> bucketRow(String id, int? expiresAtMs) => {
      'entitlement_id': id,
      'show_name': id,
      if (expiresAtMs != null) 'expires_at': expiresAtMs,
    };

Map<String, Object> balanceBody(List<Map<String, Object>> balances) => {
      'code': 0,
      'msg': '',
      'data': {'balances': balances},
    };

void main() {
  group('generateUuidV4', () {
    test('produces canonical v4 strings', () {
      final re = RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
      for (var i = 0; i < 50; i++) {
        expect(generateUuidV4(Random(42 + i)), matches(re));
      }
    });
  });

  group('planAccountLabel', () {
    test('decodes user_id from the JWT claims', () {
      expect(planAccountLabel(makeJwt(userId: 'u-7')), 'u-7');
    });

    test('garbage tokens yield null instead of throwing', () {
      expect(planAccountLabel(''), isNull);
      expect(planAccountLabel('not-a-jwt'), isNull);
      expect(planAccountLabel('a.${base64Url.encode(utf8.encode('[]'))}.c'),
          isNull);
      expect(
          planAccountLabel(
              'a.${base64Url.encode(utf8.encode('{"user_id": 0}'))}.c'),
          '0');
    });

    test('email wins over the JWT claims, blank email falls back', () {
      expect(planAccountLabel(makeJwt(userId: 'u-7'), email: 'a@b.c'), 'a@b.c');
      expect(planAccountLabel(makeJwt(userId: 'u-7'), email: '   '), 'u-7');
      expect(planAccountLabel(makeJwt(userId: 'u-7')), 'u-7');
      expect(planAccountLabel(makeJwt(userId: 'u-7'), email: null), 'u-7');
    });
  });

  group('PlanController', () {
    test('load without stored token stays signed out and never fetches',
        () async {
      final store = FakeTokenStore();
      final api = FakeApi();
      final c = PlanController(store: store, api: api.build());

      await c.ensureLoaded();

      expect(c.signedIn, isFalse);
      expect(c.snapshot.buckets, isEmpty);
      expect(api.requests, isEmpty);
    });

    test('load with stored token fetches and exposes the account label',
        () async {
      final store = FakeTokenStore()..token = makeJwt();
      final api = FakeApi();
      final c = PlanController(store: store, api: api.build());

      await c.ensureLoaded();

      expect(c.signedIn, isTrue);
      expect(c.accountLabel, 'user-42');
      expect(c.authExpired, isFalse);
      expect(c.error, isNull);
      expect(api.requests, hasLength(1));
      expect(api.requests.single.url.path,
          '/api/v1/zcode-plan/billing/balance');
      expect(api.requests.single.headers['x-device-mid'], 'mid-fixed');
      expect(c.snapshot.buckets.single.remaining, 214904631);
      // Idempotent: a second ensure does not refetch.
      await c.ensureLoaded();
      expect(api.requests, hasLength(1));
    });

    test('signIn trims, persists, fetches', () async {
      final store = FakeTokenStore();
      final api = FakeApi();
      final c = PlanController(store: store, api: api.build());
      await c.ensureLoaded();

      final ok = await c.signIn('  ${makeJwt(userId: 'u-9')}  \n');

      expect(ok, isTrue);
      expect(store.writes, 1);
      expect(store.token, makeJwt(userId: 'u-9'));
      expect(c.signedIn, isTrue);
      expect(c.accountLabel, 'u-9');
      expect(api.requests, hasLength(1));
    });

    test('signIn rejects blank tokens without fetching', () async {
      final store = FakeTokenStore();
      final api = FakeApi();
      final c = PlanController(store: store, api: api.build());
      await c.ensureLoaded();

      expect(await c.signIn('   '), isFalse);
      expect(store.writes, 0);
      expect(api.requests, isEmpty);
    });

    group('signInWithOAuth', () {
      test('ready persists the token, fetches balance, prefers the email',
          () async {
        final store = FakeTokenStore();
        final api = FakeApi();
        final c = PlanController(
          store: store,
          api: api.build(),
          oauthFactory: () => PlanOAuth(
            client: MockClient((req) async {
              if (req.url.path == '/api/v1/oauth/cli/init') {
                return oauthInitRes();
              }
              return oauthReadyRes(makeJwt(userId: 'u-oauth'));
            }),
            delay: (_) async {},
          ),
        );

        await c.signInWithOAuth();

        expect(store.writes, 1);
        expect(store.token, makeJwt(userId: 'u-oauth'));
        expect(c.signedIn, isTrue);
        expect(c.accountLabel, 'user@example.com');
        expect(c.oauthInProgress, isFalse);
        expect(c.oauthFailure, isNull);
        expect(c.error, isNull);
        expect(api.requests, hasLength(1));
        expect(api.requests.single.url.path,
            '/api/v1/zcode-plan/billing/balance');
        expect(c.snapshot.buckets.single.remaining, 214904631);
      });

      test('flow rejection surfaces oauthFailure without writing', () async {
        final store = FakeTokenStore();
        final api = FakeApi();
        final c = PlanController(
          store: store,
          api: api.build(),
          oauthFactory: () => PlanOAuth(
            client: MockClient((req) async {
              if (req.url.path == '/api/v1/oauth/cli/init') {
                return oauthInitRes();
              }
              return http.Response('', 403);
            }),
            delay: (_) async {},
          ),
        );

        await c.signInWithOAuth();

        expect(store.writes, 0);
        expect(c.signedIn, isFalse);
        expect(c.oauthFailure, PlanOAuthFailureReason.flowRejected);
        expect(c.oauthInProgress, isFalse);
        expect(api.requests, isEmpty);
      });

      test('userCancelled stays silent and leaves the store untouched',
          () async {
        final store = FakeTokenStore();
        final api = FakeApi();
        late final PlanOAuth oauth;
        final c = PlanController(
          store: store,
          api: api.build(),
          oauthFactory: () {
            oauth = PlanOAuth(
              client: MockClient((req) async {
                if (req.url.path == '/api/v1/oauth/cli/init') {
                  return oauthInitRes();
                }
                return oauthPendingRes();
              }),
              delay: (_) async => oauth.cancel(),
            );
            return oauth;
          },
        );

        await c.signInWithOAuth();

        expect(store.writes, 0);
        expect(c.signedIn, isFalse);
        // Cancelling is not an error: back to the idle card.
        expect(c.oauthFailure, isNull);
        expect(c.oauthInProgress, isFalse);
        expect(api.requests, isEmpty);
      });

      test('after a restart the label falls back to the JWT user_id',
          () async {
        final store = FakeTokenStore();
        final api = FakeApi();
        PlanController newController() => PlanController(
              store: store,
              api: api.build(),
              oauthFactory: () => PlanOAuth(
                client: MockClient((req) async {
                  if (req.url.path == '/api/v1/oauth/cli/init') {
                    return oauthInitRes();
                  }
                  return oauthReadyRes(makeJwt(userId: 'u-oauth'));
                }),
                delay: (_) async {},
              ),
            );
        final c = newController();
        await c.signInWithOAuth();
        expect(c.accountLabel, 'user@example.com');

        // Fresh process: only the token persists, email was memory-only.
        final c2 = newController();
        await c2.loadIdentity();
        expect(c2.accountLabel, 'u-oauth');
      });
    });

    test('401 marks the login expired but keeps the last snapshot',
        () async {
      final store = FakeTokenStore()..token = makeJwt();
      final api = FakeApi();
      final c = PlanController(store: store, api: api.build());
      await c.ensureLoaded();
      expect(c.snapshot.buckets, hasLength(1));

      api.nextStatus = 401;
      api.nextBody = {'code': 401};
      await c.refresh();

      expect(c.authExpired, isTrue);
      expect(c.signedIn, isTrue); // re-login replaces the token
      expect(c.error, isA<PlanAuthExpired>());
      // Stale data retained with its data timestamp (R4).
      expect(c.snapshot.buckets, hasLength(1));
    });

    test('network errors keep the snapshot and surface a retryable error',
        () async {
      final store = FakeTokenStore()..token = makeJwt();
      final api = FakeApi()..failTransport = true;
      final c = PlanController(store: store, api: api.build());

      await c.ensureLoaded();

      expect(c.error, isA<PlanNetworkError>());
      expect(c.snapshot.buckets, isEmpty);
    });

    test('a successful refresh clears error and expiry marks', () async {
      final store = FakeTokenStore()..token = makeJwt();
      final api = FakeApi();
      final c = PlanController(store: store, api: api.build());
      await c.ensureLoaded();

      api.nextStatus = 401;
      api.nextBody = {'code': 401};
      await c.refresh();
      expect(c.authExpired, isTrue);

      api.nextStatus = 200;
      api.nextBody = {
        'code': 0,
        'msg': '',
        'data': {
          'balances': [
            {'entitlement_id': 'e', 'remaining_units': 1},
          ],
        },
      };
      await c.refresh();

      expect(c.authExpired, isFalse);
      expect(c.error, isNull);
      expect(c.snapshot.buckets.single.remaining, 1);
    });

    test('signOut clears the store and resets state', () async {
      final store = FakeTokenStore()..token = makeJwt();
      final api = FakeApi();
      final c = PlanController(store: store, api: api.build());
      await c.ensureLoaded();

      await c.signOut();

      expect(store.clears, 1);
      expect(c.signedIn, isFalse);
      expect(c.accountLabel, isNull);
      expect(c.authExpired, isFalse);
      expect(c.error, isNull);
      expect(c.snapshot.buckets, isEmpty);
    });

    test('dispose is idempotent and late fetches are dropped', () async {
      final store = FakeTokenStore()..token = makeJwt();
      final api = FakeApi();
      final c = PlanController(store: store, api: api.build());
      await c.ensureLoaded();

      c.dispose();
      c.dispose(); // must not throw

      api.nextStatus = 401;
      api.nextBody = {'code': 401};
      await c.refresh(); // after dispose → no state touch, no throw
      expect(c.authExpired, isFalse);
    });
  });

  group('plan expiry memo (empty-bucket expired state)', () {
    test('a non-empty snapshot persists the latest periodEnd across buckets',
        () async {
      final store = FakeTokenStore()..token = makeJwt();
      final memo = FakePlanMemo();
      final api = FakeApi()
        ..nextBody = balanceBody([
          bucketRow('old', kNow.millisecondsSinceEpoch - 86400000),
          bucketRow('live', kNow.millisecondsSinceEpoch + 86400000),
          bucketRow('no-date', null),
        ]);
      final c = PlanController(
          store: store, api: api.build(), memo: memo, now: () => kNow);

      await c.ensureLoaded();

      expect(memo.writes, 1);
      expect(
        memo.expiry,
        DateTime.fromMillisecondsSinceEpoch(
            kNow.millisecondsSinceEpoch + 86400000),
      );
      // Live buckets: the empty-state getter stays null regardless.
      expect(c.expiredOn, isNull);
    });

    test('an unchanged latest expiry is not rewritten on the next refresh',
        () async {
      final store = FakeTokenStore()..token = makeJwt();
      final memo = FakePlanMemo();
      final api = FakeApi()
        ..nextBody = balanceBody([
          bucketRow('b', kNow.millisecondsSinceEpoch + 86400000),
        ]);
      final c = PlanController(
          store: store, api: api.build(), memo: memo, now: () => kNow);

      await c.ensureLoaded();
      await c.refresh();

      expect(memo.writes, 1);
    });

    test('buckets without any date never write the memo', () async {
      final store = FakeTokenStore()..token = makeJwt();
      final memo = FakePlanMemo();
      final api = FakeApi()
        ..nextBody = balanceBody([bucketRow('no-date', null)]);
      final c = PlanController(
          store: store, api: api.build(), memo: memo, now: () => kNow);

      await c.ensureLoaded();

      expect(memo.writes, 0);
      expect(memo.expiry, isNull);
      expect(c.expiredOn, isNull);
    });

    test('empty snapshot + past memo date classifies as expired', () async {
      final store = FakeTokenStore()..token = makeJwt();
      final memo = FakePlanMemo()
        ..expiry = kNow.subtract(const Duration(days: 1));
      final api = FakeApi()..nextBody = balanceBody([]);
      final c = PlanController(
          store: store, api: api.build(), memo: memo, now: () => kNow);

      await c.ensureLoaded();

      expect(c.error, isNull);
      expect(c.snapshot.buckets, isEmpty);
      expect(c.expiredOn, kNow.subtract(const Duration(days: 1)));
    });

    test('empty snapshot + future memo date stays the plain empty state',
        () async {
      final store = FakeTokenStore()..token = makeJwt();
      final memo = FakePlanMemo()
        ..expiry = kNow.add(const Duration(days: 1));
      final api = FakeApi()..nextBody = balanceBody([]);
      final c = PlanController(
          store: store, api: api.build(), memo: memo, now: () => kNow);

      await c.ensureLoaded();

      expect(c.expiredOn, isNull);
    });

    test('no memo + empty snapshot stays the plain empty state', () async {
      final store = FakeTokenStore()..token = makeJwt();
      final memo = FakePlanMemo();
      final api = FakeApi()..nextBody = balanceBody([]);
      final c = PlanController(
          store: store, api: api.build(), memo: memo, now: () => kNow);

      await c.ensureLoaded();

      expect(c.expiredOn, isNull);
    });

    test('boundary: memo date == judging moment is NOT expired (< is strict)',
        () async {
      final store = FakeTokenStore()..token = makeJwt();
      final memo = FakePlanMemo()..expiry = kNow;
      final api = FakeApi()..nextBody = balanceBody([]);
      var now = kNow;
      final c = PlanController(
          store: store, api: api.build(), memo: memo, now: () => now);

      await c.ensureLoaded();

      expect(c.expiredOn, isNull); // == now → not expired yet
      now = kNow.add(const Duration(milliseconds: 1));
      expect(c.expiredOn, kNow); // strictly past → expired
    });

    test('a failed refresh never reports an expiry (error is not evidence)',
        () async {
      final store = FakeTokenStore()..token = makeJwt();
      final memo = FakePlanMemo()
        ..expiry = kNow.subtract(const Duration(days: 1));
      final api = FakeApi()..failTransport = true;
      final c = PlanController(
          store: store, api: api.build(), memo: memo, now: () => kNow);

      await c.ensureLoaded();

      expect(c.error, isA<PlanNetworkError>());
      expect(c.expiredOn, isNull);
    });

    test('signOut clears the memo', () async {
      final store = FakeTokenStore()..token = makeJwt();
      final memo = FakePlanMemo()
        ..expiry = kNow.subtract(const Duration(days: 1));
      final api = FakeApi()..nextBody = balanceBody([]);
      final c = PlanController(
          store: store, api: api.build(), memo: memo, now: () => kNow);
      await c.ensureLoaded();
      expect(c.expiredOn, isNotNull);

      await c.signOut();

      expect(memo.clears, 1);
      expect(memo.expiry, isNull);
      expect(c.expiredOn, isNull);
    });

    test('signIn clears the memo (no cross-account leak, R4)', () async {
      final store = FakeTokenStore();
      final memo = FakePlanMemo()
        ..expiry = kNow.subtract(const Duration(days: 1));
      final api = FakeApi()..nextBody = balanceBody([]);
      final c = PlanController(
          store: store, api: api.build(), memo: memo, now: () => kNow);
      await c.ensureLoaded();

      final ok = await c.signIn(makeJwt(userId: 'u-next'));

      expect(ok, isTrue);
      expect(memo.clears, 1);
      expect(memo.expiry, isNull);
      expect(c.expiredOn, isNull);
    });

    test('signInWithOAuth success clears the memo (R4)', () async {
      final store = FakeTokenStore();
      final memo = FakePlanMemo()
        ..expiry = kNow.subtract(const Duration(days: 1));
      final api = FakeApi()..nextBody = balanceBody([]);
      final c = PlanController(
        store: store,
        api: api.build(),
        memo: memo,
        now: () => kNow,
        oauthFactory: () => PlanOAuth(
          client: MockClient((req) async {
            if (req.url.path == '/api/v1/oauth/cli/init') {
              return oauthInitRes();
            }
            return oauthReadyRes(makeJwt(userId: 'u-oauth'));
          }),
          delay: (_) async {},
        ),
      );

      await c.signInWithOAuth();

      expect(store.writes, 1);
      expect(memo.clears, 1);
      expect(memo.expiry, isNull);
      expect(c.expiredOn, isNull);
    });
  });
}
