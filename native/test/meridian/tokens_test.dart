import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/meridian/tokens.dart';

void main() {
  test('chrome tokens match #voice-shell.meridian in app.css', () {
    // app.css:171-180 — transcribed from the CSS, not from tokens.dart.
    expect(M.bg, const Color(0xFF020309));
    expect(M.shell, const Color(0xFF07080F));
    expect(M.ink, const Color(0xFFE8EBF4));
    expect(M.inkDim, const Color(0xFF9AA1B6));
    expect(M.inkFaint, const Color(0xFF5D647A));
    expect(M.you, const Color(0xFFF2AC46));
    expect(M.youSoft, const Color(0xFFF6C37A));
    expect(M.henry, const Color(0xFF3ECF9A));
    expect(M.conn, const Color(0xFF34D399));
    expect(M.hairline, const Color(0x12FFFFFF)); // rgba(255,255,255,0.07)
  });

  test('the literal rgb() chrome greys and turn body colours', () {
    expect(M.chrome, const Color(0xFFD6DCE9)); // .wordmark rgba(214,220,233,.82)
    expect(M.chromeDim, const Color(0xFFC8CEDC)); // .meta rgba(200,206,220,.34)
    expect(M.youBody, const Color(0xFFD7CBB2)); // .who-you .body (app.css:684)
    expect(M.brainBody, const Color(0xFFE2E6F0)); // .who-brain .body (app.css:708)
  });

  test('the oklch() colours are baked to the right sRGB', () {
    // Recomputed through the full OKLCH -> OKLab -> LMS -> linear sRGB -> gamma
    // pipeline rather than taken on trust; all three agree to the byte.
    expect(M.briefing, const Color(0xFF43B2E1)); // oklch(0.72 0.12 230)
    expect(M.followup, const Color(0xFFBA9CEF)); // oklch(0.75 0.12 300)
    expect(M.success, const Color(0xFF009689)); // daisyUI dark --color-success
  });

  test('the connection dot is connection status, not conversation state', () {
    // setConnStatus() (index.js:519-526) writes a Tailwind bg-* class for the
    // FILL while the data-conn selector drives --dot for the GLOW — on
    // `connected` those are two different greens, and that is reproduced.
    expect(connDotColors(ConnStatus.connected).fill, const Color(0xFF22C55E));
    expect(connDotColors(ConnStatus.connected).glow, M.conn);
    expect(connDotColors(ConnStatus.connected).fill,
        isNot(connDotColors(ConnStatus.connected).glow),
        reason: 'the web really does use two different greens here');
    expect(connDotColors(ConnStatus.connecting).fill, const Color(0xFFF59E0B));
    expect(connDotColors(ConnStatus.connecting).glow, const Color(0xFFF59E0B));
    expect(connDotColors(ConnStatus.offline).fill, const Color(0xFFEF4444));
    expect(connDotColors(ConnStatus.offline).glow, const Color(0xFFEF4444));
  });

  test('letter-spacing converts em to logical px against the font size', () {
    // .wordmark: 0.95rem (15.2px) at 0.42em
    expect(MType.track(15.2, 0.42), closeTo(6.384, 1e-9));
    // .meta .v: 0.52rem (8.32px) at 0.3em
    expect(MType.track(8.32, 0.3), closeTo(2.496, 1e-9));
    // .nlabel: 0.44rem (7.04px) at 0.34em
    expect(MType.track(7.04, 0.34), closeTo(2.3936, 1e-9));
  });

  test('shell metrics match the LiveView layout classes', () {
    expect(M.maxWidth, 416.0); // max-w-[26rem] (conversation_live.ex:705)
    expect(M.orbPaneMaxWidth, 320.0); // max-w-[20rem] (conversation_live.ex:804)
    expect(M.bezelMaxWidth, 272.0); // min(272px, 74%) (app.css:398)
    expect(M.bezelPaneFraction, 0.74);
    expect(M.headerMinHeight, 42.0); // min-height: 42px
  });
}
