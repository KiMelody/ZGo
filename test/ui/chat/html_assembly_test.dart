import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/ui/chat/html_assembly.dart';

/// Fake reader recording every fetch, answering from path-keyed tables and
/// assembling a caller-supplied entry document at app/index.html.
class _FakeReader {
  _FakeReader({
    Map<String, String> texts = const {},
    Map<String, String> dataUrls = const {},
  })  : texts = Map.of(texts),
        dataUrls = Map.of(dataUrls);

  final Map<String, String> texts;
  final Map<String, String> dataUrls;
  final List<String> textCalls = [];
  final List<String> mediaCalls = [];

  HtmlAssembler assembler() => HtmlAssembler(
        readText: (path) async {
          textCalls.add(path);
          return texts[path];
        },
        readMediaDataUrl: (path) async {
          mediaCalls.add(path);
          return dataUrls[path];
        },
      );

  Future<AssemblyResult> assemble(String html) {
    texts['app/index.html'] = html;
    return assembler().assemble('app/index.html');
  }
}

/// Fixture covering every reference kind: stylesheet link, non-stylesheet
/// link, classic + module scripts, img src, img srcset, remote img.
const _fixtureHtml = '''
<!DOCTYPE html>
<html>
<head>
  <link rel="stylesheet" href="assets/style.css">
  <link rel="icon" href="assets/favicon.ico">
  <script src="app.js"></script>
  <script type="module" src="mod.mjs"></script>
</head>
<body>
  <img src="assets/pic.png">
  <img srcset="assets/small.png 1x, assets/big.png 2x" src="assets/fallback.png">
  <img src="https://example.com/remote.png">
  <p>hello</p>
</body>
</html>
''';

const _pngDataUrl = 'data:image/png;base64,AAAA';

void main() {
  test('fixture: every reference kind is inlined or kept verbatim', () async {
    final reader = _FakeReader(
      texts: {
        'app/assets/style.css': 'body{background:url(bg.png)}',
        'app/app.js': 'console.log(1)',
        'app/mod.mjs': 'export const x = 1;',
      },
      dataUrls: {
        'app/assets/bg.png': _pngDataUrl,
        'app/assets/pic.png': _pngDataUrl,
        'app/assets/big.png': _pngDataUrl,
      },
    );
    final res = await reader.assemble(_fixtureHtml);

    // stylesheet → <style>, and its url() got the depth-2 data URL
    expect(res.html, contains('<style>'));
    expect(res.html, contains('background:url($_pngDataUrl)'));
    // classic script inlined; module script keeps type="module"
    expect(res.html, contains('<script>\nconsole.log(1)\n</script>'));
    expect(res.html, contains('type="module"'));
    expect(res.html, contains('export const x = 1;'));
    // img src → data URL; srcset collapses to its largest candidate
    expect(res.html, contains('src="$_pngDataUrl"'));
    expect(res.html, isNot(contains('srcset')));
    expect(reader.mediaCalls, contains('app/assets/big.png'));
    expect(reader.mediaCalls, isNot(contains('app/assets/small.png')));
    // non-stylesheet link and remote img stay untouched, never fetched
    expect(res.html, contains('<link rel="icon" href="assets/favicon.ico">'));
    expect(res.html, contains('<img src="https://example.com/remote.png">'));
    expect(reader.mediaCalls, isNot(contains('app/assets/favicon.ico')));
    expect(reader.mediaCalls, isNot(contains('app/assets/fallback.png')));

    expect(
      res.inlined,
      containsAll(<String>[
        'app/assets/style.css',
        'app/app.js',
        'app/mod.mjs',
        'app/assets/pic.png',
        'app/assets/big.png',
        'app/assets/bg.png',
      ]),
    );
    expect(res.failed, isEmpty);
    expect(res.truncated, isFalse);
  });

  test('depth cap: css url() inlines one hop only; css-in-css stays',
      () async {
    final reader = _FakeReader(texts: {
      'app/style.css': 'a{background:url(bg.png)} b{mask:url(more.css)}',
    }, dataUrls: {
      'app/bg.png': _pngDataUrl,
    });
    final res = await reader.assemble(
        '<html><head><link rel="stylesheet" href="style.css"></head></html>');

    expect(res.html, contains('background:url($_pngDataUrl)'),
        reason: 'depth-2 image target is inlined');
    // more.css is never fetched or re-parsed (no depth-3 hop)
    expect(reader.textCalls, isNot(contains('app/more.css')));
    expect(res.html, contains('url(more.css)'));
  });

  test('whitelist: disallowed extensions are never fetched', () async {
    final reader = _FakeReader(
      dataUrls: {'app/logo.svg': 'data:image/svg+xml,<x/>'},
      texts: {'app/notes.txt': 'nope'},
    );
    final res = await reader.assemble('<html><body>'
        '<img src="logo.svg">'
        '<script src="notes.txt"></script>'
        '<p>keep me</p>'
        '</body></html>');

    expect(reader.mediaCalls, isNot(contains('app/logo.svg')));
    expect(reader.textCalls, isNot(contains('app/notes.txt')));
    expect(res.html, contains('<!-- preview: skipped app/logo.svg -->'));
    expect(res.html, contains('<!-- preview: skipped app/notes.txt -->'));
    expect(res.html, contains('keep me'));
    expect(
      res.failed.map((f) => f.path),
      containsAll(<String>['app/logo.svg', 'app/notes.txt']),
    );
    expect(res.failed.map((f) => f.reason), everyElement(contains('extension')));
  });

  test('file-count cap: the 41st resource degrades to a placeholder',
      () async {
    final paths = List.generate(41, (i) => 'app/p$i.png');
    final reader = _FakeReader(
      dataUrls: {for (final p in paths) p: _pngDataUrl},
    );
    final html = '<html><body>'
        '${paths.map((p) => '<img src="${p.substring(4)}">').join()}'
        '</body></html>';
    final res = await reader.assemble(html);

    expect(reader.mediaCalls, hasLength(40));
    expect(res.html, contains('<!-- preview: skipped app/p40.png -->'));
    expect(res.truncated, isTrue);
    expect(res.failed.last.reason, contains('file-count cap'));
  });

  test('file-size cap: an over-cap css degrades to a placeholder', () async {
    final bigCss = 'a{color:red}' * (2 * 1024 * 1024 ~/ 12 + 1); // > 2MB
    final reader = _FakeReader(texts: {'app/big.css': bigCss});
    final res = await reader.assemble('<html><head>'
        '<link rel="stylesheet" href="big.css">'
        '</head><body>ok</body></html>');

    expect(res.html, contains('<!-- preview: skipped app/big.css -->'));
    expect(res.truncated, isTrue);
    expect(res.failed.single.reason, contains('byte cap'));
  });

  test('total-size cap: the resource crossing 8MB degrades', () async {
    final chunk = 'x' * (1800 * 1024); // 1.76MB each; five exceed 8MB
    final reader = _FakeReader(texts: {
      'app/a.css': chunk,
      'app/b.css': chunk,
      'app/c.css': chunk,
      'app/d.css': chunk,
      'app/e.css': chunk,
    });
    final res = await reader.assemble('<html><head>'
        '${['a', 'b', 'c', 'd', 'e'].map((n) => '<link rel="stylesheet" href="$n.css">').join()}'
        '</head><body>ok</body></html>');

    expect(res.html, contains('<!-- preview: skipped app/e.css -->'));
    expect(res.html, contains('<style>'), reason: 'earlier css still inlined');
    expect(res.truncated, isTrue);
    expect(res.failed.single.path, 'app/e.css');
  });

  test('absolute references are kept verbatim and never fetched', () async {
    final reader = _FakeReader();
    const html = '<html><head>'
        '<link rel="stylesheet" href="https://cdn.example.com/x.css">'
        '<script src="//cdn.example.com/y.js"></script>'
        '</head><body>'
        '<img src="data:image/gif;base64,R0lGOD">'
        '<img src="//cdn.example.com/z.png">'
        '</body></html>';
    final res = await reader.assemble(html);

    expect(res.html, html, reason: 'absolute references stay byte-identical');
    expect(reader.mediaCalls, isEmpty);
    expect(reader.textCalls, hasLength(1), reason: 'only the entry document');
  });

  test('read failures degrade to placeholders and keep the rest', () async {
    final reader = _FakeReader(); // style.css missing → null
    final res = await reader.assemble('<html><head>'
        '<link rel="stylesheet" href="style.css">'
        '</head><body><p>still here</p></body></html>');

    expect(res.html, contains('<!-- preview: skipped app/style.css -->'));
    expect(res.html, contains('<p>still here</p>'));
    expect(res.failed.single.reason, 'read failed');

    // main file unreadable → explicit error for the page's error state
    final missing = _FakeReader();
    await expectLater(
      missing.assembler().assemble('app/missing.html'),
      throwsStateError,
    );
  });

  test('cycles and duplicates: visited set keeps fetch counts at one',
      () async {
    final reader = _FakeReader(
      texts: {'app/a.css': 'a{background:url(a.png) url(a.css)}'},
      dataUrls: {'app/a.png': _pngDataUrl},
    );
    final res = await reader.assemble('<html><head>'
        '<link rel="stylesheet" href="a.css">'
        '<link rel="stylesheet" href="a.css">'
        '</head><body>b</body></html>');

    expect(
      reader.textCalls.where((p) => p == 'app/a.css'),
      hasLength(1),
      reason: 'duplicate links reuse the visited cache',
    );
    expect(reader.mediaCalls.where((p) => p == 'app/a.png'), hasLength(1));
    // self-referencing url(a.css) is kept, not re-fetched or re-parsed
    expect(res.html, contains('url(a.css)'));
    expect(res.html, contains('url($_pngDataUrl)'));
  });

  test('progress: (processed, discovered) fires per reference, monotonic',
      () async {
    final reader = _FakeReader(
      texts: {'app/a.css': 'a{}'},
      dataUrls: {'app/p.png': _pngDataUrl},
    );
    final events = <(int, int)>[];
    final assembler = HtmlAssembler(
      readText: (path) async {
        reader.textCalls.add(path);
        return reader.texts[path];
      },
      readMediaDataUrl: (path) async {
        reader.mediaCalls.add(path);
        return reader.dataUrls[path];
      },
      onProgress: (done, total) => events.add((done, total)),
    );
    reader.texts['app/index.html'] = '<html><head>'
        '<link rel="stylesheet" href="a.css">'
        '</head><body><img src="p.png"></body></html>';
    await assembler.assemble('app/index.html');

    // discovery event (pending fetch) + one completion event per resource
    expect(events, contains((0, 1))); // css discovered
    expect(events.last, (2, 2), reason: 'both resources inlined: 2/2');
    for (var i = 1; i < events.length; i++) {
      expect(events[i].$1 >= events[i - 1].$1, isTrue,
          reason: 'processed never regresses: $events');
      expect(events[i].$2 >= events[i - 1].$2, isTrue,
          reason: 'discovered never regresses: $events');
    }
  });
}
