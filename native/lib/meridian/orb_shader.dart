import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'orb_line.dart';
import 'orb_painter.dart' show OrbFrame, kBreathe;
import 'orb_state.dart';
import 'orb_tuning.dart';
import 'orb_uniforms.dart';
import 'palette.dart';

/// Loads `shaders/orb.frag` exactly once, and never throws.
///
/// A failure here is not fatal: OrbView falls back to the frozen Canvas
/// painter. The orb is the entire screen, so "no orb" is a much worse outcome
/// than "last year's orb", and a driver bug on one device must not be able to
/// produce it.
abstract final class OrbShaderProgram {
  static ui.FragmentProgram? _program;
  static ui.FragmentShader? _shader;
  static bool _failed = false;
  static Future<void>? _inflight;

  static ui.FragmentProgram? get program => _program;

  /// The ONE shader instance, reused by every paint and never disposed.
  ///
  /// Not created per paint: `canvas.drawRect` records the paint into a display
  /// list that rasterizes LATER, so a shader disposed at the end of `paint`
  /// is freed before it is used. Allocating a fresh one per frame without
  /// disposing would leak instead. One instance for the app's lifetime is
  /// bounded, trivial, and the pattern Flutter's own samples use.
  static ui.FragmentShader? get shader => _shader;

  static bool get failed => _failed;

  /// Idempotent, and safe to call concurrently: the in-flight future is
  /// cached, so two callers racing at startup share one decode rather than
  /// each doing their own.
  static Future<void> load() {
    if (_program != null || _failed) return Future<void>.value();
    return _inflight ??= _load();
  }

  static Future<void> _load() async {
    try {
      _program = await ui.FragmentProgram.fromAsset('shaders/orb.frag');
      _shader = _program!.fragmentShader();
    } catch (e, st) {
      _failed = true;
      // Once, not per frame: OrbView consults `failed` on every build.
      debugPrint('orb shader unavailable, using the fallback painter: $e\n$st');
    } finally {
      _inflight = null;
    }
  }

  @visibleForTesting
  static void debugReset() {
    _shader?.dispose();
    _shader = null;
    _program = null;
    _failed = false;
    _inflight = null;
  }

  /// Test seam: force the "the shader is permanently unavailable" state
  /// without racing a real asset load. `load()` becomes a no-op once this is
  /// set (it early-returns on `_failed`), so a test that needs a
  /// deterministic, permanently-null shader (e.g. proving the fallback
  /// painter is used) can call this instead of relying on timing.
  @visibleForTesting
  static void debugFail() {
    _failed = true;
  }
}

/// Paints the orb with `shaders/orb.frag`: one drawRect for the halos, the
/// contact glow and the glass body, then the line as a Canvas path on top.
///
/// Replaces the five per-frame MaskFilter.blur passes the Canvas painter needs.
class OrbShaderPainter extends CustomPainter {
  OrbShaderPainter(this.frame, this.shader) : super(repaint: frame);

  final OrbFrame frame;
  final ui.FragmentShader shader;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    // Square, centred — the shader's -1..1 space assumes it, and a non-square
    // rect would stretch the sphere into an ellipse.
    final side = math.min(size.width, size.height);
    final rect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: side,
      height: side,
    );

    final u = orbUniforms(frame, rect);
    for (var i = 0; i < OrbU.count; i++) {
      shader.setFloat(i, u[i]);
    }
    canvas.drawRect(rect, Paint()..shader = shader);

    // The line stays a Canvas path, drawn by the same function the fallback
    // painter uses so the two cannot diverge.
    // Gated on PRESENCE, not on the state: presence already IS the state rule
    // (thinking + speaking, faded), and gating on the state as well would cut
    // the fade off at its first frame so it would never be seen. The epsilon
    // is what CLOSES the gate — presence asymptotes and never reaches zero, so
    // `> 0` would keep building a path forever. See kLinePresenceEpsilon.
    if (frame.presence <= kLinePresenceEpsilon) return;

    // Must match orb.frag's `breathe` and orb_painter.dart's `r` EXACTLY: the
    // wave sits on the sphere's surface, so a wave computed against the
    // un-breathing r0 drifts off it by up to ~5.5% of the radius at full level.
    // This is also what makes orb_line.dart's "both painters draw the same
    // line by construction" claim true rather than aspirational.
    final breathe = frame.state == OrbState.off
        ? 0.0
        : kBreathe * (0.015 * math.sin(frame.t * 1.6) + frame.level * 0.04);
    final r = side * 0.3 * (1 + breathe);
    final cx = rect.center.dx;
    final cy = rect.center.dy;
    // The fallback painter clips this to the sphere; deliberately omitted
    // here — the line's own reach stays well inside the silhouette: 0.48r
    // below centre at the middle (0.06r offset + kWaveAmp), and 0.72r at the
    // ends, where the taper is zero and kWaveAmp does not enter at all. Plus
    // the 4px blur. Don't "fix" this as a forgotten clipPath without
    // re-checking that.
    drawOrbLine(
      canvas,
      level: frame.level,
      shapeLevel: frame.shapeLevel,
      presence: frame.presence,
      phase: frame.linePhase,
      color: paletteFor(frame.state).wave,
      cx: cx,
      cy: cy + r * 0.06,
      halfW: r * 0.72,
      amp: r * kWaveAmp,
    );
  }

  @override
  bool shouldRepaint(covariant OrbShaderPainter old) =>
      old.frame != frame || old.shader != shader;
}
