import 'package:flutter/material.dart';
import 'orb_state.dart';

/// Per-state Meridian palette. `glow` drives the halos, the outer contact glow and
/// the surface light-bleed; `hi`/`lo` are the sphere shading stops; `rim` is the
/// edge; `wave` is the live waveform. `bleed` is the surface glow opacity
/// (`--m-glow-o` in app.css).
///
/// Ported verbatim from PAL in server/assets/js/voice/orb.js and ORB_PAL in
/// server/assets/js/voice/index.js — do not re-tune.
@immutable
class OrbPalette {
  final Color glow;
  final Color hi;
  final Color lo;
  final Color rim;
  final Color wave;
  final double bleed;

  const OrbPalette({
    required this.glow,
    required this.hi,
    required this.lo,
    required this.rim,
    required this.wave,
    required this.bleed,
  });
}

const Map<OrbState, OrbPalette> kMeridianPalette = {
  OrbState.off: OrbPalette(
    glow: Color(0xFF64748B),
    hi: Color(0xFF4A5568),
    lo: Color(0xFF1A1F27),
    rim: Color(0xFF64748B),
    wave: Color(0xFF8B93A3),
    bleed: 0.22,
  ),
  OrbState.ambient: OrbPalette(
    glow: Color(0xFF334155),
    hi: Color(0xFF3A465A),
    lo: Color(0xFF161B22),
    rim: Color(0xFF475569),
    wave: Color(0xFF64748B),
    bleed: 0.30,
  ),
  OrbState.idle: OrbPalette(
    glow: Color(0xFF6366F1),
    hi: Color(0xFF6D7CFF),
    lo: Color(0xFF161B28),
    rim: Color(0xFF8B93F7),
    wave: Color(0xFFA5B4FC),
    bleed: 0.75,
  ),
  OrbState.listening: OrbPalette(
    glow: Color(0xFFF59E0B),
    hi: Color(0xFFF9B03A),
    lo: Color(0xFF231C11),
    rim: Color(0xFFFBBF24),
    wave: Color(0xFFFCD34D),
    bleed: 1.0,
  ),
  OrbState.speaking: OrbPalette(
    glow: Color(0xFF10B981),
    hi: Color(0xFF34D399),
    lo: Color(0xFF10201A),
    rim: Color(0xFF34D399),
    wave: Color(0xFF6EE7B7),
    bleed: 0.95,
  ),
  OrbState.thinking: OrbPalette(
    glow: Color(0xFFA855F7),
    hi: Color(0xFFC084FC),
    lo: Color(0xFF1C1230),
    rim: Color(0xFFC084FC),
    wave: Color(0xFFD8B4FE),
    bleed: 0.90,
  ),
};

OrbPalette paletteFor(OrbState state) =>
    kMeridianPalette[state] ?? kMeridianPalette[OrbState.off]!;
