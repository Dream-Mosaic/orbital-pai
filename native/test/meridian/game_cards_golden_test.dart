import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/meridian/cards/coin_card.dart';
import 'package:orbital_pai/meridian/cards/dice_card.dart';
import 'package:orbital_pai/meridian/cards/pick_card.dart';
import 'package:orbital_pai/meridian/cards/scoreboard_card.dart';
import 'package:orbital_pai/meridian/thread.dart';
import 'package:orbital_pai/meridian/thread_model.dart';
import 'package:orbital_pai/meridian/tokens.dart';
import 'package:orbital_pai/meridian/wall_layout.dart';
import 'package:orbital_pai/meridian/wall_type.dart';

import 'game_card_fixtures.dart';

/// Game night's cards, in context: the real [Thread] between the turn's other
/// lines, at the width the wall gives it — the Lenovo in landscape (1191dp),
/// whose thread pane is 631dp and whose cards are 378dp, the width these cards
/// are drawn for — and a few on a 360px phone, where they scale down.
///
/// Regenerate deliberately, then LOOK at the PNGs:
///   flutter test --update-goldens test/meridian/game_cards_golden_test.dart
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final display = FontLoader(kDisplayFamily)
      ..addFont(rootBundle.load('assets/fonts/SpaceGrotesk.ttf'));
    final body = FontLoader(kBodyFamily)..addFont(rootBundle.load('assets/fonts/Inter.ttf'));
    await Future.wait([display.load(), body.load()]);
  });

  // The Lenovo landscape's thread pane: 1191 less the page pads, the orb pane
  // (42% of the rest) and the gutter (voice_screen.dart _paneWidths).
  const lenovo = 1191.0;
  const wallInner = lenovo - 2 * Wall.pagePad;
  const wallPane = wallInner - wallInner * Wall.orbPaneFraction - Wall.gutter;
  const phone = 360.0;
  const key = ValueKey('card-golden');

  Widget host(String ask, String tool, Map<String, dynamic> data, String answer,
      {required bool wall, double height = 520}) {
    final card = ThreadCard.fromWire(data)!;
    final width = wall ? wallPane : phone;
    final pad = wall ? 0.0 : M.pagePad;
    final thread = Thread(
      glow: M.henry,
      items: [
        ThreadLine(kind: LineKind.you, label: 'you', text: ask),
        ThreadToolChip(name: tool, resolved: true),
        card,
        ThreadLine(kind: LineKind.brain, label: 'Henry', text: answer, markdown: true),
      ],
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      // The tool chip sets no family and takes the platform default on a
      // device; Inter stands in for it here so the chip renders as words.
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        textTheme: ThemeData.dark().textTheme.apply(fontFamily: kBodyFamily),
      ),
      home: Scaffold(
        backgroundColor: M.bg,
        body: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            key: key,
            child: Container(
              width: width,
              height: height,
              color: M.bg,
              padding: EdgeInsets.symmetric(horizontal: pad),
              child: SizedBox(
                width: width - 2 * pad,
                child: wall ? WallTypeScope(type: WallType.wall, child: thread) : thread,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> golden(WidgetTester tester, String name, Type cardType, Widget app,
      {required bool wall, double maxHeight = 260}) async {
    final width = wall ? wallPane : phone;
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app);
    await tester.pump();

    await expectLater(find.byKey(key), matchesGoldenFile('goldens/game_$name.png'));
    final card = tester.getSize(find.byType(cardType));
    if (wall) {
      expect(card.width, closeTo(378, 1), reason: 'the width these cards are drawn for');
    }
    expect(card.height, lessThanOrEqualTo(maxHeight),
        reason: '$name is ${card.height}px tall at ${width}px');
    expect(tester.takeException(), isNull);
  }

  group('on the wall', () {
    testWidgets('two dice', (tester) async {
      await golden(tester, 'dice', DiceCard,
          host('roll two dice', 'roll_dice', diceCard, 'Eight.', wall: true),
          wall: true);
    });

    testWidgets('dice with a modifier', (tester) async {
      await golden(tester, 'dice_modifier', DiceCard,
          host('roll 3d8 plus 2', 'roll_dice', diceModifierCard, 'Sixteen.', wall: true),
          wall: true);
    });

    testWidgets('a single d20', (tester) async {
      await golden(tester, 'dice_single', DiceCard,
          host('roll a d20', 'roll_dice', diceSingleCard, 'Seventeen — nice.', wall: true),
          wall: true);
    });

    testWidgets('ten dice', (tester) async {
      await golden(tester, 'dice_many', DiceCard,
          host('roll ten dice', 'roll_dice', diceManyCard, 'Thirty-four.', wall: true),
          wall: true);
    });

    testWidgets('a coin', (tester) async {
      await golden(tester, 'coin', CoinCard,
          host('flip a coin', 'flip_coin', coinCard, 'Heads.', wall: true),
          wall: true);
    });

    testWidgets('five coins', (tester) async {
      await golden(tester, 'coins', CoinCard,
          host('flip five coins', 'flip_coin', coinsCard, 'Three heads, two tails.', wall: true),
          wall: true);
    });

    testWidgets('a pick', (tester) async {
      await golden(
          tester,
          'pick',
          PickCard,
          host('pick who goes first: Sam, Ana or Joe', 'pick_one', pickCard, 'Ana goes first.',
              wall: true),
          wall: true);
    });

    testWidgets('two picks', (tester) async {
      await golden(
          tester,
          'pick_two',
          PickCard,
          host('pick two places for dinner', 'pick_one', pickTwoCard, 'Thai and pizza.',
              wall: true),
          wall: true);
    });

    testWidgets('a turn order', (tester) async {
      await golden(
          tester,
          'turn_order',
          PickCard,
          host('shuffle the turn order', 'pick_one', turnOrderCard, 'Joe, then Sam, Kim and Ana.',
              wall: true),
          wall: true);
    });

    testWidgets('the scoreboard', (tester) async {
      await golden(
          tester,
          'scoreboard',
          ScoreboardCard,
          host(
              'give Ana three points', 'keep_score', scoreboardCard, 'Ana pulls ahead with twelve.',
              wall: true),
          wall: true);
    });
  });

  group('on a phone', () {
    testWidgets('ten dice', (tester) async {
      await golden(tester, 'dice_many_phone', DiceCard,
          host('roll ten dice', 'roll_dice', diceManyCard, 'Thirty-four.', wall: false),
          wall: false, maxHeight: 300);
    });

    testWidgets('two picks', (tester) async {
      await golden(
          tester,
          'pick_two_phone',
          PickCard,
          host('pick two places for dinner', 'pick_one', pickTwoCard, 'Thai and pizza.',
              wall: false),
          wall: false);
    });

    testWidgets('the scoreboard', (tester) async {
      await golden(
          tester,
          'scoreboard_phone',
          ScoreboardCard,
          host(
              'give Ana three points', 'keep_score', scoreboardCard, 'Ana pulls ahead with twelve.',
              wall: false),
          wall: false);
    });
  });
}
