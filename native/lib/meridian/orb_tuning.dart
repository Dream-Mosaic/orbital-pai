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

/// The raw level treated as "full" by everything that SHAPES the orb — the
/// line's cycle count and phase speed, and the rings' level boost.
///
/// **Deliberate deviation from the spec, which asked for a scalar AGC.** The
/// `AutoGain` this replaced tracked a decaying peak to normalise a *mic*
/// signal of unknown gain. The level no longer comes from a mic: it is the RMS
/// of TTS playback, whose loudness is consistent turn to turn, so a normaliser
/// here would spend its time amplifying quiet passages into looking loud —
/// destroying exactly the dynamic range the line exists to show. A fixed
/// anchor keeps the relationship between a mumble and a shout.
///
/// The number: speech RMS on normalised PCM runs ~0.05-0.25, and
/// `rmsFromPcm16` applies a x3 gain, so the smoothed level lives around
/// 0.15-0.6 and essentially never reaches 1.0. Anchoring the shaping terms at
/// 1.0 (as they were) meant the line topped out near 3-4 of its 5.5 cycles and
/// read calmer than it was drawn to.
///
/// **This is the first knob to reach for on device**: if the line reads too
/// calm, lower it; too frantic, raise it. AMPLITUDE deliberately does NOT go
/// through it — a genuinely loud passage should still be able to reach full
/// height rather than saturating early.
const double kLevelLoudAnchor = 0.6;

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
///
/// A SPEED, integrated once per frame into `OrbFrame.linePhase`. It is never
/// multiplied onto an already-accumulated clock at render time: doing that
/// makes the rendered phase a product of elapsed time and the current level,
/// so every level move rotates the whole line by (elapsed x delta-level)
/// radians — tens of radians per frame after a few minutes of uptime, i.e.
/// spatial static during every syllable, invisible in a fresh-launch demo.
const double kLineSpeedRest = 0.9;
const double kLineSpeedLoud = 2.6;

/// Seconds for the line's SHAPE — its cycle count — to follow a step in
/// loudness, to 95%, matching [kLinePresenceSeconds]' convention. Two seconds
/// is an exponential time constant of ~0.68s.
///
/// Deliberately far slower than the VU ballistics that drive AMPLITUDE, and
/// the two must never be collapsed into one number. A syllable has to make the
/// line taller on the frame it lands; it must not also re-draw the waveform
/// underneath itself, because a cycle count moving at VU speed shifts the
/// ends of the line by radians per frame and reads as noise rather than as
/// speech. Tall now, busy slowly.
const double kLineShapeSeconds = 2.0;

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

/// Speaking's BASE must already beat thinking's — 1.30, not the 1.00 this
/// shipped with. At 1.00 speaking only overtook thinking once `level > 0.125`,
/// so the rings visibly SLOWED DOWN on the thinking to speaking transition:
/// at the start of every answer, with presence still fading in and the level
/// still rising, and again in every inter-word gap. The level boost then
/// carries it to 2.10 at full loudness.
const double kRingSpeedSpeaking = 1.30;

/// Extra speed at full level while speaking.
const double kRingSpeedLevelBoost = 0.80;

/// How far each ring drifts off-centre, as a fraction of the sphere radius.
/// This is what makes them ORBIT rather than only breathe in place.
///
/// Hand-kept in step with `kRingDrift` in `shaders/orb.frag` — GLSL cannot
/// read Dart constants, and this one is geometry rather than a shared motion
/// value worth a uniform slot of its own. Change one, change the other, or the
/// fallback painter stops looking like the shader.
///
/// 0.12, not the 0.045 this shipped with. The rings are drawn as Gaussians of
/// `kHaloSigma` = 0.055 (in the same units), and 0.045 puts the largest
/// possible displacement, `kRingDrift * sqrt(2)` = 0.064, at 1.16 sigma — an
/// orbit smaller than the blur that draws it, which is to say not an orbit you
/// can see. 0.12 puts it at 0.170, or 3.09 sigma. The shader's early-out bound
/// is written as `1.9 + kRingDriftMax` precisely so it tracks this number;
/// see the derivation in `shaders/orb.frag`.
const double kRingDrift = 0.12;
