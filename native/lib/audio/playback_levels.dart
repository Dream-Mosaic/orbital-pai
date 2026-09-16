import 'dart:collection';
import 'dart:typed_data';

import '../meridian/audio_levels.dart' show rmsFromPcm16;

/// One loudness value per arriving audio chunk, addressed by ABSOLUTE frame.
///
/// This is what replaced a 64KB PCM ring, a wall-clock cursor, a lead-sizing
/// resync, a dry detector and a fade. All of that existed to answer one
/// question — "which sample is being heard right now?" — which the platform
/// already knows: `AudioTrackPlayer.playedFrames()`. Given that number, the
/// only thing the orb needs is how loud the audio around it was, and one scalar
/// per chunk carries that.
///
/// Frames, never bytes. PCM16 mono is two bytes per frame, and counting bytes
/// would put every boundary at twice its true frame.
class PlaybackLevels {
  PlaybackLevels({this.retainFrames = 24000 * 30});

  /// How much history to keep. Only the recent past is ever looked up (playback
  /// trails arrival, it never precedes it), so anything older is dead weight —
  /// and a session that never evicted would grow for as long as the app runs.
  final int retainFrames;

  final Queue<_Span> _spans = Queue<_Span>();
  int _written = 0;

  int get writtenFrames => _written;

  /// Test seam: eviction is invisible from [levelAt] alone, so a test that
  /// could only read levels could not tell "evicted" from "retained forever".
  int get debugEntryCount => _spans.length;

  void add(Uint8List pcm16) {
    final frames = pcm16.lengthInBytes ~/ 2;
    if (frames == 0) return;
    final start = _written;
    _written += frames;
    _spans.addLast(_Span(start, _written, rmsFromPcm16(pcm16)));
    final oldest = _written - retainFrames;
    while (_spans.length > 1 && _spans.first.end < oldest) {
      _spans.removeFirst();
    }
  }

  /// Loudness at [playedFrame]. Silence before the stream starts; the last
  /// known level after its end.
  ///
  /// Holding past the end rather than returning 0 is deliberate: the poll and
  /// the arrival are independent, so playback legitimately runs a little past
  /// what has been indexed, and dropping to zero there would flicker the line.
  double levelAt(int playedFrame) {
    if (_spans.isEmpty || playedFrame < _spans.first.start) return 0.0;
    if (playedFrame >= _spans.last.end) return _spans.last.rms;
    for (final s in _spans) {
      if (playedFrame < s.end) return s.rms;
    }
    return _spans.last.rms;
  }

  /// Called from the same place that calls `stopAndFlush()`. AudioTrack resets
  /// its head position on flush, so this must reset with it or every lookup
  /// afterwards is off by the whole previous utterance.
  void reset() {
    _spans.clear();
    _written = 0;
  }
}

class _Span {
  const _Span(this.start, this.end, this.rms);
  final int start;
  final int end;
  final double rms;
}
