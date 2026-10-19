import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/ui/chat/timeline.dart';

void main() {
  Map<String, dynamic> tool(String name, {String status = 'completed'}) => {
        'kind': 'toolCall',
        'toolName': name,
        'status': status,
        'inputText': 'x',
      };

  test('consecutive execute tools merge into one rowGroup', () {
    final parts = assistantTurnParts([
      tool('bash'),
      tool('terminal'),
      tool('bash'),
    ]).parts;
    expect(parts, hasLength(1));
    expect(parts.single.kind, 'rowGroup');
    expect(parts.single.group, hasLength(3));
  });

  test('a text row splits the run; single execute stays a row', () {
    final parts = assistantTurnParts([
      tool('bash'),
      {'kind': 'assistantText', 'text': 'done'},
      tool('terminal'),
    ]).parts;
    expect(parts, hasLength(3));
    expect(parts[0].kind, 'row');
    expect(parts[0].group, isNull);
    expect(parts[1].kind, 'text');
    expect(parts[2].kind, 'row');
  });

  test('non-execute tools are not grouped', () {
    final parts = assistantTurnParts([
      tool('readFile'),
      tool('writeFile'),
    ]).parts;
    expect(parts, hasLength(2));
    for (final p in parts) {
      expect(p.kind, 'row');
      expect(p.group, isNull);
    }
  });

  test('pending text flushes above a non-execute tool row', () {
    final parts = assistantTurnParts([
      {'kind': 'assistantText', 'text': 'before'},
      tool('readFile'),
      {'kind': 'assistantText', 'text': 'after'},
    ]).parts;
    expect(parts.map((p) => p.kind), ['text', 'row', 'text']);
    expect(parts[0].text, 'before');
    expect(parts[2].text, 'after');
  });

  test('pending text flushes above a reasoning row too', () {
    final parts = assistantTurnParts([
      {'kind': 'assistantText', 'text': 'before'},
      {'kind': 'reasoning', 'text': 'think'},
    ]).parts;
    expect(parts.map((p) => p.kind), ['text', 'row']);
  });
}
