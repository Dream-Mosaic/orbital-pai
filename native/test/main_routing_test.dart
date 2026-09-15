import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orbital_pai/auth/auth_controller.dart';
import 'package:orbital_pai/auth/token_store.dart';
import 'package:orbital_pai/connection/app_connection.dart';
import 'package:orbital_pai/main.dart';
import 'package:orbital_pai/meridian/books_panel.dart';
import 'package:orbital_pai/meridian/connectors_panel.dart';
import 'package:orbital_pai/meridian/drawer.dart';
import 'package:orbital_pai/meridian/hero_icon.dart';
import 'package:orbital_pai/meridian/login_screen.dart';
import 'package:orbital_pai/meridian/nav.dart';
import 'package:orbital_pai/meridian/reminders_panel.dart';
import 'package:orbital_pai/meridian/search_panel.dart';
import 'package:orbital_pai/meridian/settings_drawer_host.dart';
import 'package:orbital_pai/meridian/voice_screen.dart';
import 'package:orbital_pai/panels/books_client.dart';
import 'package:orbital_pai/panels/connectors_client.dart';
import 'package:orbital_pai/panels/memory_client.dart';
import 'package:orbital_pai/panels/reminders_client.dart';
import 'package:orbital_pai/panels/settings_client.dart';
import 'package:orbital_pai/panels/voice_lock_client.dart';

import 'support/fake_browser_session.dart';
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
// (`ConnectorsPanelView.build` returns a shrink for a null state), so the
// station that opens it needs one to have anything to render.
const String _connectorsFrame = '[null,null,"panel:connectors:henry","state",'
    '{"connections":[],"catalog":[]}]';

/// A [FlutterSecureStoragePlatform] whose `read()` takes a real, bounded
/// delay — long enough to outlast the fake socket's near-instant connector,
/// short enough to stay well under `_buildShell`'s 2s `deviceIdReady`
/// timeout. This is what makes the device-id-gating test below able to fail:
/// `TestFlutterSecureStoragePlatform` resolves in a single microtask, so
/// against it `conn.connect()`'s own microtask-hop connector and
/// `DeviceId.get()`'s read are close enough that either ordering could win
/// by accident, and a regression to a bare `conn.connect()` might still
/// happen to pass. A genuine, larger delay on the read forces the ordering:
/// only code that actually AWAITS the device id before dialing can still
/// have the first join carry it.
class _DelayedSecureStoragePlatform extends FlutterSecureStoragePlatform {
  final Map<String, String> data = <String, String>{};

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async =>
      data.containsKey(key);

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async =>
      data.remove(key);

  @override
  Future<void> deleteAll({required Map<String, String> options}) async =>
      data.clear();

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return data[key];
  }

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async =>
      data;

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async =>
      data[key] = value;
}

void main() {
  /// The one viewport the chrome is laid out for; voice_screen_test.dart uses
  /// the same. The 800x600 default overflows it.
  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }

  Future<(AppConnection, FakeSocket)> pumpHome(WidgetTester tester) async {
    phone(tester);
    // `voice:henry` registers synchronously regardless of the device id
    // (VoiceController's constructor), so it is never at risk of going
    // unjoined here. What DOES depend on this mock: `_buildShell` now
    // awaits `VoiceController.deviceIdReady` — bounded by a 2s `.timeout()`
    // — before ever calling `conn.connect()`, so the FIRST join
    // deterministically carries the device id instead of racing
    // `connect()`'s own socket handshake. Left unmocked, `SecureDeviceIdStore`
    // (backed by `FlutterSecureStorage`) never completes at all under a
    // `testWidgets` binding (unlike a plain `test()`, where a missing
    // platform-channel handler throws promptly) — `deviceIdReady` would then
    // never resolve, and the ONLY thing that unblocks `connect()` is the
    // `.timeout()` firing for real, which would leave that Timer pending
    // across this test's disposal unless it actually gets to fire. Mocking
    // storage instead makes the read resolve in a couple of microtasks, so
    // the timeout Timer self-cancels almost immediately. Same fake the
    // 'sign-in gating' group already uses for `TokenStore`, whose storage
    // this shares.
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(<String, String>{});
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
      MaterialApp(
        home: HenryHome(connection: conn, session: FakeBrowserSession()),
      ),
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
    // Ordered: both topics register SYNCHRONOUSLY (VoiceController's
    // constructor, then BadgesClient's, in that construction order in
    // `_buildShell`) regardless of the device id, which only delays WHEN
    // `connect()` itself runs, not the order `_wanted` was built in before
    // it does — so this is deterministic, same as before device ids existed.
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

  // ---- sign-in gating: the login screen, and the handoff into the shell ----
  //
  // Every test above builds HenryHome with an explicit `connection`, which
  // bypasses sign-in entirely (see HenryHome.connection's doc) — the exact
  // shape every other drawer/routing test in this repo wants. These tests
  // instead exercise the OTHER path: no injected connection, so HenryHome
  // must build a real AuthController, show LoginScreen until it settles, and
  // only dial a connection once an AuthCodeLink exchanges successfully.
  group('sign-in gating', () {
    // A fresh in-memory keystore per test, exactly as token_store_test.dart
    // does it, so no test observes another's stored token.
    TokenStore freshStore() {
      FlutterSecureStoragePlatform.instance =
          TestFlutterSecureStoragePlatform(<String, String>{});
      return TokenStore(storage: const FlutterSecureStorage());
    }

    testWidgets('signed out shows the login screen, not the voice shell',
        (tester) async {
      phone(tester);
      final auth = AuthController(store: freshStore());
      addTearDown(auth.dispose);
      await tester.pumpWidget(MaterialApp(home: HenryHome(auth: auth)));
      // One pump for the widget tree, one for the store read's Future to
      // resolve and notifyListeners() to land.
      await tester.pump();
      await tester.pump();

      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.byType(MeridianVoiceScreen), findsNothing);
    });

    testWidgets(
        "tapping Sign in opens Authentik's login in the OS auth session",
        (tester) async {
      phone(tester);
      final session = FakeBrowserSession();
      final auth = AuthController(store: freshStore(), session: session);
      addTearDown(auth.dispose);
      await tester.pumpWidget(
          MaterialApp(home: HenryHome(auth: auth, session: session)));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byKey(const Key('login-screen-sign-in')));
      await tester.pump();

      expect(session.opened, hasLength(1));
      expect(session.opened.single.path, '/auth/login');
      expect(session.opened.single.queryParameters['return'], 'app');
    });

    testWidgets(
        'an error callback keeps the login screen up and shows why',
        (tester) async {
      phone(tester);
      final session =
          FakeBrowserSession(result: Uri.parse('orbital://auth?status=error'));
      final auth = AuthController(store: freshStore(), session: session);
      addTearDown(auth.dispose);
      await tester.pumpWidget(
          MaterialApp(home: HenryHome(auth: auth, session: session)));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byKey(const Key('login-screen-sign-in')));
      await tester.pump();
      await tester.pump();

      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.byKey(const Key('login-screen-error')), findsOneWidget);
    });

    testWidgets(
        'a code callback exchanges, stores the token, and hands off to '
        'the connected shell — without ever dialing a real socket',
        (tester) async {
      phone(tester);
      final store = freshStore();
      final client = MockClient((request) async =>
          http.Response(jsonEncode({'token': 'exchanged-token'}), 200));
      final session =
          FakeBrowserSession(result: Uri.parse('orbital://auth?code=the-code'));
      final auth =
          AuthController(store: store, httpClient: client, session: session);
      addTearDown(auth.dispose);
      final fake = FakeSocket();

      await tester.pumpWidget(MaterialApp(
        home: HenryHome(
          auth: auth,
          session: session,
          // The seam that keeps this test from dialing the configured
          // server: HenryHome hands the freshly-signed-in token to this
          // instead of building a default AppConnection.
          buildConnection: (token, onRejected) => AppConnection(
            connector: () async => fake.socket,
            rejoinBackoff: const [Duration(days: 1)],
          ),
        ),
      ));
      await tester.pump();
      await tester.pump();
      expect(find.byType(LoginScreen), findsOneWidget);

      await tester.tap(find.byKey(const Key('login-screen-sign-in')));
      // The session's own resolution, an HTTP round trip (MockClient still
      // hops a microtask), the store write, and connect()'s own await on the
      // connector — several pumps, not one.
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.byType(LoginScreen), findsNothing);
      expect(find.byType(MeridianVoiceScreen), findsOneWidget,
          reason: 'a successful exchange must open the same shell every '
              'other test in this file reaches via an injected connection');
      expect(await store.read(), 'exchanged-token');
    });

    // The rejected-token classifier lives in AppConnection, but it is inert unless main.dart
    // actually hands it somewhere to report to. It shipped unwired and every test stayed green,
    // because the injection seam supplied its own connection and never exercised what
    // main.dart passes. So this asserts the WIRING, not the classifier: that HenryHome gives
    // the connection a non-null onRejected, and that invoking it signs the user out.
    testWidgets('a rejected socket is wired back to sign-out', (tester) async {
      phone(tester);
      final store = freshStore();
      await store.write('stored-token');
      final client = MockClient((_) async => http.Response('{}', 500));
      final auth = AuthController(store: store, httpClient: client);
      addTearDown(auth.dispose);
      final fake = FakeSocket();
      Future<void> Function()? captured;

      await tester.pumpWidget(MaterialApp(
        home: HenryHome(
          auth: auth,
          buildConnection: (token, onRejected) {
            captured = onRejected;
            return AppConnection(
              connector: () async => fake.socket,
              rejoinBackoff: const [Duration(days: 1)],
            );
          },
        ),
      ));
      await tester.pump();
      await tester.pump();

      expect(captured, isNotNull,
          reason: 'main.dart must pass onRejected, or a refused token retries forever');

      await captured!();
      await tester.pump();

      expect(await store.read(), isNull,
          reason: 'a refused token must be cleared, not retried');
      expect(auth.state, AuthState.signedOut);
      expect(find.byType(LoginScreen), findsOneWidget,
          reason: 'signOut() clearing the store is not enough — the shell must actually tear '
              'down and fall through to the login screen, or the user is stuck on a dead '
              'MeridianVoiceScreen with no way back in short of killing the app');
    });
  });

  group('device id gating', () {
    // Pins `_buildShell`'s `unawaited(_connectOnceDeviceIdKnown(vc, conn))`.
    // A prior fix round found that reverting it to a bare `conn.connect()`
    // left all 725 tests green — nothing exercised the actual production
    // wiring that makes the FIRST join deterministically carry the device
    // id rather than racing it against the socket handshake.
    testWidgets(
        'the first join waits for the device id before dialing — a bare '
        'conn.connect() would send it without one', (tester) async {
      phone(tester);
      FlutterSecureStoragePlatform.instance = _DelayedSecureStoragePlatform();
      final fake = FakeSocket();
      final conn = AppConnection(
        connector: () async => fake.socket,
        rejoinBackoff: const [Duration(days: 1)],
      );

      await tester.pumpWidget(MaterialApp(home: HenryHome(connection: conn)));
      // Advance the fake clock past the delayed device-id read, then let
      // connect()'s own connector + join round trip settle.
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump();
      await tester.pump();

      final join = fake.textFrames.firstWhere(
          (p) => p[3] == 'phx_join' && p[2] == 'voice:henry',
          orElse: () => fail('voice:henry never joined'));
      expect((join[4] as Map)['device_id'], isNotNull,
          reason: '_buildShell must await deviceIdReady before calling '
              'conn.connect(), or the first join races the device-id read '
              'and can land without one');
    });
  });
}
