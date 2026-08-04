import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/meridian/nav.dart';
import 'package:henry_wall/meridian/tokens.dart';

void main() {
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
      expect(find.byIcon(tab.icon), findsOneWidget);
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
    await tester.tap(find.byIcon(MeridianTab.books.icon));
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
        tab: (dotX - tester.getCenter(find.byIcon(tab.icon)).dx).abs(),
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
    expect(style.fontSize, 7.04); // 0.44rem
    expect(style.letterSpacing, closeTo(2.3936, 1e-6));
    expect(style.shadows, MType.engraved);
  });
}
