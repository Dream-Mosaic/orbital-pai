import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/app_version.dart';

void main() {
  test('kAppVersion is in sync with pubspec.yaml', () {
    // The header shows the NATIVE app's version (the server's App.version is not
    // carried over the channel — spec §3). A const beats a plugin here, but only
    // if drift is impossible.
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match =
        RegExp(r'^version:\s*(\S+)\s*$', multiLine: true).firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec.yaml has no `version:` line');
    expect(kAppVersion, match!.group(1));
  });

  test('an unstamped build reports "unknown" rather than inventing a version',
      () {
    // The whole point of the stamp is trusting what you are looking at, so a
    // build that was NOT produced by run-dev.sh/run-profile.sh must say so
    // instead of reporting something plausible. `flutter test` passes no
    // --dart-define, so this IS the unstamped case.
    expect(kBuildSha, 'unknown');
    expect(kBuildShaUnknown, isTrue);
  });
}

