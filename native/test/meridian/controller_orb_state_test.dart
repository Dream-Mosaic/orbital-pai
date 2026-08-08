import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/connection/app_connection.dart';
import 'package:henry_wall/meridian/orb_state.dart';
import 'package:henry_wall/voice/voice_controller.dart';

import '../support/fakes.dart';

void main() {
  late AppConnection conn;

  // Never connected: every assertion here is driven through the debug seams.
  setUp(() =>
      conn = AppConnection(connector: () async => throw StateError('no socket')));
  tearDown(() => conn.dispose());

  test('starts powered off', () {
    final c = VoiceController(connection: conn, mic: FakeMic(), player: FakePlayer());
    expect(c.talking, isFalse);
    expect(c.orbState, OrbState.off);
    c.dispose();
  });

  test('server events drive turnState and orbState', () {
    final c = VoiceController(connection: conn, mic: FakeMic(), player: FakePlayer());
    c.debugSetTalking(true);
    expect(c.orbState, OrbState.idle);

    c.debugApplyEvent('thinking');
    expect(c.turnState, TurnState.thinking);
    expect(c.orbState, OrbState.thinking);

    c.debugApplyEvent('speaking');
    expect(c.orbState, OrbState.speaking);

    c.debugApplyEvent('listening');
    expect(c.orbState, OrbState.listening);
    c.dispose();
  });

  test('wake lock shows ambient while idle, but not mid-answer', () {
    final c = VoiceController(connection: conn, mic: FakeMic(), player: FakePlayer());
    c.debugSetTalking(true);
    c.debugSetWakeLocked(true);
    expect(c.orbState, OrbState.ambient);

    c.debugApplyEvent('speaking');
    expect(c.orbState, OrbState.speaking, reason: 'live turn keeps its colour');

    c.debugApplyEvent('listening');
    expect(c.orbState, OrbState.ambient, reason: 'back to asleep');
    c.dispose();
  });

  test('the orb frame tracks the resolved state', () {
    final c = VoiceController(connection: conn, mic: FakeMic(), player: FakePlayer());
    c.debugSetTalking(true);
    c.debugApplyEvent('speaking');
    expect(c.orbFrame.state, OrbState.speaking);
    c.dispose();
  });
}
