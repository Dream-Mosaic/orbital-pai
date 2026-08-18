import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/audio/mic_capture.dart';

import 'support/fakes.dart';

/// Collect the errors a test EXPECTS MicCapture to report, instead of letting
/// `FlutterError.onError` fail the test with them. A platform stop that fails
/// is reported on purpose (silence is the bug this subsystem keeps producing),
/// so a test that drives one has to take delivery of the report.
List<FlutterErrorDetails> captureFlutterErrors() {
  final reports = <FlutterErrorDetails>[];
  final original = FlutterError.onError;
  FlutterError.onError = reports.add;
  addTearDown(() => FlutterError.onError = original);
  return reports;
}

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

  test("a stop for one session must not drop ANOTHER session's in-flight open "
      'from the chain', () async {
    // THE MIRROR of the test above, and the seventh Critical. There, the
    // session being stopped is the one whose open is wedged. Here it is a
    // DIFFERENT one — the shape `_stopSession` gets during an abandoned loan:
    // the conversation's own open is still inside `startStream` when the
    // borrowed session is stopped.
    //
    // A short-circuit that only fires for the stopping session's OWN open
    // falls through here, stops the hardware, and REPLACES `_ops` — dropping
    // the wedged open out of the serialisation chain. The next start then
    // issues `startStream` on top of it (maxConcurrentStarts == 2), and when
    // the stale open finally resolves it finds itself unowned and closes the
    // recorder the new session is using: `isActive == true` over an idle
    // recorder, which is the signature of Criticals 5 and 6.
    final rec = FakeRecorder(startDelays: const [
      Duration(milliseconds: 80), // session 1 — wedged inside startStream
      Duration.zero,
      Duration.zero,
    ]);
    final mic = MicCapture(recorder: rec);

    final wedged = mic.start();
    Object? wedgedError;
    final settledWedged =
        wedged.stream.then<void>((_) {}, onError: (Object e) => wedgedError = e);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(rec.startCalls, 1,
        reason: 'sanity: session 1 is inside startStream, not merely queued');

    // A second session claims the recorder (queued behind the wedged open)
    // and is then given up — the borrower's acquireTimeout, one layer down.
    final abandoned = mic.start();
    Object? abandonedError;
    final settledAbandoned = abandoned.stream
        .then<void>((_) {}, onError: (Object e) => abandonedError = e);
    await abandoned.stop();

    // ...and a third opens in its place while session 1 is STILL in flight.
    final restored = mic.start();
    await restored.stream.timeout(const Duration(seconds: 2));
    await settledAbandoned;
    // Let the wedged open land afterwards and do whatever it is going to do.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await settledWedged;
    await settle();

    expect(rec.maxConcurrentStarts, 1,
        reason: 'two concurrent startStream() calls on one AudioRecorder is '
            'undefined behaviour: stopping session 2 must not drop session '
            "1's open out of the queue");
    expect(wedgedError, isA<StateError>());
    expect(abandonedError, isA<StateError>());
    expect(restored.isActive, isTrue);
    expect(mic.isRecording, isTrue,
        reason: 'the session that won must actually be running — a stale '
            "open's orphan-close may not stop the recorder the restore "
            'opened');
    expect(rec.platformStreaming, isTrue,
        reason: 'and the HARDWARE must agree: `isActive` over an idle '
            'recorder is the assistant going deaf with the indicator lit');
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

  // ---- the platform REFUSING to stop (Critical 2 of the session-fix review) ----
  //
  // `_running = false` used to be written before `await _recorder.stop()`, and
  // the stop RETHREW. A platform that refuses while the hardware keeps
  // streaming therefore left MicCapture recording "idle" over a live recorder,
  // and the next open skipped its defensive stop and issued `startStream` on
  // top of it — measured `overlapSeen = true`. The rethrow separately aborted
  // `VoiceController.stopMic()` half-way through. Both are Invariant A: the
  // flag was written on the far side of a platform call and was simply not
  // true when the call failed.

  test('a stop the platform refuses is reported, never thrown, and leaves the '
      'hardware recorded as possibly-still-streaming', () async {
    final reports = captureFlutterErrors();
    final rec = FakeRecorder(stopBehaviour: const [FakeCall.throws]);
    final mic = MicCapture(recorder: rec);

    final session = mic.start();
    await session.stream;
    expect(rec.platformStreaming, isTrue, reason: 'sanity: the fake is live');

    // Must NOT throw: teardown is the one thing that always has to finish.
    // A rethrow here aborted stopMic() before it could put the state right.
    await session.stop();

    expect(mic.hardware, MicHardware.unknown,
        reason: 'we asked and were not told; recording that as idle is what '
            'let the next start run on a live recorder');
    expect(mic.isRecording, isFalse);
    expect(rec.platformStreaming, isTrue,
        reason: 'sanity: the hardware really did keep streaming');
    expect(reports, hasLength(1),
        reason: 'a swallowed platform failure is how this class of bug stays '
            'invisible');
  });

  test('after a refused stop the next start re-stops the recorder instead of '
      'opening on top of it', () async {
    captureFlutterErrors();
    // The first stop fails; the defensive stop inside the next open succeeds.
    final rec = FakeRecorder(stopBehaviour: const [FakeCall.throws]);
    final mic = MicCapture(recorder: rec);

    final first = mic.start();
    await first.stream;
    await first.stop();

    final second = mic.start();
    await second.stream;

    expect(rec.startedOnLiveRecorder, isFalse,
        reason: 'two overlapping sessions on one AudioRecorder is the '
            'undefined behaviour this whole class exists to prevent');
    expect(rec.stopCalls, 2,
        reason: 'the second open must retry the stop it was never told '
            'succeeded');
    expect(mic.isRecording, isTrue);
  });

  test('a recorder that will not stop at all refuses to start rather than '
      'streaming twice', () async {
    captureFlutterErrors();
    final rec =
        FakeRecorder(stopBehaviour: const [FakeCall.throws, FakeCall.throws]);
    final mic = MicCapture(recorder: rec);

    final first = mic.start();
    await first.stream;
    await first.stop();

    final second = mic.start();
    await expectLater(second.stream, throwsA(isA<StateError>()));

    expect(rec.startCalls, 1,
        reason: 'no second startStream may be issued while the first session '
            'may still be live');
    expect(rec.startedOnLiveRecorder, isFalse);
    expect(second.isActive, isFalse,
        reason: 'a session that refused to open must not hold the claim');
  });

  test('a stop that never answers is bounded, and the session gives up its '
      'claim anyway', () async {
    captureFlutterErrors();
    final rec = FakeRecorder(stopBehaviour: const [FakeCall.hangs]);
    final mic = MicCapture(
      recorder: rec,
      platformTimeout: const Duration(milliseconds: 40),
    );

    final session = mic.start();
    await session.stream;

    // Invariant B: unbounded is worse than throwing, because there is nothing
    // to catch. This must complete on its own.
    await session.stop().timeout(const Duration(seconds: 2));

    expect(session.isActive, isFalse,
        reason: 'the claim is dropped synchronously, before the platform call '
            '— a wedged stop may not keep the recorder claimed forever');
    expect(mic.hardware, MicHardware.unknown);
  });
}
