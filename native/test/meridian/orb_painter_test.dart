import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/meridian/audio_levels.dart';
import 'package:orbital_pai/meridian/orb_painter.dart';
import 'package:orbital_pai/meridian/orb_state.dart';
import 'package:orbital_pai/meridian/orb_tuning.dart';

void main() {
  test('advance is frozen when off and steady-cadence when thinking', () {
    final f = OrbFrame()..state = OrbState.off;
    f.advance(0.1);
    expect(f.t, 0.0, reason: 'off is frozen');

    f.state = OrbState.thinking;
    f.advance(0.1);
    expect(f.t, closeTo(0.14, 1e-9), reason: 'thinking holds a steady 1.4x cadence');
  });

  test('level smooths once per FRAME, not once per audio chunk', () {
    final f = OrbFrame()..state = OrbState.listening;
    // Fifty chunks land between two frames. None of them may move the level:
    // smoothing per chunk would make the response a function of the device's
    // buffer size rather than of the audio.
    for (var i = 0; i < 50; i++) {
      f.audioTarget = 1.0;
    }
    expect(f.level, 0.0, reason: 'chunks do not smooth — frames do');

    f.advance(1 / 60);
    expect(f.level, closeTo(kLevelAttack60, 1e-9),
        reason: 'one 60Hz frame is exactly one attack step');
  });

  test('the level reaches the same place in a second at 60Hz and at 120Hz', () {
    // Ported from orb.js, the coefficient was applied per FRAME, so a 120Hz
    // phone ran the orb at twice the speed of a 60Hz one. Same wall-clock must
    // now mean same result on both.
    final at60 = OrbFrame()
      ..state = OrbState.listening
      ..audioTarget = 1.0;
    for (var i = 0; i < 60; i++) {
      at60.advance(1 / 60);
    }
    final at120 = OrbFrame()
      ..state = OrbState.listening
      ..audioTarget = 1.0;
    for (var i = 0; i < 120; i++) {
      at120.advance(1 / 120);
    }
    expect(at120.level, closeTo(at60.level, 1e-6));
  });

  test('level decays when leaving a reactive state (never sticks)', () {
    final f = OrbFrame()
      ..state = OrbState.listening
      ..audioTarget = 1.0;
    for (var i = 0; i < 40; i++) {
      f.advance(0.016);
    }
    expect(f.level, greaterThan(0.9));

    f.state = OrbState.thinking; // not audio-reactive
    for (var i = 0; i < 40; i++) {
      f.advance(0.016);
    }
    expect(f.level, lessThan(0.05),
        reason: 'must fall back to 0, not stay stuck at the last loudness');
  });

  test('reactive states quicken with loudness', () {
    final quiet = OrbFrame()
      ..state = OrbState.listening
      ..audioTarget = 0.0;
    quiet.advance(0.1);

    final loud = OrbFrame()
      ..state = OrbState.listening
      ..audioTarget = 1.0;
    loud.advance(0.1);

    // The level rises by one attack step first, and the clock speed is derived
    // from where it landed — so speed = 1 + level * 1.4.
    final step = alphaForDt(kLevelAttack60, 0.1);
    expect(loud.level, closeTo(step, 1e-9));
    expect(loud.t, closeTo(0.1 * (1 + step * 1.4), 1e-9));
    expect(loud.t, greaterThan(quiet.t), reason: 'louder = faster');
  });

  test('thinking ignores the audio target (not audio reactive)', () {
    final a = OrbFrame()..state = OrbState.thinking..audioTarget = 0.0;
    final b = OrbFrame()..state = OrbState.thinking..audioTarget = 1.0;
    a.advance(0.1);
    b.advance(0.1);
    expect(a.t, closeTo(b.t, 1e-9));
    expect(b.level, closeTo(0.0, 1e-9), reason: 'non-reactive states target 0');
  });

  test('advancing and setting fields notifies listeners (drives repaint)', () {
    final f = OrbFrame();
    var notified = 0;
    f.addListener(() => notified++);
    f.state = OrbState.speaking;
    f.waveform = Float32List(8);
    f.advance(0.016);
    expect(notified, 3);
  });

  test('audioTarget must NOT notify (repaint is driven by advance())', () {
    final f = OrbFrame()..state = OrbState.listening;
    var notified = 0;
    f.addListener(() => notified++);
    f.audioTarget = 1.0;
    expect(notified, 0);
  });

  test('off must NOT notify on advance (deliberate 24/7 wall-device power decision)', () {
    final f = OrbFrame()..state = OrbState.off;
    var notified = 0;
    f.addListener(() => notified++);
    f.advance(0.016);
    expect(notified, 0);
  });

  test('powering off resets the audio level without needing another advance()', () {
    // The ticker stops the instant state becomes off, so advance()'s own
    // off-branch reset never runs again after the first tick. The state
    // setter must do the reset itself, or the orb pops bright on next wake.
    final f = OrbFrame()
      ..state = OrbState.listening
      ..audioTarget = 1.0;
    for (var i = 0; i < 40; i++) {
      f.advance(0.016);
    }
    expect(f.level, greaterThan(0.9), reason: 'sanity: level is actually up');

    f.state = OrbState.off;
    expect(f.level, 0.0,
        reason: 'off must reset the level immediately, not on the next tick '
            'that will never come');
  });

  testWidgets('painter renders every state without throwing', (tester) async {
    for (final s in OrbState.values) {
      final f = OrbFrame()
        ..state = s
        ..audioTarget = 0.9
        ..waveform = Float32List.fromList(
            List.generate(64, (i) => (i.isEven ? 0.4 : -0.4)));
      for (var i = 0; i < 10; i++) {
        f.advance(0.016); // let the level rise so the reactive layers are exercised
      }
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 300,
            height: 300,
            child: CustomPaint(painter: OrbPainter(f)),
          ),
        ),
      );
      expect(tester.takeException(), isNull, reason: 'state $s should paint cleanly');
    }
  });

  testWidgets('painter survives a degenerate (zero) size', (tester) async {
    final f = OrbFrame()..state = OrbState.listening;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 0,
          height: 0,
          child: CustomPaint(painter: OrbPainter(f)),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  group('waveform sampling', () {
    // A varied, CONTINUOUS ramp fed in realistic chunks. Variety matters because
    // a flat or alternating signal makes every overlap assertion below vacuous;
    // continuity across chunk boundaries matters because a sliding window that
    // straddles two chunks must not see a seam that isn't in the audio.
    void feed(OrbFrame f,
        {int chunks = 16, int each = 512, int rate = 16000, int from = 0}) {
      var k = from;
      for (var c = 0; c < chunks; c++) {
        final b = ByteData(each * 2);
        for (var i = 0; i < each; i++) {
          b.setInt16(i * 2, (k % 257) * 100 - 12800, Endian.little);
          k++;
        }
        f.feedPcm(b.buffer.asUint8List(), sampleRate: rate);
      }
    }

    test('consecutive frames overlap instead of jumping a whole chunk', () {
      final f = OrbFrame()..state = OrbState.listening;
      feed(f);
      f.advance(0.016);
      final first = Float32List.fromList(f.waveform);
      // NO new audio this frame: the cursor alone must move the trace on.
      f.advance(0.016);
      final second = Float32List.fromList(f.waveform);

      expect(first.toSet().length, greaterThan(10),
          reason: 'a flat trace would make the rest of this test vacuous');
      expect(second, isNot(equals(first)),
          reason: 'the trace must advance on frames where no chunk arrived');

      // 0.016s at 16kHz = 256 samples = exactly 32 of the 128 points, so this
      // frame is the previous one shifted left by 32 — a slide, not a redraw.
      for (var i = 0; i < OrbFrame.kWavePoints - 32; i++) {
        expect(second[i], closeTo(first[i + 32], 1e-9),
            reason: 'point $i must be the previous frame\'s point ${i + 32}');
      }
    });

    test('the cursor advances at the feeding stream\'s sample rate', () {
      final f = OrbFrame()..state = OrbState.speaking;
      feed(f, rate: 24000); // TTS
      f.advance(0.016);
      final first = Float32List.fromList(f.waveform);
      f.advance(0.016);
      final second = Float32List.fromList(f.waveform);

      // 0.016s at 24kHz = 384 samples = 48 points. Reading 24k audio at the mic
      // rate would slide 32 and drift out of sync with what is being heard.
      for (var i = 0; i < OrbFrame.kWavePoints - 48; i++) {
        expect(second[i], closeTo(first[i + 48], 1e-9),
            reason: '24kHz audio must slide 48 points per 16ms frame');
      }
    });

    test('the lead is sized from the observed chunk, not assumed', () {
      // Chunk size is a device property (Android hands back whatever
      // AudioRecord.getMinBufferSize decided), and a lead shorter than a chunk
      // starves the cursor once per chunk.
      final small = OrbFrame()..state = OrbState.listening;
      feed(small, chunks: 16, each: 512);
      small.advance(0.016);

      final large = OrbFrame()..state = OrbState.listening;
      feed(large, chunks: 4, each: 2048);
      large.advance(0.016);

      expect(large.debugWaveLag, greaterThan(small.debugWaveLag),
          reason: 'a 2048-sample chunk needs more lead than a 512-sample one');
      expect(large.debugWaveLag, greaterThanOrEqualTo(2048.0),
          reason: 'the lead must cover at least one whole chunk');
    });

    test('a stalled stream does not leave the cursor pinned to the write head',
        () {
      final f = OrbFrame()..state = OrbState.listening;
      feed(f);
      f.advance(0.016); // settles the cursor behind the newest sample

      // The stream stalls (jitter, a late buffer) and the cursor eats its lead.
      for (var i = 0; i < 6; i++) {
        f.advance(0.016);
      }

      expect(f.debugWaveLag, greaterThanOrEqualTo(512.0),
          reason: 'a cursor left on the write head reads a fresh window per '
              'chunk forever after — the stutter this replaced');
      expect(f.debugWaveLag, lessThanOrEqualTo(0.0 + 2048),
          reason: 'and it must not fall so far behind that the ring evicts it');
    });

    test('feedPcm does not notify — advance() drives the repaint', () {
      final f = OrbFrame()..state = OrbState.listening;
      var notified = 0;
      f.addListener(() => notified++);
      feed(f, chunks: 1, each: 32);
      expect(notified, 0);
    });

    test('a stream that never started draws silence rather than reading garbage',
        () {
      final f = OrbFrame()..state = OrbState.listening;
      f.advance(0.016);
      expect(f.waveform.every((v) => v == 0.0), isTrue);
      f.advance(0.016);
      expect(f.waveform.every((v) => v == 0.0), isTrue);
    });

    test('powering off clears the ring so a wake shows no stale trace', () {
      final f = OrbFrame()..state = OrbState.listening;
      feed(f);
      f.advance(0.016);
      expect(f.waveform.any((v) => v != 0.0), isTrue);

      f.state = OrbState.off;
      f.state = OrbState.listening;
      f.advance(0.016);
      expect(f.waveform.every((v) => v == 0.0), isTrue,
          reason: 'a wake must not flash whatever was being said at power-down');
    });

    test('non-reactive states do not resample (idle/thinking draw no trace)', () {
      final f = OrbFrame()..state = OrbState.listening;
      feed(f);
      f.advance(0.016);
      final live = Float32List.fromList(f.waveform);
      f.state = OrbState.thinking;
      f.advance(0.016);
      expect(f.waveform, equals(live),
          reason: 'the painter gates on state; resampling here is wasted work');
    });
  });

  group('punch', () {
    test('an onset punches in a reactive state', () {
      final f = OrbFrame()
        ..state = OrbState.speaking
        ..audioTarget = 1.0;
      for (var i = 0; i < 6; i++) {
        f.advance(1 / 60);
      }
      expect(f.punch, greaterThan(0.2));
    });

    test('a non-reactive state never punches', () {
      // thinking targets 0 regardless of what the audio target says, so the
      // followers have nothing to diverge over.
      final f = OrbFrame()
        ..state = OrbState.thinking
        ..audioTarget = 1.0;
      for (var i = 0; i < 6; i++) {
        f.advance(1 / 60);
      }
      expect(f.punch, 0.0);
    });

    test('powering off clears the punch immediately', () {
      // Same argument as the level: the ticker stops the instant we go off, so
      // the state setter has to do the reset — there is no next tick to do it.
      final f = OrbFrame()
        ..state = OrbState.speaking
        ..audioTarget = 1.0;
      for (var i = 0; i < 6; i++) {
        f.advance(1 / 60);
      }
      expect(f.punch, greaterThan(0.2), reason: 'sanity: punch is actually up');

      f.state = OrbState.off;
      expect(f.punch, 0.0);
    });
  });

  group('waveGain', () {
    /// Feed [amplitude] (0..1 of full scale) as a square wave, which makes every
    /// bucket peak equal to it exactly.
    void feedAt(OrbFrame f, double amplitude) {
      const each = 2048;
      final v = (amplitude * 32767).round();
      for (var c = 0; c < 8; c++) {
        final b = ByteData(each * 2);
        for (var i = 0; i < each; i++) {
          b.setInt16(i * 2, i.isEven ? v : -v, Endian.little);
        }
        f.feedPcm(b.buffer.asUint8List(), sampleRate: 16000);
      }
    }

    test('quiet speech is normalised up toward full scale', () {
      // The thing that made the old orb a 2px squiggle: real speech peaks
      // around a quarter of full scale and was drawn at that size.
      final f = OrbFrame()..state = OrbState.listening;
      feedAt(f, 0.25);
      f.advance(1 / 60);
      expect(f.waveGain, greaterThan(3.0));
      final drawn = f.waveform.reduce((a, b) => a > b ? a : b) * f.waveGain;
      expect(drawn, closeTo(1.0, 0.05));
    });

    test('already-loud audio is never attenuated', () {
      final f = OrbFrame()..state = OrbState.listening;
      feedAt(f, 1.0);
      f.advance(1 / 60);
      // int16's positive maximum is 32767, so "full scale" lands a hair under
      // 1.0 and the gain a hair over it. The guard is that it does not boost.
      expect(f.waveGain, closeTo(1.0, 1e-4));
    });

    test('starts at unity and returns there on power-off', () {
      final f = OrbFrame();
      expect(f.waveGain, 1.0);

      f.state = OrbState.listening;
      feedAt(f, 0.2);
      f.advance(1 / 60);
      expect(f.waveGain, greaterThan(1.0), reason: 'sanity: gain moved');

      f.state = OrbState.off;
      expect(f.waveGain, 1.0);
    });
  });
}
