import 'dart:math' as math;
import 'dart:typed_data';

import 'orb_tuning.dart';

/// Smoothed loudness for the orb, computed straight from the PCM16LE mono
/// buffers of TTS playback. `rmsFromPcm16` has exactly one caller —
/// `PlaybackLevels.add`, which scores each arriving chunk on its way into the
/// index; the mic path stopped measuring loudness when the orb's level moved
/// playback-side.
///
/// `rmsFromPcm16`'s `* 3` gain and its clamp are inherited from the web orb.
///
/// This file used to also carry the waveform pipeline — a PCM ring buffer and
/// an auto-gain — that let the orb redraw a scrolling trace of the actual
/// samples. The line is synthetic now (see `orb_line.dart`): it needs one
/// number, how loud he is right now, so none of that machinery survives.

double rmsFromPcm16(Uint8List pcm) {
  final n = pcm.lengthInBytes ~/ 2;
  if (n == 0) return 0.0;
  final view = ByteData.sublistView(pcm);
  var sum = 0.0;
  for (var i = 0; i < n; i++) {
    final v = view.getInt16(i * 2, Endian.little) / 32768.0;
    sum += v * v;
  }
  return math.min(1.0, math.sqrt(sum / n) * 3.0);
}

/// Re-anchor a raw level so [kLevelLoudAnchor] reads as "full", for the terms
/// that SHAPE the orb (the line's cycle count and phase speed, the rings'
/// level boost).
///
/// There is no AGC here and deliberately so — see [kLevelLoudAnchor]. Kept out
/// of the shaping call sites themselves so there is exactly one place the
/// mapping can be changed, and so amplitude's use of the RAW level is a
/// visible omission rather than an oversight.
double anchoredLevel(double level) =>
    (level / kLevelLoudAnchor).clamp(0.0, 1.0);

/// Perceptual response curve on the RAW playback RMS, applied once — in the
/// level poll, on its way into `OrbFrame.audioTarget` — so that everything
/// downstream (amplitude, the shaping anchor, the transient detector, the
/// halos, the ring boost) sees loudness as it is heard rather than as it is
/// measured.
///
/// RMS is linear power; hearing is not, and speech spans a huge range, so soft
/// phonemes sit near the floor and never move the line. [kLevelCurve] < 1
/// lifts them: 0.10 becomes 0.20, 0.15 becomes 0.27, while 0.60 becomes only
/// 0.70 — quiet detail rises much further than loud detail does, which is what
/// "softer would just be softer reactive" asks for without flattening the
/// difference between a mumble and a shout.
///
/// Distinct from [anchoredLevel] and composed with it, not instead of it: this
/// reshapes the RANGE, the anchor rescales it for the terms that shape the orb.
/// Both exist because playback RMS never reaches 1.0, so they were re-derived
/// together — see [kLevelLoudAnchor].
///
/// The clamp is load-bearing. `drawOrbLine` treats `amp` as a hard ceiling and
/// `orb_line_test.dart` asserts the line never exceeds it; a level above 1.0
/// would paint outside the sphere.
double curvedLevel(double level) =>
    math.pow(level.clamp(0.0, 1.0), kLevelCurve).toDouble();

/// Re-express a per-frame-at-60Hz smoothing coefficient for an actual frame
/// duration.
///
/// The bug this fixes: `level += (target - level) * 0.2` applied once per frame
/// is only a 0.2 coefficient AT 60Hz. On a 120Hz phone the same line converges
/// twice as fast in wall-clock, so the orb had a different personality
/// depending on the display it was running on. Inherited from orb.js, where
/// 60Hz was a safe assumption and is no longer one here.
double alphaForDt(double alpha60, double dt) {
  if (dt <= 0) return 0.0;
  if (alpha60 <= 0.0) return 0.0;
  if (alpha60 >= 1.0) return 1.0;
  final frames = dt * 60.0;
  // A gap longer than a second is a stall, not a frame — snap rather than
  // spend the next second catching up on audio that has already been heard.
  if (frames >= 60.0) return 1.0;
  return 1.0 - math.pow(1.0 - alpha60, frames).toDouble();
}

/// Exponential smoother with VU-meter ballistics: fast attack, slow release.
///
/// The asymmetry is deliberate and is most of what separates "alive" from
/// "animated" — a peak arrives immediately and then falls away smoothly, which
/// is how physical meters and human hearing both behave. Rates come from
/// [kLevelAttack60] / [kLevelRelease60] and are frame-rate independent via
/// [alphaForDt].
class LevelSmoother {
  double _level = 0.0;

  double get value => _level;

  void update(double target, double dt) {
    final alpha60 = target > _level ? kLevelAttack60 : kLevelRelease60;
    _level += (target - _level) * alphaForDt(alpha60, dt);
  }

  void reset() {
    _level = 0.0;
  }

  /// Test seam behind [OrbFrame.debugSetLevel] (which carries the
  /// @visibleForTesting annotation; putting it here too would flag that call).
  /// Pins the smoothed level, otherwise only reachable by running update()
  /// dozens of times.
  void debugSet(double v) => _level = v;
}

/// Detects syllable onsets — the "punch" that flares the halos.
///
/// Two followers chase the same signal at very different rates; the amount by
/// which the fast one has pulled ahead of the slow one IS the onset. A steady
/// tone lets both converge and therefore produces no punch, which is exactly
/// the behaviour wanted: the orb should react to the *shape* of speech, not to
/// its mere presence (the level already covers presence).
class TransientDetector {
  double _fast = 0.0;
  double _slow = 0.0;
  double _punch = 0.0;

  /// Onset strength, 0..1.
  double get value => _punch;

  void update(double target, double dt) {
    _fast += (target - _fast) * alphaForDt(kPunchFast60, dt);
    _slow += (target - _slow) * alphaForDt(kPunchSlow60, dt);
    final onset = ((_fast - _slow) * kPunchGain).clamp(0.0, 1.0);
    if (onset > _punch) {
      _punch = onset; // instant attack — a hit is visible on the frame it lands
    } else {
      _punch += (onset - _punch) * alphaForDt(kPunchRelease60, dt);
    }
  }

  void reset() {
    _fast = 0.0;
    _slow = 0.0;
    _punch = 0.0;
  }
}
