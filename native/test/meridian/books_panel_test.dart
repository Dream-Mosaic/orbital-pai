import 'dart:convert';

import 'package:flutter/material.dart' hide ListBody;
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/connection/app_connection.dart';
import 'package:henry_wall/meridian/books_garden.dart';
import 'package:henry_wall/meridian/books_panel.dart';
import 'package:henry_wall/panels/books_client.dart';

import '../support/fake_socket.dart';

Map<String, Object?> _book({
  required String key,
  required String label,
  required String kind,
  required String icon,
}) =>
    {'key': key, 'label': label, 'kind': kind, 'icon': icon};

Map<String, Object?> _item({
  required int id,
  required String text,
  bool checked = false,
}) =>
    {'id': id, 'text': text, 'checked': checked};

String _stateFrame({
  required List<Map<String, Object?>> books,
  required String currentKey,
  String clearConfirm = 'Clear everything off Groceries?',
  Map<String, Object?>? list,
  Map<String, Object?>? garden,
}) =>
    jsonEncode([
      null,
      null,
      'panel:books:henry',
      'state',
      {
        'books': books,
        'current_key': currentKey,
        'clear_confirm': clearConfirm,
        'list': list,
        'garden': garden,
      },
    ]);

/// The default fixture: one list book (Groceries, current), one garden book,
/// two items (one unchecked, one checked) so `Clear done` gating can be
/// exercised against a non-trivial `items` array.
String _groceriesFrame({
  List<Map<String, Object?>>? items,
  bool household = false,
  String clearConfirm = 'Clear everything off Groceries?',
}) =>
    _stateFrame(
      books: [
        _book(key: 'list:3', label: 'Groceries', kind: 'list', icon: 'shopping-cart'),
        _book(key: 'garden', label: 'Garden', kind: 'garden', icon: 'sun'),
      ],
      currentKey: 'list:3',
      clearConfirm: clearConfirm,
      list: {
        'id': 3,
        'name': 'Groceries',
        'household': household,
        'items': items ??
            [
              _item(id: 9, text: 'milk'),
              _item(id: 8, text: 'eggs', checked: true),
            ],
      },
      garden: null,
    );

Map<String, Object?> _note({required String body, required String noted}) =>
    {'body': body, 'noted': noted};

Map<String, Object?> _plant({
  required int id,
  required String name,
  bool household = false,
  String meta = '',
  List<Map<String, Object?>> notes = const [],
}) =>
    {
      'id': id,
      'name': name,
      'household': household,
      'meta': meta,
      'notes': notes,
    };

Map<String, Object?> _season({
  required String season,
  required List<Map<String, Object?>> plants,
}) =>
    {'season': season, 'plants': plants};

/// A garden-current-book fixture: `active`/`past` default empty so each test
/// only supplies what it needs.
String _gardenFrame({
  List<Map<String, Object?>> active = const [],
  List<Map<String, Object?>> past = const [],
}) =>
    _stateFrame(
      books: [
        _book(key: 'garden', label: 'Garden', kind: 'garden', icon: 'sun'),
      ],
      currentKey: 'garden',
      list: null,
      garden: {'active': active, 'past': past},
    );

void main() {
  // Same rationale as memory_panel_test.dart / connectors_panel_test.dart:
  // the socket's heartbeat is a 24h periodic Timer still pending right after
  // connect(), which races flutter_test's pending-timer invariant check if
  // left to addTearDown — so each test explicitly awaits conn.disconnect()
  // once done with the client.
  Future<(BooksClient, AppConnection, FakeSocket)> openedClient(
      WidgetTester tester, String frame) async {
    final fake = FakeSocket(joinPushes: {'panel:books:henry': frame});
    final conn = AppConnection(
      connector: () async => fake.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final client = BooksClient(connection: conn);
    addTearDown(() {
      client.dispose();
      conn.dispose();
    });
    await conn.connect();
    client.open();
    await tester.pump(Duration.zero);
    return (client, conn, fake);
  }

  Future<void> pumpPanel(WidgetTester tester, BooksClient client) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: BooksPanelView(client: client)),
    ));
    await tester.pumpAndSettle();
  }

  List<Object?> lastPush(FakeSocket fake) {
    final frame = jsonDecode(fake.sent.last as String) as List<dynamic>;
    return [frame[2], frame[3], frame[4]];
  }

  bool anyPushOf(FakeSocket fake, String event) => fake.sent
      .map((f) => jsonDecode(f as String) as List<dynamic>)
      .any((p) => p[3] == event);

  testWidgets('the header shows the current book and a Clear control',
      (tester) async {
    final (client, conn, _) = await openedClient(tester, _groceriesFrame());
    await pumpPanel(tester, client);

    // Two: the header's book label AND the list card's own name — both
    // happen to read "Groceries" here, same as the web (the list book's
    // label IS the list's name).
    expect(find.text('Groceries'), findsNWidgets(2));
    expect(find.text('Clear ↻'), findsOneWidget);

    await conn.disconnect();
  });

  group('Switch book starts collapsed', () {
    // A wrong implementation might always render the picker (e.g. drop the
    // `if (_switchExpanded)` guard and rely on scroll to hide it) — that
    // would pass an "expands to show every book" assertion by accident. This
    // asserts the OTHER book is genuinely absent from the tree beforehand.
    testWidgets(
        "the other book's label is not findable before expanding, and the "
        'create field is absent too', (tester) async {
      final (client, conn, _) = await openedClient(tester, _groceriesFrame());
      await pumpPanel(tester, client);

      expect(find.text('Switch book'), findsOneWidget);
      expect(find.text('Garden'), findsNothing);
      expect(find.byKey(BooksPanelView.newListFieldKey), findsNothing);
      expect(find.byKey(BooksPanelView.createButtonKey), findsNothing);

      await conn.disconnect();
    });

    testWidgets(
        'expanding shows every book (current + other) and the create row',
        (tester) async {
      final (client, conn, _) = await openedClient(tester, _groceriesFrame());
      await pumpPanel(tester, client);

      await tester.tap(find.byKey(BooksPanelView.switchBookToggleKey));
      await tester.pumpAndSettle();

      expect(find.byKey(BooksPanelView.bookRowKey('list:3')), findsOneWidget);
      expect(find.byKey(BooksPanelView.bookRowKey('garden')), findsOneWidget);
      expect(find.text('Garden'), findsOneWidget);
      expect(find.byKey(BooksPanelView.newListFieldKey), findsOneWidget);
      expect(find.byKey(BooksPanelView.createButtonKey), findsOneWidget);

      await conn.disconnect();
    });

    testWidgets('tapping the toggle again collapses it back',
        (tester) async {
      final (client, conn, _) = await openedClient(tester, _groceriesFrame());
      await pumpPanel(tester, client);

      await tester.tap(find.byKey(BooksPanelView.switchBookToggleKey));
      await tester.pumpAndSettle();
      expect(find.text('Garden'), findsOneWidget);

      await tester.tap(find.byKey(BooksPanelView.switchBookToggleKey));
      await tester.pumpAndSettle();
      expect(find.text('Garden'), findsNothing);

      await conn.disconnect();
    });
  });

  testWidgets('tapping another book pushes select_book with that key',
      (tester) async {
    final (client, conn, fake) = await openedClient(tester, _groceriesFrame());
    await pumpPanel(tester, client);
    await tester.tap(find.byKey(BooksPanelView.switchBookToggleKey));
    await tester.pumpAndSettle();
    fake.sent.clear();

    await tester.tap(find.byKey(BooksPanelView.bookRowKey('garden')));
    await tester.pump();

    expect(lastPush(fake), ['panel:books:henry', 'select_book', {'key': 'garden'}]);

    await conn.disconnect();
  });

  group('Create', () {
    testWidgets('with text pushes new_list with that name', (tester) async {
      final (client, conn, fake) = await openedClient(tester, _groceriesFrame());
      await pumpPanel(tester, client);
      await tester.tap(find.byKey(BooksPanelView.switchBookToggleKey));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.byKey(BooksPanelView.newListFieldKey), 'Snacks');
      await tester.tap(find.byKey(BooksPanelView.createButtonKey));
      await tester.pump();

      expect(lastPush(fake),
          ['panel:books:henry', 'new_list', {'name': 'Snacks'}]);

      await conn.disconnect();
    });

    testWidgets('with blank text pushes nothing', (tester) async {
      final (client, conn, fake) = await openedClient(tester, _groceriesFrame());
      await pumpPanel(tester, client);
      await tester.tap(find.byKey(BooksPanelView.switchBookToggleKey));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(BooksPanelView.newListFieldKey), '   ');
      await tester.tap(find.byKey(BooksPanelView.createButtonKey));
      await tester.pump();

      expect(anyPushOf(fake, 'new_list'), isFalse,
          reason: 'whitespace-only name must not push');

      await conn.disconnect();
    });
  });

  testWidgets(
      'the list body renders each item with its checkbox state, and '
      'tapping one pushes toggle_item', (tester) async {
    final (client, conn, fake) = await openedClient(tester, _groceriesFrame());
    await pumpPanel(tester, client);

    expect(find.text('milk'), findsOneWidget);
    expect(find.text('eggs'), findsOneWidget);

    final milkCheckbox =
        tester.widget<Checkbox>(find.byKey(BooksPanelView.itemCheckboxKey(9)));
    final eggsCheckbox =
        tester.widget<Checkbox>(find.byKey(BooksPanelView.itemCheckboxKey(8)));
    expect(milkCheckbox.value, isFalse);
    expect(eggsCheckbox.value, isTrue);

    await tester.tap(find.byKey(BooksPanelView.itemCheckboxKey(9)));
    await tester.pump();

    expect(lastPush(fake), ['panel:books:henry', 'toggle_item', {'id': 9}]);

    await conn.disconnect();
  });

  group('Clear done visibility (the done_count gate)', () {
    // Two SEPARATE states, not one — asserting only the present case would
    // pass under an "always show Clear done" implementation.
    testWidgets('absent when nothing is checked', (tester) async {
      final (client, conn, _) = await openedClient(
        tester,
        _groceriesFrame(items: [_item(id: 9, text: 'milk')]),
      );
      await pumpPanel(tester, client);

      expect(find.text('Clear done'), findsNothing);

      await conn.disconnect();
    });

    testWidgets('present when at least one item is checked', (tester) async {
      final (client, conn, fake) = await openedClient(
        tester,
        _groceriesFrame(
            items: [_item(id: 9, text: 'milk', checked: true)]),
      );
      await pumpPanel(tester, client);

      expect(find.text('Clear done'), findsOneWidget);

      await tester.tap(find.text('Clear done'));
      await tester.pump();
      expect(lastPush(fake),
          ['panel:books:henry', 'clear_done', {'list_id': 3}]);

      await conn.disconnect();
    });
  });

  testWidgets(
      'the add-item placeholder interpolates the list name and submitting '
      'pushes add_item', (tester) async {
    final (client, conn, fake) = await openedClient(tester, _groceriesFrame());
    await pumpPanel(tester, client);

    final field =
        tester.widget<TextField>(find.byKey(BooksPanelView.addItemFieldKey));
    expect(field.decoration?.hintText, 'Add to Groceries…');

    await tester.enterText(
        find.byKey(BooksPanelView.addItemFieldKey), 'bread');
    await tester.tap(find.text('Add'));
    await tester.pump();

    expect(lastPush(fake),
        ['panel:books:henry', 'add_item', {'list_id': 3, 'text': 'bread'}]);

    await conn.disconnect();
  });

  group('Nothing on it yet.', () {
    testWidgets('shows only for an empty item list', (tester) async {
      final (emptyClient, emptyConn, _) =
          await openedClient(tester, _groceriesFrame(items: const []));
      await pumpPanel(tester, emptyClient);
      expect(find.text('Nothing on it yet.'), findsOneWidget);
      await emptyConn.disconnect();

      final (client, conn, _) = await openedClient(tester, _groceriesFrame());
      await pumpPanel(tester, client);
      expect(find.text('Nothing on it yet.'), findsNothing);
      await conn.disconnect();
    });
  });

  group('delete-list ✕', () {
    testWidgets('opens a confirm reading "Delete the <name> list?"; '
        'cancelling pushes nothing', (tester) async {
      final (client, conn, fake) = await openedClient(tester, _groceriesFrame());
      await pumpPanel(tester, client);

      await tester.tap(find.byKey(BooksPanelView.deleteListKey(3)));
      await tester.pumpAndSettle();

      expect(find.text('Delete the Groceries list?'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(anyPushOf(fake, 'delete_list'), isFalse);

      await conn.disconnect();
    });

    testWidgets('confirming pushes delete_list with the list id',
        (tester) async {
      final (client, conn, fake) = await openedClient(tester, _groceriesFrame());
      await pumpPanel(tester, client);

      await tester.tap(find.byKey(BooksPanelView.deleteListKey(3)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(
          lastPush(fake), ['panel:books:henry', 'delete_list', {'list_id': 3}]);

      await conn.disconnect();
    });
  });

  group('Clear ↻', () {
    testWidgets("shows the server's clear_confirm string verbatim",
        (tester) async {
      const confirm =
          "Clear everything off Groceries? The list stays, just empty.";
      final (client, conn, _) =
          await openedClient(tester, _groceriesFrame(clearConfirm: confirm));
      await pumpPanel(tester, client);

      await tester.tap(find.text('Clear ↻'));
      await tester.pumpAndSettle();

      expect(find.text(confirm), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await conn.disconnect();
    });

    testWidgets('confirming pushes clear_book', (tester) async {
      final (client, conn, fake) = await openedClient(tester, _groceriesFrame());
      await pumpPanel(tester, client);

      await tester.tap(find.text('Clear ↻'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(lastPush(fake), ['panel:books:henry', 'clear_book', {}]);

      await conn.disconnect();
    });
  });

  testWidgets('a :list book whose list is null renders the gone-nudge',
      (tester) async {
    final frame = _stateFrame(
      books: [
        _book(key: 'list:3', label: 'Groceries', kind: 'list', icon: 'shopping-cart'),
      ],
      currentKey: 'list:3',
      list: null,
      garden: null,
    );
    final (client, conn, _) = await openedClient(tester, frame);
    await pumpPanel(tester, client);

    expect(find.text('That list is gone — pick another book above.'),
        findsOneWidget);

    await conn.disconnect();
  });

  testWidgets(
      'an empty garden renders its own empty state, not the list body copy',
      (tester) async {
    final frame = _stateFrame(
      books: [
        _book(key: 'garden', label: 'Garden', kind: 'garden', icon: 'sun'),
      ],
      currentKey: 'garden',
      list: null,
      garden: {'active': const [], 'past': const []},
    );
    final (client, conn, _) = await openedClient(tester, frame);
    await pumpPanel(tester, client);

    expect(tester.takeException(), isNull);
    expect(
        find.text('Nothing growing yet — just say what you planted.'),
        findsOneWidget);
    // Nothing from lists_panel copy should have leaked in.
    expect(find.text('Nothing on it yet.'), findsNothing);
    expect(find.text('That list is gone — pick another book above.'),
        findsNothing);

    await conn.disconnect();
  });

  testWidgets('renders SizedBox.shrink() while client.state is null',
      (tester) async {
    // No joinPushes entry for the topic: the join reply arrives but no
    // `state` frame ever does, so client.state stays null — the drawer can
    // open before the panel's first push lands.
    final fake = FakeSocket(joinPushes: const {});
    final conn = AppConnection(
      connector: () async => fake.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final client = BooksClient(connection: conn);
    addTearDown(() {
      client.dispose();
      conn.dispose();
    });
    await conn.connect();
    client.open();
    await tester.pump(Duration.zero);

    expect(client.state, isNull);
    await pumpPanel(tester, client);

    expect(tester.takeException(), isNull);
    final shrunk = tester.widgetList<SizedBox>(find.descendant(
      of: find.byType(BooksPanelView),
      matching: find.byType(SizedBox),
    ));
    expect(
      shrunk.where((s) => s.width == 0 && s.height == 0 && s.child == null),
      isNotEmpty,
      reason: 'must render an actual SizedBox.shrink(), not just "nothing '
          'throws"',
    );

    await conn.disconnect();
  });

  testWidgets('a household list shows the shared badge', (tester) async {
    final (client, conn, _) =
        await openedClient(tester, _groceriesFrame(household: true));
    await pumpPanel(tester, client);

    expect(find.text('shared'), findsOneWidget);

    await conn.disconnect();
  });

  testWidgets('a later state push re-renders live', (tester) async {
    final (client, conn, fake) = await openedClient(tester, _groceriesFrame());
    await pumpPanel(tester, client);

    fake.ctrl.foreign.sink.add(_groceriesFrame(
      items: [_item(id: 9, text: 'milk', checked: true)],
    ));
    await tester.pumpAndSettle();

    expect(find.text('Clear done'), findsOneWidget);

    await conn.disconnect();
  });

  group('garden body', () {
    testWidgets(
        'one card per active plant; the shared badge appears only for the '
        'household one', (tester) async {
      final frame = _gardenFrame(active: [
        _plant(id: 1, name: 'Basil'),
        _plant(id: 2, name: 'Tomatoes', household: true),
      ]);
      final (client, conn, _) = await openedClient(tester, frame);
      await pumpPanel(tester, client);

      expect(find.text('Basil'), findsOneWidget);
      expect(find.text('Tomatoes'), findsOneWidget);
      // A wrong implementation that always shows the badge would find two;
      // one that never shows it would find none.
      expect(find.text('shared'), findsOneWidget);

      await conn.disconnect();
    });

    testWidgets('meta renders when non-empty and is absent entirely when blank',
        (tester) async {
      final frame = _gardenFrame(active: [
        _plant(id: 1, name: 'Tomatoes', meta: 'Roma · back bed · 5 plants'),
        _plant(id: 2, name: 'Basil', meta: ''),
      ]);
      final (client, conn, _) = await openedClient(tester, frame);
      await pumpPanel(tester, client);

      expect(find.text('Roma · back bed · 5 plants'), findsOneWidget);
      expect(find.byKey(BooksGardenBody.metaKey(1)), findsOneWidget);
      // Blank meta must not render even an empty Text — the key itself must
      // be absent, not just empty-looking.
      expect(find.byKey(BooksGardenBody.metaKey(2)), findsNothing);

      await conn.disconnect();
    });

    group('notes disclosure', () {
      testWidgets(
          'appears only when the plant has notes, with the LAST note as its '
          'summary — never the first note, and never the literal "Notes" '
          'empty-summary fallback', (tester) async {
        final frame = _gardenFrame(active: [
          _plant(id: 1, name: 'Tomatoes', notes: [
            _note(body: 'Watered', noted: 'Jul 1'),
            _note(body: 'Staked and watered again', noted: 'Jul 15'),
          ]),
          _plant(id: 2, name: 'Basil'), // no notes at all
        ]);
        final (client, conn, _) = await openedClient(tester, frame);
        await pumpPanel(tester, client);

        // Tomatoes: disclosure present, collapsed, summary = LAST note —
        // not the first (a wrong implementation might use notes.first).
        expect(find.byKey(BooksGardenBody.notesToggleKey(1)), findsOneWidget);
        expect(find.text('Staked and watered again'), findsOneWidget);
        expect(find.text('Watered'), findsNothing);

        // Basil: no notes — no disclosure at all. `latest_note_line/1`'s
        // "Notes" fallback (book_format.ex:37-42) only fires for an empty
        // notes list, but garden_panel/1 gates the whole <details> on
        // `plant.notes != []` (voice_modals.ex:248) — so that fallback can
        // never actually reach the screen on the web either. This asserts
        // the disclosure is simply absent, not present-with-"Notes".
        expect(find.byKey(BooksGardenBody.notesToggleKey(2)), findsNothing);
        expect(find.text('Notes'), findsNothing);

        await conn.disconnect();
      });

      testWidgets('expanding reveals every note with its noted date',
          (tester) async {
        final frame = _gardenFrame(active: [
          _plant(id: 1, name: 'Tomatoes', notes: [
            _note(body: 'Watered', noted: 'Jul 1'),
            _note(body: 'Staked and watered again', noted: 'Jul 15'),
          ]),
        ]);
        final (client, conn, _) = await openedClient(tester, frame);
        await pumpPanel(tester, client);

        await tester.tap(find.byKey(BooksGardenBody.notesToggleKey(1)));
        await tester.pumpAndSettle();

        expect(find.text('Watered'), findsOneWidget);
        expect(find.text('Jul 1'), findsOneWidget);
        // The latest note now appears twice: once as the (still-visible)
        // summary line, once again as its own row in the expanded list —
        // proving the summary doesn't disappear and the list isn't missing
        // its last entry.
        expect(find.text('Staked and watered again'), findsNWidgets(2));
        expect(find.text('Jul 15'), findsOneWidget);

        await conn.disconnect();
      });
    });

    testWidgets(
        "the add-note placeholder interpolates the plant's name, and "
        'submitting pushes add_note', (tester) async {
      final frame = _gardenFrame(active: [_plant(id: 7, name: 'Tomatoes')]);
      final (client, conn, fake) = await openedClient(tester, frame);
      await pumpPanel(tester, client);

      final field = tester
          .widget<TextField>(find.byKey(BooksGardenBody.noteFieldKey(7)));
      expect(field.decoration?.hintText, 'Check in on Tomatoes…');

      await tester.enterText(
          find.byKey(BooksGardenBody.noteFieldKey(7)), 'Looking healthy');
      await tester.tap(find.byKey(BooksGardenBody.noteButtonKey(7)));
      await tester.pump();

      expect(lastPush(fake), [
        'panel:books:henry',
        'add_note',
        {'plant_id': 7, 'body': 'Looking healthy'},
      ]);

      await conn.disconnect();
    });

    testWidgets('a blank add-note submission pushes nothing', (tester) async {
      final frame = _gardenFrame(active: [_plant(id: 7, name: 'Tomatoes')]);
      final (client, conn, fake) = await openedClient(tester, frame);
      await pumpPanel(tester, client);

      await tester.enterText(
          find.byKey(BooksGardenBody.noteFieldKey(7)), '   ');
      await tester.tap(find.byKey(BooksGardenBody.noteButtonKey(7)));
      await tester.pump();

      expect(anyPushOf(fake, 'add_note'), isFalse,
          reason: 'whitespace-only note body must not push');

      await conn.disconnect();
    });

    group('Archive', () {
      testWidgets(
          'opens a confirm reading "Move <name> to past seasons?"; '
          'cancelling pushes nothing', (tester) async {
        final frame = _gardenFrame(active: [_plant(id: 4, name: 'Tomatoes')]);
        final (client, conn, fake) = await openedClient(tester, frame);
        await pumpPanel(tester, client);

        await tester.tap(find.byKey(BooksGardenBody.archiveKey(4)));
        await tester.pumpAndSettle();

        expect(find.text('Move Tomatoes to past seasons?'), findsOneWidget);

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        expect(anyPushOf(fake, 'archive_plant'), isFalse);

        await conn.disconnect();
      });

      testWidgets('confirming pushes archive_plant with the plant id',
          (tester) async {
        final frame = _gardenFrame(active: [_plant(id: 4, name: 'Tomatoes')]);
        final (client, conn, fake) = await openedClient(tester, frame);
        await pumpPanel(tester, client);

        await tester.tap(find.byKey(BooksGardenBody.archiveKey(4)));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();

        expect(
            lastPush(fake), ['panel:books:henry', 'archive_plant', {'id': 4}]);

        await conn.disconnect();
      });
    });

    testWidgets(
        '"Nothing growing yet — just say what you planted." shows only '
        'when active is empty', (tester) async {
      final (emptyClient, emptyConn, _) =
          await openedClient(tester, _gardenFrame());
      await pumpPanel(tester, emptyClient);
      expect(find.text('Nothing growing yet — just say what you planted.'),
          findsOneWidget);
      await emptyConn.disconnect();

      final (client, conn, _) = await openedClient(
        tester,
        _gardenFrame(active: [_plant(id: 1, name: 'Tomatoes')]),
      );
      await pumpPanel(tester, client);
      expect(find.text('Nothing growing yet — just say what you planted.'),
          findsNothing);
      await conn.disconnect();
    });

    group('Past seasons', () {
      testWidgets('absent when past is empty', (tester) async {
        final (client, conn, _) = await openedClient(
          tester,
          _gardenFrame(active: [_plant(id: 1, name: 'Tomatoes')]),
        );
        await pumpPanel(tester, client);

        expect(find.text('Past seasons'), findsNothing);

        await conn.disconnect();
      });

      testWidgets(
          'present and collapsed when non-empty; expanding reveals seasons '
          "in the server's order, each with its plants and a working Revive",
          (tester) async {
        // The correct (server-given) order below — 2, 3, 1 — is neither
        // ascending (1, 2, 3) nor descending (3, 2, 1) nor any order a
        // two-season fixture could produce by accident; a sorting or
        // reversing bug in the render would move at least one season.
        final frame = _gardenFrame(past: [
          _season(season: 'Season 2', plants: [_plant(id: 101, name: 'Mint')]),
          _season(season: 'Season 3', plants: [_plant(id: 102, name: 'Kale')]),
          _season(
              season: 'Season 1', plants: [_plant(id: 103, name: 'Chives')]),
        ]);
        final (client, conn, fake) = await openedClient(tester, frame);
        await pumpPanel(tester, client);

        expect(find.text('Past seasons'), findsOneWidget);
        // Collapsed: none of the season content is in the tree yet.
        expect(find.text('Mint'), findsNothing);
        expect(find.text('Season 2'), findsNothing);

        await tester.tap(find.byKey(BooksGardenBody.pastSeasonsToggleKey));
        await tester.pumpAndSettle();

        expect(find.text('Mint'), findsOneWidget);
        expect(find.text('Kale'), findsOneWidget);
        expect(find.text('Chives'), findsOneWidget);

        final season2Y = tester.getTopLeft(find.text('Season 2')).dy;
        final season3Y = tester.getTopLeft(find.text('Season 3')).dy;
        final season1Y = tester.getTopLeft(find.text('Season 1')).dy;
        expect(season2Y, lessThan(season3Y));
        expect(season3Y, lessThan(season1Y));

        await tester.tap(find.byKey(BooksGardenBody.reviveKey(102)));
        await tester.pump();

        expect(lastPush(fake),
            ['panel:books:henry', 'revive_plant', {'id': 102}]);

        await conn.disconnect();
      });
    });
  });
}
