import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/meridian/audio_levels.dart';

/// Build PCM16LE mono bytes from int16 samples.
Uint8List pcm(List<int> samples) {
  final b = BytesBuilder();
  for (final s in samples) {
    b.addByte(s & 0xFF);
    b.addByte((s >> 8) & 0xFF);
  }
  return b.toBytes();
}

void main() {
  test('silence is zero', () {
    expect(rmsFromPcm16(pcm(List.filled(256, 0))), 0.0);
  });

  test('empty input is zero, not NaN', () {
    expect(rmsFromPcm16(Uint8List(0)), 0.0);
  });

  test('full-scale square wave clamps to 1.0', () {
    final s = List.generate(256, (i) => i.isEven ? 32767 : -32768);
    expect(rmsFromPcm16(pcm(s)), 1.0);
  });

  test('quiet signal scales by the x3 gain from orb.js', () {
    // constant amplitude 0.1 full-scale -> rms 0.1 -> *3 = 0.3
    final s = List.filled(256, (0.1 * 32768).round());
    expect(rmsFromPcm16(pcm(s)), closeTo(0.3, 0.01));
  });

  test('waveform returns the requested number of points in -1..1', () {
    final s = List.generate(1024, (i) => (math.sin(i / 8) * 32000).round());
    final w = waveformFromPcm16(pcm(s), 128);
    expect(w.length, 128);
    for (final v in w) {
      expect(v, inInclusiveRange(-1.0, 1.0));
    }
    expect(w.any((v) => v.abs() > 0.5), isTrue,
        reason: 'should track the sine');
  });

  test('waveform of silence is flat zero', () {
    final w = waveformFromPcm16(pcm(List.filled(512, 0)), 64);
    expect(w.length, 64);
    expect(w.every((v) => v == 0.0), isTrue);
  });

  test('waveform stretches when input is shorter than the requested points '
      '(no zero-padding)', () {
    final w = waveformFromPcm16(pcm([1000, -1000]), 32);
    expect(w.length, 32);
    const first = 1000 / 32768.0;
    const second = -1000 / 32768.0;
    for (var i = 0; i < 16; i++) {
      expect(w[i], closeTo(first, 1e-9));
    }
    for (var i = 16; i < 32; i++) {
      expect(w[i], closeTo(second, 1e-9));
    }
  });

  test('waveform preserves sample sign (catches a signed/unsigned PCM misread)',
      () {
    final negative = waveformFromPcm16(pcm(List.filled(64, -30000)), 8);
    expect(negative.length, 8);
    for (final v in negative) {
      expect(v, lessThan(0.0));
    }

    final positive = waveformFromPcm16(pcm(List.filled(64, 30000)), 8);
    expect(positive.length, 8);
    for (final v in positive) {
      expect(v, greaterThan(0.0));
    }
  });

  test('waveform with zero requested points returns an empty result', () {
    final w = waveformFromPcm16(pcm(List.filled(64, 1000)), 0);
    expect(w, isEmpty);
  });

  test('waveform does not crash on an odd byte-length input', () {
    final bytes = pcm(List.filled(64, 1000));
    final odd = Uint8List.sublistView(bytes, 0, bytes.length - 1);
    expect(() => waveformFromPcm16(odd, 16), returnsNormally);
  });

  test('LevelSmoother approaches the target at 0.2 per update', () {
    final s = LevelSmoother();
    expect(s.value, 0.0);
    s.update(1.0);
    expect(s.value, closeTo(0.2, 1e-9));
    s.update(1.0);
    expect(s.value, closeTo(0.36, 1e-9));
    s.reset();
    expect(s.value, 0.0);
  });
}
