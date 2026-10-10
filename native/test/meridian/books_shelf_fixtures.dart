import 'dart:convert';

/// Realistic `panel:books` state payloads for the three collection books, in
/// exactly the shape `AppWeb.CollectionFormat` renders — shared by the
/// widget tests and the goldens so both exercise what the channel sends.

const List<Map<String, Object?>> shelfBooks = [
  {'key': 'list:3', 'label': 'Groceries', 'kind': 'list', 'icon': 'shopping-cart'},
  {'key': 'garden', 'label': 'Garden', 'kind': 'garden', 'icon': 'sun'},
  {'key': 'recipes', 'label': 'Recipes', 'kind': 'recipes', 'icon': 'cake'},
  {'key': 'trackers', 'label': 'Trackers', 'kind': 'trackers', 'icon': 'chart-bar'},
  {'key': 'routines', 'label': 'Routines', 'kind': 'routines', 'icon': 'bolt'},
];

Map<String, Object?> shelfState(
  String current, {
  Map<String, Object?>? recipes,
  Map<String, Object?>? trackers,
  Map<String, Object?>? routines,
}) =>
    {
      'books': shelfBooks,
      'current_key': current,
      'clear_confirm': null,
      'list': null,
      'garden': null,
      'recipes': recipes,
      'trackers': trackers,
      'routines': routines,
    };

/// The raw Phoenix frame the channel pushes behind its join reply.
String shelfFrame(Map<String, Object?> state) =>
    jsonEncode([null, null, 'panel:books:henry', 'state', state]);

// ---- recipes ----

const Map<String, Object?> lasagna = {
  'id': 12,
  'title': "Grandma's Lasagna",
  'shared': true,
  'tag': 'shared',
  'meta': '9 ingredients · 6 steps',
  'detail_meta': 'Serves 8 · From Grandma',
  'ingredients': [
    '1 lb ground beef',
    '1 lb Italian sausage',
    '1 onion, finely chopped',
    '3 cloves garlic, minced',
    '28 oz crushed tomatoes',
    '12 lasagna noodles',
    '15 oz ricotta cheese',
    '1 egg',
    '1 lb mozzarella, shredded',
  ],
  'steps': [
    'Brown the beef, sausage and onion; add the garlic for the last minute.',
    'Stir in the tomatoes and simmer 30 minutes.',
    'Boil the noodles until just tender, then drain.',
    'Mix the ricotta with the egg.',
    'Layer sauce, noodles, ricotta and mozzarella three times, ending with sauce and cheese.',
    'Bake at 375°F for 45 minutes, covered for the first 25.',
  ],
  'notes': 'Rest it 15 minutes before cutting so the layers hold.\nFreezes well.',
  'delete_confirm':
      "Delete “Grandma's Lasagna” from the shared recipe book? It goes for everyone, and can't be undone.",
};

const Map<String, Object?> recipesBody = {
  'items': [
    {
      'id': 14,
      'title': 'Chicken Tikka Masala',
      'shared': true,
      'tag': 'shared',
      'meta': '13 ingredients · 7 steps',
      'detail_meta': 'Serves 4 · From seriouseats.com',
      'ingredients': ['2 lb chicken thighs'],
      'steps': ['Marinate overnight.'],
      'notes': null,
      'delete_confirm': 'Delete “Chicken Tikka Masala” from the shared recipe book?',
    },
    lasagna,
    {
      'id': 15,
      'title': 'Overnight Oats',
      'shared': false,
      'tag': 'yours',
      'meta': '6 ingredients · 3 steps',
      'detail_meta': 'Serves 1',
      'ingredients': ['½ cup rolled oats'],
      'steps': ['Stir together.'],
      'notes': null,
      'delete_confirm': 'Delete your recipe “Overnight Oats”? This can\'t be undone.',
    },
    {
      'id': 16,
      'title': 'Weeknight Chili',
      'shared': true,
      'tag': 'shared',
      'meta': '11 ingredients · 5 steps',
      'detail_meta': null,
      'ingredients': ['2 cans kidney beans'],
      'steps': ['Simmer.'],
      'notes': null,
      'delete_confirm': 'Delete “Weeknight Chili” from the shared recipe book?',
    },
  ],
  'empty': 'No recipes yet.',
  'hint': 'Try: “Henry, save my lasagna recipe…”',
};

const Map<String, Object?> emptyRecipes = {
  'items': <Object?>[],
  'empty': 'No recipes yet.',
  'hint': 'Try: “Henry, save my lasagna recipe…”',
};

// ---- trackers ----

const List<String> _days = [
  'Sep 11', 'Sep 12', 'Sep 13', 'Sep 14', 'Sep 15', 'Sep 16', 'Sep 17', 'Sep 18',
  'Sep 19', 'Sep 20', 'Sep 21', 'Sep 22', 'Sep 23', 'Sep 24', 'Sep 25', 'Sep 26',
  'Sep 27', 'Sep 28', 'Sep 29', 'Sep 30', 'Oct 1', 'Oct 2', 'Oct 3', 'Oct 4',
  'Oct 5', 'Oct 6', 'Oct 7', 'Oct 8', 'Oct 9', 'Oct 10',
];

/// 30 points from a sparse {dayIndex: value} map; [counts] marks habit days.
List<Map<String, Object?>> series({
  Map<int, num> values = const {},
  Map<int, int> counts = const {},
  int? peak,
}) =>
    [
      for (var i = 0; i < 30; i++)
        {
          'label': _days[i],
          'count': counts[i] ?? (values.containsKey(i) ? 1 : 0),
          'value': values[i],
          'peak': i == peak ? '${values[i]}' : null,
          'tip': values.containsKey(i)
              ? '${_days[i]} · ${values[i]}'
              : (counts[i] ?? 0) > 0
                  ? '${_days[i]} · ${counts[i]} ${counts[i] == 1 ? 'entry' : 'entries'}'
                  : '${_days[i]} · Nothing logged',
        },
    ];

final Map<String, Object?> headaches = {
  'id': 7,
  'label': 'Headaches',
  'unit': 'pain 1–10',
  'count': '14 entries',
  'last': '2 days ago · 6',
  'range': 'Last 30 days',
  'series': series(
    values: {1: 4, 4: 3, 8: 7, 9: 5, 13: 2, 15: 6, 19: 8, 22: 4, 24: 5, 27: 6},
    peak: 19,
  ),
  'axis_from': 'Sep 11',
  'axis_to': 'Today',
  'stats': [
    {'label': 'Average', 'value': '5'},
    {'label': 'Range', 'value': '2–8'},
    {'label': 'Entries', 'value': '10'},
  ],
  'tags': [
    {'tag': 'skipped lunch', 'tally': '×4'},
    {'tag': 'poor sleep', 'tally': '×3'},
    {'tag': 'screens', 'tally': '×2'},
    {'tag': 'weather', 'tally': null},
  ],
  'recent': [
    {
      'day': 'Thu, Oct 8',
      'time': '2:15 PM',
      'value': '6',
      'note': 'Behind the eyes after a long afternoon of calls',
      'tags': ['screens', 'skipped lunch'],
    },
    {'day': 'Sun, Oct 4', 'time': '9:40 AM', 'value': '5', 'note': '', 'tags': ['poor sleep']},
    {'day': 'Fri, Oct 2', 'time': '6:05 PM', 'value': '4', 'note': '', 'tags': <String>[]},
    {
      'day': 'Tue, Sep 29',
      'time': '1:30 PM',
      'value': '8',
      'note': 'Took ibuprofen, lay down for an hour',
      'tags': ['skipped lunch'],
    },
    {'day': 'Fri, Sep 25', 'time': '8:10 PM', 'value': '6', 'note': '', 'tags': ['weather']},
  ],
  'more': '',
  'quiet': '',
};

/// A measure in a tight band far from zero: the chart draws it as a line.
final Map<String, Object?> weight = {
  'id': 8,
  'label': 'Weight',
  'unit': 'lb',
  'count': '38 entries',
  'last': 'Today · 181.6 lb',
  'range': 'Last 30 days',
  'series': series(values: {
    0: 184.2, 1: 184.6, 3: 183.8, 4: 183.9, 6: 183.4, 7: 183.6, 9: 183.1,
    10: 182.8, 12: 183.0, 13: 182.6, 15: 182.9, 16: 182.4, 18: 182.2,
    19: 182.5, 21: 182.0, 22: 181.9, 24: 182.1, 25: 181.8, 27: 181.7,
    28: 181.9, 29: 181.6,
  }, peak: 1),
  'axis_from': 'Sep 11',
  'axis_to': 'Today',
  'stats': [
    {'label': 'Average', 'value': '182.7 lb'},
    {'label': 'Range', 'value': '181.6–184.6 lb'},
    {'label': 'Entries', 'value': '21'},
  ],
  'tags': <Object?>[],
  'recent': [
    {'day': 'Today', 'time': '7:05 AM', 'value': '181.6 lb', 'note': '', 'tags': <String>[]},
    {'day': 'Yesterday', 'time': '6:58 AM', 'value': '181.9 lb', 'note': '', 'tags': <String>[]},
    {
      'day': 'Thu, Oct 8',
      'time': '7:12 AM',
      'value': '181.7 lb',
      'note': 'After the long run',
      'tags': <String>[],
    },
  ],
  'more': 'Showing the latest 20 of 38',
  'quiet': '',
};

final Map<String, Object?> trackersBody = {
  'items': [
    weight,
    headaches,
    {
      'id': 9,
      'label': 'No soda',
      'unit': '',
      'count': '21 entries',
      'last': 'Yesterday',
      'range': 'Last 30 days',
      'series': series(counts: {
        for (var i = 0; i < 30; i++)
          if (i % 4 != 0) i: 1,
      }),
      'axis_from': 'Sep 11',
      'axis_to': 'Today',
      'stats': <Object?>[],
      'tags': <Object?>[],
      'recent': <Object?>[],
    },
  ],
  'empty': 'No trackers yet.',
  'hint': 'Try: “Henry, log a headache, about a 6.”',
};

const Map<String, Object?> emptyTrackers = {
  'items': <Object?>[],
  'empty': 'No trackers yet.',
  'hint': 'Try: “Henry, log a headache, about a 6.”',
};

// ---- routines ----

const Map<String, Object?> routinesBody = {
  'items': [
    {
      'id': 4,
      'name': 'Good night',
      'say': ['Good night', 'bedtime'],
      'steps':
          "Turn off the downstairs lights, set the thermostat to 68, and tell me what's first on my calendar tomorrow.",
      'last_run': 'Ran yesterday',
      'delete_confirm': 'Delete the “Good night” routine? This can\'t be undone.',
    },
    {
      'id': 5,
      'name': 'Leaving the house',
      'say': ['Leaving the house', 'heading out', "I'm off"],
      'steps':
          "Tell me the weather for the next few hours and remind me of anything that's due today.",
      'last_run': 'Ran 3 days ago',
      'delete_confirm': 'Delete the “Leaving the house” routine? This can\'t be undone.',
    },
    {
      'id': 6,
      'name': 'Movie time',
      'say': ['Movie time'],
      'steps': 'Dim the living room lights to 20% and pause the music.',
      'last_run': 'Not run yet',
      'delete_confirm': 'Delete the “Movie time” routine? This can\'t be undone.',
    },
  ],
  'empty': 'No routines yet.',
  'hint':
      "Try: “Henry, when I say good night, turn off the lights and tell me what's first tomorrow.”",
};

const Map<String, Object?> emptyRoutines = {
  'items': <Object?>[],
  'empty': 'No routines yet.',
  'hint':
      "Try: “Henry, when I say good night, turn off the lights and tell me what's first tomorrow.”",
};
