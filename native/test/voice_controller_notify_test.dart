import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/connection/app_connection.dart';
import 'package:orbital_pai/notify/background_notices.dart';
import 'package:orbital_pai/phoenix/decoded_message.dart';
import 'package:orbital_pai/voice/voice_controller.dart';

import 'support/fake_alarm.dart';
import 'support/fake_notifier.dart';
import 'support/fake_socket.dart';
import 'support/fakes.dart';

DecodedMessage msg(String event, Map<String, dynamic> json) =>
    DecodedMessage(topic: 'voice:henry', event: event, json: json);

DecodedMessage speak(String source, String text) =>
    msg('speak_start', {'source': source, 'text': text});

DecodedMessage timersMsg(String state) => msg('timers', {
      'timers': [
        {'id': 9, 'label': 'pasta', 'state': state, 'duration_ms': 60000, 'remaining_ms': 0},
      ],
    });

/// The controller's half of the feature: every push reaches the notices, and a
/// tap on a ringing chip cancels its notification. What gets posted when is
/// `background_notices_test.dart`'s business.
void main() {
  late FakeSocket fake;
  late AppConnection conn;
  late FakeNotifier notifier;
  late BackgroundNotices notices;
  late VoiceController vc;

  setUp(() async {
    fake = FakeSocket();
    conn = AppConnection(connector: () async => fake.socket);
    notifier = FakeNotifier();
    notices = BackgroundNotices(notifier: notifier);
    vc = VoiceController(
      connection: conn,
      mic: FakeMic(),
      player: FakePlayer(),
      spotter: FakeSpotter(),
      alarm: FakeAlarm(),
      notices: notices,
    );
    await conn.connect();
    await settle();
  });
  tearDown(() {
    vc.dispose();
    notices.dispose();
    conn.dispose();
  });

  test('backgrounded: a relayed message reaches the shade, and still the thread', () {
    notices.didChangeAppLifecycleState(AppLifecycleState.paused);
    vc.debugHandleMessage(speak('message', 'Message from Tanya —'));
    vc.debugHandleMessage(speak('brain', "Dinner's ready."));
    expect(notifier.shown.single.title, 'Message from Tanya');
    expect(notifier.shown.single.body, "Dinner's ready.");
    expect(vc.thread, hasLength(2), reason: 'the thread is unchanged by notifying');
  });

  test('in front: the same pushes post nothing', () {
    vc.debugHandleMessage(speak('message', 'Message from Tanya —'));
    vc.debugHandleMessage(speak('brain', "Dinner's ready."));
    vc.debugHandleMessage(timersMsg('ringing'));
    expect(notifier.shown, isEmpty);
  });

  test('a ringing timer notifies, and tapping its chip cancels the notification', () {
    notices.didChangeAppLifecycleState(AppLifecycleState.paused);
    vc.debugHandleMessage(timersMsg('running'));
    vc.debugHandleMessage(timersMsg('ringing'));
    expect(notifier.active.values.single.title, "Timer's done");
    vc.dismissTimer(9);
    expect(notifier.active, isEmpty);
  });

  test('without notices (desktop, older tests) the controller is unchanged', () {
    final bare = VoiceController(
      connection: conn,
      mic: FakeMic(),
      player: FakePlayer(),
      spotter: FakeSpotter(),
      alarm: FakeAlarm(),
    );
    addTearDown(bare.dispose);
    bare.debugHandleMessage(speak('message', 'Message from Tanya —'));
    bare.dismissTimer(9);
    expect(notifier.shown, isEmpty);
  });
}
