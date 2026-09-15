import 'dart:math' as math;
import 'dart:typed_data';

import 'orb_tuning.dart';

/// Smoothed loudness + waveform extraction for the orb, computed straight from the
/// PCM16LE mono buffers we already handle (mic capture and TTS playback).
///
/// `rmsFromPcm16`'s `* 3` gain and its clamp are inherited from the web orb. The
/// waveform path below deliberately is NOT: see [PcmRing.readInto].

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

/// A rolling buffer of recent PCM16 samples — our stand-in for the web
/// AnalyserNode's time-domain buffer.
///
/// Why this exists: `orb.js` calls `getByteTimeDomainData()` *inside* draw(), so
/// every frame reads a fresh window. Its analyser is fed by the audio graph every
/// 128-frame render quantum (~2.7ms), so consecutive 60Hz reads of a 1024-sample
/// window overlap by ~74% — the trace slides. Our audio arrives in chunks at
/// ~20Hz, and an Android `AudioRecord` chunk is often ≥1024 samples, so simply
/// re-reading "the newest 1024 samples" each frame would still jump the whole
/// shape once per chunk. The overlap has to come from somewhere, so reads are
/// addressed by an ABSOLUTE sample position that the caller advances by
/// wall-clock time (see `OrbFrame._advanceWave`).
class PcmRing {
  /// Must comfortably exceed (max read lag + window). 32768 samples is 2.0s at
  /// the 16kHz mic rate and 1.4s at the 24kHz TTS rate — 64KB, allocated once.
  static const int defaultCapacity = 32768;

  PcmRing({this.capacity = defaultCapacity}) : _buf = Int16List(capacity);

  final int capacity;
  final Int16List _buf;
  int _written = 0;

  /// Total samples ever written — the absolute position just past the newest one.
  /// Monotonic, so it doubles as the clock the read cursor is measured against.
  int get written => _written;

  void write(Uint8List pcm16) {
    final n = pcm16.lengthInBytes ~/ 2;
    if (n == 0) return;
    final view = ByteData.sublistView(pcm16);
    for (var i = 0; i < n; i++) {
      _buf[_written % capacity] = view.getInt16(i * 2, Endian.little);
      _written++;
    }
  }

  /// Fill [out] with the PEAK MAGNITUDE of each bucket of the [window] samples
  /// ENDING at absolute position [end]. Output is unsigned, 0..1.
  ///
  /// **This used to take each bucket's MEAN, and that was the whole reason the
  /// orb looked dead.** A 1024-sample window into 128 points is an 8:1 reduction
  /// of *signed* audio: consecutive samples of speech routinely have opposite
  /// signs, so averaging them cancels the signal and the trace collapses toward
  /// the centreline. Measured on real TTS it cost roughly an order of magnitude
  /// of amplitude before the painter ever saw the data. A peak envelope is what
  /// every oscilloscope and waveform view actually draws, and it cannot cancel.
  ///
  /// Magnitude rather than signed min/max because the painter mirrors the trace
  /// about the centreline — the sign carries no information it can render.
  ///
  /// Deliberately NOT normalised here: this stays a pure resampler so that two
  /// reads of overlapping windows agree exactly on the samples they share, which
  /// is the property that makes the trace SLIDE instead of redraw. Normalisation
  /// is a single scalar applied at paint time — see [AutoGain].
  ///
  /// Positions that were never written, or have already been overwritten, read as
  /// silence — so a window straddling the start of the stream is zero-padded at
  /// the front and the newest sample always lands at the end.
  void readInto(Float32List out, {required int end, int window = 1024}) {
    final points = out.length;
    if (points == 0) return;
    if (window <= 0 || _written == 0) {
      out.fillRange(0, points, 0.0);
      return;
    }
    final stop = end.clamp(0, _written);
    final startAbs = stop - window;
    // Anything older than this has already been overwritten by the ring.
    final oldestLive = math.max(0, _written - capacity);
    final bucket = window / points;
    // Sub-sample inside each bucket. A 0.6s window at 24kHz puts ~112 samples
    // in every bucket, and scanning all of them is ~14k iterations PER FRAME at
    // up to 120Hz for no visible gain: the peak of 16 evenly spread samples
    // tracks the peak of 112 closely enough that the difference does not
    // survive being drawn 1px wide. Short windows are unaffected — the stride
    // floors at 1, so a bucket of 8 still reads all 8.
    final stride = (bucket / 16).floor().clamp(1, 1 << 20);
    for (var i = 0; i < points; i++) {
      final from = startAbs + (i * bucket).floor();
      var to = startAbs + ((i + 1) * bucket).floor();
      if (to <= from) to = from + 1;
      var peak = 0.0;
      for (var j = from; j < to; j += stride) {
        // Also keeps j non-negative, so the modulo below is always well-defined.
        if (j < oldestLive || j >= stop) continue;
        final v = _buf[j % capacity] / 32768.0;
        final m = v < 0 ? -v : v;
        if (m > peak) peak = m;
      }
      out[i] = peak > 1.0 ? 1.0 : peak;
    }
  }

  void clear() {
    _written = 0;
    _buf.fillRange(0, capacity, 0);
  }
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

/// Normalises the waveform's scale so conversational speech fills the sphere.
///
/// Raw speech rarely peaks above ~0.3 of full scale, so an un-normalised trace
/// spends its life in the bottom third of its range no matter how correct the
/// sampling is. This tracks a rolling peak — adopted instantly, released over
/// about a second — and exposes the reciprocal as a gain.
///
/// Two clamps carry the whole safety argument. It never attenuates below unity,
/// so genuinely loud audio is never shrunk; and it never amplifies past
/// [kAgcMaxGain], which is what stops a silent room's noise floor from being
/// normalised up into a convincing waveform that isn't there.
class AutoGain {
  double _peak = 0.0;

  /// Visible for assertions about the decay; the painter wants [gain].
  double get peak => _peak;

  double get gain {
    const floor = 1.0 / kAgcMaxGain;
    final p = _peak < floor ? floor : _peak;
    final g = 1.0 / p;
    if (g > kAgcMaxGain) return kAgcMaxGain;
    return g < 1.0 ? 1.0 : g;
  }

  void observe(double instantPeak, double dt) {
    if (dt > 0) {
      _peak *= math.pow(kAgcDecayPerSec, dt).toDouble();
    }
    if (instantPeak > _peak) _peak = instantPeak;
  }

  void reset() {
    _peak = 0.0;
  }
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
