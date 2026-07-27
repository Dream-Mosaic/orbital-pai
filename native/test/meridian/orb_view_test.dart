import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/meridian/orb_painter.dart';
import 'package:henry_wall/meridian/orb_state.dart';
import 'package:henry_wall/meridian/orb_view.dart';

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
}
