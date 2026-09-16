import 'dart:typed_data';
import 'dart:ui';

import 'orb_painter.dart' show OrbFrame;
import 'orb_state.dart';
import 'orb_tuning.dart';
import 'palette.dart';

/// Float slot indices for `shaders/orb.frag`.
///
/// **The GLSL uniform block's DECLARATION ORDER is the contract.** A vec2 is
/// two consecutive slots, a vec4 is four. Reordering the declarations in the
/// shader without reordering these does not fail to compile and does not
/// throw — it silently shades the orb with the wrong numbers, which is a much
/// worse failure than a crash. Change them together, and the `count` test is
/// the tripwire.
abstract final class OrbU {
  static const int originX = 0;
  static const int originY = 1;
  static const int sizeW = 2;
  static const int sizeH = 3;
  static const int t = 4;
  static const int level = 5;
  static const int punch = 6;
  static const int off = 7;
  static const int glow = 8; // vec4
  static const int hi = 12; // vec4
  static const int lo = 16; // vec4
  static const int rim = 20; // vec4
  static const int punchSpread = 24;
  static const int punchGlow = 25;
  static const int ringPhase = 26;
  static const int count = 27;
}

/// Pack one frame's shader uniforms.
///
/// Pure, and deliberately separate from the painter: it is the only part of
/// the shader path that can be tested at all (a golden over shader-painted
/// content hangs — see the spec's spike table), so it is worth isolating.
///
/// The palette is derived from `frame.state` rather than passed in: it is a
/// pure function of the state, so accepting it separately would make "a
/// palette that disagrees with the state" representable for no benefit.
Float32List orbUniforms(OrbFrame frame, Rect rect) {
  final out = Float32List(OrbU.count);
  final pal = paletteFor(frame.state);

  out[OrbU.originX] = rect.left;
  out[OrbU.originY] = rect.top;
  out[OrbU.sizeW] = rect.width;
  out[OrbU.sizeH] = rect.height;

  out[OrbU.t] = frame.t;
  out[OrbU.level] = frame.level;
  out[OrbU.punch] = frame.punch;
  out[OrbU.off] = frame.state == OrbState.off ? 1.0 : 0.0;

  _putColor(out, OrbU.glow, pal.glow);
  _putColor(out, OrbU.hi, pal.hi);
  _putColor(out, OrbU.lo, pal.lo);
  _putColor(out, OrbU.rim, pal.rim);

  out[OrbU.punchSpread] = kPunchSpread;
  out[OrbU.punchGlow] = kPunchGlow;
  out[OrbU.ringPhase] = frame.ringPhase;
  return out;
}

/// `.r/.g/.b/.a` are doubles in 0..1. The older `.red/.green/.blue` are ints
/// in 0..255 and would saturate every channel to white.
void _putColor(Float32List out, int at, Color c) {
  out[at] = c.r;
  out[at + 1] = c.g;
  out[at + 2] = c.b;
  out[at + 3] = c.a;
}
