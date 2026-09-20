# Henry native client (`native/`)

The Flutter client for P.A.I. — the product surface (the Phoenix LiveView is a
monitor). One project, built per target; Android (phone + tablet) is what ships
today. Design specs live in `docs/superpowers/specs/` (start with
`2026-07-16-native-flutter-wall-client-design.md` and
`2026-07-24-native-meridian-voice-screen-design.md`).

## What it does

- Signs in through Authentik in the OS auth session (`flutter_web_auth_2`); the
  token lives in platform secure storage. Nothing to paste.
- Runs the "Henry" wake word on-device (`sherpa_onnx` keyword spotting,
  `assets/kws/`); audio only leaves the device after a local hit or while PTT
  is held.
- Streams 16 kHz PCM16 up the `voice:henry` Phoenix channel and plays 24 kHz
  PCM16 TTS back through a Kotlin `AudioTrack` player (`henry/audio_track`
  method channel) in communication mode, so the platform AEC covers Henry's
  own voice.
- Native panels for Reminders, Books, Connectors, Settings (+ Memory, Voice
  Lock) over the `panel:*` channels. No WebView.

## Run

Flutter is not on PATH: `export PATH="$HOME/flutter/bin:$PATH"`.

- `./run-dev.sh [--prod|--local] [device]` — debug build, defaults to the local
  server (`localhost:8787` via `adb reverse`).
- `./run-profile.sh` — profile build, same targeting.
- `./run-build.sh` — release APK, build + install + launch, defaults to prod.

`_target.sh` is the one place these decide where a build points; it prints a
`▸ target:` banner. The server address is `--dart-define`d
(`lib/server_config.dart`), defaulting to production.

## Gates

`flutter test` and `flutter analyze` must be clean before a commit. Kotlin
changes also need `flutter build apk --debug` (analyze does not compile Kotlin).

## Versions

`./bump.sh app patch|minor|major` (repo root) bumps `pubspec.yaml` and
`kAppVersion` together; a test locks them to each other.
