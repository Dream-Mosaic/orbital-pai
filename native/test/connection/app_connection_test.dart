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
  FakeSocket({
    this.refuseJoins = false,
    this.refuseTopics = const <String>{},
    this.silentTopics = const <String>{},
    this.joinPushes = const <String, String>{},
  }) {
    ctrl.foreign.stream.listen((f) {
      sent.add(f);
      final parts = jsonDecode(f as String) as List<dynamic>;
      if (parts[3] != 'phx_join') return;
      final topic = parts[2] as String;
      if (silentTopics.contains(topic)) return;
      final status = (refuseJoins || refuseTopics.contains(topic)) ? 'error' : 'ok';
      scheduleMicrotask(() {
        if (closed) return;
        ctrl.foreign.sink.add(jsonEncode(
            [null, parts[1], topic, 'phx_reply', {'status': status, 'response': {}}]));
        // Straight behind the reply, in the SAME turn — exactly what
        // VoiceChannel does (`set_client` inside join/3 pushes `state`,
        // `send(self(), :after_join)` pushes `history`).
        final behind = joinPushes[topic];
        if (status == 'ok' && behind != null) ctrl.foreign.sink.add(behind);
      });
    });
    socket = PhoenixSocket(ctrl.local, heartbeatInterval: const Duration(days: 1));
    socket.start();
  }

  final bool refuseJoins;

  /// Topics this server refuses; everything else joins normally.
  final Set<String> refuseTopics;

  /// Topics this server simply never answers.
  final Set<String> silentTopics;

  /// topic -> a raw frame pushed immediately behind that topic's join reply.
  final Map<String, String> joinPushes;

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

  test('a refused ESSENTIAL join leaves the socket closed and keeps retrying',
      () async {
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
    conn.openChannel('voice:henry', essential: true);
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(sockets.length, greaterThan(1), reason: 'the backoff must keep retrying');
    await conn.disconnect();
    await pumpEventQueue();
    expect(sockets.every((s) => !s.socket.debugHeartbeatActive), isTrue,
        reason: 'every retry used to leak a live socket + heartbeat timer');
  });

  test('a refused PANEL leaves the conversation and its socket alone', () async {
    // Spec §5.1, the half PhoenixSocket already got right and AppConnection
    // used to throw away one layer up: openChannel routed EVERY channel
    // refusal into _failConnection, so a bad panel topic closed the socket and
    // took the conversation down with it.
    final sockets = <FakeSocket>[];
    final conn = AppConnection(
      connector: () async {
        final s = FakeSocket(refuseTopics: const {'panel:reminders:1'});
        sockets.add(s);
        return s.socket;
      },
      rejoinBackoff: const [Duration(milliseconds: 10)],
    );
    addTearDown(conn.dispose);

    await conn.connect();
    final voice = conn.openChannel('voice:henry', essential: true);
    await pumpEventQueue();
    expect(voice!.isJoined, isTrue);

    conn.openChannel('panel:reminders:1');
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await pumpEventQueue();

    expect(sockets, hasLength(1),
        reason: 'a refused panel must not drive the reconnect machine');
    expect(conn.state, ConnState.joined);
    expect(voice.isJoined, isTrue,
        reason: 'the conversation must survive a panel it never asked for');
    expect(sockets.single.socket.debugHeartbeatActive, isTrue,
        reason: 'the socket is healthy — only one channel was refused');
  });

  test('a refused PANEL does not fail the connect that carried it', () async {
    // The other entry point: a panel already in the wanted set when the sweep
    // runs. connect() used to Future.wait EVERY join, so one refusal failed the
    // batch, closed the socket and dropped the conversation into the backoff.
    final sockets = <FakeSocket>[];
    final conn = AppConnection(
      connector: () async {
        final s = FakeSocket(refuseTopics: const {'panel:reminders:1'});
        sockets.add(s);
        return s.socket;
      },
      rejoinBackoff: const [Duration(milliseconds: 10)],
    );
    addTearDown(conn.dispose);

    conn.openChannel('voice:henry', essential: true);
    conn.openChannel('panel:reminders:1');
    await conn.connect();
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await pumpEventQueue();

    expect(conn.state, ConnState.joined);
    expect(sockets, hasLength(1), reason: 'no reconnect was warranted');
    expect(conn.openChannel('voice:henry', essential: true)!.isJoined, isTrue);
  });

  test('a panel that never answers does not hold the conversation behind the '
      'join timeout', () async {
    // Spec §5.2: each join resolves independently. With a one-day join timeout
    // an awaited panel would park connect() for a day.
    final conn = AppConnection(
      connector: () async =>
          FakeSocket(silentTopics: const {'panel:reminders:1'}).socket,
      rejoinBackoff: const [Duration(days: 1)],
      joinTimeout: const Duration(days: 1),
    );
    addTearDown(conn.dispose);

    conn.openChannel('voice:henry', essential: true);
    conn.openChannel('panel:reminders:1');

    await conn.connect().timeout(const Duration(seconds: 2),
        onTimeout: () => fail('a silent panel parked the whole connection'));
    expect(conn.state, ConnState.joined);
  });

  test('a channel reaches its consumer at CREATION, in time for the frames the '
      'server pushes behind the join reply', () async {
    // The connection-level half of the dropped-first-frame bug: `messages` is
    // an unbuffered broadcast stream, so a consumer handed its channel only
    // once the join RESOLVED is already behind the next transport frame.
    final fake = FakeSocket(joinPushes: const {
      'voice:henry': '[null,null,"voice:henry","state",{"phase":"listening"}]',
    });
    final conn = AppConnection(
      connector: () async => fake.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    addTearDown(conn.dispose);

    final heard = <String>[];
    var joinedWhenHandedOver = true;
    conn.openChannel('voice:henry', essential: true, onChannel: (ch) {
      joinedWhenHandedOver = ch.isJoined;
      ch.messages.listen((m) => heard.add(m.event));
    });

    await conn.connect();
    await pumpEventQueue();

    expect(joinedWhenHandedOver, isFalse,
        reason: 'the handover must beat the join, not follow it');
    expect(heard, contains('state'),
        reason: 'the frame the server pushes behind its join reply must land');
  });

  test('rejoin() replaces the socket without the old one scheduling a retry',
      () async {
    // Moved here from voice_controller_reconnect_test.dart, which used to own
    // rejoin(). The hazard is the superseded socket: its onClose still fires,
    // and if the backoff listened to it we would open a THIRD socket (and, on a
    // real WebSocket, leak the second one's heartbeat).
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
    await conn.rejoin();
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await pumpEventQueue();

    expect(sockets, hasLength(2),
        reason: "the superseded socket's onClose must be ignored, not retried");
    expect(sockets.first.socket.debugHeartbeatActive, isFalse,
        reason: 'a dropped-but-unclosed socket leaks its heartbeat Timer.periodic');
    expect(conn.state, ConnState.joined);
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
