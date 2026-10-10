import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/meridian/cards/card_view.dart';
import 'package:orbital_pai/meridian/cards/weather_glyph.dart';
import 'package:orbital_pai/meridian/thread.dart';
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

  Widget view(String type, Map<String, dynamic> data) =>
      host(ThreadCardView(card: ThreadCard(type: type, data: data)));

  testWidgets('weather renders the server strings verbatim', (tester) async {
    await tester.pumpWidget(view('weather', weatherCard));
    expect(find.text('BELLEVILLE, IL'), findsOneWidget);
    expect(find.text('72°'), findsWidgets);
    expect(find.text('Partly cloudy'), findsOneWidget);
    expect(find.text('FEELS LIKE'), findsOneWidget);
    expect(find.text('8 mph S'), findsOneWidget);
    for (final label in ['2PM', '3PM', '4PM', '5PM', '6PM', '7PM', 'Sun', 'Thu']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('80%'), findsOneWidget);
    // one glyph for the headline, six hours, five days
    expect(find.byType(WeatherGlyph), findsNWidgets(12));
  });

  testWidgets('agenda groups a range under the server day labels', (tester) async {
    await tester.pumpWidget(view('agenda', agendaWeekCard));
    expect(find.text('THIS WEEK'), findsOneWidget);
    expect(find.text('TODAY'), findsOneWidget);
    expect(find.text('MON, OCT 12'), findsOneWidget);
    expect(find.text('Brunch at Mom\'s'), findsOneWidget);
    expect(find.text('+2 more'), findsOneWidget);
  });

  testWidgets('agenda shows whose calendar, and an all-day row unsplit', (tester) async {
    await tester.pumpWidget(view('agenda', agendaCard));
    expect(find.text('Sat, Oct 10'), findsOneWidget);
    expect(find.text('All day'), findsOneWidget);
    expect(find.text('WORK'), findsOneWidget);
    // a clock time keeps every character the server sent, meridiem set small
    expect(find.textContaining('5:30', findRichText: true), findsOneWidget);
  });

  testWidgets('a list strikes through done items only', (tester) async {
    await tester.pumpWidget(view('list', listCard));
    TextDecoration? deco(String text) =>
        tester.widget<Text>(find.text(text)).style?.decoration;
    expect(deco('milk'), isNull);
    expect(deco('eggs'), TextDecoration.lineThrough);
    expect(find.text('GROCERIES'), findsOneWidget);
    expect(find.text('Household'), findsOneWidget);
    expect(find.text('6 left · 3 done'), findsOneWidget);
    expect(find.text('+2 more'), findsOneWidget);
  });

  testWidgets('reminders show when, cadence and tag', (tester) async {
    await tester.pumpWidget(view('reminders', remindersCard));
    expect(find.text('Take out the trash'), findsOneWidget);
    expect(find.text('Today, 7:30 PM'), findsOneWidget);
    expect(find.text('every Sat'), findsOneWidget);
    expect(find.text('HOUSEHOLD'), findsOneWidget);
    expect(find.text('FOLLOW-UP'), findsOneWidget);
  });

  testWidgets('email shows sender, subject and when', (tester) async {
    await tester.pumpWidget(view('email', emailCard));
    expect(find.text('UNREAD'), findsOneWidget);
    expect(find.text('Alice Smith'), findsOneWidget);
    expect(find.text('Lunch Tuesday?'), findsOneWidget);
    expect(find.text('1:05 PM'), findsOneWidget);
    expect(find.text('+1 more'), findsOneWidget);
  });

  testWidgets('an unknown type renders nothing rather than a guess', (tester) async {
    await tester.pumpWidget(view('hologram', const {'type': 'hologram', 'title': 'x'}));
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('a malformed map renders what it can and never throws', (tester) async {
    await tester.pumpWidget(view('weather', const {
      'type': 'weather',
      'temp': 72,
      'hourly': 'soon',
      'daily': [1, 'two', null],
      'details': [
        {'label': 'Wind'},
      ],
    }));
    expect(tester.takeException(), isNull);
    expect(find.text('WIND'), findsOneWidget);

    await tester.pumpWidget(view('list', const {'type': 'list', 'items': null}));
    expect(tester.takeException(), isNull);
  });

  testWidgets("in the thread, a card's left edge sits on Henry's text", (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        backgroundColor: M.bg,
        body: SizedBox(
          width: 328,
          height: 700,
          child: Thread(
            glow: M.henry,
            items: [
              ThreadCard(type: 'list', data: listCard),
              ThreadLine(kind: LineKind.brain, label: 'Henry', text: 'five left'),
            ],
          ),
        ),
      ),
    ));
    final cardLeft = tester.getTopLeft(find.byType(ThreadCardView)).dx;
    final textLeft = tester.getTopLeft(find.text('five left')).dx;
    expect(cardLeft, closeTo(textLeft, 0.01));
  });
}
