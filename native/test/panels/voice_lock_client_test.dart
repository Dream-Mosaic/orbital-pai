import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
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

    // Critical #1 from code review: micSub?.cancel() runs before
    // releaseMic() in the finally and, before this fix, was unguarded — a
    // throwing cancel() (realistic: this is the `record` plugin's stream,
    // and a platform channel can throw on teardown) skipped releaseMic()
    // entirely, leaving the mic suspended and recordingSlot stuck forever.
    test(
        '13: a mic subscription whose cancel() throws still releases and '
        'clears recordingSlot', () async {
      final fake = FakeSocket(
          joinPushes: const {'panel:voice_lock:henry': _stateFrame});
      final conn = AppConnection(
        connector: () async => fake.socket,
        rejoinBackoff: const [Duration(days: 1)],
      );
      final localMic = StreamController<Uint8List>(
        onCancel: () => throw StateError('platform cancel failed'),
      );
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

      expect(releases, 1,
          reason: 'a throwing cancel() must not skip releaseMic()');
      expect(client.recordingSlot, isNull);
    });

    // Critical #2 from code review: a throwing releaseMic() (realistic per
    // review: VoiceController.resumeMic() awaits _mic.stop() unguarded and
    // clears _micLoaned first, so a caller can't just retry) must not skip
    // the rest of the finally — recordingSlot staying stuck would dead-button
    // all three Record buttons forever, and a channel never left would sit
    // in AppConnection._wanted and get silently rejoined on every reconnect
    // (brief mutation #6's exact hazard, arriving by a different door).
    test(
        '14: a releaseMic() that throws still clears recordingSlot and '
        'leaves enroll:7', () async {
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
        releaseMic: () async {
          releases++;
          throw StateError('resumeMic failed');
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

      expect(client.recordingSlot, isNull,
          reason: 'a throwing releaseMic() must not leave the Record '
              'buttons permanently disabled');
      expect(
        fake.textFrames.any((p) => p[3] == 'phx_leave' && p[2] == 'enroll:7'),
        isTrue,
        reason: 'a throwing releaseMic() must not leave enroll:7 wanted '
            'forever — a topic left in _wanted is silently rejoined on '
            'every reconnect',
      );
    });

    // Not one of code review's two required tests, but the review named a
    // hanging cancel() as the worse failure mode ("no exception, no
    // recovery, silence") and asked for a bounded wait, not just a
    // try/catch — this proves the bound actually fires. teardownTimeout is
    // overridden short so the test doesn't have to wait out a real hang.
    test(
        '15: a mic subscription whose cancel() hangs does not block release '
        'forever', () async {
      final fake = FakeSocket(
          joinPushes: const {'panel:voice_lock:henry': _stateFrame});
      final conn = AppConnection(
        connector: () async => fake.socket,
        rejoinBackoff: const [Duration(days: 1)],
      );
      final neverDone = Completer<void>();
      final localMic = StreamController<Uint8List>(
        onCancel: () => neverDone.future,
      );
      final client = VoiceLockClient(
        connection: conn,
        acquireMic: () async {
          acquires++;
          return localMic.stream;
        },
        releaseMic: () async => releases++,
        clipLimit: const Duration(seconds: 5),
        replyTimeout: const Duration(seconds: 5),
        teardownTimeout: const Duration(milliseconds: 30),
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

      await fut.timeout(const Duration(milliseconds: 500));

      expect(releases, 1,
          reason: 'a hanging cancel() must not block releaseMic() forever');
      expect(client.recordingSlot, isNull);
    });

    // Critical from the follow-up review: releaseMic() was the one step in
    // the finally that was NOT bounded by teardownTimeout, even though the
    // doc comment already promised no step may stop the others "whether it
    // throws or ... simply never completes" and named the mic as exactly the
    // real-hardware step that can do that. Reachable in production:
    // VoiceController.resumeMic() awaits _mic.stop(), a platform-channel
    // call. Measured by the reviewer before this fix: recordingSlot stuck at
    // 1, enroll:<uid> leaked, every Record button dead for the life of the
    // app. teardownTimeout is overridden short so the test doesn't wait out
    // a real hang.
    test(
        '16: a releaseMic() that hangs does not park the finally forever',
        () async {
      final fake = FakeSocket(
          joinPushes: const {'panel:voice_lock:henry': _stateFrame});
      final conn = AppConnection(
        connector: () async => fake.socket,
        rejoinBackoff: const [Duration(days: 1)],
      );
      final localMic = StreamController<Uint8List>();
      final neverDone = Completer<void>();
      final client = VoiceLockClient(
        connection: conn,
        acquireMic: () async {
          acquires++;
          return localMic.stream;
        },
        releaseMic: () {
          releases++;
          return neverDone.future;
        },
        clipLimit: const Duration(seconds: 5),
        replyTimeout: const Duration(seconds: 5),
        teardownTimeout: const Duration(milliseconds: 30),
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

      // The whole assertion: without the release timeout this future never
      // completes and the test times out instead of failing cleanly, which
      // is exactly the production symptom (recordingSlot stuck at 1 forever).
      await fut.timeout(const Duration(milliseconds: 500));

      expect(client.recordingSlot, isNull,
          reason: 'a hanging releaseMic() must not leave the Record buttons '
              'permanently disabled');
      expect(
        fake.textFrames.any((p) => p[3] == 'phx_leave' && p[2] == 'enroll:7'),
        isTrue,
        reason: 'a hanging releaseMic() must not leave enroll:7 wanted '
            'forever',
      );
    });

    // Important from the follow-up review: _guardStep/_guardSync used to be
    // a bare `catch (_) {}` — the reviewer measured a TypeError thrown from
    // releaseMic producing ZERO zone errors and no output at all. This pins
    // that a cleanup-step failure is now reported through
    // FlutterError.onError instead of vanishing.
    test(
        '17: a cleanup-step failure is reported through FlutterError.onError, '
        'not swallowed silently', () async {
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
        // A TypeError, deliberately: it is the exact class of programming
        // bug the review's probe P7 used, and — unlike StateError — it is
        // unambiguously not something the app is expected to throw on
        // purpose.
        releaseMic: () async {
          releases++;
          throw TypeError();
        },
        clipLimit: const Duration(seconds: 5),
        replyTimeout: const Duration(seconds: 5),
      );
      addTearDown(() {
        client.dispose();
        conn.dispose();
      });

      final reports = <FlutterErrorDetails>[];
      final originalOnError = FlutterError.onError;
      FlutterError.onError = reports.add;
      addTearDown(() => FlutterError.onError = originalOnError);

      await conn.connect();
      client.open();
      await pumpEventQueue();

      final fut = client.startRecording(1);
      await pumpEventQueue();
      expect(fake.joinedTopics, contains('enroll:7'));

      client.close();

      await fut.timeout(const Duration(milliseconds: 500));

      expect(reports, isNotEmpty,
          reason: 'a caught cleanup-step failure must be reported, not '
              'dropped by a bare catch (_) {}');
      expect(reports.single.exception, isA<TypeError>());
      expect(client.recordingSlot, isNull,
          reason: 'reporting the failure must not stop the rest of the '
              'finally from running');
    });

    // Important from the follow-up review: the cap timer's `micSub = null`
    // removal (commit 86e0ad6's "test 12 correction") had no test of its
    // own — mutation testing re-added the line and the whole suite still
    // passed. A first draft of this test used a SYNCHRONOUS onCancel and
    // also survived the mutation: with a synchronous onCancel, the cap
    // timer's own `unawaited(micSub?.cancel())` records 'mic_cancelled'
    // before the mutation's `micSub = null;` line even runs, so nulling the
    // field changes nothing observable — the exact trap this phase's brief
    // warned about (a catcher structurally incapable of catching its
    // mutation). What the comment on `capTimer` actually promises is that
    // the finally's OWN cancel call — idempotent, so a second call while the
    // first is still pending returns that SAME pending future — is what
    // guarantees release WAITS for teardown to finish. That only shows up
    // with an ASYNCHRONOUS onCancel: this one resolves on a short delay, so
    // the finally must actually wait on it rather than merely have recorded
    // that cancel() was called at some point.
    test(
        '18: on the success path, release still waits for the (already '
        'in-flight, cap-timer-started) mic teardown to finish', () async {
      final fake = FakeSocket(
          joinPushes: const {'panel:voice_lock:henry': _stateFrame});
      final conn = AppConnection(
        connector: () async => fake.socket,
        rejoinBackoff: const [Duration(days: 1)],
      );
      final order = <String>[];
      final localMic = StreamController<Uint8List>(
        onCancel: () => Future<void>.delayed(
          const Duration(milliseconds: 30),
          () => order.add('mic_cancelled'),
        ),
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
        // Short enough that the cap timer fires well before the test drives
        // the clip_done reply.
        clipLimit: const Duration(milliseconds: 20),
        replyTimeout: const Duration(seconds: 5),
        // Comfortably longer than the onCancel delay above: this test means
        // to prove a genuine wait, not a bound cutting it short.
        teardownTimeout: const Duration(milliseconds: 300),
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

      await waitForClipDone(fake);
      replyToClipDone(fake, 'ok', {'slot': 1});

      await fut.timeout(const Duration(milliseconds: 500));

      expect(order, ['mic_cancelled', 'released'],
          reason: 'a re-added `micSub = null` in the cap timer would turn '
              "the finally's own idempotent cancel call into a no-op, so "
              'release would stop waiting on the teardown the cap timer '
              'already started and could run before it actually finishes');
    });

    // Minor from the follow-up review: nothing pinned two cleanup steps
    // failing at the same time. The implementation survives it (each step
    // is independently guarded), but that was previously only shown by a
    // reviewer's probe, not a test.
    test(
        '19: a cancel() that throws AND a releaseMic() that throws at the '
        'same time still clears recordingSlot and leaves enroll:7',
        () async {
      final fake = FakeSocket(
          joinPushes: const {'panel:voice_lock:henry': _stateFrame});
      final conn = AppConnection(
        connector: () async => fake.socket,
        rejoinBackoff: const [Duration(days: 1)],
      );
      final localMic = StreamController<Uint8List>(
        onCancel: () => throw StateError('platform cancel failed'),
      );
      final client = VoiceLockClient(
        connection: conn,
        acquireMic: () async {
          acquires++;
          return localMic.stream;
        },
        releaseMic: () async {
          releases++;
          throw StateError('resumeMic failed');
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

      await fut.timeout(const Duration(milliseconds: 500));

      expect(releases, 1,
          reason: 'a throwing cancel() must not skip releaseMic()');
      expect(client.recordingSlot, isNull);
      expect(
        fake.textFrames.any((p) => p[3] == 'phx_leave' && p[2] == 'enroll:7'),
        isTrue,
        reason: 'both steps failing at once must not leave enroll:7 wanted '
            'forever',
      );
    });

    // The other half of tests 15/16: those bound the RELEASE path
    // (VoiceController.resumeMic / its mic-sub cancel); this bounds the
    // ACQUIRE path (VoiceController.suspendMic). Before acquireTimeout, a
    // hanging acquireMic() parked `await acquireMic()` inside the try
    // FOREVER: the finally never ran, _micLoaned was already latched by
    // suspendMic() before its own first await, and the conversation's
    // capture was already stopped — deaf, permanently, silently, with
    // nothing to catch (a hang isn't a throw). acquireTimeout is overridden
    // short so the test doesn't wait out a real hang.
    test(
        '20: an acquireMic() that hangs does not park the finally forever',
        () async {
      final fake = FakeSocket(
          joinPushes: const {'panel:voice_lock:henry': _stateFrame});
      final conn = AppConnection(
        connector: () async => fake.socket,
        rejoinBackoff: const [Duration(days: 1)],
      );
      final neverDone = Completer<Stream<Uint8List>>();
      final client = VoiceLockClient(
        connection: conn,
        acquireMic: () {
          acquires++;
          return neverDone.future;
        },
        releaseMic: () async => releases++,
        clipLimit: const Duration(seconds: 5),
        replyTimeout: const Duration(seconds: 5),
        acquireTimeout: const Duration(milliseconds: 30),
      );
      addTearDown(() {
        client.dispose();
        conn.dispose();
      });

      await conn.connect();
      client.open();
      await pumpEventQueue();

      // The whole assertion: without the acquire timeout this future never
      // completes and the test times out instead of failing cleanly, which
      // is exactly the production symptom (recordingSlot stuck at 1
      // forever, the mic never given back).
      final fut = client.startRecording(1);
      await pumpEventQueue();
      expect(fake.joinedTopics, contains('enroll:7'));

      await fut.timeout(const Duration(milliseconds: 500));

      expect(releases, 1,
          reason: 'a hanging acquireMic() must still reach the finally that '
              'owns releasing the mic');
      expect(client.recordingSlot, isNull);
      expect(client.enrollError, (1, 'failed: mic_blocked'));
    });

    // Branch-review Minor: close() left recordingSlot set, so leaving and
    // re-entering the Voice Lock layer inside the finally's window (up to
    // ~4s if both bounded steps time out) rendered all three Record buttons
    // disabled with no explanation.
    test(
        '21: close() clears recordingSlot immediately, without waiting for a '
        'slow teardown', () async {
      final fake = FakeSocket(
          joinPushes: const {'panel:voice_lock:henry': _stateFrame});
      final conn = AppConnection(
        connector: () async => fake.socket,
        rejoinBackoff: const [Duration(days: 1)],
      );
      final localMic = StreamController<Uint8List>();
      final neverDone = Completer<void>();
      final client = VoiceLockClient(
        connection: conn,
        acquireMic: () async {
          acquires++;
          return localMic.stream;
        },
        // Hangs: this is what keeps the finally open long enough for a user
        // to leave and come back.
        releaseMic: () {
          releases++;
          return neverDone.future;
        },
        clipLimit: const Duration(seconds: 5),
        replyTimeout: const Duration(seconds: 5),
        teardownTimeout: const Duration(milliseconds: 300),
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
      expect(client.recordingSlot, 1, reason: 'sanity: recording');

      client.close();

      // The discriminating moment: the finally is still parked in its
      // hanging releaseMic() (teardownTimeout has not elapsed), so this is
      // close() answering, not the teardown.
      expect(client.recordingSlot, isNull,
          reason: 'the panel is gone; a re-entered layer must show usable '
              'Record buttons rather than three dead ones');

      await fut.timeout(const Duration(seconds: 2));
    });

    // The other half of that fix: clearing the slot in close() is only safe
    // if the abandoned teardown cannot then clobber the recording that
    // replaced it.
    test(
        '22: a stale teardown does not clear the slot (or the abort hook) of '
        'the recording that replaced it', () async {
      final fake = FakeSocket(
          joinPushes: const {'panel:voice_lock:henry': _stateFrame});
      final conn = AppConnection(
        connector: () async => fake.socket,
        rejoinBackoff: const [Duration(days: 1)],
      );
      final localMic = StreamController<Uint8List>.broadcast();
      final releaseGate = Completer<void>();
      final client = VoiceLockClient(
        connection: conn,
        acquireMic: () async {
          acquires++;
          return localMic.stream;
        },
        // The first release parks until the test opens the gate; later ones
        // return at once.
        releaseMic: () async {
          releases++;
          if (releases == 1) await releaseGate.future;
        },
        clipLimit: const Duration(seconds: 5),
        replyTimeout: const Duration(seconds: 5),
        teardownTimeout: const Duration(seconds: 5),
      );
      addTearDown(() {
        if (!releaseGate.isCompleted) releaseGate.complete();
        client.dispose();
        conn.dispose();
      });

      await conn.connect();
      client.open();
      await pumpEventQueue();

      final first = client.startRecording(1);
      await pumpEventQueue();
      client.close(); // leave the layer; the first teardown parks in release

      // Back into Voice Lock, and record another slot.
      client.open();
      await pumpEventQueue();
      final second = client.startRecording(2);
      await pumpEventQueue();
      expect(client.recordingSlot, 2, reason: 'sanity: the new clip is live');

      // Now let the ABANDONED first teardown finish, underneath the live one.
      releaseGate.complete();
      await first.timeout(const Duration(seconds: 2));
      await pumpEventQueue();

      expect(client.recordingSlot, 2,
          reason: 'a stale teardown must not re-enable the Record buttons '
              'while slot 2 is still recording');

      // And the live recording is still abortable — the stale teardown must
      // not have unhooked close()'s only way to end a clip.
      client.close();
      await second.timeout(const Duration(seconds: 2));
      expect(client.recordingSlot, isNull);
    });
  });
}
