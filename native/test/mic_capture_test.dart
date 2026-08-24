import 'dart:async';

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

  // ---- the STOP side of the same chain (the eighth Critical) ----
  //
  // The two tests above wedge a `startStream` and prove no second one is
  // issued. Both of the tests below wedge a `stop`, which for eight rounds
  // nothing did. A guard that watched only `startStream` fell through in both
  // of these windows, issued a SECOND concurrent `stop()`, and replaced the
  // queue — dropping the still-running open out of it. Measured, before the
  // fix: `maxConcurrentStops == 2`, `stopOverlappedStart == true`, and the
  // wedged stop landing on the session the next start had already opened.

  test('a stop must not race the platform stop another open is already inside',
      () async {
    // Window one: the DEFENSIVE stop at the head of an open that supersedes a
    // live session. No `startStream` is in flight, so a `startStream`-shaped
    // guard sees nothing to wait for.
    final rec = FakeRecorder(stopDelays: const [
      Duration(milliseconds: 120), // the defensive stop — wedged
      Duration.zero,
    ]);
    final mic = MicCapture(recorder: rec);

    final first = mic.start();
    await first.stream;
    final second = mic.start();
    final settledSecond =
        second.stream.then<void>((_) {}, onError: (Object _) {});
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(rec.stopCalls, 1,
        reason: "sanity: session 2's open is inside the defensive stop, and "
            'no startStream is in flight');

    // The borrower gives up on session 2 — the shape `resumeMic()` produces.
    await second.stop();
    // ...and a third session opens in its place.
    final third = mic.start();
    await third.stream.timeout(const Duration(seconds: 2));
    // Let the wedged defensive stop land afterwards and do its worst.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await settledSecond;
    await settle();

    expect(rec.maxConcurrentStops, 1,
        reason: 'two concurrent stop() calls on one AudioRecorder is the same '
            'undefined behaviour as two concurrent starts, from the other '
            'side');
    expect(rec.stopOverlappedStart, isFalse,
        reason: 'and so is a stop overlapping a start, in either order');
    expect(rec.maxConcurrentStarts, 1);
    expect(third.isActive, isTrue);
    expect(rec.platformStreaming, isTrue,
        reason: 'the wedged stop belongs to a session that is long gone; when '
            'it lands it must not be the thing that closes the recorder the '
            'restore is using');
  });

  test('a stop must not race the orphan close of a superseded open', () async {
    // THE MIRROR of the test above: same defect, the other window. Here the
    // in-flight platform stop is the ORPHAN close of an open that finished
    // `startStream` only to find itself superseded — again with no
    // `startStream` in flight for a guard to see.
    final rec = FakeRecorder(
      startDelays: const [Duration(milliseconds: 40), Duration.zero],
      stopDelays: const [
        Duration(milliseconds: 120), // the orphan close — wedged
        Duration.zero,
      ],
    );
    final mic = MicCapture(recorder: rec);

    final wedged = mic.start();
    final settledWedged =
        wedged.stream.then<void>((_) {}, onError: (Object _) {});
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(rec.startCalls, 1,
        reason: 'sanity: session 1 is inside startStream');

    final second = mic.start();
    final settledSecond =
        second.stream.then<void>((_) {}, onError: (Object _) {});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(rec.stopCalls, 1,
        reason: "sanity: session 1's open is now inside its orphan close");

    await second.stop();
    final third = mic.start();
    await third.stream.timeout(const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await settledWedged;
    await settledSecond;
    await settle();

    expect(rec.maxConcurrentStops, 1);
    expect(rec.stopOverlappedStart, isFalse);
    expect(rec.maxConcurrentStarts, 1);
    expect(third.isActive, isTrue);
    expect(rec.platformStreaming, isTrue,
        reason: 'a stale open closing its own orphan may not close the '
            'session that replaced it');
  });

  test('a superseded open closes its own orphan even when its superseder '
      'never reaches the queue', () async {
    // The price of asking `hasPermission` outside the queue, and the reason a
    // superseded open may NOT simply leave its orphan for whoever comes next.
    // Here session 2 takes the claim and is then refused permission, so it
    // throws without ever queueing anything. Nobody is coming. If session 1
    // does not close the session the platform handed it after it lost the
    // claim, the recorder streams for the life of the process with no
    // subscriber, no error and no indicator.
    final rec = FakeRecorder(
      startDelays: const [Duration(milliseconds: 40)],
      permissionBehaviours: const [FakeCall.ok, FakeCall.throws],
    );
    final mic = MicCapture(recorder: rec);

    final wedged = mic.start();
    Object? wedgedError;
    final settledWedged = wedged.stream
        .then<void>((_) {}, onError: (Object e) => wedgedError = e);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(rec.startCalls, 1,
        reason: 'sanity: session 1 is inside startStream');

    // Deliberately NOT given an error handler: a claim that dies before the
    // platform is even asked must not become an unhandled async error for a
    // caller that only ever wanted the handle.
    mic.start();
    await settle();
    expect(rec.permissionCalls, 2, reason: 'sanity: session 2 asked and lost');

    await Future<void>.delayed(const Duration(milliseconds: 80));
    await settledWedged;
    await settle();

    expect(wedgedError, isA<StateError>());
    expect(rec.stopCalls, 1,
        reason: 'the orphan the platform opened anyway must be closed by the '
            'open that lost the claim — nothing else is queued to do it');
    expect(rec.platformStreaming, isFalse,
        reason: 'a recorder left streaming with no subscriber is the '
            'assistant recording forever, silently');
    expect(mic.isRecording, isFalse);
  });

  // ---- an open that lost the claim before it reached the queue ----
  //
  // THE NINTH Critical, and the pair of guards that close it. `hasPermission`
  // is asked OUTSIDE the queue, so an open joins the queue only when its
  // permission check answers: JOIN ORDER IS PERMISSION-COMPLETION ORDER, NOT
  // START ORDER. Between joining and calling `startStream` an open therefore
  // has to establish twice that it is still wanted — once when it reaches the
  // head of the queue, and again after its own defensive stop, because that
  // stop is an await like any other. The two tests below are those two
  // windows. Before them, NEITHER guard was pinned by anything in this suite:
  // deleting either left all 448 tests green.

  test('an open superseded inside the permission dialog must not tear down '
      'the session that replaced it', () async {
    // Window one. Session 1's dialog is slow and session 2's is instant, so
    // session 2 queues FIRST and opens the recorder. Session 1 then arrives at
    // the head of the queue holding a claim it has already lost, with the
    // recorder LIVE. If its first act is to reconcile the hardware to idle
    // rather than to ask whether it is still wanted, "reconcile" is the
    // teardown of the session that replaced it — deaf after enrolling, with
    // no error and no indicator.
    final rec = FakeRecorder(permissionDelays: const [
      Duration(milliseconds: 60), // session 1 — still inside the dialog
      Duration.zero, //              session 2 — answers at once
    ]);
    final mic = MicCapture(recorder: rec);

    final superseded = mic.start();
    Object? supersededError;
    final settled = superseded.stream
        .then<void>((_) {}, onError: (Object e) => supersededError = e);

    final live = mic.start();
    await live.stream.timeout(const Duration(seconds: 2));
    expect(rec.permissionCalls, 2,
        reason: 'sanity: session 1 is still inside the dialog, holding a '
            'claim it has already lost');
    expect(rec.platformStreaming, isTrue, reason: 'sanity: session 2 is up');

    // Let session 1's dialog answer and its open reach the head of the queue.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await settled;
    await settle();

    expect(supersededError, isA<StateError>(),
        reason: 'the superseded open must give up');
    expect(rec.stopCalls, 0,
        reason: 'and give up WITHOUT touching the platform — it holds no '
            'claim, so it owns no hardware to reconcile, and the hardware it '
            "would find is somebody else's");
    expect(rec.platformStreaming, isTrue,
        reason: 'the recorder its superseder opened must still be streaming: '
            'a stale open tearing down a live one is the signature this whole '
            'class exists to prevent');
    expect(mic.isRecording, isTrue);
    expect(live.isActive, isTrue,
        reason: '`isActive` over an idle recorder is the assistant going deaf '
            'with the indicator lit');
  });

  test('an open superseded during its own defensive stop must not open the '
      'recorder anyway', () async {
    // THE MIRROR, and the second window: this open IS still wanted when it
    // reaches the head of the queue, and loses the claim while it is inside
    // the defensive stop it correctly issued. Its own reconcile is an await
    // like every other, so ownership established above it has expired by the
    // time `startStream` is reached — and a `startStream` issued for a session
    // nobody is waiting on is an orphan handed to nobody.
    final rec = FakeRecorder(stopDelays: const [
      Duration(milliseconds: 60), // session 2's defensive stop — slow
      Duration.zero,
    ]);
    final mic = MicCapture(recorder: rec);

    final first = mic.start();
    await first.stream;

    final superseded = mic.start();
    Object? supersededError;
    final settled = superseded.stream
        .then<void>((_) {}, onError: (Object e) => supersededError = e);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(rec.stopCalls, 1,
        reason: 'sanity: session 2 is inside its own defensive stop, and it '
            'still owns the claim');

    // A third session claims the recorder while session 2 is mid-reconcile.
    final live = mic.start();
    await live.stream.timeout(const Duration(seconds: 2));
    await settled;
    await settle();

    expect(supersededError, isA<StateError>());
    expect(rec.startCalls, 2,
        reason: 'sessions 1 and 3 opened; session 2 lost the claim while its '
            'defensive stop was in flight and must not issue a startStream '
            'for a session nobody is waiting on');
    expect(rec.platformStreaming, isTrue);
    expect(live.isActive, isTrue);
    expect(mic.isRecording, isTrue);
  });

  // ---- what the queue may and may not make a teardown wait for ----

  test('a teardown does not park behind an open wedged in the permission '
      'dialog', () async {
    // Why `hasPermission` is asked OUTSIDE the queue. It is the one platform
    // call with a HUMAN-scale bound — it can put a system dialog in front of
    // the user — and it does not change what the recorder is doing. A
    // teardown queued behind it would inherit that bound, and a teardown
    // that takes a minute is the assistant going deaf for a minute.
    final rec = FakeRecorder(
      permissionBehaviours: const [FakeCall.ok, FakeCall.hangs],
    );
    final mic = MicCapture(
      recorder: rec,
      permissionTimeout: const Duration(seconds: 3),
    );

    final live = mic.start();
    await live.stream;
    expect(rec.platformStreaming, isTrue, reason: 'sanity: the recorder is up');

    // A second session claims the recorder and wedges inside the dialog.
    final wedged = mic.start();
    wedged.stream.ignore();
    await settle();
    expect(rec.permissionCalls, 2,
        reason: 'sanity: session 2 is inside the dialog, holding the claim');

    await wedged.stop().timeout(const Duration(milliseconds: 300));

    expect(rec.platformStreaming, isFalse,
        reason: 'and it must really have stopped the hardware, not merely '
            'returned quickly');
  });

  test('a teardown DOES wait for a startStream already in flight', () async {
    // The mirror, and the half that must still wait. A permission check does
    // not change what the recorder is doing; an open does. `stop()`
    // overlapping `startStream()` on one AudioRecorder is undefined
    // behaviour whichever of the two started first — this is the direction
    // the deleted `_startInFlight` guard used to cover on its own.
    final rec = FakeRecorder(startDelays: const [Duration(milliseconds: 60)]);
    final mic = MicCapture(recorder: rec);

    final session = mic.start();
    Object? error;
    final settled =
        session.stream.then<void>((_) {}, onError: (Object e) => error = e);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(rec.startCalls, 1, reason: 'sanity: inside startStream');

    await session.stop();
    await settled;
    await settle();

    expect(rec.stopOverlappedStart, isFalse,
        reason: 'the teardown may not reach the platform until the open it '
            'would overlap has landed');
    expect(rec.maxConcurrentStops, 1);
    expect(error, isA<StateError>());
    expect(rec.platformStreaming, isFalse,
        reason: 'and the orphan the platform opened anyway is closed');
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

  // ---- and the ACQUIRE side of the same bound ----
  //
  // The release bound above was pinned four times over; neither acquire bound
  // was pinned at all, and mutation testing confirmed it: deleting
  // `.timeout()` from `stop()` killed four tests, deleting it from
  // `startStream()` or from `hasPermission()` killed none. `FakeRecorder` has
  // implemented both failure axes the whole time and no test used either.
  //
  // What they protect: `_open` holds `_ops`, so an unbounded wedge in an
  // acquire never settles the chain and `await previous` blocks EVERY
  // subsequent start for the life of the process. MicCapture is bricked and
  // the microphone never returns by any path — no error, no indicator, not
  // even a power tap.

  test('a startStream that never answers is bounded, and the recorder stays '
      'usable', () async {
    captureFlutterErrors();
    final rec = FakeRecorder(startBehaviour: const [FakeCall.hangs]);
    final mic = MicCapture(
      recorder: rec,
      platformTimeout: const Duration(milliseconds: 40),
    );

    final wedged = mic.start();
    await expectLater(wedged.stream, throwsA(isA<TimeoutException>()));
    expect(wedged.isActive, isFalse);

    // THE point: an unbounded wedge never settles `_ops`, so every later start
    // queues behind it forever and MicCapture is bricked for the life of the
    // process.
    final next = mic.start();
    await next.stream.timeout(const Duration(seconds: 2));
    expect(mic.isRecording, isTrue);
  }, timeout: const Timeout(Duration(seconds: 8)));

  test('a hasPermission that never answers is bounded', () async {
    captureFlutterErrors();
    final rec = FakeRecorder(permissionBehaviour: FakeCall.hangs);
    final mic = MicCapture(
      recorder: rec,
      permissionTimeout: const Duration(milliseconds: 40),
    );
    await expectLater(mic.start().stream, throwsA(isA<TimeoutException>()));
    // The chain SETTLED: a later start reaches its own verdict rather than
    // queueing behind the first one forever.
    await expectLater(mic.start().stream, throwsA(isA<TimeoutException>()));
  }, timeout: const Timeout(Duration(seconds: 8)));

  // ---- the residual limit: a bound ABANDONS, it does not CANCEL ----
  //
  // Everything above proves what the queue guarantees for platform calls that
  // finish inside [MicCapture.defaultPlatformTimeout]. These two are what
  // happens when one does not, and they are the honest limit of this design:
  // `.timeout()` stops WAITING for a platform call, it cannot stop the call.
  // The slot is released, the next operation reaches the same recorder, and
  // for a while two calls really are inside one AudioRecorder at once.
  //
  // Dart cannot close this — see the class documentation on [MicCapture]. What
  // it CAN do is not lie about it afterwards. Both tests below assert only
  // that: when a call we stopped believing in finally lands, MicCapture stops
  // claiming to know what the hardware is doing. Neither asserts that the race
  // did not happen, because it did.

  test('an abandoned stop that finally lands must not leave the hardware '
      'recorded as streaming', () async {
    captureFlutterErrors();
    // A stop that merely OVERRUNS its bound — not a wedge. This is the
    // ordinary shape of a busy audio subsystem, and it needs no enrollment:
    // end to end it is a power OFF then ON.
    final rec = FakeRecorder(stopDelays: const [
      Duration(milliseconds: 300), // abandoned at 60ms, lands at 300ms
      Duration.zero,
    ]);
    final mic = MicCapture(
      recorder: rec,
      platformTimeout: const Duration(milliseconds: 60),
    );

    final first = mic.start();
    await first.stream;
    await first.stop();

    final second = mic.start();
    await second.stream.timeout(const Duration(seconds: 2));
    expect(mic.isRecording, isTrue, reason: 'sanity: session 2 really is up');
    expect(rec.platformStreaming, isTrue);
    expect(rec.maxConcurrentStops, 2,
        reason: 'THE LIMIT ITSELF, recorded rather than asserted away: the '
            'abandoned stop is still inside the recorder while the next one '
            'is issued');
    expect(rec.stopOverlappedStart, isTrue);

    // The abandoned stop lands and closes the recorder session 2 is using.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await settle();

    expect(rec.platformStreaming, isFalse,
        reason: 'sanity: the late stop really did take the hardware down '
            'under a live session — this is the deafness, and Dart cannot '
            'prevent it');
    expect(mic.hardware, MicHardware.unknown,
        reason: 'but it must not be reported as streaming. A call we stopped '
            'believing in has just touched the recorder; whatever we thought '
            'the hardware was doing, we no longer know');
    expect(mic.isRecording, isFalse,
        reason: '`isRecording == true` over a dead recorder is a NEW lie, and '
            'the reporting is the half of this that Dart can fix');
  });

  test('an abandoned startStream that finally lands must not leave the '
      'hardware recorded as idle', () async {
    // THE MIRROR, and the more dangerous direction. An abandoned stop leaves
    // us claiming a microphone we have lost; an abandoned START leaves us
    // claiming an idle recorder that is in fact live. That belief is what
    // `_ensureIdle` consults, so the next open skips its defensive stop and
    // issues `startStream` on top of a streaming recorder — the undefined
    // behaviour this whole class exists to prevent.
    captureFlutterErrors();
    final rec = FakeRecorder(startDelays: const [
      Duration(milliseconds: 300), // abandoned at 60ms, lands at 300ms
      Duration.zero,
    ]);
    final mic = MicCapture(
      recorder: rec,
      platformTimeout: const Duration(milliseconds: 60),
    );

    final abandoned = mic.start();
    await expectLater(abandoned.stream, throwsA(isA<TimeoutException>()));

    // A session opens and closes cleanly in the meantime, which is what walks
    // MicCapture's belief all the way back to `idle`.
    final second = mic.start();
    await second.stream.timeout(const Duration(seconds: 2));
    await second.stop();
    expect(mic.hardware, MicHardware.idle, reason: 'sanity: a clean teardown');

    // Now the abandoned open lands and opens the hardware behind our back.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await settle();

    expect(rec.platformStreaming, isTrue,
        reason: 'sanity: the platform opened the microphone after we gave up '
            'waiting for it, and nothing in Dart could stop it');
    expect(mic.hardware, MicHardware.unknown,
        reason: 'recording that as idle is how a recorder ends up streaming '
            'for the life of the process with no subscriber');

    // And the consequence that makes this worth fixing rather than merely
    // reporting: the next open must RECONCILE instead of opening on top.
    final third = mic.start();
    await third.stream.timeout(const Duration(seconds: 2));

    expect(rec.startedOnLiveRecorder, isFalse,
        reason: 'believing the recorder idle is exactly what makes the next '
            'open skip its defensive stop and start a second stream on a live '
            'AudioRecorder');
    expect(mic.isRecording, isTrue);
  }, timeout: const Timeout(Duration(seconds: 8)));
}
