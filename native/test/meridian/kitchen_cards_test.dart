import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/meridian/cards/card_view.dart';
import 'package:orbital_pai/meridian/cards/cook_step_card.dart';
import 'package:orbital_pai/meridian/cards/recipe_card.dart';
import 'package:orbital_pai/meridian/cards/tracker_card.dart';
import 'package:orbital_pai/meridian/thread_model.dart';
import 'package:orbital_pai/meridian/tokens.dart';

import 'card_fixtures.dart';

void main() {
  Widget host(Widget child, {double width = 220}) => MaterialApp(
        home: Scaffold(
          backgroundColor: M.bg,
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, child: child),
          ),
        ),
      );

  Widget view(String type, Map<String, dynamic> data, {double width = 220}) =>
      host(ThreadCardView(card: ThreadCard(type: type, data: data)), width: width);

  Finder rich(String text) => find.textContaining(text, findRichText: true);

  group('tracker', () {
    testWidgets('renders the server strings verbatim', (tester) async {
      await tester.pumpWidget(view('tracker', trackerCard));
      expect(find.byType(TrackerCard), findsOneWidget);
      expect(find.text('HEADACHE'), findsOneWidget);
      expect(find.text('Last 30 days'), findsOneWidget);
      for (final label in ['ENTRIES', 'AVG', 'RANGE']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('10'), findsOneWidget);
      expect(find.text('5.3'), findsOneWidget);
      expect(find.text('3–8'), findsOneWidget);
      // the strip's axis is the series' first and last day
      expect(find.text('Sep 11'), findsOneWidget);
      expect(find.text('Oct 10'), findsOneWidget);
      expect(rich('skipped lunch'), findsWidgets);
      expect(rich('×3'), findsOneWidget);
      expect(find.text('behind the eyes'), findsOneWidget);
      expect(find.text('Yesterday, 3:45 PM'), findsOneWidget);
      expect(find.text('7'), findsOneWidget);
    });

    testWidgets('the strip gets one point per server day, the peak as sent', (tester) async {
      await tester.pumpWidget(view('tracker', trackerCard));
      final painter = tester
          .widgetList<CustomPaint>(find.descendant(
              of: find.byType(TrackerStrip), matching: find.byType(CustomPaint)))
          .map((p) => p.painter)
          .whereType<TrackerStripPainter>()
          .single;
      expect(painter.points, hasLength(30));
      expect(painter.points.where((p) => p.peak != null).single.peak, '8');
      expect(painter.points.where((p) => !p.logged), hasLength(21));
    });

    testWidgets('a habit (no values) still draws its days and ticks its entries',
        (tester) async {
      await tester.pumpWidget(view('tracker', trackerHabitCard));
      expect(find.text('BEST STREAK'), findsOneWidget);
      expect(find.text('8 days'), findsOneWidget);
      expect(find.text('Yesterday, 9:30 PM'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a logged entry shows what was saved', (tester) async {
      await tester.pumpWidget(view('tracker_logged', trackerLoggedCard));
      expect(find.byType(TrackerLoggedCard), findsOneWidget);
      expect(find.text('LOGGED'), findsOneWidget);
      expect(find.text('Today, 1:40 PM'), findsOneWidget);
      expect(find.text('Headache'), findsOneWidget);
      expect(find.text('6'), findsOneWidget);
      expect(find.text('behind the eyes, came on at work'), findsOneWidget);
      expect(find.text('skipped lunch'), findsOneWidget);
      expect(find.text('coffee'), findsOneWidget);
      expect(find.text('12th entry'), findsOneWidget);
    });

    test('a strip point reads leniently', () {
      expect(StripPoint.from(const {'label': 'Oct 1'}).logged, isFalse);
      expect(StripPoint.from(const {'value': 'six', 'count': 'x'}).logged, isFalse);
      final p = StripPoint.from(const {'value': 6, 'peak': '6'});
      expect(p.value, 6.0);
      expect(p.count, 1);
      expect(p.peak, '6');
    });
  });

  group('recipe', () {
    testWidgets('renders the server strings verbatim', (tester) async {
      await tester.pumpWidget(view('recipe', recipeCard));
      expect(find.byType(RecipeCard), findsOneWidget);
      expect(find.text("GRANDMA'S LASAGNA"), findsOneWidget);
      expect(find.text('Serves 8 · from Grandma'), findsOneWidget);
      expect(find.text('11 INGREDIENTS'), findsOneWidget);
      expect(find.text('7 STEPS'), findsOneWidget);
      expect(rich('1 lb ground beef'), findsOneWidget);
      expect(rich('1 (24 oz) jar marinara'), findsOneWidget);
      expect(rich('Fresh basil'), findsOneWidget);
      expect(rich('Preheat the oven to 375°F.'), findsOneWidget);
      expect(find.textContaining('Freezes well'), findsOneWidget);
      // a lookup has no status, and the household book says nothing about scope
      expect(find.text('Saved'), findsNothing);
    });

    testWidgets('a write says what it did in the header', (tester) async {
      await tester.pumpWidget(view('recipe', recipeSavedCard));
      expect(find.text('Saved'), findsOneWidget);
    });

    testWidgets('short neighbours share a row; a long one takes its own', (tester) async {
      await tester.pumpWidget(host(
        const IngredientGrid(colour: M.recipe, ingredients: [
          {'qty': '2', 'item': 'eggs'},
          {'qty': '½ tsp', 'item': 'salt'},
          {'qty': '3 cups', 'item': 'shredded low-moisture mozzarella'},
          {'item': 'basil'},
        ]),
        width: 260,
      ));
      double top(String t) => tester.getTopLeft(rich(t)).dy;
      expect(top('eggs'), top('salt'));
      expect(top('mozzarella'), greaterThan(top('salt')));
      expect(top('basil'), greaterThan(top('mozzarella')));
    });

    testWidgets('a long run of steps trails off rather than growing the card', (tester) async {
      final long = {
        ...recipeCard,
        'steps': [
          for (var n = 1; n <= 8; n++)
            {'number': '$n', 'text': 'Do a fairly long thing number $n with care and patience.'},
        ],
        'more_steps': '+3 more',
      };
      await tester.pumpWidget(view('recipe', long, width: 184));
      expect(find.text('+3 more'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(RecipeCard)).height, lessThanOrEqualTo(330));
    });
  });

  group('cook step', () {
    testWidgets('renders the server strings verbatim', (tester) async {
      await tester.pumpWidget(view('cook_step', cookStepCard));
      expect(find.byType(CookStepCard), findsOneWidget);
      expect(find.text("GRANDMA'S LASAGNA"), findsOneWidget);
      expect(find.text('STEP 6 OF 7'), findsOneWidget);
      expect(find.text(cookStepCard['text'] as String), findsOneWidget);
      expect(find.text('25 minutes'), findsOneWidget);
      expect(find.text('20 more minutes'), findsOneWidget);
      expect(find.byType(TimerPill), findsNWidgets(2));
      expect(find.text('NEXT'), findsOneWidget);
      expect(find.text('Let it rest 15 minutes…'), findsOneWidget);
      expect(find.byType(StepProgress), findsOneWidget);
    });

    testWidgets('the last step says so and shows no next', (tester) async {
      final last = {...cookStepCard, 'next_label': 'Last step', 'step': 7}..remove('next');
      await tester.pumpWidget(view('cook_step', last));
      expect(find.text('LAST STEP'), findsOneWidget);
      expect(find.text('Let it rest 15 minutes…'), findsNothing);
    });

    testWidgets('short text is set large, long text smaller, and never overflows',
        (tester) async {
      double size(String text) => tester
          .widget<Text>(find.text(text))
          .style!
          .fontSize!;

      await tester.pumpWidget(view('cook_step', cookFirstStepCard));
      final short = size('Preheat the oven to 375°F.');

      await tester.pumpWidget(view('cook_step', cookStepCard));
      final longer = size(cookStepCard['text'] as String);
      expect(short, greaterThan(longer));

      final essay = 'Whisk the eggs, then fold in the flour a spoonful at a time. ' * 8;
      await tester.pumpWidget(
          view('cook_step', {...cookStepCard, 'text': essay}, width: 184));
      expect(tester.takeException(), isNull);
      expect(size(essay), 15);
      expect(tester.getSize(find.byType(CookStepCard)).height, lessThanOrEqualTo(340));
    });
  });

  testWidgets('malformed maps render what they can and never throw', (tester) async {
    for (final (type, data) in [
      ('tracker', const {'type': 'tracker', 'series': 'x', 'stats': null, 'recent': [1]}),
      ('tracker', const {
        'type': 'tracker',
        'series': [
          {'label': 'Oct 1', 'value': 'high'},
          7,
        ],
      }),
      ('tracker_logged', const {'type': 'tracker_logged', 'tags': 'x'}),
      ('recipe', const {'type': 'recipe', 'ingredients': [null, 3], 'steps': 'all of them'}),
      ('cook_step', const {'type': 'cook_step', 'step': 'six', 'timers': [1, null]}),
      ('cook_step', const {'type': 'cook_step', 'step': 9, 'step_count': 0}),
    ]) {
      await tester.pumpWidget(view(type, data));
      expect(tester.takeException(), isNull, reason: '$type $data');
    }
  });
}
