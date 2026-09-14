import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/connection/app_connection.dart';
import 'package:orbital_pai/meridian/orb_state.dart';
import 'package:orbital_pai/voice/voice_controller.dart';

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

  group('PTT mode', () {
    test('a server `listening` does NOT go amber while the button is up', () {
      // Reported from a device: in PTT mode the orb sat amber and waveformed
      // the user's voice while they held nothing. The server pushes
      // `listening` on every transition back into its listening phase — after
      // each completed turn — and hands-free that is correct, the mic really is
      // hot again. In PTT mode it only means "ready for input", so taking it at
      // face value left the orb amber for the rest of the session.
      final c = VoiceController(connection: conn, mic: FakeMic(), player: FakePlayer());
      c.debugSetTalking(true);
      c.setPtt(true);

      c.debugApplyEvent('speaking');
      expect(c.orbState, OrbState.speaking);

      c.debugApplyEvent('listening'); // the push at end of turn
      expect(c.turnState, TurnState.idle);
      expect(c.orbState, OrbState.idle,
          reason: 'nothing is leaving the device, so the orb must not claim '
              'to be hearing anything');
      c.dispose();
    });

    test('holding the button still goes amber', () {
      final c = VoiceController(connection: conn, mic: FakeMic(), player: FakePlayer());
      c.debugSetTalking(true);
      c.setPtt(true);
      c.pttPress();
      expect(c.orbState, OrbState.listening);

      // And a server `listening` arriving mid-hold must not undo it.
      c.debugApplyEvent('listening');
      expect(c.orbState, OrbState.listening);
      c.dispose();
    });

    test('releasing returns to idle, not to amber', () {
      final c = VoiceController(connection: conn, mic: FakeMic(), player: FakePlayer());
      c.debugSetTalking(true);
      c.setPtt(true);
      c.pttPress();
      c.pttRelease();
      expect(c.orbState, OrbState.idle);
      c.dispose();
    });

    test('hands-free is untouched — `listening` still means listening', () {
      final c = VoiceController(connection: conn, mic: FakeMic(), player: FakePlayer());
      c.debugSetTalking(true);
      c.debugApplyEvent('listening');
      expect(c.orbState, OrbState.listening);
      c.dispose();
    });

    test('turning PTT off mid-hold clears the held flag', () {
      // Otherwise `_pttHeld` strands true with no button under it, and the
      // branch above would keep reading as "held" for the rest of the session.
      final c = VoiceController(connection: conn, mic: FakeMic(), player: FakePlayer());
      c.debugSetTalking(true);
      c.setPtt(true);
      c.pttPress();
      expect(c.pttHeld, isTrue);

      c.setPtt(false);
      expect(c.pttHeld, isFalse);
      c.dispose();
    });
  });
}
