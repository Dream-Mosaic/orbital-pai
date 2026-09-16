import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import '../meridian/audio_levels.dart' show rmsFromPcm16;

/// The RESOLUTION OF THE LINE, in frames: the longest stretch of audio allowed
/// to share a single loudness value.
///
/// 960 frames is 40ms at the server's 24kHz `tts_sample_rate` — comfortably
/// finer than the ~100ms syllable scale the line is meant to show, and finer
/// than the 50ms level poll that reads it, so the poll is what limits the
/// line's response rather than the index.
///
/// This exists because the line's time resolution must NOT be the server's
/// chunking. The brain path streams from Cartesia in ~100ms pieces and
/// animated fine; the REFLEX comes from a batch `synthesize()` call and
/// arrives as one binary of whole seconds (`spawn_reflex_tts` ->
/// `push_audio_chunk`, which does not split). One RMS per arriving chunk made
/// that entire clip a single constant and the filler could not move the line
/// at all. Subdividing here is the client-side cure, and it holds whatever the
/// server does next.
const int kLevelSpanFrames = 960;

/// One loudness value per [kLevelSpanFrames] of audio, addressed by ABSOLUTE
/// frame.
///
/// Per SPAN, not per arriving chunk. It was per chunk until the reflex — a
/// batch `synthesize()` that reaches the client as one binary — turned out to
/// be a single span of whole seconds, which the line can only draw as a flat
/// constant. See [kLevelSpanFrames].
///
/// This is what replaced a 64KB PCM ring, a wall-clock cursor, a lead-sizing
/// resync, a dry detector and a fade. All of that existed to answer one
/// question — "which sample is being heard right now?" — which the platform
/// already knows: `AudioTrackPlayer.playedFrames()`. Given that number, the
/// only thing the orb needs is how loud the audio around it was, and one scalar
/// per 40ms carries that.
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
  /// front of the index.
  ///
  /// What it costs: a span is three numbers in an object, so call it ~48 bytes
  /// with its queue slot. At [kLevelSpanFrames] resolution five minutes is
  /// 300 / 0.04 = 7500 spans, i.e. roughly 350KB — several times the 64KB PCM
  /// ring this design replaced, and five times what the same window cost at
  /// one span per 100ms chunk. Accepted deliberately: it is a fixed ceiling on
  /// a phone, it is reached only by five unbroken minutes of speech, and the
  /// alternative is shortening a window whose whole job is to outrun an
  /// arrival lead that grows without bound. [levelAt]'s scan is linear over
  /// the same 7500 at 20Hz — ~150k comparisons a second, which is noise; if
  /// either number ever matters, the spans are sorted and contiguous and a
  /// binary search is the answer, not a smaller window.
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

  /// Test seam: the (start, end) frame range of every retained span, in order.
  /// Contiguity and non-overlap are invariants [levelAt]'s scan depends on,
  /// and they stopped being trivially true the moment one `add` began
  /// producing many spans.
  List<(int, int)> get debugSpanRanges =>
      [for (final s in _spans) (s.start, s.end)];

  /// Index one arriving chunk, at [kLevelSpanFrames] resolution.
  ///
  /// The chunk is subdivided; the TOTAL is not touched. `_written` advances by
  /// exactly `pcm16.lengthInBytes ~/ 2` however many spans that becomes,
  /// because the poll's drain condition is `playedFrame >= writtenFrames` and
  /// that argument rests on this being the true count handed to AudioTrack.
  /// Sub-spans change how a range is DIVIDED, never its extent: the spans
  /// written here tile `[start, _written)` exactly, contiguous and ascending,
  /// which is what [levelAt]'s scan and both of its edge branches assume.
  void add(Uint8List pcm16) {
    final frames = pcm16.lengthInBytes ~/ 2;
    if (frames == 0) return;
    final start = _written;
    _written += frames;
    for (var off = 0; off < frames; off += kLevelSpanFrames) {
      // The trailing partial keeps its TRUE length rather than being padded or
      // folded into its neighbour — RMS is a mean, so a short span scored over
      // frames it does not own would read the next chunk's loudness early.
      final end = math.min(off + kLevelSpanFrames, frames);
      // A view, not a copy: `rmsFromPcm16` reads it through ByteData.sublistView,
      // which honours the view's own offset, so subdividing a 5-second reflex
      // allocates nothing beyond the spans themselves.
      final sub = Uint8List.sublistView(pcm16, off * 2, end * 2);
      _spans.addLast(_Span(start + off, start + end, rmsFromPcm16(sub)));
    }
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
