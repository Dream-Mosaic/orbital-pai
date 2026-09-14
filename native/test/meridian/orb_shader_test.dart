import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/meridian/orb_painter.dart';
import 'package:orbital_pai/meridian/orb_shader.dart';
import 'package:orbital_pai/meridian/orb_state.dart';

void main() {
  setUp(OrbShaderProgram.debugReset);

  testWidgets('loads the program from the asset bundle', (tester) async {
    await OrbShaderProgram.load();
    expect(OrbShaderProgram.program, isNotNull);
    expect(OrbShaderProgram.shader, isNotNull);
    expect(OrbShaderProgram.failed, isFalse);
  });

  testWidgets('load is idempotent — a second call does not reload', (tester) async {
    await OrbShaderProgram.load();
    final first = OrbShaderProgram.shader;
    await OrbShaderProgram.load();
    expect(identical(OrbShaderProgram.shader, first), isTrue,
        reason: 'the orb rebuilds constantly; reloading per build would be a '
            'per-frame asset decode');
  });

  testWidgets('paints every state without throwing', (tester) async {
    await OrbShaderProgram.load();
    for (final s in OrbState.values) {
      final f = OrbFrame()
        ..state = s
        ..audioTarget = 0.9
        ..waveform = Float32List.fromList(List.generate(64, (i) => 0.4));
      for (var i = 0; i < 10; i++) {
        f.advance(1 / 60);
      }
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 300,
          height: 300,
          child: CustomPaint(
            painter: OrbShaderPainter(f, OrbShaderProgram.shader!),
          ),
        ),
      ));
      expect(tester.takeException(), isNull, reason: 'state $s');
      f.dispose();
    }
  });

  testWidgets('a degenerate size paints nothing rather than throwing',
      (tester) async {
    await OrbShaderProgram.load();
    final f = OrbFrame()..state = OrbState.listening;
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        width: 0,
        height: 0,
        child: CustomPaint(
          painter: OrbShaderPainter(f, OrbShaderProgram.shader!),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
    f.dispose();
  });
}
