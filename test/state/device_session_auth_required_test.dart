import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/connection_params.dart';
import 'package:zgo/protocol/remote_client.dart';
import 'package:zgo/state/device_session.dart';

RemoteConnectionParams v2Params() => RemoteConnectionParams.parse(
  'https://zcode.z.ai/remote/v4?sid=s&mid=m&name=desk&app_version=3.16.2',
)!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('V2 session without a jwtProvider fails fast as auth-required', () async {
    final session = DeviceSession(
      deviceId: 'd1',
      params: v2Params(),
    );

    await session.connect();

    expect(session.status, DeviceStatus.error);
    expect(session.failureReason, 'auth-required');
    expect(session.kicked, isFalse);
    expect(session.error, contains('auth-required'));
    await session.dispose();
  });

  test('V2 session whose provider has no token surfaces auth-required',
      () async {
    final session = DeviceSession(
      deviceId: 'd2',
      params: v2Params(),
      jwtProvider: () async => null,
    );

    await session.connect().timeout(const Duration(seconds: 5));
    // The failure arrives on the relay's broadcast stream just after the
    // throwing start() — let it land.
    await pumpEventQueue();

    expect(session.status, DeviceStatus.error);
    expect(session.failureReason, 'auth-required');
    expect(session.kicked, isFalse);
    await session.dispose();
  });

  test('V1 session keeps working without the V2 seam', () async {
    // A V1 link never touches jwtProvider: a stub client proves the
    // pre-check only fires for params.v2.
    final params = RemoteConnectionParams.parse(
      'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=1&mid=m',
    )!;
    var created = 0;
    final session = DeviceSession(
      deviceId: 'd3',
      params: params,
      clientFactory: () {
        created += 1;
        return _NoopClient(params);
      },
    );
    await session.connect();
    expect(created, 1);
    expect(session.failureReason, isNot('auth-required'));
    await session.dispose();
  });
}

/// Minimal V1 client: connect/waits answer immediately; bootstrap returns an
/// empty overview so connect's auto-open is skipped.
class _NoopClient extends RemoteClient {
  _NoopClient(super.params);

  @override
  Future<void> connect() => Future.value();

  @override
  Future<void> waitPaired({Duration timeout = const Duration(seconds: 60)}) =>
      Future.value();

  @override
  Future<Map<String, dynamic>> bootstrap() async => const {
    'workspaces': <Object>[],
    'tasks': <Object>[],
  };

  @override
  Future<void> dispose() => Future.value();
}
