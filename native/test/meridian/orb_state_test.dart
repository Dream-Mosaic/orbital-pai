import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/meridian/orb_state.dart';

void main() {
  test('power off wins over everything', () {
    for (final t in TurnState.values) {
      expect(
        resolveOrbState(talking: false, wakeLocked: false, turnState: t),
        OrbState.off,
      );
      expect(
        resolveOrbState(talking: false, wakeLocked: true, turnState: t),
        OrbState.off,
      );
    }
  });

  test('wake lock shows ambient while idle or listening', () {
    expect(
      resolveOrbState(talking: true, wakeLocked: true, turnState: TurnState.idle),
      OrbState.ambient,
    );
    expect(
      resolveOrbState(talking: true, wakeLocked: true, turnState: TurnState.listening),
      OrbState.ambient,
    );
  });

  test('a live turn keeps its own colour even while wake locked', () {
    expect(
      resolveOrbState(talking: true, wakeLocked: true, turnState: TurnState.speaking),
      OrbState.speaking,
    );
    expect(
      resolveOrbState(talking: true, wakeLocked: true, turnState: TurnState.thinking),
      OrbState.thinking,
    );
  });

  test('unlocked turn states map straight through', () {
    expect(resolveOrbState(talking: true, wakeLocked: false, turnState: TurnState.idle),
        OrbState.idle);
    expect(resolveOrbState(talking: true, wakeLocked: false, turnState: TurnState.listening),
        OrbState.listening);
    expect(resolveOrbState(talking: true, wakeLocked: false, turnState: TurnState.speaking),
        OrbState.speaking);
    expect(resolveOrbState(talking: true, wakeLocked: false, turnState: TurnState.thinking),
        OrbState.thinking);
  });
}
