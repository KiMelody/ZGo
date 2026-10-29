import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/connection_params.dart';
import 'package:zgo/protocol/desktop_capabilities.dart';

/// Desktop capability table (design 10-29 §1 — keep names, thresholds,
/// sources and sites identical to `lib/protocol/desktop_capabilities.dart`
/// and the task's design.md):
///
/// | # | capability                    | threshold | step1 source     | step2 source     | probe dep       | sites (HEAD 9038a71) |
/// |---|-------------------------------|-----------|------------------|------------------|-----------------|----------------------|
/// | 1 | `bridgeAddressing`            | 3.16.3    | liveThenSnapshot | unchanged        | -               | DS:2190              |
/// | 2 | `projectLayer`                | 3.16.2    | snapshot         | unchanged        | -               | DS:2099/2570/2590/2659 |
/// | 3 | `projectCreateAddressing`     | 3.16.2    | snapshot         | liveThenSnapshot | -               | DS:3265              |
/// | 4 | `prepareWorkspaceTaskOptions` | 3.12.3    | snapshot         | liveThenSnapshot | -               | DS:3481              |
/// | 5 | `quotaWire`                   | 3.12.3    | snapshot         | liveThenSnapshot | -               | DS:3910/3931/3970/4015/4054 |
/// | 6 | `scopeFirstWire`              | 3.12.3    | snapshot         | unchanged        | -               | DS:2950/2960         |
/// | 7 | `offPeakStatusProbes`         | 3.14.0    | snapshot         | unchanged        | -               | DS:2961              |
/// | 8 | `replayableQueue`             | 3.12.3    | snapshot         | unchanged        | -               | DS:3048              |
/// | 9 | `workspaceHookReviewUi`       | 3.12.3    | snapshot         | unchanged        | -               | RC:438               |
/// | 10| `modelSelectionCatalog`       | 3.14.0    | snapshot         | unchanged        | -               | DS:2908              |
/// | 11| `modelProviderUi`             | 3.14.0    | snapshot+verdict | unchanged        | providerVerdict | TL:893/894/903; MP:41/47 |
///
/// Step 2 is the shipped state: the `step2 source` column is authoritative
/// and `_caps` mirrors it; the `step1 source` column records the frozen
/// baseline this task moved away from.
class _Cap {
  final String name;
  final int major;
  final int minor;
  final int patch;
  final CapabilitySource source;
  final bool Function(DesktopCapabilities) read;

  const _Cap(
    this.name,
    this.major,
    this.minor,
    this.patch,
    this.source,
    this.read,
  );
}

final List<_Cap> _caps = [
  _Cap('bridgeAddressing', 3, 16, 3, CapabilitySource.liveThenSnapshot,
      (c) => c.bridgeAddressing),
  _Cap('projectLayer', 3, 16, 2, CapabilitySource.snapshot,
      (c) => c.projectLayer),
  _Cap('projectCreateAddressing', 3, 16, 2, CapabilitySource.liveThenSnapshot,
      (c) => c.projectCreateAddressing),
  _Cap('prepareWorkspaceTaskOptions', 3, 12, 3,
      CapabilitySource.liveThenSnapshot, (c) => c.prepareWorkspaceTaskOptions),
  _Cap('quotaWire', 3, 12, 3, CapabilitySource.liveThenSnapshot,
      (c) => c.quotaWire),
  _Cap('scopeFirstWire', 3, 12, 3, CapabilitySource.snapshot,
      (c) => c.scopeFirstWire),
  _Cap('offPeakStatusProbes', 3, 14, 0, CapabilitySource.snapshot,
      (c) => c.offPeakStatusProbes),
  _Cap('replayableQueue', 3, 12, 3, CapabilitySource.snapshot,
      (c) => c.replayableQueue),
  _Cap('workspaceHookReviewUi', 3, 12, 3, CapabilitySource.snapshot,
      (c) => c.workspaceHookReviewUi),
  _Cap('modelSelectionCatalog', 3, 14, 0, CapabilitySource.snapshot,
      (c) => c.modelSelectionCatalog),
];

RemoteConnectionParams _paramsOf(String? version) =>
    RemoteConnectionParams.parse(
      'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=1&mid=m&name=test'
      '${version == null ? '' : '&app_version=$version'}',
    )!;

DesktopCapabilities _capsOf(
  String? snapshot, {
  String? live,
  bool? verdict,
  bool withLive = true,
}) =>
    DesktopCapabilities(
      _paramsOf(snapshot),
      liveDesktopVersion: withLive ? () => live : null,
      providerVerdict: () => verdict,
    );

/// Expected gate value from the table row: the source decides whether a
/// non-null live value wins (and, when malformed, answers false without
/// falling back to the snapshot).
bool _expected(_Cap cap, String? snapshot, String? live) {
  if (cap.source == CapabilitySource.liveThenSnapshot && live != null) {
    return versionAtLeast(live, cap.major, cap.minor, cap.patch);
  }
  return versionAtLeast(snapshot, cap.major, cap.minor, cap.patch);
}

void main() {
  group('capability matrix rows', () {
    final rows = <({String? snapshot, String? live})>[
      (snapshot: '3.12.2', live: null), // snapshot fallback
      (snapshot: '3.12.2', live: '3.16.3'), // 10-26 incident shape
      (snapshot: '3.16.3', live: '3.12.2'), // live reverse
      (snapshot: '3.16.3', live: null), // new snapshot
      (snapshot: '3.12.2', live: '3.16.3-beta'), // malformed live
    ];

    for (final row in rows) {
      test('(snapshot=${row.snapshot}, live=${row.live})', () {
        final caps = _capsOf(row.snapshot, live: row.live);
        for (final cap in _caps) {
          expect(
            cap.read(caps),
            _expected(cap, row.snapshot, row.live),
            reason: cap.name,
          );
        }
      });
    }

    test('no live callback behaves exactly like a null live value', () {
      final withoutLive = _capsOf('3.12.2', withLive: false);
      final withNullLive = _capsOf('3.12.2', live: null);
      for (final cap in _caps) {
        expect(cap.read(withoutLive), cap.read(withNullLive), reason: cap.name);
      }
    });
  });

  group('step-2 explicit matrix (flipped sources)', () {
    test('3.12.2 snapshot + null live: every gate closed', () {
      final caps = _capsOf('3.12.2', live: null);
      expect(caps.bridgeAddressing, isFalse);
      expect(caps.projectCreateAddressing, isFalse);
      expect(caps.prepareWorkspaceTaskOptions, isFalse);
      expect(caps.quotaWire, isFalse);
    });

    test('3.12.2 snapshot + 3.16.3 live: all four live gates open', () {
      final caps = _capsOf('3.12.2', live: '3.16.3');
      expect(caps.bridgeAddressing, isTrue);
      expect(caps.projectCreateAddressing, isTrue);
      expect(caps.prepareWorkspaceTaskOptions, isTrue);
      expect(caps.quotaWire, isTrue);
    });

    test('3.16.3 snapshot + 3.12.2 live: live wins in reverse', () {
      final caps = _capsOf('3.16.3', live: '3.12.2');
      expect(caps.bridgeAddressing, isFalse);
      expect(caps.projectCreateAddressing, isFalse);
      expect(caps.prepareWorkspaceTaskOptions, isFalse);
      expect(caps.quotaWire, isFalse);
    });

    test('3.16.3 snapshot + null live: snapshot opens everything', () {
      final caps = _capsOf('3.16.3', live: null);
      expect(caps.bridgeAddressing, isTrue);
      expect(caps.projectCreateAddressing, isTrue);
      expect(caps.prepareWorkspaceTaskOptions, isTrue);
      expect(caps.quotaWire, isTrue);
    });

    test('malformed live answers false and does not fall back', () {
      final caps = _capsOf('3.16.3', live: '3.16.3-beta');
      expect(caps.bridgeAddressing, isFalse,
          reason: 'live is authoritative even when unparsable');
      expect(caps.projectCreateAddressing, isFalse,
          reason: 'snapshot 3.16.3 would pass — the malformed live must win');
      expect(caps.prepareWorkspaceTaskOptions, isFalse);
      expect(caps.quotaWire, isFalse);
    });
  });

  group('frozen capabilities', () {
    test('live 3.16.3 does not move non-flipped capabilities (3.12.2 link)',
        () {
      final old = _capsOf('3.12.2', live: null);
      final live = _capsOf('3.12.2', live: '3.16.3');
      for (final cap in _caps) {
        if (cap.name == 'bridgeAddressing' ||
            cap.name == 'projectCreateAddressing' ||
            cap.name == 'prepareWorkspaceTaskOptions' ||
            cap.name == 'quotaWire') {
          continue;
        }
        expect(
          cap.read(live),
          cap.read(old),
          reason: '${cap.name} must stay snapshot-sourced',
        );
      }
    });
  });

  group('provider UI capability', () {
    test('known 3.14+ routes to provider-settings with no probe', () {
      for (final verdict in <bool?>[null, true, false]) {
        final caps = _capsOf('3.14.3', verdict: verdict);
        expect(caps.providerRoute, ProviderRoute.providerSettings);
        expect(caps.providersEntryEnabled, isTrue);
        expect(caps.shouldPrimeProviderProbe, isFalse);
      }
    });

    test('known pre-3.14 follows the cached legacy verdict and primes', () {
      final unknownVerdict = _capsOf('3.12.2');
      expect(unknownVerdict.providerRoute, ProviderRoute.legacy);
      expect(unknownVerdict.providersEntryEnabled, isTrue);
      expect(unknownVerdict.shouldPrimeProviderProbe, isTrue);

      final alive = _capsOf('3.12.2', verdict: true);
      expect(alive.providersEntryEnabled, isTrue);

      final gone = _capsOf('3.12.2', verdict: false);
      expect(gone.providersEntryEnabled, isFalse);
    });

    test('unknown version stays enabled and primes the probe', () {
      final caps = _capsOf(null);
      expect(caps.providerRoute, ProviderRoute.unknown);
      expect(caps.providersEntryEnabled, isTrue);
      expect(caps.shouldPrimeProviderProbe, isTrue);
    });

    test('verdict callback is re-read on every evaluation', () {
      bool? verdict;
      final caps = DesktopCapabilities(
        _paramsOf('3.12.2'),
        providerVerdict: () => verdict,
      );
      expect(caps.providersEntryEnabled, isTrue);
      verdict = false;
      expect(caps.providersEntryEnabled, isFalse);
      expect(caps.providerVerdict, isFalse);
    });
  });

  test('live callback is re-read on every evaluation', () {
    String? live;
    final caps = DesktopCapabilities(
      _paramsOf('3.12.2'),
      liveDesktopVersion: () => live,
    );
    expect(caps.bridgeAddressing, isFalse);
    live = '3.16.3';
    expect(caps.bridgeAddressing, isTrue);
    live = null;
    expect(caps.bridgeAddressing, isFalse);
  });
}
