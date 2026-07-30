import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/app_version.dart';

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
}
