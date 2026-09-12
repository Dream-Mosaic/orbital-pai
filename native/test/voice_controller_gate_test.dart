import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/audio/wake_gate.dart';
import 'package:orbital_pai/connection/app_connection.dart';
import 'package:orbital_pai/phoenix/decoded_message.dart';
import 'package:orbital_pai/phoenix/phoenix_socket.dart';
import 'package:orbital_pai/voice/voice_controller.dart';
import 'package:stream_channel/stream_channel.dart';

import 'support/fakes.dart';

// Harness copied from voice_controller_reconnect_test.dart / mic_loan_test's
// FakeSocket/build shape (own copy, so this file has no compile-time
// dependency on another test file's `main()`), extended with the
// spotter/gate seam Task 5 adds to the constructor.

/// One in-memory Phoenix socket: answers `phx_join` and lets a test read back
/// what the client sent.
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

  /// The event names this client put on the wire as JSON pushes, in order —
  /// `wake_detected` included, since that rides the JSON channel, not the
  /// binary one.
  List<String> get sentEvents => sent
      .whereType<String>()
      .map((f) => (jsonDecode(f) as List<dynamic>)[3] as String)
      .toList();

  Future<void> kill() => ctrl.foreign.sink.close();
}

/// Builds the pair under test, same shape as the other VoiceController test
/// files' `build()`, plus the spotter/gate seam.
({AppConnection conn, VoiceController vc, FakeSocket fake, FakeMic mic}) build({
  FakeSpotter? spotter,
  WakeGate? gate,
}) {
  final fake = FakeSocket();
  final mic = FakeMic();
  final conn = AppConnection(connector: () async => fake.socket);
  final vc = VoiceController(
    connection: conn,
    mic: mic,
    player: FakePlayer(),
    spotter: spotter ?? FakeSpotter(),
    gate: gate ?? WakeGate(),
  );
  return (conn: conn, vc: vc, fake: fake, mic: mic);
}

/// A 16 kHz mono PCM16 chunk of [bytes] bytes, contents irrelevant — the
/// gate and the fake spotter don't inspect the samples, only the frame's
/// presence and size.
Uint8List chunk(int bytes) => Uint8List(bytes);

void main() {
  test('while locked, no audio reaches the socket', () async {
    final b = build();
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    await settle();

    b.vc.debugHandleMessage(const DecodedMessage(
      topic: 'voice:henry',
      event: 'locked',
      json: {'locked': true},
    ));

    b.mic.emit(chunk(320));
    await settle();

    expect(b.fake.binaryFrames, isEmpty);
  });

  test('a spotter detection pushes wake_detected exactly once and opens the sink',
      () async {
    final spotter = FakeSpotter();
    final b = build(spotter: spotter);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    await settle();

    b.vc.debugHandleMessage(const DecodedMessage(
      topic: 'voice:henry',
      event: 'locked',
      json: {'locked': true},
    ));
    b.mic.emit(chunk(320));
    await settle();

    spotter.fireNext = true;
    b.mic.emit(chunk(320));
    await settle();

    expect(b.fake.sentEvents.where((e) => e == 'wake_detected'), hasLength(1));
    expect(b.fake.binaryFrames, isNotEmpty);

    b.mic.emit(chunk(320));
    await settle();
    expect(b.fake.sentEvents.where((e) => e == 'wake_detected'), hasLength(1),
        reason: 'already unlocked — do not re-push');
  });

  test('with no spotter available the sink stays open — fail open, never deaf',
      () async {
    final b = build(spotter: FakeSpotter(available: false));
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    await settle();

    b.vc.debugHandleMessage(const DecodedMessage(
      topic: 'voice:henry',
      event: 'locked',
      json: {'locked': true},
    ));
    b.mic.emit(chunk(320));
    await settle();

    expect(b.fake.binaryFrames, isNotEmpty);
  });

  test('a reconnect state snapshot re-syncs the gate', () async {
    final b = build();
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    await settle();

    // The reconnect path: `locked` arrives inside `state`, not as a `locked`
    // event.
    b.vc.debugHandleMessage(const DecodedMessage(
      topic: 'voice:henry',
      event: 'state',
      json: {'locked': true},
    ));
    b.mic.emit(chunk(320));
    await settle();

    expect(b.fake.binaryFrames, isEmpty,
        reason: 'a gate wired only to the locked event desyncs after every reconnect');
  });

  test('ptt while locked opens the sink', () async {
    final b = build();
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    await settle();

    b.vc.debugHandleMessage(const DecodedMessage(
      topic: 'voice:henry',
      event: 'locked',
      json: {'locked': true},
    ));
    b.vc.setPtt(true);
    b.vc.pttPress();

    b.mic.emit(chunk(320));
    await settle();

    expect(b.fake.binaryFrames, isNotEmpty);
  });

  test('the mic listener keeps feeding the spotter across an auto-restart',
      () async {
    // Task 1's mic auto-restart must not leave the spotter permanently
    // stopped: startMic() calls _spotter.start() every time it actually
    // (re)acquires a session, auto-restart included.
    final spotter = FakeSpotter();
    final b = build(spotter: spotter);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    await settle();
    expect(spotter.startCalls, 1);

    // The platform ends the stream without being asked (audio focus, a
    // revoked permission, ...): the same path _onMicStreamEnded/backoff use.
    await b.mic.current.close();
    await settle();
    expect(b.vc.micOn, isFalse);

    await Future<void>.delayed(VoiceController.micRestartBackoff.first);
    await settle();

    expect(b.vc.micOn, isTrue, reason: 'the backoff must re-arm the mic');
    expect(spotter.startCalls, 2,
        reason: 'the spotter must restart alongside the recorder, not stay dead');

    b.mic.emit(chunk(320));
    await settle();
    expect(spotter.offerCalls, greaterThan(0),
        reason: 'the restarted session must actually feed the spotter');
  });

  test('a lock that arrives before the spotter finishes loading still gates '
      'once loading completes (Critical 1)', () async {
    // The server pushes `state` (with `locked`) on every (re)bind, milliseconds
    // after join — before the mic is ever asked to start, and therefore before
    // the on-device model has even begun loading. `FakeSpotter(available:
    // false, loadAfter: ...)` is what lets this test express "not yet loaded",
    // unlike a constant-true fake, which made this exact defect invisible.
    final spotter = FakeSpotter(available: false, loadAfter: Future<void>.value());
    final b = build(spotter: spotter);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    expect(spotter.available, isFalse, reason: 'sanity: not loaded yet');

    b.vc.debugHandleMessage(const DecodedMessage(
      topic: 'voice:henry',
      event: 'state',
      json: {'locked': true},
    ));

    await b.vc.startMic();
    await settle();
    expect(spotter.available, isTrue,
        reason: 'sanity: loaded by the time startMic() returns');

    b.mic.emit(chunk(320));
    await settle();

    expect(b.fake.binaryFrames, isEmpty,
        reason: 'the lock recorded while the spotter was still loading must '
            'not be lost — there is no later event that replays it');
  });

  test('a wedged spotter load does not permanently brick startMic() '
      '(Critical 2)', () async {
    // The spotter's start() never resolves — a wedged ONNX/asset loader.
    // startMic()'s await on it must be BOUNDED, or `_micState` sticks at
    // `wanted` forever: no subscription, no restart, permanently deaf.
    final spotter = FakeSpotter(available: false, loadAfter: Completer<void>().future);
    final b = build(spotter: spotter);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();

    final starting = b.vc.startMic();
    await starting.timeout(const Duration(seconds: 10),
        onTimeout: () => fail('startMic() never returned — the spotter '
            'start() await must be bounded, not a bare `await`'));
    await settle();

    expect(b.vc.micOn, isTrue,
        reason: 'a wedged spotter load must not prevent the mic from coming up');
    expect(spotter.available, isFalse, reason: 'sanity: still never loaded');

    // Fail open: the spotter never became available, so audio must still flow.
    b.mic.emit(chunk(320));
    await settle();
    expect(b.fake.binaryFrames, isNotEmpty);
  });
}
