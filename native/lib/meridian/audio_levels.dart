import 'dart:math' as math;
import 'dart:typed_data';

import 'orb_tuning.dart';

/// Smoothed loudness for the orb, computed straight from the PCM16LE mono
/// buffers we already handle (mic capture and TTS playback).
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
