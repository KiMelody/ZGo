/// `/models` endpoint model fetch — ZLinker enhancement beyond the official
/// remote (the desktop has no fetch-models RPC; notes.md 「/models 端点
/// 拉取定论」). Reads the provider's endpoint directly with dart:io (no
/// CORS on mobile), reusing the stored API key from the provider-settings
/// view.
///
/// Protocol matrix (probe-certified api.type values):
/// - `openai-chat-completions` / `openai-responses` → `GET {base}/models`
///   with `Authorization: Bearer <key>`;
/// - `anthropic-messages` → `GET {base}/v1/models` with `x-api-key` +
///   `anthropic-version`.
///
/// Both wire responses are `{data: [{id}, …]}`. When the primary shape
/// fails (relay stations often implement only one of the two paths) the
/// other protocol's request shape is tried once. Failures surface as
/// [EndpointModelsException] with a user-mappable kind — never silently.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

enum EndpointModelsErrorKind { network, unauthorized, parse }

class EndpointModelsException implements Exception {
  final EndpointModelsErrorKind kind;
  final String detail;
  EndpointModelsException(this.kind, this.detail);

  @override
  String toString() => 'EndpointModelsException($kind): $detail';
}

/// One request shape (path + auth headers) derived from the api.type.
class _RequestShape {
  final String pathSuffix;
  final Map<String, String> headers;
  const _RequestShape(this.pathSuffix, this.headers);
}

_RequestShape _shapeOf(String apiType, String? apiKey) {
  if (apiType == 'anthropic-messages') {
    return _RequestShape('/v1/models', {
      if (apiKey != null && apiKey.isNotEmpty) 'x-api-key': apiKey,
      'anthropic-version': '2023-06-01',
    });
  }
  // openai-chat-completions / openai-responses
  return _RequestShape('/models', {
    if (apiKey != null && apiKey.isNotEmpty)
      'Authorization': 'Bearer $apiKey',
  });
}

Uri _modelsUri(String baseUrl, String pathSuffix) {
  var base = baseUrl.trim();
  while (base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }
  return Uri.parse('$base$pathSuffix');
}

/// Parses `{data: [{id}, …]}` (both protocols share the shape). Throws a
/// parse-kind [EndpointModelsException] on any other shape.
List<String> parseEndpointModels(String body) {
  Object? json;
  try {
    json = jsonDecode(body);
  } catch (e) {
    throw EndpointModelsException(
        EndpointModelsErrorKind.parse, 'invalid JSON: $e');
  }
  final data = json is Map ? json['data'] : null;
  if (data is! List) {
    throw EndpointModelsException(
        EndpointModelsErrorKind.parse, 'response has no data array');
  }
  return [
    for (final m in data)
      if (m is Map && m['id'] != null && '${m['id']}'.isNotEmpty) '${m['id']}',
  ];
}

Future<List<String>> _tryShape(
  HttpClient client,
  Uri uri,
  _RequestShape shape,
) async {
  HttpClientRequest request;
  try {
    request = await client.getUrl(uri);
  } catch (e) {
    throw EndpointModelsException(EndpointModelsErrorKind.network, '$e');
  }
  shape.headers.forEach((name, value) => request.headers.set(name, value));
  HttpClientResponse response;
  try {
    response = await request.close().timeout(const Duration(seconds: 15));
  } catch (e) {
    throw EndpointModelsException(EndpointModelsErrorKind.network, '$e');
  }
  if (response.statusCode == 401 || response.statusCode == 403) {
    throw EndpointModelsException(
        EndpointModelsErrorKind.unauthorized, 'HTTP ${response.statusCode}');
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw EndpointModelsException(
        EndpointModelsErrorKind.network, 'HTTP ${response.statusCode}');
  }
  String body;
  try {
    body = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 15));
  } catch (e) {
    throw EndpointModelsException(EndpointModelsErrorKind.network, '$e');
  }
  return parseEndpointModels(body);
}

/// Fetches the model id list of one endpoint. `apiType` is the certified
/// provider-settings value; a wrong guess falls back to the other
/// protocol's shape once. Throws [EndpointModelsException]. The throwaway
/// [HttpClient] is created and closed here — callers stay dart:io-free.
Future<List<String>> fetchEndpointModels({
  required String baseUrl,
  required String apiType,
  String? apiKey,
}) async {
  final client = HttpClient();
  try {
    final primary = _shapeOf(apiType, apiKey);
    final fallback = _shapeOf(
        apiType == 'anthropic-messages' ? 'openai-chat' : 'anthropic-messages',
        apiKey);
    try {
      return await _tryShape(
          client, _modelsUri(baseUrl, primary.pathSuffix), primary);
    } on EndpointModelsException catch (primaryError) {
      // Retry once with the other protocol's shape — unless the endpoint
      // already answered with a definite auth verdict.
      if (primaryError.kind == EndpointModelsErrorKind.unauthorized) rethrow;
      try {
        return await _tryShape(
            client, _modelsUri(baseUrl, fallback.pathSuffix), fallback);
      } on EndpointModelsException catch (fallbackError) {
        if (fallbackError.kind == EndpointModelsErrorKind.unauthorized) {
          rethrow;
        }
        // Neither shape answered: report the primary failure.
        throw primaryError;
      }
    }
  } finally {
    client.close(force: true);
  }
}
