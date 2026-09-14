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
    expect(OrbU.count, 26);
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
}
