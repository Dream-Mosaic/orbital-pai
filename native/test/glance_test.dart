import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/voice/glance.dart';

/// The `glance` push's Today-board parts (spec 2026-10-23, wall tablet,
/// phase 3): `agenda`, `forecast` and `reminders`, beside the original
/// `weather` and `next_event` (whose own tests live with the orb face).
void main() {
  group('Glance.fromJson, the Today board', () {
    test('parses the agenda, the forecast and the reminders', () {
      final g = Glance.fromJson(const {
        'weather': {
          'temp': '64°',
          'condition': 'Partly cloudy',
          'icon': 'partly'
        },
        'next_event': {
          'title': 'Dentist',
          'time': '9:00 AM',
          'day': 'Tomorrow'
        },
        'agenda': [
          {
            'title': "Mom's birthday",
            'time': 'All day',
            'day': 'Today',
            'all_day': true,
            'at': null,
          },
          {
            'title': 'Dentist',
            'time': '9:00 AM',
            'day': 'Tomorrow',
            'all_day': false,
            'at': '2026-10-11T14:00:00Z',
          },
        ],
        'forecast': {
          'hourly': [
            {
              'label': '3PM',
              'temp': '64°',
              'condition': 'Partly cloudy',
              'icon': 'partly',
              'precip': '30%'
            },
            {
              'label': '4PM',
              'temp': '63°',
              'condition': 'Cloudy',
              'icon': 'cloudy'
            },
          ],
          'daily': [
            {
              'label': 'Sun',
              'hi': '68°',
              'lo': '50°',
              'condition': 'Clear',
              'icon': 'clear'
            },
          ],
        },
        'reminders': [
          {'text': 'Take out the bins', 'time': '8:00 PM', 'household': true},
          {'text': 'Call the pharmacy', 'time': '9:30 PM', 'household': false},
        ],
      });

      expect(g.agenda, hasLength(2));
      final birthday = g.agenda.first;
      expect(birthday.title, "Mom's birthday");
      expect(birthday.time, 'All day');
      expect(birthday.day, 'Today');
      expect(birthday.allDay, isTrue);
      expect(birthday.at, isNull);
      final dentist = g.agenda.last;
      expect(dentist.allDay, isFalse);
      expect(dentist.at, DateTime.utc(2026, 10, 11, 14));

      final f = g.forecast!;
      expect(f.hourly.map((h) => h.label), ['3PM', '4PM']);
      expect(f.hourly.first.temp, '64°');
      expect(f.hourly.first.icon, 'partly');
      expect(f.hourly.first.condition, 'Partly cloudy');
      expect(f.hourly.first.precip, '30%');
      expect(f.hourly.last.precip, isNull,
          reason: 'absent below the card\'s 20%');
      expect(f.daily.single.hi, '68°');
      expect(f.daily.single.lo, '50°');

      expect(g.reminders.map((r) => r.text),
          ['Take out the bins', 'Call the pharmacy']);
      expect(g.reminders.first.time, '8:00 PM');
      expect(g.reminders.first.household, isTrue);
      expect(g.reminders.last.household, isFalse);

      expect(g.hasBoard, isTrue);
      expect(g.isEmpty, isFalse);
    });

    test(
        'an older server sends only weather and next_event, and that still parses',
        () {
      final g = Glance.fromJson(const {
        'weather': {
          'temp': '64°',
          'condition': 'Partly cloudy',
          'icon': 'partly'
        },
        'next_event': {
          'title': 'Dinner with Mom',
          'time': '7:30 PM',
          'day': 'Today'
        },
      });
      expect(g.weather!.temp, '64°');
      expect(g.next!.title, 'Dinner with Mom');
      expect(g.agenda, isEmpty);
      expect(g.forecast, isNull);
      expect(g.reminders, isEmpty);
      expect(g.hasBoard, isFalse,
          reason: 'the board says "Nothing else today."');
      expect(g.isEmpty, isFalse);
    });

    test('a board with only the new parts is not empty', () {
      final g = Glance.fromJson(const {
        'reminders': [
          {'text': 'Water the plants', 'time': '6:00 PM', 'household': false},
        ],
      });
      expect(g.weather, isNull);
      expect(g.next, isNull);
      expect(g.isEmpty, isFalse);
      expect(g.hasBoard, isTrue);
    });

    test('junk is dropped row by row, never thrown', () {
      final g = Glance.fromJson(const {
        'agenda': [
          1,
          'nope',
          {'title': 3, 'time': '9:00 AM'},
          {'title': 'No time'},
          {
            'title': 'Kept',
            'time': '9:00 AM',
            'all_day': 'true',
            'at': 'not a date',
            'day': 7
          },
        ],
        'forecast': {
          'hourly': [
            {'label': '3PM'},
            {'temp': '64°'},
            {'label': '4PM', 'temp': '63°', 'icon': 4, 'precip': ''},
          ],
          'daily': 'nope',
        },
        'reminders': [
          {'text': ''},
          {'text': '   '},
          {'time': '8:00 PM'},
          {'text': 'Kept', 'time': 9, 'household': 'yes'},
        ],
      });

      final kept = g.agenda.single;
      expect(kept.title, 'Kept');
      expect(kept.allDay, isFalse, reason: 'only a real true is all-day');
      expect(kept.at, isNull);
      expect(kept.day, '');

      final hour = g.forecast!.hourly.single;
      expect(hour.label, '4PM');
      expect(hour.icon, '');
      expect(hour.precip, isNull);
      expect(g.forecast!.daily, isEmpty);

      final r = g.reminders.single;
      expect(r.text, 'Kept');
      expect(r.time, '');
      expect(r.household, isFalse);
    });

    test('lists and a forecast of the wrong shape read as nothing', () {
      for (final json in <Map<String, dynamic>>[
        {
          'agenda': 'nope',
          'forecast': 'nope',
          'reminders': {'text': 'x'}
        },
        {'agenda': null, 'forecast': null, 'reminders': null},
        {'agenda': [], 'forecast': [], 'reminders': []},
        {
          'forecast': {'hourly': [], 'daily': []},
        },
        {
          'forecast': {
            'hourly': [1, 2],
            'daily': [
              {'label': 'Sun'}
            ],
          },
        },
      ]) {
        final g = Glance.fromJson(json);
        expect(g.agenda, isEmpty, reason: '$json');
        expect(g.forecast, isNull, reason: '$json');
        expect(g.reminders, isEmpty, reason: '$json');
        expect(g.isEmpty, isTrue, reason: '$json');
      }
    });

    test('equality covers the new parts, so a changed board is a new glance',
        () {
      Glance parse(String reminder) => Glance.fromJson({
            'agenda': const [
              {'title': 'Dentist', 'time': '9:00 AM', 'day': 'Tomorrow'},
            ],
            'forecast': const {
              'hourly': [
                {'label': '3PM', 'temp': '64°'},
              ],
            },
            'reminders': [
              {'text': reminder, 'time': '8:00 PM'},
            ],
          });
      expect(parse('Bins'), parse('Bins'));
      expect(parse('Bins').hashCode, parse('Bins').hashCode);
      expect(parse('Bins'), isNot(parse('Recycling')));
    });
  });
}
