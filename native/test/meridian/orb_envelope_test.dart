import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/meridian/orb_envelope.dart';

/// Records the ops a painter issues, so a test can assert on draw calls
/// without needing pixels (which the spec's spike showed is unreliable for
/// shader-painted content and is overkill here).
class RecordingCanvas implements Canvas {
  final List<String> ops = <String>[];
  final List<Path> paths = <Path>[];

  @override
  void drawPath(Path path, Paint paint) {
    ops.add('drawPath:${paint.style}');
    paths.add(path);
  }

  @override
  noSuchMethod(Invocation invocation) {
    ops.add(invocation.memberName.toString());
    return null;
  }
}

void main() {
  Float32List wave(int n, double v) =>
      Float32List.fromList(List<double>.filled(n, v));

  test('draws a filled body and a stroked outline, in that order', () {
    final c = RecordingCanvas();
    drawOrbEnvelope(c,
        wave: wave(64, 0.5),
        gain: 1.0,
        color: const Color(0xFFFCD34D),
        cx: 100,
        cy: 100,
        halfW: 60,
        amp: 30);
    expect(c.ops, ['drawPath:PaintingStyle.fill', 'drawPath:PaintingStyle.stroke']);
  });

  test('the envelope is symmetric about the centreline', () {
    final c = RecordingCanvas();
    drawOrbEnvelope(c,
        wave: wave(8, 1.0),
        gain: 1.0,
        color: const Color(0xFFFCD34D),
        cx: 100,
        cy: 100,
        halfW: 60,
        amp: 30);
    // A mirrored envelope's bounds must straddle cy evenly. An asymmetric
    // build (e.g. only the top edge emitted) would fail here rather than
    // merely look wrong.
    final b = c.paths.first.getBounds();
    expect(b.top, closeTo(200 - b.bottom, 0.01),
        reason: 'top and bottom must be equidistant from cy=100');
  });

  test('gain scales the drawn height', () {
    Rect boundsAt(double gain) {
      final c = RecordingCanvas();
      drawOrbEnvelope(c,
          wave: wave(8, 0.25),
          gain: gain,
          color: const Color(0xFFFCD34D),
          cx: 100,
          cy: 100,
          halfW: 60,
          amp: 30);
      return c.paths.first.getBounds();
    }

    expect(boundsAt(4.0).height, greaterThan(boundsAt(1.0).height),
        reason: 'auto-gain is what stops quiet speech drawing a squiggle');
  });

  test('a clamped magnitude never exceeds amp', () {
    final c = RecordingCanvas();
    drawOrbEnvelope(c,
        wave: wave(8, 1.0),
        gain: 8.0, // would be 8.0 unclamped
        color: const Color(0xFFFCD34D),
        cx: 100,
        cy: 100,
        halfW: 60,
        amp: 30);
    final b = c.paths.first.getBounds();
    expect(b.height, lessThanOrEqualTo(60.01),
        reason: 'amp is a hard half-height; overshoot would paint outside the sphere');
  });

  test('a degenerate input draws nothing rather than throwing', () {
    for (final (w, a) in [(wave(1, 0.5), 30.0), (wave(64, 0.5), 0.0)]) {
      final c = RecordingCanvas();
      drawOrbEnvelope(c,
          wave: w,
          gain: 1.0,
          color: const Color(0xFFFCD34D),
          cx: 100,
          cy: 100,
          halfW: 60,
          amp: a);
      expect(c.ops, isEmpty);
    }
  });
}
