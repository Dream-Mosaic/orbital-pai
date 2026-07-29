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
  FakePlayer({this.failInit = false, this.onInit});

  final bool failInit;

  /// Runs *inside* `init()`'s await. The real one is a platform-channel call
  /// taking tens of ms, so this is the honest way to land an event in that
  /// window — deterministically, instead of racing a sleep against it.
  final Future<void> Function()? onInit;

  int initCalls = 0;
  int disposeCalls = 0;
  final List<Uint8List> writes = <Uint8List>[];

  @override
  Future<void> init(int sampleRate) async {
    initCalls++;
    if (onInit != null) await onInit!();
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

  test('the mic is re-armed once an automatic rejoin succeeds (A2)', () async {
    final mic = FakeMic();
    final sockets = <FakeSocket>[];
    final vc = VoiceController(
      connector: () async {
        final s = FakeSocket();
        sockets.add(s);
        return s.client;
      },
      rejoinBackoff: const [Duration(milliseconds: 10)],
      mic: mic,
      player: FakePlayer(),
    );
    addTearDown(vc.dispose);

    await vc.connect();
    await vc.startMic();
    expect(vc.micOn, isTrue);

    await sockets.first.kill();
    await settle();
    expect(vc.micOn, isFalse,
        reason: 'the socket death must still stop a mic streaming into it');

    await Future<void>.delayed(const Duration(milliseconds: 40));
    await settle();

    expect(vc.state, ConnState.joined);
    expect(vc.micOn, isTrue,
        reason: 'a wall device must not go silently deaf after a server bounce');
    expect(mic.startCalls, 2,
        reason: 'once from the user, once from the automatic re-arm on rejoin');
  });

  test('an explicit stopMic() before the outage is not resurrected by the rejoin',
      () async {
    final mic = FakeMic();
    final sockets = <FakeSocket>[];
    final vc = VoiceController(
      connector: () async {
        final s = FakeSocket();
        sockets.add(s);
        return s.client;
      },
      rejoinBackoff: const [Duration(milliseconds: 10)],
      mic: mic,
      player: FakePlayer(),
    );
    addTearDown(vc.dispose);

    await vc.connect();
    await vc.startMic();
    expect(vc.micOn, isTrue);

    await vc.stopMic();
    expect(vc.micOn, isFalse);

    await sockets.first.kill();
    await settle();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await settle();

    expect(vc.state, ConnState.joined);
    expect(vc.micOn, isFalse,
        reason:
            'a deliberate stopMic() must never be resurrected by a later reconnect');
  });

  test('a deliberate disconnect() never re-arms the mic on the next connect()',
      () async {
    final mic = FakeMic();
    final sockets = <FakeSocket>[];
    final vc = VoiceController(
      connector: () async {
        final s = FakeSocket();
        sockets.add(s);
        return s.client;
      },
      rejoinBackoff: const [Duration(days: 1)],
      mic: mic,
      player: FakePlayer(),
    );
    addTearDown(vc.dispose);

    await vc.connect();
    await vc.startMic();
    expect(vc.micOn, isTrue);

    await vc.disconnect();
    expect(vc.micOn, isFalse);

    await vc.connect();
    expect(vc.state, ConnState.joined);
    expect(sockets, hasLength(2));
    expect(vc.micOn, isFalse,
        reason:
            'a deliberate disconnect() must not resurrect the mic on the next connect()');
  });

  test('a stopMic() DURING the outage is not resurrected by the rejoin', () async {
    // The "before the outage" test above never actually reaches stopMic()'s
    // `_micWasOn = false`: with the mic already stopped, _onSocketDown's
    // `if (_micOn || _micWanted)` is false, so the restore flag was never armed
    // in the first place. Deleting that line leaves the whole suite green.
    //
    // THIS is the ordering that arms the flag first and then asks for a stop —
    // i.e. the one where a missing clear turns a deliberate "mic off" into a
    // microphone that switches itself back on a few seconds later.
    final mic = FakeMic();
    final sockets = <FakeSocket>[];
    final vc = VoiceController(
      connector: () async {
        final s = FakeSocket();
        sockets.add(s);
        return s.client;
      },
      rejoinBackoff: const [Duration(milliseconds: 30)],
      mic: mic,
      player: FakePlayer(),
    );
    addTearDown(vc.dispose);

    await vc.connect();
    await vc.startMic();
    expect(vc.micOn, isTrue);

    await sockets.first.kill();
    await settle();
    expect(vc.micOn, isFalse); // the outage armed the restore flag

    await vc.stopMic();

    await Future<void>.delayed(const Duration(milliseconds: 100));
    await settle();

    expect(vc.state, ConnState.joined, reason: 'the rejoin must still happen');
    expect(vc.micOn, isFalse,
        reason: 'a mic stopped during an outage must stay stopped across the rejoin');
    expect(mic.startCalls, 1, reason: 'only the start the user actually asked for');
  });

  test('a socket that dies again mid-rejoin does not burn the mic-restore flag',
      () async {
    // Reachable on a device whose AudioTrack init has failed: `_playerReady`
    // stays false, so every join re-enters the real (slow, awaited) init() —
    // and a second server bounce can land inside that await. Without the
    // `identical(joinedClient, _client)` guard, the now-superseded join clears
    // _micWasOn and then calls startMic(), which returns immediately because
    // _client is null. Net effect: the flag is spent, and the wall device comes
    // back from the outage permanently deaf.
    final mic = FakeMic();
    final sockets = <FakeSocket>[];
    var killInsideInit = false;
    final vc = VoiceController(
      connector: () async {
        final s = FakeSocket();
        sockets.add(s);
        return s.client;
      },
      rejoinBackoff: const [Duration(milliseconds: 5)],
      mic: mic,
      player: FakePlayer(
        failInit: true, // keeps _playerReady false → init() re-runs every join
        onInit: () async {
          if (!killInsideInit) return;
          killInsideInit = false;
          await sockets.last.kill();
          await settle(); // let _onSocketDown run before init() returns
        },
      ),
    );
    addTearDown(vc.dispose);

    await vc.connect();
    await vc.startMic();
    expect(vc.micOn, isTrue);
    expect(sockets, hasLength(1));

    killInsideInit = true;
    await sockets.first.kill(); // outage #1 arms the restore flag
    await settle();
    expect(vc.micOn, isFalse);

    // The rejoin lands, then dies again inside _initPlayer's await.
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await settle();
    expect(sockets.length, greaterThanOrEqualTo(2),
        reason: 'the first rejoin must have opened a second socket');

    // The next rejoin is the one that sticks — and it must still re-arm.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    await settle();

    expect(vc.state, ConnState.joined);
    expect(vc.micOn, isTrue,
        reason: 'the restore flag must survive a join that got superseded');
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

  test('a server-side death mid-join recovers via backoff (C1, remote close)',
      () async {
    // C1's primary production trigger: a deploy restart lands exactly in the
    // ready→ack window — the socket is accepted, then the REMOTE end dies
    // before ever answering phx_join. This is distinct from every other case
    // already covered here: disconnect()/rejoin() route the local teardown
    // through PhoenixChannelClient.close(), and the "never answers" test above
    // is pinned entirely by the join TIMEOUT.
    //
    // NOTE on what this test does and doesn't prove: VoiceController's own
    // `_onSocketDown` reacts to the client.messages stream closing (which
    // PhoenixChannelClient._onDone triggers unconditionally) by calling
    // close() on the dead client — and close() has its OWN _failJoin call.
    // That means this end-to-end path resolves `connecting` even if
    // _onDone's direct _failJoin call were removed, one event-loop turn
    // later via that cascade — verified empirically while building this
    // test. So this test pins the desired BEHAVIOUR (recovers, self-heals),
    // but the mechanism itself (_onDone/_onError's _failJoin call) is pinned
    // in isolation by phoenix_channel_client_test.dart's
    // 'onJoin fails when the remote closes before any reply' test, which
    // deliberately never calls close() so nothing else can mask the gap.
    final sockets = <FakeSocket>[];
    final vc = VoiceController(
      connector: () async {
        final s = FakeSocket(
            joinReply: sockets.isEmpty ? JoinReply.none : JoinReply.ok);
        sockets.add(s);
        return s.client;
      },
      rejoinBackoff: const [Duration(milliseconds: 10)],
      joinTimeout: const Duration(seconds: 30),
      mic: FakeMic(),
      player: FakePlayer(),
    );
    addTearDown(vc.dispose);

    final connecting = vc.connect();
    await settle();
    expect(vc.state, ConnState.connecting);

    // The remote end vanishes — no reply, no local close() call.
    await sockets.first.kill();

    await connecting.timeout(const Duration(seconds: 2),
        onTimeout: () =>
            fail('connect() never resolved — a remote death mid-join must '
                'still fail the join, not park forever'));
    await settle();
    expect(vc.state, ConnState.error);

    // Self-heals: the backoff fires and the retry actually joins.
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await settle();

    expect(sockets, hasLength(2),
        reason: 'a server-side death mid-join must still schedule a rejoin');
    expect(vc.state, ConnState.joined);
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
