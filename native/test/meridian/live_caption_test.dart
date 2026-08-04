import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/meridian/live_caption.dart';
import 'package:henry_wall/meridian/tokens.dart';

void main() {
  test('the length ladder matches index.js setCaption()', () {
    expect(LiveCaption.startFontSize(10), 25.6); // 1.6rem
    expect(LiveCaption.startFontSize(40), 25.6);
    expect(LiveCaption.startFontSize(41), 19.2); // 1.2rem
    expect(LiveCaption.startFontSize(80), 19.2);
    expect(LiveCaption.startFontSize(81), 15.2); // 0.95rem
  });

  test('a short caption keeps its hero size', () {
    expect(LiveCaption.fitFontSize('hi', 250, 100), 25.6);
  });

  test('a long caption is scaled DOWN to fit, never up', () {
    const long =
        'this is an extremely long live transcript that would spill straight out '
        'of the orb ring and over the detents in the web client, which is exactly '
        'the bug we are here to fix once and for all';
    final size = LiveCaption.fitFontSize(long, 250, 100);
    expect(size, lessThan(LiveCaption.startFontSize(long.length)));
    expect(size, greaterThanOrEqualTo(11.0), reason: 'never below the 11px floor');
  });

  test('a caption that already fits is never scaled UP', () {
    // The ladder is a ceiling, not a target: a 90-char caption starts at 15.2
    // and must stay there even though 25.6 would also fit this generous box.
    final text = 'x' * 90;
    expect(LiveCaption.fitFontSize(text, 4000, 4000), 15.2);
  });

  test('an impossible box floors at 11px instead of looping forever', () {
    final size = LiveCaption.fitFontSize('word ' * 200, 60, 20);
    expect(size, 11.0);
  });

  testWidgets('renders inside its box and never overflows', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Center(
          child: LiveCaption(
            text: 'what is the weather like in edinburgh tomorrow afternoon please',
            width: 250,
            height: 100,
          ),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(LiveCaption)), const Size(250, 100));
    final style = tester.widget<Text>(find.byType(Text)).style!;
    expect(style.color, M.youSoft);
    expect(style.fontWeight, FontWeight.w500);
    expect(style.height, 1.22);
  });

  testWidgets('a very long caption stays within the box', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: LiveCaption(text: 'edinburgh ' * 40, width: 250, height: 100),
        ),
      ),
    ));
    expect(tester.takeException(), isNull,
        reason: 'the web overflowed the ring here — that is the bug being fixed');
    expect(tester.getSize(find.byType(LiveCaption)), const Size(250, 100));
  });

  testWidgets('an empty caption renders nothing visible', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: LiveCaption(text: '', width: 250, height: 100))),
    ));
    expect(find.byType(Text), findsNothing);
  });
}
