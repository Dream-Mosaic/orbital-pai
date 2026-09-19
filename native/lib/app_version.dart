/// The native app's own version, shown in the header as `P.A.I V<version>` and
/// in Settings ▸ About beside the SERVER's version (which the settings channel
/// carries — the two are released separately).
///
/// A plain const beats a plugin here — `app_version_test.dart` asserts it
/// against `pubspec.yaml`, so drift is impossible. Bump both together with
/// `./bump.sh app patch|minor|major`.
const String kAppVersion = '0.2.0';

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
