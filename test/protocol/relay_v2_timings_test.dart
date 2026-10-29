import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/connection_params.dart';
import 'package:zgo/protocol/relay_v2.dart';

RemoteConnectionParams paramsOf() => RemoteConnectionParams.parse(
      'https://zcode.z.ai/remote/v4?sid=s&mid=m&name=test&app_version=3.16.2',
    )!;

void main() {
  test('V2 production timings stay at 10/15/15/20', () async {
    final transport = RelayV2Transport(paramsOf());
    expect(transport.heartbeatInterval, const Duration(seconds: 10));
    expect(transport.heartbeatTimeout, const Duration(seconds: 15),
        reason: 'the live-probed 15s default must stay explicit');
    expect(transport.authAckTimeout, const Duration(seconds: 15));
    expect(transport.reconnectWaitTimeout, const Duration(seconds: 20));
    await transport.dispose();
  });

  test('V2 reconnect backoff keeps the 8-attempt / 60s tier', () {
    expect(RelayV2Transport.reconnectDelay(0), const Duration(seconds: 1));
    expect(RelayV2Transport.reconnectDelay(4), const Duration(seconds: 15));
    expect(RelayV2Transport.reconnectDelay(7), const Duration(seconds: 15));
    expect(RelayV2Transport.reconnectDelay(8), const Duration(seconds: 60));
    expect(RelayV2Transport.reconnectDelay(20), const Duration(seconds: 60));
  });
}
