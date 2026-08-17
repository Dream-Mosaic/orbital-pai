import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/connection/app_connection.dart';
import 'package:henry_wall/panels/voice_lock_client.dart';
import 'package:henry_wall/voice/voice_controller.dart';

import '../support/fake_socket.dart';
import '../support/fakes.dart';

/// The microphone loan across its REAL seam: the real [VoiceLockClient]
/// driving the real [VoiceController], wired exactly as `main.dart` wires
/// them (`acquireMic: vc.suspendMic`, `releaseMic: vc.resumeMic`).
///
/// Every other test of this contract injects lambdas on one side or the other,
/// so the contract itself — "the borrower's `finally` is the one thing that
/// gives the conversation its microphone back" — had no test at all. Both the
/// end-to-end form of the sixth Critical and Important 4 live precisely here.
const String _stateFrame = '[null,null,"panel:voice_lock:henry","state",'
    '{"user_id":7,"mode":"shadow","enrolled_slots":[],'
    '"verifier_ready":true,"drops":[]}]';

({AppConnection conn, VoiceController vc, VoiceLockClient client, FakeSocket fake})
    build({required FakeMic mic, Duration? acquireTimeout}) {
  final fake = FakeSocket(
      joinPushes: const {'panel:voice_lock:henry': _stateFrame});
  final conn = AppConnection(
    connector: () async => fake.socket,
    rejoinBackoff: const [Duration(days: 1)],
  );
  final vc = VoiceController(connection: conn, mic: mic, player: FakePlayer());
  final client = VoiceLockClient(
    connection: conn,
    acquireMic: vc.suspendMic,
    releaseMic: vc.resumeMic,
    clipLimit: const Duration(milliseconds: 30),
    replyTimeout: const Duration(milliseconds: 30),
    teardownTimeout: const Duration(milliseconds: 300),
    acquireTimeout: acquireTimeout ?? const Duration(milliseconds: 60),
  );
  return (conn: conn, vc: vc, client: client, fake: fake);
}

/// Take delivery of the errors a test deliberately provokes, so a reported
/// platform failure does not fail the test that asked for it.
void captureFlutterErrors() {
  final original = FlutterError.onError;
  FlutterError.onError = (_) {};
  addTearDown(() => FlutterError.onError = original);
}

void main() {
  test('a whole enrollment clip borrows the conversation mic and gives it '
      'back', () async {
    final mic = FakeMic();
    final b = build(mic: mic);
    addTearDown(() {
      b.client.dispose();
      b.vc.dispose();
      b.conn.dispose();
    });

    await b.conn.connect();
    b.client.open();
    await pumpEventQueue();
    await b.vc.startMic();
    expect(b.vc.micOn, isTrue, reason: 'sanity: the conversation has the mic');

    final recording = b.client.startRecording(1);
    await pumpEventQueue();
    expect(b.vc.debugMicLoaned, isTrue,
        reason: 'the real suspendMic ran through the real acquireMic seam');
    expect(b.vc.micOn, isFalse,
        reason: 'reading an enrollment prompt aloud must not become a turn');
    expect(b.fake.joinedTopics, contains('enroll:7'));

    // The clip's own audio must reach enroll:7 and nothing else.
    b.fake.sent.clear();
    mic.emit(Uint8List.fromList(const [1, 2, 3, 4]));
    await pumpEventQueue();
    expect(b.fake.binaryFrames, isNotEmpty);

    b.client.close(); // the drawer is dismissed; the clip aborts
    await recording.timeout(const Duration(seconds: 2));
    await settle();

    expect(b.vc.debugMicLoaned, isFalse);
    expect(b.vc.micOn, isTrue,
        reason: 'the borrower\'s finally is the only thing that gives the '
            'conversation its microphone back');
    expect(mic.isRecording, isTrue,
        reason: 'and the indicator must not be the only thing that came back');
  });

  test('an acquire that times out on a wedged recorder still leaves the '
      'conversation hearing', () async {
    // THE SIXTH CRITICAL, end to end and through the real seam. Measured
    // before the fix, with this exact shape: `micOn=true isRecording=false`,
    // `enrollError=(slot, 'failed: mic_blocked')`, and nothing wrong in the
    // log — a wall device deaf, its indicator saying "listening", needing two
    // deliberate power taps to recover.
    captureFlutterErrors();
    final mic = FakeMic(
      // The conversation's own session will not stop. suspendMic therefore
      // cannot hand the borrowed stream over in time, and the borrower's
      // acquireTimeout fires while the suspend is genuinely still in flight.
      stopBehaviour: const [FakeCall.hangs],
      platformTimeout: const Duration(milliseconds: 40),
    );
    final b = build(mic: mic, acquireTimeout: const Duration(milliseconds: 20));
    addTearDown(() {
      b.client.dispose();
      b.vc.dispose();
      b.conn.dispose();
    });

    await b.conn.connect();
    b.client.open();
    await pumpEventQueue();
    await b.vc.startMic();
    expect(b.vc.micOn, isTrue);

    await b.client.startRecording(1).timeout(const Duration(seconds: 3));
    // Let the wedged stop give up and the restore's own open land behind it.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await settle();

    expect(b.client.enrollError, (1, 'failed: mic_blocked'),
        reason: 'sanity: the acquire really did time out');
    expect(b.client.recordingSlot, isNull,
        reason: 'sanity: the Record buttons are usable again');
    expect(b.vc.micOn, isTrue,
        reason: 'a failed enrollment must not cost the user their microphone');
    expect(mic.isRecording, isTrue,
        reason: 'and micOn must not be the only thing that recovered');
    expect(mic.recorder.startedOnLiveRecorder, isFalse);
    expect(mic.maxConcurrentStarts, 1);

    b.fake.sent.clear();
    mic.emit(Uint8List.fromList(const [8, 8, 8, 8]));
    await settle();
    expect(b.fake.binaryFrames, isNotEmpty,
        reason: 'the decisive assertion: the assistant can actually hear');
  });
}
