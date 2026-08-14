import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/connection/app_connection.dart';
import 'package:henry_wall/panels/memory_client.dart';

import '../support/fake_socket.dart';

const String _stateFrame = '[null,null,"panel:memory:henry","state",'
    '{"summary":"Likes coffee.","facts":['
    '{"id":1,"content":"Lives in Portland","source":"chat"},'
    '{"id":2,"content":"Has a dog named Biscuit","source":"chat"}'
    ']}]';

// One well-formed fact, one row with a missing id — proves the bad row is
// dropped without blanking the rest of the payload.
const String _malformedFrame = '[null,null,"panel:memory:henry","state",'
    '{"summary":"Likes coffee.","facts":['
    '{"content":"no id here","source":"chat"},'
    '{"id":2,"content":"Has a dog named Biscuit","source":"chat"}'
    ']}]';

void main() {
  late FakeSocket fake;
  late AppConnection conn;
  late MemoryClient client;

  setUp(() {
    fake = FakeSocket(joinPushes: const {'panel:memory:henry': _stateFrame});
    conn = AppConnection(
      connector: () async => fake.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    client = MemoryClient(connection: conn);
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

    expect(fake.joinedTopics, ['panel:memory:henry']);
    final s = client.state;
    expect(s, isNotNull);
    expect(s!.summary, 'Likes coffee.');
    expect(s.facts, hasLength(2));
    expect(s.facts[0].id, 1);
    expect(s.facts[0].content, 'Lives in Portland');
    expect(s.facts[0].source, 'chat');
    expect(s.facts[1].id, 2);
    expect(s.facts[1].content, 'Has a dog named Biscuit');
  });

  test(
      'a fact row with a missing id is skipped and its siblings still land',
      () async {
    final fake2 = FakeSocket(
        joinPushes: const {'panel:memory:henry': _malformedFrame});
    final c2 = AppConnection(
      connector: () async => fake2.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final mc = MemoryClient(connection: c2);
    addTearDown(() {
      mc.dispose();
      c2.dispose();
    });

    await c2.connect();
    mc.open();
    await pumpEventQueue();

    expect(mc.state, isNotNull);
    expect(mc.state!.facts, hasLength(1),
        reason: 'the row without an id must be dropped, not thrown');
    expect(mc.state!.facts.single.id, 2);
    expect(mc.state!.facts.single.content, 'Has a dog named Biscuit');
  });

  test('close() leaves the topic, clears state, and deregisters the topic',
      () async {
    await conn.connect();
    client.open();
    await pumpEventQueue();
    expect(client.state, isNotNull);
    expect(conn.debugListenerCount('panel:memory:henry'), 1);

    client.close();
    await pumpEventQueue();

    expect(client.isOpen, isFalse);
    expect(client.state, isNull,
        reason: 'a reopen re-fetches; a stale state is a ghost');
    expect(fake.sent.map((f) => jsonDecode(f as String)[3]),
        contains('phx_leave'));
    expect(conn.debugListenerCount('panel:memory:henry'), 0,
        reason: 'close() must deregister the topic from AppConnection, not '
            'merely stop rendering it locally');
  });

  test(
      'dispose() while open also deregisters the topic from the connection '
      'registry', () async {
    final fake2 =
        FakeSocket(joinPushes: const {'panel:memory:henry': _stateFrame});
    final c2 = AppConnection(
      connector: () async => fake2.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final mc = MemoryClient(connection: c2);
    addTearDown(c2.dispose);

    await c2.connect();
    mc.open();
    await pumpEventQueue();
    expect(c2.debugListenerCount('panel:memory:henry'), 1);

    mc.dispose();

    expect(c2.debugListenerCount('panel:memory:henry'), 0,
        reason:
            'dispose() must deregister the topic from AppConnection while open');
  });

  test('each of the four writes pushes the right event and payload',
      () async {
    await conn.connect();
    client.open();
    await pumpEventQueue();
    fake.sent.clear();

    client.saveSummary('New summary.');
    client.addFact('Likes tea.');
    client.deleteFact(3);
    client.forgetMe();

    final pushed = fake.sent
        .map((f) => jsonDecode(f as String) as List<dynamic>)
        .map((p) => [p[2], p[3], p[4]])
        .toList();
    expect(pushed, [
      [
        'panel:memory:henry',
        'save_summary',
        {'summary': 'New summary.'}
      ],
      [
        'panel:memory:henry',
        'add_fact',
        {'content': 'Likes tea.'}
      ],
      [
        'panel:memory:henry',
        'delete_fact',
        {'id': 3}
      ],
      ['panel:memory:henry', 'forget_me', {}],
    ]);
  });

  test('a write before the join reply is dropped, not sent into the void',
      () async {
    await conn.connect();
    client.open();
    fake.sent.clear();

    client.deleteFact(3); // no pump: the join reply has not landed
    expect(fake.sent, isEmpty);
  });

  test('forgetMe() invokes onLocalClear once joined', () async {
    var clears = 0;
    final fake2 =
        FakeSocket(joinPushes: const {'panel:memory:henry': _stateFrame});
    final c2 = AppConnection(
      connector: () async => fake2.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final mc = MemoryClient(connection: c2, onLocalClear: () => clears++);
    addTearDown(() {
      mc.dispose();
      c2.dispose();
    });

    await c2.connect();
    mc.open();
    await pumpEventQueue();

    mc.forgetMe();
    expect(clears, 1);
  });

  test(
      'forgetMe() does not invoke onLocalClear when the channel is not '
      'joined (open but pre-join-reply)', () async {
    var clears = 0;
    final fake2 =
        FakeSocket(joinPushes: const {'panel:memory:henry': _stateFrame});
    final c2 = AppConnection(
      connector: () async => fake2.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final mc = MemoryClient(connection: c2, onLocalClear: () => clears++);
    addTearDown(() {
      mc.dispose();
      c2.dispose();
    });

    await c2.connect();
    mc.open();
    // No pump: the join reply (and the state push behind it) has not landed,
    // so the channel exists but is not yet joined.

    mc.forgetMe();

    expect(clears, 0,
        reason: 'a write that never reached the server must not wipe the '
            'on-screen transcript');
    expect(fake2.sent.map((f) => jsonDecode(f as String)[3]),
        isNot(contains('forget_me')));
  });

  test(
      'forgetMe() does not invoke onLocalClear after the socket dies '
      'mid-session', () async {
    var clears = 0;
    final fake2 =
        FakeSocket(joinPushes: const {'panel:memory:henry': _stateFrame});
    final c2 = AppConnection(
      connector: () async => fake2.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final mc = MemoryClient(connection: c2, onLocalClear: () => clears++);
    addTearDown(() {
      mc.dispose();
      c2.dispose();
    });

    await c2.connect();
    mc.open();
    await pumpEventQueue();
    expect(mc.state, isNotNull, reason: 'sanity: the panel is fully joined');

    await fake2.kill();
    await pumpEventQueue();

    mc.forgetMe();

    expect(clears, 0,
        reason: 'the drawer stays on screen with cached state after a '
            'socket drop, but a dead channel must not fire the local wipe');
  });

  test('a refused panel leaves the conversation joined', () async {
    final refusing = FakeSocket(refuseTopics: const {'panel:memory:henry'});
    final c2 = AppConnection(
      connector: () async => refusing.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final mc = MemoryClient(connection: c2);
    addTearDown(() {
      mc.dispose();
      c2.dispose();
    });

    await c2.connect();
    mc.open();
    await pumpEventQueue();

    expect(c2.state, ConnState.joined);
    expect(mc.state, isNull);
  });
}
