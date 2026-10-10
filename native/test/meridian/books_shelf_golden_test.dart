import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/connection/app_connection.dart';
import 'package:orbital_pai/meridian/books_details.dart';
import 'package:orbital_pai/meridian/books_panel.dart';
import 'package:orbital_pai/meridian/drawer.dart';
import 'package:orbital_pai/meridian/tokens.dart';
import 'package:orbital_pai/panels/books_client.dart';

import '../support/fake_socket.dart';
import 'books_shelf_fixtures.dart';

/// The Books drawer's collection books and their detail layers, as they sit
/// in the real [MeridianDrawer] on a 360px phone — header, back chevron and
/// all — so the goldens show the page the user actually sees.
///
/// Regenerate deliberately, then LOOK at the PNGs:
///   flutter test --update-goldens test/meridian/books_shelf_golden_test.dart
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final display = FontLoader(kDisplayFamily)
      ..addFont(rootBundle.load('assets/fonts/SpaceGrotesk.ttf'));
    final body = FontLoader(kBodyFamily)..addFont(rootBundle.load('assets/fonts/Inter.ttf'));
    await Future.wait([display.load(), body.load()]);
  });

  const phone = 360.0;
  const key = ValueKey('books-golden');

  Widget app(Widget drawer) => MaterialApp(
        debugShowCheckedModeBanner: false,
        // The panel's own header rows set no family and take the platform
        // default on a device; Inter stands in for it here so they render as
        // words rather than the test font's boxes.
        theme: ThemeData.dark(useMaterial3: true).copyWith(
          scaffoldBackgroundColor: M.bg,
          textTheme: ThemeData.dark().textTheme.apply(fontFamily: kBodyFamily),
        ),
        home: Scaffold(
          backgroundColor: M.bg,
          body: RepaintBoundary(key: key, child: drawer),
        ),
      );

  MeridianDrawer drawer(String title, Widget child, {bool back = false}) => MeridianDrawer(
        title: title,
        animation: const AlwaysStoppedAnimation(1),
        onClose: () {},
        onBack: back ? () {} : null,
        child: child,
      );

  Future<void> size(WidgetTester tester, double height) async {
    tester.view.physicalSize = Size(phone, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  /// The real panel, fed the channel's frame through a fake socket.
  Future<(BooksClient, AppConnection)> client(
      WidgetTester tester, Map<String, Object?> state) async {
    final fake = FakeSocket(joinPushes: {'panel:books:henry': shelfFrame(state)});
    final conn = AppConnection(
      connector: () async => fake.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final c = BooksClient(connection: conn);
    addTearDown(() {
      c.dispose();
      conn.dispose();
    });
    await conn.connect();
    c.open();
    await tester.pump(Duration.zero);
    return (c, conn);
  }

  testWidgets('recipe detail', (tester) async {
    await size(tester, 1080);
    final recipe = BooksState.fromJson(shelfState('recipes', recipes: recipesBody))
        .recipes!
        .find(12);
    await tester.pumpWidget(app(drawer(
      'Recipes',
      RecipeDetailView(recipe: recipe, onDelete: (_) {}),
      back: true,
    )));
    await tester.pump();
    await expectLater(find.byKey(key), matchesGoldenFile('goldens/books_recipe_detail.png'));
  });

  testWidgets('tracker detail', (tester) async {
    await size(tester, 940);
    final tracker = BooksState.fromJson(shelfState('trackers', trackers: trackersBody))
        .trackers!
        .find(7);
    await tester.pumpWidget(app(drawer(
      'Trackers',
      TrackerDetailView(tracker: tracker),
      back: true,
    )));
    await tester.pump();
    await expectLater(find.byKey(key), matchesGoldenFile('goldens/books_tracker_detail.png'));
  });

  testWidgets('tracker detail, a measure in a tight band', (tester) async {
    await size(tester, 640);
    final tracker = BooksState.fromJson(shelfState('trackers', trackers: trackersBody))
        .trackers!
        .find(8);
    await tester.pumpWidget(app(drawer(
      'Trackers',
      TrackerDetailView(tracker: tracker),
      back: true,
    )));
    await tester.pump();
    await expectLater(
        find.byKey(key), matchesGoldenFile('goldens/books_tracker_detail_band.png'));
  });

  testWidgets('tracker detail, a day touched', (tester) async {
    await size(tester, 520);
    final tracker = BooksState.fromJson(shelfState('trackers', trackers: trackersBody))
        .trackers!
        .find(7);
    await tester.pumpWidget(app(drawer(
      'Trackers',
      TrackerDetailView(tracker: tracker),
      back: true,
    )));
    await tester.pump();
    // Touch Oct 7's bar's neighbour, Oct 8 — the 28th of 30 slots.
    final bars = tester.getRect(find.byKey(const ValueKey('tracker-chart-bars')));
    await tester.tapAt(Offset(bars.left + bars.width * (27.5 / 30), bars.center.dy));
    await tester.pump();
    await expectLater(
        find.byKey(key), matchesGoldenFile('goldens/books_tracker_detail_touched.png'));
  });

  testWidgets('routines book', (tester) async {
    await size(tester, 860);
    final (c, conn) = await client(tester, shelfState('routines', routines: routinesBody));
    await tester.pumpWidget(app(drawer('Books', BooksPanelView(client: c))));
    await tester.pump();
    await expectLater(find.byKey(key), matchesGoldenFile('goldens/books_routines.png'));
    await conn.disconnect();
  });

  testWidgets('recipes book', (tester) async {
    await size(tester, 560);
    final (c, conn) = await client(tester, shelfState('recipes', recipes: recipesBody));
    await tester.pumpWidget(
        app(drawer('Books', BooksPanelView(client: c, onOpenRecipe: (_) {}))));
    await tester.pump();
    await expectLater(find.byKey(key), matchesGoldenFile('goldens/books_recipes.png'));
    await conn.disconnect();
  });

  testWidgets('trackers book', (tester) async {
    await size(tester, 480);
    final (c, conn) = await client(tester, shelfState('trackers', trackers: trackersBody));
    await tester.pumpWidget(
        app(drawer('Books', BooksPanelView(client: c, onOpenTracker: (_) {}))));
    await tester.pump();
    await expectLater(find.byKey(key), matchesGoldenFile('goldens/books_trackers.png'));
    await conn.disconnect();
  });

  testWidgets('an empty collection says what to say', (tester) async {
    await size(tester, 420);
    final (c, conn) = await client(tester, shelfState('trackers', trackers: emptyTrackers));
    await tester.pumpWidget(app(drawer('Books', BooksPanelView(client: c))));
    await tester.pump();
    await expectLater(find.byKey(key), matchesGoldenFile('goldens/books_trackers_empty.png'));
    await conn.disconnect();
  });

  testWidgets('the picker sets the collections apart', (tester) async {
    await size(tester, 560);
    final (c, conn) = await client(tester, shelfState('recipes', recipes: recipesBody));
    await tester.pumpWidget(
        app(drawer('Books', BooksPanelView(client: c, onOpenRecipe: (_) {}))));
    await tester.pump();
    await tester.tap(find.byKey(BooksPanelView.switchBookToggleKey));
    await tester.pump();
    await expectLater(find.byKey(key), matchesGoldenFile('goldens/books_picker.png'));
    await conn.disconnect();
  });
}
