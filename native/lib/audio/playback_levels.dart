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
  PlaybackLevels({this.retainFrames = 24000 * 300});

  /// How much history to keep. Only the recent past is ever looked up (playback
  /// trails arrival, it never precedes it), so anything older is dead weight —
  /// and a session that never evicted would grow for as long as the app runs.
  ///
  /// FIVE MINUTES, not thirty seconds. Eviction is measured backwards from
  /// `_written`, which advances on ARRIVAL, while lookups come from the
  /// PLAYBACK HEAD — and nothing paces arrival: the server pushes each chunk
  /// the moment Cartesia emits it and the Kotlin queue is unbounded. If
  /// synthesis runs at k x realtime, the arrival lead after `t` seconds of
  /// playback is `(k-1)*t` and grows monotonically, so a 30s window was
  /// overtaken ~15s into a k=3 answer and every later lookup fell off the
  /// front of the index. A span is three numbers; five minutes of 100ms chunks
  /// is well under 100KB, against the 64KB PCM ring this design replaced.
  ///
  /// FRAMES, and the default is written `24000 * 300` because 24000 is the
  /// server's `tts_sample_rate` (`server/lib/app/config.ex`), the same number
  /// `VoiceController._initPlayer` hands to `AudioTrack`. Nothing here can
  /// detect a change to it: a server that moved to 48kHz would leave this
  /// window meaning two and a half minutes rather than five, quietly, while
  /// the symptom showed up as the orb going flat late in long answers.
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
  ///
  /// Holding BEFORE the oldest retained span is deliberate for the same
  /// reason, and is NOT the same case as "before the stream". A frame under
  /// `_spans.first.start` when that start is 0 is genuinely ahead of the
  /// audio — silence. When the start is not 0 the span that held that frame
  /// was evicted, and the audio is very much still playing: returning 0 there
  /// is how a long answer used to go dark for its whole remainder.
  double levelAt(int playedFrame) {
    if (_spans.isEmpty) return 0.0;
    if (playedFrame < _spans.first.start) {
      return _spans.first.start == 0 ? 0.0 : _spans.first.rms;
    }
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
