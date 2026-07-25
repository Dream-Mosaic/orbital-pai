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

  test('palette values match the web source of truth', () {
    expect(paletteFor(OrbState.listening).glow, const Color(0xFFF59E0B));
    expect(paletteFor(OrbState.listening).wave, const Color(0xFFFCD34D));
    expect(paletteFor(OrbState.listening).bleed, 1.0);

    expect(paletteFor(OrbState.speaking).glow, const Color(0xFF10B981));
    expect(paletteFor(OrbState.speaking).bleed, 0.95);

    expect(paletteFor(OrbState.thinking).glow, const Color(0xFFA855F7));
    expect(paletteFor(OrbState.thinking).bleed, 0.90);

    expect(paletteFor(OrbState.idle).glow, const Color(0xFF6366F1));
    expect(paletteFor(OrbState.idle).bleed, 0.75);

    expect(paletteFor(OrbState.ambient).glow, const Color(0xFF334155));
    expect(paletteFor(OrbState.ambient).bleed, 0.30);

    expect(paletteFor(OrbState.off).glow, const Color(0xFF64748B));
    expect(paletteFor(OrbState.off).bleed, 0.22);
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
