# Henry native wall client — Milestone 1a (spike + skeleton)

Flutter client for the Phoenix voice channel. See
`docs/superpowers/specs/2026-07-16-native-flutter-wall-client-design.md`.

## Setup
1. `cp lib/config.example.dart lib/config.dart` and fill in the socket token
   (from the web app's `data-user-token`), the Mac's LAN IP, and the Picovoice
   AccessKey. `config.dart` is gitignored.
2. Ensure the Phoenix dev server is running on the Mac (`./dev.sh`, PORT 8787),
   and the phone/tablet is on the same LAN.
3. `flutter pub get`
4. `flutter run -d <device>`

## Test
- `flutter test` — pure-Dart codec + channel framing.
- On-device smoke — audio/wake/AEC (Tasks 5–7); results in `docs/phase0-results.md`.

## Wire contract (subset in 1a)
Client→server: binary `audio` (PCM16LE mono 16 kHz), `played{ms}`.
Server→client: binary `audio` (PCM16LE mono 24 kHz), `history{turns}`, `partial{text}`,
`transcript{text}`, `speak_start{source,text}`, `brain_delta{delta}`, `stop_playback`,
`duck`/`unduck`, `speaking`/`listening`/`thinking`, `state{phase,locked}`.
