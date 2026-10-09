/// Typed parse of the `usage-stats` channel snapshots:
/// `getAppUsageSnapshot` (app usage tab) and `getCodingPlanUsageSnapshot`
/// (coding-plan tab). Wire shapes from the desktop 3.14.4 zod schemas
/// (task 10-08-parity-usage, research/design-inputs.md §3/§4).
///
/// Pure Dart, widget-free: hand-written defensive chains per
/// protocol-guidelines §6 — a mistyped field degrades to its zero value
/// instead of throwing, because a drifted desktop must degrade the
/// surface, never crash the page.
library;

/// One `getAppUsageSnapshot` response.
class AppUsageSnapshot {
  final String range;
  final String timeZone;

  /// `'agent-db'` (local sessions) or `'bigmodel-monitor'` — the backup
  /// source where `longestSessionMs` / streaks are pinned to 0 and
  /// `heatmap.weeks` is empty (§3 备胎源注意): surfaces must render the
  /// empty state, not a broken chart.
  final String source;
  final AppUsageSummary? summary;
  final UsageHeatmap heatmap;
  final List<AppDailyUsage> dailyModelUsage;
  final List<AppModelUsage> models;

  /// Per-tool aggregates. The app tab consumes none of it today
  /// (design-inputs open question #2); parsed for schema coverage.
  final List<AppToolUsage> tools;

  const AppUsageSnapshot({
    this.range = '',
    this.timeZone = '',
    this.source = '',
    this.summary,
    this.heatmap = const UsageHeatmap(),
    this.dailyModelUsage = const [],
    this.models = const [],
    this.tools = const [],
  });

  bool get isMonitorSource => source == 'bigmodel-monitor';
}

/// `summary` block — typed passthrough of the 19-field zod object.
class AppUsageSummary {
  final int totalTokens;
  final int inputTokens;
  final int outputTokens;
  final int reasoningTokens;
  final int cacheCreationTokens;
  final int cacheReadTokens;
  final num cacheHitRate;
  final int totalSessions;
  final int totalTurns;
  final int toolCallCount;
  final num toolErrorRate;
  final num modelErrorRate;

  /// Nullable server-side averages (absent → null, never 0).
  final int? avgTimeToFirstTokenMs;
  final int? avgTurnDurationMs;
  final int activeDays;
  final int currentStreakDays;
  final int longestSessionMs;
  final int longestStreakDays;
  final int peakDayTokens;
  final AppFavoriteModel? favoriteModel;

  const AppUsageSummary({
    this.totalTokens = 0,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.reasoningTokens = 0,
    this.cacheCreationTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheHitRate = 0,
    this.totalSessions = 0,
    this.totalTurns = 0,
    this.toolCallCount = 0,
    this.toolErrorRate = 0,
    this.modelErrorRate = 0,
    this.avgTimeToFirstTokenMs,
    this.avgTurnDurationMs,
    this.activeDays = 0,
    this.currentStreakDays = 0,
    this.longestSessionMs = 0,
    this.longestStreakDays = 0,
    this.peakDayTokens = 0,
    this.favoriteModel,
  });
}

class AppFavoriteModel {
  final String? modelId;
  final int totalTokens;
  final num share;

  const AppFavoriteModel({
    this.modelId,
    this.totalTokens = 0,
    this.share = 0,
  });
}

/// `heatmap` block: weekly grid of day cells; `days` elements are
/// nullable (server sends `Array<cell | null>`).
class UsageHeatmap {
  final String? startDate;
  final String? endDate;
  final int maxTokens;
  final List<UsageHeatmapWeek> weeks;

  const UsageHeatmap({
    this.startDate,
    this.endDate,
    this.maxTokens = 0,
    this.weeks = const [],
  });
}

class UsageHeatmapWeek {
  final int weekIndex;

  /// Day cells in server order, nulls preserved (empty placeholder days).
  final List<UsageHeatmapCell?> days;

  const UsageHeatmapWeek({this.weekIndex = 0, this.days = const []});
}

class UsageHeatmapCell {
  final String date;

  /// Server-computed intensity 0-4 (daily mode renders it as-is);
  /// out-of-range values clamp.
  final int level;
  final int totalTokens;
  final int turnCount;
  final int toolCallCount;

  const UsageHeatmapCell({
    this.date = '',
    this.level = 0,
    this.totalTokens = 0,
    this.turnCount = 0,
    this.toolCallCount = 0,
  });
}

/// `dailyModelUsage` row: one day with its per-model token counts.
class AppDailyUsage {
  final String date;
  final List<AppModelDayUsage> models;

  const AppDailyUsage({this.date = '', this.models = const []});
}

class AppModelDayUsage {
  final String? modelId;
  final int totalTokens;

  const AppModelDayUsage({this.modelId, this.totalTokens = 0});
}

/// `models` row — server order is share-descending; surfaces keep it
/// (the trend chart slices the first 6, the ring caps at 6 slices).
class AppModelUsage {
  final String? modelId;
  final int totalTokens;
  final int inputTokens;
  final int outputTokens;
  final int requestCount;
  final num share;

  const AppModelUsage({
    this.modelId,
    this.totalTokens = 0,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.requestCount = 0,
    this.share = 0,
  });
}

class AppToolUsage {
  final String toolName;
  final int callCount;
  final int errorCount;
  final num errorRate;
  final int? avgDurationMs;

  const AppToolUsage({
    this.toolName = '',
    this.callCount = 0,
    this.errorCount = 0,
    this.errorRate = 0,
    this.avgDurationMs,
  });
}

/// Defensive parse of one `getAppUsageSnapshot` response. Never throws
/// on shape drift: missing blocks degrade to empty/zero carriers.
AppUsageSnapshot parseAppUsageSnapshot(Object? raw) {
  if (raw is! Map) return const AppUsageSnapshot();
  return AppUsageSnapshot(
    range: '${raw['range'] ?? ''}',
    timeZone: '${raw['timeZone'] ?? ''}',
    source: '${raw['source'] ?? ''}',
    summary: raw['summary'] is Map ? _parseSummary(raw['summary'] as Map) : null,
    heatmap: _parseHeatmap(raw['heatmap']),
    dailyModelUsage: _parseDailyUsage(raw['dailyModelUsage']),
    models: _parseModels(raw['models']),
    tools: _parseTools(raw['tools']),
  );
}

int _int(Object? v) => v is num ? v.toInt() : 0;
num _num(Object? v) => v is num ? v : 0;
int? _intOrNull(Object? v) => v is num ? v.toInt() : null;

AppUsageSummary _parseSummary(Map s) => AppUsageSummary(
      totalTokens: _int(s['totalTokens']),
      inputTokens: _int(s['inputTokens']),
      outputTokens: _int(s['outputTokens']),
      reasoningTokens: _int(s['reasoningTokens']),
      cacheCreationTokens: _int(s['cacheCreationTokens']),
      cacheReadTokens: _int(s['cacheReadTokens']),
      cacheHitRate: _num(s['cacheHitRate']),
      totalSessions: _int(s['totalSessions']),
      totalTurns: _int(s['totalTurns']),
      toolCallCount: _int(s['toolCallCount']),
      toolErrorRate: _num(s['toolErrorRate']),
      modelErrorRate: _num(s['modelErrorRate']),
      avgTimeToFirstTokenMs: _intOrNull(s['avgTimeToFirstTokenMs']),
      avgTurnDurationMs: _intOrNull(s['avgTurnDurationMs']),
      activeDays: _int(s['activeDays']),
      currentStreakDays: _int(s['currentStreakDays']),
      longestSessionMs: _int(s['longestSessionMs']),
      longestStreakDays: _int(s['longestStreakDays']),
      peakDayTokens: _int(s['peakDayTokens']),
      favoriteModel: s['favoriteModel'] is Map
          ? _parseFavoriteModel(s['favoriteModel'] as Map)
          : null,
    );

AppFavoriteModel _parseFavoriteModel(Map f) => AppFavoriteModel(
      modelId: f['modelId'] is String ? f['modelId'] as String : null,
      totalTokens: _int(f['totalTokens']),
      share: _num(f['share']),
    );

UsageHeatmap _parseHeatmap(Object? raw) {
  if (raw is! Map) return const UsageHeatmap();
  final weeks = raw['weeks'];
  return UsageHeatmap(
    startDate: raw['startDate'] is String ? raw['startDate'] as String : null,
    endDate: raw['endDate'] is String ? raw['endDate'] as String : null,
    maxTokens: _int(raw['maxTokens']),
    weeks: weeks is List
        ? [
            for (final w in weeks)
              if (w is Map) _parseWeek(w),
          ]
        : const [],
  );
}

UsageHeatmapWeek _parseWeek(Map w) {
  final days = w['days'];
  return UsageHeatmapWeek(
    weekIndex: _int(w['weekIndex']),
    // Null placeholders stay in position — the array index is the weekday
    // row, so filtering them would shift every later day up a row.
    days: days is List
        ? [
            for (final d in days)
              if (d is Map)
                UsageHeatmapCell(
                  date: '${d['date'] ?? ''}',
                  // Server sends 0-4; clamp so a drifted value can never
                  // index out of the color ladder.
                  level: _int(d['level']).clamp(0, 4),
                  totalTokens: _int(d['totalTokens']),
                  turnCount: _int(d['turnCount']),
                  toolCallCount: _int(d['toolCallCount']),
                )
              else
                null,
          ]
        : const [],
  );
}

List<AppDailyUsage> _parseDailyUsage(Object? raw) => raw is List
    ? [
        for (final d in raw)
          if (d is Map)
            AppDailyUsage(
              date: '${d['date'] ?? ''}',
              models: d['models'] is List
                  ? [
                      for (final m in d['models'] as List)
                        if (m is Map)
                          AppModelDayUsage(
                            modelId:
                                m['modelId'] is String ? m['modelId'] as String : null,
                            totalTokens: _int(m['totalTokens']),
                          ),
                    ]
                  : const [],
            ),
      ]
    : const [];

List<AppModelUsage> _parseModels(Object? raw) => raw is List
    ? [
        for (final m in raw)
          if (m is Map)
            AppModelUsage(
              modelId: m['modelId'] is String ? m['modelId'] as String : null,
              totalTokens: _int(m['totalTokens']),
              inputTokens: _int(m['inputTokens']),
              outputTokens: _int(m['outputTokens']),
              requestCount: _int(m['requestCount']),
              share: _num(m['share']),
            ),
      ]
    : const [];

List<AppToolUsage> _parseTools(Object? raw) => raw is List
    ? [
        for (final t in raw)
          if (t is Map)
            AppToolUsage(
              toolName: '${t['toolName'] ?? ''}',
              callCount: _int(t['callCount']),
              errorCount: _int(t['errorCount']),
              errorRate: _num(t['errorRate']),
              avgDurationMs: _intOrNull(t['avgDurationMs']),
            ),
      ]
    : const [];

// --------------------------------------------------------------------------
// coding plan snapshot (`usage-stats.getCodingPlanUsageSnapshot`)
// --------------------------------------------------------------------------

/// One `getCodingPlanUsageSnapshot` response (design-inputs §4.2, builder
/// `Gj`). Only the blocks the ZGo card renders are typed; `detail` /
/// `toolUsage` / `health` stay unparsed (the desktop's own surfaces for
/// them are cut from the ZGo v1 card).
class CodingPlanUsageSnapshot {
  final String range;
  final String sourceProvider;

  /// Raw `quota: {level, limits}` block — the three quota cards read
  /// `limits` with the exact type+unit+number matching discipline from
  /// entitlement-quota-semantics §2. Null when the plan exposes none.
  final Map<String, dynamic>? quota;
  final CodingPlanActivitySummary? activity;
  final CodingPlanModelUsage? modelUsage;

  const CodingPlanUsageSnapshot({
    this.range = '',
    this.sourceProvider = '',
    this.quota,
    this.activity,
    this.modelUsage,
  });
}

/// `activity.summary` block (desktop activity card `Bwn`).
class CodingPlanActivitySummary {
  final int totalTokens;
  final int peakDailyTokens;
  final String? peakDailyTokensDate;
  final int totalUsageDurationMs;
  final int currentStreakDays;
  final int longestStreakDays;
  final String? favoriteModelName;

  const CodingPlanActivitySummary({
    this.totalTokens = 0,
    this.peakDailyTokens = 0,
    this.peakDailyTokensDate,
    this.totalUsageDurationMs = 0,
    this.currentStreakDays = 0,
    this.longestStreakDays = 0,
    this.favoriteModelName,
  });
}

/// `modelUsage` block: per-model token series over the snapshot range.
class CodingPlanModelUsage {
  final int totalModelCallCount;
  final int totalTokensUsage;

  /// Shared x labels (`xTime`); empty when the desktop sends none.
  final List<String> xLabels;
  final List<CodingPlanModelSeries> series;

  const CodingPlanModelUsage({
    this.totalModelCallCount = 0,
    this.totalTokensUsage = 0,
    this.xLabels = const [],
    this.series = const [],
  });
}

/// One `modelDataList` row.
class CodingPlanModelSeries {
  final String modelName;
  final List<double> tokensUsage;

  const CodingPlanModelSeries({this.modelName = '', this.tokensUsage = const []});

  int get total => tokensUsage.fold(0, (a, b) => a + b.round());
}

CodingPlanUsageSnapshot parseCodingPlanUsageSnapshot(Object? raw) {
  if (raw is! Map) return const CodingPlanUsageSnapshot();
  final quota = raw['quota'];
  final activity = raw['activity'];
  final activitySummary = activity is Map ? activity['summary'] : null;
  final modelUsage = raw['modelUsage'];
  return CodingPlanUsageSnapshot(
    range: '${raw['range'] ?? ''}',
    sourceProvider: '${raw['sourceProvider'] ?? ''}',
    quota: quota is Map ? Map<String, dynamic>.from(quota) : null,
    activity: activitySummary is Map
        ? CodingPlanActivitySummary(
            totalTokens: _int(activitySummary['totalTokens']),
            peakDailyTokens: _int(activitySummary['peakDailyTokens']),
            peakDailyTokensDate: activitySummary['peakDailyTokensDate'] is String
                ? activitySummary['peakDailyTokensDate'] as String
                : null,
            totalUsageDurationMs: _int(activitySummary['totalUsageDurationMs']),
            currentStreakDays: _int(activitySummary['currentStreakDays']),
            longestStreakDays: _int(activitySummary['longestStreakDays']),
            favoriteModelName: activitySummary['favoriteModelName'] is String
                ? activitySummary['favoriteModelName'] as String
                : null,
          )
        : null,
    modelUsage: modelUsage is Map ? _parseModelUsage(modelUsage) : null,
  );
}

CodingPlanModelUsage _parseModelUsage(Map m) {
  final xLabels = m['xTime'];
  final rows = m['modelDataList'];
  return CodingPlanModelUsage(
    totalModelCallCount: _int(m['totalModelCallCount']),
    totalTokensUsage: _int(m['totalTokensUsage']),
    xLabels: xLabels is List
        ? [for (final l in xLabels) if (l != null) '$l']
        : const [],
    series: rows is List
        ? [
            for (final r in rows)
              if (r is Map)
                CodingPlanModelSeries(
                  modelName: '${r['modelName'] ?? ''}',
                  tokensUsage: r['tokensUsage'] is List
                      ? [
                          for (final v in r['tokensUsage'] as List)
                            if (v is num) v.toDouble(),
                        ]
                      : const [],
                ),
          ]
        : const [],
  );
}
