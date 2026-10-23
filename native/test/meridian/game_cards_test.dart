import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/meridian/cards/card_view.dart';
import 'package:orbital_pai/meridian/cards/coin_card.dart';
import 'package:orbital_pai/meridian/cards/dice_card.dart';
import 'package:orbital_pai/meridian/cards/game_pieces.dart';
import 'package:orbital_pai/meridian/cards/pick_card.dart';
import 'package:orbital_pai/meridian/cards/scoreboard_card.dart';
import 'package:orbital_pai/meridian/thread_model.dart';
import 'package:orbital_pai/meridian/tokens.dart';

import 'game_card_fixtures.dart';

void main() {
  /// A card at the wall's card width (378) unless told otherwise.
  Widget view(Map<String, dynamic> data, {double width = 378}) => MaterialApp(
        home: Scaffold(
          backgroundColor: M.bg,
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: ThreadCardView(card: ThreadCard.fromWire(data)!),
            ),
          ),
        ),
      );

  Color? colourOf(WidgetTester tester, String text) =>
      tester.widget<Text>(find.text(text)).style?.color;

  group('the router', () {
    test('knows the four game types', () {
      for (final data in [diceCard, coinCard, pickCard, scoreboardCard]) {
        expect(ThreadCard.fromWire(data), isNotNull, reason: '${data['type']}');
      }
    });

    testWidgets('lays each out with its own card', (tester) async {
      for (final (data, type) in [
        (diceCard, DiceCard),
        (coinCard, CoinCard),
        (turnOrderCard, PickCard),
        (scoreboardCard, ScoreboardCard),
      ]) {
        await tester.pumpWidget(view(data));
        expect(find.byType(type), findsOneWidget, reason: '$type');
      }
    });

    test('the tool chips read as game night', () {
      expect(const ThreadToolChip(name: 'roll_dice').text, '⚙ rolling the dice…');
      expect(const ThreadToolChip(name: 'flip_coin').text, '⚙ flipping a coin…');
      expect(const ThreadToolChip(name: 'pick_one').text, '⚙ picking…');
      expect(const ThreadToolChip(name: 'keep_score').text, '⚙ keeping score…');
    });
  });

  group('dice', () {
    testWidgets('a die per roll, pips on a d6, and the total', (tester) async {
      await tester.pumpWidget(view(diceCard));
      final faces = tester.widgetList<DieFace>(find.byType(DieFace)).toList();
      expect(faces.map((f) => f.value), [3, 5]);
      expect(faces.every((f) => f.pips), isTrue);
      expect(find.text('ROLLED 2D6'), findsOneWidget);
      expect(find.textContaining('8', findRichText: true), findsWidgets);
      expect(find.byKey(const ValueKey('dice-total')), findsOneWidget);
      expect(find.text('3 + 5'), findsOneWidget);
    });

    testWidgets('a modifier is its own tile, and other dice show numbers', (tester) async {
      await tester.pumpWidget(view(diceModifierCard));
      final faces = tester.widgetList<DieFace>(find.byType(DieFace)).toList();
      expect(faces.map((f) => f.value), [7, 2, 5]);
      expect(faces.any((f) => f.pips), isFalse);
      expect(find.text('+2'), findsOneWidget);
      expect(find.text('7 + 2 + 5 + 2'), findsOneWidget);
    });

    testWidgets('a lone die is the answer: larger, with no total', (tester) async {
      await tester.pumpWidget(view(diceSingleCard));
      final face = tester.widget<DieFace>(find.byType(DieFace));
      expect(face.value, 17);
      expect(face.size, greaterThan(90));
      expect(find.byKey(const ValueKey('dice-total')), findsNothing);
    });

    testWidgets('ten dice wrap into two rows of five, on the wall and on a phone', (tester) async {
      for (final width in [378.0, 184.0]) {
        await tester.pumpWidget(view(diceManyCard, width: width));
        final tops = {
          for (var i = 0; i < 10; i++) tester.getTopLeft(find.byType(DieFace).at(i)).dy.round(),
        };
        expect(tops, hasLength(2), reason: 'at $width');
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('a die face shrinks to fit, never grows past the wall size', (tester) async {
      await tester.pumpWidget(view(diceCard, width: 184));
      final small = tester.widget<DieFace>(find.byType(DieFace).first).size;
      await tester.pumpWidget(view(diceCard, width: 460));
      final wide = tester.widget<DieFace>(find.byType(DieFace).first).size;
      expect(small, lessThan(wide));
      expect(wide, lessThanOrEqualTo(72));
    });
  });

  group('coin', () {
    testWidgets('one flip: a big coin and the word', (tester) async {
      await tester.pumpWidget(view(coinCard));
      final coin = tester.widget<CoinDisc>(find.byType(CoinDisc));
      expect(coin.heads, isTrue);
      expect(coin.mark, 'H');
      expect(coin.size, greaterThan(90));
      expect(find.text('Heads'), findsOneWidget);
      expect(find.text('COIN FLIP'), findsOneWidget);
    });

    testWidgets('several flips: a coin each, in order, and the tally', (tester) async {
      await tester.pumpWidget(view(coinsCard));
      final coins = tester.widgetList<CoinDisc>(find.byType(CoinDisc)).toList();
      expect(coins.map((c) => c.mark), ['T', 'H', 'H', 'T', 'H']);
      expect(coins.map((c) => c.heads), [false, true, true, false, true]);
      expect(find.text('3 heads · 2 tails'), findsOneWidget);
    });
  });

  group('pick', () {
    testWidgets('the pick large, and lit among the options', (tester) async {
      await tester.pumpWidget(view(pickCard));
      expect(find.text('PICKED'), findsOneWidget);
      expect(find.text('1 of 3'), findsOneWidget);
      // the headline, and its chip
      expect(find.text('Ana'), findsNWidgets(2));
      for (final name in ['Sam', 'Joe']) {
        expect(colourOf(tester, name), isNot(M.game), reason: name);
      }
      final chip = tester.widgetList<Text>(find.text('Ana')).last;
      expect(chip.style?.color, M.game);
    });

    testWidgets('a shuffle is numbered rows, first on a lit band', (tester) async {
      await tester.pumpWidget(view(turnOrderCard));
      expect(find.text('TURN ORDER'), findsOneWidget);
      for (final (rank, name) in [('1', 'Joe'), ('2', 'Sam'), ('3', 'Kim'), ('4', 'Ana')]) {
        expect(find.text(rank), findsOneWidget);
        expect(
          tester.getTopLeft(find.text(rank)).dy,
          lessThan(tester.getBottomLeft(find.text(name)).dy),
          reason: '$rank sits on $name\'s row',
        );
      }
      expect(
          tester.getTopLeft(find.text('Joe')).dy, lessThan(tester.getTopLeft(find.text('Ana')).dy));
    });

    testWidgets('a long turn order splits into two columns', (tester) async {
      final order = [
        for (var i = 1; i <= 8; i++) {'rank': '$i', 'label': 'P$i'},
      ];
      await tester.pumpWidget(view({'type': 'pick', 'title': 'Turn order', 'order': order}));
      final x1 = tester.getTopLeft(find.text('P1')).dx;
      final x5 = tester.getTopLeft(find.text('P5')).dx;
      expect(x5, greaterThan(x1 + 100), reason: 'the second half is its own column');
      expect(
          tester.getTopLeft(find.text('P5')).dy, closeTo(tester.getTopLeft(find.text('P1')).dy, 1));
    });
  });

  group('scoreboard', () {
    testWidgets('rank · name · points, leader lit, the change beside its player', (tester) async {
      await tester.pumpWidget(view(scoreboardCard));
      expect(find.text('SCOREBOARD'), findsOneWidget);
      expect(find.text('4 players'), findsOneWidget);
      expect(colourOf(tester, '12'), M.game);
      expect(colourOf(tester, '−2'), M.ink);
      expect(find.text('9'), findsNWidgets(2));
      expect(find.text('+3'), findsOneWidget);
      // the delta rides on Ana's row
      expect(
          tester.getCenter(find.text('+3')).dy, closeTo(tester.getCenter(find.text('Ana')).dy, 3));
      // leader first
      expect(
          tester.getTopLeft(find.text('Ana')).dy, lessThan(tester.getTopLeft(find.text('Kim')).dy));
    });

    testWidgets('shows the server\'s "+N more"', (tester) async {
      await tester.pumpWidget(view({
        ...scoreboardCard,
        'more': '+3 more',
      }));
      expect(find.text('+3 more'), findsOneWidget);
    });
  });

  testWidgets('a malformed game card renders as absent, never as a crash', (tester) async {
    for (final type in ['dice', 'coin', 'pick', 'scoreboard']) {
      await tester.pumpWidget(view({
        'type': type,
        'dice': ['x', null],
        'flips': 'heads',
        'options': [1, 2],
        'rows': [
          {'rank': 1, 'points': null},
        ],
      }));
      expect(tester.takeException(), isNull, reason: type);
    }
  });

  group('tileSize', () {
    test('one row while the tiles stay big enough', () {
      expect(tileSize(300, 3, max: 200, min: 36, gap: 10), 93);
    });

    test('wraps to as few rows as keep them at the minimum', () {
      // 10 tiles in 160: five a row at 28 each
      expect(tileSize(160, 10, max: 72, min: 21.6, gap: 4.8), 28);
    });

    test('never past the maximum', () {
      expect(tileSize(1000, 2, max: 72, min: 36), 72);
    });
  });

  test('gameScale draws at the wall width and only scales down', () {
    expect(gameScale(kGameCardInner), 1.0);
    expect(gameScale(800), 1.0);
    expect(gameScale(kGameCardInner / 2), closeTo(0.6, 0.0001));
    expect(gameScale(0), 0.6);
  });
}
