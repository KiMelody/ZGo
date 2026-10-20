import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zgo/state/chat_draft_store.dart';

ChatDraftStore newStore(Directory root, {String device = 'd1'}) =>
    ChatDraftStore(deviceId: device, attachmentRoot: () async => root);

Directory deviceDir(Directory root, {String device = 'd1'}) =>
    Directory('${root.path}${Platform.pathSeparator}$device');

/// Saves under a fixed clock so entry-cap pruning is deterministic
/// (otherwise every save lands on the same millisecond).
Future<void> saveAt(
  ChatDraftStore store,
  String key,
  String text,
  DateTime at,
) {
  return withClock(Clock.fixed(at), () => store.saveText(key, text, 0));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('chat_drafts_test');
  });
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('text roundtrips through a fresh store instance', () async {
    final a = newStore(tmp);
    await a.saveText('s1', 'hello draft', 0);
    final snapshot = await newStore(tmp).restore('s1');
    expect(snapshot, isNotNull);
    expect(snapshot!.text, 'hello draft');
    expect(snapshot.files, isEmpty);
  });

  test('empty text with no attachments removes the entry', () async {
    final a = newStore(tmp);
    await a.saveText('s1', 'hello', 0);
    await a.saveText('s1', '', 0);
    expect(await a.restore('s1'), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getString('chat.drafts.d1')!), isEmpty);
  });

  test('oversize text is not persisted at all', () async {
    final a = newStore(tmp);
    await a.saveText('s1', 'a' * (32 * 1024 + 1), 0);
    expect(await newStore(tmp).restore('s1'), isNull);
  });

  test('attachment bytes roundtrip with name and mime', () async {
    final a = newStore(tmp);
    await a.saveText('s1', 'with file', 1);
    await a.putAttachment(
      's1',
      0,
      name: 'shot 界面.png',
      mime: 'image/png',
      bytes: Uint8List.fromList([1, 2, 3]),
    );
    final snapshot = await newStore(tmp).restore('s1');
    expect(snapshot!.text, 'with file');
    expect(snapshot.files, hasLength(1));
    expect(snapshot.files.single.name, 'shot 界面.png');
    expect(snapshot.files.single.mime, 'image/png');
    expect(snapshot.files.single.bytes, [1, 2, 3]);
  });

  test('attachment-only draft survives without text', () async {
    final a = newStore(tmp);
    await a.putAttachment(
      's1',
      0,
      name: 'a.bin',
      mime: 'application/octet-stream',
      bytes: Uint8List.fromList([9]),
    );
    // saveText with attachmentCount 1 must not kill the entry.
    await a.saveText('s1', '', 1);
    final snapshot = await a.restore('s1');
    expect(snapshot, isNotNull);
    expect(snapshot!.files, hasLength(1));
  });

  test('removeAttachmentAt shifts metadata and deletes the disk file',
      () async {
    final a = newStore(tmp);
    await a.putAttachment(
      's1',
      0,
      name: 'a.png',
      mime: 'image/png',
      bytes: Uint8List.fromList([1]),
    );
    await a.putAttachment(
      's1',
      1,
      name: 'b.png',
      mime: 'image/png',
      bytes: Uint8List.fromList([2]),
    );
    await a.removeAttachmentAt('s1', 0);
    final snapshot = await newStore(tmp).restore('s1');
    expect(snapshot!.files, hasLength(1));
    expect(snapshot.files.single.name, 'b.png');
    // The removed slot's disk file is gone; exactly one file remains.
    final dir = Directory(
      '${deviceDir(tmp).path}${Platform.pathSeparator}s1',
    );
    expect(await dir.list().length, 1);
  });

  test('entry with neither text nor attachments dies with its directory',
      () async {
    final a = newStore(tmp);
    await a.putAttachment(
      's1',
      0,
      name: 'a.png',
      mime: 'image/png',
      bytes: Uint8List.fromList([1]),
    );
    await a.removeAttachmentAt('s1', 0);
    expect(await a.restore('s1'), isNull);
    expect(
      await Directory(
        '${deviceDir(tmp).path}${Platform.pathSeparator}s1',
      ).exists(),
      isFalse,
    );
  });

  test('missing attachment file drops silently, text still restores',
      () async {
    final a = newStore(tmp);
    await a.saveText('s1', 'text', 1);
    await a.putAttachment(
      's1',
      0,
      name: 'a.png',
      mime: 'image/png',
      bytes: Uint8List.fromList([1]),
    );
    final dir = Directory(
      '${deviceDir(tmp).path}${Platform.pathSeparator}s1',
    );
    await for (final f in dir.list()) {
      await f.delete();
    }
    final snapshot = await a.restore('s1');
    expect(snapshot!.text, 'text');
    expect(snapshot.files, isEmpty);
  });

  test('entry with nothing restorable self-heals away', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('chat.drafts.d1', jsonEncode({
      's1': {
        't': '',
        'at': 1,
        'f': [
          {'f': '0.bin', 'n': 'a.bin', 'm': 'application/octet-stream', 's': 1},
        ],
      },
    }));
    final a = newStore(tmp);
    expect(await a.restore('s1'), isNull);
    expect(
      jsonDecode((await SharedPreferences.getInstance()).getString(
            'chat.drafts.d1',
          )!),
      isEmpty,
    );
  });

  test('orphan directories are swept on load; referenced ones kept',
      () async {
    final a = newStore(tmp);
    await a.saveText('s1', 'kept', 0);
    final stray = Directory(
      '${deviceDir(tmp).path}${Platform.pathSeparator}stray',
    )..createSync(recursive: true);
    File(
      '${stray.path}${Platform.pathSeparator}junk',
    ).writeAsStringSync('x');
    await newStore(tmp).load();
    expect(await stray.exists(), isFalse);
    expect(await newStore(tmp).restore('s1'), isNotNull);
  });

  test('entry cap prunes the oldest-touched draft', () async {
    final a = newStore(tmp);
    final base = DateTime(2026, 1, 1);
    for (var i = 0; i <= ChatDraftStore.maxEntries; i++) {
      await saveAt(a, 'k$i', 'v$i', base.add(Duration(seconds: i)));
    }
    expect(await a.restore('k0'), isNull);
    expect((await a.restore('k1'))!.text, 'v1');
    expect(
      (await a.restore('k${ChatDraftStore.maxEntries}'))!.text,
      'v${ChatDraftStore.maxEntries}',
    );
  });

  test('attachment byte budget prunes oldest entries with files', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('chat.drafts.d1', jsonEncode({
      'old': {
        't': 'x',
        'at': 1,
        'f': [
          {
            'f': '0.bin',
            'n': 'a.bin',
            'm': 'application/octet-stream',
            's': 60 * 1024 * 1024,
          },
        ],
      },
      'young': {
        't': 'y',
        'at': 2,
        'f': [
          {
            'f': '0.bin',
            'n': 'b.bin',
            'm': 'application/octet-stream',
            's': 10 * 1024 * 1024,
          },
        ],
      },
    }));
    final a = newStore(tmp);
    await a.saveText('new', 'hi', 0);
    expect(await a.restore('old'), isNull);
    expect((await a.restore('young'))!.text, 'y');
    expect((await a.restore('new'))!.text, 'hi');
  });

  test('restore realigns metadata after a dropped file', () async {
    final a = newStore(tmp);
    await a.putAttachment(
      's1',
      0,
      name: 'a.png',
      mime: 'image/png',
      bytes: Uint8List.fromList([1]),
    );
    await a.putAttachment(
      's1',
      1,
      name: 'b.png',
      mime: 'image/png',
      bytes: Uint8List.fromList([2]),
    );
    // Disk file of slot 0 goes missing; restore drops it.
    final dir = Directory(
      '${deviceDir(tmp).path}${Platform.pathSeparator}s1',
    );
    await for (final f in dir.list()) {
      if (f.path.endsWith('0.png')) await f.delete();
    }
    final dropped = await a.restore('s1');
    expect(dropped!.files, hasLength(1));
    expect(dropped.files.single.name, 'b.png');

    // Metadata now matches the caller's list: the next add APPENDS at
    // index 1 instead of overwriting a stale slot.
    await a.putAttachment(
      's1',
      1,
      name: 'c.png',
      mime: 'image/png',
      bytes: Uint8List.fromList([3]),
    );
    final snapshot = await newStore(tmp).restore('s1');
    expect(
      snapshot!.files.map((f) => f.name).toList(),
      ['b.png', 'c.png'],
    );
  });

  test('entry keys are sanitized into safe directory names', () async {
    final a = newStore(tmp);
    await a.putAttachment(
      'draft.ws/1',
      0,
      name: 'a.png',
      mime: 'image/png',
      bytes: Uint8List.fromList([1]),
    );
    final snapshot = await newStore(tmp).restore('draft.ws/1');
    expect(snapshot!.files, hasLength(1));
    // The sanitized dir survived the second store's sweep.
    expect(
      Directory(
        '${deviceDir(tmp).path}${Platform.pathSeparator}draft.ws_1',
      ).existsSync(),
      isTrue,
    );
  });

  test('null resolver degrades to text-only drafts', () async {
    final a = ChatDraftStore(deviceId: 'd1');
    await a.saveText('s1', 'text only', 0);
    await a.putAttachment(
      's1',
      0,
      name: 'a.png',
      mime: 'image/png',
      bytes: Uint8List.fromList([1]),
    );
    final snapshot = await a.restore('s1');
    expect(snapshot!.text, 'text only');
    expect(snapshot.files, isEmpty);
  });
}
