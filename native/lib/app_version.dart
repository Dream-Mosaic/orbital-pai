/// The native app's own version, shown in the header as `P.A.I V<version>`.
///
/// The web header shows the SERVER's `App.version()`, rendered server-side; no
/// channel event carries it and adding one is out of scope (spec §3). A plain
/// const beats a plugin here — `app_version_test.dart` asserts it against
/// `pubspec.yaml`, so drift is impossible. **Bump both together.**
const String kAppVersion = '0.1.0';

/// What source this binary was actually built from — git SHA, plus `+` when the
/// tree was dirty. Shown in Settings ▸ About beside the server's version.
///
/// **Why this exists.** `kAppVersion` is a hand-bumped constant, so it says
/// nothing about which commit is on the device. A build 33 commits stale looked
/// identical to a current one in the UI, and cost a whole debugging round
/// chasing a "missing" feature that had shipped — the binary simply predated it.
///
/// Injected at build time by `run-dev.sh` / `run-profile.sh` via
/// `--dart-define`. A build that does NOT pass it reports `unknown` rather than
/// a stale or invented value: a wrong answer here is worse than no answer,
/// because the whole point is trusting what you are looking at.
const String kBuildSha = String.fromEnvironment('BUILD_SHA', defaultValue: 'unknown');

/// True when this binary carries no build stamp — i.e. it was produced by a
/// bare `flutter run` / `flutter build` rather than one of the dev scripts.
bool get kBuildShaUnknown => kBuildSha == 'unknown';
