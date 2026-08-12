import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/connection/app_connection.dart';
import 'package:henry_wall/panels/settings_client.dart';

import '../support/fake_socket.dart';

const String _stateFrame =
    '[null,null,"panel:settings:henry","state",'
    '{"default_abi":true,"default_ptt":false,"voice_activation":true,'
    '"briefing_time":"07:00","relock_seconds":15,"app_version":"0.4.19"}]';

// Same payload except the morning briefing is off — proves the parse lands
// Dart null, not the string "null".
const String _nullBriefingFrame =
    '[null,null,"panel:settings:henry","state",'
    '{"default_abi":true,"default_ptt":false,"voice_activation":true,'
    '"briefing_time":null,"relock_seconds":15,"app_version":"0.4.19"}]';

void main() {
  late FakeSocket fake;
  late AppConnection conn;
  late SettingsClient client;

  setUp(() {
    fake =
        FakeSocket(joinPushes: const {'panel:settings:henry': _stateFrame});
    conn = AppConnection(
      connector: () async => fake.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    client = SettingsClient(connection: conn);
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

  test('open() joins and the state behind the join reply lands, every field',
      () async {
    await conn.connect();
    client.open();
    await pumpEventQueue();

    expect(fake.joinedTopics, ['panel:settings:henry']);
    final s = client.state;
    expect(s, isNotNull);
    expect(s!.defaultAbi, isTrue);
    expect(s.defaultPtt, isFalse);
    expect(s.voiceActivation, isTrue);
    expect(s.briefingTime, '07:00');
    expect(s.relockSeconds, 15);
    expect(s.appVersion, '0.4.19');
  });

  test('a frame with briefing_time null parses to null, not the string "null"',
      () async {
    final fake2 = FakeSocket(
        joinPushes: const {'panel:settings:henry': _nullBriefingFrame});
    final c2 = AppConnection(
      connector: () async => fake2.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final sc = SettingsClient(connection: c2);
    addTearDown(() {
      sc.dispose();
      c2.dispose();
    });

    await c2.connect();
    sc.open();
    await pumpEventQueue();

    expect(sc.state!.briefingTime, isNull);
  });

  test('close() leaves the topic, clears state, and deregisters the topic',
      () async {
    await conn.connect();
    client.open();
    await pumpEventQueue();
    expect(client.state, isNotNull);
    expect(conn.debugListenerCount('panel:settings:henry'), 1);

    client.close();
    await pumpEventQueue();

    expect(client.isOpen, isFalse);
    expect(client.state, isNull,
        reason: 'a reopen re-fetches; a stale state is a ghost');
    expect(fake.sent.map((f) => jsonDecode(f as String)[3]),
        contains('phx_leave'));
    expect(conn.debugListenerCount('panel:settings:henry'), 0,
        reason: 'close() must deregister the topic from AppConnection, not '
            'merely stop rendering it locally');
  });

  test(
      'dispose() while open also deregisters the topic from the connection '
      'registry', () async {
    final fake2 =
        FakeSocket(joinPushes: const {'panel:settings:henry': _stateFrame});
    final c2 = AppConnection(
      connector: () async => fake2.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final sc = SettingsClient(connection: c2);
    addTearDown(c2.dispose);

    await c2.connect();
    sc.open();
    await pumpEventQueue();
    expect(c2.debugListenerCount('panel:settings:henry'), 1);

    sc.dispose();

    expect(c2.debugListenerCount('panel:settings:henry'), 0,
        reason:
            'dispose() must deregister the topic from AppConnection while open');
  });

  test('each of the five writes pushes the right event and payload',
      () async {
    await conn.connect();
    client.open();
    await pumpEventQueue();
    fake.sent.clear();

    client.setPref('default_ptt', true);
    client.setBriefing('06:30');
    client.setBriefing(null);
    client.setRelock(20);
    client.clearTurns();
    client.forgetMe();

    final pushed = fake.sent
        .map((f) => jsonDecode(f as String) as List<dynamic>)
        .map((p) => [p[2], p[3], p[4]])
        .toList();
    expect(pushed, [
      [
        'panel:settings:henry',
        'set_pref',
        {'pref': 'default_ptt', 'value': true}
      ],
      [
        'panel:settings:henry',
        'set_briefing',
        {'time': '06:30'}
      ],
      [
        'panel:settings:henry',
        'set_briefing',
        {'time': null}
      ],
      [
        'panel:settings:henry',
        'set_relock',
        {'seconds': 20}
      ],
      ['panel:settings:henry', 'clear_turns', {}],
      ['panel:settings:henry', 'forget_me', {}],
    ]);
  });

  test('a write before the join reply is dropped, not sent into the void',
      () async {
    await conn.connect();
    client.open();
    fake.sent.clear();

    client.setRelock(20); // no pump: the join reply has not landed
    expect(fake.sent, isEmpty);
  });

  test('clearTurns() and forgetMe() invoke onLocalClear; setPref does not',
      () async {
    var clears = 0;
    final fake2 =
        FakeSocket(joinPushes: const {'panel:settings:henry': _stateFrame});
    final c2 = AppConnection(
      connector: () async => fake2.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final sc =
        SettingsClient(connection: c2, onLocalClear: () => clears++);
    addTearDown(() {
      sc.dispose();
      c2.dispose();
    });

    await c2.connect();
    sc.open();
    await pumpEventQueue();

    sc.setPref('default_ptt', true);
    expect(clears, 0, reason: 'a plain preference write is not destructive');

    sc.clearTurns();
    expect(clears, 1);

    sc.forgetMe();
    expect(clears, 2);
  });

  test(
      'clearTurns()/forgetMe() do not invoke onLocalClear when the channel '
      'is not joined (open but pre-join-reply)', () async {
    var clears = 0;
    final fake2 =
        FakeSocket(joinPushes: const {'panel:settings:henry': _stateFrame});
    final c2 = AppConnection(
      connector: () async => fake2.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final sc = SettingsClient(connection: c2, onLocalClear: () => clears++);
    addTearDown(() {
      sc.dispose();
      c2.dispose();
    });

    await c2.connect();
    sc.open();
    // No pump: the join reply (and the state push behind it) has not landed,
    // so the channel exists but is not yet joined.

    sc.clearTurns();
    sc.forgetMe();

    expect(clears, 0,
        reason: 'a write that never reached the server must not wipe the '
            'on-screen transcript');
    expect(fake2.sent.map((f) => jsonDecode(f as String)[3]),
        isNot(contains('clear_turns')));
    expect(fake2.sent.map((f) => jsonDecode(f as String)[3]),
        isNot(contains('forget_me')));
  });

  test(
      'clearTurns()/forgetMe() do not invoke onLocalClear after the socket '
      'dies mid-session', () async {
    var clears = 0;
    final fake2 =
        FakeSocket(joinPushes: const {'panel:settings:henry': _stateFrame});
    final c2 = AppConnection(
      connector: () async => fake2.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final sc = SettingsClient(connection: c2, onLocalClear: () => clears++);
    addTearDown(() {
      sc.dispose();
      c2.dispose();
    });

    await c2.connect();
    sc.open();
    await pumpEventQueue();
    expect(sc.state, isNotNull, reason: 'sanity: the panel is fully joined');

    await fake2.kill();
    await pumpEventQueue();

    sc.clearTurns();
    sc.forgetMe();

    expect(clears, 0,
        reason: 'the drawer stays on screen with cached state after a '
            'socket drop, but a dead channel must not fire the local wipe');
  });

  test('a refused panel leaves the conversation joined', () async {
    final refusing = FakeSocket(refuseTopics: const {'panel:settings:henry'});
    final c2 = AppConnection(
      connector: () async => refusing.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final sc = SettingsClient(connection: c2);
    addTearDown(() {
      sc.dispose();
      c2.dispose();
    });

    await c2.connect();
    sc.open();
    await pumpEventQueue();

    expect(c2.state, ConnState.joined);
    expect(sc.state, isNull);
  });
}
