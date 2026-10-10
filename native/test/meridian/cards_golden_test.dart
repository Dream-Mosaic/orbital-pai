import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/meridian/cards/agenda_card.dart';
import 'package:orbital_pai/meridian/cards/email_card.dart';
import 'package:orbital_pai/meridian/cards/list_card.dart';
import 'package:orbital_pai/meridian/cards/reminders_card.dart';
import 'package:orbital_pai/meridian/cards/weather_card.dart';
import 'package:orbital_pai/meridian/cards/weather_glyph.dart';
import 'package:orbital_pai/meridian/thread.dart';
import 'package:orbital_pai/meridian/thread_model.dart';
import 'package:orbital_pai/meridian/tokens.dart';

import 'card_fixtures.dart';

/// Each card, in context, on a 360px phone: the real [Thread] at the width the
/// voice screen gives it (360 minus the 16px page padding each side), between
/// the turn's other lines, so the golden shows the card sitting in Henry's
/// column under his name — not floating in a test box.
///
/// Regenerate deliberately, then LOOK at the PNGs:
///   flutter test --update-goldens test/meridian/cards_golden_test.dart
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final display = FontLoader(kDisplayFamily)
      ..addFont(rootBundle.load('assets/fonts/SpaceGrotesk.ttf'));
    final body = FontLoader(kBodyFamily)..addFont(rootBundle.load('assets/fonts/Inter.ttf'));
    await Future.wait([display.load(), body.load()]);
  });

  const phone = 360.0;
  const threadWidth = phone - 2 * M.pagePad;

  Widget host(Key key, String ask, String tool, ThreadCard card, String answer,
          {double height = 560}) =>
      MaterialApp(
        debugShowCheckedModeBanner: false,
        // The tool chip sets no family and takes the platform default on a
        // device; Inter stands in for it here so the chip renders as words
        // rather than the test font's boxes.
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
                width: phone,
                height: height,
                color: M.bg,
                padding: const EdgeInsets.symmetric(horizontal: M.pagePad),
                child: SizedBox(
                  width: threadWidth,
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

  Future<void> golden(WidgetTester tester, String name, Type cardType, Widget app) async {
    tester.view.physicalSize = const Size(phone, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const key = ValueKey('card-golden');
    await tester.pumpWidget(app);
    await tester.pump();

    await expectLater(find.byKey(key), matchesGoldenFile('goldens/card_$name.png'));
    final card = tester.getSize(find.byType(cardType));
    expect(card.height, lessThanOrEqualTo(280),
        reason: '$name is ${card.height}px tall on a 360px phone');
  }

  testWidgets('every weather glyph, at headline and strip size', (tester) async {
    tester.view.physicalSize = const Size(phone, 150);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const key = ValueKey('glyph-golden');
    const keys = [
      'clear', 'clear_night', 'partly', 'partly_night', 'cloudy',
      'rain', 'storm', 'snow', 'fog', 'wind',
    ];
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Align(
        alignment: Alignment.topLeft,
        child: RepaintBoundary(
          key: key,
          child: Container(
            width: phone,
            height: 150,
            color: const Color(0xFF0B0D16),
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [for (final k in keys) WeatherGlyph(k, size: 48)],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [for (final k in keys) WeatherGlyph(k, size: 17)],
                ),
              ],
            ),
          ),
        ),
      ),
    ));
    await expectLater(find.byKey(key), matchesGoldenFile('goldens/card_weather_glyphs.png'));
  });

  testWidgets('weather', (tester) async {
    await golden(
      tester,
      'weather',
      WeatherCard,
      host(const ValueKey('card-golden'), "what's the weather doing?", 'get_weather',
          const ThreadCard(type: 'weather', data: weatherCard),
          "72 and partly cloudy — storms roll in around 6, so I'd bring the chairs in."),
    );
  });

  testWidgets('agenda', (tester) async {
    await golden(
      tester,
      'agenda',
      AgendaCard,
      host(const ValueKey('card-golden'), "what's on today?", 'get_calendar_events',
          const ThreadCard(type: 'agenda', data: agendaCard),
          'Four things — soccer at 5:30 is the tight one.'),
    );
  });

  testWidgets('agenda over a week', (tester) async {
    await golden(
      tester,
      'agenda_week',
      AgendaCard,
      host(const ValueKey('card-golden'), 'what does the week look like?',
          'get_calendar_events', const ThreadCard(type: 'agenda', data: agendaWeekCard),
          'A busy start, then it eases off.'),
    );
  });

  testWidgets('list', (tester) async {
    await golden(
      tester,
      'list',
      ListCard,
      host(const ValueKey('card-golden'), "what's on the grocery list?", 'read_list',
          const ThreadCard(type: 'list', data: listCard),
          'Five things left — milk, butter, sourdough and two more.'),
    );
  });

  testWidgets('reminders', (tester) async {
    await golden(
      tester,
      'reminders',
      RemindersCard,
      host(const ValueKey('card-golden'), 'what reminders do I have?', 'list_reminders',
          const ThreadCard(type: 'reminders', data: remindersCard),
          'Trash goes out tonight, and you wanted to call your mom tomorrow.'),
    );
  });

  testWidgets('email', (tester) async {
    await golden(
      tester,
      'email',
      EmailCard,
      host(const ValueKey('card-golden'), 'anything new in my email?', 'search_email',
          const ThreadCard(type: 'email', data: emailCard),
          'Alice is asking about lunch Tuesday; the rest can wait.'),
    );
  });
}
