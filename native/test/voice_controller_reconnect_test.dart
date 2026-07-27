import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/meridian/orb_state.dart';
import 'package:henry_wall/phoenix/decoded_message.dart';
import 'package:henry_wall/phoenix/phoenix_channel_client.dart';
import 'package:henry_wall/voice/voice_controller.dart';
import 'package:stream_channel/stream_channel.dart';

/// One in-memory Phoenix socket: auto-acks the join, lets a test push server
/// events, and can be killed to simulate a server bounce.
class FakeSocket {
  FakeSocket() {
    ctrl.foreign.stream.listen(sent.add, onDone: () => localClosed = true);
    client = PhoenixChannelClient(
      ctrl.local,
      topic: 'voice:henry',
      joinPayload: const {'kiosk': false},
      heartbeatInterval: const Duration(days: 1),
    );
    client.start();
    scheduleMicrotask(() {
      if (!localClosed) {
        ctrl.foreign.sink.add(
            '["1","1","voice:henry","phx_reply",{"status":"ok","response":{}}]');
      }
    });
  }

  final StreamChannelController<dynamic> ctrl = StreamChannelController<dynamic>();
  final List<dynamic> sent = <dynamic>[];
  late final PhoenixChannelClient client;
  bool localClosed = false;

  void push(String event, String jsonPayload) =>
      ctrl.foreign.sink.add('[null,null,"voice:henry","$event",$jsonPayload]');

  Future<void> kill() => ctrl.foreign.sink.close();
}

Future<void> settle([int turns = 8]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  // `connect()` reaches AudioTrackPlayer.init() on the first successful join,
  // which is a real MethodChannel('henry/audio_track') call. Without a mock
  // handler it throws (MissingPluginException / binding-not-initialized) and
  // connect() would misreport ConnState.error for reasons that have nothing to
  // do with the reconnect logic under test here — so stub it, matching the
  // "no test may require a real socket or device" constraint.
  TestWidgetsFlutterBinding.ensureInitialized();
  const audioTrackChannel = MethodChannel('henry/audio_track');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(audioTrackChannel, (call) async => null);

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

  test('a dead socket schedules a rejoin that reconnects', () async {
    final sockets = <FakeSocket>[];
    final vc = VoiceController(
      connector: () async {
        final s = FakeSocket();
        sockets.add(s);
        return s.client;
      },
      rejoinBackoff: const [Duration(milliseconds: 10)],
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
    );

    final connecting = vc.connect();
    vc.dispose();
    await connecting;
    await settle();

    expect(fake.localClosed, isTrue,
        reason: 'a dispose inside the await used to leak an open socket forever');
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
