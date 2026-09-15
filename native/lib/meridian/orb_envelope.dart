import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'orb_tuning.dart';

/// Append [pts] to [path] as a quadratic curve through their midpoints.
///
/// Each interior point is a CONTROL point, so the curve passes through the
/// midpoints between them and never through the samples themselves — which is
/// exactly what rounds the corners. The first and last points are kept exact so
/// the envelope still starts and ends on the centreline where the taper puts
/// it, rather than drifting off it.
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

/// Live waveform across the orb's core as a MIRRORED, FILLED envelope,
/// tapered at both ends, with a soft glowing outline.
///
/// Extracted from OrbPainter so the shader painter and the frozen fallback
/// draw an identical wave. They must not drift: the fallback exists to look
/// like the app when the shader is unavailable, and a wave that differs
/// between them would make that failure MORE confusing, not less.
///
/// Values in [wave] are unsigned bucket peaks (see PcmRing.readInto), and
/// [gain] is the auto-gain scalar. Draws exactly two paths.
void drawOrbEnvelope(
  Canvas canvas, {
  required Float32List wave,
  required double gain,
  required Color color,
  required double cx,
  required double cy,
  required double halfW,
  required double amp,
}) {
  final n = wave.length;
  if (n < 2 || amp <= 0) return;

  final top = <Offset>[];
  final bottom = <Offset>[];
  for (var i = 0; i < n; i++) {
    final f = i / (n - 1);
    final x = cx - halfW + f * (2 * halfW);
    final edge = math.sin(f * math.pi); // taper both ends
    var m = wave[i] * gain;
    if (m > 1.0) m = 1.0;
    if (m < 0.0) m = 0.0;
    // Below 1.0 this LIFTS the mid-range, so a soft syllable still reads
    // instead of hugging the centreline.
    final dy = math.pow(m, kWaveCurve).toDouble() * amp * edge;
    top.add(Offset(x, cy - dy));
    bottom.add(Offset(x, cy + dy));
  }

  // Curved, not a polygon. 128 straight segments meeting at hard corners is
  // the other half of what read as "spikey" — even a smooth envelope looks
  // jagged when every sample is a vertex.
  final path = Path();
  _traceCurve(path, top, moveTo: true);
  _traceCurve(path, bottom.reversed.toList(growable: false), moveTo: false);
  path.close();

  // Fill: brightest at the two edges of the band, thinner through the middle,
  // so the envelope reads as a hollow-ish ribbon rather than a solid slab.
  final rect = Rect.fromLTRB(cx - halfW, cy - amp, cx + halfW, cy + amp);
  canvas.drawPath(
    path,
    Paint()
      ..style = PaintingStyle.fill
      // Kept as LinearGradient.createShader, byte-for-byte what OrbPainter
      // used. This extraction's whole safety argument is that it changes
      // nothing, and `orb_listening.png` is the proof — an equivalent-but-
      // differently-constructed gradient risks a sub-pixel shift that would
      // read as a golden failure with no real cause.
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          color.withValues(alpha: kWaveFillAlpha),
          color.withValues(alpha: kWaveFillAlpha * 0.4),
          color.withValues(alpha: kWaveFillAlpha),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(rect),
  );

  canvas.drawPath(
    path,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = color.withValues(alpha: kWaveEdgeAlpha)
      // _sigma(8) in orb_painter.dart: Canvas 2D shadowBlur b ~= sigma b/2.
      ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 4.0),
  );
}
