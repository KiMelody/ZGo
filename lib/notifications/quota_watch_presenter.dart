import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../state/entitlement_poller.dart';
import '../state/quota_reset.dart';
import '../state/quota_watch.dart';
import '../ui/ui_settings.dart';
import 'notification_service.dart';

/// Dart side of the quota-watch notices: turns the state layer's judged
/// snapshots/events into user-visible surfaces —
///
/// - the persistent notice (custom RemoteViews via the native side, since
///   the system template can draw neither a ring nor a same-row action),
///   re-rendered from every [QuotaWatchController.snapshot],
/// - the one-shot system-template notifications (N3 alert / N4 expiry
///   reminder / N5 reset feedback) on edge events.
///
/// All copy is assembled here from the `op.watch.*` table (both locales);
/// the native side only receives final strings. The pending-reset memory
/// records whichever button the user last saw, so a native tap
/// (`resetPressed` / the shared action id) is served without re-deriving.
class QuotaWatchPresenter {
  QuotaWatchPresenter({
    required NotificationService service,
    required String Function() localeOf,
    required Future<void> Function(QuotaWindowKind? kind) onReset,
    required Future<void> Function() onOpenUsage,
    required Future<void> Function() onRefresh,
  })  : _service = service,
        _localeOf = localeOf,
        _onReset = onReset,
        _onOpenUsage = onOpenUsage,
        _onRefresh = onRefresh;

  static const _channel = MethodChannel('zgo/quota_watch');

  /// Action id shared by the one-shot reset buttons; NotificationService
  /// routes the tap back through [NotificationService.onAction].
  static const resetActionId = 'quota_watch_reset';

  final NotificationService _service;
  final String Function() _localeOf;
  final Future<void> Function(QuotaWindowKind? kind) _onReset;
  final Future<void> Function() _onOpenUsage;
  final Future<void> Function() _onRefresh;

  QuotaWindowKind? _pendingResetKind;
  bool _pendingDegrade = false;

  // ------------------------------------------------------------ snapshot

  /// Persistent notice re-render (wired to the controller's notifier).
  /// Hidden phases withdraw the notice and clear the pending button.
  void onSnapshot(QuotaWatchSnapshot s) {
    switch (s.phase) {
      case QuotaWatchPhase.disabled:
      case QuotaWatchPhase.noPlan:
        _pendingResetKind = null;
        _pendingDegrade = false;
        unawaited(_cancelNotice());
      case QuotaWatchPhase.unavailable:
        _pendingResetKind = null;
        _pendingDegrade = false;
        unawaited(_updateNotice(s));
      case QuotaWatchPhase.normal:
      case QuotaWatchPhase.lowQuota:
      case QuotaWatchPhase.expiring:
        _pendingResetKind = s.buttonKind;
        _pendingDegrade = false;
        unawaited(_updateNotice(s));
    }
  }

  /// One-shot events (wired to the controller's event sink).
  void onEvent(QuotaWatchEvent e) {
    switch (e) {
      case QuotaLowAlertEvent():
        _showLowAlert(e);
      case QuotaExpiryEvent():
        _showExpiryReminder(e);
      case QuotaResetResultEvent():
        _showResetFeedback(e);
    }
  }

  /// The notice's reset button was tapped (native `resetPressed` push, the
  /// pending-intent pull, or a one-shot action button). A remembered
  /// window kind resets directly; the N3b degrade shape deep-links into
  /// the in-app reset dialog.
  Future<void> handleResetPress() async {
    final kind = _pendingResetKind;
    final degrade = _pendingDegrade;
    if (kind == null && !degrade) return;
    _pendingResetKind = null;
    _pendingDegrade = false;
    if (kind != null) {
      await _onReset(kind);
    } else {
      await _onReset(null); // degrade → open the reset dialog in-app
    }
  }

  /// The notice body was tapped → deep-link into the app's usage page.
  Future<void> handleOpenUsage() => _onOpenUsage();

  /// The notice's refresh icon was tapped (native `refreshPressed` push;
  /// a dead-engine tap just opens the app, whose resumed lifecycle re-polls
  /// through the same entry) → an immediate re-poll.
  Future<void> handleRefreshPress() => _onRefresh();

  // ------------------------------------------------------------- notices

  Future<void> _updateNotice(QuotaWatchSnapshot s) async {
    final now = DateTime.now();
    String? title;
    String? sub;
    Map<String, Object?>? ring;
    String? button;
    var buttonWarn = false;
    List<String>? expanded;

    if (s.phase == QuotaWatchPhase.unavailable) {
      // N6: no ring, last-success stamp, retry copy follows the cadence.
      title = _trP('op.watch.fail.title', [_clock(s.updatedAt ?? now)]);
      sub = _trP('op.watch.fail.body', [
        _trP('op.minutes', ['${s.retryEvery.inMinutes}']),
      ]);
    } else {
      final warn = s.phase == QuotaWatchPhase.lowQuota;
      ring = {
        'progress': ((s.bottleneckRemaining ?? 0).round()).clamp(0, 100),
        'warn': warn,
      };
      title = _mainLine(s);
      if (warn) {
        // N2 subline: the bottleneck type's coupon, or the honest
        // no-coupon copy (N2-nr — the other type's pool cannot save the
        // bottleneck, so no button either).
        final count = s.bottleneckCouponCount ?? 0;
        final expiry = s.bottleneckCouponExpiry;
        if (count > 0 && expiry != null) {
          sub = _couponLine(s.bottleneckKind!, count, expiry);
        } else if (s.bottleneckKind != null) {
          sub = _trP('op.watch.couponNone', [_couponLabel(s.bottleneckKind!)]);
        }
      } else if (s.phase == QuotaWatchPhase.expiring && s.expiringAt != null) {
        // N4 subline: the expiring coupon's type + countdown.
        sub = _trP('op.watch.expiringLine', [
          _couponLabel(s.expiringKind!),
          _duration(s.expiringAt!.difference(now)),
        ]);
      }
      if (s.stale) {
        // Stale tolerance (2026-09-20 真机诊断): the numbers come from the
        // retained pre-failure data — stamp the fetch time so they read as
        // old (standalone line when the phase has no subline of its own).
        final stamp = _trP('op.watch.stale.line', [_clock(s.updatedAt ?? now)]);
        sub = sub == null ? stamp : '$sub · $stamp';
      }
      if (s.buttonKind != null) {
        button = _tr(s.phase == QuotaWatchPhase.lowQuota
            ? 'op.watch.action.resetNow'
            : 'op.watch.action.reset');
        buttonWarn = warn;
      }
      expanded = _expandedLines(s);
    }

    final payload = jsonEncode({
      'ring': ring,
      'pct': ring == null ? null : '${ring['progress']}%',
      'title': title,
      'sub': sub,
      'button': button,
      'buttonWarn': buttonWarn,
      'expanded': expanded,
    });
    try {
      await _channel.invokeMethod('update', {'data': payload});
    } catch (e) {
      debugPrint('[quota-watch] notice update failed: $e');
    }
  }

  Future<void> _cancelNotice() async {
    try {
      await _channel.invokeMethod('cancel');
    } catch (e) {
      debugPrint('[quota-watch] notice cancel failed: $e');
    }
  }

  Future<void> _showLowAlert(QuotaLowAlertEvent e) async {
    final hasCoupon = e.kind != null && e.couponCount > 0;
    final degrade = e.kind == null && e.hasAnyPool;
    final title = e.kind == null
        ? _trP('op.watch.alert.titleGeneric', ['${e.remaining.round()}'])
        : _trP(
            'op.watch.alert.title', [_windowLabel(e.kind!), '${e.remaining.round()}']);
    String body;
    List<AndroidNotificationAction>? actions;
    if (hasCoupon) {
      body = _couponLine(e.kind!, e.couponCount, e.couponExpiry!);
      _pendingResetKind = e.kind;
      _pendingDegrade = false;
      actions = [
        AndroidNotificationAction(
            resetActionId, _tr('op.watch.action.resetNow')),
      ];
    } else if (degrade) {
      // N3b: unmappable window but resets exist → deep-link + in-app
      // dialog (the app's confirm flow).
      body = _tr('op.watch.alert.degradeBody');
      _pendingResetKind = null;
      _pendingDegrade = true;
      actions = [
        AndroidNotificationAction(
            resetActionId, _tr('op.watch.action.choose')),
      ];
    } else {
      // N3-nr: no coupon for the bottleneck — still warn (wrap up the
      // running tasks), but nothing to press.
      body = _trP('op.watch.alert.noResetBody', [
        e.naturalResetAt == null
            ? ''
            : _duration(e.naturalResetAt!.difference(DateTime.now())),
      ]);
    }
    await _service.show(
      NotifyChannel.quota,
      NotificationService.stableId('quota.watch.alert'),
      title,
      body,
      {'type': 'quotaWatch'},
      actions: actions,
    );
  }

  Future<void> _showExpiryReminder(QuotaExpiryEvent e) async {
    _pendingResetKind = e.kind;
    _pendingDegrade = false;
    await _service.show(
      NotifyChannel.quota,
      NotificationService.stableId('quota.watch.expiry'),
      _trP('op.watch.expiringLine', [
        _couponLabel(e.kind),
        _duration(e.expiry.difference(DateTime.now())),
      ]),
      _trP('op.watch.expiry.body', ['${e.remaining.round()}']),
      {'type': 'quotaWatch'},
      actions: [
        AndroidNotificationAction(resetActionId, _tr('op.watch.action.reset')),
      ],
    );
  }

  Future<void> _showResetFeedback(QuotaResetResultEvent e) async {
    final (title, body, id) = e.ok
        ? (
            _trP('op.watch.reset.doneTitle', [
              _tr(e.kind == QuotaWindowKind.week
                  ? 'op.watch.reset.target.week'
                  : 'op.watch.reset.target.fiveHour'),
            ]),
            _tr('op.watch.reset.doneBody'),
            'quota.watch.reset.ok',
          )
        : (
            _tr('op.watch.reset.failTitle'),
            _tr('op.watch.reset.failBody'),
            'quota.watch.reset.fail',
          );
    await _service.show(
      NotifyChannel.quota,
      NotificationService.stableId(id),
      title,
      body,
      {'type': 'quotaWatch'},
    );
  }

  // ---------------------------------------------------------------- copy

  String _tr(String key) => trLocale(_localeOf(), key);

  String _trP(String key, List<String> args) => trByKeyP(_localeOf(), key, args);

  String _windowLabel(QuotaWindowKind kind) => _tr(kind == QuotaWindowKind.fiveHour
      ? 'op.watch.window.fiveHour'
      : 'op.watch.window.week');

  String _couponLabel(QuotaWindowKind kind) => _tr(
      kind == QuotaWindowKind.fiveHour
          ? 'op.watch.coupon.fiveHour'
          : 'op.watch.coupon.week');

  /// N1/N2 main line: type label + window rollover countdown.
  String _mainLine(QuotaWatchSnapshot s) {
    if (s.bottleneckKind == null) return '';
    final label = _windowLabel(s.bottleneckKind!);
    final t = s.bottleneckResetAt == null
        ? ''
        : _duration(s.bottleneckResetAt!.difference(DateTime.now()));
    return t.isEmpty ? label : _trP('op.watch.mainLine', [label, t]);
  }

  /// N2/N4 coupon subline: relative countdown within 24h, absolute
  /// `MM-dd HH:mm` past that (a weekly coupon expiring days out).
  String _couponLine(QuotaWindowKind kind, int count, DateTime expiry) {
    final label = _couponLabel(kind);
    if (expiry.isAfter(DateTime.now().add(const Duration(hours: 24)))) {
      return _trP(
          'op.watch.couponLineAbs', [label, '$count', EntitlementView.fmtResetClock(expiry)]);
    }
    return _trP(
        'op.watch.couponLine', [label, '$count', _duration(expiry.difference(DateTime.now()))]);
  }

  /// Expanded-view detail: the other window's row + the coupon counts
  /// (single-window plans drop the window line and the weekly count —
  /// a V1 plan's weekly coupon is hidden by design).
  List<String> _expandedLines(QuotaWatchSnapshot s) {
    final lines = <String>[];
    if (s.detailKind != null) {
      final label = _windowLabel(s.detailKind!);
      final t = s.detailResetAt == null
          ? ''
          : _duration(s.detailResetAt!.difference(DateTime.now()));
      final pct = '${((s.detailRemaining ?? 0).round()).clamp(0, 100)}%';
      lines.add(t.isEmpty
          ? '$label $pct'
          : _trP('op.watch.detail.window', [label, pct, t]));
    }
    if (s.hasWeekWindow) {
      lines.add(_trP('op.watch.detail.coupons',
          ['${s.fiveHourCoupons}', '${s.weekCoupons}']));
    } else {
      lines.add(_trP('op.watch.detail.couponsFiveHour', ['${s.fiveHourCoupons}']));
    }
    return lines;
  }

  /// Duration tiers (mock 文案对照): reuse the `op.take.remaining.*` family
  /// plus the new days tier.
  String _duration(Duration d) {
    final locale = _localeOf();
    if (d.inMinutes < 1) {
      return trByKey(locale, 'op.take.remaining.lessThanMinute');
    }
    if (d.inHours < 1) {
      return trByKeyP(locale, 'op.take.remaining.minutes', ['${d.inMinutes}']);
    }
    if (d.inDays < 1) {
      final h = d.inHours;
      final m = d.inMinutes % 60;
      if (m == 0) return trByKeyP(locale, 'op.take.remaining.hours', ['$h']);
      return trByKeyP(locale, 'op.take.remaining.hoursMinutes', ['$h', '$m']);
    }
    final days = d.inDays;
    final h = d.inHours % 24;
    if (h == 0) return trByKeyP(locale, 'op.watch.duration.daysOnly', ['$days']);
    return trByKeyP(locale, 'op.watch.duration.days', ['$days', '$h']);
  }

  String _clock(DateTime at) =>
      '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}';
}
