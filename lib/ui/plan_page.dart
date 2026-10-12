import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../plan/plan_account.dart';
import '../plan/plan_models.dart';
import '../plan/plan_oauth.dart';
import 'theme.dart';
import 'ui_settings.dart';

/// Seam for opening the authorize URL (tests inject a recorder; the
/// default goes through url_launcher in an external browser).
typedef PlanUrlLauncher = Future<bool> Function(Uri url);

/// yyyy-MM-dd in the local zone — shared by the bucket expiry line and
/// the expired empty state.
String _fmtPlanDate(DateTime t) => t.toLocal().toString().substring(0, 10);

/// Account-level coding-plan quotas (z.ai billing plane) — bucket list
/// with "remaining" semantics, mirroring the relay quota panel's visual
/// language (usageBlue bars, usageGreen expiry line) without touching its
/// data path.
class PlanPage extends StatefulWidget {
  final PlanController controller;

  /// Optional launch seam; defaults to url_launcher external-application.
  final PlanUrlLauncher? urlLauncher;

  const PlanPage({
    super.key,
    required this.controller,
    this.urlLauncher,
  });

  @override
  State<PlanPage> createState() => _PlanPageState();
}

class _PlanPageState extends State<PlanPage> {
  final _tokenField = TextEditingController();

  late final PlanUrlLauncher _launch =
      widget.urlLauncher ?? _defaultLaunch;

  static Future<bool> _defaultLaunch(Uri url) async {
    try {
      return await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  @override
  void initState() {
    super.initState();
    // R3: fetch once per page entry; the controller dedupes re-entries.
    widget.controller.ensureLoaded();
  }

  @override
  void dispose() {
    _tokenField.dispose();
    super.dispose();
  }

  Future<void> _submitToken() async {
    final ok = await widget.controller.signIn(_tokenField.text);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr(context, 'plan.signIn.invalid')),
      ));
      return;
    }
    _tokenField.clear();
  }

  Future<void> _openAuthorizeUrl() async {
    final url = widget.controller.oauthAuthorizeUrl;
    if (url == null) return;
    final ok = await _launch(Uri.parse(url));
    if (!mounted || ok) return;
    // Launch failure must not break the flow — the URL stays on the card
    // for manual copy as the guaranteed fallback.
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(tr(context, 'plan.signIn.launchFailed')),
    ));
  }

  Future<void> _copyAuthorizeUrl() async {
    final url = widget.controller.oauthAuthorizeUrl;
    if (url == null) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(tr(context, 'plan.signIn.oauthCopied')),
    ));
  }

  void _cancelSignIn() {
    widget.controller.cancelSignIn();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(tr(context, 'plan.signIn.oauthCancelled')),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'plan.title'))),
      body: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final snap = controller.snapshot;
          final expiredOn = controller.expiredOn;
          return RefreshIndicator(
            onRefresh: () => controller.refresh(),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: zContentMaxWidth),
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: zScreenPadding(context, top: 8, bottom: 24),
                  children: [
                    if (!controller.signedIn)
                      _SignInCard(
                        controller: controller,
                        onSignInOAuth: controller.signInWithOAuth,
                        onOpenAuthorizeUrl: _openAuthorizeUrl,
                        onCopyAuthorizeUrl: _copyAuthorizeUrl,
                        onCancel: _cancelSignIn,
                        tokenField: _tokenField,
                        onSubmitToken: _submitToken,
                      )
                    else ...[
                      _AccountCard(controller: controller),
                      if (controller.authExpired)
                        Padding(
                          padding: const EdgeInsets.only(
                              left: ZSpacing.screen,
                              right: ZSpacing.screen,
                              bottom: 4),
                          child: Row(
                            children: [
                              Icon(Icons.warning_amber_outlined,
                                  size: 16,
                                  color: ZInk.warningTone(context)),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  tr(context, 'plan.authExpired'),
                                  style: ZType.sub
                                      .copyWith(color: ZInk.warningTone(context)),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (snap.buckets.isEmpty && controller.fetching)
                        const Padding(
                          padding: EdgeInsets.all(ZSpacing.emptyState),
                          child: Center(
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      else if (snap.buckets.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(ZSpacing.emptyState),
                          child: Center(
                            child: Text(
                              // The server silently drops expired buckets,
                              // so an empty snapshot with a past memoized
                              // expiry means "expired on X", not "no plan".
                              expiredOn != null
                                  ? trP(context, 'plan.expired',
                                      [_fmtPlanDate(expiredOn)])
                                  : tr(context, 'plan.empty'),
                              style: ZType.sub
                                  .copyWith(color: ZInk.muted(context)),
                            ),
                          ),
                        )
                      else
                        for (final bucket in snap.buckets)
                          _BucketCard(bucket: bucket),
                      if (controller.error != null)
                        _ErrorRow(controller: controller),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Sign-in card: the OAuth device flow is the primary path (idle →
/// inProgress with a copyable authorize URL → success or retryable
/// failure); the v0 token paste survives as the collapsed manual
/// fallback.
class _SignInCard extends StatelessWidget {
  final PlanController controller;
  final VoidCallback onSignInOAuth;
  final VoidCallback onOpenAuthorizeUrl;
  final VoidCallback onCopyAuthorizeUrl;
  final VoidCallback onCancel;
  final TextEditingController tokenField;
  final VoidCallback onSubmitToken;

  const _SignInCard({
    required this.controller,
    required this.onSignInOAuth,
    required this.onOpenAuthorizeUrl,
    required this.onCopyAuthorizeUrl,
    required this.onCancel,
    required this.tokenField,
    required this.onSubmitToken,
  });

  @override
  Widget build(BuildContext context) {
    final authorizeUrl = controller.oauthAuthorizeUrl;
    final failure = controller.oauthFailure;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(ZSpacing.card),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr(context, 'plan.signIn.title'), style: ZType.heading),
            const SizedBox(height: 4),
            Text(
              tr(context, 'plan.signIn.oauthBody'),
              style: ZType.sub.copyWith(color: ZInk.muted(context)),
            ),
            const SizedBox(height: 12),
            if (!controller.oauthInProgress)
              FilledButton(
                onPressed: onSignInOAuth,
                child: Text(tr(context, 'plan.signIn.oauth')),
              )
            else ...[
              Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      tr(context, 'plan.signIn.oauthWaiting'),
                      style: ZType.sub.copyWith(color: ZInk.muted(context)),
                    ),
                  ),
                ],
              ),
              if (authorizeUrl != null) ...[
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        authorizeUrl,
                        style:
                            ZType.caption.copyWith(color: ZInk.muted(context)),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      tooltip: tr(context, 'plan.signIn.oauthCopy'),
                      icon: const Icon(Icons.copy_outlined, size: 18),
                      onPressed: onCopyAuthorizeUrl,
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: onOpenAuthorizeUrl,
                        child: Text(tr(context, 'plan.signIn.oauthOpen')),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: onCancel,
                      child: Text(tr(context, 'plan.signIn.oauthCancel')),
                    ),
                  ],
                ),
              ],
            ],
            if (failure != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Icon(Icons.error_outline,
                        size: 16, color: ZInk.warningTone(context)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _failureText(context, failure),
                        style: ZType.sub
                            .copyWith(color: ZInk.warningTone(context)),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            // Manual token paste: the OAuth failure fallback, collapsed.
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: Text(tr(context, 'plan.signIn.manual'),
                  style: ZType.body),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    tr(context, 'plan.signIn.body'),
                    style: ZType.sub.copyWith(color: ZInk.muted(context)),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: tokenField,
                  maxLines: 2,
                  minLines: 1,
                  style: ZType.body,
                  decoration: InputDecoration(
                    labelText: tr(context, 'plan.signIn.tokenLabel'),
                  ),
                  onSubmitted: (_) => onSubmitToken(),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: onSubmitToken,
                  child: Text(tr(context, 'plan.signIn.submit')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _failureText(BuildContext context, PlanOAuthFailureReason reason) =>
      switch (reason) {
        PlanOAuthFailureReason.timeout =>
          tr(context, 'plan.signIn.fail.timeout'),
        PlanOAuthFailureReason.flowRejected =>
          tr(context, 'plan.signIn.fail.rejected'),
        PlanOAuthFailureReason.network =>
          tr(context, 'plan.signIn.fail.network'),
        // Never stored on the controller; listed for exhaustiveness.
        PlanOAuthFailureReason.userCancelled =>
          tr(context, 'plan.signIn.oauthCancelled'),
      };
}

class _AccountCard extends StatelessWidget {
  final PlanController controller;

  const _AccountCard({required this.controller});

  @override
  Widget build(BuildContext context) {
    final label = controller.accountLabel;
    return Card(
      child: ListTile(
        leading: const Icon(Icons.person_outline),
        title: Text(
          tr(context, 'plan.account'),
          style: ZType.caption.copyWith(color: ZInk.muted(context)),
        ),
        subtitle: Text(
          label ?? tr(context, 'plan.account'),
          style: ZType.bodyStrong,
        ),
        trailing: TextButton(
          onPressed: controller.signOut,
          child: Text(tr(context, 'plan.signOut')),
        ),
      ),
    );
  }
}

class _BucketCard extends StatelessWidget {
  /// Progress-bar geometry (relay quota-panel family: 10px track).
  static const _barHeight = 10.0;

  final PlanBucket bucket;

  const _BucketCard({required this.bucket});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(ZSpacing.card),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    bucket.showName.isEmpty
                        ? bucket.entitlementId
                        : bucket.showName,
                    style: ZType.bodyStrong,
                  ),
                ),
                if (bucket.periodEnd != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    trP(context, 'plan.bucket.expires', [
                      _fmtPlanDate(bucket.periodEnd!),
                    ]),
                    style: ZType.caption
                        .copyWith(color: ZInk.usageGreen(context)),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            // Remaining-percentage bar: same geometry family as the relay
            // quota panel (10px track, radius = height/2), usageBlue fill.
            ClipRRect(
              borderRadius: BorderRadius.circular(_barHeight / 2),
              child: SizedBox(
                height: _barHeight,
                width: double.infinity,
                child: Stack(
                  children: [
                    Container(color: ZInk.barTrackSoft(context)),
                    FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: _remainingFraction(),
                      child: Container(color: ZInk.usageBlue(context)),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _metric(context, tr(context, 'plan.bucket.remaining'),
                    _grouped(bucket.remaining)),
                _metric(context, tr(context, 'plan.bucket.used'),
                    _grouped(bucket.used)),
                _metric(context, tr(context, 'plan.bucket.total'),
                    _grouped(bucket.total)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _metric(BuildContext context, String label, String value) =>
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: ZType.caption.copyWith(color: ZInk.muted(context))),
            Text(
              value,
              style: ZType.bodyStrong.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      );

  double _remainingFraction() {
    final total = bucket.total;
    final remaining = bucket.remaining;
    if (total == null || remaining == null || total <= 0) return 0;
    return (remaining / total).clamp(0.0, 1.0);
  }

  /// Thousands separators for the tabular metric values ('—' when absent).
  String _grouped(int? n) {
    if (n == null) return '—';
    final s = '$n';
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      final rem = s.length - i;
      buf.write(s[i]);
      if (rem > 1 && rem % 3 == 1) buf.write(',');
    }
    return buf.toString();
  }
}

/// Failed refresh over retained data: the failure reason plus the data age
/// ("N 分钟前"), the quota-watch stale-display philosophy.
class _ErrorRow extends StatelessWidget {
  final PlanController controller;

  const _ErrorRow({required this.controller});

  @override
  Widget build(BuildContext context) {
    final error = controller.error;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          ZSpacing.screen, 12, ZSpacing.screen, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.cloud_off_outlined,
                  size: 16, color: ZInk.muted(context)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  trP(context, 'plan.refresh.failed',
                      [error?.message ?? '']),
                  style: ZType.sub.copyWith(color: ZInk.muted(context)),
                ),
              ),
            ],
          ),
          if (controller.snapshot.buckets.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              trP(context, 'plan.stale', [
                relativeTime(
                  context,
                  controller.snapshot.fetchedAt.millisecondsSinceEpoch,
                ),
              ]),
              style: ZType.caption.copyWith(color: ZInk.faint(context)),
            ),
          ],
        ],
      ),
    );
  }
}
