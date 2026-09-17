import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/meridian/live_caption.dart';
import 'package:orbital_pai/meridian/tokens.dart';

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

  group('the pending ellipsis', () {
    // Ink-2 withholds the trailing word or two of a live turn until they are
    // unrevisable, then dumps the tail on `turn.end`. These dots are the whole
    // of the UX answer to that: the gap has to read as "still transcribing"
    // rather than as words the model dropped.

    test('dot opacity stays inside its bounds for a whole cycle', () {
      for (var i = 0; i < 3; i++) {
        for (var step = 0; step <= 40; step++) {
          final o = LiveCaption.dotOpacity(i, step / 40);
          expect(o, inInclusiveRange(0.28, 1.0), reason: 'dot $i at step $step');
        }
      }
    });

    test('the three dots pulse in sequence, a third of a cycle apart', () {
      // Each dot peaks when the phase reaches its own offset.
      expect(LiveCaption.dotOpacity(0, 0.0), closeTo(1.0, 1e-9));
      expect(LiveCaption.dotOpacity(1, 1 / 3), closeTo(1.0, 1e-9));
      expect(LiveCaption.dotOpacity(2, 2 / 3), closeTo(1.0, 1e-9));
      // ...and is at its dimmest when the pulse is elsewhere.
      expect(LiveCaption.dotOpacity(1, 0.0), closeTo(0.28, 1e-9));
      expect(LiveCaption.dotOpacity(2, 0.0), closeTo(0.28, 1e-9));
    });

    test('the cycle wraps: phase 1.0 is phase 0.0', () {
      for (var i = 0; i < 3; i++) {
        expect(LiveCaption.dotOpacity(i, 1.0), closeTo(LiveCaption.dotOpacity(i, 0.0), 1e-9));
      }
    });

    test('three dots cannot knock a caption down a ladder rung', () {
      // The dots are measured so the type never re-steps mid-utterance, but
      // the STARTING rung must still come from the caption alone: a 40-char
      // partial is a 25.6px hero caption, and 40 + 3 dots must not demote it.
      expect(LiveCaption.startFontSize(40), 25.6);
      expect(LiveCaption.startFontSize(43), 19.2,
          reason: 'guards the test below — 43 chars really is a lower rung');
      final boundary = 'x' * 40;
      expect(
        LiveCaption.fitFontSize(
          boundary + LiveCaption.pendingDots,
          4000,
          4000,
          start: LiveCaption.startFontSize(boundary.length),
        ),
        25.6,
      );
    });

    testWidgets('a pending caption renders the dots after the words', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: Center(
            child: LiveCaption(
                text: 'what is th', pending: true, width: 250, height: 100),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      final text = tester.widget<Text>(find.byType(Text));
      expect(text.textSpan!.toPlainText(), 'what is th...');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a settled caption renders no dots', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: Center(child: LiveCaption(text: 'what is th', width: 250, height: 100)),
        ),
      ));
      final text = tester.widget<Text>(find.byType(Text));
      expect(text.textSpan!.toPlainText(), 'what is th');
    });

    testWidgets('the dots actually move', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: Center(
            child: LiveCaption(
                text: 'what is th', pending: true, width: 250, height: 100),
          ),
        ),
      ));
      Color? firstDot() {
        final root = tester.widget<Text>(find.byType(Text)).textSpan! as TextSpan;
        return (root.children!.first as TextSpan).style!.color;
      }

      await tester.pump(const Duration(milliseconds: 1));
      final a = firstDot();
      await tester.pump(const Duration(milliseconds: 300));
      expect(firstDot(), isNot(a), reason: 'a static ellipsis is not the design');
    });

    testWidgets('reduced motion keeps the ellipsis and drops the pulse',
        (tester) async {
      // The ellipsis carries the meaning; only the travelling highlight is
      // decoration, so accessibility settings take the motion, not the message.
      await tester.pumpWidget(const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: Center(
              child: LiveCaption(
                  text: 'what is th', pending: true, width: 250, height: 100),
            ),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 400));
      final root = tester.widget<Text>(find.byType(Text)).textSpan! as TextSpan;
      expect(root.toPlainText(), 'what is th...');
      for (final dot in root.children!.cast<TextSpan>()) {
        expect(dot.style, isNull, reason: 'no per-dot alpha without motion');
      }
    });

    testWidgets('an empty caption is never pending', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: Center(
            child: LiveCaption(text: '', pending: true, width: 250, height: 100),
          ),
        ),
      ));
      expect(find.byType(Text), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('an empty caption renders nothing visible', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: LiveCaption(text: '', width: 250, height: 100))),
    ));
    expect(find.byType(Text), findsNothing);
  });
}
