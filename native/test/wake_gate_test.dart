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

  test('a gate told it is not bound stays closed even while unlocked', () {
    final g = WakeGate()..onLocked(false);
    expect(g.offer(chunk(320)).send, isTrue);
    g.onBound(false);
    expect(g.offer(chunk(320)).send, isFalse,
        reason: 'a standby device must not stream even when the conversation is unlocked');
  });

  test('bound defaults true so an untold client behaves as today', () {
    expect(WakeGate().offer(chunk(320)).send, isTrue);
  });

  test('regaining bound reopens the gate', () {
    final g = WakeGate()..onBound(false);
    g.onBound(true);
    expect(g.offer(chunk(320)).send, isTrue);
  });

  test('PTT does not override a standby device\'s bound state', () {
    // A standby device's PTT press is a CLAIM, not proof it already holds
    // the conversation — the gate only opens once the server answers with
    // bound: true.
    final g = WakeGate()..onBound(false);
    g.onPttHeld(true);
    expect(g.offer(chunk(320)).send, isFalse);
  });

  test(
      'regaining bound carries the buffered ring as pre-roll — a claiming '
      'PTT press must not lose the speech spoken before the server answers',
      () {
    // A standby PTT press claims the conversation, but the gate stays
    // closed (bound: false) until the server answers. Speech spoken in
    // that window buffers into the ring same as any other closed-gate
    // audio; the false→true transition must flush it ahead of live audio,
    // exactly like a wake detection does.
    final g = WakeGate()..onBound(false);
    g.onPttHeld(true);
    for (var i = 0; i < 5; i++) {
      g.offer(chunk(320));
    }
    g.onBound(true);
    final d = g.offer(chunk(320));
    expect(d.send, isTrue);
    expect(d.preRoll, isNotEmpty,
        reason: 'the claiming utterance\'s opening must reach the server, '
            'not be silently dropped from the ring');
  });

  test('a redundant onBound(true) does not re-flush a stale ring', () {
    // The cold-start path emits two `state` pushes, both `bound: true` —
    // a gate that re-armed the flush on every redundant `true` would hand
    // the server a SECOND, by-then-stale copy of the ring on the next offer.
    final g = WakeGate()..onBound(false);
    for (var i = 0; i < 5; i++) {
      g.offer(chunk(320));
    }
    g.onBound(true);
    final first = g.offer(chunk(320));
    expect(first.preRoll, isNotEmpty, reason: 'sanity: the real transition flushed');

    g.onBound(true); // redundant re-affirmation
    final second = g.offer(chunk(320));
    expect(second.preRoll, isEmpty,
        reason: 'a redundant bound:true must not re-arm a flush of an '
            'already-drained (and stale) ring');
  });
}
