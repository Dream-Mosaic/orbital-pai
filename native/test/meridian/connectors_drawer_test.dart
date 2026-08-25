import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/connection/app_connection.dart';
import 'package:henry_wall/meridian/connectors_panel.dart';
import 'package:henry_wall/meridian/drawer.dart';
import 'package:henry_wall/meridian/hero_icon.dart';
import 'package:henry_wall/meridian/nav.dart';
import 'package:henry_wall/panels/connectors_client.dart';

import '../support/fake_socket.dart';

const String _connectorsFrame = '[null,null,"panel:connectors:henry","state",'
    '{"connections":[{"account_id":3,"email":"a@b.com","connector":"gmail",'
    '"label":"Gmail","access":"read","is_default":false,'
    '"shows_default":false,"only_grant":true}]}]';

/// heroicons are SVGs, not IconData, so `find.byIcon` does not apply. Copied
/// from drawer_test.dart, which owns the canonical version.
Finder findHero(HeroIcon icon) =>
    find.byWidgetPredicate((w) => w is HeroIconView && w.icon == icon);

/// Exposes ChangeNotifier's protected `hasListeners` from a legitimate
/// subclass — this adds nothing to ConnectorsClient itself, which stays at
/// "no new public API" per this task.
///
/// `_onClientChanged`'s own `needsWeb`/`mounted` guards make a leaked
/// listener behaviorally silent through every reachable production path (the
/// close() that follows a dismissal always resets `needsWeb` to false before
/// notifying, and by the time a NEW drawer reopens the old view's `mounted`
/// is already false) — so a leaked listener never fires anything a widget
/// test can see. Inspecting the listener count directly is the only way to
/// pin ConnectorsPanelView.dispose() removing its own listener, distinct
/// from AnimatedBuilder's own framework-owned subscription which is removed
/// either way.
class _InspectableConnectorsClient extends ConnectorsClient {
  _InspectableConnectorsClient({required super.connection});

  bool get debugHasListeners => hasListeners;
}

void main() {
  // Same rationale as settings_drawer_host_test.dart / reminders_panel_test.dart:
  // the socket's heartbeat is a 24h periodic Timer still pending right after
  // connect(), which races flutter_test's pending-timer invariant check if
  // left to addTearDown — so each test explicitly awaits conn.disconnect()
  // once done with the client.
  Future<(ConnectorsClient, AppConnection, FakeSocket)> openedClient(
      WidgetTester tester) async {
    final fake =
        FakeSocket(joinPushes: const {'panel:connectors:henry': _connectorsFrame});
    final conn = AppConnection(
      connector: () async => fake.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final client = ConnectorsClient(connection: conn);
    addTearDown(client.dispose);
    await conn.connect();
    return (client, conn, fake);
  }

  // Mirrors main.dart's _openPanel branch EXACTLY (same order, same route,
  // same whenComplete). That mirroring is what lets these tests speak for a
  // production line no widget test otherwise reaches.
  Future<void> pumpDrawer(WidgetTester tester, GlobalKey<NavigatorState> navKey,
      ConnectorsClient client) async {
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: const Scaffold(body: SizedBox()),
    ));
    client.open();
    unawaited(navKey.currentState!
        .push(meridianDrawerRoute(
          title: MeridianTab.connectors.label,
          child: ConnectorsPanelView(client: client),
        ))
        .whenComplete(client.close));
    await tester.pump(Duration.zero); // let the join reply land
    await tester.pumpAndSettle();
  }

  /// The events the client has sent, in order. Binary frames are excluded by
  /// FakeSocket.textFrames, so this is safe on any topic.
  List<String> events(FakeSocket fake) =>
      fake.textFrames.map((p) => p[3] as String).toList();

  testWidgets(
      'opens, joins exactly panel:connectors:henry, and renders the panel',
      (tester) async {
    final (client, conn, fake) = await openedClient(tester);
    final navKey = GlobalKey<NavigatorState>();
    await pumpDrawer(tester, navKey, client);

    expect(fake.joinedTopics, ['panel:connectors:henry']);
    expect(client.isOpen, isTrue);
    expect(find.text('Connectors'), findsOneWidget);
    // Assert on the panel's own content, not only the title: the title comes
    // from the route argument and would still be right if the wrong child
    // were passed.
    expect(find.text('Gmail'), findsOneWidget);

    await conn.disconnect();
  });

  testWidgets('there is no back chevron', (tester) async {
    final (client, conn, _) = await openedClient(tester);
    final navKey = GlobalKey<NavigatorState>();
    await pumpDrawer(tester, navKey, client);

    // This is a single-layer drawer and a chevron would mean somebody
    // reintroduced a layer.
    expect(findHero(HeroIcon.chevronLeft), findsNothing);

    await conn.disconnect();
  });

  testWidgets('the X button closes the drawer and leaves the topic',
      (tester) async {
    final (client, conn, fake) = await openedClient(tester);
    final navKey = GlobalKey<NavigatorState>();
    await pumpDrawer(tester, navKey, client);

    await tester.tap(findHero(HeroIcon.xMark));
    await tester.pumpAndSettle();

    expect(client.isOpen, isFalse);
    expect(events(fake), contains('phx_leave'));
    expect(conn.debugListenerCount(ConnectorsClient.topic), 0);

    await conn.disconnect();
  });

  testWidgets('tapping the scrim closes the drawer and leaves the topic',
      (tester) async {
    final (client, conn, fake) = await openedClient(tester);
    final navKey = GlobalKey<NavigatorState>();
    await pumpDrawer(tester, navKey, client);

    // Well clear of the 384px panel on the right, same offset drawer_test.dart
    // and settings_drawer_host_test.dart:425 use.
    await tester.tapAt(const Offset(100, 400));
    await tester.pumpAndSettle();

    expect(client.isOpen, isFalse);
    expect(events(fake), contains('phx_leave'));
    expect(conn.debugListenerCount(ConnectorsClient.topic), 0);

    await conn.disconnect();
  });

  testWidgets('system back closes the drawer and leaves the topic',
      (tester) async {
    // This is the route the .whenComplete exists for and the one a
    // client.close() bolted onto the X handler alone would miss entirely.
    final (client, conn, fake) = await openedClient(tester);
    final navKey = GlobalKey<NavigatorState>();
    await pumpDrawer(tester, navKey, client);

    unawaited(navKey.currentState!.maybePop());
    await tester.pumpAndSettle();

    expect(client.isOpen, isFalse);
    expect(events(fake), contains('phx_leave'));
    expect(conn.debugListenerCount(ConnectorsClient.topic), 0);

    await conn.disconnect();
  });

  testWidgets('reopening after a close rejoins the topic', (tester) async {
    // A topic left in _wanted is silently rejoined on every reconnect, so a
    // close that does not deregister shows up here as a MISSING second join,
    // not an extra one.
    final (client, conn, fake) = await openedClient(tester);
    final navKey = GlobalKey<NavigatorState>();
    await pumpDrawer(tester, navKey, client);

    unawaited(navKey.currentState!.maybePop());
    await tester.pumpAndSettle();

    await pumpDrawer(tester, navKey, client);

    expect(
        fake.joinedTopics.where((t) => t == 'panel:connectors:henry').length,
        2);

    await conn.disconnect();
  });

  testWidgets(
      "dismissing the drawer removes the panel view's own listener from the "
      'client, not just the framework\'s AnimatedBuilder subscription',
      (tester) async {
    final fake = FakeSocket(
        joinPushes: const {'panel:connectors:henry': _connectorsFrame});
    final conn = AppConnection(
      connector: () async => fake.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final client = _InspectableConnectorsClient(connection: conn);
    addTearDown(client.dispose);
    await conn.connect();

    final navKey = GlobalKey<NavigatorState>();
    await pumpDrawer(tester, navKey, client);
    expect(client.debugHasListeners, isTrue,
        reason: 'sanity: the mounted view is subscribed to the client');

    unawaited(navKey.currentState!.maybePop());
    await tester.pumpAndSettle();

    expect(client.debugHasListeners, isFalse,
        reason: "ConnectorsPanelView.dispose() must remove its own "
            'listener, or the client keeps a dangling reference to a '
            'disposed widget every time the drawer closes');

    await conn.disconnect();
  });

  // RETITLED, because the old name — "the conversation topic is never joined"
  // — was a claim this fixture is structurally unable to test: it carries a
  // ConnectorsClient and nothing else, no VoiceController and no BadgesClient,
  // so `voice:henry` could never appear in joinedTopics no matter what
  // main.dart did. That claim now has a real home in test/main_routing_test
  // .dart, which builds an actual HenryHome — where both topics ARE joined at
  // boot, so "opening a panel disturbs neither" is falsifiable.
  //
  // What remains here is the narrower thing the assertion genuinely checks:
  // this route's open/dismiss round trip touches exactly one topic.
  testWidgets('the drawer round trip joins no topic but the panel\'s own',
      (tester) async {
    final (client, conn, fake) = await openedClient(tester);
    final navKey = GlobalKey<NavigatorState>();
    await pumpDrawer(tester, navKey, client);

    unawaited(navKey.currentState!.maybePop());
    await tester.pumpAndSettle();

    expect(fake.joinedTopics, everyElement('panel:connectors:henry'));

    await conn.disconnect();
  });
}
