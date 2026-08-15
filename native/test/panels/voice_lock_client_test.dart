import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/connection/app_connection.dart';
import 'package:henry_wall/panels/voice_lock_client.dart';

import '../support/fake_socket.dart';

const String _stateFrame = '[null,null,"panel:voice_lock:henry","state",'
    '{"user_id":7,"mode":"shadow","enrolled_slots":[1,2],'
    '"verifier_ready":true,"drops":['
    '{"decision":"would_drop","transcript":"a stray line","score":0.21},'
    '{"decision":"drop","transcript":"music","score":null}'
    ']}]';

// A drop row with no "decision" (unrenderable as a badge), a well-formed row
// behind it in the same array — proves the bad row is dropped without
// blanking the rest of the payload.
const String _malformedDropFrame =
    '[null,null,"panel:voice_lock:henry","state",'
    '{"user_id":7,"mode":"shadow","enrolled_slots":[1,2],'
    '"verifier_ready":true,"drops":['
    '{"transcript":"no decision here","score":0.5},'
    '{"decision":"drop","transcript":"good row","score":0.9}'
    ']}]';

// No "user_id" key at all — must leave userId null, not throw.
const String _noUserIdFrame = '[null,null,"panel:voice_lock:henry","state",'
    '{"mode":"off","enrolled_slots":[],'
    '"verifier_ready":false,"drops":[]}]';

void main() {
  late FakeSocket fake;
  late AppConnection conn;
  late VoiceLockClient client;
  late StreamController<Uint8List> mic;

  setUp(() {
    fake =
        FakeSocket(joinPushes: const {'panel:voice_lock:henry': _stateFrame});
    conn = AppConnection(
      connector: () async => fake.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    mic = StreamController<Uint8List>.broadcast();
    client = VoiceLockClient(
      connection: conn,
      acquireMic: () async => mic.stream,
      releaseMic: () async {},
    );
  });

  tearDown(() {
    client.dispose();
    conn.dispose();
  });

  test('nothing is joined until the panel opens', () async {
    await conn.connect();
    await pumpEventQueue();
    expect(fake.joinedTopics, isEmpty,
        reason: 'a closed panel must cost the server nothing');
    expect(client.isOpen, isFalse);
  });

  test('open() joins and the state behind the join reply lands', () async {
    await conn.connect();
    client.open();
    await pumpEventQueue();

    expect(fake.joinedTopics, ['panel:voice_lock:henry']);
    final s = client.state;
    expect(s, isNotNull);
    expect(s!.userId, 7);
    expect(s.mode, 'shadow');
    expect(s.enrolledSlots, [1, 2]);
    expect(s.verifierReady, isTrue);
    expect(s.drops, hasLength(2));
  });

  test("a drop's null score parses to null, not 0.0", () async {
    await conn.connect();
    client.open();
    await pumpEventQueue();

    final drops = client.state!.drops;
    expect(drops[0].score, 0.21);
    expect(drops[1].score, isNull,
        reason: 'an unscored drop must stay null, not read as a confident '
            '0.00 on the panel whose whole purpose is reading scores');
  });

  test('a drop row missing decision is dropped while its siblings land',
      () async {
    final fake2 = FakeSocket(
        joinPushes: const {'panel:voice_lock:henry': _malformedDropFrame});
    final c2 = AppConnection(
      connector: () async => fake2.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final vc = VoiceLockClient(
      connection: c2,
      acquireMic: () async => mic.stream,
      releaseMic: () async {},
    );
    addTearDown(() {
      vc.dispose();
      c2.dispose();
    });

    await c2.connect();
    vc.open();
    await pumpEventQueue();

    expect(vc.state, isNotNull);
    expect(vc.state!.drops, hasLength(1),
        reason: 'the row without a decision must be dropped, not thrown');
    expect(vc.state!.drops.single.transcript, 'good row');
  });

  test('a missing user_id leaves userId null rather than throwing', () async {
    final fake2 = FakeSocket(
        joinPushes: const {'panel:voice_lock:henry': _noUserIdFrame});
    final c2 = AppConnection(
      connector: () async => fake2.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final vc = VoiceLockClient(
      connection: c2,
      acquireMic: () async => mic.stream,
      releaseMic: () async {},
    );
    addTearDown(() {
      vc.dispose();
      c2.dispose();
    });

    await c2.connect();
    vc.open();
    await pumpEventQueue();

    expect(vc.state, isNotNull);
    expect(vc.state!.userId, isNull);
  });

  test('setMode pushes set_mode with the mode payload', () async {
    await conn.connect();
    client.open();
    await pumpEventQueue();
    fake.sent.clear();

    client.setMode('enforce');

    final pushed = fake.textFrames.map((p) => [p[2], p[3], p[4]]).toList();
    expect(pushed, [
      [
        'panel:voice_lock:henry',
        'set_mode',
        {'mode': 'enforce'}
      ]
    ]);
  });

  test('setMode before the join reply is dropped, not sent into the void',
      () async {
    await conn.connect();
    client.open();
    // no pump: the join reply has not landed

    client.setMode('enforce');

    expect(fake.textFrames.where((p) => p[3] == 'set_mode'), isEmpty);
  });

  test('close() leaves the topic, clears state, and deregisters the topic',
      () async {
    await conn.connect();
    client.open();
    await pumpEventQueue();
    expect(client.state, isNotNull);
    expect(conn.debugListenerCount('panel:voice_lock:henry'), 1);

    client.close();
    await pumpEventQueue();

    expect(client.isOpen, isFalse);
    expect(client.state, isNull,
        reason: 'a reopen re-fetches; a stale state is a ghost');
    expect(fake.textFrames.map((p) => p[3]), contains('phx_leave'));
    expect(conn.debugListenerCount('panel:voice_lock:henry'), 0,
        reason: 'close() must deregister the topic from AppConnection, not '
            'merely stop rendering it locally');
  });

  test(
      'dispose() while open also deregisters the topic from the connection '
      'registry', () async {
    final fake2 =
        FakeSocket(joinPushes: const {'panel:voice_lock:henry': _stateFrame});
    final c2 = AppConnection(
      connector: () async => fake2.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final vc = VoiceLockClient(
      connection: c2,
      acquireMic: () async => mic.stream,
      releaseMic: () async {},
    );
    addTearDown(c2.dispose);

    await c2.connect();
    vc.open();
    await pumpEventQueue();
    expect(c2.debugListenerCount('panel:voice_lock:henry'), 1);

    vc.dispose();

    expect(c2.debugListenerCount('panel:voice_lock:henry'), 0,
        reason:
            'dispose() must deregister the topic from AppConnection while open');
  });

  test('a refused panel leaves the conversation joined', () async {
    final refusing =
        FakeSocket(refuseTopics: const {'panel:voice_lock:henry'});
    final c2 = AppConnection(
      connector: () async => refusing.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final vc = VoiceLockClient(
      connection: c2,
      acquireMic: () async => mic.stream,
      releaseMic: () async {},
    );
    addTearDown(() {
      vc.dispose();
      c2.dispose();
    });

    await c2.connect();
    vc.open();
    await pumpEventQueue();

    expect(c2.state, ConnState.joined);
    expect(vc.state, isNull);
  });
}
