import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'audio_levels.dart';
import 'orb_envelope.dart';
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
  /// Samples across the trace's full width, derived from [kWaveSeconds] at the
  /// CURRENT feed rate so the trace shows the same DURATION whatever the stream.
  ///
  /// Was a fixed 1024 — the web analyser's fftSize, carried over unexamined.
  /// At the 24kHz TTS rate that is 43ms across the whole width, which is why
  /// the trace read as hair: 8 samples per bucket is inside a single pitch
  /// period, and the whole thing scrolled a screen-width every 43ms.
  int get _waveWindow =>
      math.min((kWaveSeconds * _feedRate).round(), PcmRing.defaultCapacity);

  /// Points in the drawn trace. Unchanged from the per-chunk implementation.
  static const int kWavePoints = 128;

  /// Largest chunk seen so far. Chunk size is a device property — Android hands
  /// back whatever `AudioRecord.getMinBufferSize` decided — so the read lag has
  /// to be measured, not assumed.
  int _chunk = 0;

  OrbState _state = OrbState.off;
  final LevelSmoother _smoother = LevelSmoother(); // attack/release live here
  final AutoGain _gain = AutoGain();
  final TransientDetector _transient = TransientDetector();
  double _audioTarget = 0.0;
  double _waveGain = 1.0;
  Float32List _waveform = Float32List(0);
  double _t = 0.0;

  final PcmRing _ring = PcmRing();
  final Float32List _waveScratch = Float32List(kWavePoints);
  /// Absolute sample position the drawn window ends at. Advanced by wall-clock
  /// time in [advance], NOT by audio arrival — that is what makes consecutive
  /// frames overlap instead of jumping one whole chunk at a time.
  double _playhead = 0.0;
  int _feedRate = 16000; // 16k mic / 24k TTS, set by whoever is feeding us

  /// Whether a playback run is in progress. A run begins with the first chunk
  /// after the last one ended, and ends when the trace has drawn every sample
  /// that arrived and faded out.
  bool _runActive = false;

  /// Seconds the cursor has spent having nothing left to draw. Drives the fade.
  double _dryFor = 0.0;

  double _presence = 0.0;

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
      _gain.reset();
      _waveGain = 1.0;
      _runActive = false;
      _dryFor = 0.0;
      _audioTarget = 0.0;
      _presence = 0.0;
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
    if (!_runActive) {
      // A new playback run. Clear the ring and put the cursor at zero so the
      // window before the first sample reads as silence rather than as the tail
      // of the PREVIOUS utterance — the same reason powering off clears it.
      _ring.clear();
      _playhead = 0.0;
      _gain.reset();
      _runActive = true;
      _dryFor = 0.0;
    }
    _ring.write(pcm16);
  }

  // There is deliberately NO playedMs() correction here — see
  // VoiceController's note where the poll used to live. AudioTrackPlayer's
  // clock is relative to ITS run, and the player's run is not this one: it
  // re-anchors whenever its queue drains, which a gap between the reflex's
  // audio and the brain's is enough to cause. A cursor corrected against a
  // clock that re-anchors independently gets yanked back to the start every
  // time the two disagree.

  /// Whether the orb draws a waveform right now.
  ///
  /// SPEAKING ONLY — deliberately narrower than [_reactive]. The trace is
  /// Henry's voice; a trace of the user's own speech competes with the live
  /// transcript, which is the thing they are actually reading while they talk.
  /// Listening still reacts (see [_reactive]) so the halos pulse and the orb
  /// visibly hears them; it just does not draw.
  bool get _drawsWave => _state == OrbState.speaking;

  /// Whether the orb reacts to audio at all — level, punch, halo flare.
  /// Wider than [_drawsWave] on purpose.
  bool get _reactive =>
      _state == OrbState.listening || _state == OrbState.speaking;

  /// Raw loudness in (0..1). Set from the audio chunk listener; smoothed per
  /// FRAME by [advance] so the response is frame-locked and device-independent
  /// (orb.js smooths once per requestAnimationFrame, not once per audio buffer).
  /// Deliberately does NOT notify — [advance] drives the repaint.
  set audioTarget(double v) => _audioTarget = v;

  /// Smoothed loudness, derived. No public setter by design.
  double get level => _smoother.value;

  /// Syllable-onset strength, 0..1. Flares the halos and the contact glow.
  /// Derived. No public setter by design.
  double get punch => _transient.value;

  /// Scalar the painter multiplies each bucket magnitude by before drawing.
  ///
  /// Kept OUT of [PcmRing.readInto] on purpose: normalising inside the resampler
  /// would make two overlapping reads disagree about the samples they share, and
  /// the trace would shimmer rather than slide. One scalar per frame is also
  /// cheaper than 128 divisions.
  double get waveGain => _waveGain;

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

  /// Test seam: the raw target, before per-frame smoothing. `level` alone
  /// cannot distinguish "fed the wrong value" from "has not smoothed yet".
  @visibleForTesting
  double get debugAudioTarget => _audioTarget;

  /// Same reasoning as [debugSetLevel]: the auto-gain is a function of the audio
  /// history, so pinning it is what keeps `paint` a pure function of
  /// (state, t, level, punch, waveform, waveGain, size) — and therefore what
  /// keeps a golden possible.
  @visibleForTesting
  void debugSetWaveGain(double v) => _waveGain = v;

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
      _transient.reset();
      _gain.reset();
      _waveGain = 1.0;
      _runActive = false;
      _dryFor = 0.0;
      _audioTarget = 0.0;
      _presence = 0.0;
      return;
    }
    final reactive = _reactive;
    final target = reactive ? _audioTarget : 0.0;
    _smoother.update(target, dt);
    // Fed the RAW target, not the smoothed level: the whole job here is to see
    // the attack of a syllable, and the smoother exists to take attacks off.
    _transient.update(target, dt);
    if (_drawsWave) _advanceWave(dt);
    final speed = _state == OrbState.thinking
        ? 1.4
        : 1.0 + (reactive ? _smoother.value * 1.4 : 0.0);
    _t += dt * speed;
    _presence += ((_lineWanted ? 1.0 : 0.0) - _presence) *
        alphaForDt(_presenceAlpha60, dt);
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

    // DRYNESS IS "the cursor has drawn every sample that exists", not "no audio
    // arrived recently". Those are wildly different for TTS: Cartesia streams an
    // utterance far faster than real time, so a ten-second answer can ARRIVE in
    // two and then play out for eight. Keyed on arrival, the trace faded
    // half-way through Henry still talking.
    if (_playhead >= written) {
      // Hold at the write head. Letting it run on is what used to overrun the
      // stream and trip the forward resync below into re-reading the tail
      // forever — a wave still open with nothing being said.
      _playhead = written.toDouble();
      _dryFor += dt;
      final dry = _dryFor - kWaveDrySeconds;
      if (dry <= 0) {
        // A grace period, so a single frame of overrun cannot flicker.
        _readWindow(dt, observeGain: false);
        return;
      }
      final fade = 1.0 - (dry / kWaveFadeSeconds).clamp(0.0, 1.0);
      if (fade <= 0.0) {
        _waveScratch.fillRange(0, kWavePoints, 0.0);
        _waveform = _waveScratch;
        _gain.reset();
        _runActive = false; // the next chunk starts a fresh run
        return;
      }
      // Re-read the SAME window and scale it. Scaling in place would compound
      // frame over frame; `fade` is recomputed from elapsed time each frame, so
      // re-reading first keeps the ramp linear.
      _readWindow(dt, observeGain: false);
      for (var i = 0; i < kWavePoints; i++) {
        _waveScratch[i] *= fade;
      }
      _waveform = _waveScratch;
      return;
    }

    _dryFor = 0.0;
    // Deliberately NO forward resync. The old `lag > _waveMaxLag` clamp yanked
    // the cursor up to the newest ARRIVED sample, which for a stream that
    // arrives faster than it plays meant the trace ran seconds ahead of the
    // sound. It was built for a real-time mic stream, where arrival and
    // playback are the same rate and the clamp is harmless. The cursor's rate
    // is now the only thing that decides what is drawn, so it stays honest by
    // construction: playback consumes the same audio at the same real-time
    // rate from the same anchor.
    //
    // Falling off the BACK is still possible if the ring evicts what we have
    // not drawn yet (a very long stall); clamp up to the oldest live sample
    // rather than reading silence that was really speech.
    final oldestLive = written - PcmRing.defaultCapacity;
    if (_playhead < oldestLive) _playhead = oldestLive.toDouble();
    _readWindow(dt, observeGain: true);
  }

  /// One symmetric 3-tap pass across the buckets.
  ///
  /// Polish only — the envelope is legible because of [kWaveSeconds], not
  /// because of this. Runs before the gain is observed so the peak the gain
  /// normalises against is the peak actually drawn.
  void _smoothBuckets() {
    if (kWaveSmoothing <= 0) return;
    const w = kWaveSmoothing;
    var prev = _waveScratch[0];
    for (var i = 1; i < kWavePoints - 1; i++) {
      final cur = _waveScratch[i];
      _waveScratch[i] = cur * (1 - w) + (prev + _waveScratch[i + 1]) * (w / 2);
      prev = cur;
    }
  }

  void _readWindow(double dt, {required bool observeGain}) {
    _ring.readInto(_waveScratch, end: _playhead.floor(), window: _waveWindow);
    _smoothBuckets();
    if (observeGain) {
      // The loudest bucket in the window IS the instantaneous peak, so the gain
      // tracks exactly what is about to be drawn rather than a separate estimate
      // that could disagree with it.
      var peak = 0.0;
      for (var i = 0; i < kWavePoints; i++) {
        final v = _waveScratch[i];
        if (v > peak) peak = v;
      }
      _gain.observe(peak, dt);
      _waveGain = _gain.gain;
    }
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

/// Six-layer glass orb drawn with stacked Canvas ops.
///
/// **FROZEN — this is the fallback, not the orb.** `OrbShaderPainter` is what
/// normally renders; this runs only when `shaders/orb.frag` failed to load, so
/// its job is to look like the app on a device where something has already
/// gone wrong. Do not tune it, and do not extend it: changes belong in
/// `shaders/orb.frag`. It keeps the orb's only golden
/// (`test/meridian/goldens/orb_listening.png`), because a golden over
/// shader-painted content hangs the test harness — see the spec's spike table.
///
/// The waveform is NOT frozen: it comes from the shared `drawOrbEnvelope`, so
/// both painters draw the same wave by construction.
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
            math.sin(t * 1.3 + i * 1.4) * r0 * 0.025 * kBreathe * (1 + level);
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
        canvas.drawCircle(center, rr, paint);
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

    // --- 4. live waveform (reactive states only, inside the clip) ---
    // orb.js only draws this for REACTIVE[state] (listening = mic, speaking =
    // playback) — idle/ambient/thinking draw no waveform at all. Gating on
    // `!off` alone would leave the last listening/speaking buffer frozen on
    // screen (OrbFrame.waveform is never cleared) across those other states.
    // SPEAKING only — the trace is Henry's voice. See OrbFrame._drawsWave.
    if (frame.state == OrbState.speaking) {
      drawOrbEnvelope(
        canvas,
        wave: frame.waveform,
        gain: frame.waveGain,
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
