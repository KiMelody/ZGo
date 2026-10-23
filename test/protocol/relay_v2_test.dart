import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:zgo/protocol/connection_params.dart';
import 'package:zgo/protocol/relay_transport.dart';
import 'package:zgo/protocol/relay_v2.dart';

/// Deterministic V2 relay harness: a [MockClient] answers the token POST and
/// a fake [RelayV2Socket] records frames + lets the test inject server
/// frames. No real network, no real sockets.
class FakeV2Backend {
  final tokenRequests = <http.Request>[];
  final socketUris = <Uri>[];
  final sockets = <FakeV2Socket>[];
  int _tokenSeq = 0;

  /// A JWT the transport should send as `Authorization: Bearer`.
  static const jwt = 'jwt-from-plan-account';

  http.Client get httpClient => MockClient((request) async {
    tokenRequests.add(request);
    _tokenSeq += 1;
    return http.Response(
      jsonEncode({
        'code': 0,
        'data': {
          'token': 'tok$_tokenSeq',
          'expires_in': 60,
        },
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  });

  RelayV2Socket socketFactory(Uri uri) {
    socketUris.add(uri);
    final socket = FakeV2Socket();
    sockets.add(socket);
    return socket;
  }

  FakeV2Socket get last => sockets.last;
}

class FakeV2Socket implements RelayV2Socket {
  final _incoming = StreamController<dynamic>.broadcast();
  final sent = <String>[];
  final closed = Completer<void>();

  @override
  Future<void> get ready => Future.value();

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  int? closeCode;

  @override
  String? closeReason;

  @override
  void send(String data) => sent.add(data);

  @override
  Future<void> close([int? code, String? reason]) async {
    closeCode = code;
    closeReason = reason;
    if (!closed.isCompleted) closed.complete();
    if (!_incoming.isClosed) await _incoming.close();
  }

  void inject(Map<String, dynamic> frame) => _incoming.add(jsonEncode(frame));

  List<Map<String, dynamic>> get sentFrames => [
    for (final raw in sent) (jsonDecode(raw) as Map).cast<String, dynamic>(),
  ];
}

RemoteConnectionParams v2Params() => RemoteConnectionParams.parse(
  'https://zcode.z.ai/remote/v4?sid=sid-1&mid=mid-1&name=desk&app_version=3.16.2',
)!;

Future<void> pump([int ms = 10]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

Future<void> until(bool Function() condition,
    {int maxMs = 2000, String? because}) async {
  var waited = 0;
  while (!condition()) {
    await pump(5);
    waited += 5;
    if (waited > maxMs) break;
  }
  if (because != null && !condition()) {
    fail('condition not met within ${maxMs}ms: $because');
  }
}

void main() {
  group('RelayV2Transport handshake', () {
    test('start: Bearer token POST, ws2 token/mid query, auth_init', () async {
      final backend = FakeV2Backend();
      final transport = RelayV2Transport(
        v2Params(),
        jwtProvider: () async => FakeV2Backend.jwt,
        httpClient: backend.httpClient,
        webSocketFactory: backend.socketFactory,
        heartbeatInterval: const Duration(seconds: 10),
        heartbeatTimeout: const Duration(seconds: 15),
      );
      final states = <RelayState>[];
      transport.stateListenable.addListener(
        () => states.add(transport.state),
      );

      await transport.start();
      await pump();

      final req = backend.tokenRequests.single;
      expect(req.method, 'POST');
      expect(req.url.toString(), 'https://zcode.z.ai/api/v1/remote/token');
      expect(req.headers['authorization'], 'Bearer ${FakeV2Backend.jwt}');
      expect(jsonDecode(req.body), {'role': 'terminal'});

      expect(
        backend.socketUris.single.toString(),
        'wss://zcode.z.ai/api/v1/remote/ws2?mid=mid-1&token=tok1',
      );
      expect(transport.state, RelayState.authenticating);
      expect(states.first, RelayState.connecting);
      expect(states.last, RelayState.authenticating);

      final authInit = backend.last.sentFrames.first;
      expect(authInit['type'], 'auth_init');
      expect(authInit['device_sid'], 'sid-1');
      final meta = authInit['meta'] as Map;
      expect(meta['platform'], isA<String>());
      expect(meta['version'], '3.16.2');
      expect(meta['name'], 'zgo');
      expect(authInit['client_ts'], isA<int>());
      expect(authInit['role'], isNull,
          reason: 'V2 auth_init carries no V1 role/proof fields');

      await transport.dispose();
    });

    test('auth_ack waiting keeps the link and matched pairs + flushes queue',
        () async {
      final backend = FakeV2Backend();
      final transport = RelayV2Transport(
        v2Params(),
        jwtProvider: () async => FakeV2Backend.jwt,
        httpClient: backend.httpClient,
        webSocketFactory: backend.socketFactory,
      );
      await transport.start();
      await pump();

      backend.last.inject({'type': 'auth_ack', 'pair_status': 'waiting'});
      await pump();
      expect(transport.state, RelayState.waiting,
          reason: 'waiting = desktop offline, the link stays up');

      final payloadSink = <Map<String, dynamic>>[];
      transport.payloads.listen(payloadSink.add);
      transport.sendPayload({'zcode_type': 'bootstrap-request'});
      await pump();
      expect(
        backend.last.sentFrames.where(
          (f) =>
              f['type'] == 'data' &&
              (f['payload'] as Map?)?['zcode_type'] == 'bootstrap-request',
        ),
        isEmpty,
        reason: 'payloads queue while unpaired',
      );

      backend.last.inject({
        'type': 'auth_ack',
        'pair_status': 'matched',
        'terminal_sid': 't-1',
      });
      await pump();
      expect(transport.state, RelayState.paired);

      final dataFrames = [
        for (final f in backend.last.sentFrames)
          if (f['type'] == 'data' &&
              (f['payload'] as Map?)?['zcode_type'] == 'bootstrap-request')
            f,
      ];
      expect(dataFrames, hasLength(1));
      expect(dataFrames.single['payload'], {'zcode_type': 'bootstrap-request'});
      expect(dataFrames.single.containsKey('client_ts'), isFalse,
          reason: 'V2 data frames are {type, payload} only');

      backend.last.inject({
        'type': 'data',
        'payload': {'zcode_type': 'bootstrap-response', 'requestId': 'r1'},
      });
      await pump();
      expect(payloadSink.single['zcode_type'], 'bootstrap-response');

      await transport.dispose();
    });

    test('missing account JWT fails start with auth-required', () async {
      final backend = FakeV2Backend();
      final transport = RelayV2Transport(
        v2Params(),
        jwtProvider: () async => null,
        httpClient: backend.httpClient,
        webSocketFactory: backend.socketFactory,
      );
      final failures = <RelayFailure>[];
      transport.failures.listen(failures.add);

      await expectLater(
        transport.start(),
        throwsA(
          isA<RelayV2StartException>().having(
            (e) => e.reason,
            'reason',
            'auth-required',
          ),
        ),
      );
      await pump();
      expect(transport.state, RelayState.error);
      expect(failures.single.reason, 'auth-required');
      expect(backend.tokenRequests, isEmpty);
      expect(backend.sockets, isEmpty);

      await transport.dispose();
    });

    test('token endpoint 401 maps to auth-required', () async {
      final transport = RelayV2Transport(
        v2Params(),
        jwtProvider: () async => 'expired-jwt',
        httpClient: MockClient((_) async => http.Response(
          jsonEncode({'code': 401, 'message': 'invalid token'}),
          401,
        )),
        webSocketFactory: FakeV2Backend().socketFactory,
      );
      await expectLater(
        transport.start(),
        throwsA(
          isA<RelayV2StartException>().having(
            (e) => e.reason,
            'reason',
            'auth-required',
          ),
        ),
      );
      await transport.dispose();
    });

    test('ack without pair_status keeps the auth-timeout fallback', () async {
      final backend = FakeV2Backend();
      final transport = RelayV2Transport(
        v2Params(),
        jwtProvider: () async => FakeV2Backend.jwt,
        httpClient: backend.httpClient,
        webSocketFactory: backend.socketFactory,
        // Generous window: under full-suite load the event loop can stall
        // well past 60ms between start() and the injection.
        authAckTimeout: const Duration(milliseconds: 400),
      );
      final failures = <RelayFailure>[];
      transport.failures.listen(failures.add);
      await transport.start();
      await pump();

      backend.last.inject({'type': 'auth_ack'});
      await pump(10);
      expect(transport.state, RelayState.authenticating,
          reason: 'an ack with no pair status settles nothing');

      // The 15s fallback stays armed: the link must not park here forever.
      // Poll the EVENT, not just the state: the state flips synchronously
      // while the failure stream delivers asynchronously, so a state-only
      // poll can race ahead of the list this assertion reads.
      await until(
        () => failures.isNotEmpty,
        maxMs: 2000,
        because: 'the retained auth timer recovers the stuck handshake',
      );
      expect(transport.state, RelayState.error);
      expect(failures.single.reason, 'relay-unavailable');
      await transport.dispose();
    });

    test('a failed ws upgrade never leaks the token into logs/failure',
        () async {
      final backend = FakeV2Backend();
      final logs = <String>[];
      final transport = RelayV2Transport(
        v2Params(),
        jwtProvider: () async => FakeV2Backend.jwt,
        onLog: logs.add,
        httpClient: backend.httpClient,
        // WebSocket upgrade failures echo the full URI, token query included.
        webSocketFactory: (uri) => throw Exception(
          'WebSocketException: Connection to $uri was not upgraded',
        ),
      );
      final failures = <RelayFailure>[];
      transport.failures.listen(failures.add);

      late RelayV2StartException startError;
      try {
        await transport.start();
        fail('start should throw after the failed upgrade');
      } on RelayV2StartException catch (e) {
        startError = e;
      }
      await pump();

      // The fake token endpoint answered `tok1`.
      expect(logs.where((line) => line.contains('tok1')), isEmpty,
          reason: 'log lines are redacted');
      expect(logs.any((line) => line.contains('token=redacted')), isTrue);
      expect(failures.single.message, isNot(contains('tok1')));
      expect(failures.single.message, contains('token=redacted'));
      expect(startError.message, isNot(contains('tok1')));
      expect(startError.message, contains('token=redacted'));
      await transport.dispose();
    });
  });

  group('RelayV2Transport errors', () {
    Future<(FakeV2Backend, RelayV2Transport, List<RelayFailure>)> connected() async {
      final backend = FakeV2Backend();
      final transport = RelayV2Transport(
        v2Params(),
        jwtProvider: () async => FakeV2Backend.jwt,
        httpClient: backend.httpClient,
        webSocketFactory: backend.socketFactory,
      );
      final failures = <RelayFailure>[];
      transport.failures.listen(failures.add);
      await transport.start();
      await pump();
      backend.last.inject({'type': 'auth_ack', 'pair_status': 'matched'});
      await pump();
      return (backend, transport, failures);
    }

    test('KICKED maps to the terminal kicked state', () async {
      final (backend, transport, failures) = await connected();
      backend.last.inject({
        'type': 'error',
        'code': 'KICKED',
        'message': 'another terminal took over',
      });
      await pump();

      expect(transport.state, RelayState.kicked);
      expect(failures.single.reason, 'kicked');
      await transport.dispose();
    });

    test('AUTH_FAILED maps to auth-required', () async {
      final (backend, transport, failures) = await connected();
      backend.last.inject({
        'type': 'error',
        'code': 'AUTH_FAILED',
        'message': 'bad credentials',
      });
      await pump();

      expect(transport.state, RelayState.error);
      expect(failures.single.reason, 'auth-required');
      await transport.dispose();
    });

    test('DEVICE_OFFLINE keeps the link waiting (non-fatal)', () async {
      final (backend, transport, failures) = await connected();
      backend.last.inject({
        'type': 'error',
        'code': 'DEVICE_OFFLINE',
        'message': 'desktop went away',
      });
      await pump();

      expect(failures, isEmpty);
      expect(transport.state, RelayState.waiting);
      await transport.dispose();
    });

    test('DEVICE_OFFLINE before auth_ack goes waiting, not error', () async {
      final backend = FakeV2Backend();
      final transport = RelayV2Transport(
        v2Params(),
        jwtProvider: () async => FakeV2Backend.jwt,
        httpClient: backend.httpClient,
        webSocketFactory: backend.socketFactory,
        // Wide enough that a loaded runner cannot fire it before the
        // DEVICE_OFFLINE injection lands.
        authAckTimeout: const Duration(milliseconds: 300),
        heartbeatInterval: const Duration(milliseconds: 20),
        heartbeatTimeout: const Duration(milliseconds: 500),
      );
      final failures = <RelayFailure>[];
      transport.failures.listen(failures.add);
      await transport.start();
      await pump();
      expect(transport.state, RelayState.authenticating);

      backend.last.inject({
        'type': 'error',
        'code': 'DEVICE_OFFLINE',
        'message': 'desktop went away before auth_ack',
      });
      await pump();

      expect(transport.state, RelayState.waiting);
      expect(failures, isEmpty);

      // The auth fallback must be disarmed: waiting survives past it.
      await pump(400);
      expect(transport.state, RelayState.waiting,
          reason: 'the auth_ack timeout must not fire after DEVICE_OFFLINE');
      expect(failures, isEmpty);

      // The heartbeat keeps polling so a returning desktop can re-pair.
      await until(
        () => backend.last.sentFrames
            .any((f) => f['type'] == 'pair_status_query'),
        because: 'heartbeat polls after DEVICE_OFFLINE',
      );
      backend.last.inject({'type': 'pair_status_ack', 'pair_status': 'matched'});
      await pump();
      expect(transport.state, RelayState.paired);
      await transport.dispose();
    });

    test('unknown codes map to unexpected-error', () async {
      final (backend, transport, failures) = await connected();
      backend.last.inject({'type': 'error', 'code': 'WRONG_PARAM'});
      await pump();

      expect(transport.state, RelayState.error);
      expect(failures.single.reason, 'unexpected-error');
      await transport.dispose();
    });
  });

  group('RelayV2Transport heartbeat + reconnect', () {
    test('sends pair_status_query and reconnects after 15s of silence',
        () async {
      final backend = FakeV2Backend();
      final transport = RelayV2Transport(
        v2Params(),
        jwtProvider: () async => FakeV2Backend.jwt,
        httpClient: backend.httpClient,
        webSocketFactory: backend.socketFactory,
        heartbeatInterval: const Duration(milliseconds: 20),
        heartbeatTimeout: const Duration(milliseconds: 30),
      );
      await transport.start();
      await pump();
      backend.last.inject({'type': 'auth_ack', 'pair_status': 'matched'});
      await pump();

      await until(
        () => backend.last.sentFrames
            .any((f) => f['type'] == 'pair_status_query'),
        because: 'heartbeat query goes out while paired',
      );

      // Stay silent: the heartbeat sees no inbound frame for >30ms and
      // reconnects — the rebuilt link fetches a NEW token (60s TTL).
      await until(
        () => backend.tokenRequests.length >= 2 &&
            backend.socketUris.length >= 2,
        because: 'heartbeat timeout reconnects and refetches the token',
      );
      expect(
        backend.socketUris[1].queryParameters['token'],
        isNot(backend.socketUris[0].queryParameters['token']),
        reason: 'tokens are never reused across (re)connects',
      );

      await transport.dispose();
    });

    test('reconnect after a paired close refetches the token', () async {
      final backend = FakeV2Backend();
      final transport = RelayV2Transport(
        v2Params(),
        jwtProvider: () async => FakeV2Backend.jwt,
        httpClient: backend.httpClient,
        webSocketFactory: backend.socketFactory,
      );
      await transport.start();
      await pump();
      backend.last.inject({'type': 'auth_ack', 'pair_status': 'matched'});
      await pump();

      await backend.last.close(1000, 'server restart');
      // Backoff starts at 1s — wait for the second token fetch.
      await until(
        () => backend.tokenRequests.length >= 2,
        maxMs: 4000,
        because: 'paired close schedules a reconnect with a fresh token',
      );
      expect(backend.socketUris, hasLength(2));

      await transport.dispose();
    });
  });
}
