import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/meridian/header.dart';
import 'package:orbital_pai/meridian/hold_to_talk.dart';
import 'package:orbital_pai/meridian/hero_icon.dart';
import 'package:orbital_pai/meridian/nav.dart';
import 'package:orbital_pai/meridian/orb_bezel.dart';
import 'package:orbital_pai/meridian/thread.dart';
import 'package:orbital_pai/meridian/tokens.dart';
import 'package:orbital_pai/meridian/voice_screen.dart';
import 'package:orbital_pai/panels/badges_client.dart';
import 'package:orbital_pai/phoenix/decoded_message.dart';
import 'package:orbital_pai/connection/app_connection.dart';
import 'package:orbital_pai/voice/voice_controller.dart';

import '../support/fake_socket.dart';
import '../support/fakes.dart';

/// heroicons are SVGs, not IconData, so `find.byIcon` does not apply.
Finder findHero(HeroIcon icon) =>
    find.byWidgetPredicate((w) => w is HeroIconView && w.icon == icon);

void main() {
  late AppConnection conn;

  // The screen never drives the transport; Task 4 points its dot at this.
  setUp(() =>
      conn = AppConnection(connector: () async => throw StateError('no socket')));
  tearDown(() => conn.dispose());

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('the whole chrome mounts and lays out without overflow',
      (tester) async {
    phone(tester);
    final vc = VoiceController(connection: conn, mic: FakeMic(), player: FakePlayer());
    addTearDown(vc.dispose);

    await tester.pumpWidget(MaterialApp(
      home: MeridianVoiceScreen(controller: vc, connection: conn, userName: 'David'),
    ));
    await tester.pump();

    expect(find.byType(MeridianHeader), findsOneWidget);
    expect(find.byType(OrbBezel), findsOneWidget);
    expect(find.byType(Thread), findsOneWidget);
    expect(find.byType(HoldToTalkBar), findsOneWidget);
    expect(find.byType(MeridianNav), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no text inherits the missing-Material underline', (tester) async {
    // Shipped once: with no Material ancestor, WidgetsApp's fallback
    // DefaultTextStyle applies, and our styles override its colour/size/family
    // but NOT its `decoration` — so every label wore a yellow double underline.
    // The declared style is clean either way, so this has to assert the MERGED
    // style the RichText actually paints.
    phone(tester);
    final vc = VoiceController(connection: conn, mic: FakeMic(), player: FakePlayer());
    addTearDown(vc.dispose);

    await tester.pumpWidget(MaterialApp(
      home: MeridianVoiceScreen(controller: vc, connection: conn, userName: 'David'),
    ));
    await tester.pump();

    final painted = tester.widgetList<RichText>(find.byType(RichText));
    expect(painted, isNotEmpty);
    for (final rich in painted) {
      final style = (rich.text as TextSpan).style;
      expect(style?.decoration ?? TextDecoration.none, TextDecoration.none,
          reason: 'decoration leaked into "${rich.text.toPlainText()}"');
    }
  });

  testWidgets('a live turn flows through to the thread', (tester) async {
    phone(tester);
    final vc = VoiceController(connection: conn, mic: FakeMic(), player: FakePlayer());
    addTearDown(vc.dispose);

    await tester.pumpWidget(MaterialApp(
      home: MeridianVoiceScreen(controller: vc, connection: conn, userName: 'David'),
    ));
    vc.debugHandleMessage(const DecodedMessage(
      topic: 'voice:henry',
      event: 'transcript',
      json: {'text': 'hello henry'},
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('hello henry'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long transcript scrolls instead of overflowing',
      (tester) async {
    phone(tester);
    final vc = VoiceController(connection: conn, mic: FakeMic(), player: FakePlayer());
    addTearDown(vc.dispose);

    await tester.pumpWidget(MaterialApp(
      home: MeridianVoiceScreen(controller: vc, connection: conn, userName: 'David'),
    ));
    for (var i = 0; i < 40; i++) {
      vc.debugHandleMessage(DecodedMessage(
        topic: 'voice:henry',
        event: 'transcript',
        json: {'text': 'turn number $i with a reasonably long body to wrap'},
      ));
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull,
        reason: 'the thread is the only flexible row — it must absorb the growth');
  });

  testWidgets('the nav reports taps up to the host', (tester) async {
    phone(tester);
    final vc = VoiceController(connection: conn, mic: FakeMic(), player: FakePlayer());
    addTearDown(vc.dispose);
    final opened = <MeridianTab>[];

    await tester.pumpWidget(MaterialApp(
      home: MeridianVoiceScreen(
        controller: vc,
        connection: conn,
        userName: 'David',
        onOpenPanel: opened.add,
      ),
    ));
    await tester.tap(findHero(MeridianTab.settings.icon));
    expect(opened, [MeridianTab.settings]);
  });

  testWidgets('the header shows the app version and user', (tester) async {
    phone(tester);
    final vc = VoiceController(connection: conn, mic: FakeMic(), player: FakePlayer());
    addTearDown(vc.dispose);

    await tester.pumpWidget(MaterialApp(
      home: MeridianVoiceScreen(
        controller: vc,
        connection: conn,
        userName: 'David',
        appVersion: '9.9.9',
      ),
    ));
    expect(find.text('P.A.I V9.9.9'), findsOneWidget);
    expect(find.text('DAVID'), findsOneWidget);
    expect(find.text('HENRY'), findsOneWidget);
  });

  testWidgets('the header dot reflects the CONNECTION, not the conversation',
      (tester) async {
    phone(tester);
    final vc = VoiceController(connection: conn, mic: FakeMic(), player: FakePlayer());
    addTearDown(vc.dispose);

    await tester.pumpWidget(MaterialApp(
      home: MeridianVoiceScreen(
          controller: vc, connection: conn, userName: 'David'),
    ));
    await tester.pump();

    Color? dotColor() => (tester
            .widget<Container>(find.byKey(const ValueKey('conn-dot')))
            .decoration! as BoxDecoration)
        .color;

    // Never connected -> the dot is the connecting amber, and it got there from
    // AppConnection. Reading it off the controller would not even compile now,
    // which is the point.
    expect(conn.connStatus, ConnStatus.connecting);
    expect(dotColor(), connDotColors(ConnStatus.connecting).fill);

    // Drive the CONNECTION (not the controller — vc never touches conn's
    // state) to a new status: connect() awaits the injected connector, which
    // throws, landing on ConnState.error -> ConnStatus.offline. If the screen
    // rebuilt only off `vc`, this would still show the stale amber dot.
    unawaited(conn.connect());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(conn.connStatus, ConnStatus.offline);
    expect(dotColor(), connDotColors(ConnStatus.offline).fill);
    expect(dotColor(), isNot(connDotColors(ConnStatus.connecting).fill));

    // The failed connect() scheduled a rejoin Timer (default backoff starts at
    // 1s); disconnect() cancels it. Without this, flutter_test's pending-timer
    // invariant fails BEFORE the file's tearDown(conn.dispose) ever runs —
    // addTearDown/tearDown fire after binding.runTest's own invariant check.
    await conn.disconnect();
  });

  testWidgets('the bezel is NOT told the power is safe while the socket is down',
      (tester) async {
    // Task 6: the bezel's `powerEnabled` must be FED from the connection, not
    // hardcoded true — a hardcoded true would silently reintroduce the
    // pre-join power tap the task fixed. `conn` here never joins (its
    // connector throws), so this is the "not connected" direction.
    phone(tester);
    final vc = VoiceController(connection: conn, mic: FakeMic(), player: FakePlayer());
    addTearDown(vc.dispose);

    await tester.pumpWidget(MaterialApp(
      home: MeridianVoiceScreen(controller: vc, connection: conn, userName: 'David'),
    ));
    await tester.pump();

    expect(conn.connStatus, ConnStatus.connecting);
    expect(tester.widget<OrbBezel>(find.byType(OrbBezel)).powerEnabled, isFalse);
  });

  testWidgets('the bezel is told the power is safe once the socket has joined',
      (tester) async {
    // The other direction: a real join over a FakeSocket must flip
    // powerEnabled to true. Testing only the "false" direction would pass
    // vacuously against a hardcoded `powerEnabled: false` too.
    phone(tester);
    final conn2 = AppConnection(connector: () async => FakeSocket().socket);
    addTearDown(conn2.dispose);
    final vc = VoiceController(connection: conn2, mic: FakeMic(), player: FakePlayer());
    addTearDown(vc.dispose);

    await conn2.connect();
    await tester.pumpWidget(MaterialApp(
      home: MeridianVoiceScreen(controller: vc, connection: conn2, userName: 'David'),
    ));
    await tester.pump();

    expect(conn2.connStatus, ConnStatus.connected);
    expect(tester.widget<OrbBezel>(find.byType(OrbBezel)).powerEnabled, isTrue);

    // The socket's heartbeat is a 24h periodic Timer — still pending at this
    // point. addTearDown runs AFTER the framework's pending-timer invariant
    // check (see the "header dot" test above), so it must be torn down here,
    // in-body, not left to addTearDown(conn2.dispose).
    await conn2.disconnect();
  });

  testWidgets('the nav dot follows the badges client', (tester) async {
    phone(tester);
    final vc = VoiceController(connection: conn, mic: FakeMic(), player: FakePlayer());
    final badges = BadgesClient(connection: conn);
    addTearDown(() {
      vc.dispose();
      badges.dispose();
    });

    await tester.pumpWidget(MaterialApp(
      home: MeridianVoiceScreen(
        controller: vc,
        connection: conn,
        badges: badges,
        userName: 'David',
      ),
    ));
    await tester.pump();
    expect(find.byKey(const ValueKey('due-dot')), findsNothing);

    // The frame the server pushes when something fires.
    badges.debugHandleMessage(const DecodedMessage(
      topic: 'badges:henry',
      event: 'badges',
      json: {'reminders': 1},
    ));
    await tester.pump();

    expect(find.byKey(const ValueKey('due-dot')), findsOneWidget,
        reason: 'the screen must be listening to the badges client, not snapshotting it');
  });

  // ---- the scroll anchor ----
  //
  // The bug: `_autoScroll` keyed off the thread's LENGTH, and a streaming
  // answer rewrites ONE existing ThreadLine in place (`brain_delta`), so the
  // length never moved while the line grew taller and ran off the bottom.

  /// The Thread's own scroll position, for reading pixels/extent directly.
  ScrollPosition threadPosition(WidgetTester tester) => tester
      .state<ScrollableState>(find
          .descendant(of: find.byType(Thread), matching: find.byType(Scrollable))
          .first)
      .position;

  /// `pumpAndSettle` is unusable on this screen — the orb animates forever —
  /// so pump a fixed stretch instead, long enough for a drag's ballistic tail
  /// to come to rest.
  Future<void> settleScroll(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Enough turns to overflow the viewport, so there is somewhere to scroll.
  Future<void> fillThread(WidgetTester tester, VoiceController vc) async {
    for (var i = 0; i < 40; i++) {
      vc.debugHandleMessage(DecodedMessage(
        topic: 'voice:henry',
        event: 'transcript',
        json: {'text': 'turn number $i with a reasonably long body to wrap'},
      ));
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Grow ONE brain line, without ever changing the thread's length.
  Future<void> streamAnswer(WidgetTester tester, VoiceController vc,
      {int chunks = 8}) async {
    for (var i = 0; i < chunks; i++) {
      vc.debugHandleMessage(const DecodedMessage(
        topic: 'voice:henry',
        event: 'brain_delta',
        json: {
          'delta': 'and then it kept on talking for quite a while longer still '
        },
      ));
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('a streaming answer keeps a bottom-anchored view at the bottom',
      (tester) async {
    // Would have caught the report verbatim: with the length check, every
    // delta after the first returned early and the offset froze.
    phone(tester);
    final vc = VoiceController(connection: conn, mic: FakeMic(), player: FakePlayer());
    addTearDown(vc.dispose);

    await tester.pumpWidget(MaterialApp(
      home: MeridianVoiceScreen(controller: vc, connection: conn, userName: 'David'),
    ));
    await fillThread(tester, vc);

    // Open the brain line (this one DOES change the length) and settle there.
    vc.debugHandleMessage(const DecodedMessage(
      topic: 'voice:henry',
      event: 'brain_delta',
      json: {'delta': 'well '},
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final lengthBefore = vc.thread.length;
    final extentBefore = threadPosition(tester).maxScrollExtent;

    await streamAnswer(tester, vc);

    final pos = threadPosition(tester);
    expect(vc.thread.length, lengthBefore,
        reason: 'the deltas must grow ONE line, not append — else the old '
            'length check would have passed this by accident');
    expect(pos.maxScrollExtent, greaterThan(extentBefore),
        reason: 'the line has to actually get taller for this to test anything');
    expect(pos.pixels, moreOrLessEquals(pos.maxScrollExtent, epsilon: 0.5),
        reason: 'a reader at the bottom stays at the bottom as the answer grows');
  });

  testWidgets('growing content does not yank a reader who scrolled up',
      (tester) async {
    phone(tester);
    final vc = VoiceController(connection: conn, mic: FakeMic(), player: FakePlayer());
    addTearDown(vc.dispose);

    await tester.pumpWidget(MaterialApp(
      home: MeridianVoiceScreen(controller: vc, connection: conn, userName: 'David'),
    ));
    await fillThread(tester, vc);

    // Drag the content DOWN, i.e. scroll back up through the history.
    await tester.drag(
        find.descendant(of: find.byType(Thread), matching: find.byType(Scrollable)).first,
        const Offset(0, 400));
    await settleScroll(tester);

    final parked = threadPosition(tester).pixels;
    expect(parked, lessThan(threadPosition(tester).maxScrollExtent - 32),
        reason: 'the drag has to leave us clear of the anchor slack');

    vc.debugHandleMessage(const DecodedMessage(
      topic: 'voice:henry',
      event: 'brain_delta',
      json: {'delta': 'well '},
    ));
    await tester.pump();
    await streamAnswer(tester, vc);

    expect(threadPosition(tester).pixels, moreOrLessEquals(parked, epsilon: 0.5),
        reason: 'reading back is a deliberate act; new content must not undo it');
  });

  testWidgets('scrolling back to the bottom re-arms the anchor', (tester) async {
    phone(tester);
    final vc = VoiceController(connection: conn, mic: FakeMic(), player: FakePlayer());
    addTearDown(vc.dispose);

    await tester.pumpWidget(MaterialApp(
      home: MeridianVoiceScreen(controller: vc, connection: conn, userName: 'David'),
    ));
    await fillThread(tester, vc);

    final scroller = find
        .descendant(of: find.byType(Thread), matching: find.byType(Scrollable))
        .first;
    await tester.drag(scroller, const Offset(0, 400));
    await settleScroll(tester);
    // Big enough to bottom out whatever momentum the first drag left behind —
    // `tester.drag` moves in one step, so it can register as a fling.
    await tester.drag(scroller, const Offset(0, -4000));
    await settleScroll(tester);
    final pos0 = threadPosition(tester);
    expect(pos0.pixels, moreOrLessEquals(pos0.maxScrollExtent, epsilon: 0.5),
        reason: 'the second drag has to actually land us back at the bottom');

    vc.debugHandleMessage(const DecodedMessage(
      topic: 'voice:henry',
      event: 'brain_delta',
      json: {'delta': 'well '},
    ));
    await tester.pump();
    await streamAnswer(tester, vc);

    final pos = threadPosition(tester);
    expect(pos.pixels, moreOrLessEquals(pos.maxScrollExtent, epsilon: 0.5),
        reason: 'coming back to the bottom opts back in to following along');
  });
}
