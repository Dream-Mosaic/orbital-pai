import 'dart:async';
import 'dart:convert';
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

  group('startRecording', () {
    int acquires = 0, releases = 0;
    late StreamController<Uint8List> micCtrl;

    VoiceLockClient makeClient(AppConnection conn) {
      micCtrl = StreamController<Uint8List>();
      return VoiceLockClient(
        connection: conn,
        acquireMic: () async {
          acquires++;
          return micCtrl.stream;
        },
        releaseMic: () async => releases++,
        clipLimit: const Duration(milliseconds: 20),
        replyTimeout: const Duration(milliseconds: 20),
      );
    }

    /// Answer the clip_done the client just pushed, echoing its own ref so the
    /// socket routes the reply back to that channel. FakeSocket only auto-answers
    /// phx_join, so this is how a test drives EnrollChannel's reply.
    void replyToClipDone(
        FakeSocket fake, String status, Map<String, dynamic> response) {
      final frame = fake.textFrames.lastWhere((p) => p[3] == 'clip_done');
      fake.ctrl.foreign.sink.add(jsonEncode([
        frame[0],
        frame[1],
        frame[2],
        'phx_reply',
        {'status': status, 'response': response},
      ]));
    }

    setUp(() {
      acquires = 0;
      releases = 0;
    });

    /// Poll for clip_done rather than sleeping a fixed guess: replyTimeout is
    /// only 20ms in this group, so a wait long enough to be SURE clip_done
    /// has gone out risks overrunning the reply window and racing the timeout
    /// path instead of the one the test means to exercise.
    Future<void> waitForClipDone(FakeSocket fake) async {
      while (!fake.textFrames.any((p) => p[3] == 'clip_done')) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
    }

    test('1: success joins enroll:7, streams audio, and releases the mic',
        () async {
      final fake = FakeSocket(
          joinPushes: const {'panel:voice_lock:henry': _stateFrame});
      final conn = AppConnection(
        connector: () async => fake.socket,
        rejoinBackoff: const [Duration(days: 1)],
      );
      final client = makeClient(conn);
      addTearDown(() {
        client.dispose();
        conn.dispose();
      });

      await conn.connect();
      client.open();
      await pumpEventQueue();

      final fut = client.startRecording(1);
      await pumpEventQueue();
      expect(fake.joinedTopics, contains('enroll:7'));

      micCtrl.add(Uint8List.fromList([1, 2, 3]));
      micCtrl.add(Uint8List.fromList([4, 5, 6]));
      await pumpEventQueue();
      expect(fake.binaryFrames, isNotEmpty);

      await waitForClipDone(fake);

      replyToClipDone(fake, 'ok', {'slot': 1});
      await fut;

      expect(acquires, 1);
      expect(releases, 1);
      expect(client.recordingSlot, isNull);
      expect(client.enrollError, isNull);
      expect(
        fake.textFrames.any((p) => p[3] == 'phx_leave' && p[2] == 'enroll:7'),
        isTrue,
        reason: 'enroll:7 must be left once the clip is handed off',
      );
    });

    test('2: a clip_done rejection releases the mic and records the reason',
        () async {
      final fake = FakeSocket(
          joinPushes: const {'panel:voice_lock:henry': _stateFrame});
      final conn = AppConnection(
        connector: () async => fake.socket,
        rejoinBackoff: const [Duration(days: 1)],
      );
      final client = makeClient(conn);
      addTearDown(() {
        client.dispose();
        conn.dispose();
      });

      await conn.connect();
      client.open();
      await pumpEventQueue();

      final fut = client.startRecording(1);
      await pumpEventQueue();

      await waitForClipDone(fake);
      replyToClipDone(fake, 'error', {'reason': 'too_short'});
      await fut;

      expect(releases, 1);
      expect(client.enrollError, (1, 'failed: too_short'));
    });

    test(
        '3: a clip_done reply that never arrives times out and releases the '
        'mic', () async {
      final fake = FakeSocket(
          joinPushes: const {'panel:voice_lock:henry': _stateFrame});
      final conn = AppConnection(
        connector: () async => fake.socket,
        rejoinBackoff: const [Duration(days: 1)],
      );
      final client = makeClient(conn);
      addTearDown(() {
        client.dispose();
        conn.dispose();
      });

      await conn.connect();
      client.open();
      await pumpEventQueue();

      final fut = client.startRecording(1);
      await pumpEventQueue();
      // Never reply to clip_done.

      await fut.timeout(const Duration(milliseconds: 500));

      expect(releases, 1);
      expect(client.enrollError, (1, 'failed: timeout'));
    });

    test(
        '4: close() mid-record aborts, releases the mic, and resets the '
        'partial clip', () async {
      final fake = FakeSocket(
          joinPushes: const {'panel:voice_lock:henry': _stateFrame});
      final conn = AppConnection(
        connector: () async => fake.socket,
        rejoinBackoff: const [Duration(days: 1)],
      );
      final localMic = StreamController<Uint8List>();
      final client = VoiceLockClient(
        connection: conn,
        acquireMic: () async {
          acquires++;
          return localMic.stream;
        },
        releaseMic: () async => releases++,
        // Deliberately long: only the abort path can end this recording
        // within the .timeout below, so a deleted abort call fails loudly
        // (timeout) instead of merely completing slowly.
        clipLimit: const Duration(seconds: 5),
        replyTimeout: const Duration(seconds: 5),
      );
      addTearDown(() {
        client.dispose();
        conn.dispose();
      });

      await conn.connect();
      client.open();
      await pumpEventQueue();

      final fut = client.startRecording(1);
      await pumpEventQueue();
      expect(fake.joinedTopics, contains('enroll:7'));

      client.close();

      await fut.timeout(const Duration(milliseconds: 200));

      expect(releases, 1);
      expect(
        fake.textFrames
            .any((p) => p[3] == 'clip_reset' && p[2] == 'enroll:7'),
        isTrue,
      );
      expect(client.recordingSlot, isNull);
    });

    test('5: the socket dying mid-record releases the mic without hanging',
        () async {
      final fake = FakeSocket(
          joinPushes: const {'panel:voice_lock:henry': _stateFrame});
      final conn = AppConnection(
        connector: () async => fake.socket,
        rejoinBackoff: const [Duration(days: 1)],
      );
      final localMic = StreamController<Uint8List>();
      final client = VoiceLockClient(
        connection: conn,
        acquireMic: () async {
          acquires++;
          return localMic.stream;
        },
        releaseMic: () async => releases++,
        // Same reasoning as test 4: long enough that only the onDone path
        // (not the cap timer noticing isJoined went false) can end this
        // within the .timeout.
        clipLimit: const Duration(seconds: 5),
        replyTimeout: const Duration(seconds: 5),
      );
      addTearDown(() {
        client.dispose();
        conn.dispose();
      });

      await conn.connect();
      client.open();
      await pumpEventQueue();

      final fut = client.startRecording(1);
      await pumpEventQueue();
      expect(fake.joinedTopics, contains('enroll:7'));

      await fake.kill();

      await fut.timeout(const Duration(milliseconds: 200));

      expect(releases, 1);
    });

    test('6: dispose() mid-record releases the mic', () async {
      final fake = FakeSocket(
          joinPushes: const {'panel:voice_lock:henry': _stateFrame});
      final conn = AppConnection(
        connector: () async => fake.socket,
        rejoinBackoff: const [Duration(days: 1)],
      );
      final localMic = StreamController<Uint8List>();
      final client = VoiceLockClient(
        connection: conn,
        acquireMic: () async {
          acquires++;
          return localMic.stream;
        },
        releaseMic: () async => releases++,
        clipLimit: const Duration(seconds: 5),
        replyTimeout: const Duration(seconds: 5),
      );
      addTearDown(conn.dispose);

      await conn.connect();
      client.open();
      await pumpEventQueue();

      final fut = client.startRecording(1);
      await pumpEventQueue();
      expect(fake.joinedTopics, contains('enroll:7'));

      client.dispose();

      await fut.timeout(const Duration(milliseconds: 200));

      expect(releases, 1);
    });

    test(
        "7: an acquireMic() that throws still releases and reports "
        'mic_blocked', () async {
      final fake = FakeSocket(
          joinPushes: const {'panel:voice_lock:henry': _stateFrame});
      final conn = AppConnection(
        connector: () async => fake.socket,
        rejoinBackoff: const [Duration(days: 1)],
      );
      final client = VoiceLockClient(
        connection: conn,
        acquireMic: () async {
          acquires++;
          throw StateError('microphone permission denied');
        },
        releaseMic: () async => releases++,
        clipLimit: const Duration(milliseconds: 20),
        replyTimeout: const Duration(milliseconds: 20),
      );
      addTearDown(() {
        client.dispose();
        conn.dispose();
      });

      await conn.connect();
      client.open();
      await pumpEventQueue();

      await client.startRecording(1);

      expect(releases, 1,
          reason: 'the finally must still run when acquireMic() throws');
      expect(client.enrollError, (1, 'failed: mic_blocked'));
      expect(client.recordingSlot, isNull);
    });

    // NOTE ON DEVIATION FROM THE BRIEF: the brief's own scenario for this
    // case — "Do not conn.connect()" — can never reach the not_connected
    // branch: with no socket ever connected, the panel topic's `state` never
    // lands, so `_state?.userId` stays null and startRecording bails out on
    // the EARLIER `uid == null` guard (no error set, acquireMic never even
    // considered), not the openChannel-returns-null branch. The realistic
    // way to hit not_connected is a socket that was up (state cached, userId
    // known) and then drops before the user taps Record — e.g. a transient
    // reconnect window. That is what this test drives instead.
    test(
        '8: a dropped socket at record time is not_connected and takes '
        'nothing', () async {
      final fake = FakeSocket(
          joinPushes: const {'panel:voice_lock:henry': _stateFrame});
      final conn = AppConnection(
        connector: () async => fake.socket,
        rejoinBackoff: const [Duration(days: 1)],
      );
      final client = makeClient(conn);
      addTearDown(() {
        client.dispose();
        conn.dispose();
      });

      await conn.connect();
      client.open();
      await pumpEventQueue();
      expect(client.state?.userId, 7);

      await fake.kill();
      await pumpEventQueue();

      await client
          .startRecording(1)
          .timeout(const Duration(milliseconds: 200));

      expect(acquires, 0, reason: 'the mic must never be touched');
      expect(releases, 0, reason: 'nothing was ever taken');
      expect(client.enrollError, (1, 'failed: not_connected'));
    });

    test('9: a second startRecording while one is in flight is ignored',
        () async {
      final fake = FakeSocket(
          joinPushes: const {'panel:voice_lock:henry': _stateFrame});
      final conn = AppConnection(
        connector: () async => fake.socket,
        rejoinBackoff: const [Duration(days: 1)],
      );
      final client = makeClient(conn);
      addTearDown(() {
        client.dispose();
        conn.dispose();
      });

      await conn.connect();
      client.open();
      await pumpEventQueue();

      final fut1 = client.startRecording(1);
      await pumpEventQueue();
      expect(acquires, 1);

      final fut2 = client.startRecording(2);
      expect(acquires, 1, reason: 'the second call must be a no-op');

      await waitForClipDone(fake);
      replyToClipDone(fake, 'ok', {'slot': 1});
      await fut1;
      await fut2;

      expect(acquires, 1);
    });

    test('10: startRecording before state lands does nothing', () async {
      final fake = FakeSocket(
          joinPushes: const {'panel:voice_lock:henry': _stateFrame});
      final conn = AppConnection(
        connector: () async => fake.socket,
        rejoinBackoff: const [Duration(days: 1)],
      );
      final client = makeClient(conn);
      addTearDown(() {
        client.dispose();
        conn.dispose();
      });

      await conn.connect();
      client.open();
      // Deliberately no pump: the join reply (and the `state` push behind
      // it) has not landed, so userId is still null.

      await client.startRecording(1);

      expect(acquires, 0);
      expect(fake.joinedTopics.where((t) => t.startsWith('enroll:')), isEmpty);
    });

    test('11: frames stop reaching the wire at the clip cap', () async {
      final fake = FakeSocket(
          joinPushes: const {'panel:voice_lock:henry': _stateFrame});
      final conn = AppConnection(
        connector: () async => fake.socket,
        rejoinBackoff: const [Duration(days: 1)],
      );
      final client = makeClient(conn);
      addTearDown(() {
        client.dispose();
        conn.dispose();
      });

      await conn.connect();
      client.open();
      await pumpEventQueue();

      final fut = client.startRecording(1);
      await pumpEventQueue();

      micCtrl.add(Uint8List.fromList([1, 2, 3]));
      await pumpEventQueue();
      expect(fake.binaryFrames, isNotEmpty);

      // Stop exactly at the cap, not after the whole recording has also
      // timed out — otherwise the finally's OWN (unconditional) micSub
      // cancel would mask a missing cap-timer cancel and this test would not
      // discriminate the two.
      await waitForClipDone(fake);
      final countAtCap = fake.binaryFrames.length;

      micCtrl.add(Uint8List.fromList([9, 9, 9]));
      await pumpEventQueue();
      expect(
        fake.binaryFrames.length,
        countAtCap,
        reason: 'micSub must be cancelled at the cap; a frame emitted after '
            'it must not reach the wire',
      );

      replyToClipDone(fake, 'ok', {'slot': 1});
      await fut;
    });

    // Not one of the brief's enumerated exit paths — added after mutation
    // testing showed the "release moved out of the finally, to right after
    // the switch" mutation (the brief's own #1, called out as the one that
    // matters most) SURVIVES against tests 4, 5, and 6 as originally
    // written. Those three all resolve `_Ending.aborted` through the switch
    // normally, so a release relocated to right after the switch still runs
    // at essentially the same spot — count-based assertions cannot tell the
    // two placements apart. Only test 7 (acquireMic throws, which returns
    // BEFORE the switch) actually caught it. This test makes the ordering
    // observable instead of just the count, which the relocation does
    // change: the finally cancels the mic subscription BEFORE releasing;
    // "after the switch" releases BEFORE that cancel ever runs.
    test(
        '12: release happens strictly after the mic subscription is torn '
        'down (proves the finally, not a spot right after the switch, is '
        'the actual release site)', () async {
      final fake = FakeSocket(
          joinPushes: const {'panel:voice_lock:henry': _stateFrame});
      final conn = AppConnection(
        connector: () async => fake.socket,
        rejoinBackoff: const [Duration(days: 1)],
      );
      final order = <String>[];
      final localMic = StreamController<Uint8List>(
        onCancel: () => order.add('mic_cancelled'),
      );
      final client = VoiceLockClient(
        connection: conn,
        acquireMic: () async {
          acquires++;
          return localMic.stream;
        },
        releaseMic: () async {
          releases++;
          order.add('released');
        },
        clipLimit: const Duration(seconds: 5),
        replyTimeout: const Duration(seconds: 5),
      );
      addTearDown(() {
        client.dispose();
        conn.dispose();
      });

      await conn.connect();
      client.open();
      await pumpEventQueue();

      final fut = client.startRecording(1);
      await pumpEventQueue();
      expect(fake.joinedTopics, contains('enroll:7'));

      client.close();

      await fut.timeout(const Duration(milliseconds: 200));

      expect(order, ['mic_cancelled', 'released']);
    });
  });
}
