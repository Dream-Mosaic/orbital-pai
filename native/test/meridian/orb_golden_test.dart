import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/meridian/orb_painter.dart';
import 'package:orbital_pai/meridian/orb_state.dart';

/// A 2x gradient bug shipped in A1 precisely because no test could see pixels.
/// `paint` is pure in (state, t, ringPhase, linePhase, level, shapeLevel,
/// presence, size), so pinning t and level makes a golden the exact guard that
/// would have caught it — the framing that "the orb is animated, therefore
/// goldens are impossible" does not hold. (ringPhase and linePhase have no
/// seam; the fixed run of fixed-dt advances below pins them just as exactly,
/// at kRingSpeedSpeaking * 0.5 and kLineSpeedRest * 0.5. debugSetLevel pins
/// shapeLevel alongside the level.)
///
/// Regenerate deliberately (never to silence a failure you have not explained):
///   flutter test --update-goldens test/meridian/orb_golden_test.dart
///
/// SPEAKING, not listening: listening draws no line, and a golden of a state
/// without one would stop covering the line — the most intricate thing on the
/// canvas and the half this golden exists for.
void main() {
  Widget host(OrbFrame frame, Key key) => MaterialApp(
        home: Center(
          child: RepaintBoundary(
            key: key,
            child: Container(
              width: 300,
              height: 300,
              color: const Color(0xFF060710),
              child: CustomPaint(
                painter: OrbPainter(frame),
                size: const Size(300, 300),
              ),
            ),
          ),
        ),
      );

  testWidgets('speaking orb, t=1.0, level=0.5', (tester) async {
    final frame = OrbFrame();
    frame.state = OrbState.speaking;
    // Presence is the one input with no test seam — it exists only as the
    // accumulated result of advancing. Half a second of 60Hz frames puts it at
    // ~0.999 (kLinePresenceSeconds is 0.22), i.e. a fully faded-in line.
    for (var i = 0; i < 30; i++) {
      frame.advance(1 / 60);
    }
    // Pinned AFTER the advances, which would otherwise decay the level toward
    // the (unset, zero) audio target and move the clock — the golden has to be
    // a pure function of its inputs.
    frame.debugT = 1.0;
    frame.debugSetLevel(0.5);

    const key = ValueKey<String>('orb-golden');
    await tester.pumpWidget(host(frame, key));
    await tester.pump();

    await expectLater(
      find.byKey(key),
      matchesGoldenFile('goldens/orb_speaking.png'),
    );

    await tester.pumpWidget(const SizedBox());
    frame.dispose();
  });
}
