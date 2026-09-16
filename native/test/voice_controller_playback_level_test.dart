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

    // Leaving speaking stops the timer: a later played-frame position is no
    // longer picked up, so the target holds rather than following it.
    c.debugApplyEvent('listening');
    player.playedFramesValue = 1900;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(c.orbFrame.debugAudioTarget, whileSpeaking,
        reason: 'leaving speaking must stop the poll, not just decay it');

    // No Timer may survive the test — flutter_test checks this itself, but
    // dispose() is exercised explicitly rather than left to tearDown.
    c.dispose();
  });
}
