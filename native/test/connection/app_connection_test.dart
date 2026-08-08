import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/connection/app_connection.dart';
import 'package:henry_wall/meridian/tokens.dart';
import 'package:henry_wall/phoenix/phoenix_socket.dart';
import 'package:stream_channel/stream_channel.dart';

/// One in-memory socket that answers joins, and can be killed to simulate a
/// server bounce.
class FakeSocket {
  FakeSocket({this.refuseJoins = false}) {
    ctrl.foreign.stream.listen((f) {
      sent.add(f);
      final parts = jsonDecode(f as String) as List<dynamic>;
      if (parts[3] != 'phx_join') return;
      final status = refuseJoins ? 'error' : 'ok';
      scheduleMicrotask(() {
        if (closed) return;
        ctrl.foreign.sink.add(jsonEncode(
            [null, parts[1], parts[2], 'phx_reply', {'status': status, 'response': {}}]));
      });
    });
    socket = PhoenixSocket(ctrl.local, heartbeatInterval: const Duration(days: 1));
    socket.start();
  }

  final bool refuseJoins;
  final ctrl = StreamChannelController<dynamic>(sync: true);
  final sent = <dynamic>[];
  late final PhoenixSocket socket;
  bool closed = false;

  List<String> get joinedTopics => sent
      .map((f) => jsonDecode(f as String) as List<dynamic>)
      .where((p) => p[3] == 'phx_join')
      .map((p) => p[2] as String)
      .toList();

  Future<void> kill() async {
    closed = true;
    await ctrl.foreign.sink.close();
  }
}

void main() {
  test('connStatus maps the socket state onto the header dot', () async {
    final conn = AppConnection(
      connector: () async => FakeSocket().socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    addTearDown(conn.dispose);

    expect(conn.connStatus, ConnStatus.connecting); // idle
    await conn.connect();
    expect(conn.connStatus, ConnStatus.connected);
  });

  test('a dead socket schedules a rejoin that reconnects', () async {
    final sockets = <FakeSocket>[];
    final conn = AppConnection(
      connector: () async {
        final s = FakeSocket();
        sockets.add(s);
        return s.socket;
      },
      rejoinBackoff: const [Duration(milliseconds: 10)],
    );
    addTearDown(conn.dispose);

    await conn.connect();
    expect(sockets, hasLength(1));

    await sockets.first.kill();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await pumpEventQueue();

    expect(sockets, hasLength(2));
    expect(conn.state, ConnState.joined);
  });

  test('a reconnect re-joins EVERY open channel, not just the first', () async {
    final sockets = <FakeSocket>[];
    final conn = AppConnection(
      connector: () async {
        final s = FakeSocket();
        sockets.add(s);
        return s.socket;
      },
      rejoinBackoff: const [Duration(milliseconds: 10)],
    );
    addTearDown(conn.dispose);

    await conn.connect();
    conn.openChannel('voice:henry');
    conn.openChannel('panel:reminders:1');
    await pumpEventQueue();

    await sockets.first.kill();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await pumpEventQueue();

    expect(sockets, hasLength(2));
    expect(sockets.last.joinedTopics,
        containsAll(<String>['voice:henry', 'panel:reminders:1']),
        reason: 'a panel opened before the outage must come back with the voice');
  });

  test('openChannel after a reconnect returns the LIVE channel', () async {
    final sockets = <FakeSocket>[];
    final conn = AppConnection(
      connector: () async {
        final s = FakeSocket();
        sockets.add(s);
        return s.socket;
      },
      rejoinBackoff: const [Duration(milliseconds: 10)],
    );
    addTearDown(conn.dispose);

    await conn.connect();
    final before = conn.openChannel('voice:henry');
    // Let the join actually land before killing the socket: a channel that's
    // still MID-join when its socket dies is caught by openChannel()'s own
    // join-failure watcher instead, which would mask what this test is
    // pinning — the socket-level teardown path.
    await pumpEventQueue();
    await sockets.first.kill();
    await pumpEventQueue();

    // Mid-outage: the socket is down and the scheduled rejoin has not landed
    // yet (its backoff Timer has not fired — pumpEventQueue only drains
    // microtasks). A stale channel handed back here would be a consumer
    // pushing into a closed sink forever, and by the time the reconnect has
    // actually landed this would already be masked by connect()'s own
    // channel rebuild.
    final duringOutage = conn.openChannel('voice:henry');
    expect(identical(duringOutage, before), isFalse,
        reason: 'the old channel died with its socket; handing it back mid-outage '
            'would be a consumer pushing into a closed sink forever');

    await Future<void>.delayed(const Duration(milliseconds: 60));
    await pumpEventQueue();

    final after = conn.openChannel('voice:henry');
    expect(identical(before, after), isFalse,
        reason: 'the old channel died with its socket; handing it back would be '
            'a consumer pushing into a closed sink forever');
    expect(after, isNotNull);
  });

  test('a deliberate disconnect() does not reconnect', () async {
    final sockets = <FakeSocket>[];
    final conn = AppConnection(
      connector: () async {
        final s = FakeSocket();
        sockets.add(s);
        return s.socket;
      },
      rejoinBackoff: const [Duration(milliseconds: 10)],
    );
    addTearDown(conn.dispose);

    await conn.connect();
    await conn.disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(sockets, hasLength(1), reason: 'the backoff must respect the intent flag');
    expect(conn.state, ConnState.idle);
  });

  test('a refused join leaves the socket closed and keeps retrying', () async {
    final sockets = <FakeSocket>[];
    final conn = AppConnection(
      connector: () async {
        final s = FakeSocket(refuseJoins: true);
        sockets.add(s);
        return s.socket;
      },
      rejoinBackoff: const [Duration(milliseconds: 10)],
    );
    addTearDown(conn.dispose);

    await conn.connect();
    conn.openChannel('voice:henry');
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(sockets.length, greaterThan(1), reason: 'the backoff must keep retrying');
    await conn.disconnect();
    await pumpEventQueue();
    expect(sockets.every((s) => !s.socket.debugHeartbeatActive), isTrue,
        reason: 'every retry used to leak a live socket + heartbeat timer');
  });

  test('onJoined fires after each successful (re)join', () async {
    final sockets = <FakeSocket>[];
    final conn = AppConnection(
      connector: () async {
        final s = FakeSocket();
        sockets.add(s);
        return s.socket;
      },
      rejoinBackoff: const [Duration(milliseconds: 10)],
    );
    addTearDown(conn.dispose);

    var joins = 0;
    conn.onJoined.listen((_) => joins++);

    await conn.connect();
    await pumpEventQueue();
    expect(joins, 1);

    await sockets.first.kill();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await pumpEventQueue();
    expect(joins, 2, reason: 'consumers re-announce their toggles on this');
  });

  test('dispose() during connect() closes the socket it was awaiting', () async {
    late FakeSocket fake;
    final conn = AppConnection(
      connector: () async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        fake = FakeSocket();
        return fake.socket;
      },
    );

    final connecting = conn.connect();
    conn.dispose();
    await connecting;
    await pumpEventQueue();

    expect(fake.socket.debugHeartbeatActive, isFalse,
        reason: 'a dispose inside the await used to leak an open socket forever');
  });
}
