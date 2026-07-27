import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/audio/audio_track_player.dart';
import 'package:henry_wall/audio/mic_capture.dart';
import 'package:henry_wall/meridian/orb_state.dart';
import 'package:henry_wall/phoenix/decoded_message.dart';
import 'package:henry_wall/phoenix/phoenix_channel_client.dart';
import 'package:henry_wall/voice/voice_controller.dart';
import 'package:stream_channel/stream_channel.dart';

/// How the fake server answers `phx_join`. `none` is the case that used to
/// brick the client: the socket is up, the reply never comes.
enum JoinReply { ok, error, none }

/// One in-memory Phoenix socket: answers the join (or refuses it, or stays
/// silent), lets a test push server events, and can be killed to simulate a
/// server bounce.
class FakeSocket {
  FakeSocket({
    this.joinReply = JoinReply.ok,
    Duration heartbeat = const Duration(days: 1),
  }) {
    ctrl.foreign.stream.listen(sent.add, onDone: () => localClosed = true);
    client = PhoenixChannelClient(
      ctrl.local,
      topic: 'voice:henry',
      joinPayload: const {'kiosk': false},
      heartbeatInterval: heartbeat,
    );
    client.start();
    scheduleMicrotask(() {
      if (localClosed) return;
      switch (joinReply) {
        case JoinReply.ok:
          ctrl.foreign.sink.add(
              '["1","1","voice:henry","phx_reply",{"status":"ok","response":{}}]');
        case JoinReply.error:
          ctrl.foreign.sink.add('["1","1","voice:henry","phx_reply",'
              '{"status":"error","response":{"reason":"unauthorized"}}]');
        case JoinReply.none:
          break;
      }
    });
  }

  final JoinReply joinReply;
  final StreamChannelController<dynamic> ctrl = StreamChannelController<dynamic>();
  final List<dynamic> sent = <dynamic>[];
  late final PhoenixChannelClient client;
  bool localClosed = false;

  void push(String event, String jsonPayload) =>
      ctrl.foreign.sink.add('[null,null,"voice:henry","$event",$jsonPayload]');

  Future<void> kill() => ctrl.foreign.sink.close();
}

/// Headless MicCapture. `implements` (not `extends`) so no AudioRecorder — and
/// therefore no platform channel — is ever constructed.
class FakeMic implements MicCapture {
  FakeMic({this.startDelay = Duration.zero}) {
    _chunks = StreamController<Uint8List>(
      onListen: () => listening = true,
      onCancel: () => cancelled = true,
    );
  }

  final Duration startDelay;
  late final StreamController<Uint8List> _chunks;
  int startCalls = 0;
  int stopCalls = 0;
  bool listening = false;
  bool cancelled = false;
  bool _recording = false;

  @override
  bool get isRecording => _recording;

  @override
  Future<Stream<Uint8List>> start() async {
    startCalls++;
    if (startDelay > Duration.zero) await Future<void>.delayed(startDelay);
    _recording = true;
    return _chunks.stream;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _recording = false;
  }
}

/// Headless AudioTrackPlayer (the real one is a MethodChannel facade).
class FakePlayer implements AudioTrackPlayer {
  FakePlayer({this.failInit = false});

  final bool failInit;
  int initCalls = 0;
  int disposeCalls = 0;
  final List<Uint8List> writes = <Uint8List>[];

  @override
  Future<void> init(int sampleRate) async {
    initCalls++;
    if (failInit) throw StateError('no audio device');
  }

  @override
  Future<void> write(Uint8List pcm) async => writes.add(pcm);

  @override
  Future<int> stopAndFlush() async => 0;

  @override
  Future<int> playedMs() async => 0;

  @override
  Future<void> setVolume(double v) async {}

  @override
  Future<void> dispose() async => disposeCalls++;
}

Future<void> settle([int turns = 8]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('the state snapshot re-derives turnState from `phase`', () async {
    final vc = VoiceController();
    addTearDown(vc.dispose);
    vc.debugSetTalking(true);

    vc.debugHandleMessage(const DecodedMessage(
      topic: 'voice:henry',
      event: 'state',
      json: {'phase': 'busy', 'locked': false},
    ));
    expect(vc.orbState, OrbState.thinking,
        reason: 'index.js:268 derives turnState from the snapshot; we dropped `phase`');

    vc.debugHandleMessage(const DecodedMessage(
      topic: 'voice:henry',
      event: 'state',
      json: {'phase': 'listening', 'locked': false},
    ));
    expect(vc.orbState, OrbState.idle);
  });

  test('an absent `phase` cannot clobber the current turn state', () async {
    final vc = VoiceController();
    addTearDown(vc.dispose);
    vc.debugSetTalking(true);
    vc.debugApplyEvent('speaking');

    vc.debugHandleMessage(const DecodedMessage(
      topic: 'voice:henry',
      event: 'state',
      json: {'locked': false},
    ));
    expect(vc.orbState, OrbState.speaking);
  });

  test('a dead socket resets the orb instead of lying', () async {
    final fake = FakeSocket();
    final vc = VoiceController(
      connector: () async => fake.client,
      rejoinBackoff: const [Duration(days: 1)], // never actually retries here
      mic: FakeMic(),
      player: FakePlayer(),
    );
    addTearDown(vc.dispose);

    await vc.connect();
    expect(vc.state, ConnState.joined);
    vc.debugSetTalking(true);
    vc.debugApplyEvent('speaking');
    expect(vc.orbState, OrbState.speaking);

    await fake.kill();
    await settle();

    expect(vc.orbState, OrbState.off,
        reason: 'a server bounce must not leave the orb stuck on its last colour');
    expect(vc.talking, isFalse);
  });

  test('a dead socket stops the mic and cancels its subscription', () async {
    final mic = FakeMic();
    final fake = FakeSocket();
    final vc = VoiceController(
      connector: () async => fake.client,
      rejoinBackoff: const [Duration(days: 1)],
      mic: mic,
      player: FakePlayer(),
    );
    addTearDown(vc.dispose);

    await vc.connect();
    await vc.startMic();
    expect(vc.micOn, isTrue);
    expect(mic.listening, isTrue);

    await fake.kill();
    await settle();

    expect(vc.micOn, isFalse);
    expect(mic.stopCalls, greaterThan(0),
        reason: 'the mic was streaming into a socket that no longer exists');
    expect(mic.cancelled, isTrue,
        reason: '_micSub must be cancelled, not merely dropped');
  });

  test('a dead socket closes its client instead of leaking the heartbeat', () async {
    final fake = FakeSocket();
    final vc = VoiceController(
      connector: () async => fake.client,
      rejoinBackoff: const [Duration(days: 1)],
      mic: FakeMic(),
      player: FakePlayer(),
    );
    addTearDown(vc.dispose);

    await vc.connect();
    expect(fake.client.debugHeartbeatActive, isTrue);

    await fake.kill();
    await settle();

    // Note: localClosed can't prove this — StreamChannel.withGuarantees closes
    // the local sink by itself when the stream dies. The heartbeat timer is the
    // thing only close() can cancel, and on a real WebSocketChannel a leaked one
    // keeps calling sink.add on a dead socket every 30s forever.
    expect(fake.client.debugHeartbeatActive, isFalse,
        reason: 'a dropped-but-unclosed client leaks its heartbeat Timer.periodic');
  });

  test('a dead socket schedules a rejoin that reconnects', () async {
    final sockets = <FakeSocket>[];
    final vc = VoiceController(
      connector: () async {
        final s = FakeSocket();
        sockets.add(s);
        return s.client;
      },
      rejoinBackoff: const [Duration(milliseconds: 10)],
      mic: FakeMic(),
      player: FakePlayer(),
    );
    addTearDown(vc.dispose);

    await vc.connect();
    expect(sockets, hasLength(1));

    await sockets.first.kill();
    await settle();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await settle();

    expect(sockets, hasLength(2), reason: 'PhoenixChannelClient has no rejoin of its own');
    expect(vc.state, ConnState.joined);
  });

  test('rejoin() replaces the client without the old one scheduling a retry', () async {
    final sockets = <FakeSocket>[];
    final vc = VoiceController(
      connector: () async {
        final s = FakeSocket();
        sockets.add(s);
        return s.client;
      },
      rejoinBackoff: const [Duration(milliseconds: 10)],
      mic: FakeMic(),
      player: FakePlayer(),
    );
    addTearDown(vc.dispose);

    await vc.connect();
    await vc.rejoin();
    await settle();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await settle();

    expect(sockets, hasLength(2),
        reason: 'the superseded socket\'s onDone must be ignored, not retried');
    expect(sockets.first.localClosed, isTrue);
    expect(vc.state, ConnState.joined);
  });

  test('dispose() during connect() closes the socket it was awaiting', () async {
    late FakeSocket fake;
    final vc = VoiceController(
      connector: () async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        fake = FakeSocket();
        return fake.client;
      },
      mic: FakeMic(),
      player: FakePlayer(),
    );

    final connecting = vc.connect();
    vc.dispose();
    await connecting;
    await settle();

    expect(fake.localClosed, isTrue,
        reason: 'a dispose inside the await used to leak an open socket forever');
  });

  test('dispose() during mic start leaves no live recorder', () async {
    final mic = FakeMic(startDelay: const Duration(milliseconds: 20));
    final fake = FakeSocket();
    final vc = VoiceController(
      connector: () async => fake.client,
      rejoinBackoff: const [Duration(days: 1)],
      mic: mic,
      player: FakePlayer(),
    );

    await vc.connect();
    final starting = vc.startMic();
    vc.dispose();
    await starting;
    await settle();

    expect(mic.isRecording, isFalse,
        reason: 'a dispose inside MicCapture.start() must stop the recorder it opened');
    expect(mic.listening, isFalse,
        reason: 'subscribing post-dispose leaves a recorder nothing will ever stop');
  });

  test('disconnect() during an in-flight join does not brick connect()', () async {
    // CRITICAL 1: the transport dies (here: the user taps Disconnect) between
    // WS-ready and the join ack. The onJoin completer had no failure path, so
    // connect() parked forever, its finally never ran, and `_connecting` stayed
    // true — which no-ops every later connect() for the life of the app.
    final sockets = <FakeSocket>[];
    final vc = VoiceController(
      connector: () async {
        final s = FakeSocket(
            joinReply: sockets.isEmpty ? JoinReply.none : JoinReply.ok);
        sockets.add(s);
        return s.client;
      },
      rejoinBackoff: const [Duration(days: 1)],
      mic: FakeMic(),
      player: FakePlayer(),
    );
    addTearDown(vc.dispose);

    final parked = vc.connect();
    await settle();
    expect(vc.state, ConnState.connecting);

    await vc.disconnect();
    await parked.timeout(const Duration(seconds: 2),
        onTimeout: () => fail('connect() never resolved — _connecting is latched'));
    await settle();

    await vc.connect().timeout(const Duration(seconds: 2),
        onTimeout: () => fail('the second connect() never resolved'));
    expect(sockets, hasLength(2),
        reason: 'the second connect() must actually reach the connector');
    expect(vc.state, ConnState.joined);
  });

  test('rejoin() during an in-flight join recovers instead of bricking', () async {
    // Same defect, second trigger: rejoin() closes the very socket the parked
    // connect() is awaiting.
    final sockets = <FakeSocket>[];
    final vc = VoiceController(
      connector: () async {
        final s = FakeSocket(
            joinReply: sockets.isEmpty ? JoinReply.none : JoinReply.ok);
        sockets.add(s);
        return s.client;
      },
      rejoinBackoff: const [Duration(milliseconds: 10)],
      mic: FakeMic(),
      player: FakePlayer(),
    );
    addTearDown(vc.dispose);

    final parked = vc.connect();
    await settle();
    await vc.rejoin();
    await parked.timeout(const Duration(seconds: 2),
        onTimeout: () => fail('connect() never resolved — _connecting is latched'));
    await settle();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await settle();

    expect(vc.state, ConnState.joined);
  });

  test('a server that never answers phx_join cannot park connect() forever', () async {
    // The belt-and-braces half of CRITICAL 1: socket up, no reply, no death.
    final fake = FakeSocket(joinReply: JoinReply.none);
    final vc = VoiceController(
      connector: () async => fake.client,
      rejoinBackoff: const [Duration(days: 1)],
      joinTimeout: const Duration(milliseconds: 30),
      mic: FakeMic(),
      player: FakePlayer(),
    );
    addTearDown(vc.dispose);

    await vc.connect().timeout(const Duration(seconds: 2),
        onTimeout: () => fail('an unanswered join parked connect() forever'));
    await settle();

    expect(vc.state, ConnState.error);
    expect(fake.localClosed, isTrue,
        reason: 'the timed-out socket must not be left open');
  });

  test('a rejected join closes the socket instead of leaking one per retry', () async {
    // CRITICAL 2: Phoenix does NOT close the socket when a channel join is
    // refused (expired token / off the allowlist), so every backoff retry used
    // to strand a live socket and its heartbeat timer.
    final sockets = <FakeSocket>[];
    final vc = VoiceController(
      connector: () async {
        final s = FakeSocket(
          joinReply: JoinReply.error,
          heartbeat: const Duration(milliseconds: 15),
        );
        sockets.add(s);
        return s.client;
      },
      rejoinBackoff: const [Duration(milliseconds: 10)],
      mic: FakeMic(),
      player: FakePlayer(),
    );
    addTearDown(vc.dispose);

    await vc.connect();
    await settle();
    expect(vc.state, ConnState.error);
    expect(sockets.first.localClosed, isTrue,
        reason: 'the refused socket stays open unless we close it ourselves');
    expect(sockets.first.client.debugHeartbeatActive, isFalse);

    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(sockets.length, greaterThan(1), reason: 'the backoff must keep retrying');

    // Stop the chain before taking the census, so a retry that fired on the way
    // into the assertion can't be counted while its close is still in flight.
    await vc.disconnect();
    await settle();
    expect(sockets.where((s) => !s.localClosed), isEmpty,
        reason: 'every retry used to leak a live socket + heartbeat timer');
  });

  test('a failing audio player does not feed the reconnect loop', () async {
    // IMPORTANT 2: init() throwing used to land in connect()'s catch → error →
    // rejoin → init throws again → forever (leaking a socket each pass).
    final sockets = <FakeSocket>[];
    final vc = VoiceController(
      connector: () async {
        final s = FakeSocket();
        sockets.add(s);
        return s.client;
      },
      rejoinBackoff: const [Duration(milliseconds: 10)],
      mic: FakeMic(),
      player: FakePlayer(failInit: true),
    );
    addTearDown(vc.dispose);

    await vc.connect();
    expect(vc.state, ConnState.joined,
        reason: 'audio output is best-effort; a dead speaker is not a dead session');

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(sockets, hasLength(1),
        reason: 'a platform audio failure must never drive the reconnect machine');
  });

  test('_onMessage routes the literal event strings the server sends', () async {
    final vc = VoiceController();
    addTearDown(vc.dispose);
    vc.debugSetTalking(true);

    vc.debugHandleMessage(const DecodedMessage(
      topic: 'voice:henry',
      event: 'partial',
      json: {'text': 'hello there'},
    ));
    expect(vc.caption, 'hello there');

    vc.debugHandleMessage(const DecodedMessage(
      topic: 'voice:henry',
      event: 'thinking',
      json: {},
    ));
    expect(vc.orbState, OrbState.thinking);

    vc.debugHandleMessage(const DecodedMessage(
      topic: 'voice:henry',
      event: 'locked',
      json: {'locked': true},
    ));
    expect(vc.wakeLocked, isTrue);
  });
}
