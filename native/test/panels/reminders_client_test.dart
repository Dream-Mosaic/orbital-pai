import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/connection/app_connection.dart';
import 'package:henry_wall/panels/reminders_client.dart';

import '../support/fake_socket.dart';

const String _stateFrame =
    '[null,null,"panel:reminders:henry","state",'
    '{"due":[{"id":42,"body":"bins out","due_label":"Aug 9 7:30am",'
    '"recurrence_label":"every Tue","household":true,"kind":"followup"}],'
    '"upcoming":[{"id":43,"body":"call the vet","due_label":"Aug 11 9:00am",'
    '"recurrence_label":null,"household":false,"kind":"reminder"}]}]';

// Non-monotonic ids so neither a reversal nor an accidental sort could land
// back on this exact order by coincidence.
const String _multiRowFrame =
    '[null,null,"panel:reminders:henry","state",'
    '{"due":[{"id":7,"body":"first","due_label":"a","recurrence_label":null,'
    '"household":false,"kind":"reminder"},'
    '{"id":2,"body":"second","due_label":"b","recurrence_label":null,'
    '"household":false,"kind":"reminder"},'
    '{"id":9,"body":"third","due_label":"c","recurrence_label":null,'
    '"household":false,"kind":"reminder"}],'
    '"upcoming":[{"id":3,"body":"fourth","due_label":"d","recurrence_label":null,'
    '"household":false,"kind":"reminder"},'
    '{"id":8,"body":"fifth","due_label":"e","recurrence_label":null,'
    '"household":false,"kind":"reminder"}]}]';

void main() {
  late FakeSocket fake;
  late AppConnection conn;
  late RemindersClient client;

  setUp(() {
    fake = FakeSocket(
        joinPushes: const {'panel:reminders:henry': _stateFrame});
    conn = AppConnection(
      connector: () async => fake.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    client = RemindersClient(connection: conn);
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

    expect(fake.joinedTopics, ['panel:reminders:henry']);
    expect(client.due.map((r) => r.body), ['bins out']);
    expect(client.upcoming.map((r) => r.body), ['call the vet']);

    final r = client.due.single;
    expect(r.id, 42);
    expect(r.dueLabel, 'Aug 9 7:30am');
    expect(r.recurrenceLabel, 'every Tue');
    expect(r.household, isTrue);
    expect(r.isFollowup, isTrue);
    expect(client.upcoming.single.recurrenceLabel, isNull);
  });

  test('close() leaves the topic and empties the rows', () async {
    await conn.connect();
    client.open();
    await pumpEventQueue();
    expect(client.due, hasLength(1));

    client.close();
    await pumpEventQueue();

    expect(client.isOpen, isFalse);
    expect(client.due, isEmpty, reason: 'a reopen re-fetches; a stale list is a ghost');
    expect(client.upcoming, isEmpty);
    expect(fake.sent.map((f) => jsonDecode(f as String)[3]), contains('phx_leave'));
  });

  test('close() removes the listener from the connection registry, not just '
      'the local handle', () async {
    // A downstream symptom (rows emptied, phx_leave sent) can pass even with a
    // broken closeChannel call, because close() clears the rows itself
    // regardless. State the invariant directly — the topic must leave
    // AppConnection's `_wanted` registry, or it silently rejoins on the very
    // next reconnect even though the drawer is closed.
    await conn.connect();
    client.open();
    await pumpEventQueue();
    expect(conn.debugListenerCount('panel:reminders:henry'), 1);

    client.close();

    expect(conn.debugListenerCount('panel:reminders:henry'), 0,
        reason: 'close() must deregister the topic from AppConnection, not merely '
            'stop rendering it locally');
  });

  test('reopening after a close joins again and re-fetches', () async {
    await conn.connect();
    client.open();
    await pumpEventQueue();
    client.close();
    await pumpEventQueue();

    client.open();
    await pumpEventQueue();

    expect(fake.joinedTopics.where((t) => t == 'panel:reminders:henry').length, 2);
    expect(client.due, hasLength(1));
  });

  test('ack and dismiss push the id on the panel topic', () async {
    await conn.connect();
    client.open();
    await pumpEventQueue();
    fake.sent.clear();

    client.ack(42);
    client.dismiss(43);

    final pushed = fake.sent
        .map((f) => jsonDecode(f as String) as List<dynamic>)
        .map((p) => [p[2], p[3], p[4]])
        .toList();
    expect(pushed, [
      ['panel:reminders:henry', 'ack', {'id': 42}],
      ['panel:reminders:henry', 'dismiss', {'id': 43}],
    ]);
  });

  test('a write before the join reply is dropped, not sent into the void', () async {
    // Phoenix answers a frame on an unjoined topic with "unmatched topic", so a
    // push written between open() and the reply is silently lost. Same rule as
    // VoiceController's live-channel guard.
    await conn.connect();
    client.open();
    fake.sent.clear();

    client.ack(42); // no pump: the join reply has not landed
    expect(fake.sent, isEmpty);
  });

  test('a refused panel leaves the conversation alone', () async {
    final refusing = FakeSocket(refuseTopics: const {'panel:reminders:henry'});
    final c2 = AppConnection(
      connector: () async => refusing.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final rc = RemindersClient(connection: c2);
    addTearDown(() {
      rc.dispose();
      c2.dispose();
    });

    await c2.connect();
    rc.open();
    await pumpEventQueue();

    expect(c2.state, ConnState.joined);
    expect(rc.due, isEmpty);
  });

  test('rows render in the order the server sent them, not re-sorted', () async {
    final fake2 =
        FakeSocket(joinPushes: const {'panel:reminders:henry': _multiRowFrame});
    final c2 = AppConnection(
      connector: () async => fake2.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final rc = RemindersClient(connection: c2);
    addTearDown(() {
      rc.dispose();
      c2.dispose();
    });

    await c2.connect();
    rc.open();
    await pumpEventQueue();

    expect(rc.due.map((r) => r.id), [7, 2, 9],
        reason: 'the client must not re-sort the server\'s order');
    expect(rc.upcoming.map((r) => r.id), [3, 8],
        reason: 'the client must not re-sort the server\'s order');
  });
}
