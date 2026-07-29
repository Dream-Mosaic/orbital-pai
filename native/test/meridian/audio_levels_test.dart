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

  group('PcmRing', () {
    test('the newest sample lands at the end of the window', () {
      final r = PcmRing(capacity: 8);
      r.write(pcm([1000, 2000, 3000, 4000]));
      final out = Float32List(4);
      r.readInto(out, end: r.written, window: 4);
      expect(out.last, closeTo(4000 / 32768.0, 1e-6));
      expect(out.first, closeTo(1000 / 32768.0, 1e-6));
    });

    test('a window reaching before the start of the stream pads with silence', () {
      final r = PcmRing(capacity: 8);
      r.write(pcm([1000, 2000]));
      final out = Float32List(4);
      r.readInto(out, end: r.written, window: 4);
      expect(out[0], 0.0);
      expect(out[1], 0.0);
      expect(out[2], closeTo(1000 / 32768.0, 1e-6));
      expect(out[3], closeTo(2000 / 32768.0, 1e-6));
    });

    test('samples older than the capacity read as silence, not as stale audio', () {
      final r = PcmRing(capacity: 4);
      r.write(pcm([1, 2, 3, 4, 5, 6]));
      final out = Float32List(4);
      r.readInto(out, end: r.written, window: 4);
      expect(out.first, closeTo(3 / 32768.0, 1e-6));
      expect(out.last, closeTo(6 / 32768.0, 1e-6));
      // The evicted 1 and 2 must not reappear when the window reaches back for them.
      final older = Float32List(6);
      r.readInto(older, end: r.written, window: 6);
      expect(older[0], 0.0);
      expect(older[1], 0.0);
      expect(older[2], closeTo(3 / 32768.0, 1e-6));
    });

    test('a write spanning the wrap point stays in order', () {
      final r = PcmRing(capacity: 4);
      r.write(pcm([1, 2, 3]));
      r.write(pcm([4, 5])); // wraps
      final out = Float32List(4);
      r.readInto(out, end: r.written, window: 4);
      expect(out.first, closeTo(2 / 32768.0, 1e-6));
      expect(out.last, closeTo(5 / 32768.0, 1e-6));
    });

    test('reads are addressed absolutely, so an earlier end sees earlier audio', () {
      final r = PcmRing(capacity: 16);
      r.write(pcm([10, 20, 30, 40, 50, 60, 70, 80]));
      final a = Float32List(2);
      final b = Float32List(2);
      r.readInto(a, end: 4, window: 2); // samples 30,40
      r.readInto(b, end: 8, window: 2); // samples 70,80
      expect(a.last, closeTo(40 / 32768.0, 1e-6));
      expect(b.last, closeTo(80 / 32768.0, 1e-6));
    });

    test('written is the absolute sample clock, not a byte count', () {
      final r = PcmRing(capacity: 16);
      r.write(pcm([1, 2, 3]));
      expect(r.written, 3);
      r.write(pcm([4]));
      expect(r.written, 4);
    });

    test('preserves sign (a signed/unsigned misread would flip it)', () {
      final r = PcmRing(capacity: 4);
      r.write(pcm([-30000, -30000, -30000, -30000]));
      final out = Float32List(4);
      r.readInto(out, end: r.written, window: 4);
      expect(out.every((v) => v < 0), isTrue);
    });

    test('clear() empties the window and resets the clock', () {
      final r = PcmRing(capacity: 4);
      r.write(pcm([9000, 9000]));
      r.clear();
      expect(r.written, 0);
      final out = Float32List(4);
      r.readInto(out, end: 0, window: 4);
      expect(out.every((v) => v == 0.0), isTrue);
    });

    test('averages each bucket when the window is wider than the output', () {
      final r = PcmRing(capacity: 1024);
      // A ramp, not an alternating signal: averaging alternating samples yields
      // zeros, which would pass no matter what the bucketing did.
      r.write(pcm(List.generate(1024, (i) => i * 16)));
      final out = Float32List(128);
      r.readInto(out, end: r.written, window: 1024);
      expect(out.length, 128);
      // Last bucket = samples 1016..1023 -> mean 16312.
      expect(out.last, closeTo(16312 / 32768.0, 1e-6));
      expect(out.first, closeTo(56 / 32768.0, 1e-6));
    });
  });
}
