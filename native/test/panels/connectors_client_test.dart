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
    '],"catalog":[]}]';

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
    '],"catalog":[]}]';

// A real-shaped catalog (calendar, matching connectors_channel.ex's own
// `catalog/0`) plus a SECOND connector whose only field carries a `type`
// this client has never heard of — proving an unfamiliar field type still
// parses instead of sinking the whole connector.
const String _catalogFrame = '[null,null,"panel:connectors:henry","state",'
    '{"connections":[],"catalog":['
    '{"key":"calendar","label":"Google Calendar","provider":"google",'
    '"kind":"oauth_redirect","fields":['
    '{"name":"account","label":"Account","type":"account_select","required":true},'
    '{"name":"level","label":"Access","type":"choice","required":true,'
    '"options":[{"value":"none","label":"none"},{"value":"read","label":"read"},'
    '{"value":"write","label":"write"}]}'
    ']},'
    '{"key":"home_assistant","label":"Home Assistant","provider":"home_assistant",'
    '"kind":"oauth_redirect","fields":['
    '{"name":"widget","label":"Widget","type":"future_unknown_type","required":false}'
    ']}'
    ']}]';

// One well-formed catalog entry, and one missing ONLY `key` — every other
// field (label, provider, kind, fields) is present and valid, so this pins
// the `key` filter specifically rather than "rejects obvious garbage".
const String _malformedCatalogFrame = '[null,null,"panel:connectors:henry","state",'
    '{"connections":[],"catalog":['
    '{"label":"Ghost","provider":"google","kind":"oauth_redirect","fields":['
    '{"name":"account","label":"Account","type":"account_select","required":true}'
    ']},'
    '{"key":"calendar","label":"Google Calendar","provider":"google",'
    '"kind":"oauth_redirect","fields":[]}'
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

/// Spin up a fresh (socket, connection, client) trio behind a given join
/// payload — the pattern the malformed-frame and catalog tests already need
/// more than once.
({FakeSocket fake, AppConnection conn, ConnectorsClient client}) _harness(
    String stateFrame) {
  final fake =
      FakeSocket(joinPushes: {'panel:connectors:henry': stateFrame});
  final conn = AppConnection(
    connector: () async => fake.socket,
    rejoinBackoff: const [Duration(days: 1)],
  );
  final client = ConnectorsClient(connection: conn);
  return (fake: fake, conn: conn, client: client);
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

    expect(s.catalog, isEmpty);
  });

  test(
      'a row missing account_id, and a row whose connector is not a string, '
      'are dropped while the good row still lands', () async {
    final h = _harness(_malformedFrame);
    addTearDown(() {
      h.client.dispose();
      h.conn.dispose();
    });

    await h.conn.connect();
    h.client.open();
    await pumpEventQueue();

    expect(h.client.state, isNotNull);
    expect(h.client.state!.connections, hasLength(1),
        reason: 'both bad rows must be dropped, not thrown, and must not '
            'blank the good row');
    expect(h.client.state!.connections.single.accountId, 4);
  });

  test('catalog parses, including a connector with UNKNOWN field types',
      () async {
    final h = _harness(_catalogFrame);
    addTearDown(() {
      h.client.dispose();
      h.conn.dispose();
    });

    await h.conn.connect();
    h.client.open();
    await pumpEventQueue();

    final catalog = h.client.state!.catalog;
    expect(catalog, hasLength(2));

    final calendar = catalog[0];
    expect(calendar.key, 'calendar');
    expect(calendar.label, 'Google Calendar');
    expect(calendar.provider, 'google');
    expect(calendar.kind, 'oauth_redirect');
    expect(calendar.fields, hasLength(2));
    expect(calendar.fields[0].name, 'account');
    expect(calendar.fields[0].label, 'Account');
    expect(calendar.fields[0].type, 'account_select');
    expect(calendar.fields[0].required, isTrue);
    expect(calendar.fields[1].name, 'level');
    expect(calendar.fields[1].type, 'choice');
    expect(calendar.fields[1].options.map((o) => o.value),
        ['none', 'read', 'write']);
    expect(calendar.fields[1].options.map((o) => o.label),
        ['none', 'read', 'write']);

    // The second connector's only field carries a type this client has never
    // heard of. It must still parse — dropping the connector here would hide
    // a server capability; rendering the unknown type is Task 4's problem.
    final ha = catalog[1];
    expect(ha.key, 'home_assistant');
    expect(ha.provider, 'home_assistant');
    expect(ha.fields, hasLength(1));
    expect(ha.fields.single.name, 'widget');
    expect(ha.fields.single.type, 'future_unknown_type');
  });

  test(
      'a catalog entry missing key is dropped while its well-formed sibling '
      'lands', () async {
    final h = _harness(_malformedCatalogFrame);
    addTearDown(() {
      h.client.dispose();
      h.conn.dispose();
    });

    await h.conn.connect();
    h.client.open();
    await pumpEventQueue();

    final catalog = h.client.state!.catalog;
    expect(catalog, hasLength(1),
        reason: 'the keyless entry must be dropped even though every other '
            'field on it is well-formed');
    expect(catalog.single.key, 'calendar');
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

  test('grantUrl pushes connector and fields', () async {
    await conn.connect();
    client.open();
    await pumpEventQueue();
    fake.sent.clear();

    client.grantUrl(
      connector: 'calendar',
      fields: {'account': 'new', 'level': 'write'},
    );

    final frame = fake.textFrames.last;
    expect(frame[3], 'grant_url');
    expect(frame[4], {
      'connector': 'calendar',
      'fields': {'account': 'new', 'level': 'write'},
    });
  });

  test('a grantUrl push before the join reply is dropped, not sent into the void',
      () async {
    await conn.connect();
    client.open();
    // No pump: the join reply has not landed yet.

    client.grantUrl(
      connector: 'calendar',
      fields: {'account': 'new', 'level': 'write'},
    );

    expect(fake.textFrames.where((p) => p[3] == 'grant_url'), isEmpty);
  });

  test('oauthUrl is surfaced from an :ok grant_url reply', () async {
    await conn.connect();
    client.open();
    await pumpEventQueue();

    client.grantUrl(
      connector: 'calendar',
      fields: {'account': 'new', 'level': 'write'},
    );
    replyTo(fake, 'grant_url', 'ok',
        {'url': 'https://accounts.google.com/o/oauth2/consent'});
    await pumpEventQueue();

    expect(client.oauthUrl, 'https://accounts.google.com/o/oauth2/consent');
  });

  test('oauthUrl is also surfaced from disconnect\'s reduction reply',
      () async {
    await conn.connect();
    client.open();
    await pumpEventQueue();

    client.disconnect(accountId: 4, connector: 'calendar');
    replyTo(fake, 'disconnect', 'ok',
        {'url': 'https://accounts.google.com/o/oauth2/reduce'});
    await pumpEventQueue();

    expect(client.oauthUrl, 'https://accounts.google.com/o/oauth2/reduce');
  });

  test('oauthUrl is not surfaced from an :error grant_url reply', () async {
    await conn.connect();
    client.open();
    await pumpEventQueue();

    client.grantUrl(
      connector: 'calendar',
      fields: {'account': 'new', 'level': 'write'},
    );
    // The error response carries a `url` key too (a server bug, or just a
    // coincidental shape) — proving the :ok/:error status itself gates
    // surfacing, not merely the absence of a `url` in typical error bodies.
    replyTo(fake, 'grant_url', 'error',
        {'reason': 'bad_request', 'url': 'https://should-not-surface.example'});
    await pumpEventQueue();

    expect(client.oauthUrl, isNull);
  });

  test(
      'oauthUrl does not rise on a transport failure — no reply arrives at '
      'all', () async {
    await conn.connect();
    client.open();
    await pumpEventQueue();

    client.grantUrl(
      connector: 'calendar',
      fields: {'account': 'new', 'level': 'write'},
    );
    await fake.kill();
    await pumpEventQueue();

    expect(client.oauthUrl, isNull,
        reason: 'a dead socket produces no reply at all, and must not be '
            'confused with an answered request');
  });

  test('ackOauthUrl clears oauthUrl and notifies', () async {
    await conn.connect();
    client.open();
    await pumpEventQueue();

    client.grantUrl(
      connector: 'calendar',
      fields: {'account': 'new', 'level': 'write'},
    );
    replyTo(fake, 'grant_url', 'ok', {'url': 'https://example.com/consent'});
    await pumpEventQueue();
    expect(client.oauthUrl, isNotNull);

    var notified = false;
    client.addListener(() => notified = true);
    client.ackOauthUrl();

    expect(client.oauthUrl, isNull);
    expect(notified, isTrue);
  });

  test(
      'a second push while one is pending is dropped, so a url can never '
      'answer the wrong request', () async {
    await conn.connect();
    client.open();
    await pumpEventQueue();
    fake.sent.clear();

    client.grantUrl(
      connector: 'calendar',
      fields: {'account': 'new', 'level': 'write'},
    );
    expect(fake.textFrames.where((p) => p[3] == 'grant_url'), hasLength(1));

    // The user cannot actually tap Disconnect yet in the real app (the form
    // is mid-submit), but if this push were queued instead of dropped, the
    // grant_url reply that arrives next would be indistinguishable from a
    // reply to THIS disconnect — the exact misattribution this design must
    // not allow.
    client.disconnect(accountId: 4, connector: 'calendar');
    expect(fake.textFrames.where((p) => p[3] == 'disconnect'), isEmpty,
        reason: 'a request must not be sent while another is outstanding — '
            'that is what keeps a reply from ever answering the wrong '
            'request');

    replyTo(fake, 'grant_url', 'ok',
        {'url': 'https://accounts.google.com/grant'});
    await pumpEventQueue();

    expect(client.oauthUrl, 'https://accounts.google.com/grant');

    // The slot is free again now that grant_url's reply landed, so the
    // disconnect the user retries goes through.
    client.disconnect(accountId: 4, connector: 'calendar');
    expect(fake.textFrames.where((p) => p[3] == 'disconnect'), hasLength(1));
  });

  test(
      'close() leaves the topic, clears state, clears oauthUrl, and '
      'deregisters the topic', () async {
    await conn.connect();
    client.open();
    await pumpEventQueue();
    client.grantUrl(
      connector: 'calendar',
      fields: {'account': 'new', 'level': 'write'},
    );
    replyTo(fake, 'grant_url', 'ok', {'url': 'https://example.com/consent'});
    await pumpEventQueue();
    expect(client.state, isNotNull);
    expect(client.oauthUrl, isNotNull);
    expect(conn.debugListenerCount('panel:connectors:henry'), 1);

    client.close();
    await pumpEventQueue();

    expect(client.isOpen, isFalse);
    expect(client.state, isNull);
    expect(client.oauthUrl, isNull);
    expect(fake.sent.map((f) => jsonDecode(f as String)[3]),
        contains('phx_leave'));
    expect(conn.debugListenerCount('panel:connectors:henry'), 0,
        reason: 'close() must deregister the topic from AppConnection, not '
            'merely stop rendering it locally');
  });

  test(
      'dispose() while open also deregisters the topic from the connection '
      'registry', () async {
    final h = _harness(_stateFrame);
    addTearDown(h.conn.dispose);

    await h.conn.connect();
    h.client.open();
    await pumpEventQueue();
    expect(h.conn.debugListenerCount('panel:connectors:henry'), 1);

    h.client.dispose();

    expect(h.conn.debugListenerCount('panel:connectors:henry'), 0,
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
