import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../notifications/keepalive_controller.dart';
import '../notifications/notification_service.dart';
import '../plan/plan_account.dart';
import '../plan/remote_device_api.dart';
import '../protocol/connection_params.dart';
import '../state/device_backup.dart';
import '../state/device_session.dart';
import '../state/device_store.dart';
import '../state/quota_watch.dart';
import '../state/scheduled_store.dart';
import '../widgets/home_widget_bridge.dart';
import 'device_backup_io.dart';
import 'qr_scan_page.dart';
import 'remote_page.dart';
import 'scheduled_page.dart';
import 'settings_page.dart';
import 'task_list_page.dart';
import 'theme.dart';
import 'ui_settings.dart';
import 'widgets/device_name.dart';
import 'widgets/sheet_scaffold.dart';

/// Home: the device list with live native status. Tap a card to open the
/// native task list (or WebView fallback), long-term management via the
/// overflow menu. Supports clipboard offer-to-add, drag-reorder and pin.
class DevicesPage extends StatefulWidget {
  final DeviceStore store;
  final ThemeController theme;
  final UiSettings ui;
  final DeviceSessionHub hub;
  final ScheduledStore scheduled;
  final KeepAliveController keepalive;

  /// Quota-watch controller handed to the settings section (null on hosts
  /// without the feature).
  final QuotaWatchController? quotaWatch;

  /// Plan-account controller handed to the settings section (null when
  /// the feature is not wired).
  final PlanController? plan;

  /// Notification service handed to the settings section for the
  /// permission nudge (B-04); null on hosts without notifications.
  final NotificationService? notifications;

  /// Cloud device-directory client (task 10-22). Null on hosts without the
  /// feature — the cloud section is then never rendered.
  final RemoteDeviceApi? cloudApi;

  /// Backup delivery seams (system save / share sheet / file picker).
  /// Null falls back to the real platform implementations; widget tests
  /// inject fakes so no plugin channel is touched.
  final SaveBackupFile? saveBackupFile;
  final ShareBackupFile? shareBackupFile;
  final ReadBackupFile? readBackupFile;
  const DevicesPage({
    super.key,
    required this.store,
    required this.theme,
    required this.ui,
    required this.hub,
    required this.scheduled,
    required this.keepalive,
    this.quotaWatch,
    this.plan,
    this.notifications,
    this.cloudApi,
    this.saveBackupFile,
    this.shareBackupFile,
    this.readBackupFile,
  });

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage>
    with WidgetsBindingObserver {
  /// Last clipboard URL we already offered (or the user dismissed) so we
  /// don't spam the snackbar on every resume.
  String? _clipboardHandled;

  /// Cloud device directory (R2). Null = not fetched / failed / signed
  /// out — the section stays hidden. [_cloudToken] is the account the
  /// cached list belongs to: one fetch per identity, no polling.
  List<RemoteDeviceEntry>? _cloudDevices;
  String? _cloudToken;

  /// Device whose native link is being suspended for the WebView handover
  /// (B-01). The suspend can take seconds; its card shows the spinner and
  /// ignores taps meanwhile so a second tap cannot re-enter the handover.
  String? _handoverBusyId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.store.load().then((_) {
      _syncConnections();
      _syncHomeWidget();
      _checkClipboard();
    });
    widget.store.addListener(_onStoreChanged);
    widget.ui.addListener(_syncConnections);
    widget.plan?.addListener(_onPlanChanged);
    // Boot may still be reading the persisted identity — the listener above
    // fetches as soon as sign-in is known.
    _maybeLoadCloudDevices();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.store.removeListener(_onStoreChanged);
    widget.ui.removeListener(_syncConnections);
    widget.plan?.removeListener(_onPlanChanged);
    super.dispose();
  }

  void _onStoreChanged() {
    _syncConnections();
    _syncHomeWidget();
  }

  /// Sign-in/out and token refreshes drive the directory: the cloud list
  /// belongs to the account, so signing out drops it and a later sign-in
  /// fetches again. Same-identity notifications are no-ops.
  void _onPlanChanged() {
    if (!mounted) return;
    if (widget.plan?.signedIn != true) {
      _cloudToken = null;
      if (_cloudDevices != null) setState(() => _cloudDevices = null);
      return;
    }
    _maybeLoadCloudDevices();
  }

  /// R2: fetch the cloud directory once per account (no polling); failures
  /// collapse silently. The account token rides the plan controller — the
  /// same `zgo_plan_token` the relay V2 handshake uses.
  Future<void> _maybeLoadCloudDevices() async {
    final plan = widget.plan;
    final api = widget.cloudApi;
    final token = plan?.token;
    if (api == null ||
        plan == null ||
        !plan.signedIn ||
        token == null ||
        token.isEmpty) {
      return;
    }
    // A new account's fetch must not be swallowed by an in-flight one for a
    // stale token — last writer wins (sign-in switch without sign-out).
    if (_cloudToken == token) return;
    _cloudToken = token;
    try {
      final entries = await api.list(token: token);
      // A concurrent token change replaced this fetch; its response belongs
      // to the previous account and must not render here.
      if (!mounted || _cloudToken != token) return;
      setState(() => _cloudDevices = entries);
    } catch (_) {
      // Silent collapse: no snackbar, and the cached token keeps a failed
      // attempt from turning into a retry loop.
    }
  }

  /// Account-directory entries not yet in the local list (R1): the section
  /// is discovery-only, so mid-matched rows never render.
  List<RemoteDeviceEntry> get _cloudUnadded {
    final devices = _cloudDevices;
    if (devices == null) return const [];
    return [
      for (final entry in devices)
        if (!_isCloudEntryAdded(entry)) entry,
    ];
  }

  bool get _cloudVisible =>
      (widget.plan?.signedIn ?? false) && _cloudUnadded.isNotEmpty;

  /// Adds the entry's V2 link and opens it through the existing card tap
  /// path (native task list when the link is healthy, WebView otherwise).
  Future<void> _connectCloud(RemoteDeviceEntry entry) async {
    final device = await widget.store.addUrl(entry.remoteUrl.toString());
    if (!mounted) return;
    await _open(device);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkClipboard();
      _syncHomeWidget();
    }
  }

  void _syncHomeWidget() {
    HomeWidgetBridge.syncDevices(widget.store.devices);
  }

  /// Keeps native connections in step with the device list and the
  /// native-list switch (see [DeviceSessionHub.syncWith]).
  void _syncConnections() {
    if (!widget.store.loaded || !mounted) return;
    widget.hub.syncWith(widget.store.devices);
  }

  /// On resume / first load: if the clipboard holds a remote URL that is
  /// not already saved, offer to add it.
  Future<void> _checkClipboard() async {
    if (!mounted) return;
    // Widget tests have no clipboard channel — skip to avoid pending timers.
    final bindingName = WidgetsBinding.instance.runtimeType.toString();
    if (bindingName.contains('TestWidgetsFlutterBinding') ||
        bindingName.contains('AutomatedTest')) {
      return;
    }
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? '';
      if (text.isEmpty || text == _clipboardHandled) return;
      if (RemoteConnectionParams.parse(text) == null) return;
      if (widget.store.devices.any((d) => d.url == text)) {
        _clipboardHandled = text;
        return;
      }
      _clipboardHandled = text;
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 8),
          content: Text(tr(context, 'devices.clipboard.offer')),
          action: SnackBarAction(
            label: tr(context, 'devices.clipboard.add'),
            onPressed: () async {
              await widget.store.addUrl(text);
            },
          ),
        ),
      );
    } catch (_) {
      // Clipboard access can fail on some platforms / permissions / tests.
    }
  }

  /// Card tap: native task list when the protocol link is healthy, the
  /// WebView remote page otherwise.
  Future<void> _open(Device device) async {
    final session = widget.hub.sessionOf(device.id);
    // V2 links need the ZCode account: a signed-out device can neither
    // connect natively nor usefully fall back to the WebView, so tap shows
    // the login guidance instead of silently failing (A2).
    if (session?.failureReason == 'auth-required') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr(context, 'remote.failure.auth-required')),
          action: SnackBarAction(
            label: tr(context, 'common.retry'),
            // Signing in happens in Settings; without this the tap always
            // hits the same failure branch and there is no way back.
            onPressed: () {
              if (!mounted) return;
              widget.hub.ensure(device);
            },
          ),
        ),
      );
      return;
    }
    if (widget.ui.nativeListEnabled &&
        session != null &&
        session.status != DeviceStatus.error) {
      if (!mounted) return;
      await Navigator.of(context).push(zRoute(
        (_) => _deviceThemeWrap(
          device,
          TaskListPage(
            store: widget.store,
            hub: widget.hub,
            device: device,
            theme: widget.theme,
          ),
        ),
      ));
      return;
    }
    await _openRemote(device);
  }

  /// Applies the device URL's `theme=dark|light` for the opened route.
  Widget _deviceThemeWrap(Device device, Widget child) {
    final hint = device.themeHint;
    if (hint == null) return child;
    final data = hint == ThemeModeHint.dark
        ? buildDarkTheme()
        : buildLightTheme();
    return Theme(data: data, child: child);
  }

  /// Opens the in-app WebView remote page. The native connection is
  /// suspended first (one terminal per device) and resumes ~1s after the
  /// page pops. Injects `theme=` from the URL when present.
  ///
  /// B-01: the wait is visible (the card spins while [_handoverBusyId] names
  /// this device) and a failed suspend shows a SnackBar instead of pushing a
  /// WebView that cannot pair — the push only happens after a clean suspend.
  Future<void> _openRemote(Device device) async {
    if (_handoverBusyId != null) return;
    setState(() => _handoverBusyId = device.id);
    var ready = false;
    try {
      await widget.store.touch(device.id);
      await widget.hub.suspend(device.id);
      ready = true;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr(context, 'remote.handoverFailed'))),
        );
      }
    } finally {
      if (mounted) setState(() => _handoverBusyId = null);
    }
    if (!ready || !mounted) return;
    await Navigator.of(context).push(zRoute(
      (_) => _deviceThemeWrap(
        device,
        RemotePage(device: device),
      ),
    ));
    widget.hub.scheduleResume(device);
  }

  Future<void> _addByUrl() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr(context, 'devices.add.pasteTitle')),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          minLines: 2,
          keyboardType: TextInputType.url,
          style: ZType.body.copyWith(fontFamily: 'monospace'),
          decoration: InputDecoration(
            hintText: tr(context, 'devices.add.pasteHint2'),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c),
              child: Text(tr(context, 'devices.add.cancel'))),
          FilledButton(
            onPressed: () => Navigator.pop(c, controller.text),
            child: Text(tr(context, 'devices.add.confirm')),
          ),
        ],
      ),
    );
    if (url == null || url.trim().isEmpty) return;
    final device = await widget.store.addUrl(url);
    if (!mounted) return;
    if (device.params == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr(context, 'devices.add.savedUnparsed'))),
      );
    }
  }

  Future<void> _addByScan() async {
    final url = await Navigator.of(context).push<String>(
      zRoute((_) => const QrScanPage()),
    );
    if (url == null || url.trim().isEmpty) return;
    final device = await widget.store.addUrl(url);
    if (!mounted) return;
    if (device.params == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr(context, 'devices.add.savedUnparsed'))),
      );
    }
  }

  void _showAddSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => zSheetScaffold(
        c,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.qr_code_scanner),
              title: Text(tr(context, 'devices.add.scan')),
              subtitle: Text(tr(context, 'devices.add.scanHint')),
              onTap: () {
                Navigator.pop(c);
                _addByScan();
              },
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: Text(tr(context, 'devices.add.paste')),
              subtitle: Text(tr(context, 'devices.add.pasteHint')),
              onTap: () {
                Navigator.pop(c);
                _addByUrl();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _rename(Device device) async {
    final controller = TextEditingController(text: device.label);
    final label = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr(context, 'devices.rename.title')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: tr(context, 'devices.rename.hint')),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c),
              child: Text(tr(context, 'devices.add.cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(c, controller.text),
              child: Text(tr(context, 'devices.rename.save'))),
        ],
      ),
    );
    if (label != null) await widget.store.rename(device.id, label);
  }

  Future<void> _delete(Device device) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr(context, 'devices.delete.title')),
        content: Text(trP(context, 'devices.delete.body', [
          deviceDisplayName(context, device.label),
        ])),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(tr(context, 'devices.add.cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(c).colorScheme.error,
                foregroundColor: Theme.of(c).colorScheme.onError),
            onPressed: () => Navigator.pop(c, true),
            child: Text(tr(context, 'devices.delete.confirm')),
          ),
        ],
      ),
    );
    if (confirm == true) await widget.store.remove(device.id);
  }

  Future<void> _copyUrl(Device device) async {
    await Clipboard.setData(ClipboardData(text: device.url));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr(context, 'devices.copy.done'))));
  }

  Future<void> _openInBrowser(Device device) async {
    await launchUrl(Uri.parse(device.url),
        mode: LaunchMode.externalApplication);
  }

  /// Local-date file name for the encrypted envelope.
  String _backupFileName() {
    final now = DateTime.now();
    final month = now.month.toString().padLeft(2, '0');
    final day = now.day.toString().padLeft(2, '0');
    return 'zgo-backup-${now.year}-$month-$day.zgobak';
  }

  /// Maps a codec failure kind to its user-facing copy. `decryptFailed`
  /// deliberately covers a wrong passphrase and a tampered file alike.
  String _backupErrorKey(String? kind) => switch (kind) {
        'passphraseRequired' => 'devices.import.passphraseNeeded',
        'decryptFailed' || 'corrupt' => 'devices.import.badPassphrase',
        'unsupportedVersion' => 'devices.import.unsupported',
        _ => 'devices.import.notBackup',
      };

  Future<void> _showExport() async {
    // A random passphrase is pre-filled so the common path is one tap; the
    // user may overwrite it with anything of their own (≥8 chars). The
    // confirm field follows the passphrase until it is edited by hand.
    final generated = generateBackupPassphrase();
    final passController = TextEditingController(text: generated);
    final confirmController = TextEditingController(text: generated);
    String? syncedPass = generated;
    final signedOut = widget.plan?.signedIn != true;
    final fileChannel = deviceBackupFileChannelAvailable;
    var busy = false;
    String? errorKey;

    String? validationError() {
      final pass = passController.text;
      if (pass.isNotEmpty && pass.length < 8) {
        return 'devices.export.tooShort';
      }
      if (confirmController.text.isNotEmpty &&
          confirmController.text != pass) {
        return 'devices.export.mismatch';
      }
      return null;
    }

    bool canSubmit() {
      final pass = passController.text;
      return !busy && pass.length >= 8 && confirmController.text == pass;
    }

    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (dialogCtx, setDialogState) {
          Future<void> run(_ExportTarget target) async {
            final pass = passController.text;
            if (pass.length < 8) {
              setDialogState(() => errorKey = 'devices.export.tooShort');
              return;
            }
            if (confirmController.text != pass) {
              setDialogState(() => errorKey = 'devices.export.mismatch');
              return;
            }
            setDialogState(() {
              busy = true;
              errorKey = null;
            });
            final Map<String, Object?> result;
            try {
              result = await compute(encodeBackupJob, {
                'devices':
                    widget.store.devices.map((d) => d.toJson()).toList(),
                'token': widget.plan?.token,
                'passphrase': pass,
              });
            } catch (_) {
              // Isolate spawn failure (never a codec error — the job maps
              // those to `ok: false`): surface it instead of a dead button.
              if (dialogCtx.mounted) {
                setDialogState(() {
                  busy = false;
                  errorKey = 'devices.export.failed';
                });
              }
              return;
            }
            if (!dialogCtx.mounted) return;
            if (result['ok'] != true) {
              setDialogState(() {
                busy = false;
                // The job only reports non-BackupException failures here
                // (encode cannot fail on user input), so the import-specific
                // "wrong passphrase" copy would be misleading.
                errorKey = 'devices.export.failed';
              });
              return;
            }
            final blob = result['blob'] as String;
            final bytes = utf8.encode(blob);
            final fileName = _backupFileName();
            try {
              switch (target) {
                case _ExportTarget.save:
                  final save = widget.saveBackupFile ?? defaultSaveBackupFile;
                  final saved = await save(fileName, bytes);
                  if (!saved) {
                    if (dialogCtx.mounted) {
                      setDialogState(() => busy = false);
                    }
                    return;
                  }
                case _ExportTarget.share:
                  final share =
                      widget.shareBackupFile ?? defaultShareBackupFile;
                  await share(fileName, bytes);
                case _ExportTarget.copy:
                  await Clipboard.setData(ClipboardData(text: blob));
              }
            } catch (_) {
              // Plugin failure or a missing channel: keep the dialog open
              // so the user can retry without re-entering the passphrase.
              if (dialogCtx.mounted) {
                setDialogState(() {
                  busy = false;
                  errorKey = 'devices.export.failed';
                });
              }
              return;
            }
            if (dialogCtx.mounted) Navigator.of(dialogCtx).pop();
            if (!mounted) return;
            final doneKey = switch (target) {
              _ExportTarget.save => 'devices.export.saved',
              _ExportTarget.share => null,
              _ExportTarget.copy => 'devices.export.copied',
            };
            if (doneKey != null) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(tr(context, doneKey))),
              );
            }
          }

          final liveError = errorKey ?? validationError();
          return AlertDialog(
            title: Text(tr(dialogCtx, 'devices.export.title')),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(tr(dialogCtx, 'devices.export.note'),
                      style: ZType.body),
                  const SizedBox(height: 8),
                  Text(
                    tr(dialogCtx, 'devices.export.generated'),
                    style: ZType.sub.copyWith(color: ZInk.faint(dialogCtx)),
                  ),
                  if (signedOut) ...[
                    const SizedBox(height: 8),
                    Text(
                      tr(dialogCtx, 'devices.export.signedOut'),
                      style:
                          ZType.sub.copyWith(color: ZInk.faint(dialogCtx)),
                    ),
                  ],
                  const SizedBox(height: 16),
                  TextField(
                    key: const Key('backup-export-passphrase'),
                    controller: passController,
                    enabled: !busy,
                    // Visible on purpose: the user must be able to record the
                    // generated value before it leaves this dialog.
                    obscureText: false,
                    enableSuggestions: false,
                    autocorrect: false,
                    onChanged: (value) {
                      if (syncedPass != null &&
                          confirmController.text == syncedPass) {
                        confirmController.text = value;
                        syncedPass = value;
                      }
                      setDialogState(() => errorKey = null);
                    },
                    decoration: InputDecoration(
                      labelText: tr(dialogCtx, 'devices.export.passphrase'),
                      suffixIcon: IconButton(
                        key: const Key('backup-export-copy-passphrase'),
                        tooltip:
                            tr(dialogCtx, 'devices.export.copyPassphrase'),
                        icon: const Icon(Icons.copy_outlined, size: 18),
                        onPressed: busy
                            ? null
                            : () async {
                                await Clipboard.setData(
                                    ClipboardData(text: passController.text));
                                if (!dialogCtx.mounted) return;
                                ScaffoldMessenger.of(dialogCtx).showSnackBar(
                                  SnackBar(
                                    content: Text(tr(dialogCtx,
                                        'devices.export.passphraseCopied')),
                                  ),
                                );
                              },
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const Key('backup-export-confirm'),
                    controller: confirmController,
                    enabled: !busy,
                    obscureText: true,
                    onChanged: (_) {
                      // Manual edit wins: the passphrase stops driving it.
                      syncedPass = null;
                      setDialogState(() => errorKey = null);
                    },
                    decoration: InputDecoration(
                      labelText: tr(dialogCtx, 'devices.export.confirm'),
                    ),
                  ),
                  if (liveError != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      tr(dialogCtx, liveError),
                      key: const Key('backup-export-error'),
                      style: ZType.sub
                          .copyWith(color: ZInk.dangerTone(dialogCtx)),
                    ),
                  ],
                  if (busy) ...[
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            tr(dialogCtx, 'devices.export.busy'),
                            style: ZType.sub
                                .copyWith(color: ZInk.faint(dialogCtx)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed:
                    busy ? null : () => Navigator.of(dialogCtx).pop(),
                child: Text(tr(dialogCtx, 'common.cancel')),
              ),
              if (fileChannel) ...[
                TextButton(
                  key: const Key('backup-export-share'),
                  onPressed:
                      canSubmit() ? () => run(_ExportTarget.share) : null,
                  child: Text(tr(dialogCtx, 'devices.export.share')),
                ),
                FilledButton(
                  key: const Key('backup-export-save'),
                  onPressed:
                      canSubmit() ? () => run(_ExportTarget.save) : null,
                  child: Text(tr(dialogCtx, 'devices.export.save')),
                ),
              ] else
                FilledButton(
                  key: const Key('backup-export-copy'),
                  onPressed:
                      canSubmit() ? () => run(_ExportTarget.copy) : null,
                  child: Text(tr(dialogCtx, 'devices.export.copy')),
                ),
            ],
          );
        },
      ),
    );
  }

  void _showScheduled() {
    Navigator.of(context).push(zRoute(
      (_) => ScheduledPage(
        devices: widget.store,
        hub: widget.hub,
        store: widget.scheduled,
      ),
    ));
  }

  Future<void> _showImport() async {
    final rawController = TextEditingController();
    final passController = TextEditingController();
    final fileChannel = deviceBackupFileChannelAvailable;
    var busy = false;
    var needsPassphrase = false;
    String? errorKey;

    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (dialogCtx, setDialogState) {
          void syncNeedsPassphrase() {
            var needs = false;
            final raw = rawController.text.trim();
            if (raw.isNotEmpty) {
              try {
                needs = backupNeedsPassphrase(raw);
              } catch (_) {
                needs = false;
              }
            }
            setDialogState(() {
              needsPassphrase = needs;
              if (!needs) passController.clear();
              errorKey = null;
            });
          }

          Future<void> run() async {
            final raw = rawController.text.trim();
            if (raw.isEmpty) {
              setDialogState(() => errorKey = 'devices.import.invalid');
              return;
            }
            bool needs;
            try {
              needs = backupNeedsPassphrase(raw);
            } on BackupException catch (e) {
              // Surface the real kind (a newer version's backup, or a JSON
              // that is not a ZGo backup) instead of the generic message.
              setDialogState(() => errorKey = _backupErrorKey(e.kind.name));
              return;
            } catch (_) {
              setDialogState(() => errorKey = 'devices.import.invalid');
              return;
            }
            final pass = passController.text;
            if (needs && pass.isEmpty) {
              setDialogState(
                  () => errorKey = 'devices.import.passphraseEmpty');
              return;
            }
            setDialogState(() {
              busy = true;
              errorKey = null;
            });
            final Map<String, Object?> result;
            try {
              result = await compute(decodeBackupJob, {
                'raw': raw,
                'passphrase': needs ? pass : null,
              });
            } catch (_) {
              if (dialogCtx.mounted) {
                setDialogState(() {
                  busy = false;
                  errorKey = 'devices.import.invalid';
                });
              }
              return;
            }
            if (!dialogCtx.mounted) return;
            if (result['ok'] != true) {
              setDialogState(() {
                busy = false;
                errorKey = _backupErrorKey(result['kind'] as String?);
              });
              return;
            }
            final int added;
            try {
              added = await widget.store
                  .importJson(jsonEncode(result['devices']));
            } catch (_) {
              if (dialogCtx.mounted) {
                setDialogState(() {
                  busy = false;
                  errorKey = 'devices.import.invalid';
                });
              }
              return;
            }
            String? credentialKey;
            final token = result['token'] as String?;
            final plan = widget.plan;
            if (token != null && plan != null) {
              final expiry = jwtExpiry(token);
              try {
                await plan.restoreToken(token);
                credentialKey =
                    expiry != null && expiry.isBefore(DateTime.now())
                        ? 'devices.import.credentialsExpired'
                        : 'devices.import.credentialsRestored';
              } catch (_) {
                // The device list is already imported; only the sign-in
                // hand-off failed, so report that separately.
                credentialKey = 'devices.import.credentialsFailed';
              }
            }
            if (dialogCtx.mounted) Navigator.of(dialogCtx).pop();
            if (!mounted) return;
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
                SnackBar(
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(trP(
                          context, 'devices.import.done', ['$added'])),
                      if (credentialKey != null)
                        Text(tr(context, credentialKey)),
                    ],
                  ),
                ),
              );
          }

          return AlertDialog(
            title: Text(tr(dialogCtx, 'devices.import.title')),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (fileChannel)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: const Key('backup-import-file'),
                        onPressed: busy
                            ? null
                            : () async {
                                final read = widget.readBackupFile ??
                                    defaultReadBackupFile;
                                String? text;
                                try {
                                  text = await read();
                                } catch (_) {
                                  // Cancelling returns null; a thrown read is
                                  // a real failure the user must see.
                                  if (dialogCtx.mounted) {
                                    setDialogState(() => errorKey =
                                        'devices.import.pickFailed');
                                  }
                                  return;
                                }
                                if (text == null || !dialogCtx.mounted) {
                                  return;
                                }
                                rawController.text = text;
                                syncNeedsPassphrase();
                              },
                        icon:
                            const Icon(Icons.folder_open_outlined, size: 18),
                        label: Text(tr(dialogCtx, 'devices.import.file')),
                      ),
                    ),
                  TextField(
                    key: const Key('backup-import-raw'),
                    controller: rawController,
                    enabled: !busy,
                    minLines: 3,
                    maxLines: 6,
                    style: ZType.sub.copyWith(fontFamily: 'monospace'),
                    decoration: InputDecoration(
                      hintText: tr(dialogCtx, 'devices.import.hint'),
                    ),
                    onChanged: (_) => syncNeedsPassphrase(),
                  ),
                  if (needsPassphrase) ...[
                    const SizedBox(height: 12),
                    Text(
                      tr(dialogCtx, 'devices.import.passphraseNeeded'),
                      style:
                          ZType.sub.copyWith(color: ZInk.faint(dialogCtx)),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      key: const Key('backup-import-passphrase'),
                      controller: passController,
                      enabled: !busy,
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText:
                            tr(dialogCtx, 'devices.import.passphrase'),
                      ),
                    ),
                  ],
                  if (errorKey != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      tr(dialogCtx, errorKey!),
                      key: const Key('backup-import-error'),
                      style: ZType.sub
                          .copyWith(color: ZInk.dangerTone(dialogCtx)),
                    ),
                  ],
                  if (busy) ...[
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            tr(dialogCtx, 'devices.import.busy'),
                            style: ZType.sub
                                .copyWith(color: ZInk.faint(dialogCtx)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.of(dialogCtx).pop(),
                child: Text(tr(dialogCtx, 'common.cancel')),
              ),
              FilledButton(
                key: const Key('backup-import-confirm'),
                onPressed: busy ? null : run,
                child: Text(tr(dialogCtx, 'devices.import.confirm')),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'app.title')),
        actions: [
          IconButton(
            tooltip: tr(context, 'settings.title'),
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(zRoute(
              (_) => SettingsPage(
                store: widget.store,
                theme: widget.theme,
                ui: widget.ui,
                keepalive: widget.keepalive,
                quotaWatch: widget.quotaWatch,
                plan: widget.plan,
                notifications: widget.notifications,
              ),
            )),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'export') _showExport();
              if (v == 'import') _showImport();
              if (v == 'sched') _showScheduled();
            },
            itemBuilder: (c) => [
              PopupMenuItem(
                  value: 'export', child: Text(tr(context, 'devices.menu.export'))),
              PopupMenuItem(
                  value: 'import', child: Text(tr(context, 'devices.menu.import'))),
              PopupMenuItem(
                  value: 'sched', child: Text(tr(context, 'sched.menu'))),
            ],
          ),
        ],
      ),
      // Hidden when the store failed to load: nothing can be persisted, so
      // adding a device would only produce a broken card.
      floatingActionButton: AnimatedBuilder(
        animation: widget.store,
        builder: (context, _) => widget.store.loadError != null
            ? const SizedBox.shrink()
            : FloatingActionButton.extended(
                onPressed: _showAddSheet,
                icon: const Icon(Icons.add),
                label: Text(tr(context, 'devices.add')),
              ),
      ),
      body: AnimatedBuilder(
        animation: Listenable.merge([widget.store, widget.hub, widget.ui]),
        builder: (context, _) {
          final devices = widget.store.devices;
          if (!widget.store.loaded) {
            return const Center(child: CircularProgressIndicator());
          }
          if (widget.store.loadError != null) {
            return _loadFailedState(context);
          }
          if (devices.isEmpty) return _emptyState(context);
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ReorderableListView.builder(
              // Always scrollable: a one-device list must still accept the
              // pull gesture for the refresh indicator.
              physics: const AlwaysScrollableScrollPhysics(),
              padding: zScreenPadding(context, bottom: 96),
              // 账号设备 rides below the local cards (R2), inside the same
              // scroll view so pull-to-refresh keeps working.
              footer: _cloudSection(context),
              itemCount: devices.length,
              // The row keeps no permanent drag handle (R8): reordering is a
              // long press anywhere on the card, on every platform.
              buildDefaultDragHandles: false,
              proxyDecorator: (child, index, animation) {
                return AnimatedBuilder(
                  animation: animation,
                  builder: (context, _) => Material(
                    elevation: 2 + animation.value * 4,
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(ZRadius.tile),
                    child: child,
                  ),
                );
              },
              onReorderItem: (oldIndex, newIndex) {
                widget.store.reorder(oldIndex, newIndex);
              },
              itemBuilder: (context, i) {
                final d = devices[i];
                return ReorderableDelayedDragStartListener(
                  key: ValueKey(d.id),
                  index: i,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _deviceCard(d),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }

  /// Pull-to-refresh: re-read the stored device list, then re-sync the native
  /// connections and the home widget with it.
  Future<void> _refresh() async {
    await widget.store.load();
    if (!mounted) return;
    _syncConnections();
    _syncHomeWidget();
  }

  /// Failure state for an unreachable preference store (an "empty shell"
  /// build lacks every plugin channel): devices and settings cannot be
  /// loaded or saved, so the retry is the only action that makes sense.
  Widget _loadFailedState(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(ZSpacing.emptyState),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: ZInk.dangerTone(context).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(ZRadius.field),
              ),
              child: Icon(Icons.error_outline,
                  size: 36, color: ZInk.dangerTone(context)),
            ),
            const SizedBox(height: 20),
            Text(
              tr(context, 'devices.loadFailed.title'),
              textAlign: TextAlign.center,
              style: ZType.title.copyWith(color: ZInk.solid(context)),
            ),
            const SizedBox(height: 8),
            Text(
              tr(context, 'devices.loadFailed.body'),
              textAlign: TextAlign.center,
              style: ZType.body.copyWith(color: ZInk.faint(context)),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () async {
                await widget.store.load();
              },
              child: Text(tr(context, 'devices.loadFailed.retry')),
            ),
          ],
        ),
      ),
    );
  }

  /// Empty state, kept inside a scrollable so the pull gesture still reaches
  /// the refresh indicator when there is no device yet.
  Widget _emptyState(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _refresh,
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Column(
            // Stretch so the cloud card spans the row width instead of
            // shrink-wrapping to its text.
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConstrainedBox(
                // With cloud devices present the hint shrinks to its own
                // height instead of centering over a full page — the
                // account directory must not start below the fold.
                constraints: BoxConstraints(
                  minHeight: _cloudVisible ? 0 : constraints.maxHeight,
                ),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(ZSpacing.emptyState),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            color: ZColors.sky500.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(ZRadius.field),
                          ),
                          child: const Icon(Icons.devices,
                              size: 36, color: ZColors.sky500),
                        ),
                        const SizedBox(height: 20),
                        Text(tr(context, 'devices.empty.title'),
                            style: ZType.title
                                .copyWith(color: ZInk.solid(context))),
                        const SizedBox(height: 8),
                        Text(
                          tr(context, 'devices.empty.body'),
                          textAlign: TextAlign.center,
                          style:
                              ZType.body.copyWith(color: ZInk.faint(context)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (_cloudVisible)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      ZSpacing.screen, 0, ZSpacing.screen, 96),
                  child: _cloudSection(context),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 账号设备分区 (R2/R3): a faint section title over one card of account
  /// devices. Discovery-only — already-added entries never render, so each
  /// row is either online (connect) or offline (disabled).
  Widget _cloudSection(BuildContext context) {
    if (!_cloudVisible) return const SizedBox.shrink();
    final entries = _cloudUnadded;
    return Padding(
      padding: const EdgeInsets.only(top: ZSpacing.cardGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Row(
              children: [
                Icon(Icons.cloud_outlined,
                    size: ZTile.iconSize, color: ZInk.ghost(context)),
                const SizedBox(width: 6),
                Text(
                  tr(context, 'devices.cloud.title'),
                  style: ZType.body.copyWith(
                    color: ZInk.ghost(context),
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  '·',
                  style: ZType.caption.copyWith(color: ZInk.ghost(context)),
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    tr(context, 'devices.cloud.subtitle'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ZType.caption.copyWith(color: ZInk.ghost(context)),
                  ),
                ),
              ],
            ),
          ),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < entries.length; i++) ...[
                  if (i > 0)
                    Divider(height: 1, color: ZInk.hairline(context)),
                  _cloudRow(context, entries[i]),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// R4: dedupe against the local list on `device_mid` — the same value the
  /// V2 link carries as `mid`. V1 links have no mid, so they never match.
  bool _isCloudEntryAdded(RemoteDeviceEntry entry) => widget.store.devices
      .any((d) => d.params?.deviceMid == entry.deviceMid);

  Widget _cloudRow(BuildContext context, RemoteDeviceEntry entry) {
    final metaLine = [
      if (entry.platform.isNotEmpty) entry.platform,
      if (entry.version.isNotEmpty) entry.version,
    ].join(' · ');
    return Padding(
      padding: ZListRow.padding,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: ZListRow.twoLineHeight),
        child: Row(
          children: [
            // The same status-dot language as the local cards.
            Container(
              width: ZListRow.dot,
              height: ZListRow.dot,
              decoration: BoxDecoration(
                color: entry.online
                    ? ZInk.successTone(context)
                    : ZInk.ghost(context),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    entry.name.isEmpty
                        ? tr(context, 'devices.unnamed')
                        : entry.name,
                    style:
                        ZType.bodyStrong.copyWith(color: ZInk.solid(context)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (metaLine.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      metaLine,
                      style: ZType.caption.copyWith(color: ZInk.faint(context)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              // Offline entries keep the button but disable it (R3).
              onPressed: entry.online ? () => _connectCloud(entry) : null,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                visualDensity: VisualDensity.compact,
              ),
              child: Text(
                tr(
                  context,
                  entry.online
                      ? 'devices.cloud.connect'
                      : 'devices.cloud.offline',
                ),
                style: ZType.sub,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _deviceCard(Device device) {
    final session = widget.hub.sessionOf(device.id);
    // B-01: the handover to the WebView suspends the native link; while that
    // runs the card is not tappable and shows its progress.
    final busy = _handoverBusyId == device.id;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: busy ? null : () => _open(device),
        child: Padding(
          padding: ZListRow.padding,
          child: ConstrainedBox(
            constraints:
                const BoxConstraints(minHeight: ZListRow.twoLineHeight),
            child: Row(
              children: [
                _deviceLeading(context, session, device.pinned),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        deviceDisplayName(context, device.label),
                        style: ZType.heading,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      // While the handover runs the meta line would still
                      // read a live status the suspend is tearing down; a
                      // 2dp spinner in its slot says "working" instead.
                      if (busy)
                        const LinearProgressIndicator(minHeight: 2)
                      else
                        _deviceMeta(context, session, device),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: tr(context, 'chat.more'),
                  icon: Icon(Icons.more_vert,
                      size: ZListRow.leadingIcon, color: ZInk.muted(context)),
                  onPressed: busy ? null : () => _deviceActions(device),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Per-device actions, behind 「更多」: the row keeps no permanent
  /// drag-handle/menu placeholder (R8) — reordering is the list's long-press
  /// drag, the actions live here.
  Future<void> _deviceActions(Device device) async {
    final host = device.params?.source.host ?? '';
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    ZSpacing.screen, 0, ZSpacing.screen, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(deviceDisplayName(context, device.label),
                        style: ZType.heading),
                    // The row no longer carries the host (R5): it lives in the
                    // device's own detail surface.
                    if (host.isNotEmpty)
                      Text(
                        host,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ZType.caption.copyWith(
                          color: ZInk.faint(context),
                          fontFamily: 'monospace',
                        ),
                      ),
                  ],
                ),
              ),
              for (final (value, key) in [
                ('pin',
                    device.pinned ? 'devices.menu.unpin' : 'devices.menu.pin'),
                ('rename', 'devices.menu.rename'),
                ('web', 'devices.menu.web'),
                ('browser', 'devices.menu.browser'),
                ('copy', 'devices.menu.copy'),
                ('delete', 'devices.menu.delete'),
              ])
                ListTile(
                  leading: Icon(_deviceActionIcon(value), size: 20),
                  title: Text(
                    tr(context, key),
                    style: value == 'delete'
                        ? ZType.body.copyWith(color: ZInk.dangerTone(context))
                        : ZType.body,
                  ),
                  onTap: () {
                    Navigator.pop(c);
                    switch (value) {
                      case 'pin':
                        widget.store.setPinned(device.id, !device.pinned);
                      case 'rename':
                        _rename(device);
                      case 'web':
                        _openRemote(device);
                      case 'browser':
                        _openInBrowser(device);
                      case 'copy':
                        _copyUrl(device);
                      case 'delete':
                        _delete(device);
                    }
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  static IconData _deviceActionIcon(String action) => switch (action) {
        'pin' => Icons.push_pin_outlined,
        'rename' => Icons.edit_outlined,
        'web' => Icons.smartphone,
        'browser' => Icons.open_in_browser,
        'copy' => Icons.link,
        _ => Icons.delete_outline,
      };

  /// Device avatar with a live status dot and a running-task badge.
  Widget _deviceLeading(
      BuildContext context, DeviceSession? session, bool pinned) {
    final running = session?.runningTaskCount ?? 0;
    final dotColor = switch (session?.status) {
      DeviceStatus.connected => ZInk.successTone(context),
      DeviceStatus.connecting => ZColors.sky500,
      DeviceStatus.error => ZInk.dangerTone(context),
      _ => ZColors.neutral400,
    };
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: ZListRow.leadingSize,
          height: ZListRow.leadingSize,
          decoration: BoxDecoration(
            color: ZColors.sky500.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(ZRadius.field),
          ),
          child: Icon(
            pinned ? Icons.push_pin_outlined : Icons.desktop_windows_outlined,
            size: ZListRow.leadingIcon,
            color: ZColors.sky500,
          ),
        ),
        Positioned(
          right: -1,
          bottom: -1,
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: dotColor,
              shape: BoxShape.circle,
              border: Border.all(
                  color: Theme.of(context).colorScheme.surface, width: 2.5),
            ),
          ),
        ),
        if (running > 0)
          Positioned(
            right: -8,
            top: -8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: ZColors.sky500,
                borderRadius: BorderRadius.circular(ZRadius.field),
                border: Border.all(
                    color: Theme.of(context).colorScheme.surface, width: 2),
              ),
              child: Text(
                running > 9 ? '9+' : '$running',
                style: ZType.caption.copyWith(
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// One meta line: `状态 · 上次使用…` (the host moved to the detail sheet).
  Widget _deviceMeta(
      BuildContext context, DeviceSession? session, Device device) {
    final stage = session?.connectionStage;
    // B-03/V4: the stage wins over the coarse status — the production shapes
    // of the three stages do NOT sit on `status == connecting` (a drop redial
    // keeps `connected`, a forced rebuild suspends to `disconnected`), so
    // gating on that status hid every one of them. `kicked` still wins: it is
    // the terminal state and must never be papered over by a stage.
    final showStage = stage != null && session?.kicked != true;
    final (status, color) = showStage
        ? (tr(context, 'status.stage.$stage'), ZColors.sky500)
        : switch (session?.status) {
            DeviceStatus.connected =>
              session != null && session.runningTaskCount > 0
                  ? (trP(context, 'status.tasksRunning',
                        ['${session.runningTaskCount}']),
                      ZInk.successTone(context))
                  : (tr(context, 'status.online'), ZInk.successTone(context)),
            DeviceStatus.connecting =>
              (tr(context, 'status.connecting'), ZColors.sky500),
            DeviceStatus.error => session?.failureReason == 'auth-required'
                ? (tr(context, 'status.authRequired'), ZInk.dangerTone(context))
                : session?.kicked == true
                    ? (tr(context, 'status.kicked'), ZInk.dangerTone(context))
                    : (tr(context, 'status.error'), ZInk.dangerTone(context)),
            _ => (tr(context, 'status.offline'), ZInk.ghost(context)),
          };
    // B14: while connected, the live status segment (在线 / 任务进行中 N)
    // already answers "is it alive" — '上次使用' is the moment the app last
    // OPENED the device (local stat, not session activity), so showing it
    // mid-session reads as stale. It rides only the disconnected states, and
    // it is dropped while a stage is on screen: the one-line subtitle has no
    // room for both (V4).
    final connected = session?.status == DeviceStatus.connected;
    final lastUsed = connected || showStage
        ? null
        : (device.lastUsedAt != null
            ? trP(context, 'devices.lastUsed',
                [relativeTime(context, device.lastUsedAt!)])
            : tr(context, 'devices.neverUsed'));
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
              text: status, style: ZType.caption.copyWith(color: color)),
          if (lastUsed != null)
            TextSpan(
              text: ' · $lastUsed',
              style: ZType.caption.copyWith(color: ZInk.ghost(context)),
            ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// Export delivery picked in the passphrase dialog: file save, system share
/// sheet, or the clipboard fallback for platforms without either plugin.
enum _ExportTarget { save, share, copy }
