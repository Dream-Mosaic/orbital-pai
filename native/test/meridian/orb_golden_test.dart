import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/meridian/orb_painter.dart';
import 'package:orbital_pai/meridian/orb_state.dart';

/// A 2x gradient bug shipped in A1 precisely because no test could see pixels.
/// `paint` is pure in (state, t, level, waveform, size), so pinning t and level
/// makes a golden the exact guard that would have caught it — the framing that
/// "the orb is animated, therefore goldens are impossible" does not hold.
///
/// Regenerate deliberately (never to silence a failure you have not explained):
///   flutter test --update-goldens test/meridian/orb_golden_test.dart
///
/// SPEAKING, not listening: the waveform is drawn for speaking only now, and a
/// golden of a state that draws no wave would stop covering the envelope — the
/// most intricate thing on the canvas and the half this golden exists for.
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
    frame.debugT = 1.0;
    frame.debugSetLevel(0.5);
    // Unsigned bucket peaks now, not a signed trace — a rectified carrier under
    // a slow amplitude modulation, which is roughly the shape speech makes.
    frame.waveform = Float32List.fromList(List<double>.generate(
        128,
        (i) =>
            math.sin(i * 0.19).abs() * (0.4 + 0.6 * math.sin(i * 0.031).abs())));
    // Pinned for the same reason as t and level: the auto-gain is a function of
    // audio history, and a golden must be a pure function of its inputs.
    frame.debugSetWaveGain(1.0);

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
