import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/connection/app_connection.dart';
import 'package:orbital_pai/phoenix/decoded_message.dart';
import 'package:orbital_pai/voice/voice_controller.dart';

import 'support/fakes.dart';

void main() {
  late AppConnection conn;
  setUp(() => conn =
      AppConnection(connector: () async => throw StateError('no socket')));
  tearDown(() => conn.dispose());

  Uint8List tone(int frames, double amplitude) {
    final b = ByteData(frames * 2);
    final v = (amplitude * 32767).round();
    for (var i = 0; i < frames; i++) {
      b.setInt16(i * 2, i.isEven ? v : -v, Endian.little);
    }
    return b.buffer.asUint8List();
  }

  test('the level follows the PLAYED frame, not the arrival order', () async {
    // The bug this replaces: audioTarget was set from whatever chunk had just
    // ARRIVED. TTS arrives far faster than it plays, so the orb reacted during
    // the couple of seconds of arrival and was inert for the rest of playback.
    final player = FakePlayer();
    final c = VoiceController(connection: conn, mic: FakeMic(), player: player);
    c.debugSetPlayerReady();
    c.debugSetTalking(true);
    c.debugApplyEvent('speaking');

    c.debugHandleAudio(tone(1000, 0.1)); // frames 0..999   quiet
    c.debugHandleAudio(tone(1000, 0.9)); // frames 1000..1999 loud

    player.playedFramesValue = 500;
    await c.debugPollPlaybackLevel();
    final early = c.orbFrame.debugAudioTarget;

    player.playedFramesValue = 1500;
    await c.debugPollPlaybackLevel();
    final late = c.orbFrame.debugAudioTarget;

    expect(early, greaterThan(0.0));
    expect(late, greaterThan(early),
        reason:
            'the level must track where playback IS, not what arrived last');
    c.dispose();
  });

  test('a flush resets the index with the player, through the real path',
      () async {
    // AudioTrack resets its head position on flush. If the index did not
    // reset with it, every lookup after a barge-in would be off by the whole
    // previous utterance. Driven through `stop_playback` (not
    // `debugResetPlaybackLevels`) so this exercises the production wiring,
    // not just Task 1's `PlaybackLevels.reset`; and the pre-reset assertion
    // is a NONZERO baseline, not the field's own initial value, so a poll
    // that silently became a no-op would still fail this test.
    final player = FakePlayer();
    final c = VoiceController(connection: conn, mic: FakeMic(), player: player);
    c.debugSetPlayerReady();
    c.debugSetTalking(true);
    c.debugApplyEvent('speaking');
    c.debugHandleAudio(tone(1000, 0.9));

    player.playedFramesValue = 500;
    await c.debugPollPlaybackLevel();
    expect(c.orbFrame.debugAudioTarget, greaterThan(0.0));

    c.debugHandleMessage(
        const DecodedMessage(topic: 'voice:henry', event: 'stop_playback'));

    // Same played-frame position as before the flush — only the index
    // resetting (not the position moving on) should be what zeroes this.
    player.playedFramesValue = 500;
    await c.debugPollPlaybackLevel();
    expect(c.orbFrame.debugAudioTarget, 0.0);
    c.dispose();
  });

  test('the level poll runs only while speaking, with a live player',
      () async {
    // Nothing else in the suite exercises _syncLevelPoll's own lifecycle —
    // exactly the kind of Timer this project has been bitten by before.
    final player = FakePlayer();
    final c = VoiceController(connection: conn, mic: FakeMic(), player: player);
    c.debugSetPlayerReady();

    // Not speaking yet: no timer running, so a played-frame change sits
    // unnoticed.
    player.playedFramesValue = 500;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(c.orbFrame.debugAudioTarget, 0.0);

    // Entering speaking starts the timer: the SAME played-frame value, never
    // polled manually, is picked up on its own within a couple of ticks.
    c.debugSetTalking(true);
    c.debugApplyEvent('speaking');
    c.debugHandleAudio(tone(2000, 0.9));
    await Future<void>.delayed(const Duration(milliseconds: 120));
    final whileSpeaking = c.orbFrame.debugAudioTarget;
    expect(whileSpeaking, greaterThan(0.0));

    // Leaving speaking does TWO things, and both matter.
    //
    // It zeroes the target: the poll is the only source of a non-zero
    // `audioTarget` and `OrbFrame._reactive` still includes `listening`, so a
    // target left behind
    // would park the smoother on Henry's last playback loudness for the whole
    // time the user is talking.
    //
    // And it stops the poll: a later played-frame position must no longer be
    // picked up at all, which is what the second delay proves — 1900 is a real
    // position inside the indexed audio, so a still-running poll would put a
    // NONZERO level back.
    c.debugApplyEvent('listening');
    expect(c.orbFrame.debugAudioTarget, 0.0,
        reason: 'leaving speaking must zero the target, not leave it stuck');
    player.playedFramesValue = 1900;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(c.orbFrame.debugAudioTarget, 0.0,
        reason: 'leaving speaking must stop the poll; nothing may write the '
            'target again');

    // No Timer may survive the test — flutter_test checks this itself, but
    // dispose() is exercised explicitly rather than left to tearDown.
    c.dispose();
  });

  testWidgets('the hold past the last chunk expires when the queue drains',
      (tester) async {
    // I3. `PlaybackLevels.levelAt` holds the last chunk's loudness past the end
    // of the index, which is right for the 50-200ms of poll/arrival skew it was
    // written for and wrong for a tool round: the queue empties for seconds and
    // the orb would sit at the last syllable's loudness, then jump when audio
    // resumes. The hold cannot expire itself — `playbackHeadPosition` settles
    // AT the written frame count rather than running past it, so no frame-delta
    // inside that pure, clockless class can ever grow. The poll times it out.
    //
    // `testWidgets`, so the 50ms periodic poll is driven by the fake clock:
    // one tick per pump, exactly, instead of racing wall-clock delays against
    // the count of polls this test is about.
    final player = FakePlayer();
    final c = VoiceController(connection: conn, mic: FakeMic(), player: player);
    c.debugSetPlayerReady();
    c.debugSetTalking(true);
    c.debugApplyEvent('speaking');
    c.debugHandleAudio(tone(1000, 0.9));

    Future<void> poll() => tester.pump(const Duration(milliseconds: 50));
    double target() => c.orbFrame.debugAudioTarget;

    // Mid-utterance: the head is inside the audio and moving. Nothing here may
    // ever be mistaken for a drain, however long the answer runs.
    for (var f = 100; f <= 900; f += 100) {
      player.playedFramesValue = f;
      await poll();
      expect(target(), greaterThan(0.0),
          reason: 'a normal utterance must never trip the drain timeout');
    }

    // The head reaches the end of everything written and stops there. For the
    // first few polls the hold is still correct — this is exactly the skew
    // window it was written for — so the level must NOT drop yet.
    player.playedFramesValue = 1000;
    await poll(); // first sighting at 1000: the frame still MOVED this tick
    for (var i = 0; i < 3; i++) {
      await poll();
      expect(target(), greaterThan(0.0),
          reason: 'the hold must survive the poll/arrival skew it exists for');
    }

    // Past ~250ms of a stalled head with nothing left unplayed, it is not skew:
    // the queue has drained and nothing is being heard.
    await poll();
    await poll();
    expect(target(), 0.0,
        reason: 'a drained queue must settle the orb, not hold the last '
            'syllable for the length of a tool round');

    // Audio resuming picks it straight back up — the timeout is not sticky.
    c.debugHandleAudio(tone(1000, 0.9));
    player.playedFramesValue = 1200;
    await poll();
    expect(target(), greaterThan(0.0));
    c.dispose();
  });

  testWidgets('a new answer does not flare on the last one\'s loudness',
      (tester) async {
    // H1, introduced by the C2 fix rather than pre-existing. `_levels` is NOT
    // reset at a normal turn boundary — only `_handleStopPlayback` resets it —
    // and `playbackHeadPosition` stays parked at the end of the last answer.
    // So the first poll of the NEXT answer looks up `levelAt(head)` and gets
    // the previous answer's last-syllable RMS. Before C2 the target was
    // already sitting at that value and the write was a no-op; now the level
    // correctly rests at 0 through `listening`, so the same write is a jump
    // from 0 to near-full — a halo flare and, since `_transient` is fed the
    // RAW target, a punch with it. Worst on the wake-ack path, where
    // `speak_start` arrives several hundred ms before any audio.
    final player = FakePlayer();
    final c = VoiceController(connection: conn, mic: FakeMic(), player: player);
    c.debugSetPlayerReady();
    c.debugSetTalking(true);

    Future<void> poll() => tester.pump(const Duration(milliseconds: 50));
    double target() => c.orbFrame.debugAudioTarget;

    // Turn one, played to the end and left to drain.
    c.debugApplyEvent('speaking');
    c.debugHandleAudio(tone(1000, 0.9));
    player.playedFramesValue = 1000;
    for (var i = 0; i < 6; i++) {
      await poll();
    }
    expect(target(), 0.0, reason: 'sanity: turn one drained');

    // Back to the user, then turn two begins. NO flush: this is an ordinary
    // turn boundary, so the index still holds turn one's spans and the head
    // is still parked at 1000.
    c.debugApplyEvent('listening');
    c.debugApplyEvent('speaking');
    await poll();
    expect(target(), 0.0,
        reason: 'the first poll of a new answer must not resurrect the '
            'previous answer\'s last-syllable loudness');

    // Four more polls with still no audio — the whole window in which the
    // reset version kept writing the stale value while its counter climbed.
    for (var i = 0; i < 4; i++) {
      await poll();
      expect(target(), 0.0);
    }

    // And the real audio of turn two lifts it, immediately: the new span
    // starts exactly at the parked head, so `levelAt(head)` is turn two's own
    // loudness, not turn one's.
    c.debugHandleAudio(tone(1000, 0.4));
    await poll();
    expect(target(), greaterThan(0.0));
    c.dispose();
  });

  testWidgets('a barge-in flush leaves nothing for the next poll to read',
      (tester) async {
    // The other half of H1's reasoning, asserted rather than assumed: the
    // drain counters now survive a turn boundary, so the flush path must not
    // depend on them. It does not — `_handleStopPlayback` resets `_levels`, so
    // `levelAt` has no span to return whatever the counters hold, and
    // AudioTrack's flush takes the head back to 0 in step with it.
    final player = FakePlayer();
    final c = VoiceController(connection: conn, mic: FakeMic(), player: player);
    c.debugSetPlayerReady();
    c.debugSetTalking(true);
    c.debugApplyEvent('speaking');
    c.debugHandleAudio(tone(1000, 0.9));

    player.playedFramesValue = 400; // mid-utterance: NOT drained, counters 0
    await tester.pump(const Duration(milliseconds: 50));
    expect(c.orbFrame.debugAudioTarget, greaterThan(0.0));

    c.debugHandleMessage(
        const DecodedMessage(topic: 'voice:henry', event: 'stop_playback'));
    player.playedFramesValue = 0; // AudioTrack.flush() resets the head
    await tester.pump(const Duration(milliseconds: 50));
    expect(c.orbFrame.debugAudioTarget, 0.0,
        reason: 'a barge-in must not leave the abandoned turn audible in the '
            'orb, counters or no counters');
    c.dispose();
  });

  test('a throwing player does not propagate, and logs once per run', () async {
    // The spec requires this and nothing covered it: `FakePlayer.playedFrames`
    // could not fail, so neither the `onError:` branch nor its once-per-run
    // logging was reachable. The poll runs at 20Hz off a periodic timer with
    // nothing awaiting it, so an unguarded throw is an unhandled async error
    // twenty times a second.
    //
    // Deliberately NOT in `speaking`: the periodic timer would then interleave
    // its own failing polls with these, and the count of log lines is the
    // assertion. `_pollPlaybackLevel` itself only requires a live player.
    final player = FakePlayer();
    final c = VoiceController(connection: conn, mic: FakeMic(), player: player);
    c.debugSetPlayerReady();
    c.debugHandleAudio(tone(1000, 0.9));

    player.playedFramesValue = 500;
    await c.debugPollPlaybackLevel();
    final before = c.orbFrame.debugAudioTarget;
    expect(before, greaterThan(0.0));

    player.throwPlayedFrames = true;
    await c.debugPollPlaybackLevel(); // must not throw
    expect(c.orbFrame.debugAudioTarget, before,
        reason: 'a failed poll leaves the level alone; it decays on its own');

    int failures() => c.eventLog
        .where((l) => l.startsWith('playback level poll failed'))
        .length;
    expect(failures(), 1);

    await c.debugPollPlaybackLevel();
    await c.debugPollPlaybackLevel();
    expect(failures(), 1,
        reason: 'one line per failure RUN — 20Hz of them would bury the log');

    // Recovering re-arms it, so a later, separate failure run is still visible.
    player.throwPlayedFrames = false;
    await c.debugPollPlaybackLevel();
    player.throwPlayedFrames = true;
    await c.debugPollPlaybackLevel();
    expect(failures(), 2);
    c.dispose();
  });

  testWidgets('dispose cancels the level timer', (tester) async {
    // `testWidgets`, not `test`: only this harness runs the pending-timer
    // check, and the ordering comment in dispose() (cancel BEFORE the player
    // goes away) is otherwise unguarded — the three tests above use plain
    // `test()` and would not notice a surviving 20Hz timer.
    final player = FakePlayer();
    final c = VoiceController(connection: conn, mic: FakeMic(), player: player);
    c.debugSetPlayerReady();
    c.debugSetTalking(true);
    c.debugApplyEvent('speaking');
    expect(c.debugLevelTimerActive, isTrue, reason: 'sanity: it is running');

    c.dispose();
    expect(c.debugLevelTimerActive, isFalse);
    await tester.pump(const Duration(milliseconds: 200));
  });
}
