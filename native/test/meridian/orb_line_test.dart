import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/meridian/orb_line.dart';
import 'package:orbital_pai/meridian/orb_tuning.dart';

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
    double? shapeLevel,
    double presence = 1.0,
    double phase = 0.0,
    double amp = 30,
  }) {
    final c = RecordingCanvas();
    drawOrbLine(c,
        level: level,
        // Defaults to `level` so the tests that only care about loudness read
        // as they did: on a real frame the two converge on a steady level.
        shapeLevel: shapeLevel ?? level,
        presence: presence,
        phase: phase,
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

  test('it moves with the phase even at a fixed level', () {
    // Without this the line freezes whenever the level is steady — which is
    // most of `thinking`, where there is no audio at all.
    final a = draw(level: 0.3, phase: 0.0).paths.first.getBounds();
    final b = draw(level: 0.3, phase: 0.7).paths.first.getBounds();
    expect(a == b, isFalse);
  });

  test('a silent line still has height — kLineRestAmp', () {
    // `thinking` has no audio at all, and a mid-utterance tool round drops the
    // level to nothing while Henry is still legitimately speaking. A purely
    // level-driven line would be flat and dead in exactly those moments, which
    // is the whole reason for the rest floor — and it really does reach zero,
    // because the poll settles the target the moment the played head catches
    // `writtenFrames`, on one reading and with no grace period. Without this assertion
    // kLineRestAmp can be set to 0 and the entire file still passes: every
    // other test here either draws at a nonzero level or only counts paths,
    // and a perfectly flat line is still two drawPath calls.
    expect(height(draw(level: 0.0)), greaterThan(0.0),
        reason: 'kLineRestAmp — thinking has no audio and must still show a '
            'living line');
  });

  test('never exceeds amp', () {
    // amp is a hard half-height; overshoot paints outside the sphere.
    expect(height(draw(level: 1.0, amp: 30)), lessThanOrEqualTo(60.01));
  });

  test('at the REAL kWaveAmp the line stays inside the sphere', () {
    // S4 raised kWaveAmp from 0.34 to 0.42 for "more dramatic when he's
    // talking". The shader painter draws the line UNCLIPPED on the argument
    // that its reach stays inside the silhouette, so that argument has to be
    // checked against the constant rather than asserted in a comment. Both
    // painters pass exactly these arguments (cy + r*0.06, halfW r*0.72,
    // amp r*kWaveAmp), so this is the production geometry.
    const r = 90.0;
    const cx = 150.0, cy = 150.0;
    final c = RecordingCanvas();
    drawOrbLine(c,
        level: 1.0,
        shapeLevel: 1.0,
        presence: 1.0,
        phase: 0.0,
        color: const Color(0xFF6EE7B7),
        cx: cx,
        cy: cy + r * 0.06,
        halfW: r * 0.72,
        amp: r * kWaveAmp);

    // The stroke is 2px wide and blurred by 4, so leave the silhouette that
    // much room; the point is that the PATH is nowhere near the edge.
    const margin = 2.0 / 2 + 4.0;
    final metric = c.paths.first.computeMetrics().first;
    var worst = 0.0;
    for (var i = 0; i <= 400; i++) {
      final p = metric.getTangentForOffset(metric.length * i / 400)!.position;
      final d = (p - const Offset(cx, cy)).distance;
      if (d > worst) worst = d;
    }
    expect(worst, lessThanOrEqualTo(r - margin),
        reason: 'the line paints outside the glass');
  });
}
