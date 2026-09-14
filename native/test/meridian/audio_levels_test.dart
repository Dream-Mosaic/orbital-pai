import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/meridian/audio_levels.dart';
import 'package:orbital_pai/meridian/orb_tuning.dart';

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

  group('PcmRing', () {
    test('the newest sample lands at the end of the window', () {
      final r = PcmRing(capacity: 8);
      r.write(pcm([1000, 2000, 3000, 4000]));
      final out = Float32List(4);
      r.readInto(out, end: r.written, window: 4);
      expect(out.last, closeTo(4000 / 32768.0, 1e-6));
      expect(out.first, closeTo(1000 / 32768.0, 1e-6));
    });

    test('a window reaching before the start of the stream pads with silence', () {
      final r = PcmRing(capacity: 8);
      r.write(pcm([1000, 2000]));
      final out = Float32List(4);
      r.readInto(out, end: r.written, window: 4);
      expect(out[0], 0.0);
      expect(out[1], 0.0);
      expect(out[2], closeTo(1000 / 32768.0, 1e-6));
      expect(out[3], closeTo(2000 / 32768.0, 1e-6));
    });

    test('samples older than the capacity read as silence, not as stale audio', () {
      final r = PcmRing(capacity: 4);
      r.write(pcm([1, 2, 3, 4, 5, 6]));
      final out = Float32List(4);
      r.readInto(out, end: r.written, window: 4);
      expect(out.first, closeTo(3 / 32768.0, 1e-6));
      expect(out.last, closeTo(6 / 32768.0, 1e-6));
      // The evicted 1 and 2 must not reappear when the window reaches back for them.
      final older = Float32List(6);
      r.readInto(older, end: r.written, window: 6);
      expect(older[0], 0.0);
      expect(older[1], 0.0);
      expect(older[2], closeTo(3 / 32768.0, 1e-6));
    });

    test('a write spanning the wrap point stays in order', () {
      final r = PcmRing(capacity: 4);
      r.write(pcm([1, 2, 3]));
      r.write(pcm([4, 5])); // wraps
      final out = Float32List(4);
      r.readInto(out, end: r.written, window: 4);
      expect(out.first, closeTo(2 / 32768.0, 1e-6));
      expect(out.last, closeTo(5 / 32768.0, 1e-6));
    });

    test('reads are addressed absolutely, so an earlier end sees earlier audio', () {
      final r = PcmRing(capacity: 16);
      r.write(pcm([10, 20, 30, 40, 50, 60, 70, 80]));
      final a = Float32List(2);
      final b = Float32List(2);
      r.readInto(a, end: 4, window: 2); // samples 30,40
      r.readInto(b, end: 8, window: 2); // samples 70,80
      expect(a.last, closeTo(40 / 32768.0, 1e-6));
      expect(b.last, closeTo(80 / 32768.0, 1e-6));
    });

    test('written is the absolute sample clock, not a byte count', () {
      final r = PcmRing(capacity: 16);
      r.write(pcm([1, 2, 3]));
      expect(r.written, 3);
      r.write(pcm([4]));
      expect(r.written, 4);
    });

    test('a negative sample reads as its own magnitude, not as unsigned garbage',
        () {
      // The output is unsigned now, so "the sign survived" is no longer the
      // guard. The underlying hazard is unchanged though: reading int16 -30000
      // as UNSIGNED gives 35536, i.e. >full-scale, which would clamp to 1.0 and
      // silently peg the envelope open on any loud negative excursion.
      final r = PcmRing(capacity: 4);
      r.write(pcm([-30000, -30000, -30000, -30000]));
      final out = Float32List(4);
      r.readInto(out, end: r.written, window: 4);
      expect(out.every((v) => v > 0), isTrue, reason: 'magnitude, so positive');
      for (final v in out) {
        expect(v, closeTo(30000 / 32768.0, 1e-6));
      }
    });

    test('clear() empties the window and resets the clock', () {
      final r = PcmRing(capacity: 4);
      r.write(pcm([9000, 9000]));
      r.clear();
      expect(r.written, 0);
      final out = Float32List(4);
      r.readInto(out, end: 0, window: 4);
      expect(out.every((v) => v == 0.0), isTrue);
    });

    test('takes each bucket PEAK when the window is wider than the output', () {
      final r = PcmRing(capacity: 1024);
      // A ramp, not an alternating signal: with an alternating signal the mean
      // and the peak differ so dramatically that the test would pass by luck.
      r.write(pcm(List.generate(1024, (i) => i * 16)));
      final out = Float32List(128);
      r.readInto(out, end: r.written, window: 1024);
      expect(out.length, 128);
      // Last bucket = samples 1016..1023 -> peak 1023*16 = 16368 (mean 16312).
      expect(out.last, closeTo(16368 / 32768.0, 1e-6));
      // First bucket = samples 0..7 -> peak 7*16 = 112 (mean 56).
      expect(out.first, closeTo(112 / 32768.0, 1e-6));
    });

    test('a bucket of alternating samples keeps its amplitude instead of '
        'cancelling to zero', () {
      // THE regression this whole change exists for. Speech routinely flips
      // sign between adjacent samples; the old per-bucket MEAN cancelled it and
      // collapsed the trace onto the centreline, which is why the orb looked
      // dead. A peak envelope cannot cancel.
      final r = PcmRing(capacity: 1024);
      r.write(pcm(List.generate(1024, (i) => i.isEven ? 8000 : -8000)));
      final out = Float32List(128);
      r.readInto(out, end: r.written, window: 1024);
      expect(out.every((v) => v > 0.2), isTrue,
          reason: 'every bucket must carry the real 8000/32768 amplitude; '
              'averaging would have produced ~0 everywhere');
      for (final v in out) {
        expect(v, closeTo(8000 / 32768.0, 1e-6));
      }
    });
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

  group('AutoGain', () {
    test('adopts a peak instantly and releases it slowly', () {
      final g = AutoGain();
      g.observe(0.5, 1 / 60);
      expect(g.peak, closeTo(0.5, 1e-9), reason: 'instant attack');

      g.observe(0.0, 1.0); // a full second of silence
      expect(g.peak, closeTo(0.5 * kAgcDecayPerSec, 1e-6));
      expect(g.peak, greaterThan(0.0),
          reason: 'a slow release is what keeps the scale steady across a '
              'syllable instead of pumping inside one');
    });

    test('normalises quiet speech up toward full scale', () {
      final g = AutoGain();
      g.observe(0.25, 1 / 60);
      expect(0.25 * g.gain, closeTo(1.0, 1e-6));
    });

    test('never attenuates audio that is already loud', () {
      final g = AutoGain();
      g.observe(1.0, 1 / 60);
      expect(g.gain, 1.0);
    });

    test('a silent room is not amplified into a fake waveform', () {
      // The ceiling is the entire safety argument for auto-gain: without it,
      // normalising against a near-zero peak turns the noise floor into a
      // convincing trace of a conversation nobody is having.
      final g = AutoGain();
      g.observe(0.0005, 1 / 60);
      expect(g.gain, kAgcMaxGain);
      expect(0.0005 * g.gain, lessThan(0.01),
          reason: 'still draws as effectively flat');
    });

    test('reset clears the tracked peak', () {
      final g = AutoGain()..observe(0.9, 1 / 60);
      g.reset();
      expect(g.peak, 0.0);
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
