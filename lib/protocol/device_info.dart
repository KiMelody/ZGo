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
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      return 'android';
    case TargetPlatform.iOS:
      return 'ios';
    case TargetPlatform.windows:
      return 'windows';
    case TargetPlatform.macOS:
      return 'macos';
    case TargetPlatform.linux:
      return 'linux';
    case TargetPlatform.fuchsia:
      return 'fuchsia';
    default:
      // ohos fork adds TargetPlatform.ohos to the enum
      return 'ohos';
  }
}
