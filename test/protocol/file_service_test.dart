import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/channel_client.dart';
import 'package:zgo/protocol/file_service.dart';

void main() {
  test('first accepted candidate wins; misses advance in candidate order',
      () async {
    final calls = <String>[];
    final port = FileServicePort((method, args) async {
      calls.add(method);
      if (method == 'readMedia') {
        return {
          'dataBase64': base64Encode([1, 2, 3]),
          'mediaType': 'image/png',
          'size': 3,
        };
      }
      throw ChannelRpcError('no such method: $method', null);
    });

    final res = await port.readMedia('/repo', 'a.png');
    // readMediaPreview / mediaPreview miss (bundle names first), readMedia answers
    expect(calls, ['readMediaPreview', 'mediaPreview', 'readMedia']);
    expect(res.bytes, Uint8List.fromList([1, 2, 3]));
    expect(res.mediaType, 'image/png');
    expect(res.totalBytes, 3);
  });

  test('resolved method is reused directly on the next call', () async {
    final calls = <String>[];
    final port = FileServicePort((method, args) async {
      calls.add(method);
      if (method == 'stat') return {'type': 'file', 'size': 12};
      throw ChannelRpcError('no such method: $method', null);
    });

    final res = await port.stat('/repo', 'a.txt');
    expect(res.type, 'file');
    expect(res.size, 12);
    expect(calls, ['stat']);

    calls.clear();
    await port.stat('/repo', 'b.txt');
    expect(calls, ['stat'], reason: 'second call must skip probing');
  });

  test('payloads carry exactly the scope+file fields, no extras', () async {
    final payloads = <Map<String, Object?>>[];
    final port = FileServicePort((method, args) async {
      payloads.add((args.single as Map).cast<String, Object?>());
      if (method == 'stat') return {'type': 'file'};
      if (method == 'readMediaPreview') {
        return {'dataBase64': base64Encode(const <int>[0])};
      }
      return {'text': 'x'};
    });

    await port.stat('/repo', 'a.txt');
    // stat: absolute path only — workspacePath is certified ignored on the
    // wire (spec §1.2) and no maxBytes/offset ride along
    expect(payloads[0], {'path': 'a.txt'});
    expect(payloads[0].containsKey('workspacePath'), isFalse);
    expect(payloads[0].containsKey('maxBytes'), isFalse);

    await port.readMedia('/repo', 'a.png');
    expect(payloads[1], {'path': 'a.png'});
    expect(payloads[1].containsKey('workspacePath'), isFalse);
    expect(payloads[1].containsKey('maxBytes'), isFalse);

    await port.readMedia('/repo', 'a.png', maxBytes: 1 << 20);
    expect(payloads[2]['maxBytes'], 1 << 20);

    await port.readText('/repo', 'a.txt', offset: 8, length: 256);
    expect(payloads[3], {
      'path': 'a.txt',
      'offset': 8,
      'length': 256,
    });
  });

  test('non-missingMethod errors rethrow without advancing', () async {
    final tried = <String>[];
    final port = FileServicePort((method, args) async {
      tried.add(method);
      throw ChannelRpcError('validation failed: bad path', null);
    });
    await expectLater(
      port.stat('/repo', 'a.txt'),
      throwsA(isA<ChannelRpcError>()
          .having((e) => e.message, 'message', 'validation failed: bad path')),
    );
    expect(tried, ['stat']);
  });

  test('every candidate missing → first error rethrown', () async {
    final port = FileServicePort((method, args) async =>
        throw ChannelRpcError('no such method: $method', null));
    await expectLater(port.readText('/repo', 'a.txt', length: 10),
        throwsA(isA<ChannelRpcError>()));
  });

  test('malformed answers throw explicit StateErrors', () async {
    FileServicePort answering(dynamic res) =>
        FileServicePort((method, args) async => res);

    // stat: non-map answer / answer without a type field
    await expectLater(
        answering('not-a-map').stat('/repo', 'p'), throwsStateError);
    await expectLater(
        answering(<String, dynamic>{}).stat('/repo', 'p'), throwsStateError);

    // readMediaPreview: missing or mistyped dataBase64
    await expectLater(answering(<String, dynamic>{}).readMedia('/repo', 'p'),
        throwsStateError);
    await expectLater(
        answering(<String, dynamic>{'dataBase64': 42}).readMedia('/repo', 'p'),
        throwsStateError);

    // readMediaPreview: undecodable base64
    await expectLater(
        answering(<String, dynamic>{'dataBase64': 'not base64!!'})
            .readMedia('/repo', 'p'),
        throwsStateError);

    // readTextFile: map without a content field
    await expectLater(
        answering(<String, dynamic>{'truncated': false})
            .readText('/repo', 'p', length: 10),
        throwsStateError);
  });

  test('answer parsing accepts the documented shapes', () async {
    FileServicePort answering(dynamic res) =>
        FileServicePort((method, args) async => res);

    // Certified wire shape (spec §1.2): totalBytes carries the size
    final media = await answering(<String, dynamic>{
      'dataBase64': base64Encode(utf8.encode('png')),
      'mediaType': 'image/png',
      'totalBytes': 3,
    }).readMedia('/repo', 'p');
    expect(utf8.decode(media.bytes), 'png');
    expect(media.totalBytes, 3);

    // plain-string text answer; certified map shape carries content+truncated
    final plain = await answering('file body')
        .readText('/repo', 'p', length: 10);
    expect(plain.text, 'file body');
    expect(plain.hasMore, isNull);
    final chunked = await answering(
            <String, dynamic>{'content': 'abc', 'truncated': true})
        .readText('/repo', 'p', length: 10);
    expect(chunked.text, 'abc');
    expect(chunked.hasMore, isTrue);
  });
}
