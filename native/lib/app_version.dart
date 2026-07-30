/// The native app's own version, shown in the header as `P.A.I V<version>`.
///
/// The web header shows the SERVER's `App.version()`, rendered server-side; no
/// channel event carries it and adding one is out of scope (spec §3). A plain
/// const beats a plugin here — `app_version_test.dart` asserts it against
/// `pubspec.yaml`, so drift is impossible. **Bump both together.**
const String kAppVersion = '0.1.0';
