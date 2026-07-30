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
  /// `analyser.fftSize = 1024` on BOTH web analysers (capture.js:56,
  /// playback.js:8), so a frame draws the most recent 1024 samples.
  static const int kWaveWindow = 1024;

  /// Points in the drawn trace. Unchanged from the per-chunk implementation.
  static const int kWavePoints = 128;

  /// Largest chunk seen so far. Chunk size is a device property — Android hands
  /// back whatever `AudioRecord.getMinBufferSize` decided — so the read lag has
  /// to be measured, not assumed.
  int _chunk = 0;

  /// How far behind the newest sample the cursor runs. The stream arrives in
  /// bursts while the cursor drains smoothly, so the lag sawtooths by one chunk
  /// between arrivals; keeping TWO chunks of lead means the trough never reaches
  /// the write head. Too small and the cursor starves once per chunk — which is
  /// exactly the stutter this buffering exists to remove.
  int get _waveTargetLag =>
      math.max(kWaveWindow, math.min(_chunk * 2, PcmRing.defaultCapacity ~/ 4));

  /// Resync threshold, both directions. In steady state neither bound is reached:
  /// the cursor and the stream advance at the same long-run rate. It trips on
  /// startup, on a stalled or bursty stream, and on slow drift between the frame
  /// clock and the audio clock.
  int get _waveMaxLag => _waveTargetLag * 2;

  OrbState _state = OrbState.off;
  final LevelSmoother _smoother = LevelSmoother(); // the 0.2 alpha lives here (Task 2)
  double _audioTarget = 0.0;
  Float32List _waveform = Float32List(0);
  double _t = 0.0;

  final PcmRing _ring = PcmRing();
  final Float32List _waveScratch = Float32List(kWavePoints);
  /// Absolute sample position the drawn window ends at. Advanced by wall-clock
  /// time in [advance], NOT by audio arrival — that is what makes consecutive
  /// frames overlap instead of jumping one whole chunk at a time.
  double _playhead = 0.0;
  int _feedRate = 16000; // 16k mic / 24k TTS, set by whoever is feeding us

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
      // Same reasoning for the trace: a wake must not flash the audio from
      // whatever was being said when we powered down.
      _ring.clear();
      _playhead = 0.0;
      _chunk = 0; // the next source may be the other rate with other chunk sizes
      _waveScratch.fillRange(0, kWavePoints, 0.0);
      _waveform = Float32List(0);
    }
    notifyListeners();
  }

  /// Append live audio. Deliberately does NOT notify — [advance] samples the ring
  /// once per frame and drives the repaint, mirroring the web's
  /// read-the-analyser-inside-draw() behaviour.
  void feedPcm(Uint8List pcm16, {int sampleRate = 16000}) {
    _feedRate = sampleRate;
    final n = pcm16.lengthInBytes ~/ 2;
    if (n > _chunk) _chunk = n;
    _ring.write(pcm16);
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

  /// Test seams: pin the clock and the smoothed level so OrbPainter.paint becomes
  /// an explicitly pure function of (state, t, level, waveform, size) — which is
  /// what makes a golden possible. Neither notifies.
  @visibleForTesting
  set debugT(double v) => _t = v;

  @visibleForTesting
  void debugSetLevel(double v) => _smoother.debugSet(v);

  /// Samples between the read cursor and the newest one. Test seam: keeping a
  /// lead IS the mechanism here, and a cursor sitting on the write head reads a
  /// fresh window per chunk — the exact stutter this replaced — while still
  /// producing plausible-looking output.
  @visibleForTesting
  double get debugWaveLag => _ring.written - _playhead;

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
    if (reactive) _advanceWave(dt);
    final speed = _state == OrbState.thinking
        ? 1.4
        : 1.0 + (reactive ? _smoother.value * 1.4 : 0.0);
    _t += dt * speed;
    notifyListeners();
  }

  /// Slide the read cursor by one frame of wall-clock time and resample.
  ///
  /// In steady state the stream delivers `sampleRate` samples per second and the
  /// cursor advances by the same amount, so the lag is self-maintaining and the
  /// two clamps below effectively never fire. They exist for the edges: the very
  /// first frames (cursor starts at 0 while the stream is already running), a
  /// stalled or bursty stream, and long-run drift between the frame clock and the
  /// audio clock.
  void _advanceWave(double dt) {
    _playhead += dt * _feedRate;
    final written = _ring.written;
    final lag = written - _playhead;
    // Both bounds resync to the same place. Clamping a starved cursor to the
    // write head instead would leave it pinned there — reading `written` every
    // frame is precisely the per-chunk behaviour this replaced, and nothing
    // would ever restore the lead, so one stall would degrade the trace for the
    // rest of the session.
    if (lag < 0 || lag > _waveMaxLag) {
      _playhead = (written - _waveTargetLag).toDouble();
    }
    _ring.readInto(_waveScratch,
        end: _playhead.floor(), window: kWaveWindow);
    // Reused in place: advance() is the only writer and it runs on the frame
    // callback, and the painter reads it synchronously in the paint that this
    // same notifyListeners() schedules.
    _waveform = _waveScratch;
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
