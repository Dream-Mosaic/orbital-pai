import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/meridian/orb_painter.dart';
import 'package:henry_wall/meridian/orb_state.dart';

/// A 2x gradient bug shipped in A1 precisely because no test could see pixels.
/// `paint` is pure in (state, t, level, waveform, size), so pinning t and level
/// makes a golden the exact guard that would have caught it — the framing that
/// "the orb is animated, therefore goldens are impossible" does not hold.
///
/// Regenerate deliberately (never to silence a failure you have not explained):
///   flutter test --update-goldens test/meridian/orb_golden_test.dart
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

  testWidgets('listening orb, t=1.0, level=0.5', (tester) async {
    final frame = OrbFrame();
    frame.state = OrbState.listening;
    frame.debugT = 1.0;
    frame.debugSetLevel(0.5);
    frame.waveform =
        Float32List.fromList(List<double>.generate(128, (i) => math.sin(i * 0.19)));

    const key = ValueKey<String>('orb-golden');
    await tester.pumpWidget(host(frame, key));
    await tester.pump();

    await expectLater(
      find.byKey(key),
      matchesGoldenFile('goldens/orb_listening.png'),
    );

    await tester.pumpWidget(const SizedBox());
    frame.dispose();
  });
}
