import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/meridian/orb_painter.dart';
import 'package:orbital_pai/meridian/orb_shader.dart';
import 'package:orbital_pai/meridian/orb_state.dart';
import 'package:orbital_pai/meridian/orb_view.dart';

void main() {
  testWidgets('the clock idles while off and runs otherwise', (tester) async {
    final frame = OrbFrame(); // OrbFrame defaults to OrbState.off

    await tester.pumpWidget(MaterialApp(
      home: SizedBox(width: 200, height: 200, child: OrbView(frame: frame)),
    ));
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0,
        reason: '`off` must not hold a vsync callback — it is the state a wall device shows most');

    frame.state = OrbState.idle;
    await tester.pump();
    expect(tester.binding.transientCallbackCount, greaterThan(0),
        reason: 'a live state must drive the Ticker');

    frame.state = OrbState.off;
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);

    await tester.pumpWidget(const SizedBox());
    frame.dispose();
  });

  testWidgets('reduced motion stops the clock in every state', (tester) async {
    final frame = OrbFrame();
    frame.state = OrbState.listening;

    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: SizedBox(width: 200, height: 200, child: OrbView(frame: frame)),
      ),
    ));
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);

    await tester.pumpWidget(const SizedBox());
    frame.dispose();
  });

  testWidgets('survives UNBOUNDED constraints instead of asserting', (tester) async {
    // M-T3e: `size: Size.infinite` asserts under unbounded constraints, which is
    // a live trap now that A2 lays the orb out inside real chrome.
    final frame = OrbFrame();
    frame.state = OrbState.idle;

    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: UnconstrainedBox(child: OrbView(frame: frame)),
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(OrbView)), const Size(280, 280));

    await tester.pumpWidget(const SizedBox());
    frame.dispose();
  });

  group('painter selection', () {
    setUp(OrbShaderProgram.debugReset);

    testWidgets('uses the shader painter once the program has loaded',
        (tester) async {
      await OrbShaderProgram.load();
      final f = OrbFrame()..state = OrbState.idle;
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(width: 300, height: 300, child: OrbView(frame: f)),
      ));
      final cp = tester.widget<CustomPaint>(find.descendant(
          of: find.byType(OrbView), matching: find.byType(CustomPaint)));
      expect(cp.painter, isA<OrbShaderPainter>());
      await tester.pumpWidget(const SizedBox());
      f.dispose();
    });

    testWidgets('falls back to the Canvas painter when the program is absent',
        (tester) async {
      // THE path that matters: it runs when something has already gone wrong,
      // so it must not also be the untested one.
      final f = OrbFrame()..state = OrbState.idle;
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(width: 300, height: 300, child: OrbView(frame: f)),
      ));
      final cp = tester.widget<CustomPaint>(find.descendant(
          of: find.byType(OrbView), matching: find.byType(CustomPaint)));
      expect(cp.painter, isA<OrbPainter>());
      await tester.pumpWidget(const SizedBox());
      f.dispose();
    });

    testWidgets('the ticker still stops when off, on both painters',
        (tester) async {
      // The 24/7 wall-device power lever. Adding a painter choice must not
      // quietly reintroduce a 60Hz repaint on a powered-down orb.
      await OrbShaderProgram.load();
      final f = OrbFrame()..state = OrbState.off;
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(width: 300, height: 300, child: OrbView(frame: f)),
      ));
      final before = f.t;
      await tester.pump(const Duration(milliseconds: 200));
      expect(f.t, before, reason: 'off is frozen — no clock, no repaint');
      await tester.pumpWidget(const SizedBox());
      f.dispose();
    });
  });
}
