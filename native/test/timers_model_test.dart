import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/voice/timers_model.dart';

import 'support/fake_alarm.dart';

Map<String, dynamic> wire(List<Map<String, dynamic>> timers) => {'timers': timers};

Map<String, dynamic> t(int id,
        {String? label, String state = 'running', int duration = 600000, int remaining = 600000}) =>
    {
      'id': id,
      'label': label,
      'state': state,
      'duration_ms': duration,
      'remaining_ms': remaining,
    };

void main() {
  late FakeClock clock;
  late FakeAlarm alarm;
  late TimersModel model;

  setUp(() {
    clock = FakeClock();
    alarm = FakeAlarm();
    model = TimersModel(clock: clock.call, alarm: alarm);
  });
  tearDown(() => model.dispose());

  group('parsing', () {
    test('anchors each timer to the local clock at receipt (no server clock involved)', () {
      model.apply(wire([t(1, label: 'pasta', remaining: 5000, duration: 10000)]));
      final e = model.timers.single;
      expect(e.id, 1);
      expect(e.label, 'pasta');
      expect(e.ringing, isFalse);
      expect(e.duration, const Duration(seconds: 10));
      expect(e.remainingAt(clock()), const Duration(seconds: 5));

      clock.advance(const Duration(seconds: 2));
      expect(e.remainingAt(clock()), const Duration(seconds: 3));
      expect(e.progressAt(clock()), closeTo(0.7, 1e-9));

      clock.advance(const Duration(seconds: 10));
      expect(e.remainingAt(clock()), Duration.zero, reason: 'never negative');
      expect(e.progressAt(clock()), 1.0);
    });

    test('a ringing timer reads zero remaining and full progress', () {
      model.apply(wire([t(2, state: 'ringing', remaining: 0)]));
      final e = model.timers.single;
      expect(e.ringing, isTrue);
      expect(e.remainingAt(clock()), Duration.zero);
      expect(e.progressAt(clock()), 1.0);
    });

    test('malformed entries are skipped, not guessed at', () {
      model.apply({
        'timers': [
          {'id': 'x', 'state': 'running'},
          'junk',
          t(3),
        ],
      });
      expect(model.timers.map((e) => e.id), [3]);
      model.apply(const {});
      expect(model.timers, isEmpty);
    });

    test('the list is immutable', () {
      model.apply(wire([t(1)]));
      expect(() => model.timers.add(model.timers.first), throwsUnsupportedError);
    });
  });

  group('countdown text', () {
    test('m:ss, rounding UP so a running timer never shows 0:00', () {
      expect(formatCountdown(const Duration(minutes: 10)), '10:00');
      expect(formatCountdown(const Duration(minutes: 9, seconds: 41)), '9:41');
      expect(formatCountdown(const Duration(milliseconds: 580200)), '9:41');
      expect(formatCountdown(const Duration(milliseconds: 1)), '0:01');
      expect(formatCountdown(Duration.zero), '0:00');
    });

    test('h:mm:ss from an hour up', () {
      expect(formatCountdown(const Duration(hours: 1, minutes: 5, seconds: 3)), '1:05:03');
      expect(formatCountdown(const Duration(hours: 24)), '24:00:00');
    });
  });

  group('alarm', () {
    test('rings once when a timer turns ringing, keyed by id', () {
      model.apply(wire([t(1)]));
      expect(alarm.starts, 0);

      model.apply(wire([t(1, state: 'ringing', remaining: 0)]));
      expect(alarm.starts, 1);
      expect(model.alarmOn, isTrue);

      // Every device re-pushes on every change; the same ringing id must not re-ring.
      model.apply(wire([t(1, state: 'ringing', remaining: 0), t(2)]));
      expect(alarm.starts, 1);
    });

    test('a second timer going off re-rings', () {
      model.apply(wire([t(1, state: 'ringing', remaining: 0), t(2)]));
      model.apply(wire([t(1, state: 'ringing', remaining: 0), t(2, state: 'ringing', remaining: 0)]));
      expect(alarm.starts, 2);
    });

    test('stops when the server says nothing is ringing any more', () {
      model.apply(wire([t(1, state: 'ringing', remaining: 0)]));
      model.apply(wire([]));
      expect(alarm.sounding, isFalse);
      expect(model.alarmOn, isFalse);
    });

    test('silence(id) stops it at once, unless another timer still rings', () {
      model.apply(wire([t(1, state: 'ringing', remaining: 0), t(2, state: 'ringing', remaining: 0)]));
      model.silence(1);
      expect(alarm.sounding, isTrue, reason: 'timer 2 is still ringing');
      model.silence(2);
      expect(alarm.sounding, isFalse);

      // ...and the server's echo of the still-ringing state does not bring it back.
      model.apply(wire([t(2, state: 'ringing', remaining: 0)]));
      expect(alarm.sounding, isFalse);
    });

    test('is bounded: stops on its own after the cap', () async {
      final capped = TimersModel(
          clock: clock.call, alarm: alarm, alarmCap: const Duration(milliseconds: 30));
      addTearDown(capped.dispose);
      capped.apply(wire([t(1, state: 'ringing', remaining: 0)]));
      expect(alarm.sounding, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(alarm.sounding, isFalse);
      expect(capped.alarmOn, isFalse);
    });

    test('dispose stops it', () {
      model.apply(wire([t(1, state: 'ringing', remaining: 0)]));
      model.dispose();
      expect(alarm.sounding, isFalse);
    });
  });
}
