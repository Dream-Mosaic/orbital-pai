import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/meridian/orb_line.dart';

class RecordingCanvas implements Canvas {
  final List<String> ops = <String>[];
  final List<Path> paths = <Path>[];

  @override
  void drawPath(Path path, Paint paint) {
    ops.add('drawPath:${paint.style}');
    paths.add(path);
  }

  @override
  noSuchMethod(Invocation invocation) => null;
}

void main() {
  RecordingCanvas draw({
    double level = 0.0,
    double presence = 1.0,
    double t = 0.0,
    double amp = 30,
  }) {
    final c = RecordingCanvas();
    drawOrbLine(c,
        level: level,
        presence: presence,
        t: t,
        color: const Color(0xFF6EE7B7),
        cx: 100,
        cy: 100,
        halfW: 60,
        amp: amp);
    return c;
  }

  double height(RecordingCanvas c) => c.paths.first.getBounds().height;

  test('draws a filled body and a stroked outline, in that order', () {
    expect(draw(level: 0.5).ops,
        ['drawPath:PaintingStyle.fill', 'drawPath:PaintingStyle.stroke']);
  });

  test('presence 0 draws nothing at all', () {
    expect(draw(level: 1.0, presence: 0.0).ops, isEmpty);
  });

  test('a degenerate amp draws nothing rather than throwing', () {
    expect(draw(level: 1.0, amp: 0).ops, isEmpty);
  });

  test('louder is taller', () {
    expect(height(draw(level: 0.9)), greaterThan(height(draw(level: 0.1))));
  });

  test('louder has MORE CYCLES, not just a taller version of one shape', () {
    // This is what makes the calm line become the busy one. Counting sign
    // changes of the top edge across the width measures it directly; an
    // implementation that only scaled amplitude would score the same at both
    // levels and fail here.
    int crossings(double level) {
      final b = draw(level: level).paths.first;
      final metric = b.computeMetrics().first;
      var count = 0;
      double? prev;
      for (var i = 0; i <= 200; i++) {
        final p = metric.getTangentForOffset(metric.length * i / 400)!.position;
        final d = p.dy - 100;
        if (prev != null && prev * d < 0) count++;
        prev = d;
      }
      return count;
    }

    expect(crossings(0.9), greaterThan(crossings(0.1)));
  });

  test('it is symmetric about the centreline', () {
    final b = draw(level: 0.8).paths.first.getBounds();
    expect(b.top, closeTo(200 - b.bottom, 0.01));
  });

  test('presence scales the drawn height', () {
    expect(height(draw(level: 0.8, presence: 0.3)),
        lessThan(height(draw(level: 0.8, presence: 1.0))));
  });

  test('it moves with t even at a fixed level', () {
    // Without this the line freezes whenever the level is steady — which is
    // most of `thinking`, where there is no audio at all.
    final a = draw(level: 0.3, t: 0.0).paths.first.getBounds();
    final b = draw(level: 0.3, t: 0.7).paths.first.getBounds();
    expect(a == b, isFalse);
  });

  test('never exceeds amp', () {
    // amp is a hard half-height; overshoot paints outside the sphere.
    expect(height(draw(level: 1.0, amp: 30)), lessThanOrEqualTo(60.01));
  });
}
