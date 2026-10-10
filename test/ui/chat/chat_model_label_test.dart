import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/ui/chat/timeline.dart';

/// [chatModelLabel] — the subagent detail page's model subtitle rule
/// (design D4): the official web's `JMe` semantics. A bare model id for
/// the default/official provider, `provider/model` for third-party ones,
/// empty when the snapshot carries no model.
ConversationState _stateWith(
  Map<String, dynamic>? config, {
  List<Map<String, dynamic>> rows = const [],
}) {
  final state = ConversationState();
  state.applyFrame({
    'toSeq': 1,
    'payload': {
      'kind': 'snapshot',
      'snapshot': {
        'sessionId': 's',
        'logEpoch': 'e1',
        'revision': 1,
        'rows': {
          'window': rows,
          'totalCount': rows.length,
          if (rows.isNotEmpty) 'firstRowId': rows.first['rowId'],
        },
        if (config != null) 'config': config,
      },
    },
  }, onGap: () => fail('unexpected gap'));
  return state;
}

/// The shape the desktop logs when a subagent spawns on a different model
/// than the parent's current one (live acceptance 2026-10-10).
Map<String, dynamic> _modelChangeRow(
  int rowId,
  String from,
  String to,
) =>
    {
      'rowId': rowId,
      'kind': 'timelineMarker',
      'marker': {'type': 'modelChange', 'fromModel': from, 'toModel': to},
    };

void main() {
  test('empty / missing model renders empty label', () {
    expect(chatModelLabel(_stateWith(null)), '');
    expect(
      chatModelLabel(_stateWith({'provider': 'glm', 'model': ''})),
      '',
    );
  });

  test('official providers show the bare model id', () {
    // Coding-plan account id — the live-probed session-config shape
    // (research/subagents-probe.md: provider account:zai-individual-
    // coding-plan, model GLM-5.3-Flash).
    expect(
      chatModelLabel(_stateWith({
        'provider': 'account:zai-individual-coding-plan',
        'model': 'GLM-5.3-Flash',
      })),
      'GLM-5.3-Flash',
    );
    expect(
      chatModelLabel(_stateWith({
        'provider': 'account:bigmodel-team-coding-plan',
        'model': 'GLM-5.3',
      })),
      'GLM-5.3',
    );
    expect(chatModelLabel(_stateWith({'provider': 'glm', 'model': 'X'})), 'X');
    expect(
      chatModelLabel(_stateWith({'provider': '', 'model': 'GLM-5.3'})),
      'GLM-5.3',
    );
  });

  test('third-party provider prefixes provider/model', () {
    expect(
      chatModelLabel(_stateWith({
        'provider': 'openrouter',
        'model': 'gpt-5.2',
      })),
      'openrouter/gpt-5.2',
    );
  });

  test('already-prefixed model is not double-prefixed', () {
    expect(
      chatModelLabel(_stateWith({
        'provider': 'openrouter',
        'model': 'openrouter/gpt-5.2',
      })),
      'openrouter/gpt-5.2',
    );
  });

  test('marker fallback: a config-less snapshot derives the model from the '
      'newest modelChange marker', () {
    expect(
      chatModelLabel(_stateWith(null, rows: [
        _modelChangeRow(1, 'glm-5.2', 'glm-5.2-air'),
        const {'rowId': 2, 'kind': 'assistantText', 'text': 'done'},
        _modelChangeRow(3, 'glm-5.2-air', 'glm-5.3'),
      ])),
      'glm-5.3',
    );
  });

  test('marker fallback: a config model still wins over the marker', () {
    expect(
      chatModelLabel(_stateWith(
        const {'provider': 'glm', 'model': 'GLM-5.3'},
        rows: [_modelChangeRow(1, 'glm-5.2', 'glm-5.2-air')],
      )),
      'GLM-5.3',
    );
  });

  test('marker fallback: provider-only config still prefixes the marker '
      'model; no marker at all stays empty', () {
    expect(
      chatModelLabel(_stateWith(
        const {'provider': 'openrouter'},
        rows: [_modelChangeRow(1, 'x', 'gpt-5.2')],
      )),
      'openrouter/gpt-5.2',
    );
    expect(
      chatModelLabel(_stateWith(null, rows: const [
        {'rowId': 1, 'kind': 'assistantText', 'text': 'x'},
      ])),
      '',
    );
  });
}
