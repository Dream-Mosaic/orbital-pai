import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/meridian/orientation_lock.dart';

void main() {
  test('a phone is held to portrait (issue #8)', () {
    expect(allowedOrientations(const Size(360, 800)),
        [DeviceOrientation.portraitUp]);
    // Same phone, reported while already rotated: the short side decides.
    expect(allowedOrientations(const Size(800, 360)),
        [DeviceOrientation.portraitUp]);
  });

  test('a tablet may rotate freely', () {
    expect(allowedOrientations(const Size(800, 1280)), isEmpty);
    expect(allowedOrientations(const Size(1280, 800)), isEmpty);
  });
}
