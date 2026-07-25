import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/meridian/orb_state.dart';
import 'package:henry_wall/voice/voice_controller.dart';

void main() {
  test('starts powered off', () {
    final c = VoiceController();
    expect(c.talking, isFalse);
    expect(c.orbState, OrbState.off);
    c.dispose();
  });

  test('server events drive turnState and orbState', () {
    final c = VoiceController();
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
    final c = VoiceController();
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
    final c = VoiceController();
    c.debugSetTalking(true);
    c.debugApplyEvent('speaking');
    expect(c.orbFrame.state, OrbState.speaking);
    c.dispose();
  });
}
