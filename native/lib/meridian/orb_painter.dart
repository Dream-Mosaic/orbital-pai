import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'audio_levels.dart';
import 'orb_state.dart';
import 'palette.dart';

// Constants ported verbatim from server/assets/js/voice/orb.js — do not re-tune.
const int kHalos = 3;
const double kGlow = 1.2;
const double kBreathe = 1.05;
const double kClarity = 0.25;

/// Canvas 2D `shadowBlur = b` is approximately a Gaussian with `sigma = b / 2`.
double _sigma(double shadowBlur) => shadowBlur / 2.0;

/// Mutable orb frame state. Acts as the `CustomPainter.repaint` listenable so the
/// orb repaints without rebuilding the widget tree.
class OrbFrame extends ChangeNotifier {
  OrbState _state = OrbState.off;
  final LevelSmoother _smoother = LevelSmoother(); // the 0.2 alpha lives here (Task 2)
  double _audioTarget = 0.0;
  Float32List _waveform = Float32List(0);
  double _t = 0.0;

  OrbState get state => _state;
  set state(OrbState v) {
    if (v == _state) return;
    _state = v;
    if (v == OrbState.off) {
      // Powering off no longer relies on a tick to reset the audio state (the
      // ticker itself is now stopped the instant we go off) — do it here so
      // the very next paint, driven by this same notifyListeners(), never
      // inherits a stale level.
      _smoother.reset();
      _audioTarget = 0.0;
    }
    notifyListeners();
  }

  /// Raw loudness in (0..1). Set from the audio chunk listener; smoothed per
  /// FRAME by [advance] so the response is frame-locked and device-independent
  /// (orb.js smooths once per requestAnimationFrame, not once per audio buffer).
  /// Deliberately does NOT notify — [advance] drives the repaint.
  set audioTarget(double v) => _audioTarget = v;

  /// Smoothed loudness, derived. No public setter by design.
  double get level => _smoother.value;

  Float32List get waveform => _waveform;
  set waveform(Float32List v) {
    _waveform = v;
    notifyListeners();
  }

  double get t => _t;

  /// Advance one frame. Ported from orb.js's frame():
  ///   * `level` is smoothed toward the target ONCE PER FRAME (not per audio
  ///     chunk) so the response is frame-locked and device-independent;
  ///   * only `listening` (mic) and `speaking` (playback) track audio — every
  ///     other state targets 0, so the level decays instead of sticking;
  ///   * reactive states quicken with loudness, `thinking` keeps a steady
  ///     confident cadence, `off` is frozen.
  void advance(double dt) {
    if (_state == OrbState.off) {
      // Frozen: no clock and no repaint — this is the state a wall device shows
      // most, so not notifying here is the biggest power lever we have. Reset the
      // audio state so powering on never inherits a stale level.
      _smoother.reset();
      _audioTarget = 0.0;
      return;
    }
    final reactive =
        _state == OrbState.listening || _state == OrbState.speaking;
    _smoother.update(reactive ? _audioTarget : 0.0);
    final speed = _state == OrbState.thinking
        ? 1.4
        : 1.0 + (reactive ? _smoother.value * 1.4 : 0.0);
    _t += dt * speed;
    notifyListeners();
  }
}

/// Six-layer glass orb, a 1:1 port of orb.js's draw().
class OrbPainter extends CustomPainter {
  OrbPainter(this.frame) : super(repaint: frame);

  final OrbFrame frame;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    final pal = paletteFor(frame.state);
    final off = frame.state == OrbState.off;
    final level = frame.level;
    final t = frame.t;

    final cx = w / 2;
    final cy = h / 2;
    final center = Offset(cx, cy);
    final r0 = math.min(w, h) * 0.3;
    final breathe =
        off ? 0.0 : kBreathe * (0.015 * math.sin(t * 1.6) + level * 0.04);
    final r = r0 * (1 + breathe);

    // --- 1. glowing concentric halos behind the core ---
    if (!off) {
      for (var i = 0; i < kHalos; i++) {
        final f = kHalos > 1 ? i / (kHalos - 1) : 0.0;
        final spread = r0 * (1.06 + i * 0.17 + level * 0.05);
        final rr = spread +
            math.sin(t * 1.3 + i * 1.4) * r0 * 0.025 * kBreathe * (1 + level);
        final alpha = (0.42 - f * 0.3) *
            (0.6 + level * 0.6) *
            (0.5 + kGlow * 0.5);
        final paint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 - f
          ..color = pal.glow.withValues(alpha: alpha.clamp(0.0, 1.0))
          // Canvas 2D shadowBlur draws the blurred shadow AND THEN composites the
          // crisp shape on top — BlurStyle.solid ("solid inside, fuzzy outside")
          // is the matching semantic. BlurStyle.normal would replace the crisp
          // stroke with the blur, crushing a thin stroke's peak alpha to near zero.
          ..maskFilter = MaskFilter.blur(BlurStyle.solid, _sigma(10 + 14 * kGlow));
        canvas.drawCircle(center, rr, paint);
      }
    }

    // --- 2. outer contact glow under the sphere ---
    if (!off) {
      final paint = Paint()
        ..style = PaintingStyle.fill
        ..color = pal.glow.withValues(alpha: 0.06)
        ..maskFilter =
            MaskFilter.blur(BlurStyle.solid, _sigma(30 * kGlow * (0.6 + level)));
      canvas.drawCircle(center, r, paint);
    }

    // --- 3. glass core (clipped): spherical shading + depth shadow ---
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: center, radius: r)));

    final coreRect = Rect.fromCircle(center: center, radius: r);
    final base = RadialGradient(
      center: Alignment.center,
      focal: const Alignment(-0.32, -0.38),
      // Flutter's radius/focalRadius are fractions of the paint rect's
      // *shortestSide* (2r here, per RadialGradient.createShader — verified
      // against the Flutter SDK source), not of r. orb.js's Canvas two-circle
      // gradient radii (r0 = R*0.1, r1 = R*1.05) must be halved to land on
      // the same absolute pixel radius; otherwise the gradient renders at
      // ~2x the intended extent.
      focalRadius: 0.1 / 2,
      radius: 1.05 / 2,
      colors: [
        pal.hi.withValues(alpha: off ? 0.5 : 0.9),
        pal.hi.withValues(alpha: (off ? 0.12 : 0.22) * (1 - kClarity * 0.5)),
        pal.lo.withValues(alpha: off ? 0.85 : 0.78 + (1 - kClarity) * 0.2),
      ],
      stops: const [0.0, 0.6, 1.0],
    );
    canvas.drawRect(coreRect, Paint()..shader = base.createShader(coreRect));

    // bottom inner depth-shadow (weight)
    final shadowRect =
        Rect.fromCircle(center: Offset(cx, cy + r * 0.2), radius: r * 1.1);
    final sh = RadialGradient(
      center: Alignment.center,
      // Same shortestSide correction as the base gradient above, scaled to
      // shadowRect's own defining radius (R*1.1, so shortestSide = 2*1.1R):
      // orb.js's focal offset (R*0.55 - R*0.2 = R*0.35) and inner radius
      // (R*0.1) are expressed as fractions of 1.1R (Alignment) / 2.2R (radius).
      focal: const Alignment(0.0, 0.35 / 1.1),
      focalRadius: 0.1 / 2.2,
      radius: 1.1 / 2.2,
      colors: [
        pal.lo.withValues(alpha: 0.5),
        pal.lo.withValues(alpha: 0.0),
      ],
      stops: const [0.0, 1.0],
    );
    canvas.drawRect(shadowRect, Paint()..shader = sh.createShader(shadowRect));

    // --- 4. live waveform (reactive states only, inside the clip) ---
    // orb.js only draws this for REACTIVE[state] (listening = mic, speaking =
    // playback) — idle/ambient/thinking draw no waveform at all. Gating on
    // `!off` alone would leave the last listening/speaking buffer frozen on
    // screen (OrbFrame.waveform is never cleared) across those other states.
    final reactive =
        frame.state == OrbState.listening || frame.state == OrbState.speaking;
    if (reactive) {
      _drawWave(canvas, pal.wave, cx, cy + r * 0.06, r * 0.72, r * 0.24);
    }
    canvas.restore();

    // --- 5. specular highlight (glass) ---
    final specCenter = Offset(cx - r * 0.28, cy - r * 0.34);
    final specRect = Rect.fromCenter(
      center: specCenter,
      width: r * 0.88,
      height: r * 0.6,
    );
    final spec = RadialGradient(
      // orb.js centers this gradient at (cx - 0.32R, cy - 0.4R) — offset from
      // the ellipse's own center (cx - 0.28R, cy - 0.34R, i.e. specCenter) by
      // (-0.04R, -0.06R) — deliberately off-center from the highlight shape
      // for a glass-sparkle look, rather than dead-centering it. Express
      // that offset as an Alignment fraction of specRect's own half-width
      // (0.44R) / half-height (0.3R); default focal (== center) is correct
      // since orb.js's inner circle here has radius 0 (a plain, non-focal
      // gradient).
      center: const Alignment((-0.32 + 0.28) / 0.44, (-0.4 + 0.34) / 0.3),
      // radius is a fraction of specRect's shortestSide (0.6R): R*0.55 / 0.6R.
      radius: 0.55 / 0.6,
      colors: [
        Colors.white.withValues(alpha: 0.5 * kClarity + 0.15),
        Colors.white.withValues(alpha: 0.0),
      ],
      stops: const [0.0, 1.0],
    );
    canvas.save();
    canvas.translate(specCenter.dx, specCenter.dy);
    canvas.rotate(-0.5);
    canvas.translate(-specCenter.dx, -specCenter.dy);
    canvas.drawOval(specRect, Paint()..shader = spec.createShader(specRect));
    canvas.restore();

    // --- 6. crisp rim light ---
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = pal.rim.withValues(alpha: off ? 0.4 : 0.9),
    );
  }

  /// Live waveform across the core, tapered at both ends, with a soft glow.
  void _drawWave(Canvas canvas, Color color, double cx, double cy,
      double halfW, double amp) {
    final wave = frame.waveform;
    final n = wave.length;
    if (n < 2) return;

    final path = Path();
    for (var i = 0; i < n; i++) {
      final x = cx - halfW + (i / (n - 1)) * (2 * halfW);
      final edge = math.sin((i / (n - 1)) * math.pi); // taper both ends
      final y = cy + wave[i] * amp * edge;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = color.withValues(alpha: 0.62)
      ..maskFilter = MaskFilter.blur(BlurStyle.solid, _sigma(8));
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant OrbPainter oldDelegate) =>
      oldDelegate.frame != frame;
}
