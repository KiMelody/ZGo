import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/state/device_backup.dart';

const _passphrase = 'correct horse battery';

final _devices = <Map<String, dynamic>>[
  {
    'id': 'd-1',
    'label': '工作室',
    'url': 'https://zc.example/r/sid-1?hash=abc&t=def',
    'addedAt': 1757836800000,
    'sortOrder': 0,
  },
  {
    'id': 'd-2',
    'label': 'tablet',
    'url': 'https://zc.example/r/sid-2',
    'addedAt': 1757836900000,
    'lastUsedAt': 1757837000000,
    'useCount': 3,
    'pinned': true,
    'sortOrder': 1,
  },
];

String _token({int exp = 1795000000}) {
  final payload = base64Url.encode(utf8.encode(jsonEncode({
    'user_id': 'user-42',
    'exp': exp,
  })));
  return 'aaa.$payload.sig';
}

Map<String, dynamic> _envelope(String raw) =>
    jsonDecode(raw) as Map<String, dynamic>;

Matcher _throwsBackup(BackupErrorKind kind) => throwsA(
      isA<BackupException>().having((e) => e.kind, 'kind', kind),
    );

void main() {
  late String blob;

  setUpAll(() {
    blob = encodeBackup(
      BackupPayload(devices: _devices, accountToken: _token()),
      passphrase: _passphrase,
    );
  });

  group('v2 roundtrip', () {
    test('carries the device list and the account token', () {
      final payload = decodeBackup(blob, passphrase: _passphrase);

      expect(payload.devices, _devices);
      expect(payload.accountToken, _token());
    });

    test('a signed-out export roundtrips with a null account', () {
      final raw = encodeBackup(
        BackupPayload(devices: _devices),
        passphrase: _passphrase,
      );

      final payload = decodeBackup(raw, passphrase: _passphrase);

      expect(payload.devices, _devices);
      expect(payload.accountToken, isNull);
    });

    test('envelope stamps format, version and crypto parameters', () {
      final env = _envelope(blob);
      final kdf = env['kdf'] as Map<String, dynamic>;
      final cipher = env['cipher'] as Map<String, dynamic>;

      expect(env['app'], 'zgo');
      expect(env['format'], 'devices');
      expect(env['version'], kBackupVersion);
      expect(env['version'], 2);
      expect(env['encrypted'], isTrue);
      expect(kdf['algo'], 'pbkdf2-hmac-sha256');
      expect(kdf['iterations'], kBackupIterations);
      expect(kdf['iterations'], 210000);
      expect(base64Decode(kdf['salt'] as String), hasLength(16));
      expect(cipher['algo'], 'aes-256-gcm');
      expect(base64Decode(cipher['nonce'] as String), hasLength(12));
    });

    test('every export draws a fresh salt, nonce and ciphertext', () {
      final a = _envelope(encodeBackup(
        BackupPayload(devices: _devices, accountToken: _token()),
        passphrase: _passphrase,
      ));
      final b = _envelope(encodeBackup(
        BackupPayload(devices: _devices, accountToken: _token()),
        passphrase: _passphrase,
      ));

      expect((a['kdf'] as Map)['salt'], isNot((b['kdf'] as Map)['salt']));
      expect((a['cipher'] as Map)['nonce'], isNot((b['cipher'] as Map)['nonce']));
      expect(a['payload'], isNot(b['payload']));
    });
  });

  group('v2 failures', () {
    test('a wrong passphrase fails the tag check', () {
      expect(
        () => decodeBackup(blob, passphrase: 'wrong horse battery'),
        _throwsBackup(BackupErrorKind.decryptFailed),
      );
    });

    test('an omitted passphrase is reported before any KDF work', () {
      expect(
        () => decodeBackup(blob),
        _throwsBackup(BackupErrorKind.passphraseRequired),
      );
    });

    test('tampered ciphertext fails the tag check', () {
      final env = _envelope(blob);
      final sealed = base64Decode(env['payload'] as String);
      sealed[sealed.length ~/ 2] ^= 0x01;
      env['payload'] = base64Encode(sealed);

      expect(
        () => decodeBackup(jsonEncode(env), passphrase: _passphrase),
        _throwsBackup(BackupErrorKind.decryptFailed),
      );
    });

    test('a tampered salt derives a different key and fails the tag check',
        () {
      final env = _envelope(blob);
      final kdf = env['kdf'] as Map<String, dynamic>;
      final salt = base64Decode(kdf['salt'] as String);
      salt[0] ^= 0x01;
      kdf['salt'] = base64Encode(salt);

      expect(
        () => decodeBackup(jsonEncode(env), passphrase: _passphrase),
        _throwsBackup(BackupErrorKind.decryptFailed),
      );
    });

    test('broken base64 in payload, salt or nonce is corrupt', () {
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (env) => env['payload'] = '!!!not-base64!!!',
        (env) => (env['kdf'] as Map)['salt'] = '!!!not-base64!!!',
        (env) => (env['cipher'] as Map)['nonce'] = '!!!not-base64!!!',
      ]) {
        final env = _envelope(blob);
        mutate(env);
        expect(
          () => decodeBackup(jsonEncode(env), passphrase: _passphrase),
          _throwsBackup(BackupErrorKind.corrupt),
        );
      }
    });

    test('wrong salt/nonce lengths and a v2 envelope without encryption '
        'are corrupt', () {
      final shortSalt = _envelope(blob);
      (shortSalt['kdf'] as Map)['salt'] = base64Encode(List<int>.filled(8, 1));
      expect(
        () => decodeBackup(jsonEncode(shortSalt), passphrase: _passphrase),
        _throwsBackup(BackupErrorKind.corrupt),
      );

      final shortNonce = _envelope(blob);
      (shortNonce['cipher'] as Map)['nonce'] =
          base64Encode(List<int>.filled(8, 1));
      expect(
        () => decodeBackup(jsonEncode(shortNonce), passphrase: _passphrase),
        _throwsBackup(BackupErrorKind.corrupt),
      );

      final plainFlag = _envelope(blob)..remove('encrypted');
      expect(
        () => decodeBackup(jsonEncode(plainFlag), passphrase: _passphrase),
        _throwsBackup(BackupErrorKind.corrupt),
      );
    });

    test('an absurd KDF work factor is refused before key derivation', () {
      final env = _envelope(blob);
      (env['kdf'] as Map)['iterations'] = 50000000;

      expect(
        () => decodeBackup(jsonEncode(env), passphrase: _passphrase),
        _throwsBackup(BackupErrorKind.corrupt),
      );
    });

    test('a future version is unsupported, not corrupt', () {
      final env = _envelope(blob)..['version'] = kBackupVersion + 1;

      expect(
        () => decodeBackup(jsonEncode(env), passphrase: _passphrase),
        _throwsBackup(BackupErrorKind.unsupportedVersion),
      );
      expect(
        () => backupNeedsPassphrase(jsonEncode(env)),
        _throwsBackup(BackupErrorKind.unsupportedVersion),
      );
    });

    test('a non-integer version is corrupt', () {
      final env = _envelope(blob)..['version'] = '2';

      expect(
        () => decodeBackup(jsonEncode(env), passphrase: _passphrase),
        _throwsBackup(BackupErrorKind.corrupt),
      );
    });
  });

  group('v1 compatibility', () {
    String v1() => jsonEncode({
          'app': 'zgo',
          'format': 'devices',
          'version': 1,
          'exportedAt': '2026-11-03T10:00:00.000',
          'devices': _devices,
        });

    test('a plaintext backup decodes without a passphrase or account', () {
      final payload = decodeBackup(v1());

      expect(payload.devices, _devices);
      expect(payload.accountToken, isNull);
    });

    test('an explicit passphrase is ignored for v1', () {
      expect(decodeBackup(v1(), passphrase: _passphrase).devices, _devices);
    });

    test('backupNeedsPassphrase: v2 true, v1 false', () {
      expect(backupNeedsPassphrase(blob), isTrue);
      expect(backupNeedsPassphrase(v1()), isFalse);
    });
  });

  group('rejections', () {
    test('bad JSON is corrupt', () {
      expect(() => decodeBackup('{'), _throwsBackup(BackupErrorKind.corrupt));
      expect(
        () => backupNeedsPassphrase('{'),
        _throwsBackup(BackupErrorKind.corrupt),
      );
    });

    test('JSON without the zgo device markers is not a backup', () {
      for (final raw in [
        '{"hello":1}',
        '[]',
        '"zgo"',
        '{"app":"zgo","format":"chat","version":2}',
        '{"app":"other","format":"devices","version":2}',
      ]) {
        expect(
          () => decodeBackup(raw, passphrase: _passphrase),
          _throwsBackup(BackupErrorKind.notBackup),
        );
        expect(
          () => backupNeedsPassphrase(raw),
          _throwsBackup(BackupErrorKind.notBackup),
        );
      }
    });
  });

  group('jwtExpiry', () {
    test('decodes the exp claim as seconds', () {
      expect(
        jwtExpiry(_token(exp: 1795000000)),
        DateTime.fromMillisecondsSinceEpoch(1795000000000),
      );
    });

    test('a token without exp yields null', () {
      final payload = base64Url.encode(utf8.encode('{"user_id":"u"}'));
      expect(jwtExpiry('aaa.$payload.sig'), isNull);
    });

    test('garbage tokens yield null instead of throwing', () {
      for (final token in [
        '',
        'not-a-jwt',
        'aaa.!!!.sig',
        'a.${base64Url.encode(utf8.encode('[]'))}.c',
        'a.${base64Url.encode(utf8.encode('{"exp":"soon"}'))}.c',
      ]) {
        expect(jwtExpiry(token), isNull);
      }
    });
  });

  group('isolate entry points', () {
    test('encodeBackupJob -> decodeBackupJob roundtrips', () {
      final encoded = encodeBackupJob({
        'devices': _devices,
        'token': _token(),
        'passphrase': _passphrase,
      });

      expect(encoded['ok'], isTrue);
      final decoded = decodeBackupJob({
        'raw': encoded['blob'] as String,
        'passphrase': _passphrase,
      });

      expect(decoded['ok'], isTrue);
      expect(decoded['devices'], _devices);
      expect(decoded['token'], _token());
    });

    test('a wrong passphrase surfaces as a kind name, not an exception', () {
      final encoded = encodeBackupJob({
        'devices': _devices,
        'token': null,
        'passphrase': _passphrase,
      });

      final decoded = decodeBackupJob({
        'raw': encoded['blob'] as String,
        'passphrase': 'not-the-passphrase',
      });

      expect(decoded['ok'], isFalse);
      expect(decoded['kind'], BackupErrorKind.decryptFailed.name);
    });
  });

  group('passphrase generation', () {
    test('produces four dashed groups of five unambiguous characters', () {
      final pass = generateBackupPassphrase();
      final groups = pass.split('-');

      expect(groups, hasLength(4));
      for (final group in groups) {
        expect(group, hasLength(5));
        expect(RegExp(r'^[A-HJ-NP-Za-km-z2-9]+$').hasMatch(group), isTrue,
            reason: 'look-alikes I/O/0/1 must be excluded: $group');
      }
    });

    test('two calls never return the same passphrase', () {
      final values = List.generate(50, (_) => generateBackupPassphrase());
      expect(values.toSet(), hasLength(values.length));
    });

    test('a generated passphrase round-trips a backup', () {
      final pass = generateBackupPassphrase();
      final blob = encodeBackup(
        BackupPayload(devices: _devices, accountToken: _token()),
        passphrase: pass,
      );

      expect(decodeBackup(blob, passphrase: pass).devices, _devices);
      expect(
        () => decodeBackup(blob, passphrase: 'wrong-passphrase'),
        _throwsBackup(BackupErrorKind.decryptFailed),
      );
    });
  });

  test('exception text carries only the kind name', () {
    expect(
      const BackupException(BackupErrorKind.decryptFailed).toString(),
      'BackupException(decryptFailed)',
    );
  });
}
