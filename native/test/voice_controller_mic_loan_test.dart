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
}
