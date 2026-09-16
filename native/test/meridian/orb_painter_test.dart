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

  test('advancing and setting the state notifies listeners (drives repaint)', () {
    final f = OrbFrame();
    var notified = 0;
    f.addListener(() => notified++);
    f.state = OrbState.speaking;
    f.advance(0.016);
    expect(notified, 2);
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
        ..audioTarget = 0.9;
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

  /// Ported out of the deleted `the trace is Henry only` group. This pins
  /// `_reactive` being WIDER than the line's own rule — that `listening` is
  /// wired to react at all, so a mic-driven level would plug in and pulse the
  /// halos without drawing a line.
  ///
  /// It drives `audioTarget` BY HAND because nothing does so in production:
  /// the playback poll is the field's only writer, it runs only while
  /// `speaking`, and it zeroes the target on the way out. So this asserts the
  /// mechanism is present and reachable, NOT a behaviour you can see on a
  /// device today — where the level decays to zero through `listening`.
  test('listening is REACTIVE IN SHAPE — a level fed here moves the halos',
      () {
    final f = OrbFrame()
      ..state = OrbState.listening
      ..audioTarget = 1.0;
    for (var i = 0; i < 10; i++) {
      f.advance(1 / 60);
    }
    expect(f.level, greaterThan(0.5));
    expect(f.punch, greaterThan(0.0));
    expect(f.presence, lessThan(0.05),
        reason: 'reacting is not drawing — listening keeps the line off');
    f.dispose();
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
        // Not merely "approaches zero" — it must clear the painters' GATE.
        // Presence decays geometrically and so never reaches zero on its own
        // (only `off` assigns it); if a realistic fade-out does not get under
        // kLinePresenceEpsilon, both painters keep building a ~190-segment
        // path every frame, invisibly, for as long as the Ticker runs.
        expect(f.presence, lessThanOrEqualTo(kLinePresenceEpsilon),
            reason: '$s must hide the line, and close the gate that stops it '
                'being drawn at all');
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
