import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/audio/audio_track_player.dart';
import 'package:orbital_pai/audio/mic_capture.dart';
import 'package:orbital_pai/connection/app_connection.dart';
import 'package:orbital_pai/phoenix/phoenix_socket.dart';
import 'package:orbital_pai/voice/voice_controller.dart';
import 'package:stream_channel/stream_channel.dart';

import 'support/fakes.dart';

// The alarm bug: an alarm (or any app) taking audio focus tears the
// `AudioRecord` down under `record`. The stream closes with no exception, and
// before this fix `_onMicStreamEnded` turned the indicator off and stopped —
// Henry stayed deaf until the user power-cycled the app by hand.
//
// This harness is the same FakeSocket/build() shape as
// voice_controller_mic_loan_test.dart, copied rather than imported so this
// file has no compile-time dependency on another test file's `main()`.

/// One in-memory Phoenix socket: answers joins, and that is all these tests
/// need of it — nothing here exercises a channel bounce.
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

  /// The Phoenix V2 binary pushes this client sent (mic PCM).
  List<Uint8List> get binaryFrames => sent.whereType<Uint8List>().toList();
}

/// Builds the pair under test, same shape as the mic-loan and reconnect
/// tests' `build()`.
({AppConnection conn, VoiceController vc, FakeSocket fake}) build({
  MicCapture? mic,
  AudioTrackPlayer? player,
}) {
  final fake = FakeSocket();
  final conn = AppConnection(connector: () async => fake.socket);
  final vc = VoiceController(
      connection: conn, mic: mic ?? FakeMic(), player: player ?? FakePlayer());
  return (conn: conn, vc: vc, fake: fake);
}

/// Comfortably past [VoiceController.micRestartBackoff]'s first step (400ms).
const _pastFirstBackoff = Duration(milliseconds: 550);

/// Comfortably past its second step (2s), on top of the first.
const _pastSecondBackoff = Duration(milliseconds: 2300);

void main() {
  test('an unrequested stream end restarts the mic when the user still '
      'wants it on', () async {
    final mic = FakeMic();
    final b = build(mic: mic);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    expect(b.vc.micOn, isTrue, reason: 'sanity: the conversation has the mic');

    // The alarm: the platform tears the stream down. No exception, no
    // stop() — the frames just cease.
    unawaited(mic.current.close());
    await settle();
    expect(b.vc.micOn, isFalse,
        reason: 'the indicator goes off immediately; the restart is a '
            'backed-off retry, not instantaneous');

    // Past the first backoff step (400ms) without anybody tapping anything.
    await Future<void>.delayed(_pastFirstBackoff);
    await settle();

    expect(b.vc.micOn, isTrue,
        reason: 'the controller must re-open the mic itself');
    expect(mic.startCalls, 2);

    b.fake.sent.clear();
    mic.emit(Uint8List.fromList(const [1, 2, 3, 4]));
    await settle();
    expect(b.fake.binaryFrames, isNotEmpty,
        reason: 'the assistant must really be hearing again, not merely '
            'showing a lit indicator');
  });

  test('a deliberate stopMic does NOT restart', () async {
    final mic = FakeMic();
    final b = build(mic: mic);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    await b.vc.startMic();

    await b.vc.stopMic();
    await settle();
    expect(b.vc.micOn, isFalse);

    // Long enough for the first backoff step to have fired if one had been
    // armed.
    await Future<void>.delayed(_pastFirstBackoff);
    await settle();

    expect(b.vc.micOn, isFalse,
        reason: 'an explicit stop must stay stopped');
    expect(mic.startCalls, 1,
        reason: 'an explicit stop must not schedule (or leave armed) any '
            'restart');
  });

  test('a stopMic issued while an unasked-end restart is already pending '
      'cancels it', () async {
    // The sharper version of the test above: the platform already ended the
    // stream and armed a backoff attempt BEFORE the user reaches for power.
    // A stopMic that only clears intent flags and ignores the pending Timer
    // would still switch the mic back on moments later.
    final mic = FakeMic();
    final b = build(mic: mic);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    await b.vc.startMic();

    unawaited(mic.current.close());
    await settle();
    expect(b.vc.micOn, isFalse, reason: 'sanity: the restart is now pending');

    await b.vc.stopMic();
    await Future<void>.delayed(_pastFirstBackoff);
    await settle();

    expect(b.vc.micOn, isFalse,
        reason: 'the power-off must survive the backoff window that was '
            'already armed');
    expect(mic.startCalls, 1);
  });

  test('repeated unrequested ends back off rather than spinning', () async {
    // The recorder answers the FIRST start, then refuses every one after —
    // the shape of a microphone that stays genuinely unavailable (an alarm
    // that never lets go, permission revoked, another app holding the mic).
    final mic = FakeMic(startBehaviour: const [
      FakeCall.ok,
      FakeCall.throws,
      FakeCall.throws,
      FakeCall.throws,
      FakeCall.throws,
    ]);
    final b = build(mic: mic);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    expect(mic.startCalls, 1);

    unawaited(mic.current.close());
    await settle();

    // Past the first backoff step: one retry attempt, which the platform
    // refuses.
    await Future<void>.delayed(_pastFirstBackoff);
    await settle();
    expect(mic.startCalls, 2,
        reason: 'a failed restart attempt must chain to the next backoff '
            'step, not give up after one try nor spin immediately');

    // Past the second step too: a second retry, also refused.
    await Future<void>.delayed(_pastSecondBackoff);
    await settle();
    expect(mic.startCalls, 3);

    // A hot loop would have driven this far past 4 by now (two full backoff
    // windows have elapsed); the real implementation is still mid-way
    // through its bounded list.
    expect(mic.startCalls, lessThanOrEqualTo(4),
        reason: 'a permanently dead mic must not become a hot loop');

    // And it must not be busy-retrying inside that window either — the third
    // (and last) backoff step is 8s, so nothing further should happen this
    // soon after the second attempt failed.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await settle();
    expect(mic.startCalls, 3,
        reason: 'the third attempt is backed off by 8s, not fired '
            'immediately after the second');
  });

  test('a mic-recovery restart honours a loan instead of fighting it',
      () async {
    // Enrollment can borrow the recorder at any time, including the instant
    // an unasked-end restart is about to fire. The restart must not open a
    // second recording session on top of the loan.
    final mic = FakeMic();
    final b = build(mic: mic);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    expect(b.vc.micOn, isTrue);

    unawaited(mic.current.close());
    await settle();
    expect(b.vc.micOn, isFalse, reason: 'sanity: a restart is now pending');

    // Enrollment borrows the recorder before the backoff timer fires.
    await b.vc.suspendMic();
    expect(b.vc.debugMicLoaned, isTrue);
    final startsAtLoan = mic.startCalls;

    await Future<void>.delayed(_pastFirstBackoff);
    await settle();

    expect(mic.startCalls, startsAtLoan,
        reason: 'the restart must not open a second session while the '
            'recorder is on loan');
    expect(b.vc.debugMicLoaned, isTrue,
        reason: 'the loan must still be intact');

    // Ending the loan honours the restore, exactly like every other
    // mic-loan test in this suite.
    await b.vc.resumeMic();
    await settle();
    expect(b.vc.micOn, isTrue,
        reason: 'the intent recorded during the loan is honoured once it '
            'ends');
  });
}
