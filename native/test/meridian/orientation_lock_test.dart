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

  // On Android the view has no metrics yet when main() runs: its size reads
  // 0x0, which is "a phone" — the Lenovo came up portrait-locked and personal.
  group('settledLogicalSize', () {
    test('returns a real reading at once', () async {
      expect(await settledLogicalSize(read: () => const Size(711, 1191)),
          const Size(711, 1191));
    });

    test('waits past empty readings for the first real one', () async {
      final readings = [Size.zero, Size.zero, const Size(711, 1191)];
      var i = 0;
      final size = await settledLogicalSize(
        read: () => readings[i < readings.length - 1 ? i++ : i],
        poll: const Duration(milliseconds: 1),
      );
      expect(size, const Size(711, 1191));
    });

    test('falls back to the display when the view never settles', () async {
      final size = await settledLogicalSize(
        read: () => Size.zero,
        display: () => const Size(711, 1191),
        poll: const Duration(milliseconds: 1),
        timeout: const Duration(milliseconds: 20),
      );
      expect(size, const Size(711, 1191));
    });

    test('is null when nothing ever reports a size', () async {
      final size = await settledLogicalSize(
        read: () => null,
        display: () => null,
        poll: const Duration(milliseconds: 1),
        timeout: const Duration(milliseconds: 20),
      );
      expect(size, isNull);
    });
  });
}
