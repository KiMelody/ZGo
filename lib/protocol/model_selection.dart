/// Desktop 3.14 `model-selection` channel — the read-only model registry
/// that replaced the `model-provider` channel (removed in 3.12.3, gap
/// closed in 3.14).
///
/// `getView` (parameter-less, live-confirmed 2026-09-19) returns:
///
/// ```
/// { revision: N, providers: [ { providerId, providerName,
///     config: { group, logo, access{…}, api{type, baseUrl},
///               builtinModelIds: […] },
///     models: [ { modelId, config: { enabled, properties{…} } } ] } ] }
/// ```
///
/// Only the mapping lives here; the call itself is DeviceSession's
/// modelProviderCatalog (same cache/failure contract as the legacy
/// `getAll` branch). `revision` is noted but unused: the catalog is
/// cached for the session lifetime and a desktop does not change its
/// registry mid-session in ways the sheet cares about.
library;

/// Normalizes a `model-selection.getView` payload into the legacy
/// `model-provider.getAll` catalog shape the chat config sheet already
/// consumes: `[{id, name, models: [{id}]}]` — `id` is the `provider`/
/// `model` half of the `providerId/modelId` switch value, `name` the
/// display name. Models with `config.enabled == false` are dropped (same
/// `!= false` tolerance as the legacy provider-level filter); malformed
/// payloads degrade to an empty catalog.
List<Map<String, dynamic>> parseModelSelectionCatalog(dynamic res) {
  final providers = res is Map ? res['providers'] : null;
  if (providers is! List) return const [];
  return [
    for (final p in providers)
      if (p is Map && p['providerId'] != null)
        {
          'id': '${p['providerId']}',
          'name': '${p['providerName'] ?? p['providerId']}',
          'models': [
            for (final m in (p['models'] as List? ?? const []))
              if (m is Map &&
                  m['modelId'] != null &&
                  (m['config'] is! Map || m['config']['enabled'] != false))
                {'id': '${m['modelId']}'},
          ],
        },
  ];
}
