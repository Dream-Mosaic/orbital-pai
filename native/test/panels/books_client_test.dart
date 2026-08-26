import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/connection/app_connection.dart';
import 'package:henry_wall/panels/books_client.dart';

import '../support/fake_socket.dart';

/// Pushed straight behind the join reply, exactly what BooksChannel does
/// (`send(self(), :push_state)` in `join/2`).
const String _stateFrame = '[null,null,"panel:books:henry","state",'
    '{"books":[{"key":"list:3","label":"Groceries","kind":"list","icon":"shopping-cart"}],'
    '"current_key":"list:3","clear_confirm":"clear?",'
    '"list":{"id":3,"name":"Groceries","household":false,"items":[]},'
    '"garden":null}]';

void main() {
  // ---- BooksState.fromJson: pure parsing, no socket needed ----

  group('BooksState.fromJson', () {
    test('parses a list book', () {
      final s = BooksState.fromJson({
        'books': [
          {'key': 'list:3', 'label': 'Groceries', 'kind': 'list', 'icon': 'shopping-cart'},
          {'key': 'garden', 'label': 'Garden', 'kind': 'garden', 'icon': 'sun'},
        ],
        'current_key': 'list:3',
        'clear_confirm': 'Clear everything off Groceries? The list stays, just empty.',
        'list': {
          'id': 3,
          'name': 'Groceries',
          'household': false,
          'items': [
            {'id': 9, 'text': 'milk', 'checked': false},
            {'id': 8, 'text': 'eggs', 'checked': true},
          ],
        },
        'garden': null,
      });

      expect(s.books.map((b) => b.key), ['list:3', 'garden']);
      expect(s.currentKey, 'list:3');
      expect(s.list!.items.map((i) => i.text), ['milk', 'eggs']);
      expect(s.list!.items.last.checked, isTrue);
      expect(s.garden, isNull);
    });

    // A wrong implementation might re-sort the past seasons (e.g. ascending by
    // year, since that reads as "chronological") or read `past` as a Map
    // keyed by season. Three seasons in a non-monotonic order rule both out:
    // sorted ascending gives ['Fall 2024','Spring 2025','Winter 2026'],
    // sorted descending gives ['Winter 2026','Spring 2025','Fall 2024'], and
    // neither matches the fixture's own order — only a client that preserves
    // the server's array verbatim reproduces it.
    test('parses a garden book, preserving past-season ORDER', () {
      final s = BooksState.fromJson({
        'books': [
          {'key': 'garden', 'label': 'Garden', 'kind': 'garden', 'icon': 'sun'}
        ],
        'current_key': 'garden',
        'clear_confirm': 'x',
        'list': null,
        'garden': {
          'active': [
            {
              'id': 4,
              'name': 'Tomatoes',
              'household': true,
              'meta': 'Roma · back bed',
              'notes': [
                {'body': 'first flowers', 'noted': 'Jul 20'}
              ],
            }
          ],
          'past': [
            {
              'season': 'Spring 2025',
              'plants': [
                {'id': 2, 'name': 'Beans', 'household': false}
              ]
            },
            {
              'season': 'Fall 2024',
              'plants': [
                {'id': 1, 'name': 'Peas', 'household': false}
              ]
            },
            {
              'season': 'Winter 2026',
              'plants': [
                {'id': 5, 'name': 'Kale', 'household': false}
              ]
            },
          ],
        },
      });

      // The server decided this order. A client that re-sorted (ascending or
      // descending), or that read a map, would come back different from this.
      expect(s.garden!.past.map((p) => p.season),
          ['Spring 2025', 'Fall 2024', 'Winter 2026']);
      expect(s.garden!.active.single.notes.single.noted, 'Jul 20');
    });

    // A wrong implementation might default a missing `key` to '' and keep the
    // row instead of dropping it — that would leave three books, not two, and
    // the middle one would not equal 'list:3' or 'garden'. The bad row is
    // otherwise well-formed (valid kind/icon/label) and drops ONLY `key`, so
    // this pins the actual predicate ("has a key") rather than merely
    // "rejects a row missing everything" — a filter checking any other field
    // (e.g. `m['icon'] is String`) would wrongly keep this row.
    test('a malformed row is dropped, its siblings land', () {
      final s = BooksState.fromJson({
        'books': [
          {'key': 'list:3', 'label': 'Groceries', 'kind': 'list', 'icon': 'shopping-cart'},
          {'label': 'Sneaky Extra Book', 'kind': 'list', 'icon': 'shopping-cart'},
          {'key': 'garden', 'label': 'Garden', 'kind': 'garden', 'icon': 'sun'},
        ],
        'current_key': 'list:3',
        'clear_confirm': '',
        'list': null,
        'garden': null,
      });

      expect(s.books.map((b) => b.key), ['list:3', 'garden']);
    });

    // The item filter is a `num id && String text` AND — each bad row below
    // isolates exactly one half (the other field, and `checked`, stay
    // well-formed) so a mutation dropping either half of the guard is
    // caught, not just a mutation dropping both.
    test('a malformed list item is dropped, its siblings land', () {
      final s = BooksState.fromJson({
        'books': const [],
        'current_key': 'list:3',
        'clear_confirm': '',
        'list': {
          'id': 3,
          'name': 'Groceries',
          'household': false,
          'items': [
            {'id': 9, 'text': 'milk', 'checked': false},
            {'text': 'no id', 'checked': false},
            {'id': 7, 'checked': true},
          ],
        },
        'garden': null,
      });

      expect(s.list!.items.map((i) => i.id), [9]);
    });

    // The active-plant filter requires only an id (name/household/meta/notes
    // all default), so this bad row keeps every other field well-formed and
    // drops ONLY `id`, pinning that one guard specifically.
    test('a malformed active-plant row is dropped, its siblings land', () {
      final s = BooksState.fromJson({
        'books': const [],
        'current_key': 'garden',
        'clear_confirm': '',
        'list': null,
        'garden': {
          'active': [
            {
              'id': 4,
              'name': 'Tomatoes',
              'household': true,
              'meta': 'Roma · back bed',
              'notes': const [],
            },
            {
              'name': 'Ghost',
              'household': false,
              'meta': 'no id',
              'notes': const [],
            },
          ],
          'past': const [],
        },
      });

      expect(s.garden!.active.map((p) => p.id), [4]);
    });

    // Same guard, same fixture shape, but inside a past season's plant list
    // (PastSeason._plants) rather than active — a separate code path with its
    // own copy of the `id is num` check.
    test('a malformed past-season plant row is dropped, its siblings land', () {
      final s = BooksState.fromJson({
        'books': const [],
        'current_key': 'garden',
        'clear_confirm': '',
        'list': null,
        'garden': {
          'active': const [],
          'past': [
            {
              'season': '2025',
              'plants': [
                {'id': 2, 'name': 'Beans', 'household': false},
                {'name': 'Ghost', 'household': false},
              ],
            },
          ],
        },
      });

      expect(s.garden!.past.single.plants.map((p) => p.id), [2]);
    });

    // A wrong implementation might do `j['past'] as List? ?? []`, which
    // throws a TypeError on a String rather than falling back — this proves
    // the wrong-typed section degrades to empty instead of blowing up the
    // whole parse.
    test('a past section of the wrong shape yields empty, not a throw', () {
      final s = BooksState.fromJson({
        'books': const [],
        'current_key': 'garden',
        'clear_confirm': '',
        'list': null,
        'garden': {'active': const [], 'past': 'nope'},
      });

      expect(s.garden!.past, isEmpty);
    });
  });

  // ---- BooksClient: lifecycle + writes, against the fake socket ----

  group('BooksClient', () {
    late FakeSocket fake;
    late AppConnection conn;
    late BooksClient client;

    setUp(() {
      fake = FakeSocket(joinPushes: const {'panel:books:henry': _stateFrame});
      conn = AppConnection(
        connector: () async => fake.socket,
        rejoinBackoff: const [Duration(days: 1)],
      );
      client = BooksClient(connection: conn);
    });

    tearDown(() {
      client.dispose();
      conn.dispose();
    });

    // Table-driven so a silently missing (or mis-wired) method is impossible:
    // each row names its own event/payload and the loop below fails loudly if
    // any one of the ten is missing or sends the wrong thing.
    final pushCases = <_PushCase>[
      _PushCase('selectBook', (c) => c.selectBook('list:3'), 'select_book', {'key': 'list:3'}),
      _PushCase('newList', (c) => c.newList('Snacks'), 'new_list', {'name': 'Snacks'}),
      _PushCase('clearBook', (c) => c.clearBook(), 'clear_book', const {}),
      _PushCase('toggleItem', (c) => c.toggleItem(9), 'toggle_item', {'id': 9}),
      _PushCase(
        'addItem',
        (c) => c.addItem(listId: 3, text: 'milk'),
        'add_item',
        {'list_id': 3, 'text': 'milk'},
      ),
      _PushCase('clearDone', (c) => c.clearDone(3), 'clear_done', {'list_id': 3}),
      _PushCase('deleteList', (c) => c.deleteList(3), 'delete_list', {'list_id': 3}),
      _PushCase(
        'addNote',
        (c) => c.addNote(plantId: 4, body: 'first flowers'),
        'add_note',
        {'plant_id': 4, 'body': 'first flowers'},
      ),
      _PushCase('archivePlant', (c) => c.archivePlant(4), 'archive_plant', {'id': 4}),
      _PushCase('revivePlant', (c) => c.revivePlant(2), 'revive_plant', {'id': 2}),
    ];

    for (final tc in pushCases) {
      test('${tc.name} pushes "${tc.event}" with the right payload', () async {
        await conn.connect();
        client.open();
        await pumpEventQueue();
        fake.sent.clear();

        tc.invoke(client);

        final frame = fake.textFrames.last;
        expect(frame[3], tc.event);
        expect(frame[4], tc.payload);
      });
    }

    // A wrong implementation might push unconditionally instead of gating on
    // `ch.isJoined`, which would land a frame the server answers with
    // "unmatched topic" — dropping silently is the correct behaviour here.
    test('a push before the join reply is dropped, not sent into the void',
        () async {
      await conn.connect();
      client.open();
      // No pump: the join reply has not landed yet.

      client.selectBook('list:3');

      expect(fake.textFrames.where((p) => p[3] == 'select_book'), isEmpty);
    });

    // A wrong implementation might only clear local flags in close(), leaving
    // the topic registered in AppConnection — debugListenerCount reads the
    // CONNECTION's registry, so this catches that even if `isOpen` looks
    // correct.
    test('debugListenerCount goes 1 -> 0 on close()', () async {
      await conn.connect();
      client.open();
      await pumpEventQueue();
      expect(conn.debugListenerCount('panel:books:henry'), 1);

      client.close();

      expect(conn.debugListenerCount('panel:books:henry'), 0);
    });

    test('debugListenerCount goes 1 -> 0 on dispose()', () async {
      final fake2 = FakeSocket(joinPushes: const {'panel:books:henry': _stateFrame});
      final conn2 = AppConnection(
        connector: () async => fake2.socket,
        rejoinBackoff: const [Duration(days: 1)],
      );
      final client2 = BooksClient(connection: conn2);
      addTearDown(conn2.dispose);

      await conn2.connect();
      client2.open();
      await pumpEventQueue();
      expect(conn2.debugListenerCount('panel:books:henry'), 1);

      client2.dispose();

      expect(conn2.debugListenerCount('panel:books:henry'), 0);
    });

    // A wrong implementation might leave `_state` as-is on close(), so a
    // reopen briefly renders stale data before the next `state` lands.
    test('close() clears state back to null', () async {
      await conn.connect();
      client.open();
      await pumpEventQueue();
      expect(client.state, isNotNull);

      client.close();

      expect(client.state, isNull);
    });
  });
}

class _PushCase {
  const _PushCase(this.name, this.invoke, this.event, this.payload);

  final String name;
  final void Function(BooksClient) invoke;
  final String event;
  final Map<String, dynamic> payload;
}
