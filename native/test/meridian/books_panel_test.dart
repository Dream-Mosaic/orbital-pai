import 'dart:convert';

import 'package:flutter/material.dart' hide ListBody;
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/connection/app_connection.dart';
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

  testWidgets('the garden body renders SizedBox.shrink() (Task 6)',
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
    // Nothing from lists_panel/garden_panel copy should have leaked in.
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
}
