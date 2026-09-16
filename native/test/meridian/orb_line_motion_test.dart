import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/meridian/orb_line.dart';
import 'package:orbital_pai/meridian/orb_painter.dart';
import 'package:orbital_pai/meridian/orb_state.dart';

/// The line's MOTION, as opposed to `orb_line_test.dart`'s single-frame shape.
///
/// Everything here compares one frame against the next, because that is the
/// only place the defect this file exists for was visible. `orb_line_test.dart`
/// and the golden both pin the phase and the level independently and never move
/// the level ACROSS frames at a large clock value — which is why seven reviews'
/// worth of tests watched the line turn to static during speech and saw a
/// perfectly good waveform.
class RecordingCanvas implements Canvas {
  final List<Path> paths = <Path>[];

  @override
  void drawPath(Path path, Paint paint) => paths.add(path);

  @override
  noSuchMethod(Invocation invocation) => null;
}

const double _amp = 30.0;
const double _halfW = 108.0;
const int _grid = 33;

/// The top edge's y at [_grid] x positions evenly spaced across the line.
///
/// The drawn path is the top edge forward and then the bottom edge reversed;
/// the two are exact mirror images and the segments joining them are
/// zero-length (the taper is 0 at both ends), so the first half of the arc
/// length is precisely the top edge. Sampled densely by arc length and then
/// resampled onto a fixed x grid, because arc length is not a stable
/// coordinate between two frames of different shape and "the same point" has
/// to mean the same x.
List<double> _topEdge(Path body) {
  final metric = body.computeMetrics().first;
  final half = metric.length / 2;
  final xs = <double>[];
  final ys = <double>[];
  for (var i = 0; i <= 600; i++) {
    final p = metric.getTangentForOffset(half * i / 600)!.position;
    if (xs.isNotEmpty && p.dx <= xs.last) continue; // x is strictly increasing
    xs.add(p.dx);
    ys.add(p.dy);
  }
  final out = <double>[];
  for (var g = 0; g < _grid; g++) {
    final x = xs.first + (xs.last - xs.first) * g / (_grid - 1);
    var j = 1;
    while (j < xs.length - 1 && xs[j] < x) {
      j++;
    }
    final u = (x - xs[j - 1]) / (xs[j] - xs[j - 1]);
    out.add(ys[j - 1] + (ys[j] - ys[j - 1]) * u);
  }
  return out;
}

List<double> _sample({
  required double level,
  required double shapeLevel,
  required double presence,
  required double phase,
}) {
  final c = RecordingCanvas();
  drawOrbLine(c,
      level: level,
      shapeLevel: shapeLevel,
      presence: presence,
      phase: phase,
      color: const Color(0xFF6EE7B7),
      cx: 150,
      cy: 150,
      halfW: _halfW,
      amp: _amp);
  return _topEdge(c.paths.first);
}

/// Exactly what both painters pass. If this drifts from them the whole file
/// stops testing the shipped line.
List<double> _sampleFrame(OrbFrame f) => _sample(
      level: f.level,
      shapeLevel: f.shapeLevel,
      presence: f.presence,
      phase: f.linePhase,
    );

double _maxMove(List<double> a, List<double> b, {int from = 0, int? to}) {
  var worst = 0.0;
  for (var g = from; g < (to ?? _grid); g++) {
    worst = math.max(worst, (b[g] - a[g]).abs());
  }
  return worst;
}

void main() {
  /// Runs a syllable and its decay tail and reports the largest movement of
  /// any point on the top edge between two CONSECUTIVE frames.
  ///
  /// The tail is the interesting part: the level is moving on every one of its
  /// frames (a release step is ~0.07 at these levels), which is the condition
  /// the defect needed and the condition most of real speech is in.
  double tailScramble({required double uptimeSeconds}) {
    final f = OrbFrame()..state = OrbState.speaking;
    for (var i = 0; i < (uptimeSeconds * 60).round(); i++) {
      f.advance(1 / 60);
    }
    f.audioTarget = 0.6;
    for (var i = 0; i < 20; i++) {
      f.advance(1 / 60);
    }
    f.audioTarget = 0.0;
    var worst = 0.0;
    var prev = _sampleFrame(f);
    for (var i = 0; i < 30; i++) {
      f.advance(1 / 60);
      final now = _sampleFrame(f);
      worst = math.max(worst, _maxMove(prev, now));
      prev = now;
    }
    f.dispose();
    return worst;
  }

  test('the line stays coherent while the level moves, at ANY uptime', () {
    // THE regression test for the phase-integration defect. Before the fix the
    // rendered phase was `t * speed(level)`, a product of the accumulated
    // clock and the current level, so d(phase)/d(level) grew without bound as
    // the app stayed up: at ten minutes a single release frame rotated the
    // line by tens of radians. The spatial term had the same disease from t=0,
    // anchored at the left end and driven at VU speed.
    //
    // Both show up here as one number: how far a point on the line can move in
    // 1/60s. A coherent line moves by its amplitude change plus a fraction of
    // a radian of phase; a scrambled one moves by its whole height.
    final fresh = tailScramble(uptimeSeconds: 0.0);
    final aged = tailScramble(uptimeSeconds: 600.0);

    expect(aged, lessThan(0.15 * _amp),
        reason: 'after ten minutes of uptime the line must still be a '
            'waveform, not spatial static');
    expect(fresh, lessThan(0.15 * _amp),
        reason: 'and the same on a fresh launch — the left-anchored spatial '
            'term broke this one too');
    // Uptime must not enter into it AT ALL. This is the assertion that is
    // specifically about integration: any reintroduced `t * level` term makes
    // the aged number diverge from the fresh one no matter how the absolute
    // bound above is set.
    expect(aged, lessThan(fresh * 1.5 + 0.01 * _amp),
        reason: 'the line must behave identically ten minutes in — a fresh '
            'launch looking fine is exactly the trap');
  });

  test('amplitude answers a syllable at once; the SHAPE does not', () {
    // The two must not collapse into one time constant. Height is VU-fast so a
    // syllable lands on the frame it arrives; the cycle count is ~0.68s so the
    // waveform does not redraw itself underneath that height.
    final f = OrbFrame()..state = OrbState.speaking;
    for (var i = 0; i < 40; i++) {
      f.advance(1 / 60); // presence up, level and shape at rest
    }
    final before = _sampleFrame(f);
    final heightBefore = before.reduce(math.min);

    f.audioTarget = 0.9;
    f.advance(1 / 60); // ONE frame
    final after = _sampleFrame(f);

    expect(f.level, greaterThan(0.3),
        reason: 'one attack frame is most of the way there');
    expect(f.shapeLevel, lessThan(0.1),
        reason: 'the shape follower has barely noticed');
    // Taller, immediately: the topmost point is further above the centreline.
    expect(after.reduce(math.min), lessThan(heightBefore - 0.15 * _amp),
        reason: 'a syllable must make the line taller on the frame it lands');
    f.dispose();
  });

  test('a change in the cycle count fans out from the MIDDLE, not the left',
      () {
    // Pins the centred spatial term. With `f` rather than `f - 0.5` the left
    // end is a fixed point of a cycles change and the right end swings through
    // the whole of it, so the line accordions off one side.
    const a = 0.2, b = 0.5;
    final lo = _sample(level: 0.5, shapeLevel: a, presence: 1.0, phase: 1.1);
    final hi = _sample(level: 0.5, shapeLevel: b, presence: 1.0, phase: 1.1);
    const mid = _grid ~/ 2;
    final left = _maxMove(lo, hi, from: 0, to: mid);
    final right = _maxMove(lo, hi, from: mid, to: _grid);
    expect(left, greaterThan(0.2 * right),
        reason: 'the left half must move comparably to the right');
    expect(right, greaterThan(0.2 * left),
        reason: 'and the right half comparably to the left');
  });
}
