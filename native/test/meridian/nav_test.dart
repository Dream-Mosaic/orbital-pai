import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/meridian/hero_icon.dart';
import 'package:henry_wall/meridian/nav.dart';
import 'package:henry_wall/meridian/tokens.dart';

/// heroicons are SVGs, not IconData, so `find.byIcon` does not apply.
Finder findHero(HeroIcon icon) =>
    find.byWidgetPredicate((w) => w is HeroIconView && w.icon == icon);

void main() {
  // Widget tests substitute a square test font for everything, where every glyph
  // advances exactly one font-size — which makes any width measurement a
  // statement about Ahem, not about the chrome. Load the real display face so
  // the fit assertion below means what it says.
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final loader = FontLoader('Space Grotesk')
      ..addFont(rootBundle.load('assets/fonts/SpaceGrotesk.ttf'));
    await loader.load();
  });

  testWidgets("all five tabs ship, in the web's order", (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: MeridianNav(onTap: (_) {})),
    ));
    expect(MeridianTab.values, [
      MeridianTab.settings,
      MeridianTab.reminders,
      MeridianTab.books,
      MeridianTab.connectors,
      MeridianTab.search,
    ]);
    for (final tab in MeridianTab.values) {
      expect(find.text(tab.label.toUpperCase()), findsOneWidget);
      expect(findHero(tab.icon), findsOneWidget);
    }
  });

  test('each tab carries the phx-value-modal the web uses', () {
    // conversation_live.ex:904-941 — also the ?panel= value.
    expect(MeridianTab.settings.modal, 'settings');
    expect(MeridianTab.reminders.modal, 'reminders');
    expect(MeridianTab.books.modal, 'books');
    expect(MeridianTab.connectors.modal, 'connectors');
    expect(MeridianTab.search.modal, 'search');
  });

  testWidgets('tapping reports the tab', (tester) async {
    final tapped = <MeridianTab>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: MeridianNav(onTap: tapped.add)),
    ));
    await tester.tap(findHero(MeridianTab.books.icon));
    expect(tapped, [MeridianTab.books]);
  });

  testWidgets('the due badge only shows on Reminders, and only when due',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: MeridianNav(onTap: (_) {}, hasDue: false)),
    ));
    expect(find.byKey(const ValueKey('due-dot')), findsNothing);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: MeridianNav(onTap: (_) {}, hasDue: true)),
    ));
    expect(find.byKey(const ValueKey('due-dot')), findsOneWidget);
    final dot = tester.widget<Container>(find.byKey(const ValueKey('due-dot')));
    expect((dot.decoration! as BoxDecoration).color, M.you);

    // ...and it belongs to Reminders, not merely somewhere in the bar. It sits
    // off the station's right edge (as `right: 9px` does in the CSS, where
    // "REMINDERS" is far wider than the 18px bell), so proximity to the bell is
    // the wrong test — nearest-station is the real claim.
    final dotX = tester.getCenter(find.byKey(const ValueKey('due-dot'))).dx;
    final distances = {
      for (final tab in MeridianTab.values)
        tab: (dotX - tester.getCenter(findHero(tab.icon)).dx).abs(),
    };
    final nearest =
        distances.entries.reduce((a, b) => a.value <= b.value ? a : b).key;
    expect(nearest, MeridianTab.reminders);
  });

  testWidgets('labels are engraved at 0.34em tracking', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: MeridianNav(onTap: (_) {})),
    ));
    final style = tester.widget<Text>(find.text('SETTINGS')).style!;
    expect(style.fontSize, 6.4); // 0.44rem, dropped so CONNECTORS fits one line
    expect(style.letterSpacing, closeTo(6.4 * 0.34, 1e-6)); // 0.34em, unchanged
    expect(style.shadows, MType.engraved);
  });

  testWidgets('labels fit one line at phone width, all at one size',
      (tester) async {
    // The emulator screenshot showed "REMINDERS" and "CONNECTORS" wrapping to
    // two lines on a 360px phone. With the real Space Grotesk bundled they fit;
    // FittedBox is the safety net, and a scale below 1 here means it engaged —
    // i.e. one station's label is visibly smaller than its neighbours'.
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: MeridianNav(onTap: (_) {}),
        ),
      ),
    ));

    for (final tab in MeridianTab.values) {
      final label = find.text(tab.label.toUpperCase());
      final box = find.ancestor(of: label, matching: find.byType(FittedBox));
      final outer = tester.getSize(box.first);
      final inner = tester.getSize(label);
      final scale = (outer.width / inner.width).clamp(0.0, 1.0);
      expect(scale, greaterThan(0.88),
          reason: '${tab.label} is shrunk to ${(scale * 100).round()}% — that '
              'reads as a mistake next to its neighbours');
      expect(inner.height, lessThan(14),
          reason: '${tab.label} wrapped to a second line');
    }
  });
}
