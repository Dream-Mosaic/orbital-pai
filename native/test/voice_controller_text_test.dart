import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/connection/app_connection.dart';
import 'package:orbital_pai/meridian/thread_model.dart';
import 'package:orbital_pai/phoenix/decoded_message.dart';
import 'package:orbital_pai/voice/voice_controller.dart';

import 'support/fake_socket.dart';
import 'support/fakes.dart';

/// Type to Henry (spec 2026-10-10 household wave 1, F1): a typed message rides
/// `voice:henry` as `"text"` and is answered quietly by the server.
void main() {
  ({AppConnection conn, VoiceController vc, FakeSocket fake}) build() {
    final fake = FakeSocket();
    final conn = AppConnection(
      connector: () async => fake.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final vc = VoiceController(
      connection: conn,
      mic: FakeMic(),
      player: FakePlayer(),
      spotter: FakeSpotter(),
    );
    addTearDown(() {
      vc.dispose();
      conn.dispose();
    });
    return (conn: conn, vc: vc, fake: fake);
  }

  List<Map<String, dynamic>> textPushes(FakeSocket fake) => fake.textFrames
      .where((p) => p[2] == 'voice:henry' && p[3] == 'text')
      .map((p) => (p[4] as Map).cast<String, dynamic>())
      .toList();

  test('sendText pushes the trimmed message on voice:henry', () async {
    final b = build();
    await b.conn.connect();
    await settle();

    expect(b.vc.sendText('  what is the weather  '), isTrue);
    await settle();

    expect(textPushes(b.fake), [
      {'text': 'what is the weather'},
    ]);
  });

  test('no optimistic line: the "you" line is the server\'s transcript echo',
      () async {
    // Drawing the line locally as well would put it in the thread twice on
    // this device, and the echo is what every OTHER device of the user sees.
    final b = build();
    await b.conn.connect();
    await settle();

    b.vc.sendText('hello');
    await settle();
    expect(b.vc.thread, isEmpty);

    b.vc.debugHandleMessage(const DecodedMessage(
      topic: 'voice:henry',
      event: 'transcript',
      json: {'text': 'hello'},
    ));
    expect(b.vc.thread, hasLength(1));
    expect((b.vc.thread.single as ThreadLine).kind, LineKind.you);
  });

  test('a blank message pushes nothing', () async {
    final b = build();
    await b.conn.connect();
    await settle();

    expect(b.vc.sendText('   \n  '), isFalse);
    await settle();

    expect(textPushes(b.fake), isEmpty);
  });

  test('not joined: nothing is pushed, and the caller is told so', () async {
    // The composer keeps the draft when this returns false, rather than
    // clearing a message that never left the device.
    final b = build();

    expect(b.vc.sendText('hello'), isFalse);
    await settle();

    expect(textPushes(b.fake), isEmpty);
  });
}
