import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/audio/keyword_spotter.dart';

void main() {
  group('pcm16ToFloat32', () {
    test('converts int16 PCM to normalized float32', () {
      // -32768, 0, 32767 little-endian
      final pcm = Uint8List.fromList([0x00, 0x80, 0x00, 0x00, 0xFF, 0x7F]);
      final out = pcm16ToFloat32(pcm);
      expect(out.length, 3);
      expect(out[0], closeTo(-1.0, 1e-6));
      expect(out[1], 0.0);
      expect(out[2], closeTo(1.0, 1e-4));
    });

    test('an odd trailing byte is dropped, not misread', () {
      final out = pcm16ToFloat32(Uint8List.fromList([0x00, 0x00, 0x11]));
      expect(out.length, 1);
    });
  });

  group('SherpaWakeSpotter fail-open', () {
    test('available is false and offer returns false when the model failed '
        'to load', () async {
      final s = SherpaWakeSpotter(loader: () async => throw StateError('no asset'));
      await s.start();
      expect(s.available, isFalse);
      expect(s.offer(Uint8List(320)), isFalse, reason: 'must fail open, never throw');
    });

    test('a failed load can be retried — the "already loaded" short-circuit '
        'only applies once available', () async {
      // start() now short-circuits when `available` is already true, so a
      // mic restart reuses the warm engine instead of reloading it (Important
      // 1). That guard must not also latch a FAILED load: a spotter that
      // never became available has nothing to reuse, and every later
      // startMic() must keep trying.
      var calls = 0;
      final s = SherpaWakeSpotter(loader: () async {
        calls++;
        throw StateError('no asset');
      });
      await s.start();
      expect(s.available, isFalse);
      await s.start();
      expect(calls, 2,
          reason: 'a failed load must not be permanently latched by the reuse guard');
    });

    test('stop() before any successful start() is a safe no-op', () async {
      final s = SherpaWakeSpotter(loader: () async => throw StateError('no asset'));
      await s.stop();
      expect(s.available, isFalse);
    });
  });
}
