import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/connection/app_connection.dart';
import 'package:orbital_pai/meridian/cards/card_view.dart';
import 'package:orbital_pai/meridian/composer.dart';
import 'package:orbital_pai/meridian/header.dart';
import 'package:orbital_pai/meridian/nav.dart';
import 'package:orbital_pai/meridian/orb_bezel.dart';
import 'package:orbital_pai/meridian/orb_shader.dart';
import 'package:orbital_pai/meridian/orb_state.dart';
import 'package:orbital_pai/meridian/thread.dart';
import 'package:orbital_pai/meridian/thread_model.dart';
import 'package:orbital_pai/meridian/timer_strip.dart';
import 'package:orbital_pai/meridian/tokens.dart';
import 'package:orbital_pai/meridian/voice_screen.dart';
import 'package:orbital_pai/meridian/wall_layout.dart';
import 'package:orbital_pai/phoenix/decoded_message.dart';
import 'package:orbital_pai/voice/voice_controller.dart';

import '../support/fake_alarm.dart';
import '../support/fakes.dart';
import 'card_fixtures.dart';

DecodedMessage _msg(String event, Map<String, dynamic> json) =>
    DecodedMessage(topic: 'voice:henry', event: event, json: json);

/// The wall tablet between conversations: powered on and at rest — without a
/// socket or a microphone. The orb state is posed rather than earned, because
/// earning it takes a joined socket and a live mic.
class _WallStage extends VoiceController {
  _WallStage({required super.connection, this.posed = OrbState.idle})
      : super(
          mic: FakeMic(),
          player: FakePlayer(),
          alarm: FakeAlarm(),
          // Frozen, so the countdowns hold still for the golden.
          timerClock: () => const Duration(hours: 1),
        );

  final OrbState posed;

  @override
  bool get micOn => true;

  @override
  OrbState get orbState => posed;
}

/// A realistic afternoon: the glance, two kitchen timers, a weather question
/// answered with its card, and a live follow-up. [locked] is the wall
/// tablet's usual rest — voice activation on, waiting for its name.
void _furnish(VoiceController vc, {bool locked = false}) {
  if (locked) vc.debugHandleMessage(_msg('locked', const {'locked': true}));
  vc.debugHandleMessage(_msg('glance', const {
    'weather': {
      'temp': '64°',
      'condition': 'Partly cloudy',
      'icon': 'partly-day'
    },
    'next_event': {
      'title': 'Dinner with Mom',
      'time': '7:30 PM',
      'day': 'Today'
    },
  }));
  vc.debugHandleMessage(_msg('timers', const {
    'timers': [
      {
        'id': 1,
        'label': 'pasta',
        'state': 'running',
        'duration_ms': 600000,
        'remaining_ms': 342000,
      },
      {
        'id': 2,
        'label': 'bread',
        'state': 'running',
        'duration_ms': 2400000,
        'remaining_ms': 1395000,
      },
    ],
  }));
  vc.debugHandleMessage(_msg('history', const {
    'turns': [
      {
        'you':
            'Set a pasta timer for ten minutes, and one for the bread — forty.',
        'assistant': 'Done — pasta in ten, bread in forty.',
      },
      {
        'you': "What's the weather doing this week?",
        'assistant':
            'Mild today at 64° and partly cloudy. **Rain moves in Sunday**, '
                'storms on Monday, then it clears out and cools off midweek.',
        'cards': [weatherCard],
      },
    ],
  }));
  vc.debugHandleMessage(_msg(
      'transcript', const {'text': 'Should I bring an umbrella tonight?'}));
  vc.debugHandleMessage(_msg('brain_delta', const {
    'delta': "Not tonight — the rain holds off until tomorrow afternoon. "
        "Dinner with Mom at 7:30 should stay dry.",
  }));
}

void main() {
  late AppConnection conn;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final display = FontLoader(kDisplayFamily)
      ..addFont(rootBundle.load('assets/fonts/SpaceGrotesk.ttf'));
    final body = FontLoader(kBodyFamily)
      ..addFont(rootBundle.load('assets/fonts/Inter.ttf'));
    await Future.wait([display.load(), body.load()]);
  });

  setUp(() => conn =
      AppConnection(connector: () async => throw StateError('no socket')));
  tearDown(() => conn.dispose());

  void screen(WidgetTester tester, Size logical, {double dpr = 1.0}) {
    tester.view.physicalSize = logical * dpr;
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.reset);
  }

  Future<VoiceController> mount(WidgetTester tester,
      {bool furnished = true, OrbState posed = OrbState.idle}) async {
    final vc = _WallStage(connection: conn, posed: posed);
    addTearDown(vc.dispose);
    if (furnished) _furnish(vc, locked: posed == OrbState.ambient);
    // The orb follows the posed state, not the (socketless) turn.
    vc.orbFrame.state = posed;
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      // The app's own theme. The few strings that set no family (the
      // "earlier" divider) take the platform font on a device; Inter stands in
      // for it here so they render as words rather than test-font boxes.
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: M.bg,
        textTheme: ThemeData.dark().textTheme.apply(fontFamily: kBodyFamily),
      ),
      home: MeridianVoiceScreen(
        controller: vc,
        connection: conn,
        userName: 'David',
        appVersion: '0.9.0',
        clock: () => DateTime(2026, 10, 10, 17, 42),
      ),
    ));
    await tester.pump();
    return vc;
  }

  double bezelSide(WidgetTester tester) =>
      tester.getSize(find.byType(OrbBezel)).width;

  group('breakpoints', () {
    test('come from the width alone', () {
      expect(WallLayout.forWidth(360), WallLayout.compact);
      expect(WallLayout.forWidth(599.9), WallLayout.compact);
      expect(WallLayout.forWidth(600), WallLayout.medium);
      expect(WallLayout.forWidth(899.9), WallLayout.medium);
      expect(WallLayout.forWidth(900), WallLayout.expanded);
      expect(WallLayout.forWidth(1920), WallLayout.expanded);
    });
  });

  testWidgets('compact (360x800): the phone column, exactly as before',
      (tester) async {
    screen(tester, const Size(360, 800), dpr: 3);
    await mount(tester);

    expect(find.byKey(wallOrbPaneKey), findsNothing);
    expect(find.byKey(wallThreadPaneKey), findsNothing);
    // M.orbPaneMaxWidth * M.bezelPaneFraction — the phone's bezel, untouched.
    expect(bezelSide(tester),
        moreOrLessEquals(M.orbPaneMaxWidth * M.bezelPaneFraction));
    expect(tester.getSize(find.byType(Thread)).width, 360 - 2 * M.pagePad);

    // One column, top to bottom.
    final header = tester.getRect(find.byType(MeridianHeader));
    final orb = tester.getRect(find.byType(OrbBezel));
    final strip = tester.getRect(find.byType(TimerStrip));
    final thread = tester.getRect(find.byType(Thread));
    final composer = tester.getRect(find.byType(ComposerDock));
    final nav = tester.getRect(find.byType(MeridianNav));
    expect(header.bottom, lessThanOrEqualTo(orb.top));
    expect(orb.bottom, lessThanOrEqualTo(strip.top));
    expect(strip.bottom, lessThanOrEqualTo(thread.top));
    expect(thread.bottom, lessThanOrEqualTo(composer.top));
    expect(composer.bottom, lessThanOrEqualTo(nav.top));
    expect(tester.widget<Thread>(find.byType(Thread)).joinsAbove, isTrue);
    expect(tester.widget<TimerStrip>(find.byType(TimerStrip)).railed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('medium (800x1280): one column, sized for the tablet',
      (tester) async {
    screen(tester, const Size(800, 1280));
    await mount(tester);

    expect(find.byKey(wallOrbPaneKey), findsNothing,
        reason: 'a portrait tablet is still one column');
    expect(bezelSide(tester), greaterThan(360),
        reason:
            'the orb is the centrepiece, not a phone orb in a tablet margin');
    expect(bezelSide(tester), lessThanOrEqualTo(Wall.mediumBezelMaxWidth));

    final thread = tester.getRect(find.byType(Thread));
    expect(thread.width, Wall.mediumMaxWidth - 2 * M.pagePad);
    expect(thread.center.dx, 400, reason: 'the column is centred');
    expect(
        thread.top, greaterThan(tester.getRect(find.byType(OrbBezel)).bottom));
    expect(thread.height, greaterThan(400),
        reason: 'and the thread still gets real room');
    expect(tester.getRect(find.byType(MeridianNav)).bottom,
        lessThanOrEqualTo(1280));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'expanded (1280x800): the orb pane and the thread pane, side by side',
      (tester) async {
    screen(tester, const Size(1280, 800));
    await mount(tester);

    final orbPane = tester.getRect(find.byKey(wallOrbPaneKey));
    final threadPane = tester.getRect(find.byKey(wallThreadPaneKey));
    expect(orbPane.right, lessThan(threadPane.left),
        reason: 'two panes, left and right');
    expect(orbPane.width,
        moreOrLessEquals((1280 - 2 * Wall.pagePad) * Wall.orbPaneFraction));

    // The left pane: header, the orb as the hero, the timers, the composer.
    for (final part in [MeridianHeader, OrbBezel, TimerStrip, ComposerDock]) {
      expect(
          find.descendant(
              of: find.byKey(wallOrbPaneKey), matching: find.byType(part)),
          findsOneWidget,
          reason: '$part belongs to the orb pane');
    }
    expect(bezelSide(tester), greaterThan(420));
    expect(bezelSide(tester), lessThanOrEqualTo(Wall.bezelMaxWidth));
    expect(tester.widget<TimerStrip>(find.byType(TimerStrip)).railed, isFalse,
        reason: 'no spine runs past the timers in this pane');
    expect(tester.getRect(find.byType(ComposerDock)).bottom,
        moreOrLessEquals(800 - Wall.pagePad),
        reason: 'the composer is pinned to the foot of the pane');

    // The right pane: the thread at full height, the nav under it.
    for (final part in [Thread, MeridianNav]) {
      expect(
          find.descendant(
              of: find.byKey(wallThreadPaneKey), matching: find.byType(part)),
          findsOneWidget,
          reason: '$part belongs to the thread pane');
    }
    final thread = tester.getRect(find.byType(Thread));
    expect(thread.top, moreOrLessEquals(Wall.pagePad));
    expect(thread.height, greaterThan(640));
    expect(tester.widget<Thread>(find.byType(Thread)).joinsAbove, isFalse,
        reason: 'no elbow comes down into this spine');
    expect(
        find.byWidgetPredicate(
            (w) => w is CustomPaint && w.painter is ElbowPainter),
        findsNothing);

    // Cards get Henry's wider column, capped.
    final card = tester.getRect(find.byType(ThreadCardView));
    expect(card.width, greaterThan(300));
    expect(card.width, lessThanOrEqualTo(Thread.maxCardWidth));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a big desktop window centres the two panes as one composition',
      (tester) async {
    screen(tester, const Size(1920, 1080));
    await mount(tester);

    final orbPane = tester.getRect(find.byKey(wallOrbPaneKey));
    final threadPane = tester.getRect(find.byKey(wallThreadPaneKey));
    expect(orbPane.width, Wall.orbPaneMaxWidth);
    expect(threadPane.width, lessThanOrEqualTo(Wall.threadMaxWidth));
    expect(orbPane.left, moreOrLessEquals(1920 - threadPane.right, epsilon: 16),
        reason: 'equal margins, not an orb hugging the left edge');
    expect(bezelSide(tester), lessThanOrEqualTo(Wall.bezelMaxWidth));
    expect(tester.takeException(), isNull);
  });

  testWidgets('expanded: the keyboard lifts the composer; nothing overflows',
      (tester) async {
    screen(tester, const Size(1280, 800));
    await mount(tester);
    final restingOrb = bezelSide(tester);

    await tester.tap(find.byKey(ComposerDock.keyboardKey));
    await tester.pump(const Duration(milliseconds: 300));
    tester.view.viewInsets = const FakeViewPadding(bottom: 360);
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    expect(tester.getBottomLeft(find.byKey(ComposerDock.fieldKey)).dy,
        lessThanOrEqualTo(800 - 360));
    expect(bezelSide(tester), lessThan(restingOrb),
        reason: 'the orb gives way');
    expect(find.byType(MeridianNav), findsNothing,
        reason: 'the nav steps aside');
    final thread = tester.getRect(find.byType(Thread));
    expect(thread.bottom, lessThanOrEqualTo(800 - 360),
        reason: 'the newest line is never under the keyboard');
    expect(thread.top, moreOrLessEquals(Wall.pagePad),
        reason: 'and the thread keeps everything above it');

    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(MeridianNav), findsOneWidget);
    expect(bezelSide(tester), restingOrb);
    expect(tester.takeException(), isNull);
  });

  testWidgets('medium: the keyboard lifts the composer; nothing overflows',
      (tester) async {
    screen(tester, const Size(800, 1280));
    await mount(tester);

    await tester.tap(find.byKey(ComposerDock.keyboardKey));
    await tester.pump(const Duration(milliseconds: 300));
    tester.view.viewInsets = const FakeViewPadding(bottom: 520);
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    expect(tester.getBottomLeft(find.byKey(ComposerDock.fieldKey)).dy,
        lessThanOrEqualTo(1280 - 520));
    expect(tester.getSize(find.byType(Thread)).height, greaterThan(120));
  });

  testWidgets('a short medium window keeps a thread under its orb',
      (tester) async {
    screen(tester, const Size(700, 560));
    await mount(tester);

    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(Thread)).height, greaterThan(100));
  });

  testWidgets('rotating across the breakpoint keeps the draft and the focus',
      (tester) async {
    screen(tester, const Size(800, 1280));
    await mount(tester, furnished: false);

    await tester.tap(find.byKey(ComposerDock.keyboardKey));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
        find.byKey(ComposerDock.fieldKey), 'half-typed thought');
    await tester.pump();

    tester.view.physicalSize = const Size(1280, 800);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(wallOrbPaneKey), findsOneWidget,
        reason: 'now the wall layout');
    final field = tester.widget<TextField>(find.byKey(ComposerDock.fieldKey));
    expect(field.controller!.text, 'half-typed thought');
    expect(field.focusNode!.hasFocus, isTrue);
  });

  testWidgets('a card never stretches past its cap, however wide the thread',
      (tester) async {
    screen(tester, const Size(1200, 700));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Thread(
          glow: M.henry,
          items: [ThreadCard.fromWire(weatherCard)!],
        ),
      ),
    ));
    expect(
        tester.getSize(find.byType(ThreadCardView)).width, Thread.maxCardWidth);
    expect(tester.takeException(), isNull);
  });

  group('goldens', () {
    // The real orb shader, loaded up front so the first frame already has it.
    setUp(() async => OrbShaderProgram.load());

    Future<void> shoot(WidgetTester tester, Size size, String name,
        {OrbState posed = OrbState.idle}) async {
      screen(tester, size);
      await mount(tester, posed: posed);
      // The orb and the surface both animate; a fixed stretch of the fake
      // clock lands them on the same frame every run.
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await expectLater(
          find.byType(MeridianVoiceScreen), matchesGoldenFile(name));
    }

    // Regenerate deliberately, then LOOK at the PNGs:
    //   flutter test --update-goldens test/meridian/voice_screen_wall_test.dart
    testWidgets('medium: a portrait tablet, awake', (tester) async {
      await shoot(
          tester, const Size(800, 1280), 'goldens/voice_wall_medium.png');
    });

    // Ambient: the wall tablet's usual rest — voice activation on, the orb
    // dimmed to slate, waiting for its name.
    testWidgets('expanded: the wall display at rest', (tester) async {
      await shoot(
          tester, const Size(1280, 800), 'goldens/voice_wall_expanded.png',
          posed: OrbState.ambient);
    });
  });
}
