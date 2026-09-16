import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/meridian/orb_painter.dart';
import 'package:orbital_pai/meridian/orb_state.dart';
import 'package:orbital_pai/meridian/orb_tuning.dart';
import 'package:orbital_pai/meridian/orb_uniforms.dart';
import 'package:orbital_pai/meridian/palette.dart';

void main() {
  test('packs exactly the slots the shader declares', () {
    // The GLSL uniform block's declaration ORDER is the contract; a mismatch
    // here does not error, it silently shades with the wrong numbers.
    // 27 floats through uRingPhase, then three vec2 drifts at 27,28 / 29,30 /
    // 31,32.
    expect(OrbU.count, 33);
    expect(OrbU.drift0, 27);
  });

  test('origin and size come from the rect, never assumed', () {
    // FlutterFragCoord() is relative to the RENDER SURFACE, not to the rect
    // being painted, so the shader cannot derive its own coordinate space.
    // Getting this wrong renders a perfect orb in the wrong place.
    final f = OrbFrame()..state = OrbState.idle;
    final u = orbUniforms(f, const Rect.fromLTWH(37, 91, 280, 280));
    expect(u[OrbU.originX], 37);
    expect(u[OrbU.originY], 91);
    expect(u[OrbU.sizeW], 280);
    expect(u[OrbU.sizeH], 280);
    f.dispose();
  });

  test('carries the frame clock, level and punch', () {
    final f = OrbFrame()
      ..state = OrbState.speaking
      ..audioTarget = 1.0;
    // Advance first so punch is genuinely non-zero: comparing a packed 0.0
    // against a getter that also returns 0.0 would pass for a packer that
    // simply hardcodes the slot.
    for (var i = 0; i < 6; i++) {
      f.advance(1 / 60);
    }
    expect(f.punch, greaterThan(0.2), reason: 'sanity: punch is actually up');
    final withPunch = orbUniforms(f, const Rect.fromLTWH(0, 0, 100, 100));
    expect(withPunch[OrbU.punch], closeTo(f.punch, 1e-6));

    f.debugT = 2.5;
    f.debugSetLevel(0.5);
    final u = orbUniforms(f, const Rect.fromLTWH(0, 0, 100, 100));
    expect(u[OrbU.t], closeTo(2.5, 1e-6));
    expect(u[OrbU.level], closeTo(0.5, 1e-6));
    f.dispose();
  });

  test('uOff is 1.0 only when powered down', () {
    for (final s in OrbState.values) {
      final f = OrbFrame()..state = s;
      final u = orbUniforms(f, const Rect.fromLTWH(0, 0, 100, 100));
      expect(u[OrbU.off], s == OrbState.off ? 1.0 : 0.0, reason: '$s');
      f.dispose();
    }
  });

  test('every state packs its own palette', () {
    for (final s in OrbState.values) {
      final f = OrbFrame()..state = s;
      final u = orbUniforms(f, const Rect.fromLTWH(0, 0, 100, 100));
      final pal = paletteFor(s);
      for (final (slot, c, name) in [
        (OrbU.glow, pal.glow, 'glow'),
        (OrbU.hi, pal.hi, 'hi'),
        (OrbU.lo, pal.lo, 'lo'),
        (OrbU.rim, pal.rim, 'rim'),
      ]) {
        expect(u[slot], closeTo(c.r, 1e-6), reason: '$s.$name r');
        expect(u[slot + 1], closeTo(c.g, 1e-6), reason: '$s.$name g');
        expect(u[slot + 2], closeTo(c.b, 1e-6), reason: '$s.$name b');
        expect(u[slot + 3], closeTo(c.a, 1e-6), reason: '$s.$name a');
      }
      f.dispose();
    }
  });

  test('colour channels are 0..1, not 0..255', () {
    // Color.r/.g/.b are doubles in 0..1; the deprecated .red/.green/.blue are
    // ints in 0..255. Passing the latter blows every channel to full white.
    final f = OrbFrame()..state = OrbState.listening;
    final u = orbUniforms(f, const Rect.fromLTWH(0, 0, 100, 100));
    for (var i = OrbU.glow; i < OrbU.punchSpread; i++) {
      expect(u[i], inInclusiveRange(0.0, 1.0), reason: 'slot $i');
    }
    f.dispose();
  });

  test('shared motion constants ride along so the two painters cannot '
      'disagree', () {
    final f = OrbFrame()..state = OrbState.listening;
    final u = orbUniforms(f, const Rect.fromLTWH(0, 0, 100, 100));
    expect(u[OrbU.punchSpread], closeTo(kPunchSpread, 1e-6));
    expect(u[OrbU.punchGlow], closeTo(kPunchGlow, 1e-6));
    f.dispose();
  });

  test('ring phase advances at the state cadence', () {
    double phaseAfterASecond(OrbState s) {
      final f = OrbFrame()..state = s;
      for (var i = 0; i < 60; i++) {
        f.advance(1 / 60);
      }
      final p = f.ringPhase;
      f.dispose();
      return p;
    }

    expect(phaseAfterASecond(OrbState.ambient), 0.0,
        reason: 'a wall device at rest must not animate');
    expect(phaseAfterASecond(OrbState.listening),
        greaterThan(phaseAfterASecond(OrbState.idle)));
    expect(phaseAfterASecond(OrbState.thinking),
        greaterThan(phaseAfterASecond(OrbState.listening)));
    // The chain used to stop at thinking, which is how a speaking base SLOWER
    // than thinking got through review. Speaking is the fastest state, and it
    // must be so at level 0 — the level boost is on top, not what gets it
    // there: `phaseAfterASecond` never sets an audio target, so this is
    // speaking's base against thinking's.
    expect(phaseAfterASecond(OrbState.speaking),
        greaterThan(phaseAfterASecond(OrbState.thinking)),
        reason: 'spec decision 7: speaking is fastest, and must not visibly '
            'slow down on the thinking to speaking transition');
  });

  test('ring phase is packed for the shader', () {
    final f = OrbFrame()..state = OrbState.thinking;
    for (var i = 0; i < 60; i++) {
      f.advance(1 / 60);
    }
    final u = orbUniforms(f, const Rect.fromLTWH(0, 0, 100, 100));
    expect(u[OrbU.ringPhase], closeTo(f.ringPhase, 1e-6));
    expect(OrbU.count, 33, reason: 'the GLSL must declare exactly these');
    f.dispose();
  });

  test('the ring drifts are computed once here, not per fragment', () {
    final f = OrbFrame()..state = OrbState.speaking;
    for (var i = 0; i < 40; i++) {
      f.advance(1 / 60);
    }
    expect(f.ringPhase, greaterThan(0.1),
        reason: 'sanity: a phase of 0 would make sin() vanish and pass for a '
            'packer that hardcoded zero');
    final u = orbUniforms(f, const Rect.fromLTWH(0, 0, 100, 100));
    for (var i = 0; i < 3; i++) {
      // The same call `orb_painter.dart` makes for the fallback's halo
      // centres. That shared call is the point of the uniform: `orb.frag`
      // used to carry its own copy of kRingDrift and evaluate the Lissajous
      // per ring per fragment, so the two renderers could be re-tuned apart.
      final want = ringDrift(i, f.ringPhase);
      expect(u[OrbU.drift0 + i * 2], closeTo(want.dx, 1e-6), reason: 'drift$i x');
      expect(u[OrbU.drift0 + i * 2 + 1], closeTo(want.dy, 1e-6),
          reason: 'drift$i y');
      // Dimensionless — a fraction of the sphere radius, never a pixel offset.
      // The shader scales it by the BREATHING R and the fallback by r0, which
      // is the one difference between them and only stays a uniform scale if
      // what rides the wire carries no radius of its own.
      expect(want.distance, lessThanOrEqualTo(kRingDrift * math.sqrt2 + 1e-9),
          reason: 'drift$i magnitude peaks at kRingDrift*sqrt(2) — the bound '
              "orb.frag's early-out is derived to preserve");
    }
    // Not all three the same: the per-ring phase offsets are what stop the
    // rings locking into a formation.
    expect(u[OrbU.drift0], isNot(closeTo(u[OrbU.drift0 + 2], 1e-6)));
    f.dispose();
  });
}
