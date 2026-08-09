import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/audio/audio_track_player.dart';
import 'package:henry_wall/audio/mic_capture.dart';
import 'package:henry_wall/connection/app_connection.dart';
import 'package:henry_wall/meridian/orb_state.dart';
import 'package:henry_wall/meridian/thread_model.dart';
import 'package:henry_wall/phoenix/decoded_message.dart';
import 'package:henry_wall/phoenix/phoenix_socket.dart';
import 'package:henry_wall/voice/voice_controller.dart';
import 'package:stream_channel/stream_channel.dart';

import 'support/fakes.dart';

/// How the fake server answers `phx_join`. `none` is the case that used to
/// brick the client: the socket is up, the reply never comes.
enum JoinReply { ok, error, none }

/// One in-memory Phoenix socket: answers joins (or refuses, or stays silent),
/// lets a test push server events, and can be killed to simulate a bounce.
class FakeSocket {
  FakeSocket({
    this.joinReply = JoinReply.ok,
    this.joinPushes = const <String>[],
    Duration heartbeat = const Duration(days: 1),
  }) {
    ctrl.foreign.stream.listen((f) {
      sent.add(f);
      if (f is! String) return;
      final p = jsonDecode(f) as List<dynamic>;
      if (p[3] != 'phx_join' || joinReply == JoinReply.none) return;
      final status = joinReply == JoinReply.ok ? 'ok' : 'error';
      scheduleMicrotask(() {
        if (localClosed) return;
        ctrl.foreign.sink.add(jsonEncode([
          null,
          p[1],
          p[2],
          'phx_reply',
          {'status': status, 'response': <String, dynamic>{}},
        ]));
        if (status != 'ok') return;
        // Straight behind the reply, in the SAME turn. That is what
        // VoiceChannel does: `set_client` inside join/3 pushes the `state`
        // snapshot, and `send(self(), :after_join)` pushes `history`.
        for (final frame in joinPushes) {
          ctrl.foreign.sink.add(frame);
        }
      });
    }, onDone: () => localClosed = true);
    socket = PhoenixSocket(ctrl.local, heartbeatInterval: heartbeat);
    socket.start();
  }

  final JoinReply joinReply;

  /// Raw frames this server pushes immediately behind its join reply.
  final List<String> joinPushes;

  final StreamChannelController<dynamic> ctrl = StreamChannelController<dynamic>();
  final List<dynamic> sent = <dynamic>[];
  late final PhoenixSocket socket;
  bool localClosed = false;

  /// The event names this client actually put on the wire, in order.
  List<String> get sentEvents => sent
      .whereType<String>()
      .map((f) => (jsonDecode(f) as List<dynamic>)[3] as String)
      .toList();

  void push(String event, String jsonPayload) =>
      ctrl.foreign.sink.add('[null,null,"voice:henry","$event",$jsonPayload]');

  /// A server→client BINARY push — kind 0 with no ref, which is how
  /// VoiceChannel ships raw 24k PCM (no JSON envelope, no base64).
  void pushBinary(String event, List<int> pcm) {
    final jr = utf8.encode('1');
    final tp = utf8.encode('voice:henry');
    final ev = utf8.encode(event);
    ctrl.foreign.sink.add(Uint8List.fromList(
        [0, jr.length, tp.length, ev.length, ...jr, ...tp, ...ev, ...pcm]));
  }

  Future<void> kill() => ctrl.foreign.sink.close();
}

/// A connector that never yields a socket, for the tests that drive the event
/// router directly and want no transport at all.
Future<PhoenixSocket> noSocket() async => throw StateError('no socket');

/// Builds the pair under test. Every reconnect assertion below is about the
/// CONNECTION; the controller is along for the ride, which is the point of the
/// refactor.
({AppConnection conn, VoiceController vc}) build({
  required Future<PhoenixSocket> Function() connector,
  List<Duration> backoff = const [Duration(days: 1)],
  Duration joinTimeout = const Duration(seconds: 15),
  MicCapture? mic,
  AudioTrackPlayer? player,
}) {
  final conn = AppConnection(
      connector: connector, rejoinBackoff: backoff, joinTimeout: joinTimeout);
  final vc = VoiceController(
      connection: conn, mic: mic ?? FakeMic(), player: player ?? FakePlayer());
  return (conn: conn, vc: vc);
}

void main() {
  // ---- the wire seam: a real frame, through PhoenixSocket and PhoenixChannel,
  // into VoiceController._onMessage. Everything else here drives the router
  // directly, which is exactly how the dropped-first-frame bug got through.

  test('server frames drive the conversation end-to-end over a real socket',
      () async {
    // Nothing else in the suite pushes a frame all the way from the transport
    // into the event router: stub the message handler out and the whole suite
    // used to stay green while the device rendered nothing and played nothing.
    final player = FakePlayer();
    final fake = FakeSocket();
    final b = build(connector: () async => fake.socket, player: player);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);

    await b.conn.connect();
    await settle();

    fake.push('transcript', '{"text":"what is the weather"}');
    fake.push('brain_delta', '{"delta":"it is "}');
    fake.push('brain_delta', '{"delta":"sunny"}');
    fake.push('speak_start', '{"source":"brain","text":"It is sunny."}');
    fake.pushBinary('audio', const [1, 2, 3, 4]);
    await settle();

    expect(b.vc.transcript, contains('you: what is the weather'));
    final lines = b.vc.thread.whereType<ThreadLine>().map((l) => l.text).toList();
    expect(lines, contains('what is the weather'));
    expect(lines, contains('It is sunny.'),
        reason: 'the streamed deltas must snap to the full markdown render');
    expect(player.writes, hasLength(1),
        reason: 'a binary audio frame must reach the output track');
    expect(player.writes.single, <int>[1, 2, 3, 4]);
  });

  test('the frames the server pushes behind its join reply are not lost',
      () async {
    // VoiceChannel pushes the `state` snapshot from `set_client` inside join/3
    // and `history` from `:after_join`, both immediately behind the join reply.
    // `PhoenixChannel.messages` is an unbuffered broadcast stream, so a
    // consumer that took its channel from a "joined" signal — two microtask
    // hops behind the reply, while the next transport frame is one — dropped
    // BOTH, on every single connect.
    final fake = FakeSocket(joinPushes: const [
      '[null,null,"voice:henry","state",{"phase":"listening","locked":true}]',
      '[null,null,"voice:henry","history",'
          '{"turns":[{"you":"hi","assistant":"hello"}]}]',
    ]);
    final b = build(connector: () async => fake.socket);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);

    await b.conn.connect();
    await settle();

    expect(b.vc.wakeLocked, isTrue,
        reason: 'the `state` snapshot rides directly behind the join reply');
    expect(b.vc.thread.whereType<ThreadLine>().map((l) => l.text),
        containsAll(<String>['hi', 'hello']),
        reason: 'the history backfill is the very next frame after that');
  });

  test('a frame behind the join reply survives a RECONNECT too', () async {
    // The reconnect is the case that actually bites a wall device: it rebinds
    // to a live session and re-derives its state from the snapshot the server
    // pushes behind the rejoin. Lose it and the UI is stranded on whatever it
    // believed before the outage.
    final sockets = <FakeSocket>[];
    final b = build(
      connector: () async {
        final s = FakeSocket(
          joinPushes: sockets.isEmpty
              ? const <String>[]
              : const ['[null,null,"voice:henry","locked",{"locked":true}]'],
        );
        sockets.add(s);
        return s.socket;
      },
      backoff: const [Duration(milliseconds: 10)],
    );
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);

    await b.conn.connect();
    await settle();
    expect(b.vc.wakeLocked, isFalse);

    await sockets.first.kill();
    await settle();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await settle();

    expect(b.conn.state, ConnState.joined);
    expect(sockets, hasLength(2));
    expect(b.vc.wakeLocked, isTrue,
        reason: 'the rejoin must adopt its channel before the server pushes '
            'behind the reply, not after');
  });

  test('the state snapshot re-derives turnState from `phase`', () async {
    final b = build(connector: noSocket);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    final vc = b.vc;
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
    final b = build(connector: noSocket);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    final vc = b.vc;
    vc.debugSetTalking(true);
    vc.debugApplyEvent('speaking');

    vc.debugHandleMessage(const DecodedMessage(
      topic: 'voice:henry',
      event: 'state',
      json: {'locked': false},
    ));
    expect(vc.orbState, OrbState.speaking);
  });

  test('a controller built against an ALREADY-JOINED connection initialises its '
      'audio track and announces its toggles', () async {
    // main.dart builds the controller lazily (`late final`, first touched in
    // build()), so the connection can already be up by the time it exists.
    // There is no onJoined left to fire for it: without the constructor
    // adopting the live channel, the output track never initialises and every
    // TTS byte is silently dropped — while mic, captions and thread all keep
    // working, which is what makes it so easy to miss.
    final fake = FakeSocket();
    final conn = AppConnection(
      connector: () async => fake.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    addTearDown(conn.dispose);

    await conn.connect();
    await settle();
    expect(conn.state, ConnState.joined, reason: 'the connection is up FIRST');

    final player = FakePlayer();
    final vc =
        VoiceController(connection: conn, mic: FakeMic(), player: player);
    addTearDown(vc.dispose);
    await settle();

    expect(player.initCalls, 1,
        reason: 'a late-built consumer still needs its 24k output track');
    expect(fake.sentEvents,
        containsAll(<String>['allow_interruptions', 'ptt']),
        reason: 'the server must learn a late-built client\'s toggles too');
  });

  test('a controller built BEFORE the join initialises its audio track exactly once',
      () async {
    // The other half of the same fix: adopting in the constructor must not make
    // the onJoined that follows re-run the join work on the same channel.
    final fake = FakeSocket();
    final player = FakePlayer();
    final b = build(connector: () async => fake.socket, player: player);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);

    expect(player.initCalls, 0, reason: 'there is no channel to init against yet');

    await b.conn.connect();
    await settle();

    expect(player.initCalls, 1,
        reason: 'the constructor and onJoined must not both init the same channel');
    expect(fake.sentEvents.where((e) => e == 'ptt'), hasLength(1),
        reason: 'the toggles are announced once per join, not twice');
  });

  test('a dead socket resets the orb instead of lying', () async {
    final fake = FakeSocket();
    final b = build(connector: () async => fake.socket);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);

    await b.conn.connect();
    await settle();
    expect(b.conn.state, ConnState.joined);
    b.vc.debugSetTalking(true);
    b.vc.debugApplyEvent('speaking');
    expect(b.vc.orbState, OrbState.speaking);

    await fake.kill();
    await settle();

    expect(b.vc.orbState, OrbState.off,
        reason: 'a server bounce must not leave the orb stuck on its last colour');
    expect(b.vc.talking, isFalse);
  });

  test('a dead socket stops the mic and cancels its subscription', () async {
    final mic = FakeMic();
    final fake = FakeSocket();
    final b = build(connector: () async => fake.socket, mic: mic);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);

    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    expect(b.vc.micOn, isTrue);
    expect(mic.listening, isTrue);

    await fake.kill();
    await settle();

    expect(b.vc.micOn, isFalse);
    expect(mic.stopCalls, greaterThan(0),
        reason: 'the mic was streaming into a socket that no longer exists');
    expect(mic.cancelled, isTrue,
        reason: '_micSub must be cancelled, not merely dropped');
  });

  test('the mic is re-armed once an automatic rejoin succeeds (A2)', () async {
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

    await sockets.first.kill();
    await settle();
    expect(b.vc.micOn, isFalse,
        reason: 'the socket death must still stop a mic streaming into it');

    await Future<void>.delayed(const Duration(milliseconds: 40));
    await settle();

    expect(b.conn.state, ConnState.joined);
    expect(b.vc.micOn, isTrue,
        reason: 'a wall device must not go silently deaf after a server bounce');
    expect(mic.startCalls, 2,
        reason: 'once from the user, once from the automatic re-arm on rejoin');
  });

  test('an explicit stopMic() before the outage is not resurrected by the rejoin',
      () async {
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

    await b.vc.stopMic();
    expect(b.vc.micOn, isFalse);

    await sockets.first.kill();
    await settle();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await settle();

    expect(b.conn.state, ConnState.joined);
    expect(b.vc.micOn, isFalse,
        reason:
            'a deliberate stopMic() must never be resurrected by a later reconnect');
  });

  test('a deliberate disconnect() never re-arms the mic on the next connect()',
      () async {
    final mic = FakeMic();
    final sockets = <FakeSocket>[];
    final b = build(
      connector: () async {
        final s = FakeSocket();
        sockets.add(s);
        return s.socket;
      },
      mic: mic,
    );
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);

    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    expect(b.vc.micOn, isTrue);

    await b.conn.disconnect();
    await settle();
    expect(b.vc.micOn, isFalse);

    await b.conn.connect();
    await settle();
    expect(b.conn.state, ConnState.joined);
    expect(sockets, hasLength(2));
    expect(b.vc.micOn, isFalse,
        reason:
            'a deliberate disconnect() must not resurrect the mic on the next connect()');
  });

  test('a disconnect() DURING the outage is not resurrected by the next connect()',
      () async {
    // The disconnect test above tears down a LIVE channel, so _onChannelDown
    // sees the deliberate teardown for itself. Here the channel is already dead
    // and the restore flag already armed when the user gives up and
    // disconnects — nothing dies a second time, so the only signal left is the
    // connection telling us its intent changed.
    final mic = FakeMic();
    final sockets = <FakeSocket>[];
    final b = build(
      connector: () async {
        final s = FakeSocket();
        sockets.add(s);
        return s.socket;
      },
      mic: mic,
    );
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);

    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    expect(b.vc.micOn, isTrue);

    await sockets.first.kill(); // the outage arms the restore flag
    await settle();
    expect(b.vc.micOn, isFalse);

    await b.conn.disconnect();
    await settle();
    await b.conn.connect();
    await settle();

    expect(b.conn.state, ConnState.joined);
    expect(b.vc.micOn, isFalse,
        reason: 'giving up mid-outage is still a deliberate teardown');
    expect(mic.startCalls, 1, reason: 'only the start the user actually asked for');
  });

  test('startMic() during an outage does not light the orb over a dead channel',
      () async {
    // _onChannelDown drops the channel handle, which is what makes startMic()
    // a no-op mid-outage. Keeping a stale handle would let the power button
    // turn the orb "live" while the audio went nowhere.
    final mic = FakeMic();
    final fake = FakeSocket();
    final b = build(connector: () async => fake.socket, mic: mic);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);

    await b.conn.connect();
    await settle();
    await fake.kill();
    await settle();

    await b.vc.startMic();

    expect(b.vc.micOn, isFalse);
    expect(b.vc.orbState, OrbState.off);
    expect(mic.startCalls, 0, reason: 'there is nothing to stream into');
  });

  test('a stopMic() DURING the outage is not resurrected by the rejoin', () async {
    // The "before the outage" test above never actually reaches stopMic()'s
    // `_micWasOn = false`: with the mic already stopped, _onChannelDown's
    // `if (_micOn || _micWanted)` is false, so the restore flag was never armed
    // in the first place. Deleting that line leaves the whole suite green.
    //
    // THIS is the ordering that arms the flag first and then asks for a stop —
    // i.e. the one where a missing clear turns a deliberate "mic off" into a
    // microphone that switches itself back on a few seconds later.
    final mic = FakeMic();
    final sockets = <FakeSocket>[];
    final b = build(
      connector: () async {
        final s = FakeSocket();
        sockets.add(s);
        return s.socket;
      },
      backoff: const [Duration(milliseconds: 30)],
      mic: mic,
    );
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);

    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    expect(b.vc.micOn, isTrue);

    await sockets.first.kill();
    await settle();
    expect(b.vc.micOn, isFalse); // the outage armed the restore flag

    await b.vc.stopMic();

    await Future<void>.delayed(const Duration(milliseconds: 100));
    await settle();

    expect(b.conn.state, ConnState.joined, reason: 'the rejoin must still happen');
    expect(b.vc.micOn, isFalse,
        reason: 'a mic stopped during an outage must stay stopped across the rejoin');
    expect(mic.startCalls, 1, reason: 'only the start the user actually asked for');
  });

  test('a socket that dies again mid-rejoin does not burn the mic-restore flag',
      () async {
    // Reachable on a device whose AudioTrack init has failed: `_playerReady`
    // stays false, so every join re-enters the real (slow, awaited) init() —
    // and a second server bounce can land inside that await. The re-arm must
    // survive it: whichever way the two interleave, the join that dies has to
    // hand the flag back rather than spend it, or the wall device comes back
    // from the outage permanently deaf.
    final mic = FakeMic();
    final sockets = <FakeSocket>[];
    var killInsideInit = false;
    final b = build(
      connector: () async {
        final s = FakeSocket();
        sockets.add(s);
        return s.socket;
      },
      backoff: const [Duration(milliseconds: 5)],
      mic: mic,
      player: FakePlayer(
        failInit: true, // keeps _playerReady false → init() re-runs every join
        onInit: () async {
          if (!killInsideInit) return;
          killInsideInit = false;
          await sockets.last.kill();
          await settle(); // let _onChannelDown run before init() returns
        },
      ),
    );
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);

    await b.conn.connect();
    await settle();
    await b.vc.startMic();
    expect(b.vc.micOn, isTrue);
    expect(sockets, hasLength(1));

    killInsideInit = true;
    await sockets.first.kill(); // outage #1 arms the restore flag
    await settle();
    expect(b.vc.micOn, isFalse);

    // The rejoin lands, then dies again inside _initPlayer's await.
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await settle();
    expect(sockets.length, greaterThanOrEqualTo(2),
        reason: 'the first rejoin must have opened a second socket');

    // The next rejoin is the one that sticks — and it must still re-arm.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    await settle();

    expect(b.conn.state, ConnState.joined);
    expect(b.vc.micOn, isTrue,
        reason: 'the restore flag must survive a join that got superseded');
  });

  test('a dead socket schedules a rejoin that reconnects', () async {
    final sockets = <FakeSocket>[];
    final b = build(
      connector: () async {
        final s = FakeSocket();
        sockets.add(s);
        return s.socket;
      },
      backoff: const [Duration(milliseconds: 10)],
    );
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);

    await b.conn.connect();
    expect(sockets, hasLength(1));

    await sockets.first.kill();
    await settle();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await settle();

    expect(sockets, hasLength(2), reason: 'PhoenixSocket has no rejoin of its own');
    expect(b.conn.state, ConnState.joined);
  });

  test('dispose() during connect() closes the socket it was awaiting', () async {
    late FakeSocket fake;
    final b = build(connector: () async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      fake = FakeSocket();
      return fake.socket;
    });

    final connecting = b.conn.connect();
    b.vc.dispose();
    b.conn.dispose();
    await connecting;
    await settle();

    expect(fake.localClosed, isTrue,
        reason: 'a dispose inside the await used to leak an open socket forever');
  });

  test('dispose() during mic start leaves no live recorder', () async {
    final mic = FakeMic(startDelay: const Duration(milliseconds: 20));
    final fake = FakeSocket();
    final b = build(connector: () async => fake.socket, mic: mic);
    addTearDown(b.conn.dispose);

    await b.conn.connect();
    await settle();
    final starting = b.vc.startMic();
    b.vc.dispose();
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
    final b = build(connector: () async {
      final s = FakeSocket(joinReply: sockets.isEmpty ? JoinReply.none : JoinReply.ok);
      sockets.add(s);
      return s.socket;
    });
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);

    final parked = b.conn.connect();
    await settle();
    expect(b.conn.state, ConnState.connecting);

    await b.conn.disconnect();
    await parked.timeout(const Duration(seconds: 2),
        onTimeout: () => fail('connect() never resolved — _connecting is latched'));
    await settle();

    await b.conn.connect().timeout(const Duration(seconds: 2),
        onTimeout: () => fail('the second connect() never resolved'));
    expect(sockets, hasLength(2),
        reason: 'the second connect() must actually reach the connector');
    expect(b.conn.state, ConnState.joined);
  });

  test('rejoin() during an in-flight join recovers instead of bricking', () async {
    // Same defect, second trigger: rejoin() closes the very socket the parked
    // connect() is awaiting.
    final sockets = <FakeSocket>[];
    final b = build(
      connector: () async {
        final s = FakeSocket(joinReply: sockets.isEmpty ? JoinReply.none : JoinReply.ok);
        sockets.add(s);
        return s.socket;
      },
      backoff: const [Duration(milliseconds: 10)],
    );
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);

    final parked = b.conn.connect();
    await settle();
    await b.conn.rejoin();
    await parked.timeout(const Duration(seconds: 2),
        onTimeout: () => fail('connect() never resolved — _connecting is latched'));
    await settle();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await settle();

    expect(b.conn.state, ConnState.joined);
  });

  test('a server that never answers phx_join cannot park connect() forever', () async {
    // The belt-and-braces half of CRITICAL 1: socket up, no reply, no death.
    final fake = FakeSocket(joinReply: JoinReply.none);
    final b = build(
      connector: () async => fake.socket,
      joinTimeout: const Duration(milliseconds: 30),
    );
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);

    await b.conn.connect().timeout(const Duration(seconds: 2),
        onTimeout: () => fail('an unanswered join parked connect() forever'));
    await settle();

    expect(b.conn.state, ConnState.error);
    expect(fake.localClosed, isTrue,
        reason: 'the timed-out socket must not be left open');
  });

  test('a server-side death mid-join recovers via backoff (C1, remote close)',
      () async {
    // C1's primary production trigger: a deploy restart lands exactly in the
    // ready→ack window — the socket is accepted, then the REMOTE end dies
    // before ever answering phx_join. This is distinct from every other case
    // already covered here: disconnect()/rejoin() route the local teardown
    // through PhoenixSocket.close(), and the "never answers" test above is
    // pinned entirely by the join TIMEOUT.
    //
    // NOTE on what this test does and doesn't prove: it pins the desired
    // BEHAVIOUR (recovers, self-heals). The mechanism itself — a transport
    // death failing every pending join instead of leaving it hanging — is
    // pinned in isolation by phoenix_socket_test.dart's 'transport death fails
    // every pending join', which never calls close() so nothing else can mask
    // the gap.
    final sockets = <FakeSocket>[];
    final b = build(
      connector: () async {
        final s = FakeSocket(joinReply: sockets.isEmpty ? JoinReply.none : JoinReply.ok);
        sockets.add(s);
        return s.socket;
      },
      backoff: const [Duration(milliseconds: 10)],
      joinTimeout: const Duration(seconds: 30),
    );
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);

    final connecting = b.conn.connect();
    await settle();
    expect(b.conn.state, ConnState.connecting);

    // The remote end vanishes — no reply, no local close() call.
    await sockets.first.kill();

    await connecting.timeout(const Duration(seconds: 2),
        onTimeout: () =>
            fail('connect() never resolved — a remote death mid-join must '
                'still fail the join, not park forever'));
    await settle();
    expect(b.conn.state, ConnState.error);

    // Self-heals: the backoff fires and the retry actually joins.
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await settle();

    expect(sockets, hasLength(2),
        reason: 'a server-side death mid-join must still schedule a rejoin');
    expect(b.conn.state, ConnState.joined);
  });

  test('a failing audio player does not feed the reconnect loop', () async {
    // IMPORTANT 2: init() throwing used to land in connect()'s catch → error →
    // rejoin → init throws again → forever (leaking a socket each pass).
    final sockets = <FakeSocket>[];
    final b = build(
      connector: () async {
        final s = FakeSocket();
        sockets.add(s);
        return s.socket;
      },
      backoff: const [Duration(milliseconds: 10)],
      player: FakePlayer(failInit: true),
    );
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);

    await b.conn.connect();
    await settle();
    expect(b.conn.state, ConnState.joined,
        reason: 'audio output is best-effort; a dead speaker is not a dead session');

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(sockets, hasLength(1),
        reason: 'a platform audio failure must never drive the reconnect machine');
  });

  test('a disposed controller is not handed the channels a reconnect makes',
      () async {
    // dispose() drops the channel handle, so if the controller is STILL on the
    // connection's listener list the next reconnect silently gives it a new
    // one — a live message subscription on a disposed object, once per
    // reconnect, forever.
    final fake = FakeSocket();
    final b = build(
      connector: () async => fake.socket,
      backoff: const [Duration(milliseconds: 10)],
    );
    addTearDown(b.conn.dispose);

    await b.conn.connect();
    await settle();
    expect(b.vc.debugHasChannel, isTrue);

    b.vc.dispose();
    await b.conn.rejoin();
    await settle();

    expect(b.vc.debugHasChannel, isFalse,
        reason: 'a disposed consumer left registered adopts every later channel');
  });

  test('_onMessage routes the literal event strings the server sends', () async {
    final b = build(connector: noSocket);
    addTearDown(b.vc.dispose);
    addTearDown(b.conn.dispose);
    final vc = b.vc;
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
