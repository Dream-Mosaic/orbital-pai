import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/meridian/orb_state.dart';
import 'package:henry_wall/meridian/palette.dart';

void main() {
  test('every orb state has a palette', () {
    for (final s in OrbState.values) {
      expect(kMeridianPalette[s], isNotNull, reason: 'missing palette for $s');
    }
  });

  test('all 36 palette values match the web source of truth', () {
    // The A1 review verified every value by hand but the test locked only 13 of
    // 36 — and these values ARE the design's ground truth. Transcribed from the
    // web sources directly, not from lib/meridian/palette.dart (which would make
    // the test a mirror of the thing it is checking): colours from PAL in
    // server/assets/js/voice/orb.js, bleed from ORB_PAL in index.js:47-52.
    const expected = <OrbState, List<Object>>{
      // glow, hi, lo, rim, wave, bleed
      OrbState.off: [0xFF64748B, 0xFF4A5568, 0xFF1A1F27, 0xFF64748B, 0xFF8B93A3, 0.22],
      OrbState.ambient: [0xFF334155, 0xFF3A465A, 0xFF161B22, 0xFF475569, 0xFF64748B, 0.30],
      OrbState.idle: [0xFF6366F1, 0xFF6D7CFF, 0xFF161B28, 0xFF8B93F7, 0xFFA5B4FC, 0.75],
      OrbState.listening: [0xFFF59E0B, 0xFFF9B03A, 0xFF231C11, 0xFFFBBF24, 0xFFFCD34D, 1.0],
      OrbState.speaking: [0xFF10B981, 0xFF34D399, 0xFF10201A, 0xFF34D399, 0xFF6EE7B7, 0.95],
      OrbState.thinking: [0xFFA855F7, 0xFFC084FC, 0xFF1C1230, 0xFFC084FC, 0xFFD8B4FE, 0.90],
    };

    expect(expected.keys.toSet(), OrbState.values.toSet(),
        reason: 'a new state must be added here, not silently skipped');

    for (final entry in expected.entries) {
      final p = paletteFor(entry.key);
      final v = entry.value;
      expect(p.glow, Color(v[0] as int), reason: '${entry.key}.glow');
      expect(p.hi, Color(v[1] as int), reason: '${entry.key}.hi');
      expect(p.lo, Color(v[2] as int), reason: '${entry.key}.lo');
      expect(p.rim, Color(v[3] as int), reason: '${entry.key}.rim');
      expect(p.wave, Color(v[4] as int), reason: '${entry.key}.wave');
      expect(p.bleed, v[5] as double, reason: '${entry.key}.bleed');
    }
  });

  test('bleed rises with engagement: off < ambient < idle < thinking < speaking < listening', () {
    final b = {for (final s in OrbState.values) s: paletteFor(s).bleed};
    expect(b[OrbState.off]! < b[OrbState.ambient]!, isTrue);
    expect(b[OrbState.ambient]! < b[OrbState.idle]!, isTrue);
    expect(b[OrbState.idle]! < b[OrbState.thinking]!, isTrue);
    expect(b[OrbState.thinking]! < b[OrbState.speaking]!, isTrue);
    expect(b[OrbState.speaking]! < b[OrbState.listening]!, isTrue);
  });
}
