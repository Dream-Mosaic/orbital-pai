import 'dart:math' as math;
import 'dart:typed_data';

/// Smoothed loudness + waveform extraction for the orb, computed straight from the
/// PCM16LE mono buffers we already handle (mic capture and TTS playback).
///
/// The web orb reads an AnalyserNode's *byte* time-domain data and normalises with
/// `(v - 128) / 128`; we have real PCM16, so the equivalent is `sample / 32768`.
/// The `* 3` gain and the clamp to 1.0 are carried over from orb.js unchanged.

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

/// Downsample to exactly [points] samples in -1..1 for the waveform stroke.
/// Each output point is the average of its input bucket (cheap anti-aliasing).
/// If the input has fewer samples than [points] (this never happens in
/// production — a mic chunk is ~1600 samples vs. 128 points), each input
/// sample is repeated across several output points, stretching the trace
/// rather than zero-padding it. The function always returns exactly [points]
/// samples.
Float32List waveformFromPcm16(Uint8List pcm, int points) {
  final out = Float32List(points);
  final n = pcm.lengthInBytes ~/ 2;
  if (n == 0 || points == 0) return out;
  final view = ByteData.sublistView(pcm);
  final bucket = n / points;
  for (var i = 0; i < points; i++) {
    final start = (i * bucket).floor();
    var end = ((i + 1) * bucket).floor();
    if (end <= start) end = start + 1;
    var sum = 0.0;
    var count = 0;
    for (var j = start; j < end && j < n; j++) {
      sum += view.getInt16(j * 2, Endian.little) / 32768.0;
      count++;
    }
    out[i] = count == 0 ? 0.0 : (sum / count).clamp(-1.0, 1.0);
  }
  return out;
}

/// Exponential smoother matching orb.js: `level += (target - level) * 0.2` per frame.
class LevelSmoother {
  static const double _alpha = 0.2;
  double _level = 0.0;

  double get value => _level;

  void update(double target) {
    _level += (target - _level) * _alpha;
  }

  void reset() {
    _level = 0.0;
  }
}
