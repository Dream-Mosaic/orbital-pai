import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/connection/app_connection.dart';
import 'package:henry_wall/panels/connectors_client.dart';

import '../support/fake_socket.dart';

// Emails are deliberately the REVERSE of label order (gmail's email sorts
// after calendar's): the server orders by {label, email}, so this row order
// (gmail first) only survives if the client does not re-sort by email. A
// client-side sort-by-email would put the calendar row first instead, which
// is exactly the mutation this fixture exists to catch — see
// "connections arrive in the server's order, not re-sorted" below.
const String _stateFrame = '[null,null,"panel:connectors:henry","state",'
    '{"connections":['
    '{"account_id":3,"email":"z@b.com","connector":"gmail","label":"Gmail",'
    '"access":"read","is_default":false,"shows_default":false,"only_grant":true},'
    '{"account_id":4,"email":"a@d.com","connector":"calendar",'
    '"label":"Google Calendar","access":"write","is_default":true,'
    '"shows_default":true,"only_grant":false}'
    ']}]';

// One well-formed row, one with a missing account_id, one whose connector is a
// number — proves the bad rows are dropped without blanking the payload.
const String _malformedFrame = '[null,null,"panel:connectors:henry","state",'
    '{"connections":['
    '{"email":"no@id.com","connector":"gmail","label":"Gmail","access":"read",'
    '"is_default":false,"shows_default":false,"only_grant":true},'
    '{"account_id":9,"email":"n@c.com","connector":7,"label":"Gmail",'
    '"access":"read","is_default":false,"shows_default":false,"only_grant":true},'
    '{"account_id":4,"email":"c@d.com","connector":"calendar",'
    '"label":"Google Calendar","access":"write","is_default":true,'
    '"shows_default":true,"only_grant":false}'
    ']}]';

/// Answer a frame the client just pushed, echoing its own ref so the socket
/// routes the reply back to that channel. FakeSocket only auto-answers
/// phx_join, so this is how a test drives a handler's reply.
void replyTo(FakeSocket fake, String event, String status,
    Map<String, dynamic> response) {
  final frame = fake.textFrames.lastWhere((p) => p[3] == event);
  fake.ctrl.foreign.sink.add(jsonEncode([
    frame[0],
    frame[1],
    frame[2],
    'phx_reply',
    {'status': status, 'response': response},
  ]));
}

void main() {
  late FakeSocket fake;
  late AppConnection conn;
  late ConnectorsClient client;

  setUp(() {
    fake =
        FakeSocket(joinPushes: const {'panel:connectors:henry': _stateFrame});
    conn = AppConnection(
      connector: () async => fake.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    client = ConnectorsClient(connection: conn);
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

  test(
      'open() joins and the state behind the join reply lands, both rows, '
      'in the server order, every field parsed', () async {
    await conn.connect();
    client.open();
    await pumpEventQueue();

    expect(fake.joinedTopics, ['panel:connectors:henry']);
    final s = client.state;
    expect(s, isNotNull);
    expect(s!.connections, hasLength(2));

    // gmail arrives FIRST despite its email ('z@b.com') sorting after the
    // calendar row's ('a@d.com') — proving the order is the server's
    // {label, email} order, not a client-side re-sort by any single field.
    final gmail = s.connections[0];
    expect(gmail.accountId, 3);
    expect(gmail.email, 'z@b.com');
    expect(gmail.connector, 'gmail');
    expect(gmail.label, 'Gmail');
    expect(gmail.access, 'read');
    expect(gmail.isDefault, isFalse);
    expect(gmail.showsDefault, isFalse);
    expect(gmail.onlyGrant, isTrue);

    final calendar = s.connections[1];
    expect(calendar.accountId, 4);
    expect(calendar.email, 'a@d.com');
    expect(calendar.connector, 'calendar');
    expect(calendar.label, 'Google Calendar');
    expect(calendar.access, 'write');
    expect(calendar.isDefault, isTrue);
    expect(calendar.showsDefault, isTrue);
    expect(calendar.onlyGrant, isFalse);
  });

  test(
      'a row missing account_id, and a row whose connector is not a string, '
      'are dropped while the good row still lands', () async {
    final fake2 = FakeSocket(
        joinPushes: const {'panel:connectors:henry': _malformedFrame});
    final c2 = AppConnection(
      connector: () async => fake2.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final cc = ConnectorsClient(connection: c2);
    addTearDown(() {
      cc.dispose();
      c2.dispose();
    });

    await c2.connect();
    cc.open();
    await pumpEventQueue();

    expect(cc.state, isNotNull);
    expect(cc.state!.connections, hasLength(1),
        reason: 'both bad rows must be dropped, not thrown, and must not '
            'blank the good row');
    expect(cc.state!.connections.single.accountId, 4);
  });

  test('setDefault pushes set_default with the account id', () async {
    await conn.connect();
    client.open();
    await pumpEventQueue();
    fake.sent.clear();

    client.setDefault(3);

    final frame = fake.textFrames.last;
    expect(frame[3], 'set_default');
    expect(frame[4], {'account_id': 3});
  });

  test(
      'disconnect pushes disconnect with account id and connector, and no '
      'only_grant key', () async {
    await conn.connect();
    client.open();
    await pumpEventQueue();
    fake.sent.clear();

    client.disconnect(accountId: 3, connector: 'gmail');

    final frame = fake.textFrames.last;
    expect(frame[3], 'disconnect');
    expect(frame[4], {'account_id': 3, 'connector': 'gmail'});
    expect((frame[4] as Map).containsKey('only_grant'), isFalse,
        reason: 'the server re-derives only_grant; a client that sends one '
            'is offering a stale answer');
  });

  test('a setDefault before the join reply is dropped, not sent into the void',
      () async {
    await conn.connect();
    client.open();
    // No pump: the join reply has not landed yet.

    client.setDefault(3);

    expect(fake.textFrames.where((p) => p[3] == 'set_default'), isEmpty);
  });

  test('needsWeb rises on a needs_web reply, and ackNeedsWeb clears it',
      () async {
    await conn.connect();
    client.open();
    await pumpEventQueue();

    client.disconnect(accountId: 3, connector: 'gmail');
    replyTo(fake, 'disconnect', 'error', {'reason': 'needs_web'});
    await pumpEventQueue();

    expect(client.needsWeb, isTrue);

    var notified = false;
    client.addListener(() => notified = true);
    client.ackNeedsWeb();

    expect(client.needsWeb, isFalse);
    expect(notified, isTrue);
  });

  test('needsWeb does not rise on a bad_request reply', () async {
    await conn.connect();
    client.open();
    await pumpEventQueue();

    client.disconnect(accountId: 3, connector: 'gmail');
    replyTo(fake, 'disconnect', 'error', {'reason': 'bad_request'});
    await pumpEventQueue();

    expect(client.needsWeb, isFalse);
  });

  test('needsWeb does not rise on an ok reply', () async {
    await conn.connect();
    client.open();
    await pumpEventQueue();

    client.disconnect(accountId: 3, connector: 'gmail');
    replyTo(fake, 'disconnect', 'ok', {});
    await pumpEventQueue();

    expect(client.needsWeb, isFalse);
  });

  test(
      'needsWeb does not rise on a transport failure — the distinction from '
      'a genuine refusal', () async {
    await conn.connect();
    client.open();
    await pumpEventQueue();

    client.disconnect(accountId: 3, connector: 'gmail');
    await fake.kill();
    await pumpEventQueue();

    expect(client.needsWeb, isFalse,
        reason: 'a dead socket produces no reply at all, and must not be '
            'confused with a needs_web refusal');
  });

  test(
      'close() leaves the topic, clears state, clears needsWeb, and '
      'deregisters the topic', () async {
    await conn.connect();
    client.open();
    await pumpEventQueue();
    client.disconnect(accountId: 3, connector: 'gmail');
    replyTo(fake, 'disconnect', 'error', {'reason': 'needs_web'});
    await pumpEventQueue();
    expect(client.state, isNotNull);
    expect(client.needsWeb, isTrue);
    expect(conn.debugListenerCount('panel:connectors:henry'), 1);

    client.close();
    await pumpEventQueue();

    expect(client.isOpen, isFalse);
    expect(client.state, isNull);
    expect(client.needsWeb, isFalse);
    expect(fake.sent.map((f) => jsonDecode(f as String)[3]),
        contains('phx_leave'));
    expect(conn.debugListenerCount('panel:connectors:henry'), 0,
        reason: 'close() must deregister the topic from AppConnection, not '
            'merely stop rendering it locally');
  });

  test(
      'dispose() while open also deregisters the topic from the connection '
      'registry', () async {
    final fake2 = FakeSocket(
        joinPushes: const {'panel:connectors:henry': _stateFrame});
    final c2 = AppConnection(
      connector: () async => fake2.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final cc = ConnectorsClient(connection: c2);
    addTearDown(c2.dispose);

    await c2.connect();
    cc.open();
    await pumpEventQueue();
    expect(c2.debugListenerCount('panel:connectors:henry'), 1);

    cc.dispose();

    expect(c2.debugListenerCount('panel:connectors:henry'), 0,
        reason:
            'dispose() must deregister the topic from AppConnection while open');
  });

  test('a refused panel leaves the conversation alone', () async {
    final refusing =
        FakeSocket(refuseTopics: const {'panel:connectors:henry'});
    final c2 = AppConnection(
      connector: () async => refusing.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final cc = ConnectorsClient(connection: c2);
    addTearDown(() {
      cc.dispose();
      c2.dispose();
    });

    await c2.connect();
    cc.open();
    await pumpEventQueue();

    expect(c2.state, ConnState.joined);
    expect(cc.state, isNull);
  });
}
