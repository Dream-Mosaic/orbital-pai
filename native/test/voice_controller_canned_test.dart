import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/connection/app_connection.dart';
import 'package:orbital_pai/meridian/thread_model.dart';
import 'package:orbital_pai/phoenix/decoded_message.dart';
import 'package:orbital_pai/voice/voice_controller.dart';

import 'support/fakes.dart';

DecodedMessage msg(String event, Map<String, dynamic> json) =>
    DecodedMessage(topic: 'voice:henry', event: event, json: json);

void main() {
  late AppConnection conn;
  late VoiceController vc;

  setUp(() {
    conn = AppConnection(connector: () async => throw StateError('no socket'));
    vc = VoiceController(connection: conn, mic: FakeMic(), player: FakePlayer());
  });
  tearDown(() {
    vc.dispose();
    conn.dispose();
  });

  List<String> lines() => [
        for (final i in vc.thread)
          if (i is ThreadLine) '${i.kind.name}: ${i.text}',
      ];

  test('a canned agenda turn after a typed turn shows both its lead and its body', () {
    // The typed turn: transcript, tool chip, streamed answer snapped by speak_start.
    vc.debugHandleMessage(msg('transcript', const {'text': 'Set a 15 second tea timer'}));
    vc.debugHandleMessage(msg('thinking', const {}));
    vc.debugHandleMessage(msg('tool_call', const {'name': 'set_timer'}));
    vc.debugHandleMessage(msg('brain_delta', const {'delta': 'Tea timer, 15 seconds.'}));
    vc.debugHandleMessage(msg('speak_start', const {'source': 'brain', 'text': 'Tea timer, 15 seconds.'}));
    vc.debugHandleMessage(msg('metrics', const {'ttfa': null, 'ttb': 900}));
    vc.debugHandleMessage(msg('listening', const {}));

    // The timer rings: exactly the sequence a bound device receives (live-captured).
    vc.debugHandleMessage(msg('speaking', const {}));
    vc.debugHandleMessage(msg('speak_start', const {'source': 'timer', 'text': "Timer's done —"}));
    vc.debugHandleMessage(msg('metrics', const {'ttfa': null, 'ttb': 368}));
    vc.debugHandleMessage(msg('speak_start', const {'source': 'brain', 'text': 'Your tea timer is up.'}));
    vc.debugHandleMessage(msg('listening', const {}));

    expect(lines(), [
      'you: Set a 15 second tea timer',
      'brain: Tea timer, 15 seconds.',
      "timer: Timer's done —",
      'brain: Your tea timer is up.',
    ]);
  });
}
