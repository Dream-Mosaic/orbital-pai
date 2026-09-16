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

  group('curvedLevel', () {
    test('the endpoints are fixed — silence is silence, full scale is full', () {
      expect(curvedLevel(0.0), 0.0);
      expect(curvedLevel(1.0), closeTo(1.0, 1e-12));
    });

    test('it LIFTS quiet detail — the whole of S2', () {
      // Raw RMS is linear power and speech is enormously dynamic, so soft
      // phonemes sit near the floor and never move the line. The reported
      // symptom is a line that spikes on hard consonants while softer words
      // barely register.
      expect(curvedLevel(0.10), closeTo(0.1995, 0.001));
      expect(curvedLevel(0.15), closeTo(0.2650, 0.001));
    });

    test('a loud passage is lifted much LESS than a quiet one', () {
      // If it lifted everything equally the line would just be uniformly
      // busy, which is a different failure and just as wrong.
      final quietGain = curvedLevel(0.10) / 0.10;
      final loudGain = curvedLevel(0.60) / 0.60;
      expect(quietGain, greaterThan(loudGain * 1.5));
    });

    test('loud is still louder — order is preserved', () {
      var prev = -1.0;
      for (var x = 0.0; x <= 1.0; x += 0.05) {
        final v = curvedLevel(x);
        expect(v, greaterThan(prev));
        prev = v;
      }
    });

    test('it stays inside 0..1 whatever it is handed', () {
      // drawOrbLine treats `amp` as a hard ceiling; a level above 1.0 paints
      // the line outside the sphere.
      expect(curvedLevel(1.5), 1.0);
      expect(curvedLevel(-0.3), 0.0);
    });

    test('the anchor still means what it says once the curve is in front of it',
        () {
      // kLevelCurve and kLevelLoudAnchor overlap: both exist because playback
      // RMS never reaches 1.0. Stacking the curve on the OLD 0.6 anchor would
      // have saturated the shaping terms at raw 0.482 — a merely-loud 0.40
      // reading 0.877 of full — so the anchor moved to 0.6^0.7 with it. This
      // pins that relationship: whoever re-tunes one must re-derive the other.
      expect(anchoredLevel(curvedLevel(0.60)), closeTo(1.0, 0.005),
          reason: 'raw 0.6 is what the anchor calls full');
      expect(anchoredLevel(curvedLevel(0.55)), lessThan(0.97),
          reason: 'and it must not have saturated before it');
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

    test('a soft syllable 150ms after a loud one rises clear of its tail', () {
      // S3. At kLevelRelease60 = 0.12 the time constant was 130ms against
      // syllables arriving every 150-250ms, so a soft syllable landed on the
      // decaying tail of the loud one before it and never rose above it — it
      // was invisible, which is the reported "reacts more at the start of
      // words". Both levels go through curvedLevel because that is what the
      // poll feeds the smoother.
      final loud = curvedLevel(0.40);
      final soft = curvedLevel(0.15);
      final s = LevelSmoother()..debugSet(loud);
      for (var i = 0; i < 9; i++) {
        s.update(0.0, 1 / 60); // 150ms of gap
      }
      final tail = s.value;
      expect(tail, lessThan(soft * 0.5),
          reason: 'the tail must be well clear, not merely under — a soft '
              'syllable has to READ as a rise, not as a nudge');

      s.update(soft, 1 / 60);
      expect(s.value, greaterThan(tail),
          reason: 'and the very next frame must already be rising');
    });

    test('release is still clearly slower than attack', () {
      // The asymmetry is most of what makes a meter feel alive rather than
      // merely animated; S3 raised the release and must not have collapsed it.
      expect(kLevelRelease60, lessThan(kLevelAttack60 * 0.6));
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
