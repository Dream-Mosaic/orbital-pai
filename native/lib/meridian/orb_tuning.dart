/// Every knob that decides how the orb *feels*, in one file.
///
/// This exists so tuning is a one-file edit rather than a hunt through the DSP
/// and the painter. Change a number here, rebuild, look at it. Nothing in this
/// file is derived from anything else — they are all taste.
///
/// **These are deliberately NOT the orb.js values.** The web orb was the
/// reference implementation until 2026-09-05; it is a monitor now, and the
/// native client's motion is decided on native grounds. Do not "restore parity"
/// with `server/assets/js/voice/orb.js` — it is not the source of truth for any
/// number in this file.
library;

// ---------------------------------------------------------------------------
// Level ballistics — how the smoothed loudness chases the raw loudness.
// ---------------------------------------------------------------------------

/// Smoothing coefficient per frame AT 60Hz while the level is RISING.
/// Higher = the orb snaps to peaks harder. (orb.js used 0.2 in both directions,
/// which is why it read as sleepy.)
const double kLevelAttack60 = 0.45;

/// Smoothing coefficient per frame at 60Hz while the level is FALLING.
/// Lower = a longer, smoother tail after a syllable. The asymmetry between this
/// and [kLevelAttack60] is most of what makes a meter feel alive rather than
/// merely animated; keep release well below attack.
const double kLevelRelease60 = 0.12;

// ---------------------------------------------------------------------------
// Line render.
// ---------------------------------------------------------------------------

/// Half-height of the line at full scale, as a fraction of the sphere radius.
/// The line is mirrored about its centre, so the drawn band is twice this.
const double kWaveAmp = 0.34;

/// Fill opacity of the line's body at its widest.
const double kWaveFillAlpha = 0.34;

/// Opacity of the glowing outline traced around the line.
const double kWaveEdgeAlpha = 0.72;

// ---------------------------------------------------------------------------
// Transient detection — the per-syllable "punch" that flares the halos.
// ---------------------------------------------------------------------------

/// Fast envelope follower (60Hz coefficient). Tracks the attack of a syllable.
const double kPunchFast60 = 0.55;

/// Slow envelope follower (60Hz coefficient). Tracks the running baseline.
/// Punch is the amount by which fast has pulled ahead of slow, so a steady tone
/// — where both converge — produces no punch at all. That is the point.
const double kPunchSlow60 = 0.05;

/// Multiplier on (fast - slow) before clamping to 0..1. Raise for more
/// frequent, bigger flares; lower if it reads as twitchy.
const double kPunchGain = 3.0;

/// How fast a punch falls back to zero (60Hz coefficient). Attack is instant by
/// construction; this is purely the decay.
const double kPunchRelease60 = 0.10;

/// How far a full punch pushes the halos outward, as a fraction of the base
/// radius.
const double kPunchSpread = 0.10;

/// How much a full punch brightens the halos and the contact glow.
const double kPunchGlow = 0.9;

// ---------------------------------------------------------------------------
// The line's presence — whether it is on screen at all.
// ---------------------------------------------------------------------------

/// Seconds for the line to fade fully in or out.
///
/// Presence is a function of STATE, not of level: the line is there while Henry
/// is thinking or speaking, and gone while listening or idle. A fade rather
/// than a cut, because the state can flip several times in a turn.
const double kLinePresenceSeconds = 0.22;

/// Below this, the line is not drawn at all.
///
/// Presence decays GEOMETRICALLY, so it asymptotes and never actually reaches
/// zero except on `off` (which assigns it). A `presence > 0` gate therefore
/// never closes: in idle/ambient/listening the Ticker is still running — it
/// stops only for `off` — so both painters would go on allocating 192 offsets,
/// building a ~190-segment path and stroking a blurred gradient every frame,
/// forever, at an alpha that rounds to invisible. On a 24/7 wall device that is
/// exactly the waste the stopped ticker exists to avoid.
///
/// This does NOT clip the fade-IN, which is the reason the gate is on presence
/// rather than on the state: one frame of fade-in already puts presence at
/// ~0.203, two orders of magnitude above this. Fading OUT, half a second (the
/// full fade plus margin) lands at ~0.0011, comfortably under it.
const double kLinePresenceEpsilon = 0.002;

// ---------------------------------------------------------------------------
// The line's shape.
// ---------------------------------------------------------------------------

/// Amplitude with no audio at all, as a fraction of full scale.
///
/// `thinking` has no audio — a purely level-driven line would be flat and dead
/// exactly when the line is meant to be present. This is the line breathing on
/// its own.
const double kLineRestAmp = 0.16;

/// How many visible cycles the line carries at rest and at full level.
/// Growing the COUNT as well as the amplitude is what turns the calm line into
/// the busy one rather than merely a taller version of the same shape.
const double kLineCyclesRest = 1.2;
const double kLineCyclesLoud = 5.5;

/// Phase speed at rest and at full level, in radians per second.
const double kLineSpeedRest = 0.9;
const double kLineSpeedLoud = 2.6;

// ---------------------------------------------------------------------------
// Glass (shader only).
// ---------------------------------------------------------------------------
//
// The glass knobs — index of refraction, dispersion, specular exponents,
// caustic and Fresnel strength, halo softness — live in a marked block at the
// top of `shaders/orb.frag`, because GLSL cannot read Dart constants.
//
// Anything SHARED with the fallback Canvas painter stays here and is passed
// to the shader as a uniform (see orb_uniforms.dart), so the two renderers
// cannot drift apart on a value they both use. kPunchSpread and kPunchGlow
// above are the two that qualify today.

// ---------------------------------------------------------------------------
// Ring cadence — the ambient loop, per state.
// ---------------------------------------------------------------------------

/// Phase advance per second, by state. Idle calm, listening a little more,
/// thinking faster, speaking fastest (and level-modulated on top).
/// `off` and `ambient` are deliberately 0: a wall device at rest must not
/// animate at all.
const double kRingSpeedIdle = 0.35;
const double kRingSpeedListening = 0.60;
const double kRingSpeedThinking = 1.10;
const double kRingSpeedSpeaking = 1.00;

/// Extra speed at full level while speaking.
const double kRingSpeedLevelBoost = 0.80;

/// How far each ring drifts off-centre, as a fraction of the sphere radius.
/// This is what makes them ORBIT rather than only breathe in place.
///
/// Hand-kept in step with `kRingDrift` in `shaders/orb.frag` — GLSL cannot
/// read Dart constants, and this one is geometry rather than a shared motion
/// value worth a uniform slot of its own. Change one, change the other, or the
/// fallback painter stops looking like the shader.
const double kRingDrift = 0.045;
