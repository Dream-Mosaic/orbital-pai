import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/connection/app_connection.dart';
import 'package:orbital_pai/main.dart';
import 'package:orbital_pai/meridian/books_panel.dart';
import 'package:orbital_pai/meridian/connectors_panel.dart';
import 'package:orbital_pai/meridian/drawer.dart';
import 'package:orbital_pai/meridian/hero_icon.dart';
import 'package:orbital_pai/meridian/nav.dart';
import 'package:orbital_pai/meridian/reminders_panel.dart';
import 'package:orbital_pai/meridian/search_panel.dart';
import 'package:orbital_pai/meridian/settings_drawer_host.dart';
import 'package:orbital_pai/panels/books_client.dart';
import 'package:orbital_pai/panels/connectors_client.dart';
import 'package:orbital_pai/panels/memory_client.dart';
import 'package:orbital_pai/panels/reminders_client.dart';
import 'package:orbital_pai/panels/settings_client.dart';
import 'package:orbital_pai/panels/voice_lock_client.dart';

import 'support/fake_socket.dart';

/// The PRODUCTION station wiring — `main.dart`'s `_openPanel` — driven through
/// a real [HenryHome] on a fake socket.
///
/// Every other drawer test in this repo builds a test-local MIRROR of one of
/// those branches, and a mirror cannot catch a divergence in the thing it
/// mirrors: with `_openPanel` untested, deleting a branch outright, or copying
/// a branch and forgetting to swap the client inside it, left the whole suite
/// green. These tests tap the real bottom nav and watch what the real
/// `_openPanel` does.
///
/// Two things this file must never do, both measured:
///   * `pumpAndSettle` NEVER RETURNS here — the orb animates forever — so every
///     wait below is an explicit `pump`.
///   * `HenryHome()` with no connection dials the configured server for real.
///     Always pass one.
///
/// heroicons are SVGs, not IconData, so `find.byIcon` does not apply. Copied
/// from drawer_test.dart, which owns the canonical version.
Finder findHero(HeroIcon icon) =>
    find.byWidgetPredicate((w) => w is HeroIconView && w.icon == icon);

// Copied from settings_drawer_host_test.dart, which owns the canonical shape.
const String _settingsFrame = '[null,null,"panel:settings:henry","state",'
    '{"default_abi":true,"default_ptt":false,"voice_activation":true,'
    '"briefing_time":null,"relock_seconds":15,"app_version":"0.4.19"}]';

const String _memoryFrame = '[null,null,"panel:memory:henry","state",'
    '{"summary":"Likes coffee.","facts":[]}]';

// The connectors panel renders nothing at all until its first `state` lands
// (`ConnectorsPanelView.build` returns a shrink for a null state), so the deep
// link tests below need one to have anything to assert a banner against.
const String _connectorsFrame = '[null,null,"panel:connectors:henry","state",'
    '{"connections":[],"catalog":[]}]';

void main() {
  /// The one viewport the chrome is laid out for; voice_screen_test.dart uses
  /// the same. The 800x600 default overflows it.
  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }

  Future<(AppConnection, FakeSocket)> pumpHome(
    WidgetTester tester, {
    Stream<Uri>? deepLinks,
  }) async {
    phone(tester);
    // Only the two panels whose CONTENT a test drives (the Settings layer
    // rows) need a state frame; every other station is asserted on its
    // routing, which does not depend on what the server pushed.
    final fake = FakeSocket(joinPushes: const {
      'panel:settings:henry': _settingsFrame,
      'panel:memory:henry': _memoryFrame,
      'panel:connectors:henry': _connectorsFrame,
    });
    final conn = AppConnection(
      connector: () async => fake.socket,
      // The heartbeat is a 24h Timer and the backoff would be another; both
      // are parked well past the end of the test, and `conn.disconnect()`
      // below closes the socket for real.
      rejoinBackoff: const [Duration(days: 1)],
    );
    await tester.pumpWidget(
      MaterialApp(home: HenryHome(connection: conn, deepLinks: deepLinks)),
    );
    // Two pumps: one for connect()'s await on the connector, one for the join
    // replies the fake delivers a microtask later.
    await tester.pump();
    await tester.pump();
    return (conn, fake);
  }

  /// Tap a bottom-nav station and let its route push and slide in.
  ///
  /// `warnIfMissed: false`: the hit target is the station's opaque
  /// GestureDetector, not the icon itself.
  Future<void> tapStation(WidgetTester tester, MeridianTab tab) async {
    await tester.tap(findHero(tab.icon), warnIfMissed: false);
    await tester.pump();
    // Past MeridianDrawer.slide, derived rather than a bare literal so the
    // coupling to the route's actual transition duration stays explicit.
    await tester.pump(MeridianDrawer.slide + const Duration(milliseconds: 100));
  }

  /// Dismiss the open drawer via its ✕, which pops the route and so runs the
  /// branch's `whenComplete`.
  Future<void> dismissDrawer(WidgetTester tester) async {
    await tester.tap(findHero(HeroIcon.xMark));
    await tester.pump();
    await tester.pump(MeridianDrawer.slide + const Duration(milliseconds: 100));
  }

  /// Pop whatever station is showing.
  ///
  /// Straight at the Navigator rather than through a control: every station
  /// is a `_drawerRoute` now (drawer.dart), all sharing the same 300ms
  /// `transitionDuration`/`reverseTransitionDuration`, so one generic pop
  /// dismisses any of them without needing to know which control a given
  /// station's content exposes.
  Future<void> popTop(WidgetTester tester) async {
    tester.firstState<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump();
    await tester.pump(MeridianDrawer.slide + const Duration(milliseconds: 100));
  }

  List<String> leftTopics(FakeSocket fake) => fake.textFrames
      .where((p) => p[3] == 'phx_leave')
      .map((p) => p[2] as String)
      .toList();

  int joinsOf(FakeSocket fake, String topic) =>
      fake.joinedTopics.where((t) => t == topic).length;

  /// The claim every native station makes: tapping it opens the drawer with
  /// ITS panel inside — not another station's.
  Future<void> expectNativeStation(
    WidgetTester tester,
    MeridianTab tab,
    Type panel,
  ) async {
    await tapStation(tester, tab);
    expect(find.byType(MeridianDrawer), findsOneWidget,
        reason: '${tab.label} must open the native drawer');
    expect(find.byType(panel), findsOneWidget,
        reason: '${tab.label} must be handed its own panel, not another '
            "station's");
  }

  // ---- routing: which screen each station opens ----

  testWidgets('Reminders opens the native panel', (tester) async {
    final (conn, _) = await pumpHome(tester);
    await expectNativeStation(
        tester, MeridianTab.reminders, RemindersPanelView);
    await conn.disconnect();
  });

  testWidgets('Connectors opens the native panel', (tester) async {
    final (conn, _) = await pumpHome(tester);
    await expectNativeStation(
        tester, MeridianTab.connectors, ConnectorsPanelView);
    await conn.disconnect();
  });

  testWidgets('Settings opens the native drawer host', (tester) async {
    final (conn, _) = await pumpHome(tester);
    await expectNativeStation(
        tester, MeridianTab.settings, SettingsDrawerHost);
    await conn.disconnect();
  });

  testWidgets('Search opens the native panel and joins no topic',
      (tester) async {
    final (conn, fake) = await pumpHome(tester);
    final before = List<String>.from(fake.joinedTopics);

    await expectNativeStation(tester, MeridianTab.search, SearchPanelView);

    // Search is the one station with no channel behind it; a future refactor
    // that gave it one would have to say so here.
    expect(fake.joinedTopics, before);
    await conn.disconnect();
  });

  testWidgets('Books opens the native panel', (tester) async {
    final (conn, _) = await pumpHome(tester);
    await expectNativeStation(tester, MeridianTab.books, BooksPanelView);
    await conn.disconnect();
  });

  // ---- the copy-paste hazard: each branch must close ITS OWN client ----
  //
  // Every native branch is a byte-for-byte copy of the one above it, so the
  // realistic slip is not deleting a branch — it is `.whenComplete(
  // _reminders.close)` in the Connectors branch. That mutant is invisible to
  // `flutter analyze` and to every mirror test: the topic is simply never
  // left, the client's `_open` stays true, and the NEXT tap short-circuits on
  // `open()`'s `if (_open) return`. The drawer then reopens on stale state
  // forever. So each test below dismisses and REOPENS, which is exactly the
  // user-visible shape of that bug.

  Future<void> expectClosesItsOwnTopic(
    WidgetTester tester,
    FakeSocket fake,
    MeridianTab tab,
    String topic,
  ) async {
    await tapStation(tester, tab);
    expect(joinsOf(fake, topic), 1, reason: 'sanity: ${tab.label} joined once');

    await dismissDrawer(tester);
    expect(leftTopics(fake), [topic],
        reason: "${tab.label}'s whenComplete must close ITS OWN client — "
            'exactly this topic, and no other');

    await tapStation(tester, tab);
    expect(joinsOf(fake, topic), 2,
        reason: 'a topic that was never left is never rejoined, and the '
            'reopened drawer shows whatever state it had last time');
  }

  testWidgets('dismissing Reminders leaves its topic, so a reopen refetches',
      (tester) async {
    final (conn, fake) = await pumpHome(tester);
    await expectClosesItsOwnTopic(
        tester, fake, MeridianTab.reminders, RemindersClient.topic);
    await conn.disconnect();
  });

  testWidgets('dismissing Connectors leaves its topic, so a reopen refetches',
      (tester) async {
    final (conn, fake) = await pumpHome(tester);
    await expectClosesItsOwnTopic(
        tester, fake, MeridianTab.connectors, ConnectorsClient.topic);
    await conn.disconnect();
  });

  testWidgets('dismissing Settings leaves its topic, so a reopen refetches',
      (tester) async {
    final (conn, fake) = await pumpHome(tester);
    await expectClosesItsOwnTopic(
        tester, fake, MeridianTab.settings, SettingsClient.topic);
    await conn.disconnect();
  });

  testWidgets('dismissing Books leaves its topic, so a reopen refetches',
      (tester) async {
    final (conn, fake) = await pumpHome(tester);
    await expectClosesItsOwnTopic(
        tester, fake, MeridianTab.books, BooksClient.topic);
    await conn.disconnect();
  });

  testWidgets(
      "Settings' whenComplete closes the SUB-LAYER that is showing, not just "
      'the settings client', (tester) async {
    // The Settings branch is the one whose whenComplete closes three clients,
    // because the drawer can be dismissed from any of its layers. Dismiss from
    // the Memory layer: by then `_settings` is already closed (the host closes
    // a layer before opening the next), so `_memory.close()` in main.dart is
    // the ONLY thing that leaves panel:memory:henry. Drop it and the topic
    // leaks with nothing else in the repo to notice.
    final (conn, fake) = await pumpHome(tester);
    await tapStation(tester, MeridianTab.settings);

    // The Memory row sits below the fold on this viewport.
    await tester.ensureVisible(find.text('Memory'));
    await tester.pump();
    await tester.tap(find.text('Memory'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(joinsOf(fake, MemoryClient.topic), 1,
        reason: 'sanity: the Memory layer opened its own topic');

    await dismissDrawer(tester);

    expect(leftTopics(fake), contains(MemoryClient.topic));
    expect(leftTopics(fake), contains(SettingsClient.topic));
    expect(leftTopics(fake), isNot(contains(VoiceLockClient.topic)),
        reason: 'a client that never opened has nothing to leave');

    await conn.disconnect();
  });

  // ---- what opening a panel must NOT disturb ----

  testWidgets('no station opens or closes the conversation topic',
      (tester) async {
    // This is the claim connectors_drawer_test.dart could not make: its
    // fixture has no VoiceController and no BadgesClient, so `voice:henry`
    // could never appear there whatever main.dart did. Here they are real, and
    // both topics are genuinely joined at boot — so "opening a panel disturbs
    // neither" is falsifiable.
    final (conn, fake) = await pumpHome(tester);
    expect(fake.joinedTopics, ['voice:henry', 'badges:henry'],
        reason: 'sanity: the conversation and its badges are up before any tap');

    for (final tab in MeridianTab.values) {
      await tapStation(tester, tab);
      // Without this the loop could tap five dead icons and still "pass".
      expect(find.byType(MeridianDrawer).evaluate().length, 1,
          reason: 'sanity: ${tab.label} put exactly one screen up');
      await popTop(tester);
    }

    expect(joinsOf(fake, 'voice:henry'), 1);
    expect(joinsOf(fake, 'badges:henry'), 1);
    expect(leftTopics(fake), isNot(contains('voice:henry')));
    expect(leftTopics(fake), isNot(contains('badges:henry')));

    await conn.disconnect();
  });

  /// The return hop from a connector OAuth flow that finished in the system
  /// browser. Production feeds this from `AppLinks().uriLinkStream`; here it is
  /// a plain controller, which is the whole reason [HenryHome.deepLinks] is
  /// injectable — see the note in main.dart.
  group('deep links back from the browser', () {
    testWidgets('a success link opens the closed Connectors drawer and reports it',
        (tester) async {
      // Broadcast, so `close()` completes whether or not a listener is still
      // attached. A single-subscription controller's close() never completes
      // once its listener has been cancelled — which is exactly what a FAILING
      // test does on the way out, turning a clean failure into a hung suite.
      final links = StreamController<Uri>.broadcast();
      addTearDown(links.close);
      final (conn, _) = await pumpHome(tester, deepLinks: links.stream);
      addTearDown(conn.disconnect);

      expect(find.byType(ConnectorsPanelView), findsNothing);

      links.add(Uri.parse('orbital://connectors?status=ok'));
      // Two pumps before the slide, same reason pumpHome needs two: a stream
      // event is delivered a microtask after `add`, so the first pump is what
      // lets _onDeepLink run at all and the second renders what it pushed.
      await tester.pump();
      await tester.pump();
      await tester.pump(MeridianDrawer.slide + const Duration(milliseconds: 100));

      expect(find.byType(ConnectorsPanelView), findsOneWidget);
      expect(find.byKey(ConnectorsPanelView.resultBannerKey), findsOneWidget);
      expect(find.textContaining('up to date'), findsOneWidget);
    });

    testWidgets('a failure link says nothing changed', (tester) async {
      // Broadcast, so `close()` completes whether or not a listener is still
      // attached. A single-subscription controller's close() never completes
      // once its listener has been cancelled — which is exactly what a FAILING
      // test does on the way out, turning a clean failure into a hung suite.
      final links = StreamController<Uri>.broadcast();
      addTearDown(links.close);
      final (conn, _) = await pumpHome(tester, deepLinks: links.stream);
      addTearDown(conn.disconnect);

      links.add(Uri.parse('orbital://connectors?status=error'));
      // Two pumps before the slide, same reason pumpHome needs two: a stream
      // event is delivered a microtask after `add`, so the first pump is what
      // lets _onDeepLink run at all and the second renders what it pushed.
      await tester.pump();
      await tester.pump();
      await tester.pump(MeridianDrawer.slide + const Duration(milliseconds: 100));

      expect(find.byKey(ConnectorsPanelView.resultBannerKey), findsOneWidget);
      expect(find.textContaining("didn't finish"), findsOneWidget);
    });

    // The drawer is normally still open — the user launched the browser from
    // it — and re-pushing the route on top of itself would leave two.
    testWidgets('a link arriving while the drawer is already open does not stack a second one',
        (tester) async {
      // Broadcast, so `close()` completes whether or not a listener is still
      // attached. A single-subscription controller's close() never completes
      // once its listener has been cancelled — which is exactly what a FAILING
      // test does on the way out, turning a clean failure into a hung suite.
      final links = StreamController<Uri>.broadcast();
      addTearDown(links.close);
      final (conn, _) = await pumpHome(tester, deepLinks: links.stream);
      addTearDown(conn.disconnect);

      await tapStation(tester, MeridianTab.connectors);
      expect(find.byType(ConnectorsPanelView), findsOneWidget);

      links.add(Uri.parse('orbital://connectors?status=ok'));
      // Two pumps before the slide, same reason pumpHome needs two: a stream
      // event is delivered a microtask after `add`, so the first pump is what
      // lets _onDeepLink run at all and the second renders what it pushed.
      await tester.pump();
      await tester.pump();
      await tester.pump(MeridianDrawer.slide + const Duration(milliseconds: 100));

      expect(find.byType(ConnectorsPanelView), findsOneWidget);
      expect(find.byKey(ConnectorsPanelView.resultBannerKey), findsOneWidget);
    });

    // Any app on the device can fire our scheme; an unrecognized link must not
    // yank a drawer open, let alone claim a connection succeeded.
    testWidgets('an unrecognized link is ignored entirely', (tester) async {
      // Broadcast, so `close()` completes whether or not a listener is still
      // attached. A single-subscription controller's close() never completes
      // once its listener has been cancelled — which is exactly what a FAILING
      // test does on the way out, turning a clean failure into a hung suite.
      final links = StreamController<Uri>.broadcast();
      addTearDown(links.close);
      final (conn, _) = await pumpHome(tester, deepLinks: links.stream);
      addTearDown(conn.disconnect);

      links.add(Uri.parse('orbital://connectors?status=whatever'));
      links.add(Uri.parse('orbital://somewhere-else?status=ok'));
      links.add(Uri.parse('other://connectors?status=ok'));
      // Two pumps before the slide, same reason pumpHome needs two: a stream
      // event is delivered a microtask after `add`, so the first pump is what
      // lets _onDeepLink run at all and the second renders what it pushed.
      await tester.pump();
      await tester.pump();
      await tester.pump(MeridianDrawer.slide + const Duration(milliseconds: 100));

      expect(find.byType(ConnectorsPanelView), findsNothing);
    });
  });
}
