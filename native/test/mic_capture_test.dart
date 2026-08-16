import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/audio/mic_capture.dart';

import 'support/fakes.dart';

/// MicCapture's session rules, straight — no VoiceController in the way.
///
/// These exist because the rules ARE the fix: five Criticals of one class
/// came from `MicCapture` wrapping a single AudioRecorder behind a single
/// `bool _recording` with no session identity, so a caller that had given up
/// could not tell its own session from a newer one and its stop() killed
/// whichever happened to be live.
void main() {
  test("a stale session's stop() cannot close the session that replaced it",
      () async {
    final rec = FakeRecorder();
    final mic = MicCapture(recorder: rec);

    final first = mic.start();
    await first.stream;
    await first.stop();
    final second = mic.start();
    await second.stream;
    expect(mic.isRecording, isTrue, reason: 'sanity: the second session is up');

    // The stale caller's late continuation, doing exactly what suspendMic's
    // superseded branch does.
    await first.stop();

    expect(mic.isRecording, isTrue,
        reason: 'stopping a session that no longer owns the recorder must be '
            'a no-op, not the end of the live one');
    expect(second.isActive, isTrue);
    expect(first.isActive, isFalse);
  });

  test('a session stopped while its open is still in flight never starts '
      'recording', () async {
    // The window the whole design turns on: `_recording` was set only AFTER
    // startStream resolved, so a stop landing here found "nothing to stop",
    // no-opped, and left a session running that nobody owned.
    final rec = FakeRecorder(startDelay: const Duration(milliseconds: 40));
    final mic = MicCapture(recorder: rec);

    final session = mic.start();
    Object? error;
    final settled =
        session.stream.then<void>((_) {}, onError: (Object e) => error = e);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(mic.isRecording, isFalse, reason: 'sanity: still opening');

    await session.stop();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    await settled;

    expect(mic.isRecording, isFalse,
        reason: 'a session stopped before the platform answered must not come '
            'up behind its owner’s back');
    expect(error, isA<StateError>(),
        reason: 'and it must not hand back a stream nobody will listen to');
    expect(rec.stopCalls, 1,
        reason: 'the orphan the platform opened anyway must be closed');
    expect(session.isActive, isFalse);
  });

  test('a start issued while another is still opening waits instead of '
      'overlapping it', () async {
    // Two concurrent startStream() calls on one AudioRecorder is undefined
    // behaviour on the plugin side: it either throws or tears the first
    // stream down. Both lose the microphone.
    final rec = FakeRecorder(startDelays: const [
      Duration(milliseconds: 40),
      Duration.zero,
    ]);
    final mic = MicCapture(recorder: rec);

    final wedged = mic.start();
    Object? error;
    final settled =
        wedged.stream.then<void>((_) {}, onError: (Object e) => error = e);
    // Let the first one get INSIDE startStream before the second claims.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(rec.startCalls, 1, reason: 'sanity: the first start is in flight');

    final live = mic.start();
    await live.stream;
    await settled;

    expect(rec.maxConcurrentStarts, 1,
        reason: 'the second start must wait for the first to settle');
    expect(error, isA<StateError>());
    expect(mic.isRecording, isTrue,
        reason: 'and the session that won must actually be running');
    expect(live.isActive, isTrue);
  });

  test('a refused permission leaves no claim on the recorder', () async {
    final rec = FakeRecorder(permitted: false);
    final mic = MicCapture(recorder: rec);

    final refused = mic.start();
    await expectLater(refused.stream, throwsA(isA<StateError>()));

    expect(refused.isActive, isFalse,
        reason: 'a session that never opened owns nothing — otherwise it '
            'blocks the next one from ever claiming the recorder');
    expect(mic.isRecording, isFalse);
    expect(rec.startCalls, 0);

    // And the next attempt is unaffected.
    final rec2 = FakeRecorder();
    final mic2 = MicCapture(recorder: rec2);
    await mic2.start().stream;
    expect(mic2.isRecording, isTrue);
  });
}
