import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/meridian/thread.dart';
import 'package:henry_wall/meridian/thread_model.dart';
import 'package:henry_wall/meridian/tokens.dart';

void main() {
  const width = 384.0;

  Widget host(List<ThreadItem> items, {void Function(int)? onAck}) => MaterialApp(
        home: Scaffold(
          backgroundColor: M.bg,
          body: SizedBox(
            width: width,
            height: 600,
            child: Thread(items: items, glow: M.you, onAck: onAck),
          ),
        ),
      );

  testWidgets('you turns sit on the rail, brain answers in the field',
      (tester) async {
    await tester.pumpWidget(host(const [
      ThreadLine(kind: LineKind.you, label: 'you', text: 'what is the weather'),
      ThreadLine(kind: LineKind.brain, label: 'Henry', text: 'sunny', markdown: true),
    ]));
    expect(find.text('you'), findsOneWidget);
    expect(find.text('henry'), findsOneWidget);

    final youX = tester.getTopLeft(find.text('what is the weather')).dx;
    final brainX = tester.getTopLeft(find.textContaining('sunny')).dx;
    expect(youX, lessThan(brainX),
        reason: 'the rail is left of the spine; the field is right of it');
  });

  testWidgets('speaker labels are lowercase and letterspaced', (tester) async {
    await tester.pumpWidget(host(const [
      ThreadLine(kind: LineKind.brain, label: 'Henry', text: 'hi'),
    ]));
    final style = tester.widget<Text>(find.text('henry')).style!;
    expect(style.fontSize, 8.64); // 0.54rem
    expect(style.letterSpacing, closeTo(2.0736, 1e-6)); // 0.24em
    expect(style.color, M.henry);
  });

  testWidgets('the dots float just left of the spine, as in the web',
      (tester) async {
    // The web resolves the spine's 36% against .log's PADDING box and the
    // lines' 36% against #voice-log's CONTENT box — 12px apart at this width.
    // The visible result is that the nodes sit a few px clear of the rail
    // rather than centred on it. Porting one unified base would close that gap
    // and quietly restyle the transcript.
    await tester.pumpWidget(host(const [
      ThreadLine(kind: LineKind.brain, label: 'Henry', text: 'hi'),
    ]));
    final spine = tester.getRect(find.byKey(const ValueKey('spine')));
    final dot = tester.getRect(find.byKey(const ValueKey('node')));

    expect(dot.right, lessThan(spine.left),
        reason: 'the node must clear the rail, not overlap it');
    expect(spine.left - dot.right, closeTo(3.3, 0.6));
  });

  testWidgets('the divider, metrics and tool chips render their exact strings',
      (tester) async {
    await tester.pumpWidget(host(const [
      ThreadDivider(),
      ThreadToolChip(name: 'get_calendar_events'),
      ThreadToolChip(name: 'get_weather', resolved: true),
      ThreadMetrics(ttfaMs: 555, ttbMs: 3400),
    ]));
    expect(find.text('— earlier —'), findsOneWidget);
    expect(find.text('⚙ checking your calendar…'), findsOneWidget);
    expect(find.text('⚙ checking the weather ✓'), findsOneWidget);
    expect(find.text('⚡ 0.6s · 🧠 3.4s'), findsOneWidget);
  });

  testWidgets('collapsed margins: chips stack tight, lines keep the rhythm',
      (tester) async {
    // Measured between whole items: a body-to-body span would also include the
    // next line's speaker label.
    double gapBetweenItems(WidgetTester t) =>
        t.getRect(find.byKey(const ValueKey('item-1'))).top -
        t.getRect(find.byKey(const ValueKey('item-0'))).bottom;

    await tester.pumpWidget(host(const [
      ThreadLine(kind: LineKind.brain, label: 'Henry', text: 'one'),
      ThreadLine(kind: LineKind.brain, label: 'Henry', text: 'two'),
    ]));
    expect(gapBetweenItems(tester), closeTo(16.8, 0.5),
        reason: '.voice-line margin 1.05rem, collapsed');

    await tester.pumpWidget(host(const [
      ThreadToolChip(name: 'get_weather'),
      ThreadToolChip(name: 'send_email'),
    ]));
    expect(gapBetweenItems(tester), closeTo(0, 0.5),
        reason: '.voice-tool-chip sets no margin — a uniform gap would invent one');

    await tester.pumpWidget(host(const [
      ThreadLine(kind: LineKind.reflex, label: 'Henry', text: 'one moment'),
      ThreadLine(kind: LineKind.reflex, label: 'Henry', text: 'still going'),
    ]));
    expect(gapBetweenItems(tester), closeTo(8.8, 0.5),
        reason: '.who-reflex overrides the rhythm with 0.55rem');

    await tester.pumpWidget(host(const [
      ThreadLine(kind: LineKind.brain, label: 'Henry', text: 'answer'),
      ThreadLine(kind: LineKind.reflex, label: 'Henry', text: 'one moment'),
    ]));
    expect(gapBetweenItems(tester), closeTo(16.8, 0.5),
        reason: 'collapsing takes the LARGER of the two margins, not the newer');
  });

  testWidgets('a thinking line is faint and italic', (tester) async {
    await tester.pumpWidget(host(const [
      ThreadLine(
          kind: LineKind.brain,
          label: 'Henry',
          text: 'Henry: thinking...',
          thinking: true),
    ]));
    final style = tester.widget<Text>(find.text('Henry: thinking...')).style!;
    expect(style.fontStyle, FontStyle.italic);
    expect(style.color!.a, closeTo(0.42, 0.01));
  });

  testWidgets('an offered ack chip is tappable exactly once', (tester) async {
    var acked = 0;
    await tester.pumpWidget(host(
      const [
        ThreadLine(
          kind: LineKind.reminder,
          label: 'reminder',
          text: 'take the bins out',
          ack: AckState.offered,
          ackId: 42,
        ),
      ],
      onAck: (id) {
        expect(id, 42);
        acked++;
      },
    ));
    // .ack-chip is text-transform: lowercase, so the web shows "ack".
    await tester.tap(find.text('ack'));
    expect(acked, 1);

    await tester.pumpWidget(host(const [
      ThreadLine(
        kind: LineKind.reminder,
        label: 'reminder',
        text: 'take the bins out',
        ack: AckState.acked,
        ackId: 42,
      ),
    ]));
    expect(find.text('acked ✓'), findsOneWidget);
    expect(find.text('ack'), findsNothing);
  });

  testWidgets('an acked chip is inert', (tester) async {
    var acked = 0;
    await tester.pumpWidget(host(
      const [
        ThreadLine(
          kind: LineKind.reminder,
          label: 'reminder',
          text: 'done already',
          ack: AckState.acked,
          ackId: 42,
        ),
      ],
      onAck: (_) => acked++,
    ));
    await tester.tap(find.text('acked ✓'));
    expect(acked, 0, reason: 'the web disables the button after the first tap');
  });

  testWidgets('a brain line renders markdown once complete', (tester) async {
    await tester.pumpWidget(host(const [
      ThreadLine(
          kind: LineKind.brain,
          label: 'Henry',
          text: '- milk\n- eggs',
          markdown: true),
    ]));
    expect(find.text('• '), findsNWidgets(2));

    await tester.pumpWidget(host(const [
      ThreadLine(kind: LineKind.brain, label: 'Henry', text: '- milk\n- eggs'),
    ]));
    expect(find.text('• '), findsNothing,
        reason: 'streaming deltas stay plaintext until speak_start');
  });

  testWidgets('every LineKind renders without throwing', (tester) async {
    for (final kind in LineKind.values) {
      await tester.pumpWidget(host([
        ThreadLine(kind: kind, label: kind.name, text: 'body text'),
      ]));
      expect(tester.takeException(), isNull, reason: '$kind');
    }
  });
}
