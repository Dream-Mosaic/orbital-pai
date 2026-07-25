import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/meridian/orb_painter.dart';
import 'package:henry_wall/meridian/orb_state.dart';

void main() {
  test('advance is frozen when off and steady-cadence when thinking', () {
    final f = OrbFrame()..state = OrbState.off;
    f.advance(0.1);
    expect(f.t, 0.0, reason: 'off is frozen');

    f.state = OrbState.thinking;
    f.advance(0.1);
    expect(f.t, closeTo(0.14, 1e-9), reason: 'thinking holds a steady 1.4x cadence');
  });

  test('level smooths toward the audio target once per FRAME, not per chunk', () {
    // orb.js smooths once per requestAnimationFrame: level += (target - level) * 0.2.
    final f = OrbFrame()
      ..state = OrbState.listening
      ..audioTarget = 1.0;
    f.advance(0.016);
    expect(f.level, closeTo(0.2, 1e-9));
    f.advance(0.016);
    expect(f.level, closeTo(0.36, 1e-9));
  });

  test('level decays when leaving a reactive state (never sticks)', () {
    final f = OrbFrame()
      ..state = OrbState.listening
      ..audioTarget = 1.0;
    for (var i = 0; i < 40; i++) {
      f.advance(0.016);
    }
    expect(f.level, greaterThan(0.9));

    f.state = OrbState.thinking; // not audio-reactive
    for (var i = 0; i < 40; i++) {
      f.advance(0.016);
    }
    expect(f.level, lessThan(0.05),
        reason: 'must fall back to 0, not stay stuck at the last loudness');
  });

  test('reactive states quicken with loudness', () {
    final quiet = OrbFrame()
      ..state = OrbState.listening
      ..audioTarget = 0.0;
    quiet.advance(0.1);

    final loud = OrbFrame()
      ..state = OrbState.listening
      ..audioTarget = 1.0;
    loud.advance(0.1);

    // level smooths 0 -> 0.2 first, so speed = 1 + 0.2 * 1.4
    expect(loud.level, closeTo(0.2, 1e-9));
    expect(loud.t, closeTo(0.1 * (1 + 0.2 * 1.4), 1e-9));
    expect(loud.t, greaterThan(quiet.t), reason: 'louder = faster');
  });

  test('thinking ignores the audio target (not audio reactive)', () {
    final a = OrbFrame()..state = OrbState.thinking..audioTarget = 0.0;
    final b = OrbFrame()..state = OrbState.thinking..audioTarget = 1.0;
    a.advance(0.1);
    b.advance(0.1);
    expect(a.t, closeTo(b.t, 1e-9));
    expect(b.level, closeTo(0.0, 1e-9), reason: 'non-reactive states target 0');
  });

  test('advancing and setting fields notifies listeners (drives repaint)', () {
    final f = OrbFrame();
    var notified = 0;
    f.addListener(() => notified++);
    f.state = OrbState.speaking;
    f.waveform = Float32List(8);
    f.advance(0.016);
    expect(notified, 3);
  });

  test('audioTarget must NOT notify (repaint is driven by advance())', () {
    final f = OrbFrame()..state = OrbState.listening;
    var notified = 0;
    f.addListener(() => notified++);
    f.audioTarget = 1.0;
    expect(notified, 0);
  });

  test('off must NOT notify on advance (deliberate 24/7 wall-device power decision)', () {
    final f = OrbFrame()..state = OrbState.off;
    var notified = 0;
    f.addListener(() => notified++);
    f.advance(0.016);
    expect(notified, 0);
  });

  testWidgets('painter renders every state without throwing', (tester) async {
    for (final s in OrbState.values) {
      final f = OrbFrame()
        ..state = s
        ..audioTarget = 0.9
        ..waveform = Float32List.fromList(
            List.generate(64, (i) => (i.isEven ? 0.4 : -0.4)));
      for (var i = 0; i < 10; i++) {
        f.advance(0.016); // let the level rise so the reactive layers are exercised
      }
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 300,
            height: 300,
            child: CustomPaint(painter: OrbPainter(f)),
          ),
        ),
      );
      expect(tester.takeException(), isNull, reason: 'state $s should paint cleanly');
    }
  });

  testWidgets('painter survives a degenerate (zero) size', (tester) async {
    final f = OrbFrame()..state = OrbState.listening;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 0,
          height: 0,
          child: CustomPaint(painter: OrbPainter(f)),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
