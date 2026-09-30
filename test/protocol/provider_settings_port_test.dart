import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/provider_settings.dart';

/// Wire shapes and the snapshot-conflict retry contract of the write
/// surface — the certified shapes from the task's notes.md (2026-09-28
/// live probes). The desktop's snapshot-identity guard rejects a write
/// whose view frame went stale with a `revision conflict` error BEFORE
/// applying it; the port answers with one getView resync and an identical
/// retry.
void main() {
  late List<(String, String, List<Object?>)> calls;

  ProviderSettingsPort makePort(
      Future<Object?> Function(String method, List<Object?> args) handler) {
    return ProviderSettingsPort((channel, method, args) {
      calls.add((channel, method, args));
      return handler(method, args);
    });
  }

  setUp(() {
    calls = [];
  });

  /// Record `==` compares the args list by reference, so whole-tuple
  /// expects fail on identical payloads — assert per field instead
  /// (`expect` deep-compares the args list).
  void expectCall((String, String, List<Object?>) call, String method,
      List<Object?> args) {
    expect(call.$1, 'provider-settings');
    expect(call.$2, method);
    expect(call.$3, args);
  }

  test('every write goes to the provider-settings channel', () async {
    final port = makePort((m, a) async => {});
    await port.getView();
    await port.setPersonalModelEnabled('p', 'm', false);
    expect(calls, hasLength(2));
    for (final (channel, _, _) in calls) {
      expect(channel, 'provider-settings');
    }
  });

  test('setPersonalModelEnabled sends three positional args', () async {
    final port = makePort((m, a) async => {});
    await port.setPersonalModelEnabled('p1', 'glm-5.2', false);
    expectCall(calls.single, 'setPersonalModelEnabled',
        <Object?>['p1', 'glm-5.2', false]);
  });

  test('addPersonalModel sends the four-slot shape', () async {
    final port = makePort((m, a) async => {});
    await port.addPersonalModel('p1', 'gpt-4o',
        modelConfig: {'properties': {'contextWindow': 128000}},
        useRecommendedConfig: false);
    expectCall(
      calls.single,
      'addPersonalModel',
      <Object?>[
        'p1',
        'gpt-4o',
        {'properties': {'contextWindow': 128000}},
        false,
      ],
    );
  });

  test('enabled/rename rides savePersonalProviderOverlay patches', () async {
    final port = makePort((m, a) async => {});
    await port.setPersonalProviderEnabled('p1', false);
    await port.renamePersonalProvider('p1', 'Renamed');
    expect(calls, hasLength(2));
    expectCall(calls[0], 'savePersonalProviderOverlay',
        <Object?>['p1', {}, {'enabled': false}]);
    expectCall(calls[1], 'savePersonalProviderOverlay',
        <Object?>['p1', {}, {'providerName': 'Renamed'}]);
  });

  test('reorders send the full adjusted id sequence', () async {
    final port = makePort((m, a) async => {});
    await port.reorderPersonalProviders(['b', 'a', 'c']);
    await port.reorderPersonalModels('b', ['m2', 'm1']);
    expectCall(calls[0], 'reorderPersonalProviders', <Object?>[
      ['b', 'a', 'c']
    ]);
    expectCall(calls[1], 'reorderPersonalModels', <Object?>[
      'b',
      ['m2', 'm1']
    ]);
  });

  test('delete and rename-model shapes', () async {
    final port = makePort((m, a) async => {});
    await port.deletePersonalProvider('p1');
    await port.deletePersonalModel('p1', 'm1');
    await port.renamePersonalModel('p1', 'm1', 'm1x');
    expectCall(
        calls[0], 'deletePersonalProvider', <Object?>['p1']);
    expectCall(
        calls[1], 'deletePersonalModel', <Object?>['p1', 'm1']);
    expectCall(calls[2], 'renamePersonalModel',
        <Object?>['p1', 'm1', 'm1x']);
  });

  test('savePersonalModelDraft sends the single six-key map', () async {
    final port = makePort((m, a) async => {});
    await port.savePersonalModelDraft(
      providerId: 'p1',
      modelId: 'm1',
      newModelId: 'm2',
      personalConfig: {'properties': {'maxOutputTokens': 8192}},
      basedOnRevision: '[30,4]',
      useRecommendedConfig: false,
    );
    expectCall(
        calls.single,
        'savePersonalModelDraft',
        <Object?>[
          {
            'providerId': 'p1',
            'originalModelId': 'm1',
            'nextModelId': 'm2',
            'personalConfig': {'properties': {'maxOutputTokens': 8192}},
            'basedOnRevision': '[30,4]',
            'useRecommendedConfig': false,
          }
        ]);
  });

  test('createPersonalProvider maps template/name to the arg object',
      () async {
    final port = makePort((m, a) async => {'providerId': 'new-1'});
    expect(await port.createPersonalProvider(templateId: 'deepseek'), 'new-1');
    expectCall(calls.single, 'createPersonalProvider', <Object?>[
      {'templateId': 'deepseek'}
    ]);

    calls.clear();
    expect(await port.createPersonalProvider(providerName: 'Mine'), 'new-1');
    expectCall(calls.single, 'createPersonalProvider', <Object?>[
      {'providerName': 'Mine'}
    ]);
  });

  test('createPersonalProvider without providerId is a StateError',
      () async {
    final port = makePort((m, a) async => {'ok': true});
    expect(
        () => port.createPersonalProvider(providerName: 'X'),
        throwsA(isA<StateError>()));
  });

  test('overlay saves without rulePatch send two positionals, never a name',
      () async {
    final port = makePort((m, a) async => {});
    await port.savePersonalProviderOverlay(
        'p1', {'api': {'baseUrl': 'https://x'}}, null);
    expect(
        calls.single.$3,
        <Object?>[
          'p1',
          {'api': {'baseUrl': 'https://x'}},
        ],
        reason: 'no rulePatch → no third positional');

    // Round-1 probe: providerName inside the overlay was rejected by the
    // desktop's zod .strict() ("Unrecognized key") — it belongs to the
    // rulePatch. Lock the negative: the overlay the UI/port builds for
    // rename/enabled never carries it.
    final port2 = makePort((m, a) async => {});
    await port2.renamePersonalProvider('p1', 'Renamed');
    final overlay = calls.last.$3[1] as Map;
    expect(overlay.containsKey('providerName'), isFalse);
    expect(calls.last.$3[2], {'providerName': 'Renamed'});
  });

  test('revision conflict resyncs once and retries the identical write',
      () async {
    var writes = 0;
    final port = makePort((m, a) async {
      if (m != 'getView') writes++;
      if (m == 'savePersonalProviderOverlay' && writes == 1) {
        throw Exception('Provider Settings snapshot revision conflict');
      }
      return {'revision': '[31,4]'};
    });
    final res = await port.renamePersonalProvider('p1', 'New');
    expect(res, {'revision': '[31,4]'});
    expect(calls.map(((String, String, List<Object?>) c) => c.$2).toList(), [
      'savePersonalProviderOverlay',
      'getView',
      'savePersonalProviderOverlay',
    ]);
    // The retry sends the byte-identical payload (the resync changes only
    // the desktop facade's cache, never the write).
    expect(calls[0].$3, calls[2].$3);
  });

  test('non-conflict failures are not retried, not swallowed', () async {
    final boom = Exception('channel unavailable');
    final port = makePort((m, a) async {
      throw boom;
    });
    await expectLater(port.deletePersonalProvider('p1'), throwsA(same(boom)));
    expect(calls.map((c) => c.$2), ['deletePersonalProvider']);
  });

  test('a second conflict still surfaces (single retry only)', () async {
    final port = makePort((m, a) async {
      if (m != 'getView') {
        throw Exception('Provider Settings snapshot revision conflict');
      }
      return {};
    });
    await expectLater(
        port.reorderPersonalProviders(['a', 'b']), throwsException);
    expect(calls.map((c) => c.$2),
        ['reorderPersonalProviders', 'getView', 'reorderPersonalProviders']);
  });
}
