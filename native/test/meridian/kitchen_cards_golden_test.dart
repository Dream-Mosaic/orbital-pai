import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/meridian/cards/cook_step_card.dart';
import 'package:orbital_pai/meridian/cards/recipe_card.dart';
import 'package:orbital_pai/meridian/cards/tracker_card.dart';
import 'package:orbital_pai/meridian/thread.dart';
import 'package:orbital_pai/meridian/thread_model.dart';
import 'package:orbital_pai/meridian/tokens.dart';

import 'card_fixtures.dart';

/// The tracker and recipe cards, in context: the real [Thread] between the
/// turn's other lines, on a 360px phone and — for the cards that live on the
/// kitchen tablet — at the voice screen's widest column (its 416px max width),
/// where Henry's column is as wide as it gets.
///
/// Regenerate deliberately, then LOOK at the PNGs:
///   flutter test --update-goldens test/meridian/kitchen_cards_golden_test.dart
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final display = FontLoader(kDisplayFamily)
      ..addFont(rootBundle.load('assets/fonts/SpaceGrotesk.ttf'));
    final body = FontLoader(kBodyFamily)..addFont(rootBundle.load('assets/fonts/Inter.ttf'));
    await Future.wait([display.load(), body.load()]);
  });

  const phone = 360.0;
  const tablet = M.maxWidth;
  const key = ValueKey('card-golden');

  Widget host(String ask, String tool, ThreadCard card, String answer,
          {double width = phone, double height = 620}) =>
      MaterialApp(
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
                padding: const EdgeInsets.symmetric(horizontal: M.pagePad),
                child: SizedBox(
                  width: width - 2 * M.pagePad,
                  child: Thread(
                    glow: M.henry,
                    items: [
                      ThreadLine(kind: LineKind.you, label: 'you', text: ask),
                      const ThreadLine(
                          kind: LineKind.reflex, label: 'Henry', text: 'One sec.'),
                      ThreadToolChip(name: tool, resolved: true),
                      card,
                      ThreadLine(
                          kind: LineKind.brain, label: 'Henry', text: answer, markdown: true),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  Future<void> golden(WidgetTester tester, String name, Type cardType, Widget app,
      {double width = phone, double maxHeight = 320}) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app);
    await tester.pump();

    await expectLater(find.byKey(key), matchesGoldenFile('goldens/card_$name.png'));
    final card = tester.getSize(find.byType(cardType));
    expect(card.height, lessThanOrEqualTo(maxHeight),
        reason: '$name is ${card.height}px tall at ${width}px');
    expect(tester.takeException(), isNull);
  }

  testWidgets('tracker', (tester) async {
    await golden(
      tester,
      'tracker',
      TrackerCard,
      host('how have my headaches been this month?', 'get_tracker_entries',
          const ThreadCard(type: 'tracker', data: trackerCard),
          'Ten this month, mostly mild — skipped lunch shows up in three of them.'),
    );
  });

  testWidgets('tracker for a habit with no values', (tester) async {
    await golden(
      tester,
      'tracker_habit',
      TrackerCard,
      host('how am I doing on no soda?', 'get_tracker_entries',
          const ThreadCard(type: 'tracker', data: trackerHabitCard),
          'Twenty-three days, and an eight-day run going into October.'),
    );
  });

  testWidgets('tracker entry logged', (tester) async {
    await golden(
      tester,
      'tracker_logged',
      TrackerLoggedCard,
      host("I've got a headache, maybe a 6 — I skipped lunch and had coffee",
          'log_tracker_entry', const ThreadCard(type: 'tracker_logged', data: trackerLoggedCard),
          'Logged — headache, 6.'),
    );
  });

  testWidgets('recipe', (tester) async {
    await golden(
      tester,
      'recipe',
      RecipeCard,
      host('what do I need for the lasagna?', 'get_recipe',
          const ThreadCard(type: 'recipe', data: recipeCard),
          'Eleven things — the beef, sausage and three cheeses are the big ones.',
          height: 700),
    );
  });

  testWidgets('recipe just saved, on the kitchen tablet', (tester) async {
    await golden(
      tester,
      'recipe_saved_tablet',
      RecipeCard,
      host('yes, save it', 'save_recipe',
          const ThreadCard(type: 'recipe', data: recipeSavedCard),
          "Saved — Grandma's lasagna is in the recipe book.",
          width: tablet, height: 640),
      width: tablet,
    );
  });

  testWidgets('cook step', (tester) async {
    await golden(
      tester,
      'cook_step',
      CookStepCard,
      host('next', 'get_recipe', const ThreadCard(type: 'cook_step', data: cookStepCard),
          'Step 6 — cover with foil and bake 25 minutes, then uncover for 20 more. Want a timer?',
          height: 660),
      maxHeight: 340,
    );
  });

  testWidgets('cook step on the kitchen tablet', (tester) async {
    await golden(
      tester,
      'cook_step_tablet',
      CookStepCard,
      host('next', 'get_recipe', const ThreadCard(type: 'cook_step', data: cookStepCard),
          'Step 6 — cover with foil and bake 25 minutes, then uncover for 20 more. Want a timer?',
          width: tablet, height: 660),
      width: tablet,
      maxHeight: 340,
    );
  });

  testWidgets('cook mode, first step: short text set large', (tester) async {
    await golden(
      tester,
      'cook_step_first',
      CookStepCard,
      host("let's make the lasagna", 'get_recipe',
          const ThreadCard(type: 'cook_step', data: cookFirstStepCard),
          'Step 1 — preheat the oven to 375.',
          width: tablet),
      width: tablet,
      maxHeight: 340,
    );
  });
}
