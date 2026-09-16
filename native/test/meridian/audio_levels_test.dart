import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/meridian/audio_levels.dart';

/// Build PCM16LE mono bytes from int16 samples.
Uint8List pcm(List<int> samples) {
  final b = BytesBuilder();
  for (final s in samples) {
    b.addByte(s & 0xFF);
    b.addByte((s >> 8) & 0xFF);
  }
  return b.toBytes();
}

void main() {
  test('silence is zero', () {
    expect(rmsFromPcm16(pcm(List.filled(256, 0))), 0.0);
  });

  test('empty input is zero, not NaN', () {
    expect(rmsFromPcm16(Uint8List(0)), 0.0);
  });

  test('full-scale square wave clamps to 1.0', () {
    final s = List.generate(256, (i) => i.isEven ? 32767 : -32768);
    expect(rmsFromPcm16(pcm(s)), 1.0);
  });

  test('quiet signal scales by the x3 gain from orb.js', () {
    // constant amplitude 0.1 full-scale -> rms 0.1 -> *3 = 0.3
    final s = List.filled(256, (0.1 * 32768).round());
    expect(rmsFromPcm16(pcm(s)), closeTo(0.3, 0.01));
  });

  group('alphaForDt', () {
    test('a 60Hz frame reproduces the raw coefficient', () {
      expect(alphaForDt(0.2, 1 / 60), closeTo(0.2, 1e-9));
    });

    test('converges identically at 60Hz and 120Hz over the same wall-clock', () {
      // The bug: `level += (target - level) * 0.2` per FRAME meant a 120Hz phone
      // reached the target twice as fast as a 60Hz one, so the orb had a
      // different personality depending on the display.
      var a = 0.0;
      for (var i = 0; i < 60; i++) {
        a += (1.0 - a) * alphaForDt(0.2, 1 / 60);
      }
      var b = 0.0;
      for (var i = 0; i < 120; i++) {
        b += (1.0 - b) * alphaForDt(0.2, 1 / 120);
      }
      expect(b, closeTo(a, 1e-6));
    });

    test('a stall longer than a second snaps rather than catching up slowly', () {
      expect(alphaForDt(0.2, 2.0), 1.0);
    });

    test('degenerate inputs are inert, not NaN', () {
      expect(alphaForDt(0.2, 0), 0.0);
      expect(alphaForDt(0.0, 1 / 60), 0.0);
      expect(alphaForDt(1.0, 1 / 60), 1.0);
    });
  });

  group('LevelSmoother', () {
    test('attacks faster than it releases (VU ballistics)', () {
      final up = LevelSmoother();
      up.update(1.0, 1 / 60);
      final rise = up.value;

      final down = LevelSmoother()..debugSet(1.0);
      down.update(0.0, 1 / 60);
      final fall = 1.0 - down.value;

      expect(rise, greaterThan(fall),
          reason: 'a peak must arrive faster than it leaves — symmetric '
              'smoothing is what made the old orb feel sleepy');
    });

    test('is frame-rate independent', () {
      final at60 = LevelSmoother();
      for (var i = 0; i < 60; i++) {
        at60.update(1.0, 1 / 60);
      }
      final at120 = LevelSmoother();
      for (var i = 0; i < 120; i++) {
        at120.update(1.0, 1 / 120);
      }
      expect(at120.value, closeTo(at60.value, 1e-6));
    });

    test('reset returns to silence', () {
      final s = LevelSmoother()..debugSet(0.8);
      s.reset();
      expect(s.value, 0.0);
    });
  });

  group('TransientDetector', () {
    test('fires on an onset', () {
      final d = TransientDetector();
      for (var i = 0; i < 6; i++) {
        d.update(1.0, 1 / 60);
      }
      expect(d.value, greaterThan(0.2),
          reason: 'a sudden arrival of loudness is exactly what should punch');
    });

    test('a steady tone produces no punch once the followers converge', () {
      final d = TransientDetector();
      for (var i = 0; i < 600; i++) {
        d.update(1.0, 1 / 60); // ten seconds of unchanging loudness
      }
      expect(d.value, lessThan(0.05),
          reason: 'punch tracks the SHAPE of speech; presence is the level\'s '
              'job, and double-counting it would just make the orb buzz');
    });

    test('decays after the onset passes', () {
      final d = TransientDetector();
      for (var i = 0; i < 6; i++) {
        d.update(1.0, 1 / 60);
      }
      final peak = d.value;
      for (var i = 0; i < 60; i++) {
        d.update(0.0, 1 / 60);
      }
      expect(d.value, lessThan(peak * 0.25));
    });

    test('silence produces nothing at all', () {
      final d = TransientDetector();
      for (var i = 0; i < 60; i++) {
        d.update(0.0, 1 / 60);
      }
      expect(d.value, 0.0);
    });

    test('reset clears both followers, not just the output', () {
      final d = TransientDetector();
      for (var i = 0; i < 30; i++) {
        d.update(1.0, 1 / 60);
      }
      d.reset();
      expect(d.value, 0.0);
      // If only _punch had been cleared, the stale slow follower would make the
      // next onset read as a DROP and suppress the punch that should fire.
      for (var i = 0; i < 6; i++) {
        d.update(1.0, 1 / 60);
      }
      expect(d.value, greaterThan(0.2));
    });
  });
}
