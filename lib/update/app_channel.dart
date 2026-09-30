/// Distribution channel, fixed at build time:
/// `flutter build apk --dart-define=APP_CHANNEL=github|play|appstore`
///
/// - github: in-app update check against GitHub releases; downloads open
///   in the external browser (the app itself never downloads/installs
///   APKs — store builds must not carry any self-install code path, and
///   keeping one code path avoids drift).
/// - play / appstore: "check for updates" just opens the store listing.
const appChannel = String.fromEnvironment('APP_CHANNEL',
    defaultValue: 'github');

const _playPackageId = 'org.songsong.zlinker';

/// Filled when the App Store listing exists (numeric id). Until then the
/// appstore channel shows a hint instead of a broken link.
const appStoreId = '';

Uri? get storeListingUrl {
  switch (appChannel) {
    case 'play':
      return Uri.parse('market://details?id=$_playPackageId');
    case 'appstore':
      return appStoreId.isEmpty
          ? null
          : Uri.parse('itms-apps://apps.apple.com/app/id$appStoreId');
    default:
      return null;
  }
}
