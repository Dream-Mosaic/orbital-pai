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
// Waveform render.
// ---------------------------------------------------------------------------

/// Half-height of the envelope at full scale, as a fraction of the sphere
/// radius. The trace is mirrored, so the drawn band is twice this.
const double kWaveAmp = 0.34;

/// How much audio the trace shows across its full width, in seconds.
///
/// THE knob that decides whether this reads as a voice or as hair. It used to
/// be a fixed 1024 samples — 43ms at the 24kHz TTS rate — so the trace was an
/// oscilloscope zoomed in on individual glottal pulses, scrolling a whole
/// screen-width every 43ms. Every bucket held 8 samples, which within a single
/// pitch period swing wildly from one to the next; that is the spikiness, and
/// no amount of smoothing fixes it because the detail is real. Over ~0.6s each
/// bucket spans several pitch periods instead, so its peak becomes the SYLLABLE
/// envelope: smooth, legible, and scrolling at a pace the eye can follow.
///
/// Bounded by PcmRing.defaultCapacity (1.37s at 24kHz) — leave margin.
const double kWaveSeconds = 0.6;

/// Neighbour blend applied across buckets, 0 = none.
/// Takes the last of the hash off the envelope's edge. Deliberately small: this
/// is polish on top of [kWaveSeconds], not a substitute for it.
const double kWaveSmoothing = 0.35;

/// Response curve applied to each normalised bucket magnitude.
/// Below 1.0 LIFTS quiet detail (a 0.3 becomes 0.43 at 0.7), which is what
/// stops soft syllables from disappearing. Above 1.0 would exaggerate peaks at
/// the cost of everything else.
const double kWaveCurve = 0.8;

/// Fill opacity of the envelope body at its widest.
const double kWaveFillAlpha = 0.34;

/// Opacity of the glowing outline traced around the envelope.
const double kWaveEdgeAlpha = 0.72;

/// How long the audio stream may go dry before the trace starts fading out.
///
/// Without this the wave outlived its audio. The read cursor advances on
/// WALL-CLOCK while the ring only advances when audio arrives, so once the
/// stream stops the cursor overruns the write head, the lag goes negative, and
/// the resync drops it straight back into the last written samples — re-reading
/// the same window forever. On screen that is a waveform still open and still
/// moving with nothing being said. The resync itself is right, but it exists
/// for brief jitter stalls and cannot tell one from a stream that has ended.
///
/// A TOOL ROUND is the case that matters: the brain goes quiet mid-turn while
/// the orb is legitimately still `speaking`.
const double kWaveDrySeconds = 0.12;

/// How long the held trace takes to fade to nothing once it has gone dry.
/// A hard cut would read as a glitch; this reads as the wave settling.
const double kWaveFadeSeconds = 0.18;

// ---------------------------------------------------------------------------
// Auto-gain — what stops conversational speech from drawing a 2px squiggle.
// ---------------------------------------------------------------------------

/// Hard ceiling on the normalising gain. This is the knob that stops a SILENT
/// room from having its noise floor amplified into a convincing fake waveform:
/// anything quieter than 1/kAgcMaxGain full-scale stays visibly small.
const double kAgcMaxGain = 8.0;

/// Fraction of the tracked peak still remaining one second later. Peaks are
/// adopted instantly and released at this rate, so the trace's scale holds
/// steady across a whole syllable instead of pumping inside one.
const double kAgcDecayPerSec = 0.55;

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
