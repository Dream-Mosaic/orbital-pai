import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/meridian/orb_painter.dart';
import 'package:henry_wall/meridian/orb_state.dart';

class Rec {
  Rec(this.method, this.args);
  final String method;
  final List<Object?> args;
}

/// A Canvas that records draw calls instead of rasterising them. `paint` is a
/// pure function of (state, t, level, waveform, size), so pinning t + level makes
/// every radius and rect below exactly predictable from orb.js's formulas.
class RecordingCanvas implements Canvas {
  final List<Rec> calls = <Rec>[];

  List<Rec> of(String method) =>
      calls.where((c) => c.method == method).toList(growable: false);

  @override
  void drawCircle(Offset c, double radius, Paint paint) =>
      calls.add(Rec('drawCircle', [c, radius, paint]));

  @override
  void drawRect(Rect rect, Paint paint) => calls.add(Rec('drawRect', [rect, paint]));

  @override
  void drawOval(Rect rect, Paint paint) => calls.add(Rec('drawOval', [rect, paint]));

  @override
  void drawPath(ui.Path path, Paint paint) => calls.add(Rec('drawPath', [path, paint]));

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  const size = Size(300, 300);
  const cx = 150.0;
  const cy = 150.0;
  const r0 = 90.0; // min(w, h) * 0.3

  RecordingCanvas paintAt(OrbState state,
      {double t = 0.0, double level = 0.0, Float32List? wave}) {
    final frame = OrbFrame();
    frame.state = state;
    frame.debugT = t;
    frame.debugSetLevel(level);
    if (wave != null) frame.waveform = wave;
    final canvas = RecordingCanvas();
    OrbPainter(frame).paint(canvas, size);
    frame.dispose();
    return canvas;
  }

  test('`off` draws the rim only — no halos, no contact glow, frozen radius', () {
    final c = paintAt(OrbState.off);
    final circles = c.of('drawCircle');
    expect(circles, hasLength(1), reason: '`off` must skip layers 1 and 2 entirely');
    expect(circles.single.args[1], closeTo(r0, 1e-9), reason: 'breathe is 0 while off');
    expect((circles.single.args[2] as Paint).strokeWidth, 1.5);
  });

  test('halo radii match orb.js exactly at t=0, level=0', () {
    final c = paintAt(OrbState.listening);
    final radii = c.of('drawCircle').map((r) => r.args[1] as double).toList();
    // 3 halos, then the contact glow, then the rim.
    expect(radii, hasLength(5));
    for (var i = 0; i < 3; i++) {
      // orb.js: spread + sin(t*1.3 + i*1.4) * R * 0.025 * BREATHE * (1 + level).
      // The sine term does NOT vanish at t=0 for i=1,2 — literals here rather
      // than the kBreathe constant so a re-tune of it fails this test, which is
      // the point of "ported verbatim, do not re-tune".
      final expected =
          r0 * (1.06 + i * 0.17) + math.sin(i * 1.4) * r0 * 0.025 * 1.05;
      expect(radii[i], closeTo(expected, 1e-9), reason: 'halo $i');
    }
    expect(radii[3], closeTo(r0, 1e-9)); // contact glow at R
    expect(radii[4], closeTo(r0, 1e-9)); // rim at R
  });

  test('level and t drive the halo radii (a static orb would pass the above)', () {
    final still = paintAt(OrbState.listening);
    final moved = paintAt(OrbState.listening, t: 1.0, level: 0.5);
    final a = still.of('drawCircle').map((r) => r.args[1] as double).toList();
    final b = moved.of('drawCircle').map((r) => r.args[1] as double).toList();
    expect(b[0], isNot(closeTo(a[0], 1e-6)), reason: 'halos must breathe');
    expect(b[4], greaterThan(a[4]), reason: 'loudness must swell the rim radius');
  });

  test('the core, depth-shadow and specular rects match orb.js', () {
    final c = paintAt(OrbState.listening);
    final rects = c.of('drawRect').map((r) => r.args[0] as Rect).toList();
    expect(rects, hasLength(2));
    expect(rects[0], Rect.fromCircle(center: const Offset(cx, cy), radius: r0));
    expect(rects[1],
        Rect.fromCircle(center: const Offset(cx, cy + r0 * 0.2), radius: r0 * 1.1));

    final oval = c.of('drawOval').single.args[0] as Rect;
    expect(oval.center.dx, closeTo(cx - r0 * 0.28, 1e-9));
    expect(oval.center.dy, closeTo(cy - r0 * 0.34, 1e-9));
    expect(oval.width, closeTo(r0 * 0.88, 1e-9));
    expect(oval.height, closeTo(r0 * 0.6, 1e-9));
  });

  test('the waveform is drawn for reactive states only', () {
    final wave =
        Float32List.fromList(List<double>.generate(64, (i) => math.sin(i * 0.3)));
    expect(paintAt(OrbState.listening, wave: wave).of('drawPath'), hasLength(1));
    expect(paintAt(OrbState.speaking, wave: wave).of('drawPath'), hasLength(1));
    for (final s in [OrbState.idle, OrbState.ambient, OrbState.thinking]) {
      expect(paintAt(s, wave: wave).of('drawPath'), isEmpty,
          reason: '$s must not inherit a frozen trace from the last reactive state');
    }
  });

  test('the specular gradient centre is pre-rotated into the canvas frame', () {
    // orb.js offsets the gradient from the ellipse centre by (-0.04R, -0.06R)
    // and fills under an IDENTITY transform — its `-0.5` is ctx.ellipse's own
    // rotation argument (orb.js:172), which tilts the path only. We produce the
    // same path by rotating the canvas, which also rotates the shader, so the
    // offset has to be pre-rotated by +0.5 rad to cancel it.
    const dx = -0.04, dy = -0.06;
    final rx = dx * math.cos(0.5) - dy * math.sin(0.5);
    final ry = dx * math.sin(0.5) + dy * math.cos(0.5);
    expect(kSpecularGradientCenter.x, closeTo(rx / 0.44, 1e-3));
    expect(kSpecularGradientCenter.y, closeTo(ry / 0.30, 1e-3));

    // And it is genuinely rotated: the naive value (the offset used as-is) is
    // 3.21px away at r=90, which is what shipped before this was pinned.
    const naive = Alignment(dx / 0.44, dy / 0.30);
    final driftX = (kSpecularGradientCenter.x - naive.x) * 0.44 * 90;
    final driftY = (kSpecularGradientCenter.y - naive.y) * 0.30 * 90;
    expect(math.sqrt(driftX * driftX + driftY * driftY), closeTo(3.21, 0.01));
  });
}
