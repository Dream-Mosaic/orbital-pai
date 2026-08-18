import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/audio/audio_track_player.dart';
import 'package:henry_wall/audio/mic_capture.dart';
import 'package:henry_wall/connection/app_connection.dart';
import 'package:henry_wall/phoenix/phoenix_socket.dart';
import 'package:henry_wall/voice/voice_controller.dart';
import 'package:stream_channel/stream_channel.dart';

import 'support/fakes.dart';

// This harness is copied from voice_controller_reconnect_test.dart (same
// FakeSocket/build shape) rather than imported, so this file has no
// compile-time dependency on another test file's `main()`. Trimmed to what
// the mic-loan tests actually exercise: join replies are always `ok`, so
// there is no JoinReply knob here.

/// One in-memory Phoenix socket: answers joins, lets a test push server
/// events, and can be killed to simulate a bounce.
class FakeSocket {
  FakeSocket({Duration heartbeat = const Duration(days: 1)}) {
    ctrl.foreign.stream.listen((f) {
      sent.add(f);
      if (f is! String) return;
      final p = jsonDecode(f) as List<dynamic>;
      if (p[3] != 'phx_join') return;
      scheduleMicrotask(() {
        if (localClosed) return;
        ctrl.foreign.sink.add(jsonEncode([
          null,
          p[1],
          p[2],
          'phx_reply',
          {'status': 'ok', 'response': <String, dynamic>{}},
        ]));
      });
    }, onDone: () => localClosed = true);
    socket = PhoenixSocket(ctrl.local, heartbeatInterval: heartbeat);
    socket.start();
  }

  final StreamChannelController<dynamic> ctrl = StreamChannelController<dynamic>();
  final List<dynamic> sent = <dynamic>[];
  late final PhoenixSocket socket;
  bool localClosed = false;

  /// The Phoenix V2 binary pushes this client sent (mic PCM, enrollment PCM).
  List<Uint8List> get binaryFrames => sent.whereType<Uint8List>().toList();

  Future<void> kill() => ctrl.foreign.sink.close();
}

/// Builds the pair under test, same shape as voice_controller_reconnect_test's
/// `build()`.
({AppConnection conn, VoiceController vc, FakeSocket fake}) build({
  Future<PhoenixSocket> Function()? connector,
  List<Duration> backoff = const [Duration(days: 1)],
  MicCapture? mic,
  AudioTrackPlayer? player,
}) {
  final fake = FakeSocket();
  final conn = AppConnection(
      connector: connector ?? (() async => fake.socket), rejoinBackoff: backoff);
  final vc = VoiceController(
      connection: conn, mic: mic ?? FakeMic(), player: player ?? FakePlayer());
  return (conn: conn, vc: vc, fake: fake);
}

/// Take delivery of the errors a test deliberately provokes. A platform stop
/// that fails or times out is REPORTED on purpose — silence is the bug this
/// subsystem keeps producing — so a test that drives one must collect it
/// rather than let `FlutterError.onError` fail the test with it.
List<FlutterErrorDetails> captureFlutterErrors() {
  final reports = <FlutterErrorDetails>[];
  final original = FlutterError.onError;
  FlutterError.onError = reports.add;
  addTearDown(() => FlutterError.onError = original);
  return reports;
}

void main() {
  test('suspendMic() with the mic on stops the conversation session and hands '
      'back a live borrowed stream', () async {
    final mic = FakeMic();
    final b = build(mic: mic);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    expect(b.vc.micOn, isTrue);
    final stopsBefore = mic.stopCalls;

    final stream = await b.vc.suspendMic();

    expect(b.vc.micOn, isFalse,
        reason: 'the conversation no longer owns the recorder');
    expect(mic.stopCalls, greaterThan(stopsBefore),
        reason: 'the conversation session must be stopped before the borrow starts');
    expect(mic.startCalls, 2,
        reason: 'once for the conversation, once for the loan');

    final frames = <Uint8List>[];
    final sub = stream.listen(frames.add);
    mic.emit(Uint8List.fromList(const [9, 9, 9]));
    await settle();
    expect(frames, hasLength(1),
        reason: 'the returned stream must be the live borrowed session');
    await sub.cancel();
  });

  test('frames on the borrowed stream never reach voice:henry', () async {
    // Spec §3: reading an enrollment prompt aloud must not become a turn.
    final mic = FakeMic();
    final b = build(mic: mic);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    await settle();
    b.fake.sent.clear();

    final stream = await b.vc.suspendMic();
    final sub = stream.listen((_) {});
    mic.emit(Uint8List.fromList(const [1, 2, 3, 4]));
    await settle();

    expect(b.fake.binaryFrames, isEmpty,
        reason: 'the borrowed stream is not wired to the mic listener that '
            'pushes into voice:henry');
    await sub.cancel();
  });

  test('resumeMic() after a suspend with the mic on restores it', () async {
    final mic = FakeMic();
    final b = build(mic: mic);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    await b.vc.suspendMic();
    expect(mic.startCalls, 2);

    await b.vc.resumeMic();
    await settle();

    expect(b.vc.micOn, isTrue);
    expect(mic.startCalls, 3, reason: 'resume must reopen the conversation session');
  });

  test('resumeMic() after a suspend with the mic off stays off', () async {
    final mic = FakeMic();
    final b = build(mic: mic);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    // The conversation's mic was never on before the loan.
    await b.vc.suspendMic();
    expect(mic.startCalls, 1, reason: "only the loan's own start");
    final stopsBeforeResume = mic.stopCalls;

    await b.vc.resumeMic();
    await settle();

    expect(b.vc.micOn, isFalse);
    expect(mic.startCalls, 1, reason: 'nothing to restore means no third start');
    expect(mic.stopCalls, greaterThan(stopsBeforeResume),
        reason: 'the borrowed session must be closed even when nothing is restored');
    expect(mic.isRecording, isFalse);
  });

  test('resumeMic() twice in a row is a no-op the second time', () async {
    final mic = FakeMic();
    final b = build(mic: mic);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    await b.vc.suspendMic();
    await b.vc.resumeMic();
    await settle();
    final startsAfterFirstResume = mic.startCalls;
    final stopsAfterFirstResume = mic.stopCalls;

    await b.vc.resumeMic();
    await settle();

    expect(mic.startCalls, startsAfterFirstResume);
    expect(mic.stopCalls, stopsAfterFirstResume);
    expect(b.vc.micOn, isTrue);
  });

  test('resumeMic() without a prior suspend returns cleanly and changes '
      'nothing', () async {
    final mic = FakeMic();
    final b = build(mic: mic);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();

    await b.vc.resumeMic();
    await settle();

    expect(b.vc.micOn, isFalse);
    expect(mic.startCalls, 0);
    expect(mic.stopCalls, 0);
    expect(b.vc.debugMicLoaned, isFalse);
  });

  test('startMic() during the loan does not touch the recorder but is '
      'honoured on resume', () async {
    final mic = FakeMic();
    final b = build(mic: mic);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    // The mic was OFF before the loan.
    await b.vc.suspendMic();
    final startsDuringLoan = mic.startCalls;

    await b.vc.startMic();
    await settle();
    expect(mic.startCalls, startsDuringLoan,
        reason: 'a second recording session must not open while one is on loan');
    expect(b.vc.micOn, isFalse);

    await b.vc.resumeMic();
    await settle();

    expect(b.vc.micOn, isTrue,
        reason: 'the power tap made during enrollment is honoured once the mic '
            'comes back');
  });

  test('stopMic() during the loan cancels the restore', () async {
    final mic = FakeMic();
    final b = build(mic: mic);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    await b.vc.suspendMic();

    await b.vc.stopMic();
    await b.vc.resumeMic();
    await settle();

    expect(b.vc.micOn, isFalse,
        reason: 'a power-off during enrollment must stick once the mic comes back');
  });

  test('a resume while the channel is down still re-arms once the reconnect '
      'lands', () async {
    final mic = FakeMic();
    final sockets = <FakeSocket>[];
    final b = build(
      connector: () async {
        final s = FakeSocket();
        sockets.add(s);
        return s.socket;
      },
      backoff: const [Duration(milliseconds: 10)],
      mic: mic,
    );
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);

    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    expect(b.vc.micOn, isTrue);

    await b.vc.suspendMic();
    await sockets.first.kill();
    await settle();

    await b.vc.resumeMic();
    await settle();
    expect(b.vc.micOn, isFalse,
        reason: 'the channel is down, so resumeMic() cannot start the mic directly');

    await Future<void>.delayed(const Duration(milliseconds: 40));
    await settle();

    expect(b.conn.state, ConnState.joined);
    expect(b.vc.micOn, isTrue,
        reason: 'the restore is handed to the same re-arm flag a socket death '
            'uses, so the automatic rejoin brings the mic back');
  });

  test('dispose() mid-loan stops the recorder', () async {
    final mic = FakeMic();
    final b = build(mic: mic);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    await b.vc.suspendMic();
    expect(mic.isRecording, isTrue);

    b.vc.dispose();
    await settle();

    expect(mic.isRecording, isFalse);
  });

  test('suspendMic() while already loaned throws, and debugMicLoaned tracks '
      'the loan', () async {
    final mic = FakeMic();
    final b = build(mic: mic);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();

    expect(b.vc.debugMicLoaned, isFalse);
    await b.vc.suspendMic();
    expect(b.vc.debugMicLoaned, isTrue);

    await expectLater(b.vc.suspendMic(), throwsA(isA<StateError>()));
    expect(b.vc.debugMicLoaned, isTrue,
        reason: 'a refused double-suspend must not clear the existing loan');

    await b.vc.resumeMic();
    await settle();
    expect(b.vc.debugMicLoaned, isFalse);
  });

  // The second-order problem behind VoiceLockClient.acquireTimeout: that
  // timeout only stops the CALLER from waiting on a hung suspendMic() —
  // Dart futures cannot be cancelled, so suspendMic()'s own unbounded
  // _mic.start() keeps running underneath. This pins what suspendMic() and
  // resumeMic() must do about it: a caller that gives up (by calling
  // resumeMic() in its place, exactly what VoiceLockClient's `finally`
  // does) must not be undone by the belated start() landing afterward —
  // it must not hand back a stream nobody listens to, must not leave the
  // recorder running unconsumed, and must not re-latch a loan resumeMic()
  // already closed.
  test(
      'a suspendMic() whose caller gives up before it finishes stops the '
      'recorder instead of leaving it running once it belatedly completes',
      () async {
    final mic = FakeMic(startDelay: const Duration(milliseconds: 60));
    final b = build(mic: mic);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    // The conversation's mic was off before the loan, so resumeMic() below
    // has nothing to restore. That is ONE case, not the interesting one: the
    // entangled version — mic ON, so the restore path runs too — is covered
    // by the test immediately below and by the sixth-Critical pair at the end
    // of this file. Leaving the entangled case out is exactly how the fifth
    // and sixth Criticals hid.
    expect(b.vc.micOn, isFalse);

    final fut = b.vc.suspendMic();
    expect(b.vc.debugMicLoaned, isTrue,
        reason: 'suspendMic() latches the loan synchronously, before its '
            'own first await');
    // Zero-duration turns are enough to clear the conversation's own teardown
    // (nothing delays it here), landing suspendMic() inside the delayed open
    // of the borrowed session — genuinely in flight, not yet resolved.
    // `mic.startCalls` proves it: it counts FakeRecorder.startStream calls,
    // incremented once hasPermission() has resolved and the platform open is
    // actually under way.
    await settle();
    expect(mic.startCalls, 1,
        reason: 'suspendMic() has called _mic.start() and is now waiting '
            'on it');

    // Simulates VoiceLockClient's acquireTimeout firing while suspendMic()
    // is genuinely still in flight: the caller gives up and its `finally`
    // calls resumeMic() in its place.
    await b.vc.resumeMic();
    await settle();
    expect(b.vc.debugMicLoaned, isFalse);

    // Now let the abandoned suspendMic() actually finish.
    await expectLater(fut, throwsA(isA<StateError>()),
        reason: 'a suspend that finishes after its caller already gave up '
            'must not hand back a stream nobody will ever listen to');
    await settle();

    expect(mic.isRecording, isFalse,
        reason: 'the belated start() must be stopped immediately, not left '
            'running with nobody consuming it');
    expect(b.vc.debugMicLoaned, isFalse,
        reason: 'the stale continuation must not re-latch a loan resumeMic() '
            'already closed');

    // And the world still works afterward: a normal conversation turn can
    // still get the microphone.
    await b.vc.startMic();
    await settle();
    expect(b.vc.micOn, isTrue,
        reason: 'a later, unrelated startMic() must not be wedged by the '
            'stale loan');
  });

  // THE ENTANGLED CASE the test above deliberately left out — and the one that
  // actually breaks. Same abandoned-suspend race, but with the conversation's
  // mic ON before the loan, so resumeMic() RESTORES it. A generation counter
  // cannot fix this: it protects VoiceController's own fields, and the thing
  // being clobbered is the one piece of shared hardware. Measured before the
  // fix: micOn=true isRecording=false — deaf, with the indicator lying.
  test(
      'a suspendMic() abandoned mid-start must not stop the session the '
      'restore opened', () async {
    // Per-call delays reproduce the production shape: the loan's start is the
    // one that wedges (the audio subsystem is busy tearing the conversation's
    // session down); the restore's start is ordinary.
    final mic = FakeMic(startDelays: const [
      Duration.zero, // the conversation's own session
      Duration(milliseconds: 100), // the loan's start — wedged
      Duration.zero, // the restore's start
    ]);
    final b = build(mic: mic);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    expect(b.vc.micOn, isTrue, reason: 'sanity: the conversation has the mic');

    // The borrower's acquire. Its error is captured rather than awaited: this
    // models VoiceLockClient, whose `.timeout(acquireTimeout)` stops waiting
    // but leaves a listener attached, so a late failure is discarded, not
    // unhandled.
    Object? loanOutcome;
    final loan = b.vc.suspendMic().then<void>(
      (s) => loanOutcome = s,
      onError: (Object e) => loanOutcome = e,
    );
    await settle();
    expect(mic.startCalls, 2,
        reason: 'suspendMic() has issued the loan start and is waiting on it');
    expect(mic.isRecording, isFalse,
        reason: 'sanity: the wedged start has not opened anything yet, which '
            'is exactly why a plain stop() cannot close it');

    // acquireTimeout fires: the borrower gives up and its `finally` calls
    // resumeMic() in its place, which restores the conversation's mic.
    unawaited(b.vc.resumeMic());
    // Long enough for the wedged loan start to land afterwards.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await settle();
    await loan;

    expect(loanOutcome, isA<StateError>(),
        reason: 'the abandoned suspend must fail rather than hand back a '
            'stream nobody will listen to');
    expect(b.vc.micOn, isTrue,
        reason: 'sanity: the restore claims the conversation is listening');
    expect(mic.isRecording, isTrue,
        reason: 'and it must actually BE listening — the stale suspend must '
            'not stop the session the restore opened');
    expect(mic.maxConcurrentStarts, 1,
        reason: 'two concurrent startStream() calls on one AudioRecorder is '
            'undefined behaviour: the restore must not open a session on top '
            'of the wedged one');

    // The decisive assertion: frames from the live session still reach
    // voice:henry. micOn is a flag; this is the assistant actually hearing.
    b.fake.sent.clear();
    mic.emit(Uint8List.fromList(const [7, 7, 7, 7]));
    await settle();
    expect(b.fake.binaryFrames, isNotEmpty,
        reason: 'the conversation must be subscribed to the session that is '
            'really running');
  });

  // THE MIRROR IMAGE of the test above, and the seventh Critical of this
  // class. Same abandoned-suspend race, but the wedged start is the
  // CONVERSATION'S OWN rather than the loan's — the shape a slow audio
  // subsystem actually produces when the user taps Record right after tapping
  // power. The test above is satisfied by a short-circuit that only fires for
  // the stopping session's own in-flight open; this one is not, because here
  // the in-flight open belongs to somebody else, so `_stopSession` falls
  // through and clobbers MicCapture's serialisation chain.
  //
  // Measured before the fix, end to end through the real VoiceController:
  // maxConcurrentStarts=2, settling at micOn=true micIsRecording=false — deaf,
  // indicator lit, with startMic() and setPtt() both dead and only two power
  // taps recovering.
  test(
      "a suspendMic() abandoned while the CONVERSATION'S own start is still "
      'in flight must not overlap the restore onto it', () async {
    final mic = FakeMic(startDelays: const [
      Duration(milliseconds: 120), // the conversation's own start — wedged
      Duration.zero, // the loan's start
      Duration.zero, // the restore's start
    ]);
    final b = build(mic: mic);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();

    // Not awaited: the point is that the platform has NOT answered yet.
    final ownStart = b.vc.startMic();
    await settle();
    expect(mic.startCalls, 1,
        reason: "sanity: the conversation's own start is inside startStream");
    expect(b.vc.micOn, isFalse, reason: 'sanity: it has not opened yet');

    // The user taps Record inside that window. Its error is captured rather
    // than awaited, modelling VoiceLockClient's `.timeout(acquireTimeout)`.
    Object? loanOutcome;
    final loan = b.vc.suspendMic().then<void>(
      (s) => loanOutcome = s,
      onError: (Object e) => loanOutcome = e,
    );
    await settle();

    // acquireTimeout fires: the borrower's `finally` calls resumeMic(), which
    // restores the conversation's mic — while the original start is STILL
    // inside the plugin.
    unawaited(b.vc.resumeMic());
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await settle();
    await loan;
    await ownStart;

    expect(mic.maxConcurrentStarts, 1,
        reason: 'the restore must queue behind the wedged open, not be handed '
            'a chain the loan-stop already replaced');
    expect(loanOutcome, isA<StateError>());
    expect(b.vc.micOn, isTrue,
        reason: 'sanity: the restore claims the conversation is listening');
    expect(mic.isRecording, isTrue,
        reason: "and it must actually BE listening — the stale open's "
            'orphan-close may not stop the session the restore opened');

    b.fake.sent.clear();
    mic.emit(Uint8List.fromList(const [9, 9, 9, 9]));
    await settle();
    expect(b.fake.binaryFrames, isNotEmpty,
        reason: 'the assistant actually hearing, not merely a lit indicator');
  });

  // The same guard reached WITHOUT enrollment: impatient power tapping. There
  // is no loan here at all, so a reader cannot dismiss the Critical above as
  // an enrollment-only problem — any stop issued for one session while
  // another session's open is in flight has to leave the chain alone.
  test('power tapped repeatedly while a start is wedged never overlaps two '
      'starts', () async {
    final mic = FakeMic(startDelays: const [
      Duration(milliseconds: 120), // tap 1 — still inside startStream
      Duration.zero,
      Duration.zero,
    ]);
    final b = build(mic: mic);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();

    final wedged = b.vc.startMic(); // ON  — session 1, wedged
    await settle();
    await b.vc.stopMic(); // OFF — short-circuits: session 1 is its own
    final second = b.vc.startMic(); // ON  — session 2, queued behind it
    await settle();
    await b.vc.stopMic(); // OFF — THE case: session 2's stop, session 1 in flight
    final third = b.vc.startMic(); // ON  — session 3

    await Future<void>.delayed(const Duration(milliseconds: 250));
    await settle();
    await wedged;
    await second;
    await third;

    expect(mic.maxConcurrentStarts, 1,
        reason: "stopping session 2 must not drop session 1's open out of "
            "MicCapture's queue");
    expect(b.vc.micOn, isTrue);
    expect(mic.isRecording, isTrue,
        reason: 'the last tap left the mic ON and it must really be on');
  });

  // ---- the platform ENDING the stream under us ----
  //
  // `MicState.on` is derived from holding a subscription — but a subscription
  // to a DONE stream is still non-null, so it is derived from HOLDING one, not
  // from audio FLOWING. Audio focus lost to an incoming call, the OS revoking
  // the record permission, another app taking the microphone: the frames stop
  // and nothing throws. MEASURED before the fix: micOn=true, and startMic()
  // then no-ops on its own `held.on` guard, so the recovery path is dead too.

  test('a mic stream the platform ends under us turns the indicator off, and '
      'the next tap gets the microphone back', () async {
    final mic = FakeMic();
    final b = build(mic: mic);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    expect(b.vc.micOn, isTrue, reason: 'sanity: the conversation has the mic');

    // The platform ends the stream. No exception, no stop() — the frames just
    // cease.
    unawaited(mic.current.close());
    await settle();

    expect(b.vc.micOn, isFalse,
        reason: 'the refactor claims `on` is derived and therefore cannot '
            'lie; it can, because it is derived from holding a subscription '
            'rather than from audio flowing');

    // The consequence that makes it a Critical rather than a cosmetic one:
    // with the indicator stuck on, startMic() bails on `held.on`.
    await b.vc.startMic();
    await settle();
    expect(b.vc.micOn, isTrue);
    expect(mic.isRecording, isTrue);
    expect(mic.startCalls, 2,
        reason: 'the retry has to actually reach the platform, not no-op on a '
            'stale flag');

    b.fake.sent.clear();
    mic.emit(Uint8List.fromList(const [3, 3, 3, 3]));
    await settle();
    expect(b.fake.binaryFrames, isNotEmpty,
        reason: 'the assistant really hearing again, not merely a dark '
            'indicator');
  });

  // THE MIRROR: turning the indicator off is only half of it. The recorder is
  // still CLAIMED — this controller's session owns it and MicCapture still has
  // the hardware down as streaming — so a fix that only flipped the state
  // would leave the next start opening on top of a session nobody stopped,
  // which is the undefined behaviour the whole MicCapture design exists to
  // prevent.
  test('a mic stream the platform ends is also let go of at the hardware',
      () async {
    final rec = FakeRecorder();
    final mic = FakeMic.withRecorder(rec);
    final b = build(mic: mic);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    expect(rec.platformStreaming, isTrue, reason: 'sanity: the fake is live');

    unawaited(rec.sessions.last.close());
    await settle();

    expect(mic.isRecording, isFalse,
        reason: 'the session must be stopped by name, not merely forgotten');
    expect(rec.platformStreaming, isFalse,
        reason: 'and the HARDWARE let go: an indicator turned off over a '
            'recorder still claimed is the same lie in the other direction');
    expect(rec.stopCalls, 1);

    await b.vc.startMic();
    await settle();
    expect(rec.startedOnLiveRecorder, isFalse,
        reason: 'the retry must not open a second session on top of one that '
            'was never released');
    expect(rec.maxConcurrentStarts, 1);
  });

  test(
      'a start that fails after a newer start took over must not cancel the '
      'newer one', () async {
    // The same ownership rule, on the conversation's own path rather than the
    // loan's: a stale startMic() reporting its failure used to clear
    // `_micWanted`, which made the LIVE start bail out on its own guard when
    // it landed a moment later. Deaf, again, with nothing to debug from.
    final mic = FakeMic(startDelays: const [
      Duration(milliseconds: 80), // the abandoned start
      Duration.zero, // the one the user actually gets
    ]);
    final b = build(mic: mic);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();

    final abandoned = b.vc.startMic();
    await settle();
    await b.vc.stopMic(); // the user changes their mind mid-start…
    final wanted = b.vc.startMic(); // …and then changes it back

    await abandoned;
    await wanted;
    await settle();

    expect(b.vc.micOn, isTrue,
        reason: 'the second start is the live one and nothing stale may '
            'cancel it');
    expect(mic.isRecording, isTrue);
    expect(mic.maxConcurrentStarts, 1);
  });

  test(
      'a mic-off tapped inside resumeMic()\'s own platform await is honoured, '
      'not undone', () async {
    // resumeMic() has an unbounded `stop()` of its own, and every write after
    // it used to be unguarded — so the user tapping power OFF inside that
    // await got the microphone turned back ON by the continuation.
    final mic = FakeMic(stopDelay: const Duration(milliseconds: 60));
    final b = build(mic: mic);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    await b.vc.suspendMic();
    expect(b.vc.micOn, isFalse);

    final resuming = b.vc.resumeMic();
    await settle(); // land inside resumeMic()'s stop of the borrowed session

    await b.vc.stopMic();
    expect(b.vc.micOn, isFalse, reason: 'sanity: the tap took effect');

    await resuming;
    await settle();

    expect(b.vc.micOn, isFalse,
        reason: 'a power-off tapped while the mic was coming back must stick — '
            'the same guarantee that already holds inside the loan');
    expect(mic.isRecording, isFalse,
        reason: 'and no recorder may be left running behind it');
  });

  test(
      'a second enrollment started while a slow resumeMic() is still in flight '
      'does not lose the restore intent', () async {
    // VoiceLockClient bounds releaseMic() at 2s, so a slow resumeMic() is
    // ABANDONED mid-flight and the panel lets the user record the next slot.
    // suspendMic() then recomputed _resumeMicWanted from _micOn/_micWanted —
    // both false precisely BECAUSE the first loan took the mic — so "the
    // conversation had the microphone" was lost and the device stayed
    // silently deaf after enrollment.
    final mic = FakeMic(stopDelay: const Duration(milliseconds: 60));
    final b = build(mic: mic);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    expect(b.vc.micOn, isTrue);

    await b.vc.suspendMic(); // enrollment 1 borrows the mic
    final resuming = b.vc.resumeMic(); // …and its return is slow
    await settle();

    // The borrower gave up on that release; enrollment 2 takes the mic.
    await b.vc.suspendMic();
    await resuming; // the abandoned first return lands somewhere in here
    await settle();

    await b.vc.resumeMic(); // enrollment 2 gives it back
    await settle();

    expect(b.vc.micOn, isTrue,
        reason: 'the conversation had the microphone before enrollment 1, and '
            'nobody asked for it to go off');
    expect(mic.isRecording, isTrue);
    // The abandoned first return must also have STOOD DOWN rather than run
    // its tail against a cycle it no longer owned. Its state writes happen to
    // be self-healing today (see resumeMic), so the log is what makes the
    // guard falsifiable at all — without it there is nothing to distinguish
    // "recognised itself as stale" from "got lucky".
    // The abandoned first return also has to have stood down rather than run
    // its tail against a cycle it no longer owned. What makes that falsifiable
    // is the hardware, not a log line: a stale return that acted would have
    // stopped or re-opened the recorder underneath the live session.
    expect(mic.maxConcurrentStarts, 1);
    expect(mic.recorder.startedOnLiveRecorder, isFalse,
        reason: 'the abandoned return must not have opened a session on top '
            'of the one enrollment 2 was holding');
  });

  // ---- the ordinary conversation teardown, held to the same two rules ----
  //
  // stopMic() is the NORMAL path, not the enrollment one, and it has the same
  // shape as every Critical in this family: a transition and a platform call.
  // These three pin the rules directly rather than through a scenario.

  test('stopMic() switches the microphone off before it touches the platform, '
      'not after', () async {
    // INVARIANT A, measured at the only moment that can tell the difference:
    // while the platform call is still outstanding.
    captureFlutterErrors();
    final mic = FakeMic(
      stopBehaviour: const [FakeCall.hangs],
      platformTimeout: const Duration(milliseconds: 60),
    );
    final b = build(mic: mic);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    expect(b.vc.micOn, isTrue);

    final stopping = b.vc.stopMic();
    await settle();

    expect(b.vc.micOn, isFalse,
        reason: 'the whole transition is applied before the recorder is asked '
            'to stop; a state that waits for the platform is a state that '
            'lies whenever the platform does not answer');
    await stopping.timeout(const Duration(seconds: 2));
    expect(b.vc.micOn, isFalse);
  });

  test('a mic subscription whose cancel never returns cannot park the '
      'teardown', () async {
    // INVARIANT B. The session stream belongs to the plugin, so its cancel()
    // is the one microphone-shaped call MicCapture cannot bound for us. An
    // unbounded one is worse than a throwing one: there is nothing to catch,
    // and the teardown simply never finishes.
    final mic = FakeMic(
      cancelBehaviour: FakeCall.hangs,
      platformTimeout: const Duration(milliseconds: 40),
    );
    final b = build(mic: mic);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    expect(b.vc.micOn, isTrue);

    // The assertion IS the timeout: without the bound this never completes.
    await b.vc.stopMic().timeout(const Duration(seconds: 2));

    expect(b.vc.micOn, isFalse);
    expect(mic.isRecording, isFalse,
        reason: 'and the recorder must have been stopped regardless of what '
            'the subscription did');
  });

  test('a mic subscription whose cancel throws does not stop the recorder '
      'being closed', () async {
    // The same step failing the other way. It must not propagate either:
    // dispose() and _onChannelDown() tear down fire-and-forget, so a throw
    // here becomes an unhandled async error rather than anything catchable.
    final mic = FakeMic(cancelBehaviour: FakeCall.throws);
    final b = build(mic: mic);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    await b.vc.startMic();

    await expectLater(b.vc.stopMic(), completes,
        reason: 'teardown is the one thing that must always finish');

    expect(b.vc.micOn, isFalse);
    expect(mic.isRecording, isFalse);
    expect(b.vc.eventLog, contains(startsWith('mic cancel failed')),
        reason: 'and the failure must be visible, not swallowed — silence is '
            'this subsystem’s whole failure mode');
  });

  // ---- THE SIXTH CRITICAL: the microphone goes off in the same breath the
  // conversation gives up the recorder, never on the far side of a platform
  // call ----
  //
  // Measured before the fix: suspendMic() dropped `_micSub` and `_micSession`
  // BEFORE `await conversation.stop()` but set `_micOn = false` AFTER it,
  // behind a superseded() that throws. A stop that wedged therefore left
  // `micOn == true` over no recorder at all — and every automatic recovery
  // path (_reArmMic, setPtt, resumeMic's own restore) funnels into startMic(),
  // which bailed on `_micOn`. Recovery was two deliberate power taps by a user
  // whose indicator said the assistant was listening.
  //
  // Both earlier race tests in this file park suspendMic at its LATER platform
  // call (`_mic.start()`). These park it at the FIRST one, WITH THE MIC ON —
  // the entangled case, which is the damaging one. That exclusion is how the
  // sixth Critical hid.

  // The ACQUIRE-side companion to the stop-side bound tests below. Mutation
  // testing found the asymmetry exactly: deleting `.timeout()` from `stop()`
  // killed four tests; deleting it from `startStream()` killed none. What it
  // protects, from up here where a user would feel it: an unbounded wedge
  // never settles MicCapture's `_ops`, so every later start queues behind it
  // forever and the microphone never comes back — no error, no indicator, not
  // even a power tap.
  test('a start the platform never answers gives the microphone back to the '
      'next tap', () async {
    captureFlutterErrors();
    final mic = FakeMic(
      // Only the FIRST start wedges; the user's second tap is ordinary.
      startBehaviour: const [FakeCall.hangs],
      platformTimeout: const Duration(milliseconds: 60),
    );
    final b = build(mic: mic);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();

    await b.vc.startMic().timeout(const Duration(seconds: 2));
    expect(b.vc.micOn, isFalse,
        reason: 'a start that never opened must report itself off rather '
            'than hang the caller');

    // THE assertion: the next tap actually works.
    await b.vc.startMic().timeout(const Duration(seconds: 2));
    await settle();
    expect(b.vc.micOn, isTrue);
    expect(mic.isRecording, isTrue);
    expect(mic.startCalls, 2);
  }, timeout: const Timeout(Duration(seconds: 8)));

  test('a conversation stop that never answers cannot leave the microphone '
      'claiming to be on', () async {
    captureFlutterErrors();
    final mic = FakeMic(
      // The conversation's own session refuses to stop, the way a wedged
      // audio subsystem does: no exception, just no answer. Bounded inside
      // MicCapture (Invariant B), so it resolves — late, and as a failure.
      stopBehaviour: const [FakeCall.hangs],
      platformTimeout: const Duration(milliseconds: 60),
    );
    final b = build(mic: mic);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    expect(b.vc.micOn, isTrue, reason: 'sanity: the conversation has the mic');

    Object? loanOutcome;
    final loan = b.vc.suspendMic().then<void>(
          (s) => loanOutcome = s,
          onError: (Object e) => loanOutcome = e,
        );
    await settle();

    // THE assertion. The conversation has already let go of its subscription
    // and its session; a state that still reports "on" is a lie every
    // recovery path then acts on.
    expect(b.vc.micOn, isFalse,
        reason: 'the transition off happens with the handles it describes, '
            'entirely before the platform call — not after it, and not '
            'conditionally on it returning');
    expect(b.vc.debugMicLoaned, isTrue,
        reason: 'sanity: the loan really is in flight at this point');

    // And the same must hold once the wedged stop finally gives up.
    await b.vc.resumeMic();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await settle();
    await loan;
    expect(loanOutcome, anything, reason: 'the abandoned loan settled');
  });

  test('a conversation stop that wedges must not leave the restore path dead',
      () async {
    // The full sixth-Critical scenario, end to end: mic ON, Record tapped,
    // suspendMic parks in the conversation's platform stop, acquireTimeout
    // fires, and the borrower's `finally` calls resumeMic() in its place.
    captureFlutterErrors();
    final mic = FakeMic(
      stopBehaviour: const [FakeCall.hangs],
      platformTimeout: const Duration(milliseconds: 60),
    );
    final b = build(mic: mic);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    expect(b.vc.micOn, isTrue);

    Object? loanOutcome;
    final loan = b.vc.suspendMic().then<void>(
          (s) => loanOutcome = s,
          onError: (Object e) => loanOutcome = e,
        );
    await settle();

    unawaited(b.vc.resumeMic());
    // Long enough for the bounded stop to give up and for the restore to open
    // its own session behind it.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await settle();
    await loan;

    expect(loanOutcome, isA<StateError>(),
        reason: 'the abandoned suspend must fail rather than hand back a '
            'stream nobody will listen to');
    expect(b.vc.micOn, isTrue,
        reason: 'the restore must actually restart the microphone — it used '
            'to bail out on a stale micOn and nothing ever restarted it');
    expect(mic.isRecording, isTrue,
        reason: 'and the indicator must not be the only thing that recovered');
    expect(mic.maxConcurrentStarts, 1);
    expect(mic.recorder.startedOnLiveRecorder, isFalse);

    // The decisive assertion: the assistant can actually hear again.
    b.fake.sent.clear();
    mic.emit(Uint8List.fromList(const [4, 2, 4, 2]));
    await settle();
    expect(b.fake.binaryFrames, isNotEmpty,
        reason: 'micOn is a flag; this is the conversation subscribed to the '
            'session that is really running');
  });

  test('a conversation stop the platform refuses still completes the loan',
      () async {
    // The sixth Critical's SECOND trigger: a platform stop that THROWS rather
    // than wedging used to propagate straight out of suspendMic() with the
    // mic still claiming to be on. MicSession.stop() is non-throwing by
    // construction now, so the loan simply proceeds.
    captureFlutterErrors();
    final mic = FakeMic(stopBehaviour: const [FakeCall.throws]);
    final b = build(mic: mic);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    expect(b.vc.micOn, isTrue);

    final stream = await b.vc.suspendMic();

    expect(b.vc.micOn, isFalse);
    expect(b.vc.debugMicLoaned, isTrue);
    final frames = <Uint8List>[];
    final sub = stream.listen(frames.add);
    mic.emit(Uint8List.fromList(const [5, 5]));
    await settle();
    expect(frames, hasLength(1),
        reason: 'the borrowed stream must be live even though the '
            "conversation's own session refused to close");
    await sub.cancel();
  });

  test('a restore that fails does not leave an intent for the NEXT enrollment '
      'to act on', () async {
    // resumeMic() consumes the restore intent, it does not merely read it.
    // Left set, it is inherited by the next suspendMic() — so an enrollment
    // that follows a failed restore would switch the microphone on by itself,
    // with the user having asked for nothing. The failed restore is what makes
    // this observable: after a SUCCESSFUL one the mic is on anyway, so a stale
    // intent and a consumed one look identical.
    captureFlutterErrors();
    final mic = FakeMic(startBehaviour: const [
      FakeCall.ok, // the conversation's own session
      FakeCall.ok, // enrollment 1's borrowed session
      FakeCall.throws, // the restore — the platform refuses
      FakeCall.ok, // enrollment 2's borrowed session
      FakeCall.ok, // anything enrollment 2's return might try to open
    ]);
    final b = build(mic: mic);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    expect(b.vc.micOn, isTrue);

    await b.vc.suspendMic();
    await b.vc.resumeMic();
    await settle();
    expect(b.vc.micOn, isFalse,
        reason: 'sanity: the restore was refused by the platform');

    // A second enrollment, with the conversation's mic legitimately off.
    await b.vc.suspendMic();
    await b.vc.resumeMic();
    await settle();

    expect(b.vc.micOn, isFalse,
        reason: 'nobody asked for the microphone between the two '
            'enrollments; a restore intent the first return failed to consume '
            'must not be inherited by the second');
    expect(mic.isRecording, isFalse);
  });

  test('a loan stop the platform refuses still gives the microphone back',
      () async {
    // Important 3: `await session?.stop()` throwing used to exit resumeMic()
    // with `_micLoaned` already false and `_resumeMicWanted` never consumed,
    // so startMic() was never reached and the mic never returned (logcat
    // only — the indicator was honest, so nothing looked wrong).
    captureFlutterErrors();
    // stop #1 closes the conversation's session; stop #2 is the loan's return
    // and the platform refuses it.
    final mic = FakeMic(stopBehaviour: const [FakeCall.ok, FakeCall.throws]);
    final b = build(mic: mic);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    await b.vc.suspendMic();
    expect(b.vc.micOn, isFalse);

    await b.vc.resumeMic();
    await settle();

    expect(b.vc.micOn, isTrue,
        reason: 'the restore intent is consumed in the same synchronous '
            'transition that ends the loan, so no platform failure can strand '
            'it');
    expect(mic.isRecording, isTrue);
    expect(b.vc.debugMicLoaned, isFalse);
  });
}
