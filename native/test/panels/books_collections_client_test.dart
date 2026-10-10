import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/panels/books_client.dart';

/// The three collection books' bodies — recipes, trackers, routines — as
/// `AppWeb.CollectionFormat` renders them. Pure parsing: every string is the
/// server's, kept verbatim; a malformed row is dropped without taking its
/// siblings (or the rest of the payload) with it.
Map<String, dynamic> _state({
  Object? recipes,
  Object? trackers,
  Object? routines,
  String current = 'recipes',
}) =>
    {
      'books': [
        {'key': 'garden', 'label': 'Garden', 'kind': 'garden', 'icon': 'sun'},
        {'key': 'recipes', 'label': 'Recipes', 'kind': 'recipes', 'icon': 'cake'},
        {'key': 'trackers', 'label': 'Trackers', 'kind': 'trackers', 'icon': 'chart-bar'},
        {'key': 'routines', 'label': 'Routines', 'kind': 'routines', 'icon': 'bolt'},
      ],
      'current_key': current,
      'clear_confirm': null,
      'list': null,
      'garden': null,
      'recipes': recipes,
      'trackers': trackers,
      'routines': routines,
    };

void main() {
  test('a collection book has no clear_confirm: null parses to empty', () {
    final s = BooksState.fromJson(_state());
    expect(s.clearConfirm, '');
    expect(s.books.map((b) => b.kind), ['garden', 'recipes', 'trackers', 'routines']);
    expect(s.recipes, isNull);
    expect(s.trackers, isNull);
    expect(s.routines, isNull);
  });

  group('recipes', () {
    test('parses rows verbatim, with the full body each detail needs', () {
      final s = BooksState.fromJson(_state(recipes: {
        'items': [
          {
            'id': 12,
            'title': "Grandma's Lasagna",
            'shared': true,
            'tag': 'shared',
            'meta': '9 ingredients · 6 steps',
            'detail_meta': 'Serves 6 · From Grandma',
            'ingredients': ['1 lb ground beef', '12 noodles'],
            'steps': ['Layer it up.', 'Bake.'],
            'notes': 'Rest it 10 minutes.',
            'delete_confirm': 'Delete it?',
          },
          {
            'id': 13,
            'title': 'Chili',
            'shared': false,
            'tag': 'yours',
            'meta': '1 ingredient · 1 step',
            'detail_meta': null,
            'ingredients': ['beans'],
            'steps': ['Simmer.'],
            'notes': null,
            'delete_confirm': 'Delete your recipe?',
          },
        ],
        'empty': 'No recipes yet.',
        'hint': 'Try: “Henry, save my lasagna recipe…”',
      }));

      final r = s.recipes!;
      expect(r.empty, 'No recipes yet.');
      expect(r.hint, 'Try: “Henry, save my lasagna recipe…”');
      expect(r.items.map((i) => i.id), [12, 13]);
      final lasagna = r.items.first;
      expect(lasagna.title, "Grandma's Lasagna");
      expect(lasagna.shared, isTrue);
      expect(lasagna.tag, 'shared');
      expect(lasagna.meta, '9 ingredients · 6 steps');
      expect(lasagna.detailMeta, 'Serves 6 · From Grandma');
      expect(lasagna.ingredients, ['1 lb ground beef', '12 noodles']);
      expect(lasagna.steps, ['Layer it up.', 'Bake.']);
      expect(lasagna.notes, 'Rest it 10 minutes.');
      expect(lasagna.deleteConfirm, 'Delete it?');
      expect(r.items.last.detailMeta, '');
      expect(r.items.last.notes, '');
    });

    test('a row without an id is dropped; non-string ingredients are skipped', () {
      final s = BooksState.fromJson(_state(recipes: {
        'items': [
          {'title': 'No id'},
          {
            'id': 2,
            'title': 'Ok',
            'ingredients': ['salt', 3, null],
          },
        ],
      }));
      expect(s.recipes!.items.map((i) => i.title), ['Ok']);
      expect(s.recipes!.items.single.ingredients, ['salt']);
      expect(s.recipes!.items.single.steps, isEmpty);
    });

    test('find() looks a recipe up by id', () {
      final s = BooksState.fromJson(_state(recipes: {
        'items': [
          {'id': 2, 'title': 'A'},
          {'id': 5, 'title': 'B'},
        ],
      }));
      expect(s.recipes!.find(5)!.title, 'B');
      expect(s.recipes!.find(9), isNull);
    });
  });

  group('trackers', () {
    test('parses the row, the 30-day series, stats, tags and recent entries', () {
      final s = BooksState.fromJson(_state(current: 'trackers', trackers: {
        'items': [
          {
            'id': 7,
            'label': 'Headaches',
            'unit': 'pain 1-10',
            'count': '14 entries',
            'last': '2 days ago · 6',
            'range': 'Last 30 days',
            'series': [
              {'label': 'Sep 11', 'count': 0, 'value': null, 'peak': null},
              {
                'label': 'Sep 12',
                'count': 2,
                'value': 8,
                'peak': '8',
                'tip': 'Sat, Sep 12 · up to 8 · 2 entries',
              },
              {'label': 'Sep 13', 'count': 1, 'value': 4.5, 'peak': null},
            ],
            'axis_from': 'Sep 11',
            'axis_to': 'Today',
            'stats': [
              {'label': 'Average', 'value': '5.4'},
              {'label': 'Range', 'value': '2–8'},
            ],
            'tags': [
              {'tag': 'skipped lunch', 'tally': '×4'},
              {'tag': 'poor sleep', 'tally': null},
            ],
            'recent': [
              {
                'day': 'Today',
                'time': '2:15 PM',
                'value': '6',
                'note': 'after lunch',
                'tags': ['stress'],
              },
              {'day': 'Yesterday', 'time': '9:00 AM', 'value': null, 'note': null, 'tags': []},
            ],
            'more': 'Showing the latest 20 of 48',
            'quiet': null,
          },
        ],
        'empty': 'No trackers yet.',
        'hint': 'Try: “Henry, log a headache, about a 6.”',
      }));

      final t = s.trackers!.items.single;
      expect(t.id, 7);
      expect(t.label, 'Headaches');
      expect(t.unit, 'pain 1-10');
      expect(t.count, '14 entries');
      expect(t.last, '2 days ago · 6');
      expect(t.range, 'Last 30 days');
      expect(t.series.map((p) => p.label), ['Sep 11', 'Sep 12', 'Sep 13']);
      expect(t.series[0].value, isNull);
      expect(t.series[0].logged, isFalse);
      expect(t.series[1].value, 8.0);
      expect(t.series[1].peak, '8');
      expect(t.series[1].tip, 'Sat, Sep 12 · up to 8 · 2 entries');
      expect(t.series[0].tip, '');
      expect(t.series[2].value, 4.5);
      expect(t.axisFrom, 'Sep 11');
      expect(t.axisTo, 'Today');
      expect(t.stats.map((x) => '${x.label}=${x.value}'), ['Average=5.4', 'Range=2–8']);
      expect(t.tags.map((x) => '${x.tag}${x.tally}'), ['skipped lunch×4', 'poor sleep']);
      expect(t.recent.first.note, 'after lunch');
      expect(t.recent.first.tags, ['stress']);
      expect(t.recent.last.value, '');
      expect(t.more, 'Showing the latest 20 of 48');
      expect(t.quiet, '');
      expect(s.trackers!.find(7), same(t));
      expect(s.trackers!.hint, 'Try: “Henry, log a headache, about a 6.”');
    });

    test('a habit point with no value but a count still reads as logged', () {
      final p = TrackerPoint.fromJson(const {'label': 'Oct 1', 'count': 2, 'value': null});
      expect(p.logged, isTrue);
      expect(p.count, 2);
    });
  });

  group('routines', () {
    test('parses name, phrases, steps, last run and the delete copy', () {
      final s = BooksState.fromJson(_state(current: 'routines', routines: {
        'items': [
          {
            'id': 4,
            'name': 'Good night',
            'say': ['Good night', 'bedtime'],
            'steps': 'Lights off.',
            'last_run': 'Ran yesterday',
            'delete_confirm': 'Delete the “Good night” routine?',
          },
          {'name': 'no id'},
        ],
        'empty': 'No routines yet.',
        'hint': 'Try: …',
      }));

      final r = s.routines!.items.single;
      expect(r.id, 4);
      expect(r.name, 'Good night');
      expect(r.say, ['Good night', 'bedtime']);
      expect(r.steps, 'Lights off.');
      expect(r.lastRun, 'Ran yesterday');
      expect(r.deleteConfirm, 'Delete the “Good night” routine?');
      expect(s.routines!.empty, 'No routines yet.');
    });
  });

  test('a body of the wrong shape is null, not a throw', () {
    final s = BooksState.fromJson(_state(recipes: 'nope', trackers: 3, routines: const []));
    expect(s.recipes, isNull);
    expect(s.trackers, isNull);
    expect(s.routines, isNull);
  });
}
