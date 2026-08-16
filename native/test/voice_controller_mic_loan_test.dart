import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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
    // has nothing to restore — isolating exactly the race this test means
    // to exercise, rather than entangling it with the restore path already
    // covered above.
    expect(b.vc.micOn, isFalse);

    final fut = b.vc.suspendMic();
    expect(b.vc.debugMicLoaned, isTrue,
        reason: 'suspendMic() latches the loan synchronously, before its '
            'own first await');
    // Zero-duration turns are enough to clear _micSub?.cancel() and
    // _mic.stop() (nothing delays those here), landing suspendMic() inside
    // its call to the delayed _mic.start() — genuinely in flight, not yet
    // resolved. mic.startCalls proves it: FakeMic.start() increments that
    // before awaiting its own delay.
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
    expect(b.vc.eventLog, contains('mic return superseded'),
        reason: 'resumeMic() must read the generation it bumps, not just bump '
            'it');
  });
}
