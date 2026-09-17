import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/protocol/connection_params.dart';

void main() {
  group('uriSchemeIsSecure', () {
    test('https → secure', () {
      final params = RemoteConnectionParams(
        deviceSid: 'sid',
        passHash: 'hash',
        timestamp: 1,
        source: Uri.parse('https://zcode.z.ai/remote'),
      );
      expect(params.uriSchemeIsSecure, isTrue);
    });

    test('wss → secure', () {
      final params = RemoteConnectionParams(
        deviceSid: 'sid',
        passHash: 'hash',
        timestamp: 1,
        source: Uri.parse('wss://zcode.z.ai/ws'),
      );
      expect(params.uriSchemeIsSecure, isTrue);
    });

    test('http → not secure', () {
      final params = RemoteConnectionParams(
        deviceSid: 'sid',
        passHash: 'hash',
        timestamp: 1,
        source: Uri.parse('http://zcode.z.ai/remote'),
      );
      expect(params.uriSchemeIsSecure, isFalse);
    });

    test('ws → not secure', () {
      final params = RemoteConnectionParams(
        deviceSid: 'sid',
        passHash: 'hash',
        timestamp: 1,
        source: Uri.parse('ws://zcode.z.ai/ws'),
      );
      expect(params.uriSchemeIsSecure, isFalse);
    });

    test('ftp → not secure (was bug)', () {
      final params = RemoteConnectionParams(
        deviceSid: 'sid',
        passHash: 'hash',
        timestamp: 1,
        source: Uri.parse('ftp://bad.example.com/remote'),
      );
      expect(params.uriSchemeIsSecure, isFalse);
    });

    test('unknown scheme → not secure', () {
      final params = RemoteConnectionParams(
        deviceSid: 'sid',
        passHash: 'hash',
        timestamp: 1,
        source: Uri.parse('file:///etc/passwd'),
      );
      expect(params.uriSchemeIsSecure, isFalse);
    });
  });

  group('relayWsUri', () {
    test('https → wss', () {
      final params = RemoteConnectionParams.parse(
        'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=1&mid=m',
      );
      expect(params!.relayWsUri.toString(), 'wss://zcode.z.ai/ws?mid=m');
    });

    test('http → ws', () {
      final params = RemoteConnectionParams.parse(
        'http://localhost:3000/remote/v4?sid=s&hash=h&t=1',
      );
      expect(params!.relayWsUri.toString(), 'ws://localhost:3000/ws');
    });

    test('port is preserved', () {
      final params = RemoteConnectionParams.parse(
        'https://zcode.z.ai:8443/remote/v4?sid=s&hash=h&t=1',
      );
      expect(params!.relayWsUri.toString(), 'wss://zcode.z.ai:8443/ws');
    });

    test('no mid → no query params', () {
      final params = RemoteConnectionParams.parse(
        'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=1',
      );
      expect(params!.relayWsUri.toString(), 'wss://zcode.z.ai/ws');
    });
  });

  group('parse edge cases', () {
    test('missing sid returns null', () {
      expect(
        RemoteConnectionParams.parse(
            'https://zcode.z.ai/remote/v4?hash=h&t=1'),
        isNull,
      );
    });

    test('missing hash returns null', () {
      expect(
        RemoteConnectionParams.parse(
            'https://zcode.z.ai/remote/v4?sid=s&t=1'),
        isNull,
      );
    });

    test('missing t returns null', () {
      expect(
        RemoteConnectionParams.parse(
            'https://zcode.z.ai/remote/v4?sid=s&hash=h'),
        isNull,
      );
    });

    test('invalid timestamp returns null', () {
      expect(
        RemoteConnectionParams.parse(
            'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=abc'),
        isNull,
      );
    });

    test('trimmed query values', () {
      final params = RemoteConnectionParams.parse(
        'https://zcode.z.ai/remote/v4?sid= SID &hash= HASH &t=1',
      );
      expect(params, isNotNull);
      expect(params!.deviceSid, 'SID');
      expect(params.passHash, 'HASH');
    });

    test('empty optional fields are null', () {
      final params = RemoteConnectionParams.parse(
        'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=1&mid=&name=',
      );
      expect(params!.deviceMid, isNull);
      expect(params.deviceName, isNull);
    });

    test('theme is parsed', () {
      final params = RemoteConnectionParams.parse(
        'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=1&theme=dark',
      );
      expect(params!.theme, 'dark');
    });
  });

  group('atLeast', () {
    RemoteConnectionParams withVersion(String? v) => RemoteConnectionParams(
          deviceSid: 'sid',
          passHash: 'hash',
          timestamp: 1,
          source: Uri.parse('https://zcode.z.ai/remote/v4'),
          appVersion: v,
        );

    test('exact version → true', () {
      expect(withVersion('3.12.3').atLeast(3, 12, 3), isTrue);
    });

    test('higher patch/minor/major → true', () {
      expect(withVersion('3.12.4').atLeast(3, 12, 3), isTrue);
      expect(withVersion('3.13.0').atLeast(3, 12, 3), isTrue);
      expect(withVersion('4.0.0').atLeast(3, 12, 3), isTrue);
    });

    test('lower → false', () {
      expect(withVersion('3.12.2').atLeast(3, 12, 3), isFalse);
      expect(withVersion('3.11.9').atLeast(3, 12, 3), isFalse);
      expect(withVersion('2.99.99').atLeast(3, 12, 3), isFalse);
    });

    test('two segments pad with zero', () {
      expect(withVersion('3.12').atLeast(3, 12, 0), isTrue);
      expect(withVersion('3.12').atLeast(3, 12, 1), isFalse);
    });

    test('non-numeric suffix → false (unknown keeps legacy shapes)', () {
      expect(withVersion('3.12.3-beta').atLeast(3, 12, 3), isFalse);
      expect(withVersion('v3.12.3').atLeast(3, 12, 3), isFalse);
    });

    test('absent or garbage → false', () {
      expect(withVersion(null).atLeast(3, 12, 3), isFalse);
      expect(withVersion('').atLeast(3, 12, 3), isFalse);
      expect(withVersion('abc').atLeast(3, 12, 3), isFalse);
    });
  });
}
