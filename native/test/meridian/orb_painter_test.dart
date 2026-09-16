import 'dart:math' as math;
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

    /// Audio with a varying ENVELOPE — a carrier under a slow amplitude
    /// modulation, which is roughly the shape syllables make.
    ///
    /// The ramp `feed` above is unsuitable for these two: its amplitude is
    /// constant, so over a 0.6s window every bucket's PEAK is the same value
    /// and the trace is flat — which would make a slide assertion vacuous. That
    /// it now matters is the point of the change: the trace shows an envelope,
    /// not a waveform.
    void feedSyllables(OrbFrame f, {required int rate, int samples = 40000}) {
      const chunk = 512;
      var k = 0;
      while (k < samples) {
        final b = ByteData(chunk * 2);
        for (var i = 0; i < chunk; i++) {
          final env = 0.2 + 0.8 * math.sin(2 * math.pi * k / 3000).abs();
          b.setInt16(i * 2, ((k.isEven ? 1 : -1) * env * 12000).round(),
              Endian.little);
          k++;
        }
        f.feedPcm(b.buffer.asUint8List(), sampleRate: rate);
      }
    }

    /// Seconds of playback that slide the trace by exactly [points] buckets, at
    /// [rate]. The window is now a DURATION ([kWaveSeconds]) rather than a fixed
    /// sample count, so the old "0.016s == 32 points" arithmetic no longer
    /// holds — derive it instead of writing a number that a retune invalidates.
    double secondsForPoints(int points, int rate) =>
        points * kWaveSeconds / OrbFrame.kWavePoints;

    test('consecutive frames slide the trace instead of redrawing it', () {
      const rate = 24000;
      final f = OrbFrame()..state = OrbState.speaking;
      feedSyllables(f, rate: rate);
      // Play past one full window first: a run anchors the cursor at its FIRST
      // sample, so until then the window is mostly the silence before the
      // stream and the trace is legitimately flat.
      for (var i = 0; i < 48; i++) {
        f.advance(1 / 60); // 0.8s > kWaveSeconds
      }
      final first = Float32List.fromList(f.waveform);

      const shift = 4;
      // NO new audio this frame: the cursor alone must move the trace on.
      f.advance(secondsForPoints(shift, rate));
      final second = Float32List.fromList(f.waveform);

      expect(first.toSet().length, greaterThan(10),
          reason: 'a flat trace would make the rest of this test vacuous');
      expect(second, isNot(equals(first)),
          reason: 'the trace must advance on frames where no chunk arrived');

      // Every point is the previous frame's point `shift` to its right — a
      // slide, not a redraw. The tolerance absorbs the 3-tap bucket smoothing
      // at the seams; the interior is otherwise exact.
      var matched = 0;
      for (var i = 2; i < OrbFrame.kWavePoints - shift - 2; i++) {
        if ((second[i] - first[i + shift]).abs() < 0.02) matched++;
      }
      expect(matched, greaterThan(OrbFrame.kWavePoints - shift - 20),
          reason: 'the frame must be the previous one shifted, not a fresh read');
    });

    test('the trace shows kWaveSeconds of audio, whatever the sample rate', () {
      // The window is a duration now. It was a fixed 1024 samples — the web
      // analyser's fftSize, carried over unexamined — which at the 24kHz TTS
      // rate is 43ms across the whole width: an oscilloscope zoomed in on
      // individual glottal pulses, scrolling a screen-width every 43ms. That
      // is what read as hair.
      for (final rate in [16000, 24000]) {
        final f = OrbFrame()..state = OrbState.speaking;
        feedSyllables(f, rate: rate);
        for (var i = 0; i < 48; i++) {
          f.advance(1 / 60);
        }
        final before = Float32List.fromList(f.waveform);

        // Slide by exactly half the width; the right half must become the left.
        f.advance(secondsForPoints(OrbFrame.kWavePoints ~/ 2, rate));
        final after = Float32List.fromList(f.waveform);

        var matched = 0;
        for (var i = 2; i < OrbFrame.kWavePoints ~/ 2 - 2; i++) {
          if ((after[i] - before[i + OrbFrame.kWavePoints ~/ 2]).abs() < 0.02) {
            matched++;
          }
        }
        expect(matched, greaterThan(OrbFrame.kWavePoints ~/ 2 - 20),
            reason: 'at ${rate}Hz the window must still span kWaveSeconds');
        f.dispose();
      }
    });

    test('feedPcm does not notify — advance() drives the repaint', () {
      final f = OrbFrame()..state = OrbState.speaking;
      var notified = 0;
      f.addListener(() => notified++);
      feed(f, chunks: 1, each: 32);
      expect(notified, 0);
    });

    test('a stream that never started draws silence rather than reading garbage',
        () {
      final f = OrbFrame()..state = OrbState.speaking;
      f.advance(0.016);
      expect(f.waveform.every((v) => v == 0.0), isTrue);
      f.advance(0.016);
      expect(f.waveform.every((v) => v == 0.0), isTrue);
    });

    test('powering off clears the ring so a wake shows no stale trace', () {
      final f = OrbFrame()..state = OrbState.speaking;
      feed(f);
      f.advance(0.016);
      expect(f.waveform.any((v) => v != 0.0), isTrue);

      f.state = OrbState.off;
      f.state = OrbState.speaking;
      f.advance(0.016);
      expect(f.waveform.every((v) => v == 0.0), isTrue,
          reason: 'a wake must not flash whatever was being said at power-down');
    });

    test('states that draw no wave do not resample (idle/thinking/listening)', () {
      final f = OrbFrame()..state = OrbState.speaking;
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
      final f = OrbFrame()..state = OrbState.speaking;
      feedAt(f, 0.25);
      f.advance(1 / 60);
      expect(f.waveGain, greaterThan(3.0));
      final drawn = f.waveform.reduce((a, b) => a > b ? a : b) * f.waveGain;
      expect(drawn, closeTo(1.0, 0.05));
    });

    test('already-loud audio is never attenuated', () {
      final f = OrbFrame()..state = OrbState.speaking;
      feedAt(f, 1.0);
      f.advance(1 / 60);
      // int16's positive maximum is 32767, so "full scale" lands a hair under
      // 1.0 and the gain a hair over it. The guard is that it does not boost.
      expect(f.waveGain, closeTo(1.0, 1e-4));
    });

    test('starts at unity and returns there on power-off', () {
      final f = OrbFrame();
      expect(f.waveGain, 1.0);

      f.state = OrbState.speaking;
      feedAt(f, 0.2);
      f.advance(1 / 60);
      expect(f.waveGain, greaterThan(1.0), reason: 'sanity: gain moved');

      f.state = OrbState.off;
      expect(f.waveGain, 1.0);
    });
  });

  group('the trace is Henry only', () {
    void feed(OrbFrame f, {int rate = 16000}) {
      for (var c = 0; c < 8; c++) {
        final b = ByteData(512 * 2);
        for (var i = 0; i < 512; i++) {
          b.setInt16(i * 2, (i % 257) * 100 - 12800, Endian.little);
        }
        f.feedPcm(b.buffer.asUint8List(), sampleRate: rate);
      }
    }

    test('listening does not resample, so it cannot draw a trace', () {
      // A trace of the user's own speech competes with the live transcript,
      // which is what they are actually reading while they talk.
      final f = OrbFrame()..state = OrbState.listening;
      feed(f);
      f.advance(1 / 60);
      expect(f.waveform.every((v) => v == 0.0), isTrue);
      f.dispose();
    });

    test('listening still REACTS — the halos must show it is hearing you', () {
      // The narrower "draws a wave" rule must not take the level with it, or
      // the only ambient signal that the mic is live goes too.
      final f = OrbFrame()
        ..state = OrbState.listening
        ..audioTarget = 1.0;
      for (var i = 0; i < 10; i++) {
        f.advance(1 / 60);
      }
      expect(f.level, greaterThan(0.5));
      expect(f.punch, greaterThan(0.0));
      f.dispose();
    });

    test('speaking draws', () {
      final f = OrbFrame()..state = OrbState.speaking;
      feed(f, rate: 24000);
      f.advance(1 / 60);
      expect(f.waveform.any((v) => v != 0.0), isTrue);
      f.dispose();
    });
  });

  group('a dry stream', () {
    void feed(OrbFrame f) {
      for (var c = 0; c < 8; c++) {
        final b = ByteData(512 * 2);
        for (var i = 0; i < 512; i++) {
          b.setInt16(i * 2, (i % 257) * 100 - 12800, Endian.little);
        }
        f.feedPcm(b.buffer.asUint8List(), sampleRate: 24000);
      }
    }

    test('the trace does not outlive its audio', () {
      // THE bug this group exists for. The read cursor advances on wall-clock
      // while the ring only advances when audio arrives, so once the stream
      // stopped the cursor overran the write head, the lag went negative, and
      // the resync dropped it back into the last written samples — re-reading
      // the same window forever. On screen: a waveform still open and still
      // moving with nothing being said. A TOOL ROUND is the case that matters,
      // where the brain goes quiet mid-turn while the orb is still `speaking`.
      final f = OrbFrame()..state = OrbState.speaking;
      feed(f);
      f.advance(1 / 60);
      expect(f.waveform.any((v) => v != 0.0), isTrue, reason: 'sanity: drawing');

      // Long enough to play out everything that arrived AND sit through the
      // grace and the fade.
      for (var i = 0; i < 120; i++) {
        f.advance(1 / 60);
      }
      expect(f.waveform.every((v) => v == 0.0), isTrue,
          reason: 'silence must draw silence');
      f.dispose();
    });

    test('it fades rather than cutting', () {
      // A hard cut reads as a glitch. Sampled mid-fade, the trace must be
      // smaller than it was but not yet gone.
      final f = OrbFrame()..state = OrbState.speaking;
      feed(f);
      f.advance(1 / 60);
      final full = f.waveform.reduce((a, b) => a > b ? a : b);

      // Run the cursor until it has drawn everything that arrived — the dry
      // clock starts THERE, not at the last feed, which is the whole point of
      // the change (audio arrives far faster than it plays).
      while (f.debugWaveLag > 0) {
        f.advance(1 / 60);
      }
      // Then land inside the fade window.
      var dryElapsed = 0.0;
      while (dryElapsed < kWaveDrySeconds + kWaveFadeSeconds * 0.5) {
        f.advance(1 / 60);
        dryElapsed += 1 / 60;
      }
      final mid = f.waveform.reduce((a, b) => a > b ? a : b);
      expect(mid, lessThan(full));
      expect(mid, greaterThan(0.0));
      f.dispose();
    });

    test('audio arriving again restores the trace', () {
      // The fade must not be a one-way latch — a tool round ends and Henry
      // keeps talking.
      final f = OrbFrame()..state = OrbState.speaking;
      feed(f);
      for (var i = 0; i < 120; i++) {
        f.advance(1 / 60);
      }
      expect(f.waveform.every((v) => v == 0.0), isTrue, reason: 'sanity: dry');

      feed(f);
      f.advance(1 / 60);
      f.advance(1 / 60);
      expect(f.waveform.any((v) => v != 0.0), isTrue);
      f.dispose();
    });
  });

  group('the cursor follows PLAYBACK, not arrival', () {
    /// One second of 24kHz audio, delivered in a single burst — which is what
    /// TTS actually does. Cartesia streams an utterance far faster than real
    /// time, so a ten-second answer can ARRIVE in two and then play for eight.
    void burst(OrbFrame f, {int seconds = 1}) {
      const rate = 24000;
      final b = ByteData(rate * seconds * 2);
      for (var i = 0; i < rate * seconds; i++) {
        b.setInt16(i * 2, (i % 257) * 100 - 12800, Endian.little);
      }
      f.feedPcm(b.buffer.asUint8List(), sampleRate: rate);
    }

    test('a fast-arriving stream does not drag the cursor to the newest sample',
        () {
      // THE regression test. The old code clamped the cursor to a fixed lead
      // behind the write head, which is right for a real-time mic stream and
      // badly wrong for TTS: it kept yanking the cursor onto the newest
      // ARRIVED sample, so the trace ran SECONDS ahead of the sound, and then
      // looped the tail once arrival stopped.
      final f = OrbFrame()..state = OrbState.speaking;
      burst(f); // a whole second lands at once
      f.advance(1 / 60);

      // One frame in, the cursor must be one frame into the audio — not at the
      // end of it. 24000 - 400 = 23600 samples still to play.
      expect(f.debugWaveLag, greaterThan(20000),
          reason: 'the cursor must still have almost the whole second to play');
      f.dispose();
    });

    test('it advances at real time however fast the audio arrived', () {
      final f = OrbFrame()..state = OrbState.speaking;
      burst(f);
      final before = f.debugWaveLag;
      for (var i = 0; i < 30; i++) {
        f.advance(1 / 60); // half a second of frames
      }
      // Half a second of playback = 12000 samples consumed, give or take a
      // frame. Nothing about the arrival burst may change that.
      expect(before - f.debugWaveLag, closeTo(12000, 500));
      f.dispose();
    });



  });

  group('presence', () {
    void run(OrbFrame f, double seconds) {
      for (var i = 0; i < (seconds * 60).round(); i++) {
        f.advance(1 / 60);
      }
    }

    test('fades IN for thinking and for speaking', () {
      for (final s in [OrbState.thinking, OrbState.speaking]) {
        final f = OrbFrame()..state = s;
        expect(f.presence, 0.0, reason: '$s starts absent');
        run(f, 0.5);
        expect(f.presence, greaterThan(0.95), reason: '$s must show the line');
        f.dispose();
      }
    });

    test('fades OUT for listening, idle and ambient', () {
      for (final s in [OrbState.listening, OrbState.idle, OrbState.ambient]) {
        final f = OrbFrame()..state = OrbState.speaking;
        run(f, 0.5);
        expect(f.presence, greaterThan(0.95), reason: 'sanity: it was up');

        f.state = s;
        run(f, 0.5);
        expect(f.presence, lessThan(0.05), reason: '$s must hide the line');
        f.dispose();
      }
    });

    test('it FADES rather than cutting', () {
      // Sampled mid-transition it must be strictly between the two ends; a cut
      // would read as a glitch when the state flips mid-turn, which it does
      // several times (listening -> thinking -> speaking -> listening).
      final f = OrbFrame()..state = OrbState.speaking;
      run(f, kLinePresenceSeconds * 0.5);
      expect(f.presence, greaterThan(0.05));
      expect(f.presence, lessThan(0.95));
      f.dispose();
    });

    test('powering off clears it immediately', () {
      // Same reasoning as the level: the ticker stops the instant we go off, so
      // there is no next tick to finish a fade.
      final f = OrbFrame()..state = OrbState.speaking;
      run(f, 0.5);
      f.state = OrbState.off;
      expect(f.presence, 0.0);
      f.dispose();
    });

    test('it is frame-rate independent', () {
      final at60 = OrbFrame()..state = OrbState.speaking;
      for (var i = 0; i < 12; i++) {
        at60.advance(1 / 60);
      }
      final at120 = OrbFrame()..state = OrbState.speaking;
      for (var i = 0; i < 24; i++) {
        at120.advance(1 / 120);
      }
      expect(at120.presence, closeTo(at60.presence, 1e-6));
      at60.dispose();
      at120.dispose();
    });
  });
}
