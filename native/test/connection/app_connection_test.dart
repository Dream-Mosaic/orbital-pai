import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/connection/app_connection.dart';
import 'package:henry_wall/meridian/tokens.dart';
import 'package:henry_wall/phoenix/phoenix_channel.dart';

import '../support/fake_socket.dart';

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

  test('a listener that opens ANOTHER topic during the sweep does not abort it',
      () async {
    // connect() used to iterate `_wanted.entries` live while _createChannel
    // synchronously hands each channel to its listeners — and that handover
    // contract explicitly invites a listener to re-enter openChannel. Doing so
    // with a NEW topic mutated the map mid-iteration; the
    // ConcurrentModificationError was swallowed by connect()'s own catch, so
    // the symptom was not a crash but a connection that silently closed its
    // socket and dropped into the backoff.
    final sockets = <FakeSocket>[];
    final conn = AppConnection(
      connector: () async {
        final s = FakeSocket();
        sockets.add(s);
        return s.socket;
      },
      rejoinBackoff: const [Duration(days: 1)],
    );
    addTearDown(conn.dispose);

    conn.openChannel('voice:henry', essential: true, onChannel: (_) {
      // Exactly the shape the panels phase needs: the conversation comes up and
      // opens the panel topics it discovers it wants.
      conn.openChannel('panel:reminders:1');
    });

    await conn.connect();
    await pumpEventQueue();

    expect(conn.state, ConnState.joined);
    expect(sockets.single.socket.debugHeartbeatActive, isTrue,
        reason: 'the swallowed error tore down a perfectly healthy socket');
    expect(sockets.single.joinedTopics,
        containsAll(<String>['voice:henry', 'panel:reminders:1']));
  });

  // openChannel used to overwrite `essential` on every call, so a consumer
  // asking for a handle to a topic somebody else owns silently reclassified the
  // conversation as an optional panel: its refusal stopped escalating and
  // connect() stopped gating on its join. Registration WIDENS instead — and it
  // has to widen in both directions, because either party can arrive first: a
  // panel client built before the conversation, or a widget rebuilt after it.
  for (final ownerFirst in [true, false]) {
    test('a bare openChannel cannot demote an ESSENTIAL topic '
        '(owner ${ownerFirst ? 'first' : 'second'})', () async {
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

      if (ownerFirst) {
        conn.openChannel('voice:henry', essential: true);
        conn.openChannel('voice:henry');
      } else {
        conn.openChannel('voice:henry');
        conn.openChannel('voice:henry', essential: true);
      }

      await conn.connect();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(sockets.length, greaterThan(1),
          reason: 'a refused CONVERSATION must still escalate to the backoff');
    });
  }

  test('a bare openChannel does not wipe the join payload it was opened with',
      () async {
    final sockets = <FakeSocket>[];
    final conn = AppConnection(
      connector: () async {
        final s = FakeSocket();
        sockets.add(s);
        return s.socket;
      },
      rejoinBackoff: const [Duration(days: 1)],
    );
    addTearDown(conn.dispose);

    conn.openChannel('voice:henry',
        essential: true, joinPayload: const {'since': 7});
    conn.openChannel('voice:henry'); // a consumer, not the owner

    await conn.connect();

    final join = sockets.single.sent
        .map((f) => jsonDecode(f as String) as List<dynamic>)
        .firstWhere((p) => p[3] == 'phx_join');
    expect(join[4], const {'since': 7},
        reason: 'the owner registered how this topic joins; a consumer must not '
            'silently rejoin it with nothing');
  });

  test('a refused PANEL is dropped from the registry, so re-opening it retries',
      () async {
    // The dead handle used to stay in BOTH registries for the life of the
    // socket: openChannel handed it to every later caller, onCreate never ran
    // again, and nothing reached the wire — so a panel refused once stayed
    // broken until the next reconnect.
    final refuse = <String>{'panel:reminders:1'};
    final fake = FakeSocket(refuseTopics: refuse);
    final conn = AppConnection(
      connector: () async => fake.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    addTearDown(conn.dispose);

    await conn.connect();

    final handed = <Object>[];
    final first = conn.openChannel('panel:reminders:1', onChannel: handed.add);
    await pumpEventQueue();

    refuse.clear(); // whatever the server was unhappy about is resolved
    final second = conn.openChannel('panel:reminders:1', onChannel: handed.add);
    await pumpEventQueue();

    expect(identical(first, second), isFalse,
        reason: 'the corpse used to be handed back for the life of the socket');
    expect(second!.isJoined, isTrue);
    expect(fake.joinedTopics.where((t) => t == 'panel:reminders:1').length, 2,
        reason: 'the retry must reach the wire');
    expect(conn.state, ConnState.joined,
        reason: 'none of this is the conversation’s business');
  });

  test('a closed channel does not evict the replacement that outlived it',
      () async {
    // Close a panel and reopen it straight away — plausible the moment panels
    // have a back button. leave() fails the outgoing channel's still-pending
    // join, and its de-registration lands a microtask LATER, by which time the
    // fresh channel is the one in the registry. Keyed on presence rather than
    // identity, the corpse evicts its own replacement; the socket still has it,
    // so nothing looks broken until a consumer asks for the topic and
    // openChannel silently hands it nothing.
    final conn = AppConnection(
      connector: () async =>
          FakeSocket(silentTopics: const {'panel:reminders:1'}).socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    addTearDown(conn.dispose);
    await conn.connect();

    conn.openChannel('panel:reminders:1'); // join still in flight
    conn.closeChannel('panel:reminders:1'); // ...which leave() now fails
    conn.openChannel('panel:reminders:1');
    await pumpEventQueue();

    Object? handedOver;
    conn.openChannel('panel:reminders:1', onChannel: (ch) => handedOver = ch);
    expect(handedOver, isNotNull,
        reason: 'a consumer that asks for a topic is always handed its channel');
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

  test('dropListener stops a consumer hearing about later channels', () async {
    // A consumer that goes away while its topic stays open — VoiceController on
    // dispose. Without this it keeps adopting every channel a reconnect makes,
    // forever, and each adoption opens a fresh subscription on the new channel.
    final sockets = <FakeSocket>[];
    final conn = AppConnection(
      connector: () async {
        final s = FakeSocket();
        sockets.add(s);
        return s.socket;
      },
      rejoinBackoff: const [Duration(days: 1)],
    );
    addTearDown(conn.dispose);

    final seen = <PhoenixChannel>[];
    void listener(PhoenixChannel ch) => seen.add(ch);

    conn.openChannel('voice:henry', essential: true, onChannel: listener);
    await conn.connect();
    expect(seen, hasLength(1));

    conn.dropListener('voice:henry', listener);
    await conn.rejoin();
    await pumpEventQueue();

    expect(seen, hasLength(1),
        reason: 'a dropped listener must not be handed the reconnect’s channel');
  });
}
