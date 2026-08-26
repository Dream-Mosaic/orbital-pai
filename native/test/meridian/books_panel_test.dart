import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/connection/app_connection.dart';
import 'package:henry_wall/meridian/books_garden.dart';
import 'package:henry_wall/meridian/books_panel.dart';
import 'package:henry_wall/meridian/drawer.dart';
import 'package:henry_wall/meridian/hero_icon.dart';
import 'package:henry_wall/meridian/tokens.dart';
import 'package:henry_wall/panels/books_client.dart';

import '../support/fake_socket.dart';

/// heroicons are SVGs, not IconData, so `find.byIcon` does not apply — the
/// same predicate six sibling test files already use (nav_test.dart,
/// drawer_test.dart, orb_bezel_test.dart, etc).
Finder findHero(HeroIcon icon) =>
    find.byWidgetPredicate((w) => w is HeroIconView && w.icon == icon);

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

  testWidgets(
      "the header renders the CURRENT BOOK's own label AND icon — not "
      "books.first's, not the list's name, and not a hardcoded value",
      (tester) async {
    // A DECOY book listed FIRST (garden/sun/"Garden"), with the actual
    // current book second (list:3/clipboard-document-list/"Groceries
    // List") — distinct from BOTH the decoy's label/icon AND the list's own
    // name. This single fixture catches four independent wrong
    // implementations at once:
    //   - Text(currentBook.label)  -> Text(state.books.first.label)
    //   - Text(currentBook.label)  -> Text('Groceries')  (hardcoded)
    //   - _iconFor(currentBook.icon) -> _iconFor(state.books.first.icon)
    //   - _iconFor(currentBook.icon) -> HeroIcon.shoppingCart (hardcoded)
    // A single-book fixture (the prior version of this test) cannot
    // distinguish "keyed off currentKey" from "always books.first", since
    // with one book they're the same book.
    final frame = _stateFrame(
      books: [
        _book(key: 'garden', label: 'Garden', kind: 'garden', icon: 'sun'),
        _book(
            key: 'list:3',
            label: 'Groceries List',
            kind: 'list',
            icon: 'clipboard-document-list'),
      ],
      currentKey: 'list:3',
      list: {'id': 3, 'name': 'Groceries', 'household': false, 'items': const []},
      garden: null,
    );
    final (client, conn, _) = await openedClient(tester, frame);
    await pumpPanel(tester, client);

    final header = find.byKey(BooksPanelView.headerKey);

    expect(
      find.descendant(of: header, matching: find.text('Groceries List')),
      findsOneWidget,
      reason: "the header must show the CURRENT book's label",
    );
    expect(
      find.descendant(of: header, matching: find.text('Garden')),
      findsNothing,
      reason: "the header must not show books.first's label",
    );
    expect(
      find.descendant(of: header, matching: find.text('Groceries')),
      findsNothing,
      reason: 'the header must not show the LIST name',
    );
    // And the list card, outside the header, carries the list's own name.
    expect(find.text('Groceries'), findsOneWidget,
        reason: 'the list card shows its own name, once, outside the header');

    expect(
      find.descendant(
          of: header, matching: findHero(HeroIcon.clipboardDocumentList)),
      findsOneWidget,
      reason: "the header must show the CURRENT book's icon",
    );
    expect(
      find.descendant(of: header, matching: findHero(HeroIcon.sun)),
      findsNothing,
      reason: "the header must not show books.first's icon",
    );
    expect(
      find.descendant(of: header, matching: findHero(HeroIcon.shoppingCart)),
      findsNothing,
      reason: 'the header icon must not be hardcoded to shoppingCart',
    );

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
      expect(find.text('➕ New list…'), findsOneWidget);
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

  testWidgets(
      'the book picker renders in the SERVER\'s order, not re-sorted by '
      'label or key', (tester) async {
    // Given order: list:2 (Zeta, current), list:5 (Alpha), list:1 (Mango).
    // Chosen so every plausible re-sort disagrees with it:
    //   ascending label:  Alpha, Mango, Zeta   (list:5, list:1, list:2)
    //   descending label: Zeta, Mango, Alpha   (list:2, list:1, list:5)
    //   ascending key:    list:1, list:2, list:5
    //   descending key:   list:5, list:2, list:1
    // None of those four match the given list:2, list:5, list:1 — a
    // re-sort under ANY of them would move at least one row.
    final frame = _stateFrame(
      books: [
        _book(key: 'list:2', label: 'Zeta', kind: 'list', icon: 'shopping-cart'),
        _book(key: 'list:5', label: 'Alpha', kind: 'list', icon: 'shopping-cart'),
        _book(key: 'list:1', label: 'Mango', kind: 'list', icon: 'shopping-cart'),
      ],
      currentKey: 'list:2',
      list: {'id': 2, 'name': 'Zeta', 'household': false, 'items': const []},
      garden: null,
    );
    final (client, conn, _) = await openedClient(tester, frame);
    await pumpPanel(tester, client);
    await tester.tap(find.byKey(BooksPanelView.switchBookToggleKey));
    await tester.pumpAndSettle();

    double topOf(String key) =>
        tester.getTopLeft(find.byKey(BooksPanelView.bookRowKey(key))).dy;
    final y2 = topOf('list:2');
    final y5 = topOf('list:5');
    final y1 = topOf('list:1');

    expect(y2, lessThan(y5), reason: 'list:2 must render before list:5');
    expect(y5, lessThan(y1), reason: 'list:5 must render before list:1');

    await conn.disconnect();
  });

  testWidgets(
      'the current book row is styled distinctly from a non-current row, '
      'in both directions', (tester) async {
    final (client, conn, _) = await openedClient(tester, _groceriesFrame());
    await pumpPanel(tester, client);
    await tester.tap(find.byKey(BooksPanelView.switchBookToggleKey));
    await tester.pumpAndSettle();

    final currentLabel = tester.widget<Text>(find.descendant(
        of: find.byKey(BooksPanelView.bookRowKey('list:3')),
        matching: find.text('Groceries')));
    final otherLabel = tester.widget<Text>(find.descendant(
        of: find.byKey(BooksPanelView.bookRowKey('garden')),
        matching: find.text('Garden')));

    // Asserted both ways: a style that is unconditionally "current" (every
    // row tinted/bold) or unconditionally "not current" (every row plain)
    // would each satisfy only ONE of these two checks.
    expect(currentLabel.style?.color, M.you,
        reason: 'the current row must be tinted');
    expect(currentLabel.style?.fontWeight, FontWeight.w600,
        reason: 'the current row must be bold');
    expect(otherLabel.style?.color, isNot(M.you),
        reason: 'a non-current row must NOT be tinted');
    expect(otherLabel.style?.fontWeight, isNot(FontWeight.w600),
        reason: 'a non-current row must NOT be bold');

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
      expect(
          tester
              .widget<TextField>(find.byKey(BooksPanelView.newListFieldKey))
              .controller!
              .text,
          isEmpty,
          reason: 'a successful create clears the field');

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

    // Every other Create test drives the button. `onSubmitted` is a
    // SEPARATE wire on TextField — a mutation that sets it to null (submit
    // via the keyboard's "done" key does nothing) leaves every button-driven
    // test green, so this drives the field itself via the IME action
    // instead of tapping Create.
    testWidgets('submitting via the keyboard (not the button) also pushes '
        'new_list', (tester) async {
      final (client, conn, fake) = await openedClient(tester, _groceriesFrame());
      await pumpPanel(tester, client);
      await tester.tap(find.byKey(BooksPanelView.switchBookToggleKey));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.byKey(BooksPanelView.newListFieldKey), 'Snacks');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(lastPush(fake),
          ['panel:books:henry', 'new_list', {'name': 'Snacks'}]);

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

  testWidgets(
      'items render in the SERVER\'s order, not re-sorted by id or text',
      (tester) async {
    // Given order: id 5 "Bananas", id 2 "Apples", id 9 "Carrots". Chosen so
    // every plausible re-sort disagrees with it:
    //   ascending id:    2, 5, 9   -> Apples, Bananas, Carrots
    //   descending id:   9, 5, 2   -> Carrots, Bananas, Apples
    //   ascending text:  Apples, Bananas, Carrots
    //   descending text: Carrots, Bananas, Apples
    // None of those four put Bananas first — only the server's own order
    // (preserved verbatim) does.
    final frame = _groceriesFrame(items: [
      _item(id: 5, text: 'Bananas'),
      _item(id: 2, text: 'Apples'),
      _item(id: 9, text: 'Carrots'),
    ]);
    final (client, conn, _) = await openedClient(tester, frame);
    await pumpPanel(tester, client);

    double topOf(int id) =>
        tester.getTopLeft(find.byKey(BooksPanelView.itemCheckboxKey(id))).dy;
    final y5 = topOf(5);
    final y2 = topOf(2);
    final y9 = topOf(9);

    expect(y5, lessThan(y2), reason: 'Bananas (5) must render before Apples (2)');
    expect(y2, lessThan(y9), reason: 'Apples (2) must render before Carrots (9)');

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
    expect(
        tester
            .widget<TextField>(find.byKey(BooksPanelView.addItemFieldKey))
            .controller!
            .text,
        isEmpty,
        reason: 'a successful add clears the field');

    await conn.disconnect();
  });

  testWidgets('a blank add-item submission pushes nothing', (tester) async {
    // The twin of Create's blank-text test — Create has one, add-item
    // never did, so `.trim()`'s removal (or deleting the empty-check
    // entirely) on THIS field went unpinned.
    final (client, conn, fake) = await openedClient(tester, _groceriesFrame());
    await pumpPanel(tester, client);

    await tester.enterText(find.byKey(BooksPanelView.addItemFieldKey), '   ');
    await tester.tap(find.text('Add'));
    await tester.pump();

    expect(anyPushOf(fake, 'add_item'), isFalse,
        reason: 'whitespace-only text must not push');

    await conn.disconnect();
  });

  testWidgets(
      'submitting the add-item field via the keyboard (not the button) also '
      'pushes add_item', (tester) async {
    // Same rationale as the new-list keyboard-submit test above: every other
    // add-item test drives the "Add" button, so a null `onSubmitted` on this
    // field would otherwise go undetected.
    final (client, conn, fake) = await openedClient(tester, _groceriesFrame());
    await pumpPanel(tester, client);

    await tester.enterText(
        find.byKey(BooksPanelView.addItemFieldKey), 'bread');
    await tester.testTextInput.receiveAction(TextInputAction.done);
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

    testWidgets(
        'dismissing the confirm via the barrier (not Cancel) pushes nothing',
        (tester) async {
      // The same rationale (and pattern) as books_garden.dart's Archive
      // barrier-dismiss test: `_confirm`'s `showDialog<bool>` defaults
      // barrierDismissible to true, so a barrier tap or back gesture pops
      // NULL, not an explicit false. The Cancel-button test above pops an
      // explicit false, so it cannot catch a mutant that only mishandles
      // the null (dismissed) case — e.g. `return ok ?? true;`.
      final (client, conn, fake) = await openedClient(tester, _groceriesFrame());
      await pumpPanel(tester, client);

      await tester.tap(find.byKey(BooksPanelView.deleteListKey(3)));
      await tester.pumpAndSettle();

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(anyPushOf(fake, 'delete_list'), isFalse,
          reason: 'a barrier dismissal must not count as confirmation — '
              'this is a destructive action');

      await conn.disconnect();
    });

    testWidgets(
        'the delete control is keyed on the ACTUAL list id, and its push '
        'carries that id — not a hardcoded 3', (tester) async {
      final frame = _stateFrame(
        books: [
          _book(key: 'list:7', label: 'Chores', kind: 'list', icon: 'clipboard-document-list'),
        ],
        currentKey: 'list:7',
        list: {'id': 7, 'name': 'Chores', 'household': false, 'items': const []},
        garden: null,
      );
      final (client, conn, fake) = await openedClient(tester, frame);
      await pumpPanel(tester, client);

      expect(find.byKey(BooksPanelView.deleteListKey(3)), findsNothing,
          reason: 'no list with id 3 exists in this fixture');
      expect(find.byKey(BooksPanelView.deleteListKey(7)), findsOneWidget);

      await tester.tap(find.byKey(BooksPanelView.deleteListKey(7)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(
          lastPush(fake), ['panel:books:henry', 'delete_list', {'list_id': 7}]);

      await conn.disconnect();
    });
  });

  group('Clear ↻', () {
    testWidgets(
        "shows the server's clear_confirm string verbatim; cancelling pushes "
        'nothing', (tester) async {
      const confirm =
          "Clear everything off Groceries? The list stays, just empty.";
      final (client, conn, fake) =
          await openedClient(tester, _groceriesFrame(clearConfirm: confirm));
      await pumpPanel(tester, client);

      await tester.tap(find.text('Clear ↻'));
      await tester.pumpAndSettle();

      expect(find.text(confirm), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // The twin of the delete-list cancel assertion below — this is the
      // panel's most destructive control, and a mutation that shows the
      // dialog but ignores its answer (always clearing) must be caught here,
      // not just at the confirming path.
      expect(anyPushOf(fake, 'clear_book'), isFalse,
          reason: 'dismissing the confirm dialog must push nothing');

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

    testWidgets(
        'dismissing the confirm via the barrier (not Cancel) pushes nothing',
        (tester) async {
      // Same rationale as the delete-list barrier-dismiss test above, and
      // books_garden.dart's Archive one: the Cancel-button test pops an
      // explicit false, which cannot catch a mutant that mishandles only
      // the null (barrier-dismissed) case, e.g. `return ok ?? true;`. This
      // is the panel's other destructive control gated by the same
      // `_confirm`.
      final (client, conn, fake) = await openedClient(tester, _groceriesFrame());
      await pumpPanel(tester, client);

      await tester.tap(find.text('Clear ↻'));
      await tester.pumpAndSettle();

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(anyPushOf(fake, 'clear_book'), isFalse,
          reason: 'a barrier dismissal must not count as confirmation — '
              'this is the panel\'s most destructive control');

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

  testWidgets(
      'each book icon string maps to its OWN HeroIcon, and an unrecognised '
      'one falls back to bookOpen', (tester) async {
    final frame = _stateFrame(
      books: [
        _book(key: 'list:1', label: 'Chores', kind: 'list', icon: 'clipboard-document-list'),
        _book(key: 'list:2', label: 'Groceries', kind: 'list', icon: 'shopping-cart'),
        _book(key: 'garden', label: 'Garden', kind: 'garden', icon: 'sun'),
        _book(key: 'list:3', label: 'Mystery', kind: 'list', icon: 'nonsense-icon'),
      ],
      currentKey: 'list:2',
      list: {'id': 2, 'name': 'Groceries', 'household': false, 'items': const []},
      garden: null,
    );
    final (client, conn, _) = await openedClient(tester, frame);
    await pumpPanel(tester, client);

    // Before expanding: only the header's own icon is on screen — the
    // current book, 'shopping-cart'. A collapsed-`_iconFor` mutation (e.g.
    // always bookOpen) is already visible here.
    expect(findHero(HeroIcon.shoppingCart), findsOneWidget);
    expect(findHero(HeroIcon.bookOpen), findsNothing);

    await tester.tap(find.byKey(BooksPanelView.switchBookToggleKey));
    await tester.pumpAndSettle();

    expect(findHero(HeroIcon.clipboardDocumentList), findsOneWidget,
        reason: "Chores' icon");
    expect(findHero(HeroIcon.sun), findsOneWidget, reason: "Garden's icon");
    expect(findHero(HeroIcon.bookOpen), findsOneWidget,
        reason: "Mystery's unrecognised icon must fall back to bookOpen, "
            'and only ONE row may do so');
    // shoppingCart now appears twice: the header AND the Groceries row.
    expect(findHero(HeroIcon.shoppingCart), findsNWidgets(2));

    await conn.disconnect();
  });

  group('the shared badge', () {
    // Two SEPARATE states, not one — the same trap as the Clear done gate:
    // asserting only the household:true case would pass under an "always
    // show shared" implementation.
    testWidgets('is absent for a non-household list', (tester) async {
      final (client, conn, _) =
          await openedClient(tester, _groceriesFrame(household: false));
      await pumpPanel(tester, client);

      expect(find.text('shared'), findsNothing);

      await conn.disconnect();
    });

    testWidgets('appears for a household list', (tester) async {
      final (client, conn, _) =
          await openedClient(tester, _groceriesFrame(household: true));
      await pumpPanel(tester, client);

      expect(find.text('shared'), findsOneWidget);

      await conn.disconnect();
    });
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

  group('keyboard avoidance (both halves — see memory_panel_test.dart)', () {
    // Ported from memory_panel_test.dart:323-394's two scenarios (a deep
    // field pushed below the fold by content, and a short/landscape
    // viewport that covers even an early field) — that file's own comments
    // explain the FakeViewPadding-is-physical gotcha and the
    // devicePixelRatio pin this borrows verbatim. Both of memory_panel's
    // halves apply equally here: books_panel.dart's own bottomInset
    // Padding, AND each TextField's scrollPadding — removing EITHER lets a
    // focused field land (or stay) behind the keyboard.
    testWidgets(
        'the add-item field scrolls clear of the keyboard when pushed below '
        'the fold by a long item list', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.physicalSize = const Size(360, 800);
      addTearDown(tester.view.resetPhysicalSize);

      // Enough items that the add-item field's UNSCROLLED position is
      // already well past the fold — otherwise this could pass by accident
      // on a short list that never needed to scroll in the first place.
      final manyItems = List.generate(
        16,
        (i) => _item(id: i + 1, text: 'Item number $i, long enough for a full line'),
      );
      final frame = _groceriesFrame(items: manyItems);
      final (client, conn, _) = await openedClient(tester, frame);

      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);

      await tester.pumpWidget(MaterialApp(
        home: MeridianDrawer(
          title: 'Books',
          animation: const AlwaysStoppedAnimation<double>(1),
          onClose: () {},
          child: BooksPanelView(client: client),
        ),
      ));
      await tester.pumpAndSettle();

      // Sanity: confirm the hazard is real before the fix gets credit for
      // solving it.
      final unfocused =
          tester.getRect(find.byKey(BooksPanelView.addItemFieldKey));
      expect(unfocused.bottom, greaterThan(800 - 300),
          reason: 'sanity: the field must start out behind the keyboard '
              'line, or this test could pass without the fix ever running');

      await tester.showKeyboard(find.byKey(BooksPanelView.addItemFieldKey));
      await tester.pumpAndSettle();

      final box = tester.getRect(find.byKey(BooksPanelView.addItemFieldKey));
      expect(box.bottom, lessThanOrEqualTo(800 - 300),
          reason: 'the field must scroll clear of the keyboard, not sit '
              'behind it');
      // The drawer's fixed header sits directly above its own
      // SingleChildScrollView, so that scroll view's top IS the header's
      // bottom — an over-eager correction that scrolls too far would clip
      // the field's top underneath the header while still satisfying the
      // bottom assertion above.
      final headerBottom =
          tester.getRect(find.byType(SingleChildScrollView)).top;
      expect(box.top, greaterThanOrEqualTo(headerBottom),
          reason: 'the field must not be scrolled so far that its top ends '
              'up clipped under the drawer header');

      await conn.disconnect();
    });

    testWidgets(
        'the new-list field also scrolls clear of the keyboard under a '
        'short (landscape) viewport', (tester) async {
      // The new-list field sits near the TOP of the panel (right behind the
      // header, once "Switch book" is expanded) — on a tall portrait phone
      // it never comes close to a keyboard. The realistic scenario where it
      // does is a short landscape viewport, same rationale as
      // memory_panel_test.dart's summary-field test.
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.physicalSize = const Size(800, 380);
      addTearDown(tester.view.resetPhysicalSize);

      final (client, conn, _) = await openedClient(tester, _groceriesFrame());

      tester.view.viewInsets = const FakeViewPadding(bottom: 220);
      addTearDown(tester.view.resetViewInsets);

      await tester.pumpWidget(MaterialApp(
        home: MeridianDrawer(
          title: 'Books',
          animation: const AlwaysStoppedAnimation<double>(1),
          onClose: () {},
          child: BooksPanelView(client: client),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(BooksPanelView.switchBookToggleKey));
      await tester.pumpAndSettle();

      final unfocused =
          tester.getRect(find.byKey(BooksPanelView.newListFieldKey));
      expect(unfocused.bottom, greaterThan(380 - 220),
          reason: 'sanity: the field must start out behind the keyboard '
              'line, or this test could pass without the fix ever running');

      await tester.showKeyboard(find.byKey(BooksPanelView.newListFieldKey));
      await tester.pumpAndSettle();

      final box = tester.getRect(find.byKey(BooksPanelView.newListFieldKey));
      expect(box.bottom, lessThanOrEqualTo(380 - 220),
          reason: 'the new-list field must scroll clear of the keyboard '
              'too, not sit behind it');
      final headerBottom =
          tester.getRect(find.byType(SingleChildScrollView)).top;
      expect(box.top, greaterThanOrEqualTo(headerBottom),
          reason: 'the new-list field must not be scrolled so far that its '
              'top ends up clipped under the drawer header');

      await conn.disconnect();
    });

    testWidgets(
        'the garden add-note field scrolls clear of the keyboard when '
        "pushed below the fold by several plant cards — both halves apply "
        "here too (books_panel.dart's bottomInset AND the field's own "
        'scrollPadding)', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.physicalSize = const Size(360, 800);
      addTearDown(tester.view.resetPhysicalSize);

      // Enough plants, each with a meta line and a notes summary (like a
      // real card), that the LAST one's add-note field starts out well past
      // the fold — otherwise this could pass without either fix ever
      // running.
      final manyPlants = List.generate(
        8,
        (i) => _plant(
          id: i + 1,
          name: 'Plant number $i',
          meta: 'Meta line long enough to take its own row',
          notes: [_note(body: 'Check-in $i', noted: 'Jul $i')],
        ),
      );
      final frame = _gardenFrame(active: manyPlants);
      final (client, conn, _) = await openedClient(tester, frame);

      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);

      await tester.pumpWidget(MaterialApp(
        home: MeridianDrawer(
          title: 'Books',
          animation: const AlwaysStoppedAnimation<double>(1),
          onClose: () {},
          child: BooksPanelView(client: client),
        ),
      ));
      await tester.pumpAndSettle();

      final lastFieldKey = BooksGardenBody.noteFieldKey(8);
      final unfocused = tester.getRect(find.byKey(lastFieldKey));
      expect(unfocused.bottom, greaterThan(800 - 300),
          reason: 'sanity: the field must start out behind the keyboard '
              'line, or this test could pass without either fix ever '
              'running');

      await tester.showKeyboard(find.byKey(lastFieldKey));
      await tester.pumpAndSettle();

      final box = tester.getRect(find.byKey(lastFieldKey));
      expect(box.bottom, lessThanOrEqualTo(800 - 300),
          reason: 'the garden add-note field must scroll clear of the '
              'keyboard, not sit behind it');
      final headerBottom =
          tester.getRect(find.byType(SingleChildScrollView)).top;
      expect(box.top, greaterThanOrEqualTo(headerBottom),
          reason: 'the field must not be scrolled so far that its top ends '
              'up clipped under the drawer header');

      await conn.disconnect();
    });
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

    testWidgets(
        "active plants render in the server's own order, not sorted or "
        'reversed', (tester) async {
      // The correct (server-given) order below — 2, 3, 1 — is neither
      // ascending (1, 2, 3) nor descending (3, 2, 1), so `.reversed`, a
      // sort-ascending, and a sort-descending mutation on `garden.active`
      // would all move at least one plant. The OTHER multi-plant fixtures
      // in this group only ever use 2 plants, which cannot distinguish a
      // correct render from a reversed one (any permutation of 2 elements
      // IS its own reversal) — this is the dedicated order fixture.
      final frame = _gardenFrame(active: [
        _plant(id: 201, name: 'Plant 2'),
        _plant(id: 202, name: 'Plant 3'),
        _plant(id: 203, name: 'Plant 1'),
      ]);
      final (client, conn, _) = await openedClient(tester, frame);
      await pumpPanel(tester, client);

      final plant2Y = tester.getTopLeft(find.text('Plant 2')).dy;
      final plant3Y = tester.getTopLeft(find.text('Plant 3')).dy;
      final plant1Y = tester.getTopLeft(find.text('Plant 1')).dy;
      expect(plant2Y, lessThan(plant3Y));
      expect(plant3Y, lessThan(plant1Y));

      await conn.disconnect();
    });

    testWidgets(
        'meta renders the correct PER-PLANT value when non-empty, and is '
        'absent entirely when blank', (tester) async {
      final frame = _gardenFrame(active: [
        _plant(id: 1, name: 'Tomatoes', meta: 'Roma · back bed · 5 plants'),
        _plant(id: 2, name: 'Basil', meta: 'Sweet basil · pot 4'),
        _plant(id: 3, name: 'Mint', meta: ''),
      ]);
      final (client, conn, _) = await openedClient(tester, frame);
      await pumpPanel(tester, client);

      // Two DIFFERENT non-blank values, each tied to its own plant — a
      // hardcoded meta string (pinning only the presence guard, not the
      // actual value) would satisfy just one of these.
      expect(find.text('Roma · back bed · 5 plants'), findsOneWidget);
      expect(find.text('Sweet basil · pot 4'), findsOneWidget);
      expect(find.byKey(BooksGardenBody.metaKey(1)), findsOneWidget);
      expect(find.byKey(BooksGardenBody.metaKey(2)), findsOneWidget);
      // Blank meta must not render even an empty Text — the key itself must
      // be absent, not just empty-looking.
      expect(find.byKey(BooksGardenBody.metaKey(3)), findsNothing);

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

      testWidgets(
          'expanding reveals every note, oldest first, with its noted date',
          (tester) async {
        final frame = _gardenFrame(active: [
          _plant(id: 1, name: 'Tomatoes', notes: [
            _note(body: 'Watered', noted: 'Jul 1'),
            _note(body: 'Fed', noted: 'Jul 10'),
            _note(body: 'Staked and watered again', noted: 'Jul 15'),
          ]),
        ]);
        final (client, conn, _) = await openedClient(tester, frame);
        await pumpPanel(tester, client);

        await tester.tap(find.byKey(BooksGardenBody.notesToggleKey(1)));
        await tester.pumpAndSettle();

        expect(find.text('Watered'), findsOneWidget);
        expect(find.text('Jul 1'), findsOneWidget);
        expect(find.text('Fed'), findsOneWidget);
        expect(find.text('Jul 10'), findsOneWidget);
        // The latest note now appears twice: once as the (still-visible)
        // summary line, once again as its own row in the expanded list —
        // proving the summary doesn't disappear and the list isn't missing
        // its last entry.
        expect(find.text('Staked and watered again'), findsNWidgets(2));
        expect(find.text('Jul 15'), findsOneWidget);

        // Order within the expanded list itself: oldest first, not
        // reversed. 'Watered' and 'Fed' each appear exactly once (neither
        // is the latest note shown twice), so their positions unambiguously
        // pin the list's own order.
        final wateredY = tester.getTopLeft(find.text('Watered')).dy;
        final fedY = tester.getTopLeft(find.text('Fed')).dy;
        expect(wateredY, lessThan(fedY));

        await conn.disconnect();
      });

      testWidgets(
          "expanding one plant's notes does not expand another plant's",
          (tester) async {
        final frame = _gardenFrame(active: [
          _plant(id: 1, name: 'Tomatoes', notes: [
            _note(body: 'Watered', noted: 'Jul 1'),
            _note(body: 'Staked and watered again', noted: 'Jul 15'),
          ]),
          _plant(id: 2, name: 'Basil', notes: [
            _note(body: 'Pinched', noted: 'Jun 1'),
            _note(body: 'Trimmed again', noted: 'Jun 20'),
          ]),
        ]);
        final (client, conn, _) = await openedClient(tester, frame);
        await pumpPanel(tester, client);

        await tester.tap(find.byKey(BooksGardenBody.notesToggleKey(1)));
        await tester.pumpAndSettle();

        // Tomatoes expanded: its non-summary note is visible.
        expect(find.text('Watered'), findsOneWidget);
        // Basil was never toggled: its non-summary note ('Pinched') must
        // stay hidden — a single shared expansion flag (rather than
        // per-plant state) would leak it open too.
        expect(find.text('Pinched'), findsNothing);

        await conn.disconnect();
      });
    });

    testWidgets(
        "the add-note placeholder interpolates the plant's name; "
        'submitting pushes add_note and clears the field', (tester) async {
      final frame = _gardenFrame(active: [_plant(id: 7, name: 'Tomatoes')]);
      final (client, conn, fake) = await openedClient(tester, frame);
      await pumpPanel(tester, client);

      final field = tester
          .widget<TextField>(find.byKey(BooksGardenBody.noteFieldKey(7)));
      expect(field.decoration?.hintText, 'Check in on Tomatoes…');
      expect(find.text('Note'), findsOneWidget);

      await tester.enterText(
          find.byKey(BooksGardenBody.noteFieldKey(7)), 'Looking healthy');
      await tester.tap(find.byKey(BooksGardenBody.noteButtonKey(7)));
      await tester.pump();

      expect(lastPush(fake), [
        'panel:books:henry',
        'add_note',
        {'plant_id': 7, 'body': 'Looking healthy'},
      ]);
      expect(
        tester
            .widget<TextField>(find.byKey(BooksGardenBody.noteFieldKey(7)))
            .controller!
            .text,
        isEmpty,
        reason: 'the field must clear after a successful submit',
      );

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

    testWidgets(
        'submitting a note via the keyboard (not the button) also pushes '
        'add_note', (tester) async {
      // `onSubmitted` is a SEPARATE wire on TextField from the button's
      // onPressed — a mutation that drops it leaves every button-driven
      // test green (same rationale as books_panel.dart's own new_list /
      // add_item keyboard-submit tests above).
      final frame = _gardenFrame(active: [_plant(id: 7, name: 'Tomatoes')]);
      final (client, conn, fake) = await openedClient(tester, frame);
      await pumpPanel(tester, client);

      await tester.enterText(
          find.byKey(BooksGardenBody.noteFieldKey(7)), 'Looking healthy');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(lastPush(fake), [
        'panel:books:henry',
        'add_note',
        {'plant_id': 7, 'body': 'Looking healthy'},
      ]);

      await conn.disconnect();
    });

    testWidgets(
        "a note submitted on a non-first plant is attributed to THAT "
        "plant, not the first one's", (tester) async {
      final frame = _gardenFrame(active: [
        _plant(id: 10, name: 'Basil'),
        _plant(id: 20, name: 'Tomatoes'),
      ]);
      final (client, conn, fake) = await openedClient(tester, frame);
      await pumpPanel(tester, client);

      await tester.enterText(
          find.byKey(BooksGardenBody.noteFieldKey(20)), 'Looking healthy');
      await tester.tap(find.byKey(BooksGardenBody.noteButtonKey(20)));
      await tester.pump();

      expect(lastPush(fake), [
        'panel:books:henry',
        'add_note',
        {'plant_id': 20, 'body': 'Looking healthy'},
      ]);

      await conn.disconnect();
    });

    group('Archive', () {
      testWidgets(
          'opens a confirm reading "Move <name> to past seasons?"; '
          'cancelling pushes nothing', (tester) async {
        final frame = _gardenFrame(active: [_plant(id: 4, name: 'Tomatoes')]);
        final (client, conn, fake) = await openedClient(tester, frame);
        await pumpPanel(tester, client);

        expect(find.text('Archive'), findsOneWidget);

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

      testWidgets(
          'dismissing the confirm via the barrier (not Cancel) pushes '
          'nothing', (tester) async {
        final frame = _gardenFrame(active: [_plant(id: 4, name: 'Tomatoes')]);
        final (client, conn, fake) = await openedClient(tester, frame);
        await pumpPanel(tester, client);

        await tester.tap(find.byKey(BooksGardenBody.archiveKey(4)));
        await tester.pumpAndSettle();

        // Dismiss by tapping the barrier, NOT the Cancel button — the
        // default barrierDismissible: true pops with no value (null), which
        // only an explicit `ok ?? false` (not e.g. `ok ?? true`) turns into
        // "don't act." The Cancel-button test above pops an EXPLICIT
        // false, so it cannot catch a mutant that only mishandles the null
        // (dismissed) case.
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();

        expect(anyPushOf(fake, 'archive_plant'), isFalse,
            reason: 'a barrier dismissal must not count as confirmation — '
                'this is a destructive action');

        await conn.disconnect();
      });

      testWidgets(
          'archiving a non-first plant is attributed to THAT plant, not '
          "the first one's", (tester) async {
        final frame = _gardenFrame(active: [
          _plant(id: 4, name: 'Tomatoes'),
          _plant(id: 5, name: 'Basil'),
        ]);
        final (client, conn, fake) = await openedClient(tester, frame);
        await pumpPanel(tester, client);

        await tester.tap(find.byKey(BooksGardenBody.archiveKey(5)));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();

        expect(
            lastPush(fake), ['panel:books:henry', 'archive_plant', {'id': 5}]);

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
          "in the server's order, a season's own plants in the server's "
          'order, the shared badge, and a working Revive on each',
          (tester) async {
        // The correct (server-given) SEASON order below — 2, 3, 1 — is
        // neither ascending (1, 2, 3) nor descending (3, 2, 1) nor any
        // order a two-season fixture could produce by accident; a sorting
        // or reversing bug in the render would move at least one season.
        // Season 3 additionally carries two plants (Kale, then Arugula) to
        // pin that a season's OWN plant order is server-given too, and
        // Kale is household so the shared badge gets exercised on an
        // archived row (not just an active one).
        final frame = _gardenFrame(past: [
          _season(season: 'Season 2', plants: [_plant(id: 101, name: 'Mint')]),
          _season(season: 'Season 3', plants: [
            _plant(id: 102, name: 'Kale', household: true),
            _plant(id: 104, name: 'Arugula'),
          ]),
          _season(
              season: 'Season 1', plants: [_plant(id: 103, name: 'Chives')]),
        ]);
        final (client, conn, fake) = await openedClient(tester, frame);
        await pumpPanel(tester, client);

        expect(find.text('Past seasons'), findsOneWidget);
        // Collapsed: none of the season content is in the tree yet.
        expect(find.text('Mint'), findsNothing);
        expect(find.text('Season 2'), findsNothing);
        expect(find.text('shared'), findsNothing);

        await tester.tap(find.byKey(BooksGardenBody.pastSeasonsToggleKey));
        await tester.pumpAndSettle();

        expect(find.text('Mint'), findsOneWidget);
        expect(find.text('Kale'), findsOneWidget);
        expect(find.text('Arugula'), findsOneWidget);
        expect(find.text('Chives'), findsOneWidget);
        // Kale is the only household plant among these four archived rows
        // — both "always show" and "never show" would fail this.
        expect(find.text('shared'), findsOneWidget);
        expect(find.text('Revive'), findsNWidgets(4));

        final season2Y = tester.getTopLeft(find.text('Season 2')).dy;
        final season3Y = tester.getTopLeft(find.text('Season 3')).dy;
        final season1Y = tester.getTopLeft(find.text('Season 1')).dy;
        expect(season2Y, lessThan(season3Y));
        expect(season3Y, lessThan(season1Y));

        // Within Season 3: Kale (server-given first) above Arugula.
        final kaleY = tester.getTopLeft(find.text('Kale')).dy;
        final arugulaY = tester.getTopLeft(find.text('Arugula')).dy;
        expect(kaleY, lessThan(arugulaY));

        await tester.tap(find.byKey(BooksGardenBody.reviveKey(102)));
        await tester.pump();

        expect(lastPush(fake),
            ['panel:books:henry', 'revive_plant', {'id': 102}]);

        await conn.disconnect();
      });
    });
  });
}
