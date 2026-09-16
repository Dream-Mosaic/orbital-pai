import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'audio_levels.dart';
import 'orb_line.dart';
import 'orb_state.dart';
import 'orb_tuning.dart';
import 'palette.dart';

// Geometry constants, originally ported from server/assets/js/voice/orb.js.
// The GEOMETRY still matches the web orb and there is no reason to move it.
// The MOTION no longer does — see orb_tuning.dart, which owns every value that
// decides how the orb feels and is deliberately not orb.js's. The web is a
// monitor now; it is not the reference implementation and not a parity target.
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
  final LevelSmoother _smoother = LevelSmoother(); // attack/release live here
  final TransientDetector _transient = TransientDetector();
  double _audioTarget = 0.0;
  double _t = 0.0;

  double _presence = 0.0;
  double _ringPhase = 0.0;

  /// The halo rings' own clock, in radians, advanced per frame at the state's
  /// cadence ([_ringSpeed]) rather than at [t]'s.
  ///
  /// Separate from [t] because the rings are the orb's ambient loop and want
  /// their own pace: calm at idle, quicker while Henry is thinking, quickest
  /// while he is speaking. Monotonic by construction — it is a phase, never
  /// wound back except by powering off — so a cadence change is a change of
  /// SPEED, never a jump in position.
  double get ringPhase => _ringPhase;

  /// How much of the line is on screen, 0..1.
  ///
  /// A function of STATE, not of level. The line belongs to Henry's half of the
  /// conversation: it fades in while he is thinking or speaking and out while
  /// he is listening or idle, so the live transcript owns the orb when the
  /// user is the one talking.
  double get presence => _presence;

  bool get _lineWanted =>
      _state == OrbState.thinking || _state == OrbState.speaking;

  /// kLinePresenceSeconds expressed as a 60Hz smoothing coefficient: reaching
  /// ~95% in that time means shedding 5% of the remaining gap per frame at
  /// 1 - 0.05^(1/(seconds*60)).
  static final double _presenceAlpha60 =
      1.0 - math.pow(0.05, 1.0 / (kLinePresenceSeconds * 60.0)).toDouble();

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
      _transient.reset();
      _audioTarget = 0.0;
      // Same reasoning for the line: a wake must not inherit the presence or
      // the loudness of whatever was being said when we powered down.
      _presence = 0.0;
      _ringPhase = 0.0;
    }
    notifyListeners();
  }

  /// Whether the orb reacts to audio at all — level, punch, halo flare.
  ///
  /// Deliberately WIDER than the line's own rule ([presence], which is
  /// thinking + speaking): `listening` reacts so the halos pulse and the orb
  /// visibly hears you, but draws no line, because the live transcript is what
  /// you are actually reading while you talk.
  bool get _reactive =>
      _state == OrbState.listening || _state == OrbState.speaking;

  /// Phase advance per second for the current state. `off` and `ambient` are 0
  /// by contract — the wall device at rest must not animate.
  double get _ringSpeed => switch (_state) {
        OrbState.off || OrbState.ambient => 0.0,
        OrbState.idle => kRingSpeedIdle,
        OrbState.listening => kRingSpeedListening,
        OrbState.thinking => kRingSpeedThinking,
        OrbState.speaking =>
          kRingSpeedSpeaking + _smoother.value * kRingSpeedLevelBoost,
      };

  /// Raw loudness in (0..1). Set from the playback-clock poll (looked up by
  /// the frame actually leaving the speaker, not by chunk arrival — TTS
  /// audio arrives far faster than it plays); the mic listener no longer
  /// writes this at all. Smoothed per FRAME by [advance] so the response is
  /// frame-locked and device-independent (orb.js smooths once per
  /// requestAnimationFrame, not once per audio buffer). Deliberately does NOT
  /// notify — [advance] drives the repaint.
  set audioTarget(double v) => _audioTarget = v;

  /// Smoothed loudness, derived. No public setter by design.
  double get level => _smoother.value;

  /// Syllable-onset strength, 0..1. Flares the halos and the contact glow.
  /// Derived. No public setter by design.
  double get punch => _transient.value;

  double get t => _t;

  /// Test seams: pin the clock and the smoothed level so OrbPainter.paint
  /// becomes an explicitly pure function of
  /// (state, t, ringPhase, level, presence, size) — which is what makes a
  /// golden possible. Neither notifies. `ringPhase` and `presence` have no
  /// seam of their own: both are pure accumulations of [advance], so a fixed
  /// number of fixed-dt frames pins them exactly.
  @visibleForTesting
  set debugT(double v) => _t = v;

  @visibleForTesting
  void debugSetLevel(double v) => _smoother.debugSet(v);

  /// Test seam: the raw target, before per-frame smoothing. `level` alone
  /// cannot distinguish "fed the wrong value" from "has not smoothed yet".
  @visibleForTesting
  double get debugAudioTarget => _audioTarget;

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
      _transient.reset();
      _audioTarget = 0.0;
      _presence = 0.0;
      _ringPhase = 0.0;
      return;
    }
    final reactive = _reactive;
    final target = reactive ? _audioTarget : 0.0;
    _smoother.update(target, dt);
    // Fed the RAW target, not the smoothed level: the whole job here is to see
    // the attack of a syllable, and the smoother exists to take attacks off.
    _transient.update(target, dt);
    final speed = _state == OrbState.thinking
        ? 1.4
        : 1.0 + (reactive ? _smoother.value * 1.4 : 0.0);
    _t += dt * speed;
    _ringPhase += dt * _ringSpeed;
    _presence += ((_lineWanted ? 1.0 : 0.0) - _presence) *
        alphaForDt(_presenceAlpha60, dt);
    notifyListeners();
  }
}

/// Where the specular gradient's centre sits, as an [Alignment] fraction of the
/// highlight ellipse's half-width (0.44R) and half-height (0.3R).
///
/// orb.js centres this gradient at (cx - 0.32R, cy - 0.4R) — offset from the
/// highlight ellipse's own centre (cx - 0.28R, cy - 0.34R) by (-0.04R, -0.06R),
/// deliberately off-centre for a glass-sparkle look.
///
/// The subtlety: orb.js never rotates the canvas. Its `-0.5` is the `rotation`
/// ARGUMENT of `ctx.ellipse(...)` (orb.js:172), which tilts the ellipse path
/// alone, so the gradient is filled under an identity transform. We get the same
/// path by rotating the canvas instead — but that also rotates the shader, which
/// drags the gradient's centre off to (-0.0639R, -0.0335R) absolute: an error of
/// 0.0357R, i.e. 3.21px at r=90. Pre-rotating the offset by +0.5 rad cancels the
/// canvas rotation exactly and lands it back on orb.js's pixel.
///
/// Derived, not hand-tuned — `orb_geometry_test.dart` recomputes the rotation
/// from first principles and asserts this value.
const Alignment kSpecularGradientCenter = Alignment(-0.0144, -0.2394);

/// Six-layer glass orb drawn with stacked Canvas ops.
///
/// **FROZEN — this is the fallback, not the orb.** `OrbShaderPainter` is what
/// normally renders; this runs only when `shaders/orb.frag` failed to load, so
/// its job is to look like the app on a device where something has already
/// gone wrong. Do not tune it, and do not extend it: changes belong in
/// `shaders/orb.frag`. It keeps the orb's only golden
/// (`test/meridian/goldens/orb_speaking.png`), because a golden over
/// shader-painted content hangs the test harness — see the spec's spike table.
///
/// The line is NOT frozen: it comes from the shared `drawOrbLine`, so both
/// painters draw the same line by construction.
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
    final punch = off ? 0.0 : frame.punch;
    final t = frame.t;
    final ringPhase = frame.ringPhase;

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
        // The punch terms are the whole point of the transient detector: a
        // syllable onset shoves the rings outward and brightens them, and they
        // settle back between syllables. Level alone (which is smoothed, and
        // deliberately slow to release) cannot produce that per-hit flare.
        final spread =
            r0 * (1.06 + i * 0.17 + level * 0.05 + punch * kPunchSpread);
        final rr = spread +
            math.sin(ringPhase * 1.3 + i * 1.4) *
                r0 *
                0.025 *
                kBreathe *
                (1 + level);
        // Each ring orbits its own little Lissajous — two independent phases,
        // so the three never lock into a formation. The formula is the
        // shader's `haloField` drift verbatim; the only difference is the base
        // radius, r0 here against the shader's breathing R, which is the same
        // base the halo radii above already use. Keeping the centre on that
        // base is what keeps the whole ring assembly a uniform scale of the
        // shader's rather than a distorted one.
        final drift = Offset(
          kRingDrift * r0 * math.sin(ringPhase + i * 2.1),
          kRingDrift * r0 * math.cos(ringPhase * 0.83 + i * 1.7),
        );
        final alpha = (0.42 - f * 0.3) *
            (0.6 + level * 0.6) *
            (0.5 + kGlow * 0.5) *
            (1 + punch * kPunchGlow);
        final paint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 - f
          ..color = pal.glow.withValues(alpha: alpha.clamp(0.0, 1.0))
          // Canvas 2D shadowBlur draws the blurred shadow AND THEN composites the
          // crisp shape on top — BlurStyle.solid ("solid inside, fuzzy outside")
          // is the matching semantic. BlurStyle.normal would replace the crisp
          // stroke with the blur, crushing a thin stroke's peak alpha to near zero.
          ..maskFilter = MaskFilter.blur(BlurStyle.solid, _sigma(10 + 14 * kGlow));
        canvas.drawCircle(center + drift, rr, paint);
      }
    }

    // --- 2. outer contact glow under the sphere ---
    if (!off) {
      final paint = Paint()
        ..style = PaintingStyle.fill
        ..color = pal.glow.withValues(alpha: 0.06)
        ..maskFilter = MaskFilter.blur(BlurStyle.solid,
            _sigma(30 * kGlow * (0.6 + level + punch * 0.5)));
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

    // --- 4. the living line (inside the clip) ---
    // Gated on PRESENCE, not on the state: presence already IS the state rule
    // (thinking + speaking, faded), and gating on the state as well would cut
    // the fade off at its first frame so it would never be seen. The epsilon
    // is what CLOSES the gate — presence asymptotes and never reaches zero, so
    // `> 0` would keep building a path forever. See kLinePresenceEpsilon.
    if (frame.presence > kLinePresenceEpsilon) {
      drawOrbLine(
        canvas,
        level: frame.level,
        presence: frame.presence,
        t: frame.t,
        color: pal.wave,
        cx: cx,
        cy: cy + r * 0.06,
        halfW: r * 0.72,
        amp: r * kWaveAmp,
      );
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
      // Pre-rotated into the canvas frame — see kSpecularGradientCenter. The
      // default focal (== center) is correct: orb.js's inner circle here has
      // radius 0, so it is a plain, non-focal gradient.
      center: kSpecularGradientCenter,
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

  @override
  bool shouldRepaint(covariant OrbPainter oldDelegate) =>
      oldDelegate.frame != frame;
}
