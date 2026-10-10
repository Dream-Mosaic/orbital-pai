import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/connection/app_connection.dart';
import 'package:orbital_pai/phoenix/decoded_message.dart';
import 'package:orbital_pai/voice/voice_controller.dart';

import 'support/fake_alarm.dart';
import 'support/fake_socket.dart';
import 'support/fakes.dart';

DecodedMessage timersMsg(List<Map<String, dynamic>> timers) =>
    DecodedMessage(topic: 'voice:henry', event: 'timers', json: {'timers': timers});

Map<String, dynamic> wireTimer(int id, {String state = 'running', int remaining = 60000}) => {
      'id': id,
      'label': 'pasta',
      'state': state,
      'duration_ms': 60000,
      'remaining_ms': remaining,
    };

void main() {
  late FakeSocket fake;
  late AppConnection conn;
  late FakeAlarm alarm;
  late FakeClock clock;
  late VoiceController vc;

  setUp(() async {
    fake = FakeSocket();
    conn = AppConnection(connector: () async => fake.socket);
    alarm = FakeAlarm();
    clock = FakeClock();
    vc = VoiceController(
      connection: conn,
      mic: FakeMic(),
      player: FakePlayer(),
      spotter: FakeSpotter(),
      alarm: alarm,
      timerClock: clock.call,
    );
    await conn.connect();
    await settle();
  });
  tearDown(() {
    vc.dispose();
    conn.dispose();
  });

  /// The event-named JSON pushes this client sent, decoded, in order.
  List<Map<String, dynamic>> pushesOf(String event) => fake.sent
      .whereType<String>()
      .map((f) => jsonDecode(f) as List<dynamic>)
      .where((p) => p[3] == event)
      .map((p) => (p[4] as Map).cast<String, dynamic>())
      .toList();

  test('a `timers` push becomes the timer list, anchored to the local clock', () {
    var notified = 0;
    vc.addListener(() => notified++);
    vc.debugHandleMessage(timersMsg([wireTimer(7, remaining: 30000)]));

    expect(notified, greaterThan(0));
    final e = vc.timers.single;
    expect(e.id, 7);
    expect(e.label, 'pasta');
    clock.advance(const Duration(seconds: 10));
    expect(e.remainingAt(vc.timerClock()), const Duration(seconds: 20));
  });

  test('a timer turning ringing sounds the alarm once', () {
    vc.debugHandleMessage(timersMsg([wireTimer(7)]));
    expect(alarm.starts, 0);
    vc.debugHandleMessage(timersMsg([wireTimer(7, state: 'ringing', remaining: 0)]));
    vc.debugHandleMessage(timersMsg([wireTimer(7, state: 'ringing', remaining: 0)]));
    expect(alarm.starts, 1);
    expect(alarm.sounding, isTrue);
  });

  test('dismissTimer pushes dismiss_timer and silences the alarm at once', () async {
    vc.debugHandleMessage(timersMsg([wireTimer(7, state: 'ringing', remaining: 0)]));
    vc.dismissTimer(7);
    await settle();

    expect(alarm.sounding, isFalse);
    expect(pushesOf('dismiss_timer'), [
      {'id': 7}
    ]);
  });

  test('startTimer pushes start_timer with seconds and label; nonsense is refused', () async {
    expect(vc.startTimer(480, 'lasagna'), isTrue);
    expect(vc.startTimer(0, 'nope'), isFalse);
    await settle();
    expect(pushesOf('start_timer'), [
      {'seconds': 480, 'label': 'lasagna'}
    ]);
  });

  test('cancelTimer pushes cancel_timer', () async {
    vc.debugHandleMessage(timersMsg([wireTimer(7)]));
    vc.cancelTimer(7);
    await settle();
    expect(pushesOf('cancel_timer'), [
      {'id': 7}
    ]);
  });

  test('dispose stops a sounding alarm', () {
    vc.debugHandleMessage(timersMsg([wireTimer(7, state: 'ringing', remaining: 0)]));
    vc.dispose();
    expect(alarm.sounding, isFalse);
    // tearDown disposes again; rebuild a throwaway so that is harmless.
    vc = VoiceController(connection: conn, mic: FakeMic(), player: FakePlayer(), alarm: alarm);
  });
}
