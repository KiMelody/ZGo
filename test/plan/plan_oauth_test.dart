import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:zgo/plan/plan_oauth.dart';

const jwt =
    'eyJhbGciOiJFUzI1NiJ9.eyJ1c2VyX2lkIjoidS0xIn0.signature-of-255-characters';
const zaiAccessToken = 'zai-access-token-must-not-be-captured';
const flowId = 'flow-abc123';
const pollToken = 'poll-token-64-hex-from-init';

/// Fixed clock base; `initData` derives `expires_at` from it.
final baseTime = DateTime.fromMillisecondsSinceEpoch(1790000000 * 1000);

http.Response jsonRes(Object body, {int status = 200}) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});

Map<String, dynamic> initData({
  int expiresInSeconds = 60,
  int intervalSec = 2,
}) =>
    {
      'flow_id': flowId,
      'poll_token': pollToken,
      'authorize_url':
          'https://chat.z.ai/oauth/authorize?client_id=client_P8X5&state=s',
      'expires_at': 1790000000 + expiresInSeconds,
      'poll_interval_sec': intervalSec,
    };

Map<String, dynamic> pendingData() => {'status': 'pending'};

Map<String, dynamic> readyData() => {
      'status': 'ready',
      'token': jwt,
      'user': {
        'user_id': 'u-1',
        'email': 'user@example.com',
        'name': 'User',
        'avatar': 'https://example.com/a.png',
      },
      'zai': {'access_token': zaiAccessToken},
    };

/// A mock transport splitting `cli/init` from `cli/poll`; poll frames pop
/// [pollFrames] in order (a non-[http.Response] frame is thrown, i.e. a
/// transport error).
MockClient mockFlow({
  Future<http.Response> Function(http.Request)? onInit,
  required List<Object> pollFrames,
  void Function(http.Request)? onPoll,
}) =>
    MockClient((req) async {
      if (req.url.path == '/api/v1/oauth/cli/init') {
        return await onInit?.call(req) ??
            jsonRes({'code': 0, 'data': initData()});
      }
      onPoll?.call(req);
      final frame = pollFrames.removeAt(0);
      if (frame is http.Response) return frame;
      throw frame;
    });

/// Scripted ready/pending bodies for the poll queue.
http.Response readyRes() => jsonRes({'code': 0, 'data': readyData()});
http.Response pendingRes() => jsonRes({'code': 0, 'data': pendingData()});

PlanOAuth oauthOf(
  MockClient client, {
  DateTime Function()? now,
  Future<void> Function(Duration)? delay,
  void Function(String url)? onUrl,
}) =>
    PlanOAuth(
      client: client,
      now: now ?? () => baseTime,
      delay: delay ?? (_) async {},
    );

void main() {
  group('init', () {
    test('posts the probe-certified wire shape and yields the URL', () async {
      http.Request? initReq;
      final oauth = oauthOf(
        MockClient((req) async {
          if (req.url.path == '/api/v1/oauth/cli/init') {
            initReq = req;
            return jsonRes({'code': 0, 'data': initData()});
          }
          return readyRes();
        }),
      );

      String? authorizeUrl;
      final outcome =
          await oauth.start(onAuthorizeUrl: (url) => authorizeUrl = url);

      expect(initReq, isNotNull);
      expect(initReq!.method, 'POST');
      expect(initReq!.url.path, '/api/v1/oauth/cli/init');
      // Client-generated bearer: 32 random bytes as hex.
      expect(initReq!.headers['authorization'],
          matches(RegExp(r'^Bearer [0-9a-f]{64}$')));
      expect(initReq!.headers['content-type'], contains('application/json'));
      expect(jsonDecode(initReq!.body), {'provider': 'zai'});
      // Server-built URL, handed out exactly once, verbatim.
      expect(authorizeUrl, initData()['authorize_url']);
      final success = outcome as PlanOAuthSuccess;
      expect(success.token, jwt);
      expect(success.user.email, 'user@example.com');
      expect(success.user.userId, 'u-1');
    });

    test('non-200 init maps to flowRejected', () async {
      final oauth = oauthOf(MockClient(
        (req) async => jsonRes({'code': 401}, status: 401),
      ));
      final outcome =
          await oauth.start(onAuthorizeUrl: (_) => fail('no URL expected'));
      expect(outcome, isA<PlanOAuthFailed>());
      expect((outcome as PlanOAuthFailed).reason,
          PlanOAuthFailureReason.flowRejected);
    });

    test('non-zero envelope init maps to flowRejected', () async {
      final oauth = oauthOf(MockClient(
        (req) async => jsonRes({'code': 1001, 'msg': 'denied'}),
      ));
      final outcome =
          await oauth.start(onAuthorizeUrl: (_) => fail('no URL expected'));
      expect((outcome as PlanOAuthFailed).reason,
          PlanOAuthFailureReason.flowRejected);
    });

    test('init transport failure maps to network', () async {
      final oauth = oauthOf(MockClient((req) async {
        throw http.ClientException('offline');
      }));
      final outcome =
          await oauth.start(onAuthorizeUrl: (_) => fail('no URL expected'));
      expect(
          (outcome as PlanOAuthFailed).reason, PlanOAuthFailureReason.network);
    });

    test('snake_case drift on required fields maps to flowRejected', () async {
      final bad = initData()..remove('poll_token');
      final oauth = oauthOf(MockClient(
        (req) async => jsonRes({'code': 0, 'data': bad}),
      ));
      final outcome =
          await oauth.start(onAuthorizeUrl: (_) => fail('no URL expected'));
      expect((outcome as PlanOAuthFailed).reason,
          PlanOAuthFailureReason.flowRejected);
    });
  });

  group('poll', () {
    test('sends bearer poll_token to the flow path', () async {
      final polls = <http.Request>[];
      final oauth = oauthOf(mockFlow(
        pollFrames: [readyRes()],
        onPoll: polls.add,
      ));
      await oauth.start(onAuthorizeUrl: (_) {});

      expect(polls, hasLength(1));
      expect(polls.single.method, 'GET');
      expect(polls.single.url.path, '/api/v1/oauth/cli/poll/$flowId');
      expect(polls.single.headers['authorization'], 'Bearer $pollToken');
    });

    test('pending frames keep polling at the certified interval', () async {
      final sleeps = <Duration>[];
      final oauth = oauthOf(
        mockFlow(pollFrames: [pendingRes(), pendingRes(), readyRes()]),
        delay: (d) async => sleeps.add(d),
      );
      final outcome = await oauth.start(onAuthorizeUrl: (_) {});

      expect(outcome, isA<PlanOAuthSuccess>());
      expect(sleeps, [const Duration(seconds: 2), const Duration(seconds: 2)]);
    });

    test('honours poll_interval_sec from the server', () async {
      final sleeps = <Duration>[];
      final oauth = oauthOf(
        MockClient((req) async {
          if (req.url.path == '/api/v1/oauth/cli/init') {
            return jsonRes({'code': 0, 'data': initData(intervalSec: 5)});
          }
          if (sleeps.isEmpty) return pendingRes();
          return readyRes();
        }),
        delay: (d) async => sleeps.add(d),
      );
      await oauth.start(onAuthorizeUrl: (_) {});

      expect(sleeps, [const Duration(seconds: 5)]);
    });

    test('any other 4xx rejects the flow', () async {
      final oauth = oauthOf(mockFlow(
        pollFrames: [jsonRes({'code': 3001}, status: 400)],
      ));
      final outcome = await oauth.start(onAuthorizeUrl: (_) {});
      expect((outcome as PlanOAuthFailed).reason,
          PlanOAuthFailureReason.flowRejected);
    });

    test('408 is a retryable hiccup', () async {
      final sleeps = <Duration>[];
      final oauth = oauthOf(
        mockFlow(pollFrames: [http.Response('', 408), readyRes()]),
        delay: (d) async => sleeps.add(d),
      );
      final outcome = await oauth.start(onAuthorizeUrl: (_) {});
      expect(outcome, isA<PlanOAuthSuccess>());
      expect(sleeps, hasLength(1));
    });

    test('429 is a retryable hiccup', () async {
      final oauth = oauthOf(mockFlow(
        pollFrames: [http.Response('', 429), readyRes()],
      ));
      expect(await oauth.start(onAuthorizeUrl: (_) {}), isA<PlanOAuthSuccess>());
    });

    test('5xx is a retryable hiccup', () async {
      final oauth = oauthOf(mockFlow(
        pollFrames: [http.Response('boom', 500), readyRes()],
      ));
      expect(await oauth.start(onAuthorizeUrl: (_) {}), isA<PlanOAuthSuccess>());
    });

    test('transport errors keep polling', () async {
      var first = true;
      final oauth = oauthOf(MockClient((req) async {
        if (req.url.path == '/api/v1/oauth/cli/init') {
          return jsonRes({'code': 0, 'data': initData()});
        }
        if (first) {
          first = false;
          throw http.ClientException('dropped');
        }
        return readyRes();
      }));
      final outcome = await oauth.start(onAuthorizeUrl: (_) {});
      expect(outcome, isA<PlanOAuthSuccess>());
    });

    test('ready terminal carries only data.token, never zai.access_token',
        () async {
      final oauth = oauthOf(mockFlow(pollFrames: [readyRes()]));
      final outcome = await oauth.start(onAuthorizeUrl: (_) {});

      final success = outcome as PlanOAuthSuccess;
      expect(success.token, jwt);
      // Guard: the zai-plane credential and the poll token never surface
      // in toString (default instance rendering carries no fields).
      expect(success.toString(), isNot(contains(zaiAccessToken)));
      expect(success.toString(), isNot(contains(pollToken)));
    });
  });

  group('termination', () {
    test('times out when expires_at passes while pending', () async {
      var current = baseTime;
      final polls = <http.Request>[];
      final oauth = oauthOf(
        mockFlow(
          pollFrames: [pendingRes()],
          onPoll: polls.add,
        ),
        // Advance past expires_at during the post-pending wait.
        delay: (d) async =>
            current = current.add(const Duration(seconds: 61)),
        now: () => current,
      );
      final outcome = await oauth.start(onAuthorizeUrl: (_) {});

      expect((outcome as PlanOAuthFailed).reason,
          PlanOAuthFailureReason.timeout);
      expect(polls, hasLength(1)); // no frame past the deadline
    });

    test('cancel mid-wait settles with userCancelled', () async {
      final polls = <http.Request>[];
      late final PlanOAuth oauth;
      oauth = oauthOf(
        mockFlow(pollFrames: [pendingRes()], onPoll: polls.add),
        delay: (_) async => oauth.cancel(),
      );
      final outcome = await oauth.start(onAuthorizeUrl: (_) {});

      expect((outcome as PlanOAuthFailed).reason,
          PlanOAuthFailureReason.userCancelled);
      expect(polls, hasLength(1));
    });

    test('cancel before start settles immediately', () async {
      final requests = <http.Request>[];
      final oauth = oauthOf(MockClient((req) async {
        requests.add(req);
        return jsonRes({'code': 0, 'data': initData()});
      }));
      oauth.cancel();
      final outcome = await oauth.start(onAuthorizeUrl: (_) {});

      expect((outcome as PlanOAuthFailed).reason,
          PlanOAuthFailureReason.userCancelled);
      expect(requests, isEmpty);
    });

    test('failure outcomes never embed wire secrets', () async {
      final oauth = oauthOf(mockFlow(
        pollFrames: [jsonRes({'code': 403}, status: 403)],
      ));
      final outcome = await oauth.start(onAuthorizeUrl: (_) {});

      final text = outcome.toString();
      expect(text, isNot(contains(jwt)));
      expect(text, isNot(contains(pollToken)));
      expect(text, isNot(contains(zaiAccessToken)));
    });

    test('start is single-use', () async {
      final oauth = oauthOf(mockFlow(pollFrames: [readyRes()]));
      await oauth.start(onAuthorizeUrl: (_) {});
      expect(
        () => oauth.start(onAuthorizeUrl: (_) {}),
        throwsStateError,
      );
    });
  });
}
