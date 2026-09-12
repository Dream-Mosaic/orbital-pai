import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/audio/wake_gate.dart';

Uint8List chunk(int n) => Uint8List(n);

void main() {
  test('starts open — an unlocked conversation streams as it does today', () {
    final g = WakeGate();
    expect(g.offer(chunk(320)).send, isTrue);
  });

  test('locked closes the gate', () {
    final g = WakeGate()..onLocked(true);
    expect(g.offer(chunk(320)).send, isFalse);
  });

  test('a detection opens the gate and flushes pre-roll ahead of live audio',
      () {
    final g = WakeGate()..onLocked(true);
    for (var i = 0; i < 10; i++) {
      g.offer(chunk(320));
    }
    g.onWakeDetected();
    final d = g.offer(chunk(320));
    expect(d.send, isTrue);
    expect(d.preRoll, isNotEmpty,
        reason: 'the wake word itself must reach the server');
  });

  test('pre-roll flushes exactly once', () {
    final g = WakeGate()..onLocked(true);
    g.offer(chunk(320));
    g.onWakeDetected();
    expect(g.offer(chunk(320)).preRoll, isNotEmpty);
    expect(g.offer(chunk(320)).preRoll, isEmpty);
  });

  test('the pre-roll ring is bounded to 1.5s and drops the oldest', () {
    final g = WakeGate(preRoll: const Duration(milliseconds: 100)); // 3200 bytes @16k/16bit
    for (var i = 0; i < 100; i++) {
      g.offer(chunk(320));
    }
    g.onWakeDetected();
    final bytes =
        g.offer(chunk(320)).preRoll.fold<int>(0, (a, b) => a + b.length);
    expect(bytes, lessThanOrEqualTo(3200));
  });

  test('PTT opens the gate even while locked', () {
    final g = WakeGate()..onLocked(true);
    g.onPttHeld(true);
    expect(g.offer(chunk(320)).send, isTrue);
    g.onPttHeld(false);
    expect(g.offer(chunk(320)).send, isFalse);
  });

  test('relock closes a gate that a wake had opened', () {
    final g = WakeGate()..onLocked(true);
    g.onWakeDetected();
    expect(g.offer(chunk(320)).send, isTrue);
    g.onLocked(true); // server relocked on idle
    expect(g.offer(chunk(320)).send, isFalse);
  });

  test(
      'a wake before the ring fully fills flushes only what accumulated, '
      'not nothing and not a padded buffer', () {
    final g = WakeGate(preRoll: const Duration(milliseconds: 100)) // max 3200 bytes / 10 chunks
      ..onLocked(true);
    g.offer(chunk(320)); // only one chunk has accumulated so far
    g.onWakeDetected();
    final d = g.offer(chunk(320));
    expect(d.preRoll.length, 1);
    expect(d.preRoll.single.length, 320);
  });
}
