import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/meridian/orb_painter.dart';
import 'package:orbital_pai/meridian/orb_shader.dart';
import 'package:orbital_pai/meridian/orb_state.dart';

class _Rec {
  _Rec(this.method, this.args);
  final String method;
  final List<Object?> args;
}

/// A Canvas that records draw calls instead of rasterising them — the same
/// technique `orb_geometry_test.dart` uses for the fallback painter, applied
/// here to the shader painter's Canvas-drawn line. This never touches the
/// shader's rasterised output (the drawRect carrying the shader is recorded,
/// not rendered), so it cannot hang the way a pixel comparison would.
class _RecordingCanvas implements Canvas {
  final List<_Rec> calls = <_Rec>[];

  List<_Rec> of(String method) =>
      calls.where((c) => c.method == method).toList(growable: false);

  @override
  void drawPath(Path path, Paint paint) => calls.add(_Rec('drawPath', [path, paint]));

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

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
        ..audioTarget = 0.9;
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

  testWidgets(
      'the line breathes with t — a regression test for the un-breathing r0 bug',
      (tester) async {
    await OrbShaderProgram.load();

    // Pure function of (state, t, level, presence, size): pinning everything
    // except t isolates exactly the term this test is about.
    Rect fillBounds(double t) {
      // SPEAKING: the line is Henry's half of the conversation, and listening
      // draws none at all — a listening frame here would assert against an
      // empty canvas and pass for the wrong reason.
      final f = OrbFrame()..state = OrbState.speaking;
      // Presence only exists once the frame has been advanced; pin t and level
      // afterwards so the geometry stays a pure function of them.
      for (var i = 0; i < 30; i++) {
        f.advance(1 / 60);
      }
      f.debugT = t;
      f.debugSetLevel(0.5);
      final canvas = _RecordingCanvas();
      OrbShaderPainter(f, OrbShaderProgram.shader!)
          .paint(canvas, const Size(300, 300));
      f.dispose();
      final fills = canvas
          .of('drawPath')
          .where((c) => (c.args[1] as Paint).style == PaintingStyle.fill)
          .toList();
      expect(fills, hasLength(1),
          reason: 'exactly one filled line path per paint');
      return (fills.single.args[0] as Path).getBounds();
    }

    // WIDTH, not the whole rect. The line's own shape is now a function of t
    // (t is its phase), so "the bounds moved" would pass on the un-breathing
    // bug too — it would just be reading the phase. The path spans exactly
    // [cx - halfW, cx + halfW] and halfW is r * 0.72, so the bounds' WIDTH is
    // 1.44r and nothing else: phase-free, and carrying the breathe term alone.
    //
    // Under the bug (`r = side * 0.3`, never breathing) the width is a pure
    // function of (size) and these two are identical. With the fix, `r` carries
    // `kBreathe * (0.015*sin(t*1.6) + level*0.04)`, which varies with t even at
    // a fixed level — about 2px across at r=90.
    final a = fillBounds(0.0);
    final b = fillBounds(1.0);
    expect(b.width, isNot(closeTo(a.width, 0.5)),
        reason: 'the line must sit on the breathing sphere (varies with t), '
            'not the frozen r0 the shader painter used to pass in');
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
