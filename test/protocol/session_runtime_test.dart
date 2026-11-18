import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/session_runtime.dart';

void main() {
  const scope = {
    'workspacePath': r'F:\Java Code\gdzk-tracker',
    'workspaceIdentity': 'ws-id-1',
  };

  test(
      'initializeWorkspace: request is exactly '
      '[{workspacePath, workspaceIdentity}] on zcode-session', () async {
    final calls = <(String, String, List<Object?>)>[];
    final port = SessionRuntimePort((channel, method, args) async {
      calls.add((channel, method, args));
      return {
        'available': true,
        'workspaceKey': scope['workspacePath'],
        'protocolName': 'ZCode Protocol',
        'protocolVersion': 1,
        'transportKind': 'stdio',
      };
    });

    final result = await port.initializeWorkspace(scope);

    final call = calls.single;
    expect(call.$1, 'zcode-session');
    expect(call.$2, 'initializeWorkspace');
    expect(call.$3, hasLength(1));
    final payload = (call.$3.single as Map).cast<String, Object?>();
    expect(payload.keys.toSet(), {'workspacePath', 'workspaceIdentity'});
    expect(payload, scope);
    expect(result.available, isTrue);
    expect(result.workspaceKey, scope['workspacePath']);
    expect(result.providerNotReady, isFalse);
  });

  test('initializeWorkspace: a scope without identity sends only the path',
      () async {
    final calls = <List<Object?>>[];
    final port = SessionRuntimePort((channel, method, args) async {
      calls.add(args);
      return {'available': true, 'workspaceKey': '/repo/app'};
    });

    await port.initializeWorkspace({'workspacePath': '/repo/app'});

    final payload = (calls.single.single as Map).cast<String, Object?>();
    expect(payload.keys.toSet(), {'workspacePath'});
  });

  test('provider_not_ready is its own verdict, not a transport failure',
      () async {
    final port = SessionRuntimePort(
      (channel, method, args) async => {
        'available': false,
        'reason': 'No model provider is ready.',
        'reasonCode': 'provider_not_ready',
      },
    );

    final result = await port.initializeWorkspace(scope);

    expect(result.available, isFalse);
    expect(result.providerNotReady, isTrue);
    expect(result.reasonCode, 'provider_not_ready');
    expect(result.reason, 'No model provider is ready.');
  });

  test('any other available:false verdict stays a non-provider miss', () async {
    final port = SessionRuntimePort(
      (channel, method, args) async => {
        'available': false,
        'reasonCode': 'workspace_not_found',
      },
    );

    final result = await port.initializeWorkspace(scope);

    expect(result.available, isFalse);
    expect(result.providerNotReady, isFalse);
  });

  test('a non-map answer degrades to not available', () async {
    final port = SessionRuntimePort((channel, method, args) async => null);

    final result = await port.initializeWorkspace(scope);

    expect(result.available, isFalse);
    expect(result.providerNotReady, isFalse);
  });

  test(
      'unknown method raises the degrade signal and is cached for the '
      'session: later calls never reach the wire', () async {
    var calls = 0;
    final port = SessionRuntimePort((channel, method, args) async {
      calls += 1;
      throw ChannelRpcError(
        'Method not found: initializeWorkspace',
        null,
      );
    });

    await expectLater(
      port.initializeWorkspace(scope),
      throwsA(isA<WorkspaceWakeUnavailable>()),
    );
    expect(port.available, isFalse);

    await expectLater(
      port.initializeWorkspace(scope),
      throwsA(isA<WorkspaceWakeUnavailable>()),
    );
    expect(calls, 1, reason: 'the miss is a session-lifetime verdict');
  });

  test('a bare "Method not found" without the method name does NOT degrade',
      () async {
    final port = SessionRuntimePort(
      (channel, method, args) async =>
          throw ChannelRpcError('Method not found', null),
    );

    await expectLater(
      port.initializeWorkspace(scope),
      throwsA(isA<ChannelRpcError>()),
    );
    expect(port.available, isTrue,
        reason: 'over-broad wording must not disable the wake');
  });

  test('validation / transport errors rethrow untouched and do not cache',
      () async {
    var calls = 0;
    final port = SessionRuntimePort((channel, method, args) async {
      calls += 1;
      throw StateError('bridge unhealthy');
    });

    await expectLater(
      port.initializeWorkspace(scope),
      throwsA(isA<StateError>()),
    );
    expect(port.available, isTrue);
    await expectLater(
      port.initializeWorkspace(scope),
      throwsA(isA<StateError>()),
    );
    expect(calls, 2);
  });
}
