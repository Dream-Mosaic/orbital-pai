import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/connection/app_connection.dart';
import 'package:orbital_pai/meridian/books_details.dart';
import 'package:orbital_pai/meridian/books_drawer_host.dart';
import 'package:orbital_pai/meridian/books_panel.dart';
import 'package:orbital_pai/meridian/books_shelf.dart';
import 'package:orbital_pai/meridian/books_tracker_chart.dart';
import 'package:orbital_pai/meridian/drawer.dart';
import 'package:orbital_pai/meridian/hero_icon.dart';
import 'package:orbital_pai/panels/books_client.dart';

import '../support/fake_socket.dart';
import 'books_shelf_fixtures.dart';

/// heroicons are SVGs, not IconData — same predicate as the sibling tests.
Finder findHero(HeroIcon icon) =>
    find.byWidgetPredicate((w) => w is HeroIconView && w.icon == icon);

/// The Books panel's collection books — recipes, trackers, routines — and the
/// detail layers `BooksDrawerHost` opens from them. Every assertion on copy
/// checks the CHANNEL's string, verbatim: this panel formats nothing.
void main() {
  // Same rationale as books_panel_test.dart: each test awaits
  // conn.disconnect() itself rather than leaving the 24h heartbeat Timer to
  // addTearDown.
  Future<(BooksClient, AppConnection, FakeSocket)> opened(
      WidgetTester tester, Map<String, Object?> state) async {
    final fake = FakeSocket(joinPushes: {'panel:books:henry': shelfFrame(state)});
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
      home: Scaffold(body: SingleChildScrollView(child: BooksPanelView(client: client))),
    ));
    await tester.pumpAndSettle();
  }

  /// The host, through the real hosted route, exactly as main.dart pushes it.
  Future<GlobalKey<NavigatorState>> pumpHost(WidgetTester tester, BooksClient client) async {
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: const Scaffold(body: SizedBox()),
    ));
    unawaited(navKey.currentState!.push(meridianHostedDrawerRoute(
      builder: (context, animation, onClose) => BooksDrawerHost(
        animation: animation,
        onClose: onClose,
        client: client,
      ),
    )));
    await tester.pumpAndSettle();
    return navKey;
  }

  List<Object?> lastPush(FakeSocket fake) {
    final frame = jsonDecode(fake.sent.last as String) as List<dynamic>;
    return [frame[2], frame[3], frame[4]];
  }

  bool anyPushOf(FakeSocket fake, String event) => fake.textFrames.any((p) => p[3] == event);

  String drawerTitle(WidgetTester tester) => tester
      .widget<MeridianDrawer>(find.byType(MeridianDrawer))
      .title;

  group('the picker and header', () {
    testWidgets('a collection offers no Clear', (tester) async {
      final (client, conn, _) =
          await opened(tester, shelfState('recipes', recipes: recipesBody));
      await pumpPanel(tester, client);

      final header = find.byKey(BooksPanelView.headerKey);
      expect(find.descendant(of: header, matching: find.text('Recipes')), findsOneWidget);
      expect(find.descendant(of: header, matching: findHero(HeroIcon.cake)), findsOneWidget);
      expect(find.text('Clear'), findsNothing);
      await conn.disconnect();
    });

    testWidgets('the collections follow a divider, with their own icons, and select by key',
        (tester) async {
      final (client, conn, fake) =
          await opened(tester, shelfState('recipes', recipes: recipesBody));
      await pumpPanel(tester, client);

      await tester.tap(find.byKey(BooksPanelView.switchBookToggleKey));
      await tester.pumpAndSettle();

      expect(find.byKey(BooksPanelView.collectionsDividerKey), findsOneWidget);
      // Below the garden row, above the recipes row.
      final divider = tester.getTopLeft(find.byKey(BooksPanelView.collectionsDividerKey)).dy;
      expect(tester.getTopLeft(find.byKey(BooksPanelView.bookRowKey('garden'))).dy,
          lessThan(divider));
      expect(tester.getTopLeft(find.byKey(BooksPanelView.bookRowKey('recipes'))).dy,
          greaterThan(divider));
      expect(findHero(HeroIcon.chartBar), findsOneWidget);
      expect(findHero(HeroIcon.bolt), findsOneWidget);

      fake.sent.clear();
      await tester.tap(find.byKey(BooksPanelView.bookRowKey('trackers')));
      await tester.pump();
      expect(lastPush(fake), ['panel:books:henry', 'select_book', {'key': 'trackers'}]);
      await conn.disconnect();
    });
  });

  group('recipes', () {
    testWidgets('rows render the channel strings verbatim, in its order', (tester) async {
      final (client, conn, _) =
          await opened(tester, shelfState('recipes', recipes: recipesBody));
      await pumpPanel(tester, client);

      final titles = ['Chicken Tikka Masala', "Grandma's Lasagna", 'Overnight Oats', 'Weeknight Chili'];
      for (final t in titles) {
        expect(find.text(t), findsOneWidget);
      }
      final ys = [for (final t in titles) tester.getTopLeft(find.text(t)).dy];
      expect(ys, [...ys]..sort(), reason: 'server order, never re-sorted');
      expect(find.text('9 ingredients · 6 steps'), findsOneWidget);
      expect(find.text('shared'), findsNWidgets(3));
      expect(find.text('yours'), findsOneWidget);
      // Without a host there is nowhere to open a recipe: no chevrons.
      expect(findHero(HeroIcon.chevronRight), findsNothing);
      await conn.disconnect();
    });

    testWidgets('an empty book says what to say', (tester) async {
      final (client, conn, _) =
          await opened(tester, shelfState('recipes', recipes: emptyRecipes));
      await pumpPanel(tester, client);

      expect(find.text('No recipes yet.'), findsOneWidget);
      expect(find.text('Try: “Henry, save my lasagna recipe…”'), findsOneWidget);
      await conn.disconnect();
    });

    testWidgets('a row opens its detail; the back chevron returns to the book',
        (tester) async {
      final (client, conn, _) =
          await opened(tester, shelfState('recipes', recipes: recipesBody));
      await pumpHost(tester, client);
      expect(drawerTitle(tester), 'Books');
      expect(findHero(HeroIcon.chevronLeft), findsNothing);

      await tester.tap(find.byKey(RecipesShelfBody.rowKey(12)));
      await tester.pumpAndSettle();

      expect(find.byType(RecipeDetailView), findsOneWidget);
      // The layer's title is the BOOK's label, as the channel sent it.
      expect(drawerTitle(tester), 'Recipes');
      expect(find.text("Grandma's Lasagna"), findsOneWidget);
      expect(find.text('Serves 8 · From Grandma'), findsOneWidget);
      expect(find.text('1 lb Italian sausage'), findsOneWidget);
      expect(find.text('Mix the ricotta with the egg.'), findsOneWidget);
      // Steps are numbered here, in order.
      expect(find.text('4'), findsOneWidget);
      expect(
        find.text('Rest it 15 minutes before cutting so the layers hold.\nFreezes well.'),
        findsOneWidget,
      );

      await tester.tap(findHero(HeroIcon.chevronLeft));
      await tester.pumpAndSettle();
      expect(find.byType(RecipeDetailView), findsNothing);
      expect(find.byKey(RecipesShelfBody.rowKey(12)), findsOneWidget);
      await conn.disconnect();
    });

    testWidgets('system back pops the detail, not the drawer', (tester) async {
      final (client, conn, _) =
          await opened(tester, shelfState('recipes', recipes: recipesBody));
      final navKey = await pumpHost(tester, client);
      await tester.tap(find.byKey(RecipesShelfBody.rowKey(12)));
      await tester.pumpAndSettle();

      unawaited(navKey.currentState!.maybePop());
      await tester.pumpAndSettle();
      expect(find.byType(MeridianDrawer), findsOneWidget);
      expect(find.byType(RecipeDetailView), findsNothing);
      expect(find.byType(BooksPanelView), findsOneWidget);

      // At the book, back closes the drawer as usual.
      unawaited(navKey.currentState!.maybePop());
      await tester.pumpAndSettle();
      expect(find.byType(MeridianDrawer), findsNothing);
      await conn.disconnect();
    });

    testWidgets("Delete reads the recipe's own confirmation, pushes its id, and returns",
        (tester) async {
      final (client, conn, fake) =
          await opened(tester, shelfState('recipes', recipes: recipesBody));
      await pumpHost(tester, client);
      await tester.tap(find.byKey(RecipesShelfBody.rowKey(12)));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(RecipeDetailView.deleteKey));
      await tester.tap(find.byKey(RecipeDetailView.deleteKey));
      await tester.pumpAndSettle();
      expect(find.text(lasagna['delete_confirm']! as String), findsOneWidget);

      // Cancel destroys nothing.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(anyPushOf(fake, 'delete_recipe'), isFalse);
      expect(find.byType(RecipeDetailView), findsOneWidget);

      await tester.tap(find.byKey(RecipeDetailView.deleteKey));
      await tester.pumpAndSettle();
      fake.sent.clear();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(lastPush(fake), ['panel:books:henry', 'delete_recipe', {'id': 12}]);
      expect(find.byType(RecipeDetailView), findsNothing,
          reason: 'back to the book at once');
      await conn.disconnect();
    });

    testWidgets('an open recipe re-renders live, and says so when it is gone',
        (tester) async {
      final (client, conn, fake) =
          await opened(tester, shelfState('recipes', recipes: recipesBody));
      await pumpHost(tester, client);
      await tester.tap(find.byKey(RecipesShelfBody.rowKey(12)));
      await tester.pumpAndSettle();

      // Edited by voice: a new ingredient lands while the recipe is open.
      final edited = {
        ...lasagna,
        'ingredients': [...(lasagna['ingredients']! as List), 'fresh basil'],
      };
      fake.ctrl.foreign.sink.add(shelfFrame(shelfState('recipes', recipes: {
        ...recipesBody,
        'items': [edited],
      })));
      await tester.pumpAndSettle();
      expect(find.text('fresh basil'), findsOneWidget);

      // Another device switched the shared current book to groceries: the push arrives with NO
      // recipes body. Not told is not deleted — the open recipe stays.
      fake.ctrl.foreign.sink.add(shelfFrame(shelfState('groceries')));
      await tester.pumpAndSettle();
      expect(find.text('fresh basil'), findsOneWidget);
      expect(find.text(RecipeDetailView.goneText), findsNothing);

      // Deleted by the other person.
      fake.ctrl.foreign.sink.add(shelfFrame(shelfState('recipes', recipes: emptyRecipes)));
      await tester.pumpAndSettle();
      expect(find.text(RecipeDetailView.goneText), findsOneWidget);
      await conn.disconnect();
    });
  });

  group('trackers', () {
    testWidgets('rows render the channel strings verbatim', (tester) async {
      final (client, conn, _) =
          await opened(tester, shelfState('trackers', trackers: trackersBody));
      await pumpPanel(tester, client);

      expect(find.text('Weight'), findsOneWidget);
      expect(find.text('lb · 38 entries'), findsOneWidget);
      expect(find.text('Today · 181.6 lb'), findsOneWidget);
      expect(find.text('Headaches'), findsOneWidget);
      expect(find.text('pain 1–10 · 14 entries'), findsOneWidget);
      expect(find.text('2 days ago · 6'), findsOneWidget);
      // A habit tracker has no unit: just its count.
      expect(find.text('21 entries'), findsOneWidget);
      expect(find.text('Yesterday'), findsOneWidget);
      await conn.disconnect();
    });

    testWidgets('an empty book says what to say', (tester) async {
      final (client, conn, _) =
          await opened(tester, shelfState('trackers', trackers: emptyTrackers));
      await pumpPanel(tester, client);

      expect(find.text('No trackers yet.'), findsOneWidget);
      expect(find.text('Try: “Henry, log a headache, about a 6.”'), findsOneWidget);
      await conn.disconnect();
    });

    testWidgets('a row opens the detail: chart, stats, tags and recent entries',
        (tester) async {
      final (client, conn, _) =
          await opened(tester, shelfState('trackers', trackers: trackersBody));
      await pumpHost(tester, client);

      await tester.tap(find.byKey(TrackersShelfBody.rowKey(7)));
      await tester.pumpAndSettle();

      expect(find.byType(TrackerDetailView), findsOneWidget);
      expect(drawerTitle(tester), 'Trackers');
      expect(find.byType(TrackerChart), findsOneWidget);
      expect(find.text('LAST 30 DAYS'), findsOneWidget);
      expect(find.text('Sep 11'), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('AVERAGE'), findsOneWidget);
      expect(find.text('2–8'), findsOneWidget);
      expect(find.textContaining('skipped lunch'), findsWidgets);
      expect(find.text('Behind the eyes after a long afternoon of calls'), findsOneWidget);
      expect(find.text('Thu, Oct 8 · 2:15 PM'), findsOneWidget);

      await tester.tap(findHero(HeroIcon.chevronLeft));
      await tester.pumpAndSettle();
      expect(find.byType(TrackerDetailView), findsNothing);
      await conn.disconnect();
    });

    testWidgets("touching a day reads out that day's own server tip", (tester) async {
      final (client, conn, _) =
          await opened(tester, shelfState('trackers', trackers: trackersBody));
      await pumpHost(tester, client);
      await tester.tap(find.byKey(TrackersShelfBody.rowKey(7)));
      await tester.pumpAndSettle();

      final bars = tester.getRect(find.byKey(TrackerChart.barsKey));
      // Slot 19 of 30 — Sep 30, the peak (8).
      await tester.tapAt(Offset(bars.left + bars.width * (19.5 / 30), bars.center.dy));
      await tester.pump();
      expect(
        tester.widget<Text>(find.byKey(TrackerChart.readoutKey)).data,
        'Sep 30 · 8',
      );

      // Touching it again lets go: the caption comes back.
      await tester.tapAt(Offset(bars.left + bars.width * (19.5 / 30), bars.center.dy));
      await tester.pump();
      expect(tester.widget<Text>(find.byKey(TrackerChart.readoutKey)).data, 'LAST 30 DAYS');
      await conn.disconnect();
    });
  });

  group('routines', () {
    testWidgets('each card renders the channel strings verbatim', (tester) async {
      final (client, conn, _) =
          await opened(tester, shelfState('routines', routines: routinesBody));
      await pumpPanel(tester, client);

      expect(find.text('Good night'), findsOneWidget);
      expect(find.text('“Good night”'), findsOneWidget);
      expect(find.text('“bedtime”'), findsOneWidget);
      expect(find.text('“I\'m off”'), findsOneWidget);
      expect(
        find.text("Turn off the downstairs lights, set the thermostat to 68, and tell me "
            "what's first on my calendar tomorrow."),
        findsOneWidget,
      );
      expect(find.text('Ran yesterday'), findsOneWidget);
      expect(find.text('Not run yet'), findsOneWidget);
      await conn.disconnect();
    });

    testWidgets('an empty book says what to say', (tester) async {
      final (client, conn, _) =
          await opened(tester, shelfState('routines', routines: emptyRoutines));
      await pumpPanel(tester, client);

      expect(find.text('No routines yet.'), findsOneWidget);
      expect(find.text(emptyRoutines['hint']! as String), findsOneWidget);
      await conn.disconnect();
    });

    testWidgets("Delete reads the routine's own confirmation and pushes its id",
        (tester) async {
      final (client, conn, fake) =
          await opened(tester, shelfState('routines', routines: routinesBody));
      await pumpPanel(tester, client);

      await tester.tap(find.byKey(RoutinesShelfBody.deleteKey(5)));
      await tester.pumpAndSettle();
      expect(find.text('Delete the “Leaving the house” routine? This can\'t be undone.'),
          findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(anyPushOf(fake, 'delete_routine'), isFalse);

      await tester.tap(find.byKey(RoutinesShelfBody.deleteKey(5)));
      await tester.pumpAndSettle();
      fake.sent.clear();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(lastPush(fake), ['panel:books:henry', 'delete_routine', {'id': 5}]);
      await conn.disconnect();
    });

    testWidgets('a routine deleted elsewhere disappears on the next push', (tester) async {
      final (client, conn, fake) =
          await opened(tester, shelfState('routines', routines: routinesBody));
      await pumpPanel(tester, client);
      expect(find.byKey(RoutinesShelfBody.cardKey(6)), findsOneWidget);

      fake.ctrl.foreign.sink.add(shelfFrame(shelfState('routines', routines: {
        ...routinesBody,
        'items': (routinesBody['items']! as List).take(2).toList(),
      })));
      await tester.pumpAndSettle();
      expect(find.byKey(RoutinesShelfBody.cardKey(6)), findsNothing);
      await conn.disconnect();
    });
  });
}
