# ZGo

**ZCode — to go.** A Flutter app (Android / iOS) that remote-controls a
desktop **ZCode** instance: native device list, live task directory,
and a full native chat over the remote protocol, with the official web
remote available in-app as a fallback.

## Get started

You need a desktop machine running ZCode (zcode.z.ai). Generate a
remote-control link there (ZCode → Remote Control), then in the app:
**Add device** → scan or paste → tap the card → your tasks.

Prebuilt APKs live on the [releases page](https://github.com/KiMelody/ZGo/releases).

## Build from source

```bash
flutter pub get
flutter run
flutter build apk --release
```

## License

MIT — see [LICENSE](LICENSE).
