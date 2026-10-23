import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'plan_api.dart';
import 'plan_local_memo.dart';
import 'plan_models.dart';
import 'plan_oauth.dart';

/// Persistence seam for the plan account state. The token lives only in
/// storage here — no log or exception path may ever carry it (red line).
abstract class PlanTokenStore {
  Future<String?> readToken();
  Future<void> writeToken(String token);
  Future<void> clearToken();

  /// The `X-Device-Mid` header value. First call generates a UUID v4 and
  /// persists it; the desktop's device id is never reused.
  Future<String> deviceMid();
}

/// [PlanTokenStore] backed by flutter_secure_storage. On ohos the SIG
/// companion plugin serves the same method channel transparently (see the
/// pubspec note), so this single implementation covers every platform.
class SecurePlanTokenStore implements PlanTokenStore {
  static const _tokenKey = 'zgo_plan_token';
  static const _deviceMidKey = 'zgo_plan_device_mid';

  final FlutterSecureStorage _storage;
  SecurePlanTokenStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<String?> readToken() => _storage.read(key: _tokenKey);

  @override
  Future<void> writeToken(String token) =>
      _storage.write(key: _tokenKey, value: token);

  @override
  Future<void> clearToken() async {
    await _storage.delete(key: _tokenKey);
  }

  @override
  Future<String> deviceMid() async {
    final existing = await _storage.read(key: _deviceMidKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final mid = generateUuidV4(Random.secure());
    await _storage.write(key: _deviceMidKey, value: mid);
    return mid;
  }
}

/// RFC 4122 v4 UUID from [random] (version bits 0100, variant bits 10).
String generateUuidV4(Random random) {
  final b = List<int>.generate(16, (_) => random.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final hex = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// Account identity: the [email] captured on the OAuth path wins; the
/// JWT claims (`user_id`, falling back to `sub`) stay as the manual-paste
/// fallback. Null when neither exists — the UI hides the label rather
/// than guessing.
String? planAccountLabel(String token, {String? email}) {
  final mail = email?.trim() ?? '';
  if (mail.isNotEmpty) return mail;
  try {
    final parts = token.split('.');
    if (parts.length < 2) return null;
    final payload = base64Url.decode(base64Url.normalize(parts[1]));
    final claims = jsonDecode(utf8.decode(payload));
    if (claims is! Map) return null;
    final id = claims['user_id'] ?? claims['sub'];
    if (id is String && id.isNotEmpty) return id;
    if (id is num) return '$id';
    return null;
  } catch (_) {
    return null;
  }
}

/// Factory for the per-attempt OAuth device flow machine (tests inject a
/// PlanOAuth wired to a mock client / immediate delay).
typedef CreatePlanOAuth = PlanOAuth Function();

/// Global account state for the plan plane: login state + latest snapshot
/// + last error, one ChangeNotifier consumed by the settings entry row and
/// the plan page via constructor injection.
///
/// Deliberately outside [DeviceSession] / QuotaWatch: this is the account
/// data plane (z.ai billing REST), unrelated to the relay quota plane.
class PlanController extends ChangeNotifier {
  PlanController({
    PlanApi? api,
    PlanTokenStore? store,
    PlanLocalMemo? memo,
    CreatePlanOAuth? oauthFactory,
    DateTime Function()? now,
  })  : _api = api ?? PlanApi(),
        _store = store ?? SecurePlanTokenStore(),
        _memo = memo ?? SharedPrefsPlanMemo(),
        _oauthFactory = oauthFactory ?? PlanOAuth.new,
        _now = now ?? DateTime.now;

  final PlanApi _api;
  final PlanTokenStore _store;
  final PlanLocalMemo _memo;
  final CreatePlanOAuth _oauthFactory;
  final DateTime Function() _now;

  String? _token;
  bool _loaded = false;
  Future<void>? _identityLoad;
  bool _signedIn = false;
  bool _authExpired = false;
  bool _fetching = false;
  bool _disposed = false;
  PlanApiException? _error;
  PlanSnapshot _snapshot = PlanSnapshot.empty;
  String? _accountLabel;
  PlanOAuth? _oauth;
  bool _oauthInProgress = false;
  String? _oauthAuthorizeUrl;
  PlanOAuthFailureReason? _oauthFailure;
  DateTime? _memoExpiry;

  bool get signedIn => _signedIn;

  /// In-memory ZCode JWT (the same credential persisted under
  /// `zgo_plan_token`). Exposed ONLY as the relay-V2 terminal-auth seam —
  /// never log, display or persist it elsewhere.
  String? get token => _token;

  /// 401 has been seen since the last successful fetch → the UI prompts
  /// for re-login; stale data stays visible.
  bool get authExpired => _authExpired;
  bool get fetching => _fetching;

  /// Last failed refresh; null after any success. Kept alongside the stale
  /// snapshot so the page can show "数据时间 N 分钟前".
  PlanApiException? get error => _error;
  PlanSnapshot get snapshot => _snapshot;
  String? get accountLabel => _accountLabel;

  /// A device-flow sign-in is running (idle → inProgress phase of the
  /// sign-in card).
  bool get oauthInProgress => _oauthInProgress;

  /// The server-built authorize URL while [oauthInProgress] — the page
  /// shows, copies and re-opens it.
  String? get oauthAuthorizeUrl => _oauthAuthorizeUrl;

  /// Why the last device flow failed (userCancelled never lands here —
  /// cancelling is not an error); the sign-in card renders it with a
  /// retry affordance. Null on idle/success.
  PlanOAuthFailureReason? get oauthFailure => _oauthFailure;

  /// The "plan expired on X" date for the empty-bucket state: the memoized
  /// latest expiry, from the last *successful* fetch, strictly before the
  /// current moment. Null → the plain "no plan data" empty state (no memo,
  /// date still current, clock rolled back, or the last fetch failed — an
  /// error is not evidence of expiry).
  DateTime? get expiredOn {
    if (_error != null) return null;
    if (_snapshot.buckets.isNotEmpty) return null;
    final memo = _memoExpiry;
    if (memo == null) return null;
    // Boundary decided here once (strict `<`): a memo date equal to the
    // judging moment is not expired yet, so a rolled-back device clock
    // falls back to the plain empty state instead of guessing.
    return memo.isBefore(_now()) ? memo : null;
  }

  /// Boots from the persisted token; idempotent, safe to call on every
  /// page entry (only the first call fetches).
  Future<void> ensureLoaded() async {
    if (_loaded || _disposed) return;
    _loaded = true;
    await loadIdentity();
    if (!_signedIn || _disposed) return;
    await refresh();
  }

  /// Reads only the persisted identity (no network) — the app-root calls
  /// this once so the settings entry row shows the real signed-in state;
  /// the actual fetch waits for the page entry (R3: fetch on page open).
  ///
  /// Concurrent callers share one in-flight Future: the app root fires this
  /// unawaited while the relay-V2 `jwtProvider` awaits it on the first
  /// connection, and a second call must not return before `_token` is set
  /// (cold-start false `auth-required`).
  Future<void> loadIdentity() {
    if (_disposed) return Future.value();
    return _identityLoad ??= _readIdentity();
  }

  Future<void> _readIdentity() async {
    // The expiry memo rides the same boot path as the token so an empty
    // snapshot right after startup can already be classified. A failed
    // read silently degrades to no memory (never-throw contract).
    try {
      _memoExpiry = await _memo.readPlanExpiry();
    } catch (_) {
      _memoExpiry = null;
    }
    String? token;
    try {
      token = await _store.readToken();
    } catch (_) {
      // Same never-throw contract as the memo read. The shared
      // [_identityLoad] Future must not cache the failure: a boot-time
      // read error would otherwise keep jwtProvider permanently
      // auth-required and a later sign-in could never repair the relay.
      token = null;
    }
    if (_disposed) return;
    if (token == null || token.isEmpty) {
      notifyListeners();
      return;
    }
    _token = token;
    _signedIn = true;
    _accountLabel = planAccountLabel(token);
    notifyListeners();
  }

  /// v0 login path: paste a zcode JWT. Returns false (and does nothing)
  /// for blank input; validity is proven by the server, not by us.
  Future<bool> signIn(String rawToken) async {
    final token = rawToken.trim();
    if (token.isEmpty || _disposed) return false;
    _token = token;
    _signedIn = true;
    _authExpired = false;
    _accountLabel = planAccountLabel(token);
    _memoExpiry = null;
    notifyListeners();
    await _store.writeToken(token);
    // Identity switch: drop the previous account's expiry memo so it can
    // never pollute the new account's empty-bucket state.
    await _clearMemo();
    await refresh();
    return true;
  }

  /// v1 login path: OAuth device flow. Drives a fresh [PlanOAuth] machine
  /// to its terminal outcome; `ready` stores the token (same seam as the
  /// manual path) and immediately pulls the balance through the shared
  /// fetch/error semantics. Flow failures land in [oauthFailure] for the
  /// sign-in card; userCancelled is silent (back to idle).
  Future<void> signInWithOAuth() async {
    if (_disposed || _oauthInProgress) return;
    final oauth = _oauthFactory();
    _oauth = oauth;
    _oauthInProgress = true;
    _oauthAuthorizeUrl = null;
    _oauthFailure = null;
    notifyListeners();
    PlanOAuthOutcome outcome;
    try {
      outcome = await oauth.start(onAuthorizeUrl: (url) {
        if (_disposed) return;
        _oauthAuthorizeUrl = url;
        notifyListeners();
      });
    } finally {
      _oauth = null;
    }
    if (_disposed) return;
    _oauthInProgress = false;
    _oauthAuthorizeUrl = null;
    if (outcome is PlanOAuthSuccess) {
      _token = outcome.token;
      _signedIn = true;
      _authExpired = false;
      _error = null;
      // Email is a memory-only label: the persisted token already carries
      // user_id (JWT claims) so a restart falls back to it — no extra
      // secure-storage key for a cosmetic value.
      _accountLabel =
          planAccountLabel(outcome.token, email: outcome.user.email);
      _memoExpiry = null;
      notifyListeners();
      await _store.writeToken(outcome.token);
      // Same identity-switch rule as [signIn]: the new account starts with
      // a clean expiry memo.
      await _clearMemo();
      await refresh();
      return;
    }
    final reason = (outcome as PlanOAuthFailed).reason;
    if (reason != PlanOAuthFailureReason.userCancelled) {
      _oauthFailure = reason;
    }
    notifyListeners();
  }

  /// Cancels the running device flow, if any; the machine settles with
  /// userCancelled and the controller returns to the idle sign-in card.
  void cancelSignIn() => _oauth?.cancel();

  /// Fetch-once refresh (page entry + manual pull-to-refresh; no polling).
  Future<void> refresh() async {
    final token = _token;
    if (token == null || _disposed) return;
    _setFetching(true);
    try {
      final mid = await _store.deviceMid();
      if (_disposed) return;
      final snap = await _api.fetchBalance(token: token, deviceMid: mid);
      if (_disposed) return;
      _snapshot = snap;
      _error = null;
      _authExpired = false;
      _rememberExpiry(snap);
    } on PlanAuthExpired catch (e) {
      if (_disposed) return;
      _error = e;
      _authExpired = true;
    } on PlanApiException catch (e) {
      if (_disposed) return;
      _error = e;
    } finally {
      _setFetching(false);
    }
  }

  Future<void> signOut() async {
    if (_disposed) return;
    _token = null;
    _signedIn = false;
    _authExpired = false;
    _error = null;
    _accountLabel = null;
    _oauthFailure = null;
    _snapshot = PlanSnapshot.empty;
    _memoExpiry = null;
    notifyListeners();
    await _store.clearToken();
    await _clearMemo();
  }

  /// R1: on a successful non-empty snapshot, re-arm the expiry memo with
  /// the latest `periodEnd` across all buckets (multi-plan: the latest
  /// expiry wins, so an old expired plan never shadows a live one; buckets
  /// without a date are skipped and an all-null set writes nothing).
  /// Persisted fire-and-forget — the memo only refines the empty-state
  /// copy, so a lost write degrades to the plain empty state.
  void _rememberExpiry(PlanSnapshot snap) {
    DateTime? latest;
    for (final b in snap.buckets) {
      final end = b.periodEnd;
      if (end != null && (latest == null || end.isAfter(latest))) {
        latest = end;
      }
    }
    if (latest == null || latest == _memoExpiry) return;
    _memoExpiry = latest;
    _persistMemo(latest);
  }

  /// Memo persistence never throws: a failed write degrades to no memory.
  /// Not awaited by [refresh] — nothing downstream depends on the flush.
  Future<void> _persistMemo(DateTime d) async {
    try {
      await _memo.writePlanExpiry(d);
    } catch (_) {
      // Silent: the empty state falls back to "no plan data".
    }
  }

  /// Same never-throw contract for the clear path ([signOut] /
  /// [signIn] / [signInWithOAuth]).
  Future<void> _clearMemo() async {
    try {
      await _memo.clearPlanExpiry();
    } catch (_) {
      // Silent: a stale memo only mislabels an empty state, never breaks it.
    }
  }

  void _setFetching(bool value) {
    if (_disposed) return;
    _fetching = value;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // Stop a mid-flight device flow so it cannot outlive the controller.
    _oauth?.cancel();
    super.dispose();
  }
}
