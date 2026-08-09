import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/connection/app_connection.dart';
import 'package:henry_wall/panels/badges_client.dart';

import '../support/fake_socket.dart';

void main() {
  test('the count arrives even though the server pushes it behind the join reply',
      () async {
    // `messages` is an unbuffered broadcast stream and the server pushes
    // `badges` from :push_badges immediately behind its reply, so a client that
    // subscribed on JOIN instead of on CREATION would miss it every connect.
    final fake = FakeSocket(joinPushes: const {
      'badges:henry': '[null,null,"badges:henry","badges",{"reminders":2}]',
    });
    final conn = AppConnection(
      connector: () async => fake.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final badges = BadgesClient(connection: conn);
    addTearDown(() {
      badges.dispose();
      conn.dispose();
    });

    await conn.connect();
    await pumpEventQueue();

    expect(badges.count('reminders'), 2);
    expect(badges.hasDue, isTrue);
  });

  test('a later push replaces the counts and notifies', () async {
    final fake = FakeSocket(joinPushes: const {
      'badges:henry': '[null,null,"badges:henry","badges",{"reminders":2}]',
    });
    final conn = AppConnection(
      connector: () async => fake.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final badges = BadgesClient(connection: conn);
    addTearDown(() {
      badges.dispose();
      conn.dispose();
    });

    var notifications = 0;
    badges.addListener(() => notifications++);

    await conn.connect();
    await pumpEventQueue();

    fake.ctrl.foreign.sink
        .add('[null,null,"badges:henry","badges",{"reminders":0}]');
    await pumpEventQueue();

    expect(badges.count('reminders'), 0);
    expect(badges.hasDue, isFalse);
    expect(notifications, 2);
  });

  test('an unknown panel reads zero, not null', () {
    final conn = AppConnection(connector: () async => throw StateError('no socket'));
    final badges = BadgesClient(connection: conn);
    addTearDown(() {
      badges.dispose();
      conn.dispose();
    });
    expect(badges.count('books'), 0);
    expect(badges.hasDue, isFalse);
  });

  test('the badges topic is NOT essential', () async {
    // A refused badge count must not drive the reconnect machine or take the
    // conversation down with it.
    final sockets = <FakeSocket>[];
    final conn = AppConnection(
      connector: () async {
        final s = FakeSocket(refuseTopics: const {'badges:henry'});
        sockets.add(s);
        return s.socket;
      },
      rejoinBackoff: const [Duration(milliseconds: 10)],
    );
    final badges = BadgesClient(connection: conn);
    addTearDown(() {
      badges.dispose();
      conn.dispose();
    });

    await conn.connect();
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(sockets, hasLength(1), reason: 'a refused badge must not retry the socket');
    expect(conn.state, ConnState.joined);
  });

  test('dispose() removes the listener from the connection registry, not just '
      'the local handle', () async {
    // A downstream symptom test (e.g. "no more counts after dispose") can pass
    // even with a broken dropListener call: _onMessage's own `_disposed` guard
    // hides the leak from every observation made through BadgesClient itself.
    // State the invariant directly — the closure must leave AppConnection's
    // registry, or it sits there forever, growing by one every time a
    // BadgesClient is rebuilt (e.g. on every hot restart / screen rebuild).
    final fake = FakeSocket();
    final conn = AppConnection(connector: () async => fake.socket);
    addTearDown(conn.dispose);
    final badges = BadgesClient(connection: conn);

    await conn.connect();
    await pumpEventQueue();
    expect(conn.debugListenerCount('badges:henry'), 1);

    badges.dispose();

    expect(conn.debugListenerCount('badges:henry'), 0,
        reason: 'dispose() must deregister _adopt, not merely guard it');
  });

  test('an event other than "badges" on the topic is ignored', () async {
    final fake = FakeSocket(joinPushes: const {
      'badges:henry': '[null,null,"badges:henry","badges",{"reminders":2}]',
    });
    final conn = AppConnection(
      connector: () async => fake.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final badges = BadgesClient(connection: conn);
    addTearDown(() {
      badges.dispose();
      conn.dispose();
    });

    await conn.connect();
    await pumpEventQueue();
    expect(badges.count('reminders'), 2);

    // Some other frame on the same topic (e.g. a phx presence/heartbeat-shaped
    // event) must not be mistaken for a badges push.
    fake.ctrl.foreign.sink
        .add('[null,null,"badges:henry","presence_diff",{"reminders":99}]');
    await pumpEventQueue();

    expect(badges.count('reminders'), 2,
        reason: 'a non-"badges" event must not overwrite the counts');
  });
}
