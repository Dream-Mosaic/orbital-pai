import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/connection/app_connection.dart';
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

  test('a flush resets the index with the player', () async {
    // AudioTrack resets its head position on flush. If the index did not reset
    // with it, every lookup after a barge-in would be off by the whole previous
    // utterance.
    final player = FakePlayer();
    final c = VoiceController(connection: conn, mic: FakeMic(), player: player);
    c.debugSetTalking(true);
    c.debugApplyEvent('speaking');
    c.debugHandleAudio(tone(1000, 0.9));

    c.debugResetPlaybackLevels();
    player.playedFramesValue = 500;
    await c.debugPollPlaybackLevel();
    expect(c.orbFrame.debugAudioTarget, 0.0);
    c.dispose();
  });
}
