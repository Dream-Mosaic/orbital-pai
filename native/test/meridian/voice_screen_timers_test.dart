import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/connection/app_connection.dart';
import 'package:orbital_pai/meridian/thread.dart';
import 'package:orbital_pai/meridian/timer_strip.dart';
import 'package:orbital_pai/meridian/voice_screen.dart';
import 'package:orbital_pai/phoenix/decoded_message.dart';
import 'package:orbital_pai/voice/voice_controller.dart';

import '../support/fake_alarm.dart';
import '../support/fakes.dart';

DecodedMessage timers(List<Map<String, dynamic>> list) => DecodedMessage(
    topic: 'voice:henry', event: 'timers', json: {'timers': list});

void main() {
  late AppConnection conn;

  setUp(() => conn =
      AppConnection(connector: () async => throw StateError('no socket')));
  tearDown(() => conn.dispose());

  testWidgets(
      'a timers push puts the strip between the orb pane and the thread, and it goes again',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final vc = VoiceController(
        connection: conn,
        mic: FakeMic(),
        player: FakePlayer(),
        alarm: FakeAlarm());
    addTearDown(vc.dispose);
    await tester.pumpWidget(MaterialApp(
      home: MeridianVoiceScreen(
          controller: vc, connection: conn, userName: 'David'),
    ));
    await tester.pump();
    expect(tester.getSize(find.byType(TimerStrip)).height, 0);
    final threadTop = tester.getTopLeft(find.byType(Thread)).dy;

    vc.debugHandleMessage(timers([
      {
        'id': 1,
        'label': 'pasta',
        'state': 'running',
        'duration_ms': 600000,
        'remaining_ms': 581000
      },
    ]));
    await tester.pump();

    expect(find.text('PASTA'), findsOneWidget);
    expect(find.text('9:41'), findsOneWidget);
    expect(tester.getTopLeft(find.byType(Thread)).dy, greaterThan(threadTop),
        reason: 'the strip takes its room above the thread');
    expect(tester.takeException(), isNull);

    vc.debugHandleMessage(timers(const []));
    await tester.pump();
    expect(find.text('PASTA'), findsNothing);
    expect(tester.getTopLeft(find.byType(Thread)).dy, threadTop);
  });
}
