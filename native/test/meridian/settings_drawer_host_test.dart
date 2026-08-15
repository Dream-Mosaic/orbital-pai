import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/connection/app_connection.dart';
import 'package:henry_wall/meridian/drawer.dart';
import 'package:henry_wall/meridian/hero_icon.dart';
import 'package:henry_wall/meridian/settings_drawer_host.dart';
import 'package:henry_wall/panels/memory_client.dart';
import 'package:henry_wall/panels/settings_client.dart';
import 'package:henry_wall/panels/voice_lock_client.dart';

import '../support/fake_socket.dart';

const String _settingsFrame = '[null,null,"panel:settings:henry","state",'
    '{"default_abi":true,"default_ptt":false,"voice_activation":true,'
    '"briefing_time":null,"relock_seconds":15,"app_version":"0.4.19"}]';

const String _memoryFrame = '[null,null,"panel:memory:henry","state",'
    '{"summary":"Likes coffee.","facts":[]}]';

const String _voiceLockFrame = '[null,null,"panel:voice_lock:henry","state",'
    '{"user_id":7,"mode":"off","enrolled_slots":[],'
    '"verifier_ready":true,"drops":[]}]';

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
  Future<(SettingsClient, MemoryClient, VoiceLockClient, AppConnection, FakeSocket)>
      openedClients(WidgetTester tester) async {
    final fake = FakeSocket(joinPushes: const {
      'panel:settings:henry': _settingsFrame,
      'panel:memory:henry': _memoryFrame,
      'panel:voice_lock:henry': _voiceLockFrame,
    });
    final conn = AppConnection(
      connector: () async => fake.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final settings = SettingsClient(connection: conn);
    final memory = MemoryClient(connection: conn);
    // acquireMic/releaseMic are never exercised by this file — it only
    // covers the drawer's layer plumbing, not enrollment recording — so
    // these are inert stubs, not fakes worth naming.
    final voiceLock = VoiceLockClient(
      connection: conn,
      acquireMic: () async => const Stream<Uint8List>.empty(),
      releaseMic: () async {},
    );
    addTearDown(() {
      settings.dispose();
      memory.dispose();
      voiceLock.dispose();
      conn.dispose();
    });
    await conn.connect();
    // Mirrors main.dart's _openPanel: the caller opens Settings BEFORE
    // pushing the host. The host itself only ever toggles between the
    // layers — it never performs the very first open.
    settings.open();
    await tester.pump(Duration.zero);
    return (settings, memory, voiceLock, conn, fake);
  }

  // Pushes the host through the real meridianHostedDrawerRoute (not a bare
  // pumpWidget of the widget alone) so system-back tests exercise the actual
  // Navigator/PopScope integration main.dart relies on. The whenComplete
  // mirrors main.dart's _openPanel wiring EXACTLY (byte-identical, same
  // order): the drawer can be dismissed from any layer (✕, scrim, or back),
  // so all three clients must end closed regardless of which layer was
  // visible at dismissal.
  Future<void> pumpHost(
    WidgetTester tester,
    GlobalKey<NavigatorState> navKey,
    SettingsClient settings,
    MemoryClient memory,
    VoiceLockClient voiceLock,
  ) async {
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: const Scaffold(body: SizedBox()),
    ));
    unawaited(navKey.currentState!
        .push(meridianHostedDrawerRoute(
          builder: (context, animation, onClose) => SettingsDrawerHost(
            animation: animation,
            onClose: onClose,
            settings: settings,
            memory: memory,
            voiceLock: voiceLock,
          ),
        ))
        .whenComplete(() {
      voiceLock.close();
      memory.close();
      settings.close();
    }));
    await tester.pumpAndSettle();
  }

  // Scrolls to and taps the Settings panel's "Memory" nav row.
  Future<void> openMemoryLayer(WidgetTester tester) async {
    await tester.ensureVisible(find.text('Memory'));
    await tester.tap(find.text('Memory'));
    await tester.pump();
    await tester.pump(Duration.zero); // let the join reply land
    await tester.pumpAndSettle();
  }

  // Scrolls to and taps the Settings panel's "Voice Lock" nav row.
  Future<void> openVoiceLockLayer(WidgetTester tester) async {
    await tester.ensureVisible(find.text('Voice Lock'));
    await tester.tap(find.text('Voice Lock'));
    await tester.pump();
    await tester.pump(Duration.zero); // let the join reply land
    await tester.pumpAndSettle();
  }

  testWidgets(
      'starts on the Settings layer with both nav rows and only that topic '
      'joined', (tester) async {
    final (settings, memory, voiceLock, conn, fake) =
        await openedClients(tester);
    final navKey = GlobalKey<NavigatorState>();
    await pumpHost(tester, navKey, settings, memory, voiceLock);

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Memory'), findsOneWidget);
    expect(find.text('Voice Lock'), findsOneWidget);
    // The web renders Memory first (voice_modals.ex:663-678) — pin the
    // order, not just presence, since findsOneWidget alone cannot tell
    // "Memory above Voice Lock" from "Voice Lock above Memory".
    expect(tester.getRect(find.text('Memory')).top,
        lessThan(tester.getRect(find.text('Voice Lock')).top),
        reason: 'Memory must render above Voice Lock, matching the web');
    expect(findHero(HeroIcon.chevronLeft), findsNothing);
    expect(fake.joinedTopics, contains('panel:settings:henry'));
    expect(fake.joinedTopics, isNot(contains('panel:memory:henry')));
    expect(fake.joinedTopics, isNot(contains('panel:voice_lock:henry')));
    expect(settings.isOpen, isTrue);
    expect(memory.isOpen, isFalse);
    expect(voiceLock.isOpen, isFalse);

    await conn.disconnect();
  });

  testWidgets(
      'tapping Memory -> swaps to the Memory layer, leaving settings and '
      'joining memory', (tester) async {
    final (settings, memory, voiceLock, conn, fake) =
        await openedClients(tester);
    final navKey = GlobalKey<NavigatorState>();
    await pumpHost(tester, navKey, settings, memory, voiceLock);

    // The Memory row sits below the fold on the default test surface — it is
    // inside the drawer's own SingleChildScrollView (drawer.dart), unlike the
    // fixed header. openMemoryLayer scrolls it into view before tapping,
    // exactly as a real finger would have to.
    await openMemoryLayer(tester);

    expect(find.text('Memory'), findsOneWidget,
        reason: 'the header title; SettingsPanelView (with its own "Memory" '
            'row) is no longer built');
    expect(findHero(HeroIcon.chevronLeft), findsOneWidget);
    expect(settings.isOpen, isFalse);
    expect(memory.isOpen, isTrue);
    expect(voiceLock.isOpen, isFalse);
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
    final (settings, memory, voiceLock, conn, fake) =
        await openedClients(tester);
    final navKey = GlobalKey<NavigatorState>();
    await pumpHost(tester, navKey, settings, memory, voiceLock);

    await openMemoryLayer(tester);
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

  testWidgets(
      'tapping Voice Lock -> swaps to the Voice Lock layer, leaving '
      'settings and joining voice lock', (tester) async {
    final (settings, memory, voiceLock, conn, fake) =
        await openedClients(tester);
    final navKey = GlobalKey<NavigatorState>();
    await pumpHost(tester, navKey, settings, memory, voiceLock);

    await openVoiceLockLayer(tester);

    expect(find.text('Voice Lock'), findsOneWidget,
        reason: 'the header title; SettingsPanelView (with its own "Voice '
            'Lock" row) is no longer built');
    expect(findHero(HeroIcon.chevronLeft), findsOneWidget);
    expect(settings.isOpen, isFalse);
    expect(voiceLock.isOpen, isTrue);
    expect(memory.isOpen, isFalse);
    expect(fake.joinedTopics,
        ['panel:settings:henry', 'panel:voice_lock:henry']);
    expect(fake.sent.map((f) => jsonDecode(f as String)[3]),
        contains('phx_leave'),
        reason: 'closing Settings must actually leave the channel, not just '
            'stop rendering it locally');

    await conn.disconnect();
  });

  testWidgets(
      'tapping the chevron from Voice Lock returns to Settings, leaving '
      'voice lock and rejoining settings', (tester) async {
    final (settings, memory, voiceLock, conn, fake) =
        await openedClients(tester);
    final navKey = GlobalKey<NavigatorState>();
    await pumpHost(tester, navKey, settings, memory, voiceLock);

    await openVoiceLockLayer(tester);
    fake.sent.clear(); // isolate the assertions below to the chevron tap

    await tester.tap(findHero(HeroIcon.chevronLeft));
    await tester.pump();
    await tester.pump(Duration.zero);
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    expect(findHero(HeroIcon.chevronLeft), findsNothing);
    expect(voiceLock.isOpen, isFalse);
    expect(settings.isOpen, isTrue);
    expect(fake.joinedTopics, ['panel:settings:henry'],
        reason: 'only settings should rejoin from this tap');
    expect(fake.sent.map((f) => jsonDecode(f as String)[3]),
        contains('phx_leave'),
        reason: 'closing Voice Lock must actually leave the channel');

    await conn.disconnect();
  });

  testWidgets('system back at the Memory layer pops the layer, not the route',
      (tester) async {
    final (settings, memory, voiceLock, conn, fake) =
        await openedClients(tester);
    final navKey = GlobalKey<NavigatorState>();
    await pumpHost(tester, navKey, settings, memory, voiceLock);

    await openMemoryLayer(tester);
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

  testWidgets(
      'system back at the Voice Lock layer pops the layer, not the route',
      (tester) async {
    final (settings, memory, voiceLock, conn, fake) =
        await openedClients(tester);
    final navKey = GlobalKey<NavigatorState>();
    await pumpHost(tester, navKey, settings, memory, voiceLock);

    await openVoiceLockLayer(tester);
    expect(find.text('Voice Lock'), findsOneWidget,
        reason: 'sanity: on Voice Lock');

    unawaited(navKey.currentState!.maybePop());
    await tester.pump();
    await tester.pump(Duration.zero);
    await tester.pumpAndSettle();

    // The drawer is STILL on screen, showing Settings — the route did not
    // pop, only the layer did.
    expect(find.byType(SettingsDrawerHost), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(findHero(HeroIcon.chevronLeft), findsNothing);
    expect(voiceLock.isOpen, isFalse);
    expect(settings.isOpen, isTrue);

    await conn.disconnect();
  });

  testWidgets('system back at the Settings layer closes the drawer',
      (tester) async {
    final (settings, memory, voiceLock, conn, fake) =
        await openedClients(tester);
    final navKey = GlobalKey<NavigatorState>();
    await pumpHost(tester, navKey, settings, memory, voiceLock);
    expect(find.byType(SettingsDrawerHost), findsOneWidget,
        reason: 'sanity: the drawer is on screen');

    unawaited(navKey.currentState!.maybePop());
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byType(SettingsDrawerHost), findsNothing);

    await conn.disconnect();
  });

  testWidgets(
      'the X button closes the whole drawer from the Memory layer in one tap',
      (tester) async {
    // Regression: MeridianDrawer's X and scrim both call onClose ->
    // Navigator.maybePop(), which used to route through this host's own
    // PopScope and get swallowed at the Memory layer (canPop: false), so a
    // first tap silently returned to Settings instead of closing. Fixed by
    // handing onClose Navigator.pop() (drawer.dart), which does not consult
    // PopScope at all — this pins that X closes in ONE tap regardless of
    // layer, and that ALL THREE clients end closed (mirroring main.dart's
    // shared whenComplete).
    final (settings, memory, voiceLock, conn, _) =
        await openedClients(tester);
    final navKey = GlobalKey<NavigatorState>();
    await pumpHost(tester, navKey, settings, memory, voiceLock);

    await openMemoryLayer(tester);
    expect(find.text('Memory'), findsOneWidget, reason: 'sanity: on Memory');

    await tester.tap(findHero(HeroIcon.xMark));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byType(SettingsDrawerHost), findsNothing,
        reason: 'X from the Memory layer must close the whole drawer, not '
            'just pop back to Settings');
    expect(settings.isOpen, isFalse);
    expect(memory.isOpen, isFalse);
    expect(voiceLock.isOpen, isFalse);

    await conn.disconnect();
  });

  testWidgets(
      'the X button closes the whole drawer from the Voice Lock layer in '
      'one tap', (tester) async {
    // Same regression as the Memory X test above, pinned again at the third
    // layer: nothing about a THIRD _Layer value should reintroduce the
    // "swallowed by PopScope" bug the enum replaced the bool to avoid.
    final (settings, memory, voiceLock, conn, _) =
        await openedClients(tester);
    final navKey = GlobalKey<NavigatorState>();
    await pumpHost(tester, navKey, settings, memory, voiceLock);

    await openVoiceLockLayer(tester);
    expect(find.text('Voice Lock'), findsOneWidget,
        reason: 'sanity: on Voice Lock');

    await tester.tap(findHero(HeroIcon.xMark));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byType(SettingsDrawerHost), findsNothing,
        reason: 'X from the Voice Lock layer must close the whole drawer, '
            'not just pop back to Settings');
    expect(settings.isOpen, isFalse);
    expect(memory.isOpen, isFalse);
    expect(voiceLock.isOpen, isFalse);

    await conn.disconnect();
  });

  testWidgets(
      'tapping the scrim closes the whole drawer from the Memory layer in '
      'one tap', (tester) async {
    // Same regression as the X test above, via the scrim's GestureDetector
    // instead of the header's X icon — both call the same onClose.
    final (settings, memory, voiceLock, conn, _) =
        await openedClients(tester);
    final navKey = GlobalKey<NavigatorState>();
    await pumpHost(tester, navKey, settings, memory, voiceLock);

    await openMemoryLayer(tester);
    expect(find.text('Memory'), findsOneWidget, reason: 'sanity: on Memory');

    // Well clear of the 384px panel on the right, same offset drawer_test.dart
    // uses for its own scrim test.
    await tester.tapAt(const Offset(100, 400));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byType(SettingsDrawerHost), findsNothing,
        reason: 'the scrim from the Memory layer must close the whole '
            'drawer, not just pop back to Settings');
    expect(settings.isOpen, isFalse);
    expect(memory.isOpen, isFalse);
    expect(voiceLock.isOpen, isFalse);

    await conn.disconnect();
  });

  testWidgets(
      'tapping the scrim closes the whole drawer from the Voice Lock layer '
      'in one tap', (tester) async {
    final (settings, memory, voiceLock, conn, _) =
        await openedClients(tester);
    final navKey = GlobalKey<NavigatorState>();
    await pumpHost(tester, navKey, settings, memory, voiceLock);

    await openVoiceLockLayer(tester);
    expect(find.text('Voice Lock'), findsOneWidget,
        reason: 'sanity: on Voice Lock');

    await tester.tapAt(const Offset(100, 400));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byType(SettingsDrawerHost), findsNothing,
        reason: 'the scrim from the Voice Lock layer must close the whole '
            'drawer, not just pop back to Settings');
    expect(settings.isOpen, isFalse);
    expect(memory.isOpen, isFalse);
    expect(voiceLock.isOpen, isFalse);

    await conn.disconnect();
  });

  testWidgets(
      'only one panel topic is open at a time across all three layers',
      (tester) async {
    final (settings, memory, voiceLock, conn, fake) =
        await openedClients(tester);
    final navKey = GlobalKey<NavigatorState>();
    await pumpHost(tester, navKey, settings, memory, voiceLock);

    await openMemoryLayer(tester);
    expect(memory.isOpen, isTrue);
    expect(settings.isOpen, isFalse);
    expect(voiceLock.isOpen, isFalse);

    await tester.tap(findHero(HeroIcon.chevronLeft));
    await tester.pump();
    await tester.pump(Duration.zero);
    await tester.pumpAndSettle();
    expect(settings.isOpen, isTrue);
    expect(memory.isOpen, isFalse);

    await openVoiceLockLayer(tester);
    expect(memory.isOpen, isFalse);
    expect(voiceLock.isOpen, isTrue);
    expect(settings.isOpen, isFalse);
    // Each topic joined exactly once across the whole sequence — nothing
    // reopened a channel that was never explicitly re-entered.
    expect(
        fake.joinedTopics.where((t) => t == 'panel:memory:henry').length, 1);
    expect(
        fake.joinedTopics
            .where((t) => t == 'panel:voice_lock:henry')
            .length,
        1);

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
    final (settings, memory, voiceLock, conn, _) =
        await openedClients(tester);
    final navKey = GlobalKey<NavigatorState>();
    await pumpHost(tester, navKey, settings, memory, voiceLock);

    final barrier =
        find.byType(ModalBarrier).evaluate().last.widget as ModalBarrier;
    expect(barrier.dismissible, isFalse,
        reason: 'the drawer\'s own scrim is the tap target; the route\'s '
            'barrier sits above it and would swallow the tap if dismissible');

    await conn.disconnect();
  });

  testWidgets(
      'no text inherits the missing-Material underline, on any layer',
      (tester) async {
    // The same bug drawer_test.dart guards against, ported here because this
    // host is a NEW composition on top of MeridianDrawer/PopScope — worth
    // pinning directly rather than trusting the sibling test transitively.
    // Checked on ALL THREE layers: this bug has shipped twice in this
    // codebase, and a check that only ever ran against Settings would not
    // prove anything about MemoryPanelView's or VoiceLockPanelView's own
    // text.
    final (settings, memory, voiceLock, conn, _) =
        await openedClients(tester);
    final navKey = GlobalKey<NavigatorState>();
    await pumpHost(tester, navKey, settings, memory, voiceLock);

    void expectNoUnderline() {
      final painted = tester.widgetList<RichText>(find.byType(RichText));
      expect(painted, isNotEmpty);
      for (final rich in painted) {
        final style = (rich.text as TextSpan).style;
        expect(style?.decoration ?? TextDecoration.none, TextDecoration.none,
            reason: 'decoration leaked into "${rich.text.toPlainText()}"');
      }
    }

    expectNoUnderline(); // Settings layer

    await openMemoryLayer(tester);
    expectNoUnderline(); // Memory layer

    await tester.tap(findHero(HeroIcon.chevronLeft));
    await tester.pump();
    await tester.pump(Duration.zero);
    await tester.pumpAndSettle();

    await openVoiceLockLayer(tester);
    expectNoUnderline(); // Voice Lock layer

    await conn.disconnect();
  });
}
