import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/connection/app_connection.dart';
import 'package:henry_wall/meridian/drawer.dart';
import 'package:henry_wall/meridian/hero_icon.dart';
import 'package:henry_wall/meridian/settings_drawer_host.dart';
import 'package:henry_wall/panels/memory_client.dart';
import 'package:henry_wall/panels/settings_client.dart';

import '../support/fake_socket.dart';

const String _settingsFrame = '[null,null,"panel:settings:henry","state",'
    '{"default_abi":true,"default_ptt":false,"voice_activation":true,'
    '"briefing_time":null,"relock_seconds":15,"app_version":"0.4.19"}]';

const String _memoryFrame = '[null,null,"panel:memory:henry","state",'
    '{"summary":"Likes coffee.","facts":[]}]';

/// heroicons are SVGs, not IconData, so `find.byIcon` does not apply. Copied
/// from drawer_test.dart, which owns the canonical version.
Finder findHero(HeroIcon icon) =>
    find.byWidgetPredicate((w) => w is HeroIconView && w.icon == icon);

void main() {
  // Same rationale as settings_panel_test.dart / memory_panel_test.dart: the
  // socket's heartbeat is a 24h periodic Timer still pending right after
  // connect(), which races flutter_test's pending-timer invariant check if
  // left to addTearDown — so each test explicitly awaits conn.disconnect()
  // once done with the clients.
  Future<(SettingsClient, MemoryClient, AppConnection, FakeSocket)>
      openedClients(WidgetTester tester) async {
    final fake = FakeSocket(joinPushes: const {
      'panel:settings:henry': _settingsFrame,
      'panel:memory:henry': _memoryFrame,
    });
    final conn = AppConnection(
      connector: () async => fake.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final settings = SettingsClient(connection: conn);
    final memory = MemoryClient(connection: conn);
    addTearDown(() {
      settings.dispose();
      memory.dispose();
      conn.dispose();
    });
    await conn.connect();
    // Mirrors main.dart's _openPanel: the caller opens Settings BEFORE
    // pushing the host. The host itself only ever toggles between the two
    // layers — it never performs the very first open.
    settings.open();
    await tester.pump(Duration.zero);
    return (settings, memory, conn, fake);
  }

  // Pushes the host through the real meridianHostedDrawerRoute (not a bare
  // pumpWidget of the widget alone) so system-back tests exercise the actual
  // Navigator/PopScope integration main.dart relies on.
  Future<void> pumpHost(
    WidgetTester tester,
    GlobalKey<NavigatorState> navKey,
    SettingsClient settings,
    MemoryClient memory,
  ) async {
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: const Scaffold(body: SizedBox()),
    ));
    unawaited(navKey.currentState!.push(meridianHostedDrawerRoute(
      builder: (context, animation, onClose) => SettingsDrawerHost(
        animation: animation,
        onClose: onClose,
        settings: settings,
        memory: memory,
      ),
    )));
    await tester.pumpAndSettle();
  }

  testWidgets('starts on the Settings layer with only that topic joined',
      (tester) async {
    final (settings, memory, conn, fake) = await openedClients(tester);
    final navKey = GlobalKey<NavigatorState>();
    await pumpHost(tester, navKey, settings, memory);

    expect(find.text('Settings'), findsOneWidget);
    expect(findHero(HeroIcon.chevronLeft), findsNothing);
    expect(fake.joinedTopics, contains('panel:settings:henry'));
    expect(fake.joinedTopics, isNot(contains('panel:memory:henry')));
    expect(settings.isOpen, isTrue);
    expect(memory.isOpen, isFalse);

    await conn.disconnect();
  });

  testWidgets(
      'tapping Memory -> swaps to the Memory layer, leaving settings and '
      'joining memory', (tester) async {
    final (settings, memory, conn, fake) = await openedClients(tester);
    final navKey = GlobalKey<NavigatorState>();
    await pumpHost(tester, navKey, settings, memory);

    // The Memory row sits below the fold on the default test surface — it is
    // inside the drawer's own SingleChildScrollView (drawer.dart), unlike the
    // fixed header. Scroll it into view before tapping, exactly as a real
    // finger would have to.
    await tester.ensureVisible(find.text('Memory'));
    await tester.tap(find.text('Memory'));
    await tester.pump();
    await tester.pump(Duration.zero); // let the join reply land
    await tester.pumpAndSettle();

    expect(find.text('Memory'), findsOneWidget,
        reason: 'the header title; SettingsPanelView (with its own "Memory" '
            'row) is no longer built');
    expect(findHero(HeroIcon.chevronLeft), findsOneWidget);
    expect(settings.isOpen, isFalse);
    expect(memory.isOpen, isTrue);
    expect(fake.joinedTopics, ['panel:settings:henry', 'panel:memory:henry']);
    expect(fake.sent.map((f) => jsonDecode(f as String)[3]),
        contains('phx_leave'),
        reason: 'closing Settings must actually leave the channel, not just '
            'stop rendering it locally');

    await conn.disconnect();
  });

  testWidgets(
      'tapping the chevron returns to Settings, leaving memory and '
      'rejoining settings', (tester) async {
    final (settings, memory, conn, fake) = await openedClients(tester);
    final navKey = GlobalKey<NavigatorState>();
    await pumpHost(tester, navKey, settings, memory);

    await tester.ensureVisible(find.text('Memory'));
    await tester.tap(find.text('Memory'));
    await tester.pump();
    await tester.pump(Duration.zero);
    await tester.pumpAndSettle();
    fake.sent.clear(); // isolate the assertions below to the chevron tap

    await tester.tap(findHero(HeroIcon.chevronLeft));
    await tester.pump();
    await tester.pump(Duration.zero);
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    expect(findHero(HeroIcon.chevronLeft), findsNothing);
    expect(memory.isOpen, isFalse);
    expect(settings.isOpen, isTrue);
    expect(fake.joinedTopics, ['panel:settings:henry'],
        reason: 'only settings should rejoin from this tap');
    expect(fake.sent.map((f) => jsonDecode(f as String)[3]),
        contains('phx_leave'),
        reason: 'closing Memory must actually leave the channel');

    await conn.disconnect();
  });

  testWidgets('system back at the Memory layer pops the layer, not the route',
      (tester) async {
    final (settings, memory, conn, fake) = await openedClients(tester);
    final navKey = GlobalKey<NavigatorState>();
    await pumpHost(tester, navKey, settings, memory);

    await tester.ensureVisible(find.text('Memory'));
    await tester.tap(find.text('Memory'));
    await tester.pump();
    await tester.pump(Duration.zero);
    await tester.pumpAndSettle();
    expect(find.text('Memory'), findsOneWidget, reason: 'sanity: on Memory');

    // The framework's own PopScope tests drive a simulated system back via
    // NavigatorState.maybePop() (see pop_scope_test.dart) — that is exactly
    // the path a hardware/gesture back invokes, respecting canPop the same
    // way.
    unawaited(navKey.currentState!.maybePop());
    await tester.pump();
    await tester.pump(Duration.zero);
    await tester.pumpAndSettle();

    // The drawer is STILL on screen, showing Settings — the route did not
    // pop, only the layer did.
    expect(find.byType(SettingsDrawerHost), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(findHero(HeroIcon.chevronLeft), findsNothing);
    expect(memory.isOpen, isFalse);
    expect(settings.isOpen, isTrue);

    await conn.disconnect();
  });

  testWidgets('system back at the Settings layer closes the drawer',
      (tester) async {
    final (settings, memory, conn, fake) = await openedClients(tester);
    final navKey = GlobalKey<NavigatorState>();
    await pumpHost(tester, navKey, settings, memory);
    expect(find.byType(SettingsDrawerHost), findsOneWidget,
        reason: 'sanity: the drawer is on screen');

    unawaited(navKey.currentState!.maybePop());
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byType(SettingsDrawerHost), findsNothing);

    await conn.disconnect();
  });

  testWidgets(
      'the pushed drawer route is not barrier-dismissible', (tester) async {
    // The deferred finding from Task 1: meridianHostedDrawerRoute existed
    // but had no caller, so nothing pinned its barrierDismissible: false.
    // This is the first caller — close it here. The drawer's OWN scrim
    // (drawer.dart) is the intended tap target and fully covers the screen
    // ahead of the route's own ModalBarrier, so a behavioral tap-based test
    // cannot discriminate this flag; asserting the framework's ModalBarrier
    // widget directly is the same technique Flutter's own routes_test.dart
    // uses for exactly this property.
    final (settings, memory, conn, _) = await openedClients(tester);
    final navKey = GlobalKey<NavigatorState>();
    await pumpHost(tester, navKey, settings, memory);

    final barrier =
        find.byType(ModalBarrier).evaluate().last.widget as ModalBarrier;
    expect(barrier.dismissible, isFalse,
        reason: 'the drawer\'s own scrim is the tap target; the route\'s '
            'barrier sits above it and would swallow the tap if dismissible');

    await conn.disconnect();
  });

  testWidgets('no text inherits the missing-Material underline',
      (tester) async {
    // The same bug drawer_test.dart guards against, ported here because this
    // host is a NEW composition on top of MeridianDrawer/PopScope — worth
    // pinning directly rather than trusting the sibling test transitively.
    final (settings, memory, conn, _) = await openedClients(tester);
    final navKey = GlobalKey<NavigatorState>();
    await pumpHost(tester, navKey, settings, memory);

    final painted = tester.widgetList<RichText>(find.byType(RichText));
    expect(painted, isNotEmpty);
    for (final rich in painted) {
      final style = (rich.text as TextSpan).style;
      expect(style?.decoration ?? TextDecoration.none, TextDecoration.none,
          reason: 'decoration leaked into "${rich.text.toPlainText()}"');
    }

    await conn.disconnect();
  });
}
