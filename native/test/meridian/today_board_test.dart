import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/meridian/cards/card_frame.dart';
import 'package:orbital_pai/meridian/cards/forecast_strip.dart';
import 'package:orbital_pai/meridian/today_board.dart';
import 'package:orbital_pai/meridian/tokens.dart';
import 'package:orbital_pai/meridian/wall_type.dart';
import 'package:orbital_pai/voice/glance.dart';

const _agenda = [
  {
    'title': 'Dinner with Mom',
    'time': '7:30 PM',
    'day': 'Today',
    'all_day': false
  },
  {
    'title': "Mom's birthday",
    'time': 'All day',
    'day': 'Tomorrow',
    'all_day': true
  },
  {'title': 'Dentist', 'time': '9:00 AM', 'day': 'Tomorrow', 'all_day': false},
];

const _forecast = {
  'hourly': [
    {'label': '6PM', 'temp': '63°', 'icon': 'partly'},
    {'label': '7PM', 'temp': '61°', 'icon': 'rain', 'precip': '40%'},
  ],
  'daily': [
    {'label': 'Sun', 'hi': '66°', 'lo': '52°', 'icon': 'rain'},
    {'label': 'Mon', 'hi': '61°', 'lo': '47°', 'icon': 'storm'},
  ],
};

const _reminders = [
  {'text': 'Take out the bins', 'time': '8:00 PM', 'household': true},
  {'text': 'Call the pharmacy', 'time': '9:30 PM', 'household': false},
];

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final display = FontLoader(kDisplayFamily)
      ..addFont(rootBundle.load('assets/fonts/SpaceGrotesk.ttf'));
    final body = FontLoader(kBodyFamily)
      ..addFont(rootBundle.load('assets/fonts/Inter.ttf'));
    await Future.wait([display.load(), body.load()]);
  });

  /// The board where the screen puts it: a wall's thread slot, under the
  /// wall's type.
  Future<void> pump(WidgetTester tester, Map<String, dynamic> json,
      {Size slot = const Size(631, 580)}) async {
    tester.view.physicalSize = const Size(1200, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Material(
        color: M.bg,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox.fromSize(
            size: slot,
            child: WallTypeScope(
              type: WallType.wall,
              child: TodayBoard(glance: Glance.fromJson(json)),
            ),
          ),
        ),
      ),
    ));
  }

  /// The colour of the span whose text is exactly [text] (a clock time, set
  /// apart from its meridiem).
  Color? spanColour(WidgetTester tester, String text) {
    final rich = tester.widget<RichText>(find.byWidgetPredicate(
        (w) => w is RichText && w.text.toPlainText().startsWith(text)));
    Color? colour;
    rich.text.visitChildren((span) {
      if (span is TextSpan && span.text == text) {
        colour = span.style?.color;
        return false;
      }
      return true;
    });
    return colour;
  }

  testWidgets('shows every section, in order', (tester) async {
    await pump(tester, const {
      'agenda': _agenda,
      'forecast': _forecast,
      'reminders': _reminders,
    });

    final agenda = tester.getTopLeft(find.byKey(TodayBoard.agendaKey));
    final weather = tester.getTopLeft(find.byKey(TodayBoard.weatherKey));
    final reminders = tester.getTopLeft(find.byKey(TodayBoard.remindersKey));
    expect(agenda.dy, lessThan(weather.dy));
    expect(weather.dy, lessThan(reminders.dy));
    expect(find.text('COMING UP'), findsOneWidget);
    expect(find.text('WEATHER'), findsOneWidget);
    expect(find.text('REMINDERS TODAY'), findsOneWidget);
    expect(find.byKey(TodayBoard.emptyKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the agenda groups under its day labels, one label per day',
      (tester) async {
    await pump(tester, const {'agenda': _agenda});

    expect(find.text('TODAY'), findsOneWidget);
    expect(find.text('TOMORROW'), findsOneWidget,
        reason: 'two events, one heading');
    final today = tester.getTopLeft(find.text('TODAY')).dy;
    final dinner = tester.getTopLeft(find.text('Dinner with Mom')).dy;
    final tomorrow = tester.getTopLeft(find.text('TOMORROW')).dy;
    final birthday = tester.getTopLeft(find.text("Mom's birthday")).dy;
    final dentist = tester.getTopLeft(find.text('Dentist')).dy;
    expect(
        today < dinner &&
            dinner < tomorrow &&
            tomorrow < birthday &&
            birthday < dentist,
        isTrue);
  });

  testWidgets('times are the accent green; an all-day event says so, quietly',
      (tester) async {
    await pump(tester, const {'agenda': _agenda});

    expect(spanColour(tester, '7:30'), M.henry.withValues(alpha: 0.92));
    expect(spanColour(tester, '9:00'), M.henry.withValues(alpha: 0.92));
    final allDay = tester.widget<Text>(find.text('All day'));
    expect(allDay.style!.color, isNot(M.henry.withValues(alpha: 0.92)),
        reason: '"All day" is not a time');
  });

  testWidgets(
      'reminders: the time, the words, and "Shared" for the household\'s',
      (tester) async {
    await pump(tester, const {'reminders': _reminders});

    expect(spanColour(tester, '8:00'), M.followup.withValues(alpha: 0.92));
    expect(find.text('Take out the bins'), findsOneWidget);
    expect(find.text('Call the pharmacy'), findsOneWidget);
    expect(find.widgetWithText(CardTag, 'SHARED'), findsOneWidget,
        reason: 'only the household reminder is tagged');
    // The tag follows its reminder's words, on their line.
    final words = tester.getRect(find.text('Take out the bins'));
    final tag = tester.getRect(find.byType(CardTag));
    expect(tag.left - words.right, lessThan(20));
    expect(tag.center.dy, moreOrLessEquals(words.center.dy, epsilon: 6));
  });

  testWidgets('weather: the hours and the days, side by side', (tester) async {
    await pump(tester, const {'forecast': _forecast});

    final strips =
        tester.widgetList<ForecastStrip>(find.byType(ForecastStrip)).toList();
    expect(strips, hasLength(2));
    expect(strips.first.daily, isFalse);
    expect(strips.last.daily, isTrue);
    expect(strips.first.scale, greaterThan(1),
        reason: 'set larger than the card');
    for (final label in [
      '6PM',
      '7PM',
      'Sun',
      'Mon',
      '63°',
      '66°',
      '52°',
      '40%'
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(tester.getTopLeft(find.text('Sun')).dx,
        greaterThan(tester.getTopRight(find.text('7PM')).dx));
    expect(tester.getTopLeft(find.text('Sun')).dy,
        moreOrLessEquals(tester.getTopLeft(find.text('7PM')).dy));
  });

  testWidgets('a forecast with only hours draws one strip', (tester) async {
    await pump(tester, const {
      'forecast': {
        'hourly': [
          {'label': '6PM', 'temp': '63°', 'icon': 'partly'},
        ],
      },
    });
    expect(find.byType(ForecastStrip), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final (name, json, present) in [
    ('only the agenda', {'agenda': _agenda}, TodayBoard.agendaKey),
    ('only the weather', {'forecast': _forecast}, TodayBoard.weatherKey),
    ('only reminders', {'reminders': _reminders}, TodayBoard.remindersKey),
  ]) {
    testWidgets('omits what is empty: $name', (tester) async {
      await pump(tester, json);
      for (final key in [
        TodayBoard.agendaKey,
        TodayBoard.weatherKey,
        TodayBoard.remindersKey,
      ]) {
        expect(find.byKey(key), key == present ? findsOneWidget : findsNothing);
      }
      expect(find.byKey(TodayBoard.emptyKey), findsNothing);
    });
  }

  for (final (name, json) in [
    ('an empty glance', const <String, dynamic>{}),
    (
      'an older server (weather and next event only)',
      const {
        'weather': {'temp': '64°', 'condition': 'Clear', 'icon': 'clear'},
        'next_event': {'title': 'Dinner', 'time': '7:30 PM', 'day': 'Today'},
      }
    ),
  ]) {
    testWidgets('$name: one quiet line, not a blank pane', (tester) async {
      await pump(tester, json);
      expect(find.text(TodayBoard.emptyLine), findsOneWidget);
      expect(find.text('COMING UP'), findsNothing);
      // Centred in the slot.
      expect(tester.getCenter(find.byKey(TodayBoard.emptyKey)).dy,
          moreOrLessEquals(290, epsilon: 1));
    });
  }

  testWidgets('drawn at the wall\'s size', (tester) async {
    await pump(tester, const {'agenda': _agenda});
    final title = tester.widget<Text>(find.text('Dinner with Mom'));
    expect(title.style!.fontSize, WallType.wall.body(16));
    final label = tester.widget<Text>(find.text('COMING UP'));
    expect(label.style!.fontSize, WallType.wall.chrome(9.6));
  });

  testWidgets('a crowded day is scaled to fit, never cut off or overflowing',
      (tester) async {
    const long =
        'Quarterly planning with the whole design team, and lunch after';
    await pump(
      tester,
      {
        'agenda': [
          for (var i = 0; i < 6; i++)
            {
              'title': '$long $i',
              'time': '1$i:00 AM',
              'day': i < 3 ? 'Today' : 'Tomorrow'
            },
        ],
        'forecast': _forecast,
        'reminders': [
          for (var i = 0; i < 5; i++)
            {'text': '$long $i', 'time': '8:0$i PM', 'household': true},
        ],
      },
      slot: const Size(528, 400),
    );

    expect(tester.takeException(), isNull);
    final slot = tester.getRect(find.byType(TodayBoard));
    final last = tester.getRect(find.text('$long 4').last);
    expect(last.bottom, lessThanOrEqualTo(slot.bottom),
        reason: 'the last reminder is on screen');
  });
}
