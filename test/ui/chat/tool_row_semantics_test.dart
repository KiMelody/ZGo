// Pure-Dart coverage for lib/ui/chat/tool_row_semantics.dart: every tool
// family pumps a row straight through toolRowSemantics — no page widget,
// no gateway (the old copy lived as private statics on chat_page's tile
// state and could only be tested by pumping the whole ChatPage).
//
// Parity discipline (ADR-0006): the copy under test is the frozen desktop
// wording from the zh/en tables in ui_settings.dart.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/ui/chat/tool_row_semantics.dart';

Map<String, dynamic> toolRow(Map<String, dynamic> extra) => {
  'kind': 'toolCall',
  'status': 'success',
  ...extra,
};

void main() {
  group('write/edit/notebook family', () {
    test('write: basename title, directory subtitle (zh)', () {
      final r = toolRowSemantics(
        toolRow({
          'toolName': 'Write',
          'inputText': '{"filePath":"a/b/c.dart"}',
        }),
        locale: 'zh-CN',
      );
      expect(r.title, '已写入 c.dart');
      expect(r.subtitle, 'a/b');
      expect(r.additions, 0);
      expect(r.deletions, 0);
    });

    test('edit: diff stats from structuredPatch, name fallback for path', () {
      final r = toolRowSemantics(
        toolRow({
          'toolName': 'Edit',
          'structuredPatch': [
            {
              'oldStart': 1,
              'oldLines': 2,
              'newStart': 1,
              'newLines': 3,
              'lines': [' ctx', '-old', '+new1', '+new2'],
            },
          ],
        }),
        locale: 'zh-CN',
      );
      expect(r.title, '已写入 Edit');
      expect(r.subtitle, isNull);
      expect(r.additions, 2);
      expect(r.deletions, 1);
    });

    test('notebook: notebookPath key picked up, diff filePath fallback', () {
      final r = toolRowSemantics(
        toolRow({
          'toolName': 'NotebookEdit',
          'inputText': '{"notebookPath":"note.ipynb"}',
          'structuredPatch': [
            {
              'filePath': 'dir/note.ipynb',
              'lines': ['+cell'],
            },
          ],
        }),
        locale: 'en-US',
      );
      expect(r.title, 'Wrote note.ipynb');
      expect(r.subtitle, isNull);
      expect(r.additions, 1);
      expect(r.deletions, 0);
    });

    test('status icon: success check / running hourglass', () {
      final ok = toolRowSemantics(
        toolRow({'toolName': 'Write', 'inputText': ''}),
        locale: 'zh-CN',
      );
      expect(ok.icon, Icons.check);
      final running = toolRowSemantics(
        toolRow({'toolName': 'Write', 'status': 'running'}),
        locale: 'zh-CN',
      );
      expect(running.icon, Icons.hourglass_top);
    });
  });

  group('taskoutput family', () {
    test('pending → fetching, default → retrieved (zh)', () {
      final pending = toolRowSemantics(
        toolRow({'toolName': 'TaskOutput', 'status': 'pending'}),
        locale: 'zh-CN',
      );
      expect(pending.title, '任务输出 · 正在获取任务输出');
      expect(pending.subtitle, isNull);
      expect(pending.additions, 0);
      expect(pending.deletions, 0);

      final done = toolRowSemantics(
        toolRow({'toolName': 'TaskOutput'}),
        locale: 'zh-CN',
      );
      expect(done.title, '任务输出 · 已获取');
    });

    test('en sample + failed branch', () {
      final failed = toolRowSemantics(
        toolRow({'toolName': 'TaskOutput', 'status': 'failed'}),
        locale: 'en-US',
      );
      expect(failed.title, 'Task output · Failed to fetch output');
    });
  });

  group('taskstop family', () {
    test('running → stopping, failed → failed, default → stopped (zh)', () {
      final stopping = toolRowSemantics(
        toolRow({'toolName': 'TaskStop', 'status': 'running'}),
        locale: 'zh-CN',
      );
      expect(stopping.title, '停止任务 · 正在停止任务');

      final failed = toolRowSemantics(
        toolRow({'toolName': 'TaskStop', 'status': 'failed'}),
        locale: 'zh-CN',
      );
      expect(failed.title, '停止任务 · 停止任务失败');

      final stopped = toolRowSemantics(
        toolRow({'toolName': 'TaskStop'}),
        locale: 'zh-CN',
      );
      expect(stopped.title, '停止任务 · 已停止');
    });

    test('denied branch', () {
      final denied = toolRowSemantics(
        toolRow({'toolName': 'TaskStop', 'status': 'denied'}),
        locale: 'zh-CN',
      );
      expect(denied.title, '停止任务 · 停止操作已拒绝');
    });
  });

  group('sendmessage family', () {
    test('running → sending, default → sent (zh + en)', () {
      final sending = toolRowSemantics(
        toolRow({'toolName': 'SendMessage', 'status': 'running'}),
        locale: 'zh-CN',
      );
      expect(sending.title, '发送消息 · 发送中');

      final sent = toolRowSemantics(
        toolRow({'toolName': 'SendMessage'}),
        locale: 'zh-CN',
      );
      expect(sent.title, '发送消息 · 已发送');

      final enSent = toolRowSemantics(
        toolRow({'toolName': 'SendMessage'}),
        locale: 'en-US',
      );
      expect(enSent.title, 'Send message · Sent');
    });

    test('stopped branch', () {
      final stopped = toolRowSemantics(
        toolRow({'toolName': 'SendMessage', 'status': 'stopped'}),
        locale: 'zh-CN',
      );
      expect(stopped.title, '发送消息 · 发送已停止');
    });
  });

  group('agent family', () {
    test('running with description → launching · subject, type subtitle', () {
      final r = toolRowSemantics(
        toolRow({
          'toolName': 'Agent',
          'status': 'running',
          'inputText':
              '{"description":"加固任务","subagent_type":"general"}',
        }),
        locale: 'zh-CN',
      );
      expect(r.title, '启动中 · 加固任务');
      expect(r.subtitle, 'general');
      expect(r.icon, Icons.hourglass_top);
    });

    test('description missing → type becomes subject, subtitle null', () {
      final r = toolRowSemantics(
        toolRow({
          'toolName': 'Agent',
          'inputText': '{"subagentType":"explore"}',
        }),
        locale: 'zh-CN',
      );
      expect(r.title, '已启动 · explore');
      expect(r.subtitle, isNull);
    });

    test('failed / stopped / error branches + en sample', () {
      final failed = toolRowSemantics(
        toolRow({'toolName': 'Agent', 'status': 'failed', 'inputText': '{}'}),
        locale: 'zh-CN',
      );
      expect(failed.title, '启动失败');

      final stopped = toolRowSemantics(
        toolRow(
          {'toolName': 'Agent', 'status': 'cancelled', 'inputText': '{}'},
        ),
        locale: 'zh-CN',
      );
      expect(stopped.title, '已停止');

      final en = toolRowSemantics(
        toolRow({'toolName': 'Agent', 'inputText': '{}'}),
        locale: 'en-US',
      );
      expect(en.title, 'Launched');
    });
  });

  group('askuserquestion family', () {
    test('asked with question count from input JSON (zh)', () {
      final r = toolRowSemantics(
        toolRow({
          'toolName': 'AskUserQuestion',
          'inputText': '{"questions":[{"q":1},{"q":2}]}',
        }),
        locale: 'zh-CN',
      );
      expect(r.title, '已询问 · 2 个问题');
    });

    test('running → asking; output marker → auto-continued', () {
      final asking = toolRowSemantics(
        toolRow({'toolName': 'AskUserQuestion', 'status': 'running'}),
        locale: 'zh-CN',
      );
      expect(asking.title, '正在询问');

      final auto = toolRowSemantics(
        toolRow({
          'toolName': 'AskUserQuestion',
          'outputText': 'No answer provided (auto-continued)',
        }),
        locale: 'zh-CN',
      );
      expect(auto.title, '未回答，已自动继续');
    });

    test('plain asked + en sample', () {
      final asked = toolRowSemantics(
        toolRow({'toolName': 'AskUserQuestion', 'inputText': '{}'}),
        locale: 'zh-CN',
      );
      expect(asked.title, '已询问');

      final en = toolRowSemantics(
        toolRow({
          'toolName': 'AskUserQuestion',
          'inputText': '{"questions":[{}]}',
        }),
        locale: 'en-US',
      );
      expect(en.title, 'Asked · 1 questions');
    });
  });

  group('execute family (bash/terminal/exec/command)', () {
    test('first command line as title, raw name as subtitle (zh)', () {
      final r = toolRowSemantics(
        toolRow({
          'toolName': 'Bash',
          'inputText': '{"command":"flutter test\\nsecond line"}',
        }),
        locale: 'zh-CN',
      );
      expect(r.title, '终端 · flutter test');
      expect(r.subtitle, 'Bash');
    });

    test('non-JSON input falls back to its first line; en sample', () {
      final r = toolRowSemantics(
        toolRow({'toolName': 'bash', 'inputText': 'ls -la\necho hi'}),
        locale: 'zh-CN',
      );
      expect(r.title, '终端 · ls -la');

      final en = toolRowSemantics(
        toolRow({'toolName': 'bash'}),
        locale: 'en-US',
      );
      expect(en.title, 'Terminal');
    });

    test('command line truncated at 60 chars', () {
      final long = 'x' * 100;
      final r = toolRowSemantics(
        toolRow({'toolName': 'Bash', 'inputText': long}),
        locale: 'zh-CN',
      );
      expect(r.title, '终端 · ${'x' * 60}');
    });
  });

  group('explore family (read/glob/grep/explore/search)', () {
    test('paths array → exploreN count (zh + en)', () {
      final r = toolRowSemantics(
        toolRow({
          'toolName': 'Grep',
          'inputText': '{"paths":["a","b","c"]}',
        }),
        locale: 'zh-CN',
      );
      expect(r.title, '探索 · 3 文件');
      expect(r.subtitle, 'Grep');

      final en = toolRowSemantics(
        toolRow({
          'toolName': 'Grep',
          'inputText': '{"paths":["a","b","c"]}',
        }),
        locale: 'en-US',
      );
      expect(en.title, 'Explore · 3 files');
    });

    test('file_path key → explore · file; bare input → bare explore', () {
      // file_path is not one of _fileCount's keys, so this reaches the
      // file branch (filePath/filePath would short-circuit as count 1).
      final file = toolRowSemantics(
        toolRow({'toolName': 'Read', 'inputText': '{"file_path":"x.dart"}'}),
        locale: 'zh-CN',
      );
      expect(file.title, '探索 · x.dart');

      final bare = toolRowSemantics(
        toolRow({'toolName': 'Read', 'inputText': '{}'}),
        locale: 'zh-CN',
      );
      expect(bare.title, '探索');
      expect(bare.subtitle, 'Read');
    });

    test('streaming (invalid-JSON) input counts path markers', () {
      final r = toolRowSemantics(
        toolRow({'toolName': 'Glob', 'inputText': '"path": "a", "path": "b"'}),
        locale: 'zh-CN',
      );
      expect(r.title, '探索 · 2 文件');
    });
  });

  group('fallback family', () {
    test('unknown tool renders raw name; diff stats still carried', () {
      final plain = toolRowSemantics(
        toolRow({'toolName': 'WebFetch', 'inputText': '{"url":"z.ai"}'}),
        locale: 'zh-CN',
      );
      expect(plain.title, 'WebFetch');
      expect(plain.subtitle, isNull);
      expect(plain.additions, 0);
      expect(plain.deletions, 0);

      final withDiff = toolRowSemantics(
        toolRow({
          'toolName': 'WebFetch',
          'input': {'oldText': 'a', 'newText': 'a\nb'},
        }),
        locale: 'zh-CN',
      );
      expect(withDiff.title, 'WebFetch');
      expect(withDiff.additions, 1);
      expect(withDiff.deletions, 0);
    });
  });

  group('status icon mapping', () {
    test('error / cancelled / unknown glyphs', () {
      expect(
        toolRowSemantics(
          toolRow({'toolName': 'Bash', 'status': 'error'}),
          locale: 'zh-CN',
        ).icon,
        Icons.error_outline,
      );
      expect(
        toolRowSemantics(
          toolRow({'toolName': 'Bash', 'status': 'cancelled'}),
          locale: 'zh-CN',
        ).icon,
        Icons.block,
      );
      expect(
        toolRowSemantics(
          toolRow({'toolName': 'Bash', 'status': 'inputStreaming'}),
          locale: 'zh-CN',
        ).icon,
        Icons.hourglass_top,
      );
      expect(
        toolRowSemantics(
          toolRow({'toolName': 'Bash', 'status': 'pendingApproval'}),
          locale: 'zh-CN',
        ).icon,
        Icons.hourglass_top,
      );
      expect(
        toolRowSemantics(
          toolRow({'toolName': 'Bash', 'status': 'unknown'}),
          locale: 'zh-CN',
        ).icon,
        Icons.build_outlined,
      );
    });
  });

  group('row semantics predicates', () {
    test('isExecuteTool matches the execute family only', () {
      expect(isExecuteTool(toolRow({'toolName': 'Bash'})), isTrue);
      expect(isExecuteTool(toolRow({'toolName': 'RunTerminal'})), isTrue);
      expect(isExecuteTool(toolRow({'toolName': 'exec_process'})), isTrue);
      expect(isExecuteTool(toolRow({'toolName': 'Write'})), isFalse);
      expect(isExecuteTool({'kind': 'userInput', 'toolName': 'Bash'}), isFalse);
    });

    test('isAgentTool matches the agent name exactly', () {
      expect(isAgentTool(toolRow({'toolName': 'Agent'})), isTrue);
      expect(isAgentTool(toolRow({'toolName': 'subagent'})), isFalse);
      expect(isAgentTool({'kind': 'userInput', 'toolName': 'Agent'}), isFalse);
    });

    test('promptOf reads the agent prompt, tolerates junk', () {
      expect(promptOf('{"prompt":"do it"}'), 'do it');
      expect(promptOf('{"prompt":""}'), isNull);
      expect(promptOf('not json'), isNull);
      expect(promptOf('{"other":1}'), isNull);
    });
  });
}
