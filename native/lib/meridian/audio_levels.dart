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

  /// Fill [out] with the [window] samples ENDING at absolute position [end],
  /// averaged down to `out.length` points and normalised to -1..1.
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
    for (var i = 0; i < points; i++) {
      final from = startAbs + (i * bucket).floor();
      var to = startAbs + ((i + 1) * bucket).floor();
      if (to <= from) to = from + 1;
      var sum = 0.0;
      var count = 0;
      for (var j = from; j < to; j++) {
        // Also keeps j non-negative, so the modulo below is always well-defined.
        if (j < oldestLive || j >= stop) continue;
        sum += _buf[j % capacity] / 32768.0;
        count++;
      }
      out[i] = count == 0 ? 0.0 : (sum / count).clamp(-1.0, 1.0);
    }
  }

  void clear() {
    _written = 0;
    _buf.fillRange(0, capacity, 0);
  }
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
