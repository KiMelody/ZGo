import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/endpoint_models.dart';

/// `/models` endpoint fetch matrix (design 09-28 增强节): path + headers per
/// api.type, `{data:[{id}]}` parsing, auth/network/parse error taxonomy and
/// the cross-protocol fallback — served by a local loopback HttpServer.
void main() {
  late HttpServer server;
  final requests = <HttpRequest>[];

  /// Serves [handler] on the loopback and answers the path/headers matrix.
  Future<String> start(
    Future<void> Function(HttpRequest request) handler,
  ) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      requests.add(request);
      handler(request);
    });
    return 'http://127.0.0.1:${server.port}';
  }

  setUp(() async {
    requests.clear();
  });

  tearDown(() async {
    await server.close(force: true);
  });

  Future<void> expectKind(
    Future<List<String>> Function() run,
    EndpointModelsErrorKind kind,
  ) async {
    try {
      await run();
      fail('expected EndpointModelsException($kind)');
    } on EndpointModelsException catch (e) {
      expect(e.kind, kind);
    }
  }

  test('openai api.type hits {base}/models with Bearer', () async {
    final base = await start((request) async {
      expect(request.uri.path, '/models');
      expect(request.headers.value('Authorization'), 'Bearer sk-test');
      request.response.add(utf8.encode(
          jsonEncode({'data': [{'id': 'gpt-x'}, {'id': 'gpt-y'}]})));
      await request.response.close();
    });
    final ids = await fetchEndpointModels(
      baseUrl: '$base/',
      apiType: 'openai-chat-completions',
      apiKey: 'sk-test',
    );
    expect(ids, ['gpt-x', 'gpt-y']);
    expect(requests, hasLength(1));
  });

  test('anthropic api.type hits {base}/v1/models with x-api-key', () async {
    final base = await start((request) async {
      expect(request.uri.path, '/v1/models');
      expect(request.headers.value('x-api-key'), 'sk-anthropic');
      expect(request.headers.value('anthropic-version'), '2023-06-01');
      request.response.add(utf8.encode(
          jsonEncode({'data': [{'id': 'claude-x'}]})));
      await request.response.close();
    });
    final ids = await fetchEndpointModels(
      baseUrl: base,
      apiType: 'anthropic-messages',
      apiKey: 'sk-anthropic',
    );
    expect(ids, ['claude-x']);
  });

  test('openai-responses shares the openai request shape', () async {
    final base = await start((request) async {
      expect(request.uri.path, '/models');
      request.response.add(utf8.encode(
          jsonEncode({'data': <Object>[]})));
      await request.response.close();
    });
    expect(
      await fetchEndpointModels(
          baseUrl: base,
        apiType: 'openai-responses',
      ),
      isEmpty,
    );
  });

  test('cross-protocol fallback: openai type served on /v1/models',
      () async {
    final base = await start((request) async {
      if (request.uri.path == '/models') {
        request.response.statusCode = 404;
        await request.response.close();
        return;
      }
      expect(request.uri.path, '/v1/models');
      request.response.add(utf8.encode(
          jsonEncode({'data': [{'id': 'relay-model'}]})));
      await request.response.close();
    });
    final ids = await fetchEndpointModels(
      baseUrl: base,
      apiType: 'openai-chat-completions',
    );
    expect(ids, ['relay-model']);
    expect(requests, hasLength(2), reason: 'primary then fallback');
  });

  test('401 on the primary shape is reported without fallback', () async {
    final base = await start((request) async {
      request.response.statusCode = 401;
      await request.response.close();
    });
    await expectKind(
      () => fetchEndpointModels(
          baseUrl: base,
        apiType: 'openai-chat-completions',
        apiKey: 'bad',
      ),
      EndpointModelsErrorKind.unauthorized,
    );
    expect(requests, hasLength(1), reason: 'no fallback after auth verdict');
  });

  test('HTTP 500 lands in the network kind', () async {
    final base = await start((request) async {
      request.response.statusCode = 500;
      await request.response.close();
    });
    await expectKind(
      () => fetchEndpointModels(
          baseUrl: base,
        apiType: 'openai-chat-completions',
      ),
      EndpointModelsErrorKind.network,
    );
  });

  test('connection refused lands in the network kind', () async {
    // Port 1 on loopback: nothing listens there.
    await expectKind(
      () => fetchEndpointModels(
          baseUrl: 'http://127.0.0.1:1',
        apiType: 'openai-chat-completions',
      ),
      EndpointModelsErrorKind.network,
    );
  });

  test('non-data response shape is a parse error', () async {
    final base = await start((request) async {
      request.response.add(utf8.encode(jsonEncode({'models': []})));
      await request.response.close();
    });
    await expectKind(
      () => fetchEndpointModels(
          baseUrl: base,
        apiType: 'openai-chat-completions',
      ),
      EndpointModelsErrorKind.parse,
    );
  });

  test('unparseable body is a parse error', () async {
    final base = await start((request) async {
      request.response.add(utf8.encode('<html>not json</html>'));
      await request.response.close();
    });
    await expectKind(
      () => fetchEndpointModels(
          baseUrl: base,
        apiType: 'openai-chat-completions',
      ),
      EndpointModelsErrorKind.parse,
    );
  });

  group('parseEndpointModels', () {
    test('parses the shared data array shape', () {
      expect(
        parseEndpointModels(
            jsonEncode({'data': [{'id': 'a'}, {'id': 'b'}, {'other': 1}]})),
        ['a', 'b'],
      );
    });

    test('rejects missing/non-list data', () {
      expect(
        () => parseEndpointModels(jsonEncode({'data': {}})),
        throwsA(isA<EndpointModelsException>()),
      );
      expect(
        () => parseEndpointModels('[1,2]'),
        throwsA(isA<EndpointModelsException>()),
      );
    });
  });
}
