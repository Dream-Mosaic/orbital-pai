import 'package:flutter/material.dart';

/// Meridian chrome tokens — ported verbatim from `#voice-shell.meridian` and the
/// MERIDIAN block of server/assets/css/app.css. The CSS is the source of truth;
/// see docs/superpowers/specs/2026-07-26-meridian-chrome-design.md. Do not re-tune.
abstract final class M {
  // --- palette (spec §1, app.css:171-180) ---
  static const Color bg = Color(0xFF020309); // --m-bg
  static const Color shell = Color(0xFF07080F); // --m-shell
  static const Color ink = Color(0xFFE8EBF4); // --m-ink
  static const Color inkDim = Color(0xFF9AA1B6); // --m-ink-dim
  static const Color inkFaint = Color(0xFF5D647A); // --m-ink-faint
  static const Color you = Color(0xFFF2AC46); // --you
  static const Color youSoft = Color(0xFFF6C37A); // --you-soft
  static const Color henry = Color(0xFF3ECF9A); // --henry
  static const Color conn = Color(0xFF34D399); // --m-conn (the dot's GLOW)
  static const Color hairline = Color(0x12FFFFFF); // rgba(255,255,255,0.07)

  /// oklch(0.72 0.12 230) — `.who-briefing .who` (app.css:724).
  static const Color briefing = Color(0xFF43B2E1);

  /// oklch(0.75 0.12 300) — `.who-followup .who` (app.css:729).
  static const Color followup = Color(0xFFBA9CEF);

  /// daisyUI dark `--color-success` = oklch(0.60 0.118 184.704) — the power
  /// detent's icon while ON (`setPower()` toggles Tailwind's `.text-success`).
  ///
  /// This one is OUTSIDE the sRGB gamut, so its byte values depend on how the
  /// renderer gamut-maps it; this is the clipped conversion, which is also the
  /// value Chrome renders. If it ever looks off against the web, that mapping is
  /// the thing to re-check — the other two are comfortably in gamut.
  static const Color success = Color(0xFF009689);

  /// The two greys the CSS spells out as literal rgb() triples, so callers can
  /// apply the per-rule alpha themselves and keep the CSS greppable.
  static const Color chrome = Color(0xFFD6DCE9); // rgba(214,220,233,·)
  static const Color chromeDim = Color(0xFFC8CEDC); // rgba(200,206,220,·)

  /// The body text colour of a `you` turn (`.who-you .body`, app.css:684).
  static const Color youBody = Color(0xFFD7CBB2);

  /// The body text colour of a brain answer (`.who-brain .body`, app.css:708).
  static const Color brainBody = Color(0xFFE2E6F0);

  // --- shell metrics (spec §2) ---
  static const double pagePad = 16.0; // px-4 py-4
  static const double columnGap = 12.0; // gap-3
  static const double maxWidth = 416.0; // max-w-[26rem]
  static const double orbPaneMaxWidth = 320.0; // max-w-[20rem]
  static const double bezelMaxWidth = 272.0; // min(272px, 74%)
  static const double bezelPaneFraction = 0.74;
  static const double headerMinHeight = 42.0;
}

/// The web self-hosts Inter (body, `--font-sans`) and Space Grotesk (display,
/// `--font-display`) as woff2, which Flutter cannot consume — so the SAME files
/// are converted to ttf at `assets/fonts/` and bundled. Both are variable fonts;
/// see [MType.wght] for reaching a CSS weight exactly.
const String kDisplayFamily = 'Space Grotesk';
const String kBodyFamily = 'Inter';

abstract final class MType {
  /// CSS `letter-spacing` is in `em`; Flutter's is in logical px.
  static double track(double fontSize, double em) => fontSize * em;

  /// Both bundled families are VARIABLE (Space Grotesk wght 300-700, Inter
  /// 100-900), so a CSS `font-weight: 650` lands exactly instead of rounding to
  /// FontWeight.w600. Pair with `fontWeight` for the non-variable fallback.
  static List<FontVariation> wght(double w) => [FontVariation('wght', w)];

  /// `text-shadow: 0 -1px 0 rgba(0,0,0,0.7)` — the "engraved" chrome labels.
  static const List<Shadow> engraved = [
    Shadow(offset: Offset(0, -1), color: Color(0xB3000000)),
  ];

  /// `.wordmark`'s two-shadow bevel (app.css:290-292).
  static const List<Shadow> wordmark = [
    Shadow(offset: Offset(0, -1), color: Color(0xCC000000)), // black @ 0.8
    Shadow(offset: Offset(0, 1), color: Color(0x0DFFFFFF)), // white @ 0.05
  ];
}

/// The header dot reflects SERVER/connection status, NOT the conversation state
/// (index.js:519). It is independent of the orb's six states.
enum ConnStatus { connected, connecting, offline }

@immutable
class ConnDotColors {
  const ConnDotColors(this.fill, this.glow);
  final Color fill;
  final Color glow;
}

/// `setConnStatus()` rewrites the dot's className to a Tailwind `bg-*` utility
/// (the FILL) while the `data-conn` attribute selector drives `--dot` (the GLOW).
/// On `connected` those are two different greens in the web. Reproduced verbatim.
ConnDotColors connDotColors(ConnStatus s) => switch (s) {
      ConnStatus.connected => const ConnDotColors(Color(0xFF22C55E), M.conn),
      ConnStatus.connecting =>
        const ConnDotColors(Color(0xFFF59E0B), Color(0xFFF59E0B)),
      ConnStatus.offline =>
        const ConnDotColors(Color(0xFFEF4444), Color(0xFFEF4444)),
    };
