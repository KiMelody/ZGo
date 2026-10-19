import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/file_service.dart';
import 'package:zgo/ui/chat/file_read_result.dart';
import 'package:zgo/ui/chat/timeline.dart';

import '../../helpers/recording_chat_gateway.dart';

/// The desktop's server-side clamp (research/official-large-text §1).
const _step = 256 * 1024;

/// The app-side per-file read cap (design §1.3).
const _cap = 2 * 1024 * 1024;

/// Scripted [ChatGateway.fileReadText]: every call pops one entry — a
/// [TextChunk] is answered, anything else is thrown (error-path
/// programming). All (offset, length) pairs are recorded.
class _ScriptedTextGateway extends RecordingChatGateway {
  _ScriptedTextGateway(this.script);

  final List<Object> script;
  final List<(int, int)> textCalls = [];

  @override
  Future<TextChunk> fileReadText(String workspacePath, String path,
      {int offset = 0, required int length}) async {
    textCalls.add((offset, length));
    if (script.isEmpty) {
      fail('fileReadText called past the end of the script');
    }
    final next = script.removeAt(0);
    if (next is TextChunk) return next;
    throw next;
  }
}

/// Server-faithful chunk list for a file of [size] filler bytes ('a' — one
/// char = one byte): every answer clamps to 256 KiB and carries the wire
/// metadata (`truncated = offset + bytesRead < totalBytes`).
List<TextChunk> chunksFor(int size) {
  if (size == 0) {
    return [
      const TextChunk(
        text: '',
        bytesRead: 0,
        totalBytes: 0,
        hasMore: false,
        isBinary: false,
      ),
    ];
  }
  final out = <TextChunk>[];
  var offset = 0;
  while (offset < size) {
    final n = math.min(_step, size - offset);
    out.add(TextChunk(
      text: 'a' * n,
      bytesRead: n,
      totalBytes: size,
      hasMore: offset + n < size,
      isBinary: false,
    ));
    offset += n;
  }
  return out;
}

void main() {
  group('read loop (design §1.3)', () {
    test('small file: one 256 KiB-clamped step with wire metadata',
        () async {
      final gateway = _ScriptedTextGateway(chunksFor(100));
      final result = await ChatPreview(gateway).readText('C:/w/note.txt');

      expect(result.text, 'a' * 100);
      expect(result.failure, isNull);
      expect(result.totalBytes, 100);
      expect(result.truncated, isFalse);
      expect(gateway.textCalls, [(0, _step)],
          reason: 'requests are 256 KiB — the old single 2 MiB request was '
              'what the server silently clamped');
    });

    test('a >256 KiB file is no longer silently truncated at one chunk',
        () async {
      const size = 300 * 1024; // pre-S2 this came back cut at 256 KiB
      final gateway = _ScriptedTextGateway(chunksFor(size));
      final result = await ChatPreview(gateway).readText('C:/w/notes.md');

      expect(result.text!.length, size);
      expect(result.text!.substring(_step), 'a' * (size - _step));
      expect(gateway.textCalls, [(0, _step), (_step, _step)]);
      expect(result.truncated, isFalse);
    });

    test('exactly 256 KiB: a single full step, truncated false', () async {
      final gateway = _ScriptedTextGateway(chunksFor(_step));
      final result = await ChatPreview(gateway).readText('C:/w/edge.txt');

      expect(result.text!.length, _step);
      expect(result.totalBytes, _step);
      expect(result.truncated, isFalse);
      expect(gateway.textCalls, [(0, _step)]);
    });

    test('a file across three chunks assembles in wire order', () async {
      const size = 600000;
      final gateway = _ScriptedTextGateway(chunksFor(size));
      final result = await ChatPreview(gateway).readText('C:/w/big.log');

      expect(result.text, 'a' * size);
      expect(result.totalBytes, size);
      expect(result.truncated, isFalse);
      expect(gateway.textCalls,
          [(0, _step), (_step, _step), (2 * _step, _step)]);
    });

    test('the 2 MiB cap stops the loop after eight steps', () async {
      const size = 3 * 1024 * 1024;
      final gateway = _ScriptedTextGateway(chunksFor(size));
      final result = await ChatPreview(gateway).readText('C:/w/huge.json');

      expect(gateway.textCalls.length, _cap ~/ _step);
      expect(gateway.textCalls.first, (0, _step));
      expect(gateway.textCalls.last, (7 * _step, _step));
      expect(result.text!.length, _cap);
      expect(result.totalBytes, size);
      expect(result.truncated, isTrue);
    });

    test('an empty answer marks EOF when the wire omits the metadata',
        () async {
      final gateway = _ScriptedTextGateway([
        const TextChunk(text: 'hello', bytesRead: 5),
        const TextChunk(text: '', bytesRead: 0),
      ]);
      final result = await ChatPreview(gateway).readText('C:/w/quiet.txt');

      expect(result.text, 'hello');
      expect(result.failure, isNull);
      expect(result.truncated, isFalse);
      expect(gateway.textCalls.length, 2);
    });

    test('a binary chunk → binary failure, no further reads', () async {
      final gateway = _ScriptedTextGateway([
        const TextChunk(
          text: '',
          bytesRead: _step,
          totalBytes: _step,
          hasMore: true,
          isBinary: true,
        ),
        const TextChunk(text: 'never reached'),
      ]);
      final result = await ChatPreview(gateway).readText('C:/w/blob.dat');

      expect(result.failure, FileReadFailure.binary);
      expect(result.text, isNull);
      expect(gateway.textCalls.length, 1);
    });

    test('an empty file → empty failure', () async {
      final gateway = _ScriptedTextGateway(chunksFor(0));
      final result = await ChatPreview(gateway).readText('C:/w/zero.txt');

      expect(result.failure, FileReadFailure.empty);
      expect(result.text, isNull);
      expect(result.totalBytes, 0);
    });

    test('no workspace: readFailed without touching the wire', () async {
      final gateway = _ScriptedTextGateway(const [])..workspacePath = null;
      final result = await ChatPreview(gateway).readText('C:/w/x.txt');

      expect(result.failure, FileReadFailure.readFailed);
      expect(gateway.textCalls, isEmpty);
    });
  });

  group('error classification (design §2)', () {
    test('ENOENT → notFound (official f6 regex, case-insensitive)',
        () async {
      for (final message in [
        "ENOENT: no such file or directory, open 'C:/w/gone.txt'",
        'No Such File Or Directory',
      ]) {
        final gateway = _ScriptedTextGateway([Exception(message)]);
        final result = await ChatPreview(gateway).readText('C:/w/gone.txt');
        expect(result.failure, FileReadFailure.notFound, reason: message);
      }
    });

    test('the over-limit readMedia family → tooLarge', () async {
      final gateway = _ScriptedTextGateway([
        Exception('Media file is too large for inline preview'),
      ]);
      final result = await ChatPreview(gateway).readText('C:/w/huge.png');

      expect(result.failure, FileReadFailure.tooLarge);
      expect(result.text, isNull);
    });

    test('anything else → readFailed', () async {
      final gateway = _ScriptedTextGateway([Exception('boom')]);
      final result = await ChatPreview(gateway).readText('C:/w/x.txt');

      expect(result.failure, FileReadFailure.readFailed);
    });
  });
}
