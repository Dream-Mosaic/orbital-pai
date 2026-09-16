import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/meridian/orb_painter.dart';
import 'package:orbital_pai/meridian/orb_state.dart';
import 'package:orbital_pai/meridian/orb_tuning.dart';

class Rec {
  Rec(this.method, this.args);
  final String method;
  final List<Object?> args;
}

/// A Canvas that records draw calls instead of rasterising them. `paint` is a
/// pure function of (state, t, ringPhase, level, presence, size), so pinning
/// t + level (and advancing a fixed number of fixed-dt frames for ringPhase)
/// makes every radius and rect below exactly predictable from orb.js's
/// formulas.
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

  /// [advance] is seconds of frames to run BEFORE pinning t and level — the
  /// line is gated on `presence`, which only exists after the frame has been
  /// advanced. Pinning happens last so `paint` stays a pure function of
  /// (state, t, ringPhase, level, presence, size).
  RecordingCanvas paintAt(OrbState state,
      {double t = 0.0, double level = 0.0, double advance = 0.0}) {
    final frame = OrbFrame();
    frame.state = state;
    for (var i = 0; i < (advance * 60).round(); i++) {
      frame.advance(1 / 60);
    }
    frame.debugT = t;
    frame.debugSetLevel(level);
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

  /// Where halo `i` is centred for a given ring phase.
  ///
  /// Derived from [kRingDrift] rather than written out as a literal on
  /// purpose: a literal would pin this test to today's 0.045 and go on passing
  /// if the constant were re-tuned while the painter stopped reading it. What
  /// is being asserted is the RELATIONSHIP — the shader's `haloField` drift,
  /// which the fallback has to reproduce or the two renderers diverge on any
  /// device where the shader fails to load.
  Offset haloCenter(int i, double ringPhase) => const Offset(cx, cy) +
      Offset(
        kRingDrift * r0 * math.sin(ringPhase + i * 2.1),
        kRingDrift * r0 * math.cos(ringPhase * 0.83 + i * 1.7),
      );

  test('halo radii and drifted centres at ringPhase=0, t=0, level=0', () {
    final c = paintAt(OrbState.listening);
    final radii = c.of('drawCircle').map((r) => r.args[1] as double).toList();
    final centers = c.of('drawCircle').map((r) => r.args[0] as Offset).toList();
    // 3 halos, then the contact glow, then the rim.
    expect(radii, hasLength(5));
    for (var i = 0; i < 3; i++) {
      // orb.js: spread + sin(phase*1.3 + i*1.4) * R * 0.025
      //         * BREATHE * (1 + level).
      // The sine term does NOT vanish at phase 0 for i=1,2 — literals here
      // rather than the kBreathe constant so a re-tune of it fails this test,
      // which is the point of "ported verbatim, do not re-tune".
      final expected =
          r0 * (1.06 + i * 0.17) + math.sin(i * 1.4) * r0 * 0.025 * 1.05;
      expect(radii[i], closeTo(expected, 1e-9), reason: 'halo $i radius');
      // The rings ORBIT: even at phase 0 each one is already off-centre, and
      // i=0's cos(0)=1 puts it a full kRingDrift below the sphere's centre.
      final want = haloCenter(i, 0.0);
      expect(centers[i].dx, closeTo(want.dx, 1e-9), reason: 'halo $i cx');
      expect(centers[i].dy, closeTo(want.dy, 1e-9), reason: 'halo $i cy');
    }
    expect(radii[3], closeTo(r0, 1e-9)); // contact glow at R
    expect(radii[4], closeTo(r0, 1e-9)); // rim at R
    // Only the rings drift. The glow and the rim belong to the sphere.
    expect(centers[3], const Offset(cx, cy));
    expect(centers[4], const Offset(cx, cy));
  });

  test('the rings orbit while listening and are frozen while ambient', () {
    List<Offset> haloCentersAfter(OrbState state, double seconds) => paintAt(
          state,
          advance: seconds,
        ).of('drawCircle').take(3).map((r) => r.args[0] as Offset).toList();

    final still = haloCentersAfter(OrbState.listening, 0.0);
    final orbited = haloCentersAfter(OrbState.listening, 1.0);
    for (var i = 0; i < 3; i++) {
      expect(orbited[i], isNot(still[i]), reason: 'halo $i must orbit');
      // Not merely different — different by exactly the phase a second of
      // listening buys, which is what ties the painter to the cadence knob.
      final want = haloCenter(i, kRingSpeedListening);
      expect(orbited[i].dx, closeTo(want.dx, 1e-6), reason: 'halo $i cx');
      expect(orbited[i].dy, closeTo(want.dy, 1e-6), reason: 'halo $i cy');
    }

    // A wall device at rest must not animate: ambient's ring speed is 0, so a
    // second of frames leaves every centre exactly where phase 0 put it.
    final ambient = haloCentersAfter(OrbState.ambient, 1.0);
    for (var i = 0; i < 3; i++) {
      expect(ambient[i], haloCenter(i, 0.0), reason: 'ambient halo $i');
    }
  });

  test('level and t drive the radii (a static orb would pass the above)', () {
    final still = paintAt(OrbState.listening);
    final moved = paintAt(OrbState.listening, t: 1.0, level: 0.5);
    final a = still.of('drawCircle').map((r) => r.args[1] as double).toList();
    final b = moved.of('drawCircle').map((r) => r.args[1] as double).toList();
    // The halo WOBBLE runs on ringPhase now, not t, so level is what moves a
    // halo radius here; t reaches the rim through `breathe` below.
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

  test('the line is drawn where PRESENCE is, and nowhere else', () {
    // Two paths per present frame: the gradient-filled body and the blurred
    // outline traced around it.
    expect(paintAt(OrbState.speaking, advance: 0.5).of('drawPath'),
        hasLength(2));
    expect(paintAt(OrbState.thinking, advance: 0.5).of('drawPath'),
        hasLength(2), reason: 'thinking has no audio but still has a line');
    // LISTENING is in this list deliberately. The line is Henry's half of the
    // conversation; a line over the user's own speech competes with the live
    // transcript, which is what they are actually reading while they talk.
    // `listening` remains audio-REACTIVE in shape (halos, glow, breathe), but
    // nothing feeds that target in production today — the playback poll is its
    // only writer and it stops at the end of `speaking` — so on a device the
    // level decays to zero here rather than pulsing.
    for (final s in [
      OrbState.idle,
      OrbState.ambient,
      OrbState.listening,
    ]) {
      expect(paintAt(s, advance: 0.5).of('drawPath'), isEmpty,
          reason: '$s must not draw a line');
    }
    // And an un-advanced speaking frame draws nothing either: presence starts
    // at zero and fades, so the gate is genuinely presence and not the state.
    expect(paintAt(OrbState.speaking).of('drawPath'), isEmpty,
        reason: 'presence starts at 0 — the line fades in, it does not cut in');
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
