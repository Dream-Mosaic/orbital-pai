import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/audio/playback_levels.dart';

/// PCM16 mono of [frames] samples at a constant magnitude.
Uint8List tone(int frames, double amplitude) {
  final b = ByteData(frames * 2);
  final v = (amplitude * 32767).round();
  for (var i = 0; i < frames; i++) {
    b.setInt16(i * 2, i.isEven ? v : -v, Endian.little);
  }
  return b.buffer.asUint8List();
}

/// PCM16 mono of [frames] samples that steps from [a] to [b] at the halfway
/// point — one chunk whose loudness genuinely varies across it.
Uint8List ramped(int frames, double a, double b) {
  final out = Uint8List(frames * 2);
  final half = frames ~/ 2;
  out.setAll(0, tone(half, a));
  out.setAll(half * 2, tone(frames - half, b));
  return out;
}

void main() {
  test('one long chunk is indexed at the LINE\'s resolution, not the server\'s',
      () {
    // S1, the reflex bug. `spawn_reflex_tts` is a BATCH synthesize() call, so
    // the whole filler arrives as ONE binary and `push_audio_chunk` sends it
    // unsplit. One RMS per add() made that entire clip a single span: the line
    // held one constant for its whole duration and could not move. The brain
    // path only animated because Cartesia happens to stream it in ~100ms
    // pieces — i.e. the line's time resolution was the server's chunking.
    final l = PlaybackLevels();
    l.add(ramped(kLevelSpanFrames * 4, 0.05, 0.25));

    expect(l.debugEntryCount, greaterThan(1),
        reason: 'a chunk longer than one sub-span must be subdivided');
    expect(l.levelAt(kLevelSpanFrames * 3), greaterThan(l.levelAt(0)),
        reason: 'the loud half of a single chunk must read louder than its '
            'quiet half — otherwise the reflex is a flat line');
  });

  test('sub-splitting does not change writtenFrames', () {
    // The drain condition in the poll is `playedFrame >= writtenFrames`, and
    // the argument that one reading settles it rests on this being the exact
    // total handed to AudioTrack. Sub-spans change how a range is DIVIDED,
    // never the total.
    final l = PlaybackLevels();
    l.add(tone(kLevelSpanFrames * 3 + 7, 0.5));
    expect(l.writtenFrames, kLevelSpanFrames * 3 + 7);
    l.add(tone(10, 0.5));
    expect(l.writtenFrames, kLevelSpanFrames * 3 + 17);
  });

  test('spans stay contiguous, non-overlapping and ascending', () {
    // levelAt's scan and both of its edge branches assume it.
    final l = PlaybackLevels();
    l.add(ramped(kLevelSpanFrames * 2 + 100, 0.05, 0.25)); // trailing partial
    l.add(tone(50, 0.4)); // shorter than one sub-span
    l.add(tone(kLevelSpanFrames, 0.6)); // exactly one

    final ranges = l.debugSpanRanges;
    expect(ranges.first.$1, 0);
    expect(ranges.last.$2, l.writtenFrames);
    for (var i = 0; i < ranges.length; i++) {
      expect(ranges[i].$2, greaterThan(ranges[i].$1), reason: 'empty span');
      if (i > 0) {
        expect(ranges[i].$1, ranges[i - 1].$2,
            reason: 'a gap or an overlap at span $i');
      }
    }
  });

  test('a chunk shorter than one sub-span stays a single span', () {
    final l = PlaybackLevels();
    l.add(tone(kLevelSpanFrames - 1, 0.5));
    expect(l.debugEntryCount, 1);
    expect(l.debugSpanRanges.single, (0, kLevelSpanFrames - 1));
  });

  test('an empty index reads as silence, not as garbage', () {
    expect(PlaybackLevels().levelAt(0), 0.0);
    expect(PlaybackLevels().levelAt(99999), 0.0);
  });

  test('a played frame reads the level of the chunk containing it', () {
    final l = PlaybackLevels();
    l.add(tone(100, 0.2)); // frames 0..99
    l.add(tone(100, 0.8)); // frames 100..199

    final quiet = l.levelAt(50);
    final loud = l.levelAt(150);
    expect(loud, greaterThan(quiet));
    expect(quiet, greaterThan(0.0));
  });

  test('frames are counted in SAMPLES, not bytes', () {
    // PCM16 is two bytes per frame. Counting bytes would put every boundary at
    // twice its true frame, so a lookup would read the wrong chunk for the
    // whole back half of the stream.
    final l = PlaybackLevels();
    l.add(tone(100, 0.2));
    expect(l.writtenFrames, 100);
  });

  test('a frame past the last chunk holds the last level', () {
    // Playback can legitimately run a little past what has been indexed — the
    // poll and the arrival are independent. Holding is right; returning 0 would
    // make the line drop out for a frame and flicker.
    final l = PlaybackLevels();
    l.add(tone(100, 0.8));
    expect(l.levelAt(500), closeTo(l.levelAt(50), 1e-9));
  });

  test('a frame before the first chunk is silence', () {
    final l = PlaybackLevels()..add(tone(100, 0.8));
    expect(l.levelAt(-10), 0.0);
  });

  test('reset clears everything, so the next stream starts at frame zero', () {
    // Called from the same handler that calls stopAndFlush(). AudioTrack's head
    // position resets on flush, so if this did not, every lookup afterwards
    // would be off by the whole previous utterance.
    final l = PlaybackLevels();
    l.add(tone(100, 0.8));
    l.reset();
    expect(l.writtenFrames, 0);
    expect(l.levelAt(50), 0.0);
  });

  test('the retained window is five minutes by default', () {
    // Every other test here passes its own `retainFrames`, so a revert of the
    // DEFAULT alone would go unnoticed — and the default is the whole of C1's
    // second half. Thirty seconds was overtaken ~15s into a k=3 answer.
    expect(PlaybackLevels().retainFrames, 24000 * 300);
  });

  test('eviction does not outrun the playback head on a long answer', () {
    // C1. Eviction is measured back from ARRIVAL; lookups come from the
    // PLAYBACK HEAD, which trails it by however much faster than realtime the
    // synthesis runs. Once that lead exceeds the retained window the played
    // frame falls off the front of the index — and returning 0.0 there dropped
    // the line to its rest floor and darkened the halos for the entire rest of
    // the utterance, mid-sentence, which is the exact symptom this file exists
    // to prevent.
    final l = PlaybackLevels(retainFrames: 24000 * 10); // 10s retained
    for (var i = 0; i < 600; i++) {
      l.add(tone(2400, 0.8)); // 100ms chunks, 60s of audio arrived
    }
    // 5s in: long evicted, but unambiguously still being heard.
    expect(l.levelAt(24000 * 5), greaterThan(0.0),
        reason: 'an evicted-but-playing frame must read the oldest level we '
            'still have, never silence');
    // And the genuine before-the-stream case is still silence.
    final fresh = PlaybackLevels()..add(tone(100, 0.8));
    expect(fresh.levelAt(-1), 0.0);
  });

  test('old entries are evicted, so a long session cannot grow without bound',
      () {
    final l = PlaybackLevels(retainFrames: 1000);
    for (var i = 0; i < 100; i++) {
      l.add(tone(100, 0.5)); // 10_000 frames total
    }
    expect(l.writtenFrames, 10000);
    // The recent past still resolves...
    expect(l.levelAt(9950), greaterThan(0.0));
    // ...and the distant past has been dropped rather than retained forever.
    expect(l.debugEntryCount, lessThan(20));
  });

  test('a span is finer than the poll that reads it', () {
    // The two resolutions are chosen against each other: spans are 40ms
    // BECAUSE the playback poll runs every 50ms (VoiceController's
    // _levelPollPeriod). If a span ever grew past a poll period, the poll —
    // not the index — would become what limits the line, and S1's whole point
    // was to stop the line's resolution being decided somewhere else.
    // Retuning either constant alone should trip this.
    const pollPeriodFrames = 24000 * 50 ~/ 1000;
    expect(kLevelSpanFrames, lessThanOrEqualTo(pollPeriodFrames),
        reason: 'a span longer than one poll period makes the poll the limit');
  });
}
