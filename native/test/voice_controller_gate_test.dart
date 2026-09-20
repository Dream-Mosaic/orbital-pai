import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/audio/wake_gate.dart';
import 'package:orbital_pai/auth/device_id.dart';
import 'package:orbital_pai/connection/app_connection.dart';
import 'package:orbital_pai/phoenix/decoded_message.dart';
import 'package:orbital_pai/phoenix/phoenix_socket.dart';
import 'package:orbital_pai/voice/voice_controller.dart';
import 'package:stream_channel/stream_channel.dart';

import 'support/fakes.dart';

/// A [DeviceIdStore] that already has a value on disk — stands in for "this
/// device already has a persisted id," so [DeviceId.get] takes the
/// read-and-adopt path deterministically rather than generating a random
/// one this test would then have no way to assert against. `read()` still
/// resolves via a real (if immediate) `Future`, so the join genuinely waits
/// on it rather than the test accidentally exercising a synchronous path.
class _FixedDeviceIdStore implements DeviceIdStore {
  _FixedDeviceIdStore(this.value);
  final String value;
  @override
  Future<String?> read() => Future.value(value);
  @override
  Future<void> write(String value) async {}
}

/// A [DeviceIdStore] whose `read()` NEVER completes — the empirically
/// observed shape of an unmocked `FlutterSecureStorage` read under some
/// bindings (see the Task 4 fix-round-1 report), and the one a fake MUST be
/// able to express: `DeviceId.get()`'s own try/catch is inert against a
/// hang, so a fake that eventually resolves (even slowly) cannot exercise
/// the bug the synchronous-registration fix exists to guard against. The
/// `Completer` is simply never completed, by any caller, for the lifetime
/// of the test.
class _NeverResolvingDeviceIdStore implements DeviceIdStore {
  final Completer<String?> _never = Completer<String?>();
  @override
  Future<String?> read() => _never.future;
  @override
  Future<void> write(String value) async {}
}

/// A [DeviceIdStore] whose `read()` resolves only after a real delay.
/// Deliberately NOT instant: an instantly-resolving fake can race an
/// equally-instant fake connector and happen to land in time whether or not
/// anything actually orders the two — exactly the false confidence a
/// re-review caught in an earlier version of the "sends the resolved
/// device id" test below, which passed by accidental microtask ordering
/// rather than by any real guarantee. A real delay this much longer than a
/// few microtasks means a test relying on EXPLICIT synchronization (an
/// `await` on [VoiceController.deviceIdReady]) still passes, while a test
/// — or a future code change — that drops back to just racing the two
/// would fail for real.
class _DelayedDeviceIdStore implements DeviceIdStore {
  _DelayedDeviceIdStore(this.value);
  final String value;
  @override
  Future<String?> read() => Future.delayed(const Duration(milliseconds: 50), () => value);
  @override
  Future<void> write(String value) async {}
}

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

  /// The payload of the `phx_join` frame this client sent for [topic] — the
  /// only way to see what the constructor's async device-id resolution
  /// actually put on the wire, since `DeviceId.get()` resolves after the
  /// controller is already built.
  Map<String, dynamic>? joinPayload(String topic) {
    for (final f in sent) {
      if (f is! String) continue;
      final p = jsonDecode(f) as List<dynamic>;
      if (p[3] == 'phx_join' && p[2] == topic) {
        return (p[4] as Map).cast<String, dynamic>();
      }
    }
    return null;
  }

  Future<void> kill() => ctrl.foreign.sink.close();
}

/// Builds the pair under test, same shape as the other VoiceController test
/// files' `build()`, plus the spotter/gate seam.
({AppConnection conn, VoiceController vc, FakeSocket fake, FakeMic mic}) build({
  FakeSpotter? spotter,
  WakeGate? gate,
  DeviceId? deviceId,
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
    deviceId: deviceId,
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

  test('disposing a VoiceController disposes ITS spotter for good, not '
      'merely resets it (New 1)', () async {
    // Models the sign-out/sign-in sequence main.dart actually drives:
    // `_teardownShell` calls `_vc?.dispose()` on the outgoing controller,
    // then a fresh sign-in builds a brand new `VoiceController` (and a
    // brand new `SherpaWakeSpotter`) via `_ensureConnection`. If `dispose()`
    // only ever reset the old spotter (what every ordinary mic teardown
    // already does via `_release`/`stop()`), the old ONNX engine would never
    // be freed and would leak for the rest of the process.
    final spotterA = FakeSpotter();
    final a = build(spotter: spotterA);
    addTearDown(a.conn.dispose);
    await a.conn.connect();
    await settle();
    await a.vc.startMic();
    await settle();
    expect(spotterA.disposed, isFalse, reason: 'sanity: alive while in use');

    a.vc.dispose();
    await settle();

    expect(spotterA.disposed, isTrue,
        reason: 'VoiceController.dispose() must free its own spotter, not '
            'merely reset it');
    expect(spotterA.stopCalls, greaterThanOrEqualTo(1),
        reason: 'the ordinary mic-teardown reset (_release) still runs too, '
            'same as any other mic teardown');

    // The NEXT sign-in's controller gets its OWN fresh spotter, entirely
    // unaffected by the first controller's disposal.
    final spotterB = FakeSpotter();
    final b = build(spotter: spotterB);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    await settle();

    expect(spotterB.disposed, isFalse);
    expect(b.vc.micOn, isTrue);
  });

  test('a superseded start does not reset the spotter out from under the '
      'session that replaced it (New 2)', () async {
    // `_spotter` is ONE instance shared by every mic session on this
    // controller, not one per attempt. Session A supersedes itself (via a
    // stop+restart while its own `_spotter.start()` await is still in
    // flight) and must NOT call `_spotter.stop()` on the way out once it
    // resumes — the live session that replaced it (B) may already be
    // decoding, and a stray reset would drop a wake word spoken at exactly
    // that moment.
    final gate = Completer<void>();
    final spotter = FakeSpotter(available: false, loadAfter: gate.future);
    final b = build(spotter: spotter);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();

    // Session A: proceeds up to (and blocks on) `await _spotter.start()`.
    final startingA = b.vc.startMic();
    await settle();

    // Supersede it: a deliberate stop (this is what legitimately resets the
    // spotter once, via `_release`) followed by a fresh start — session B —
    // which reaches the SAME blocking await on the SAME shared spotter.
    await b.vc.stopMic();
    final startingB = b.vc.startMic();
    await settle();
    expect(spotter.stopCalls, 1, reason: 'sanity: only the deliberate stop so far');

    // Release both attempts at once. A resumes first (it awaited first) and
    // must see itself superseded; B resumes and must proceed normally.
    gate.complete();
    await startingA;
    await startingB;
    await settle();

    expect(b.vc.micOn, isTrue, reason: 'session B must have come up normally');
    expect(spotter.stopCalls, 1,
        reason: 'the superseded session A must not call stop() again on its '
            'way out — that would reset the spotter out from under B');
  });

  test('a dispose() during mid-load does not resurrect the spotter once the '
      'load finally resolves', () async {
    // The exact scenario a round-2 fix introduced: VoiceController.dispose()
    // fires `_spotter.dispose()` unawaited while startMic()'s
    // `await _spotter.start()` is still pending — a sign-out during model
    // load. Modelled directly with FakeSpotter's own post-await `disposed`
    // re-check (mirroring SherpaWakeSpotter's real one) rather than via
    // internal null-ness.
    final gate = Completer<void>();
    final spotter = FakeSpotter(available: false, loadAfter: gate.future);
    final b = build(spotter: spotter);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();

    final starting = b.vc.startMic();
    await settle();
    expect(spotter.available, isFalse, reason: 'sanity: still loading');

    // Sign-out lands WHILE the model is still loading.
    b.vc.dispose();
    await settle();
    expect(spotter.disposed, isTrue, reason: 'sanity: the sign-out ran');

    // The load finally finishes, well after dispose() already latched.
    gate.complete();
    await starting;
    await settle();

    expect(spotter.available, isFalse,
        reason: 'a dispose() that lands mid-load must not be resurrected '
            'once the loader resolves — the engine would then leak forever, '
            'since dispose() has already run and will not run again');
  });

  test('sends the resolved device id in the join payload', () async {
    final b = build(deviceId: DeviceId(store: _FixedDeviceIdStore('phone-1')));
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();

    expect(b.fake.joinPayload('voice:henry'), containsPair('device_id', 'phone-1'));
  });

  test(
      'awaiting deviceIdReady before connect() puts the device id in the '
      'FIRST join, deterministically — not by racing a fast store against '
      'a fast connector', () async {
    // A DELAYED store, not the instant one above: this is what makes the
    // test a real regression guard. main.dart's own `_connectOnceDeviceIdKnown`
    // does exactly this — await `deviceIdReady`, THEN `connect()` — and
    // that explicit ordering is what must be pinned, not "it happened to
    // land in time."
    final b = build(deviceId: DeviceId(store: _DelayedDeviceIdStore('phone-1')));
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);

    await b.vc.deviceIdReady;
    await b.conn.connect();
    await settle();

    expect(b.fake.joinPayload('voice:henry'), containsPair('device_id', 'phone-1'));
  });

  test('a device id that resolves after the first join still reaches a LATER join',
      () async {
    // Own multi-socket harness (a fresh FakeSocket per connect()), same
    // shape voice_controller_reconnect_test.dart uses — build()'s harness
    // reuses one socket for the controller's whole life, which can't show
    // a SECOND join's payload.
    final sockets = <FakeSocket>[];
    final conn = AppConnection(
      connector: () async {
        final s = FakeSocket();
        sockets.add(s);
        return s.socket;
      },
      rejoinBackoff: const [Duration(milliseconds: 10)],
    );
    final vc = VoiceController(
      connection: conn,
      mic: FakeMic(),
      player: FakePlayer(),
      spotter: FakeSpotter(),
      gate: WakeGate(),
      deviceId: DeviceId(store: _DelayedDeviceIdStore('phone-3')),
    );
    addTearDown(vc.dispose);
    addTearDown(conn.dispose);

    // Connect WITHOUT waiting for deviceIdReady, unlike the test above — the
    // delayed store has not resolved yet, so this first join is legacy,
    // same as a caller that doesn't do what main.dart's
    // `_connectOnceDeviceIdKnown` does.
    await conn.connect();
    await settle();
    expect(sockets, hasLength(1));
    expect(sockets.first.joinPayload('voice:henry')!.containsKey('device_id'), isFalse,
        reason: 'sanity: the id had not resolved yet when this join went out');

    // Let the device id resolve, then force a reconnect.
    await vc.deviceIdReady;
    await conn.rejoin();
    await settle();

    expect(sockets, hasLength(2), reason: 'sanity: rejoin() actually opened a new socket');
    expect(sockets.last.joinPayload('voice:henry'), containsPair('device_id', 'phone-3'),
        reason: 'the widened payload must reach every join from here on, not just the first');
  });

  test(
      'a wedged device-id store does not block the voice topic from joining',
      () async {
    // A device whose keystore is wedged (empirically: an unmocked
    // FlutterSecureStorage read that never completes at all, not merely
    // slowly — see the Task 4 fix-round-1 report) must not leave
    // `voice:henry` unregistered: the topic is now registered SYNCHRONOUSLY
    // in the constructor with a legacy (no device_id) payload, and the
    // device id is layered on afterward as a pure side task nothing else
    // depends on — so a store that never resolves at all costs nothing but
    // the enrichment itself. No waiting required: if this regresses to the
    // old "await the device id before registering" shape, this join simply
    // never happens, with or without a delay.
    final b = build(deviceId: DeviceId(store: _NeverResolvingDeviceIdStore()));
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();

    final payload = b.fake.joinPayload('voice:henry');
    expect(payload, isNotNull,
        reason: 'a wedged device-id store must not block the voice join forever');
    expect(payload!.containsKey('device_id'), isFalse,
        reason: 'a legacy join with no device_id is valid and binds normally — the server '
            'treats a nil id as today\'s behaviour, not as broken');
  });

  test('the bound push closes the sink', () async {
    final b = build();
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    await settle();

    b.vc.debugHandleMessage(const DecodedMessage(
      topic: 'voice:henry',
      event: 'bound',
      json: {'bound': false},
    ));

    b.mic.emit(chunk(320));
    await settle();

    expect(b.fake.binaryFrames, isEmpty);
  });

  test('bound in the state snapshot also closes the sink', () async {
    final b = build();
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    await settle();

    // The reconnect path: `bound` arrives inside `state`, not as a `bound`
    // event.
    b.vc.debugHandleMessage(const DecodedMessage(
      topic: 'voice:henry',
      event: 'state',
      json: {'bound': false},
    ));

    b.mic.emit(chunk(320));
    await settle();

    expect(b.fake.binaryFrames, isEmpty,
        reason: 'the snapshot is the reconnect path; a gate wired only to the event desyncs');
  });

  test('regaining bound reopens the sink', () async {
    final b = build();
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    await settle();

    b.vc.debugHandleMessage(const DecodedMessage(
      topic: 'voice:henry',
      event: 'bound',
      json: {'bound': false},
    ));
    b.vc.debugHandleMessage(const DecodedMessage(
      topic: 'voice:henry',
      event: 'bound',
      json: {'bound': true},
    ));

    b.mic.emit(chunk(320));
    await settle();

    expect(b.fake.binaryFrames, isNotEmpty);
  });

  test('an absent bound key in a later state snapshot does not clobber a known standby state',
      () async {
    final b = build();
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    await settle();

    b.vc.debugHandleMessage(const DecodedMessage(
      topic: 'voice:henry',
      event: 'bound',
      json: {'bound': false},
    ));
    // A later snapshot that says nothing about `bound` must not silently
    // reopen a gate the server explicitly closed — same idiom as the
    // existing `locked` handling.
    b.vc.debugHandleMessage(const DecodedMessage(
      topic: 'voice:henry',
      event: 'state',
      json: {'locked': false},
    ));

    b.mic.emit(chunk(320));
    await settle();

    expect(b.fake.binaryFrames, isEmpty,
        reason: 'an absent bound key must not clobber what the client already knows');
  });

  test(
      'a standby device still pushes wake_detected on a spotter hit — the '
      'single hop the whole handoff feature rests on', () async {
    // This is the claim mechanism: a standby device's local keyword spotter
    // must keep announcing a wake hit to the server even though `bound:
    // false` keeps ITS OWN gate closed (see WakeGate.open's `_bound &&`
    // doc). A plausible-looking `if (!_bound) return;` guard here would make
    // handoff impossible without turning anything else red.
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
      event: 'bound',
      json: {'bound': false},
    ));
    b.mic.emit(chunk(320));
    await settle();

    spotter.fireNext = true;
    b.mic.emit(chunk(320));
    await settle();

    expect(b.fake.sentEvents.where((e) => e == 'wake_detected'), hasLength(1),
        reason: 'a standby device claims the conversation by pushing '
            'wake_detected even though bound keeps its own sink closed');
    expect(b.fake.binaryFrames, isEmpty,
        reason: 'sanity: still standby — a wake hit must not have opened '
            'this device\'s own audio sink');
  });

  /// The event-named JSON pushes this client sent to [topic], decoded, in
  /// order — unlike [FakeSocket.sentEvents] this keeps the payload, needed
  /// to tell a `ptt: true` push apart from a `ptt: false` one.
  List<Map<String, dynamic>> pushesOf(FakeSocket fake, String event) => fake.sent
      .whereType<String>()
      .map((f) => jsonDecode(f) as List<dynamic>)
      .where((p) => p[3] == event)
      .map((p) => (p[4] as Map).cast<String, dynamic>())
      .toList();

  test('the join declares no camera, so the server never holds a turn for one (issue #5)',
      () async {
    final b = build();
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    expect(b.fake.joinPayload('voice:henry'), containsPair('vision', false));
  });

  test('a stray capture_frame is answered with an empty frame, not ignored', () async {
    // Defence in depth behind the join flag: an older server (or one that
    // ever forgets the flag) must get an immediate "no camera" back rather
    // than wait out its vision timeout with the brain held.
    final b = build();
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();

    b.vc.debugHandleMessage(const DecodedMessage(
      topic: 'voice:henry',
      event: 'capture_frame',
      json: {'ref': 7},
    ));
    await settle();

    final frames = pushesOf(b.fake, 'vision_frame');
    expect(frames, hasLength(1));
    expect(frames.single, {'ref': 7, 'data': null, 'error': 'no_camera'});
  });

  test('tapping the Ack chip pushes ack_reminder to the server (issue #4)',
      () async {
    // The chip used to flip local state only: the reminder stayed due on the
    // server, the badge stayed lit, and the nudge re-asked on the next
    // connect. The push has to ride voice:henry -- panel:reminders is only
    // joined while the drawer is open.
    final b = build();
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();

    b.vc.debugHandleMessage(const DecodedMessage(
      topic: 'voice:henry',
      event: 'speak_start',
      json: {'source': 'reminder', 'text': 'bins out'},
    ));
    b.vc.debugHandleMessage(const DecodedMessage(
      topic: 'voice:henry',
      event: 'reminder_ack_offer',
      json: {'id': 42},
    ));
    b.vc.ackReminder(42);
    await settle();

    final acks = pushesOf(b.fake, 'ack_reminder');
    expect(acks, hasLength(1));
    expect(acks.single['id'], 42);
  });

  test(
      'regaining bound re-announces this device\'s toggles — a standby ptt '
      'press must not claim into a server still running auto mode',
      () async {
    // The server drops control casts from a non-bound client
    // (conversation.ex), so a standby device's `ptt: true` sent at join
    // time never reached it. Without a re-announce on the transition, the
    // claiming PTT press leaves the server on the auto Ink-2 endpoint, so
    // `ptt_release`'s `finalize` is a no-op.
    final b = build();
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();

    // Enabled AFTER the join's own announce, so the join's `ptt: false` is
    // distinguishable from what the bound transition sends.
    b.vc.setPtt(true);
    await settle();

    b.vc.debugHandleMessage(const DecodedMessage(
      topic: 'voice:henry',
      event: 'bound',
      json: {'bound': false},
    ));
    await settle();
    b.vc.debugHandleMessage(const DecodedMessage(
      topic: 'voice:henry',
      event: 'bound',
      json: {'bound': true},
    ));
    await settle();

    final pttPushes = pushesOf(b.fake, 'ptt');
    expect(pttPushes.last['enabled'], isTrue,
        reason: 'the transition back to bound must re-send the CURRENT '
            'toggle state, not the join-time default');
    expect(pttPushes.length, 3,
        reason: 'join announce (ptt: false) + setPtt(true) + the '
            're-announce on regaining bound');
  });

  test('a controller told bound: true twice does not spam a re-announce',
      () async {
    // The cold-start path emits two `state` pushes, both `bound: true` —
    // only a real false→true transition may re-announce.
    final b = build();
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();

    final beforeCount = pushesOf(b.fake, 'ptt').length;

    b.vc.debugHandleMessage(const DecodedMessage(
      topic: 'voice:henry',
      event: 'bound',
      json: {'bound': true},
    ));
    await settle();
    b.vc.debugHandleMessage(const DecodedMessage(
      topic: 'voice:henry',
      event: 'bound',
      json: {'bound': true},
    ));
    await settle();

    expect(pushesOf(b.fake, 'ptt').length, beforeCount,
        reason: 'a redundant bound: true must not re-send toggles that were '
            'never dropped in the first place');
  });

  test('a standby device\'s PTT press does not stream — bound closes the '
      'sink even while PTT is held', () async {
    final b = build();
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    await settle();

    b.vc.debugHandleMessage(const DecodedMessage(
      topic: 'voice:henry',
      event: 'bound',
      json: {'bound': false},
    ));
    b.vc.setPtt(true);
    b.vc.pttPress();

    b.mic.emit(chunk(320));
    await settle();

    expect(b.fake.binaryFrames, isEmpty,
        reason: 'a standby device\'s PTT press is a claim, not proof it already holds the '
            'conversation — it must not stream until the server answers bound: true');
  });
}
