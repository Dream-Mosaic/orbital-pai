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

/// The period every free-running clock on the orb is wrapped to, in the units
/// each of them counts (seconds for [OrbFrame.t], radians for the two phases).
///
/// 200*pi, and not an arbitrary large number: it is an exact common period of
/// every consumer any of the three has, so a wrap lands on a bit-identical
/// rendered position and cannot be seen.
///
///   * `t` feeds only `sin(t * 1.6)` (the breathe, in both painters and in
///     orb.frag): 200*pi * 1.6 = 160 full turns.
///   * `ringPhase` feeds `sin(p)`, `cos(p * 0.83)` and `sin(p * 1.3)`:
///     100, 83 and 130 full turns.
///   * `linePhase` feeds `sin(p * s)` for s in {1.0, 1.37, 0.71}:
///     100, 137 and 71 full turns.
///
/// It exists because these are 24/7 clocks on a wall device and they ship to
/// the shader as float32: unwrapped, a day of `idle` puts `t` at 86400, where
/// a float32 quantum is ~8ms and the breathe visibly steps. Adding a consumer
/// at a frequency that is not a rational multiple of these means changing this
/// number, which is why they are enumerated rather than summarised.
const double kPhaseWrap = 200 * math.pi;

double _wrapPhase(double v) => v >= kPhaseWrap ? v % kPhaseWrap : v;

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
  double _linePhase = 0.0;
  double _shapeLevel = 0.0;

  /// The halo rings' own clock, in radians, advanced per frame at the state's
  /// cadence ([_ringSpeed]) rather than at [t]'s.
  ///
  /// Separate from [t] because the rings are the orb's ambient loop and want
  /// their own pace: calm at idle, quicker while Henry is thinking, quickest
  /// while he is speaking. Monotonic by construction — it is a phase, never
  /// wound back except by powering off and by [kPhaseWrap], which is chosen so
  /// the wrap is invisible — so a cadence change is a change of SPEED, never a
  /// jump in position.
  double get ringPhase => _ringPhase;

  /// The LINE's own clock, in radians, advanced per frame at a speed that
  /// interpolates [kLineSpeedRest] -> [kLineSpeedLoud] on the (anchored)
  /// smoothed level.
  ///
  /// **Integrated here, exactly as [ringPhase] is, and for the same reason.**
  /// The line used to be handed `t` and multiply it by a level-dependent speed
  /// at render time. That is not a phase: it is (elapsed time x current
  /// speed), so d(phase)/d(level) = t * (kLineSpeedLoud - kLineSpeedRest).
  /// `t` never resets and advances all day in `idle`, so ten minutes in, a
  /// single frame's level move of 0.03 — well inside [kLevelRelease60]
  /// ballistics — rotated the whole line by ~30 radians. The line turned to
  /// spatial static during every attack and release, i.e. precisely while
  /// Henry talks, and a fresh-launch demo looked perfect. Do not reintroduce a
  /// level factor at the point of use.
  double get linePhase => _linePhase;

  /// The slow follower that drives the line's SHAPE — its cycle count — as
  /// distinct from [level], which drives its amplitude.
  ///
  /// Two time constants on purpose: a syllable must make the line taller on
  /// the frame it lands ([level], VU ballistics), and must not simultaneously
  /// re-draw the waveform underneath itself ([shapeLevel], ~0.68s). Collapsing
  /// them back into one number is the defect this exists to prevent. Already
  /// anchored through [anchoredLevel], so it is 0..1 shaping units, not raw
  /// loudness.
  double get shapeLevel => _shapeLevel;

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

  /// [kLineShapeSeconds] as a 60Hz coefficient, by the same 95%-in-T rule.
  static final double _shapeAlpha60 =
      1.0 - math.pow(0.05, 1.0 / (kLineShapeSeconds * 60.0)).toDouble();

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
      _linePhase = 0.0;
      _shapeLevel = 0.0;
      _t = 0.0;
    }
    notifyListeners();
  }

  /// Whether the orb reacts to audio at all — level, punch, halo flare.
  ///
  /// Deliberately WIDER than the line's own rule ([presence], which is
  /// thinking + speaking): `listening` is reactive IN SHAPE, so a mic-driven
  /// level would plug straight in and pulse the halos without ever drawing a
  /// line (the live transcript is what you are reading while you talk).
  ///
  /// But today nothing feeds it there. The only source of a NON-ZERO
  /// [audioTarget] is the playback-clock poll, which runs only while
  /// `speaking` and zeroes the target when it stops (the mic-teardown paths
  /// write it too, but only ever zero) — so in production the level simply DECAYS TO ZERO
  /// through `listening`, and that is the intended behaviour, not a gap. Keep
  /// this wide anyway: narrowing it to `speaking` would delete the seam a
  /// mic-driven source needs.
  bool get _reactive =>
      _state == OrbState.listening || _state == OrbState.speaking;

  /// Phase advance per second for the current state. `off` and `ambient` are 0
  /// by contract — the wall device at rest must not animate.
  double get _ringSpeed => switch (_state) {
        OrbState.off || OrbState.ambient => 0.0,
        OrbState.idle => kRingSpeedIdle,
        OrbState.listening => kRingSpeedListening,
        OrbState.thinking => kRingSpeedThinking,
        // Through [anchoredLevel], not the raw level: the boost is a SHAPING
        // term and was anchored at a loudness TTS playback never reaches, so
        // most of it was unreachable. See kLevelLoudAnchor.
        OrbState.speaking => kRingSpeedSpeaking +
            anchoredLevel(_smoother.value) * kRingSpeedLevelBoost,
      };

  /// Loudness in (0..1), on the PERCEPTUAL curve — `curvedLevel` is applied by
  /// the poll, once, so that everything reading it (amplitude here, the
  /// [anchoredLevel] shaping terms, the transient detector, the halos, the
  /// ring boost) agrees on what "loud" means. Not raw RMS; see kLevelCurve.
  ///
  /// Set from the playback-clock poll — the only
  /// source of a non-zero value here — which looks it up by the frame actually
  /// leaving the speaker, not by chunk arrival (TTS audio arrives far faster than it plays). The
  /// mic listener no longer writes this at all, and the poll zeroes it when it
  /// stops, so every non-`speaking` state decays from 0 rather than parking on
  /// the last thing heard. Smoothed per FRAME by [advance] so the response is
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
  /// (state, t, ringPhase, linePhase, level, shapeLevel, presence, size) —
  /// which is what makes a golden possible. None of them notify. `ringPhase`,
  /// `linePhase` and `presence` have no seam for normal use: all three are
  /// pure accumulations of [advance], so a fixed number of fixed-dt frames
  /// pins them exactly. `shapeLevel` has no seam of its own either — it rides
  /// [debugSetLevel], which pins both followers together.
  @visibleForTesting
  set debugT(double v) => _t = v;

  /// Test seam for the ONE branch that is otherwise unreachable: `advance`'s
  /// own `off` reset. The state setter zeroes every accumulator on the way
  /// into `off`, so by the time a tick could take that branch there is nothing
  /// left to observe — and it is the branch that runs if a tick ever does land
  /// after power-down, which is exactly why it exists.
  @visibleForTesting
  set debugLinePhase(double v) => _linePhase = v;

  /// Pins BOTH followers: a steady level is one the slow shape follower has
  /// long since converged on, so setting only the fast one would pin the orb
  /// in a state it can never actually be in (tall but drawn at rest cycles)
  /// and quietly make the golden a picture of nothing real.
  ///
  /// [v] is in CURVED units, not raw RMS. Production feeds `audioTarget`
  /// through `curvedLevel` at the poll, so `_smoother.value` never holds a raw
  /// RMS — a test that passes one here is pinning a level the orb cannot reach
  /// (raw 0.25 arrives as 0.54). See `kLevelCurve`.
  @visibleForTesting
  void debugSetLevel(double v) {
    _smoother.debugSet(v);
    _shapeLevel = anchoredLevel(v);
  }

  /// Test seam: the raw target, before per-frame smoothing. `level` alone
  /// cannot distinguish "fed the wrong value" from "has not smoothed yet".
  @visibleForTesting
  double get debugAudioTarget => _audioTarget;

  /// Advance one frame. Ported from orb.js's frame():
  ///   * `level` is smoothed toward the target ONCE PER FRAME (not per audio
  ///     chunk) so the response is frame-locked and device-independent;
  ///   * only the reactive states (see [_reactive]) track the audio target —
  ///     every other state targets 0, so the level decays instead of sticking;
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
      _linePhase = 0.0;
      _shapeLevel = 0.0;
      _t = 0.0;
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
    final shaping = anchoredLevel(_smoother.value);
    _t = _wrapPhase(_t + dt * speed);
    _ringPhase = _wrapPhase(_ringPhase + dt * _ringSpeed);
    _linePhase = _wrapPhase(_linePhase +
        dt * (kLineSpeedRest + (kLineSpeedLoud - kLineSpeedRest) * shaping));
    _shapeLevel += (shaping - _shapeLevel) * alphaForDt(_shapeAlpha60, dt);
    // Presence fades on the STATE, and the state's timing is the server's: it
    // arms `listening` at `audio_until + jitter_buffer_ms` (150ms,
    // `server/lib/app/config.ex`), a budget that has to absorb network transit,
    // AudioTrack startup AND the output route's own latency. On a Bluetooth
    // sink (~200-300ms) `listening` therefore arrives while tail audio is
    // still audible and the line starts leaving while Henry is still being
    // heard. Deliberately NOT changed: on the speaker, which is what the wall
    // device uses, the budget holds, and gating the fade on the drain
    // condition instead would be a different design. Written down because the
    // coupling is invisible from either end.
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
        // Each ring orbits its own little Lissajous. NOT a copy of the
        // shader's formula any more — literally the same call: `ringDrift` is
        // what `orb_uniforms.dart` packs into uDrift0..2, so there is one
        // evaluation of the orbit and the two renderers cannot disagree on it.
        //
        // It returns a FRACTION of the radius, and the base radius is the one
        // difference that remains: r0 here against the shader's breathing R,
        // which is the same base the halo radii above already use. Keeping the
        // centre on that base is what keeps the whole ring assembly a uniform
        // scale of the shader's rather than a distorted one.
        final unit = ringDrift(i, ringPhase);
        final drift = Offset(unit.dx * r0, unit.dy * r0);
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
          ..maskFilter =
              MaskFilter.blur(BlurStyle.solid, _sigma(10 + 14 * kGlow));
        canvas.drawCircle(center + drift, rr, paint);
      }
    }

    // --- 2. outer contact glow under the sphere ---
    if (!off) {
      final paint = Paint()
        ..style = PaintingStyle.fill
        ..color = pal.glow.withValues(alpha: 0.06)
        ..maskFilter = MaskFilter.blur(
            BlurStyle.solid, _sigma(30 * kGlow * (0.6 + level + punch * 0.5)));
      canvas.drawCircle(center, r, paint);
    }

    // --- 3. glass core (clipped): spherical shading + depth shadow ---
    canvas.save();
    canvas
        .clipPath(Path()..addOval(Rect.fromCircle(center: center, radius: r)));

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
        shapeLevel: frame.shapeLevel,
        presence: frame.presence,
        phase: frame.linePhase,
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
