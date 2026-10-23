import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/connection/app_connection.dart';
import 'package:orbital_pai/meridian/cards/card_view.dart';
import 'package:orbital_pai/meridian/composer.dart';
import 'package:orbital_pai/meridian/header.dart';
import 'package:orbital_pai/meridian/hero_icon.dart';
import 'package:orbital_pai/meridian/meridian_surface.dart';
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
import 'package:orbital_pai/meridian/wall_type.dart';
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
/// tablet's usual rest — voice activation on, waiting for its name. [event]
/// is the orb face's next event.
void _furnish(VoiceController vc,
    {bool locked = false, String event = 'Dinner with Mom'}) {
  if (locked) vc.debugHandleMessage(_msg('locked', const {'locked': true}));
  vc.debugHandleMessage(_msg('glance', {
    'weather': const {
      'temp': '64°',
      'condition': 'Partly cloudy',
      'icon': 'partly-day'
    },
    'next_event': {'title': event, 'time': '7:30 PM', 'day': 'Today'},
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

  /// The wall tablet as it reports itself: a Lenovo TB305FU, 800×1340 px at
  /// devicePixelRatio 1.125 (711×1191 dp), system font scale 1.08.
  void lenovo(WidgetTester tester, {required bool portrait}) {
    tester.view.physicalSize =
        portrait ? const Size(800, 1340) : const Size(1340, 800);
    tester.view.devicePixelRatio = 1.125;
    tester.platformDispatcher.textScaleFactorTestValue = 1.08;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  Future<VoiceController> mount(WidgetTester tester,
      {bool furnished = true,
      OrbState posed = OrbState.idle,
      String event = 'Dinner with Mom'}) async {
    final vc = _WallStage(connection: conn, posed: posed);
    addTearDown(vc.dispose);
    if (furnished) {
      _furnish(vc, locked: posed == OrbState.ambient, event: event);
    }
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
    // Three of Henry's lines at the wall's size (line-height 1.5). The orb is
    // already at its floor here; the wall's larger chrome is what is left.
    expect(tester.getSize(find.byType(Thread)).height,
        greaterThan(3 * WallType.wall.body(14.88) * 1.5));
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

  group('the wall type floor', () {
    // The DECLARED sizes; the platform's font scale multiplies on top of them.
    TextStyle styleOf(WidgetTester tester, String text) =>
        tester.widget<Text>(find.text(text).first).style!;
    double sizeOf(WidgetTester tester, String text) =>
        styleOf(tester, text).fontSize!;
    double alphaOf(WidgetTester tester, String text) =>
        styleOf(tester, text).color!.a;
    double navIcon(WidgetTester tester) => tester
        .widget<HeroIconView>(find
            .descendant(
                of: find.byType(MeridianNav),
                matching: find.byType(HeroIconView))
            .first)
        .size;
    double footShade(WidgetTester tester) =>
        tester.widget<MeridianSurface>(find.byType(MeridianSurface)).footShade;
    const youSaid = 'Should I bring an umbrella tonight?';
    const henrySaid = 'Not tonight — the rain holds off until tomorrow '
        'afternoon. Dinner with Mom at 7:30 should stay dry.';

    testWidgets("a phone (360x800) keeps the CSS port's sizes, untouched",
        (tester) async {
      screen(tester, const Size(360, 800), dpr: 3);
      await mount(tester);

      expect(sizeOf(tester, 'CONNECTORS'), 6.4);
      expect(alphaOf(tester, 'CONNECTORS'), closeTo(0.3, 1e-6));
      expect(navIcon(tester), 18);
      expect(sizeOf(tester, 'P.A.I V0.9.0'), 8.32);
      expect(alphaOf(tester, 'DAVID'), closeTo(0.34, 1e-6));
      expect(sizeOf(tester, 'HOLD TO TALK'), 8.32);
      expect(alphaOf(tester, 'HOLD TO TALK'), closeTo(0.2, 1e-6),
          reason: 'disabled: PTT mode is off');
      expect(sizeOf(tester, 'PTT'), 7.36);
      expect(sizeOf(tester, 'PASTA'), 8.32);
      expect(footShade(tester), MeridianSurface.defaultFootShade);
      expect(sizeOf(tester, 'henry'), 8.64);
      expect(sizeOf(tester, henrySaid), 14.88);
      // A phone's thread shows only the newest line; bring your question in.
      await tester.drag(find.byType(Thread), const Offset(0, 160));
      await tester.pump();
      expect(sizeOf(tester, 'you'), 8.64);
      expect(sizeOf(tester, youSaid), 13.44);
      expect(tester.takeException(), isNull);
    });

    for (final portrait in [true, false]) {
      final name = portrait
          ? 'the Lenovo in portrait (711x1191, medium)'
          : 'the Lenovo in landscape (1191x711, expanded)';
      testWidgets('$name reads from across the room', (tester) async {
        lenovo(tester, portrait: portrait);
        await mount(tester);
        expect(find.byKey(wallOrbPaneKey),
            portrait ? findsNothing : findsOneWidget);

        // The nav: 6.4 -> the floor; its icons 18 -> 23.4.
        expect(sizeOf(tester, 'CONNECTORS'), 11);
        expect(alphaOf(tester, 'CONNECTORS'), closeTo(0.6, 1e-6));
        expect(navIcon(tester), closeTo(23.4, 1e-6));
        // CONNECTORS still fits its station on one line, unscaled.
        final connectors = find.text('CONNECTORS');
        expect(tester.getRect(connectors).width,
            moreOrLessEquals(tester.getSize(connectors).width),
            reason: 'FittedBox shrinking one label reads as a bug');
        // The header's meta.
        expect(sizeOf(tester, 'P.A.I V0.9.0'), 11);
        expect(alphaOf(tester, 'DAVID'), closeTo(0.68, 1e-6));
        // Hold to talk, still visibly disabled next to its enabled 0.76.
        expect(sizeOf(tester, 'HOLD TO TALK'), 11);
        expect(alphaOf(tester, 'HOLD TO TALK'), closeTo(0.4, 1e-6));
        // The detents' engraving.
        expect(sizeOf(tester, 'PTT'), 11);
        expect(alphaOf(tester, 'PTT'), closeTo(0.72, 1e-6));
        // The rail labels, and the conversation itself (x1.2).
        expect(sizeOf(tester, 'henry'), closeTo(11.232, 1e-6));
        expect(sizeOf(tester, 'you'), closeTo(11.232, 1e-6));
        expect(sizeOf(tester, youSaid), closeTo(16.128, 1e-6));
        expect(sizeOf(tester, henrySaid), closeTo(17.856, 1e-6));
        // A kitchen timer's name.
        expect(sizeOf(tester, 'PASTA'), 11);
        // And the glass's foot no longer swallows the nav it just raised.
        expect(footShade(tester), 0.35);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('the floor follows the width across a rotation',
        (tester) async {
      screen(tester, const Size(360, 800));
      await mount(tester);
      expect(sizeOf(tester, 'CONNECTORS'), 6.4);

      tester.view.physicalSize = const Size(800, 1280);
      await tester.pump();
      expect(sizeOf(tester, 'CONNECTORS'), 11);

      tester.view.physicalSize = const Size(599, 800);
      await tester.pump();
      expect(sizeOf(tester, 'CONNECTORS'), 6.4,
          reason: 'back under the medium line: the phone again');
    });

    test('a phone is the identity; a wall never dims what is bright', () {
      for (final v in [0.0, 6.4, 8.32, 14.88]) {
        expect(WallType.hand.chrome(v), v);
        expect(WallType.hand.body(v), v);
      }
      for (final a in [0.0, 0.2, 0.34, 0.9, 1.0]) {
        expect(WallType.hand.ink(a), a);
        expect(WallType.wall.ink(a), greaterThanOrEqualTo(a));
      }
      expect(WallType.wall.ink(0.9), 0.9, reason: 'above the ceiling: kept');
      expect(WallType.forLayout(WallLayout.compact), WallType.hand);
      expect(WallType.forLayout(WallLayout.medium), WallType.wall);
      expect(WallType.forLayout(WallLayout.expanded), WallType.wall);
    });
  });

  group('goldens', () {
    // The real orb shader, loaded up front so the first frame already has it.
    setUp(() async => OrbShaderProgram.load());

    /// Mount on whatever screen the test has set, and shoot.
    Future<void> capture(WidgetTester tester, String name,
        {OrbState posed = OrbState.idle,
        String event = 'Dinner with Mom'}) async {
      await mount(tester, posed: posed, event: event);
      // The orb and the surface both animate; a fixed stretch of the fake
      // clock lands them on the same frame every run.
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await expectLater(
          find.byType(MeridianVoiceScreen), matchesGoldenFile(name));
    }

    Future<void> shoot(WidgetTester tester, Size size, String name,
        {OrbState posed = OrbState.idle}) async {
      screen(tester, size);
      await capture(tester, name, posed: posed);
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

    // The Lenovo itself, at the size and font scale it reports. Portrait is
    // awake with a next event too long for one line, so the face's second
    // line is on record; landscape is the wall at rest.
    testWidgets('the Lenovo in portrait (711x1191): awake', (tester) async {
      lenovo(tester, portrait: true);
      await capture(tester, 'goldens/voice_wall_lenovo_portrait.png',
          event: 'Dinner with Mom and Dad at Trattoria Marcella');
    });

    testWidgets('the Lenovo in landscape (1191x711): at rest', (tester) async {
      lenovo(tester, portrait: false);
      await capture(tester, 'goldens/voice_wall_lenovo_landscape.png',
          posed: OrbState.ambient);
    });
  });
}
