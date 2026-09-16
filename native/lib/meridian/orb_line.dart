import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'orb_tuning.dart';

/// Points along the line. Enough to look continuous once curved; far fewer than
/// the 128 the old sample-driven trace needed, because the shape is analytic.
const int _kPoints = 96;

/// Three incommensurate partials. Irrational-ish ratios so the sum never
/// visibly repeats — with harmonic ratios the line would pulse on a loop and
/// read as a screensaver.
const List<double> _kFreq = [1.0, 1.61, 2.73];
const List<double> _kWeight = [0.62, 0.26, 0.12];
const List<double> _kPhaseSpeed = [1.0, 1.37, 0.71];

/// The living line across the orb's core.
///
/// Replaced a scrolling readout of real samples. That needed to know which
/// sample was being heard at every frame, and five rebuilds in a row broke on
/// some version of that question. This needs one number — how loud he is now —
/// where being a hundred milliseconds late is invisible.
///
/// [level] shapes it, [presence] decides whether it is there at all, and [t]
/// keeps it alive when the level is steady.
void drawOrbLine(
  Canvas canvas, {
  required double level,
  required double presence,
  required double t,
  required Color color,
  required double cx,
  required double cy,
  required double halfW,
  required double amp,
}) {
  if (presence <= 0 || amp <= 0) return;

  final lv = level.clamp(0.0, 1.0);
  // A floor under the amplitude, not a multiplier over it: `thinking` has no
  // audio, and a purely level-driven line would be flat and dead exactly when
  // it is meant to be present.
  final a = (kLineRestAmp + (1.0 - kLineRestAmp) * lv) * presence * amp;
  final cycles = kLineCyclesRest + (kLineCyclesLoud - kLineCyclesRest) * lv;
  final speed = kLineSpeedRest + (kLineSpeedLoud - kLineSpeedRest) * lv;

  final top = <Offset>[];
  final bottom = <Offset>[];
  for (var i = 0; i < _kPoints; i++) {
    final f = i / (_kPoints - 1);
    final x = cx - halfW + f * 2 * halfW;
    final taper = math.sin(f * math.pi); // flat at both ends
    var sum = 0.0;
    for (var h = 0; h < _kFreq.length; h++) {
      sum += _kWeight[h] *
          math.sin(2 * math.pi * _kFreq[h] * cycles * f +
              t * speed * _kPhaseSpeed[h]);
    }
    final dy = sum * taper * a;
    top.add(Offset(x, cy - dy));
    bottom.add(Offset(x, cy + dy));
  }

  final path = Path();
  _traceCurve(path, top, moveTo: true);
  _traceCurve(path, bottom.reversed.toList(growable: false), moveTo: false);
  path.close();

  final rect = Rect.fromLTRB(cx - halfW, cy - amp, cx + halfW, cy + amp);
  canvas.drawPath(
    path,
    Paint()
      ..style = PaintingStyle.fill
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          color.withValues(alpha: kWaveFillAlpha * presence),
          color.withValues(alpha: kWaveFillAlpha * 0.4 * presence),
          color.withValues(alpha: kWaveFillAlpha * presence),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(rect),
  );

  canvas.drawPath(
    path,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = color.withValues(alpha: kWaveEdgeAlpha * presence)
      ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 4.0),
  );
}

/// Quadratic through the midpoints — each sample is a CONTROL point, so every
/// corner is rounded in one pass with no extra geometry and none of the
/// overshoot a Catmull-Rom spline adds on a sharp turn.
void _traceCurve(Path path, List<Offset> pts, {required bool moveTo}) {
  if (moveTo) {
    path.moveTo(pts.first.dx, pts.first.dy);
  } else {
    path.lineTo(pts.first.dx, pts.first.dy);
  }
  for (var i = 1; i < pts.length - 1; i++) {
    final mid = Offset(
      (pts[i].dx + pts[i + 1].dx) / 2,
      (pts[i].dy + pts[i + 1].dy) / 2,
    );
    path.quadraticBezierTo(pts[i].dx, pts[i].dy, mid.dx, mid.dy);
  }
  path.lineTo(pts.last.dx, pts.last.dy);
}
