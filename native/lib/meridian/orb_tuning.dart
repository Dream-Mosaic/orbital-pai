/// Every knob that decides how the orb *feels*, in one file.
///
/// This exists so tuning is a one-file edit rather than a hunt through the DSP
/// and the painter. Change a number here, rebuild, look at it. Almost nothing
/// here is derived from anything else — they are mostly taste. The one
/// exception is [kLevelLoudAnchor], which is a raw loudness carried through
/// [kLevelCurve]: re-tune the curve and that number must be re-derived, not
/// re-guessed. `audio_levels_test.dart` pins the relationship.
///
/// **These are deliberately NOT the orb.js values.** The web orb was the
/// reference implementation until 2026-09-05; it is a monitor now, and the
/// native client's motion is decided on native grounds. Do not "restore parity"
/// with `server/assets/js/voice/orb.js` — it is not the source of truth for any
/// number in this file.
library;

import 'dart:math' as math;
import 'dart:ui' show Offset;

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
///
/// 0.20, not the 0.12 this shipped with. 0.12 is a 130ms time constant, and
/// syllables arrive every 150-250ms: a soft syllable landing on the tail of a
/// loud one never rose above it, so it was invisible. That IS the reported
/// "reacts more at the start of words". The arithmetic — 0.40 loud, 0.15 soft,
/// 150ms apart, through [kLevelCurve]: the tail at 130ms is 0.527 x 0.316 =
/// 0.167, versus a soft peak of 0.265, barely a tenth of range clear. At 0.20
/// (75ms) the tail is 0.527 x 0.134 = 0.071 and the soft syllable stands 0.19
/// above it.
///
/// Not higher. The level poll is 50ms, so 75ms is 1.5 poll periods and the
/// release still averages across polls; 0.25 (58ms) is 1.17 of one and starts
/// TRACING the 20Hz staircase instead of smoothing it. It also keeps the
/// asymmetry real: 75ms against [kLevelAttack60]'s 28ms is 2.7x, where 0.25
/// would leave 2.1x.
///
/// Since the phase-integration fix this changes only how the HEIGHT tracks;
/// the line's shape follows [kLineShapeSeconds] and no longer moves with it.
const double kLevelRelease60 = 0.20;

/// Exponent of the compressive response curve applied to the raw playback RMS
/// before anything downstream sees it — `curvedLevel`, called once in the
/// level poll, so amplitude, shaping, punch, halos and the ring boost all see
/// perceptual loudness rather than linear power.
///
/// Below 1.0 this LIFTS quiet detail: 0.10 becomes 0.20, 0.15 becomes 0.27.
/// RMS is linear and speech is enormously dynamic, so soft phonemes sit near
/// the floor and simply do not register — "each noise he makes would make it
/// react, with more noise being more reactive, softer would just be softer
/// reactive" is a request for a perceptual curve. The sampled envelope this
/// line replaced carried one (`kWaveCurve`); the synthetic line shipped
/// without an equivalent, which is the whole of S2.
///
/// 0.70 is the exponent that old doc's worked example itself used ("a 0.3
/// becomes 0.43"). It roughly doubles the bottom of the range while leaving the loud
/// end clearly loudest — see the mapping on [kLevelLoudAnchor], which had to
/// move with it.
const double kLevelCurve = 0.70;

/// The level treated as "full" by everything that SHAPES the orb — the line's
/// cycle count and phase speed, and the rings' level boost. In CURVED units:
/// what reaches `anchoredLevel` has already been through [kLevelCurve].
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
/// `rmsFromPcm16` applies a x3 gain, so the RAW level lives around 0.15-0.6
/// and essentially never reaches 1.0. Anchoring the shaping terms at 1.0 (as
/// they were) meant the line topped out near 3-4 of its 5.5 cycles and read
/// calmer than it was drawn to.
///
/// **This is the first knob to reach for on device**: if the line reads too
/// calm, lower it; too frantic, raise it. AMPLITUDE deliberately does NOT go
/// through it — a genuinely loud passage should still be able to reach full
/// height rather than saturating early.
///
/// 0.70, not the 0.6 this shipped with, and the change is bookkeeping rather
/// than taste: the level reaching `anchoredLevel` is now CURVED, and 0.6 raw
/// through [kLevelCurve] is 0.6^0.7 = 0.699. Anchoring at 0.70 therefore
/// leaves this constant meaning exactly what it always meant — raw 0.6 reads
/// as full — with saturation still landing at raw 0.601.
///
/// Stacking the curve on the OLD 0.6 would have been the trap: shaping would
/// have saturated at raw 0.482, putting a merely-loud 0.40 at 0.877 of full
/// and 4.97 of 5.5 cycles. The line would have been near-maximally busy for
/// most of every sentence — a different failure from the one S2 fixes, and
/// just as wrong.
const double kLevelLoudAnchor = 0.70;

// ---------------------------------------------------------------------------
// Line render.
// ---------------------------------------------------------------------------

/// Half-height of the line at full scale, as a fraction of the sphere radius.
/// The line is mirrored about its centre, so the drawn band is twice this.
///
/// 0.42, not the 0.34 this shipped with — "more dramatic when he's talking".
/// Raising it cannot push the line out of the glass: the line's farthest point
/// from the sphere's centre is at its ENDS, where the `sin(f * pi)` taper is
/// zero and the distance is `sqrt(0.72^2 + 0.06^2) = 0.72r` whatever this is
/// set to. The centre excursion, which this does scale, reaches 0.06r + 0.42r
/// = 0.48r — well inside both the fallback painter's clip and the shader's
/// silhouette.
const double kWaveAmp = 0.42;

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
// above qualify, and so does the ring orbit below — which rides as the three
// evaluated drifts (see [ringDrift]) rather than as kRingDrift itself, because
// what both renderers actually consume is the drift, not the knob.

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
/// **Read only by [ringDrift], which both renderers go through.** There is no
/// longer a copy of this number in `shaders/orb.frag`: the three drifts are
/// evaluated here, once per frame, and the shader receives them as the
/// `uDrift0..2` uniforms. Re-tune it freely — nothing else has to be mirrored
/// by hand.
///
/// 0.12, not the 0.045 this shipped with. The rings are drawn as Gaussians of
/// `kHaloSigma` = 0.055 (in the same units), and 0.045 puts the largest
/// possible displacement, `kRingDrift * sqrt(2)` = 0.064, at 1.16 sigma — an
/// orbit smaller than the blur that draws it, which is to say not an orbit you
/// can see. 0.12 puts it at 0.170, or 3.09 sigma. The shader's early-out bound
/// is derived from the drift uniforms themselves rather than from this number,
/// so it follows any re-tune exactly; see the derivation in
/// `shaders/orb.frag`.
const double kRingDrift = 0.12;

/// Where ring [i]'s centre sits at [ringPhase], as a fraction of the sphere
/// radius — the displacement itself, with no base radius folded in.
///
/// **The orbit has exactly one definition, and this is it.** The shader takes
/// the three results as uniforms (`orb_uniforms.dart` packs them) and the
/// fallback painter calls this directly, so the two renderers cannot disagree
/// on the orbit the way they could while `shaders/orb.frag` carried a
/// hand-kept copy of [kRingDrift] — the same policy [kPunchSpread] and
/// [kPunchGlow] already ride on.
///
/// It is also the cheap place to compute it. The drift is constant across a
/// draw, but `haloField` ran this per RING per FRAGMENT, and it runs twice per
/// fragment inside the sphere (direct and refracted) — 12 sin/cos per inner
/// fragment, ~90k times a frame, on a device that is on 24/7, to arrive at
/// three numbers.
///
/// Two independent phases, so each ring traces a Lissajous rather than a
/// circle and the three never lock into a formation.
///
/// Dimensionless ON PURPOSE. The shader measures the rings in units of the
/// BREATHING radius R (`length(p / R - drift)`); the fallback multiplies this
/// by the un-breathing r0, which is the same base its halo radii use. Carrying
/// the fraction rather than a pixel offset is what keeps the shader's whole
/// halo assembly a uniform (1 + breathe) scale of the fallback's about the
/// centre, rather than a distorted one — a deliberate difference, and the only
/// one left between them here.
Offset ringDrift(int i, double ringPhase) => Offset(
      kRingDrift * math.sin(ringPhase + i * 2.1),
      kRingDrift * math.cos(ringPhase * 0.83 + i * 1.7),
    );
