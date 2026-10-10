import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/meridian/timer_strip.dart';
import 'package:orbital_pai/meridian/tokens.dart';
import 'package:orbital_pai/voice/timers_model.dart';

import '../support/fake_alarm.dart';

TimerEntry entry(int id,
        {String? label,
        bool ringing = false,
        int durationS = 600,
        required Duration deadline}) =>
    TimerEntry(
      id: id,
      label: label,
      ringing: ringing,
      duration: Duration(seconds: durationS),
      deadline: deadline,
    );

void main() {
  late FakeClock clock;

  setUp(() => clock = FakeClock());

  Widget host(List<TimerEntry> timers,
          {void Function(int)? onDismiss, void Function(int)? onCancel}) =>
      MaterialApp(
        home: Scaffold(
          backgroundColor: M.bg,
          body: Column(children: [
            TimerStrip(
              timers: timers,
              clock: clock.call,
              glow: M.henry,
              onDismiss: onDismiss,
              onCancel: onCancel,
            ),
          ]),
        ),
      );

  testWidgets('renders nothing at all when there are no timers',
      (tester) async {
    await tester.pumpWidget(host(const []));
    expect(tester.getSize(find.byType(TimerStrip)).height, 0);
  });

  testWidgets(
      'one chip per timer: engraved label (TIMER when unnamed) and m:ss',
      (tester) async {
    await tester.pumpWidget(host([
      entry(1,
          label: 'pasta',
          deadline: clock.now + const Duration(minutes: 9, seconds: 41)),
      entry(2, deadline: clock.now + const Duration(seconds: 45)),
    ]));
    expect(find.text('PASTA'), findsOneWidget);
    expect(find.text('9:41'), findsOneWidget);
    expect(find.text('TIMER'), findsOneWidget);
    expect(find.text('0:45'), findsOneWidget);
  });

  testWidgets('counts down once a second against the injected clock',
      (tester) async {
    await tester.pumpWidget(host([
      entry(1, label: 'tea', deadline: clock.now + const Duration(seconds: 10))
    ]));
    expect(find.text('0:10'), findsOneWidget);

    clock.advance(const Duration(seconds: 3));
    // The tick wakes just past the next whole-second boundary, not on it.
    await tester.pump(const Duration(milliseconds: 1100));
    expect(find.text('0:07'), findsOneWidget);
  });

  testWidgets('a ringing chip says tap to stop, and a tap dismisses it',
      (tester) async {
    final dismissed = <int>[];
    await tester.pumpWidget(host(
      [entry(4, label: 'eggs', ringing: true, deadline: clock.now)],
      onDismiss: dismissed.add,
    ));
    expect(find.text('TAP TO STOP'), findsOneWidget);
    expect(find.text('0:00'), findsOneWidget);

    await tester.tap(find.text('EGGS'));
    expect(dismissed, [4]);
    // The pulse is an endless animation: tear down explicitly, don't settle.
    await tester.pumpWidget(host(const []));
  });

  testWidgets(
      'a running chip long-presses to cancel (with a haptic); a tap does nothing',
      (tester) async {
    final haptics = <String>[];
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        haptics.add(call.arguments as String);
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    final cancelled = <int>[];
    final dismissed = <int>[];
    await tester.pumpWidget(host(
      [
        entry(9,
            label: 'rice', deadline: clock.now + const Duration(minutes: 5))
      ],
      onCancel: cancelled.add,
      onDismiss: dismissed.add,
    ));

    await tester.tap(find.text('RICE'));
    expect(cancelled, isEmpty);
    expect(dismissed, isEmpty);

    await tester.longPress(find.text('RICE'));
    expect(cancelled, [9]);
    expect(haptics, isNotEmpty);
  });

  testWidgets('stops ticking when the timers go away (no pending timers left)',
      (tester) async {
    await tester.pumpWidget(
        host([entry(1, deadline: clock.now + const Duration(minutes: 1))]));
    await tester.pump(const Duration(seconds: 1));
    // ignore: invalid_use_of_visible_for_testing_member
    bool ticking() => (tester.state(find.byType(TimerStrip)) as dynamic).debugTicking as bool;
    expect(ticking(), isTrue, reason: 'a countdown on screen ticks');
    await tester.pumpWidget(host(const []));
    expect(ticking(), isFalse, reason: 'no timers left: the tick must be cancelled, not just orphaned');
  });
}
