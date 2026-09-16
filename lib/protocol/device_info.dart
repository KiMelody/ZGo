import 'package:flutter/foundation.dart';

/// Device identity sent during relay auth and mobile-view-state updates.
///
/// The web client reports itself as a browser; ZLinker identifies itself
/// honestly so the desktop can show the real connected client.
const remoteAppName = 'zlinker';

/// Real runtime platform (android / ios / web / windows / ...), defaults to
/// `web` when unknown so the handshake stays valid on exotic targets.
String remotePlatformName() {
  if (kIsWeb) return 'web';
  // Lookup instead of a switch: the ohos fork adds TargetPlatform.ohos to
  // the enum, so a `default` arm is only reachable there — on official SDKs
  // it trips `unreachable_switch_default`. The `?? 'ohos'` fallback covers
  // the fork's extra value identically.
  const names = {
    TargetPlatform.android: 'android',
    TargetPlatform.iOS: 'ios',
    TargetPlatform.windows: 'windows',
    TargetPlatform.macOS: 'macos',
    TargetPlatform.linux: 'linux',
    TargetPlatform.fuchsia: 'fuchsia',
  };
  return names[defaultTargetPlatform] ?? 'ohos';
}
