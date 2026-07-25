/// The conversation's turn state, mirrored from the web hook's `this.turnState`
/// (server/assets/js/voice/index.js).
enum TurnState { idle, listening, speaking, thinking }

/// What the orb actually renders. `off` = powered down, `ambient` = wake-locked
/// (asleep on the wall). Mirrors the PAL keys in server/assets/js/voice/orb.js.
enum OrbState { off, ambient, idle, listening, speaking, thinking }

/// Single source of truth for the orb, ported verbatim from `resolveOrbState()`
/// in server/assets/js/voice/index.js:
///
///   power off wins, then the wake lock (ambient = asleep on the wall), then
///   whatever the turn is doing.
///
/// Note the deliberate asymmetry: a wake-locked kiosk shows the slate ambient orb
/// while idle/listening, but a speaking/thinking turn still finishes in its live
/// colour even if the lock lands mid-turn.
OrbState resolveOrbState({
  required bool talking,
  required bool wakeLocked,
  required TurnState turnState,
}) {
  if (!talking) return OrbState.off;
  if (wakeLocked &&
      (turnState == TurnState.idle || turnState == TurnState.listening)) {
    return OrbState.ambient;
  }
  return switch (turnState) {
    TurnState.idle => OrbState.idle,
    TurnState.listening => OrbState.listening,
    TurnState.speaking => OrbState.speaking,
    TurnState.thinking => OrbState.thinking,
  };
}
