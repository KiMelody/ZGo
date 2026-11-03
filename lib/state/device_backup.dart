import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Encrypted device-backup envelope (`.zgobak`), version 2.
///
/// Pure Dart — no UI, no platform channels — so every target (including
/// ohos) runs the same codec. The passphrase, plaintext payload, derived
/// key and account token must never reach a log, an exception message or a
/// plaintext file (all failures surface as [BackupException] kinds).
const int kBackupVersion = 2;

/// PBKDF2-HMAC-SHA256 work factor stamped into every v2 envelope. Readers
/// always honour the envelope's own value, so raising it stays compatible
/// with already-exported backups.
const int kBackupIterations = 210000;

const int _saltLength = 16;
const int _nonceLength = 12;
const int _keyLength = 32;
const int _tagBits = 128;
const String _kdfAlgo = 'pbkdf2-hmac-sha256';
const String _cipherAlgo = 'aes-256-gcm';

/// Binds the ciphertext to the format version (cross-format replay guard).
final Uint8List _aad = Uint8List.fromList(utf8.encode('zgo-backup-v2'));

class BackupPayload {
  final List<Map<String, dynamic>> devices;

  /// Account JWT captured at export time; null when the exporter was
  /// signed out (v1 backups never carry one).
  final String? accountToken;

  const BackupPayload({required this.devices, this.accountToken});
}

enum BackupErrorKind {
  /// Not a zgo backup at all (missing app/format markers).
  notBackup,

  /// Written by a newer app (`version > 2`).
  unsupportedVersion,

  /// v2 envelope but no passphrase was supplied.
  passphraseRequired,

  /// GCM tag check failed — wrong passphrase and tampering are
  /// indistinguishable on purpose.
  decryptFailed,

  /// Structurally broken: bad JSON/base64 or unexpected field shapes.
  corrupt,
}

/// Failure of [decodeBackup] / [backupNeedsPassphrase]. [toString] carries
/// only the kind name — never data, a passphrase or a token.
class BackupException implements Exception {
  final BackupErrorKind kind;

  const BackupException(this.kind);

  @override
  String toString() => 'BackupException(${kind.name})';
}

/// Encrypts [payload] into the v2 envelope string.
String encodeBackup(BackupPayload payload, {required String passphrase}) {
  final token = payload.accountToken;
  final plain = utf8.encode(jsonEncode({
    'devices': payload.devices,
    // A blank token is treated as "no account" so it can never produce an
    // envelope that every importer rejects as corrupt.
    'account': token == null || token.isEmpty ? null : {'token': token},
  }));
  final salt = _randomBytes(_saltLength);
  final nonce = _randomBytes(_nonceLength);
  final key = _deriveKey(passphrase, salt, kBackupIterations);
  final cipher = GCMBlockCipher(AESEngine())
    ..init(true, AEADParameters(KeyParameter(key), _tagBits, nonce, _aad));
  final sealed = cipher.process(plain);
  return jsonEncode({
    'app': 'zgo',
    'format': 'devices',
    'version': kBackupVersion,
    'encrypted': true,
    'kdf': {
      'algo': _kdfAlgo,
      'iterations': kBackupIterations,
      'salt': base64Encode(salt),
    },
    'cipher': {
      'algo': _cipherAlgo,
      'nonce': base64Encode(nonce),
    },
    'payload': base64Encode(sealed),
  });
}

/// Decodes a v2 (passphrase-protected) or v1 (plaintext) backup.
BackupPayload decodeBackup(String raw, {String? passphrase}) {
  final env = _envelope(raw);
  final version = _version(env);
  if (version == 1) {
    return BackupPayload(devices: _devicesFrom(env['devices']));
  }
  if (passphrase == null) {
    throw const BackupException(BackupErrorKind.passphraseRequired);
  }
  if (env['encrypted'] != true) {
    throw const BackupException(BackupErrorKind.corrupt);
  }
  final kdf = env['kdf'];
  final cipherInfo = env['cipher'];
  if (kdf is! Map || cipherInfo is! Map) {
    throw const BackupException(BackupErrorKind.corrupt);
  }
  if (kdf['algo'] != _kdfAlgo || cipherInfo['algo'] != _cipherAlgo) {
    throw const BackupException(BackupErrorKind.corrupt);
  }
  final iterations = kdf['iterations'];
  // The work factor is honour-the-envelope for forward compatibility, but a
  // hostile file could demand hours of PBKDF2 before the tag check — cap it
  // well above any plausible future value (10x today's) and fail closed.
  if (iterations is! int || iterations <= 0 || iterations > 2000000) {
    throw const BackupException(BackupErrorKind.corrupt);
  }
  final Uint8List salt;
  final Uint8List nonce;
  final Uint8List sealed;
  try {
    salt = base64Decode(kdf['salt'] as String);
    nonce = base64Decode(cipherInfo['nonce'] as String);
    sealed = base64Decode(env['payload'] as String);
  } on Object {
    throw const BackupException(BackupErrorKind.corrupt);
  }
  if (salt.length != _saltLength || nonce.length != _nonceLength) {
    throw const BackupException(BackupErrorKind.corrupt);
  }

  // Wrong passphrase and tampered ciphertext both fail the GCM tag — one
  // kind, no oracle for an attacker and no internal detail in the message.
  final List<int> plain;
  try {
    final key = _deriveKey(passphrase, salt, iterations);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(false, AEADParameters(KeyParameter(key), _tagBits, nonce, _aad));
    plain = cipher.process(sealed);
  } on Object {
    throw const BackupException(BackupErrorKind.decryptFailed);
  }

  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(plain));
  } on Object {
    throw const BackupException(BackupErrorKind.corrupt);
  }
  if (decoded is! Map) {
    throw const BackupException(BackupErrorKind.corrupt);
  }
  final account = decoded['account'];
  String? token;
  if (account != null) {
    if (account is! Map) {
      throw const BackupException(BackupErrorKind.corrupt);
    }
    final value = account['token'];
    if (value is! String || value.isEmpty) {
      throw const BackupException(BackupErrorKind.corrupt);
    }
    token = value;
  }
  return BackupPayload(
    devices: _devicesFrom(decoded['devices']),
    accountToken: token,
  );
}

/// Whether [raw] is a v2 backup that needs a passphrase (v1 returns false).
/// A malformed envelope throws [BackupException] instead of guessing.
bool backupNeedsPassphrase(String raw) {
  final env = _envelope(raw);
  return _version(env) == kBackupVersion;
}

/// JWT `exp` (seconds) as a [DateTime]; null when absent or unparseable.
DateTime? jwtExpiry(String token) {
  try {
    final parts = token.split('.');
    if (parts.length < 2) return null;
    final payload = base64Url.decode(base64Url.normalize(parts[1]));
    final claims = jsonDecode(utf8.decode(payload));
    if (claims is! Map) return null;
    final exp = claims['exp'];
    if (exp is! num) return null;
    return DateTime.fromMillisecondsSinceEpoch((exp * 1000).round());
  } on Object {
    return null;
  }
}

/// `compute` entry: runs PBKDF2 + AES-GCM off the UI isolate.
///
/// An isolate cannot rethrow a typed [BackupException] (it degrades to a
/// `RemoteError` string), so outcomes are returned as sendable maps:
/// `{ok: true, blob: String}` or `{ok: false, kind: <BackupErrorKind.name>}`.
Map<String, Object?> encodeBackupJob(Map<String, Object?> args) {
  try {
    return {
      'ok': true,
      'blob': encodeBackup(
        BackupPayload(
          devices: List<Map<String, dynamic>>.from(args['devices'] as List),
          accountToken: args['token'] as String?,
        ),
        passphrase: args['passphrase'] as String,
      ),
    };
  } on BackupException catch (e) {
    return {'ok': false, 'kind': e.kind.name};
  } on Object {
    // Defensive: malformed job args must not surface as a raw RemoteError.
    return {'ok': false, 'kind': BackupErrorKind.corrupt.name};
  }
}

/// `compute` entry: counterpart of [encodeBackupJob]. Success carries the
/// device maps and the optional account token; failure carries the kind name.
Map<String, Object?> decodeBackupJob(Map<String, Object?> args) {
  try {
    final payload = decodeBackup(
      args['raw'] as String,
      passphrase: args['passphrase'] as String?,
    );
    return {
      'ok': true,
      'devices': payload.devices,
      'token': payload.accountToken,
    };
  } on BackupException catch (e) {
    return {'ok': false, 'kind': e.kind.name};
  } on Object {
    return {'ok': false, 'kind': BackupErrorKind.corrupt.name};
  }
}

/// Human-copyable random passphrase for a fresh export: 20 characters in
/// four groups of five (dashes make it easy to read off a screen). The
/// alphabet drops look-alikes (I/O/0/1) and the source is [Random.secure].
String generateBackupPassphrase() {
  const alphabet =
      'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
  final random = Random.secure();
  final chars = List<String>.generate(
      20, (_) => alphabet[random.nextInt(alphabet.length)]);
  return '${chars.sublist(0, 5).join()}-${chars.sublist(5, 10).join()}-'
      '${chars.sublist(10, 15).join()}-${chars.sublist(15, 20).join()}';
}

Map<String, dynamic> _envelope(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on Object {
    throw const BackupException(BackupErrorKind.corrupt);
  }
  if (decoded is! Map) {
    throw const BackupException(BackupErrorKind.notBackup);
  }
  final env = Map<String, dynamic>.from(decoded);
  if (env['app'] != 'zgo' || env['format'] != 'devices') {
    throw const BackupException(BackupErrorKind.notBackup);
  }
  return env;
}

int _version(Map<String, dynamic> env) {
  final version = env['version'];
  if (version is! int) {
    throw const BackupException(BackupErrorKind.corrupt);
  }
  if (version > kBackupVersion) {
    throw const BackupException(BackupErrorKind.unsupportedVersion);
  }
  if (version != kBackupVersion && version != 1) {
    throw const BackupException(BackupErrorKind.corrupt);
  }
  return version;
}

List<Map<String, dynamic>> _devicesFrom(Object? value) {
  if (value is! List) {
    throw const BackupException(BackupErrorKind.corrupt);
  }
  final devices = <Map<String, dynamic>>[];
  for (final item in value) {
    if (item is! Map) {
      throw const BackupException(BackupErrorKind.corrupt);
    }
    devices.add(Map<String, dynamic>.from(item));
  }
  return devices;
}

Uint8List _deriveKey(String passphrase, Uint8List salt, int iterations) {
  final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(salt, iterations, _keyLength));
  return derivator.process(utf8.encode(passphrase));
}

Uint8List _randomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)));
}
