import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'hero_icon.dart';
import 'live_caption.dart';
import 'orb_painter.dart';
import 'orb_view.dart';
import 'tokens.dart';

/// The orb canvas is oversized and centred so the sphere (drawn at 60% of the
/// canvas box by orb.js) fills the well and its halos spill onto the rim on
/// purpose. `--orb-scale` in app.css:402.
const double kOrbScale = 1.55;

/// The glass sphere's radius as a fraction of the BEZEL's width.
///
/// `OrbPainter`/`orb.frag` draw the sphere at `0.3 * min(w, h)` of the OrbView
/// box, and OrbView is laid out at [kOrbScale] of the bezel, centred on it.
/// Derived rather than written down so it cannot drift if either changes.
const double kSphereRadiusOfBezel = 0.3 * kOrbScale;

/// Half-width of the caption's box, as a fraction of the sphere's radius.
/// Its half-HEIGHT is derived from this so the box stays inscribed — see
/// [_captionBox].
const double _kCaptionHalfWidthOfR = 0.82;

/// The machined bezel: a lit well with the animated orb inside it, the live
/// caption over it, and the four control detents on its diagonals. Fills whatever
/// square box its parent gives it — the parent owns `min(272px, 74%)`.
class OrbBezel extends StatelessWidget {
  const OrbBezel({
    super.key,
    required this.frame,
    required this.glow,
    required this.caption,
    required this.powerOn,
    required this.pttOn,
    required this.abiOn,
    required this.onPower,
    required this.onClear,
    required this.onPtt,
    required this.onAbi,
    this.powerEnabled = true,
  });

  final OrbFrame frame;
  final Color glow;
  final String caption;
  final bool powerOn;
  final bool pttOn;
  final bool abiOn;
  final VoidCallback onPower;
  final VoidCallback onClear;
  final ValueChanged<bool> onPtt;
  final ValueChanged<bool> onAbi;

  /// False until the socket has actually joined. See OrbDetent.enabled.
  final bool powerEnabled;

  static const double _detent = 37.0;

  /// Your live speech, centred IN the glass, inscribed in the sphere.
  ///
  /// It used to sit in the bezel's lower half (`top: 58%`), deliberately clear
  /// of the middle so it would not cover the waveform while you talked. That
  /// reason is gone: the waveform is Henry's voice only now, and this caption
  /// is only ever your own — set from `partial`, cleared on `transcript` — so
  /// the two can no longer be on screen together. Nothing is left to dodge, and
  /// the text gets the whole orb.
  ///
  /// The box is INSCRIBED in the sphere rather than merely centred on it: a
  /// rectangle centred in a circle of radius R fits when `w² + h² ≤ R²`, so
  /// fixing the half-width at [_kCaptionHalfWidthOfR] of R derives the
  /// half-height. Get that wrong in the generous direction and long captions
  /// spill over the glass edge, which reads as a layout bug rather than as
  /// text. LiveCaption's own ladder then shrinks the type to fit the box.
  Widget _captionBox(double d, String caption) {
    final r = kSphereRadiusOfBezel * d;
    final halfW = r * _kCaptionHalfWidthOfR;
    final halfH = r *
        math.sqrt(1 - _kCaptionHalfWidthOfR * _kCaptionHalfWidthOfR);
    return Positioned(
      left: d / 2 - halfW,
      top: d / 2 - halfH,
      width: halfW * 2,
      height: halfH * 2,
      child: IgnorePointer(
        child: LiveCaption(
          text: caption,
          width: halfW * 2,
          height: halfH * 2,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final d = constraints.maxWidth;
        final overscan = d * (kOrbScale - 1) / 2;
        return SizedBox(
          width: d,
          height: d,
          child: Stack(
            clipBehavior: Clip.none, // nothing here clips: overflow is visible
            children: [
              Positioned(
                left: -overscan,
                top: -overscan,
                width: d * kOrbScale,
                height: d * kOrbScale,
                child: IgnorePointer(child: OrbView(frame: frame)),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(painter: BezelPainter(glow: glow)),
                ),
              ),
              _captionBox(d, caption),
              _at(
                  d,
                  0.08,
                  0.08,
                  OrbDetent(
                    icon: HeroIcon.power,
                    tooltip: 'Power on/off',
                    onTap: onPower,
                    enabled: powerEnabled,
                    iconColor: powerOn ? M.success : null,
                    dimmed: !powerOn,
                  )),
              _at(
                  d,
                  0.92,
                  0.08,
                  OrbDetent(
                    icon: HeroIcon.trash,
                    tooltip: 'Clear conversation',
                    onTap: onClear,
                  )),
              _at(
                  d,
                  0.08,
                  0.92,
                  OrbDetent(
                    icon: HeroIcon.microphone,
                    tooltip: 'Push-to-talk mode',
                    label: 'PTT',
                    on: pttOn,
                    onTap: () => onPtt(!pttOn),
                  )),
              _at(
                  d,
                  0.92,
                  0.92,
                  OrbDetent(
                    icon: HeroIcon.handRaised,
                    tooltip: 'Allow barge-in',
                    label: 'ABI',
                    on: abiOn,
                    onTap: () => onAbi(!abiOn),
                  )),
            ],
          ),
        );
      },
    );
  }

  /// `transform: translate(-50%, -50%)` about a fraction of the bezel box.
  static Widget _at(double d, double fx, double fy, Widget child) => Positioned(
        left: fx * d - _detent / 2,
        top: fy * d - _detent / 2,
        width: _detent,
        height: _detent,
        child: child,
      );
}

/// The bezel ring: `::before` (the well) and `::after` (the lit arc).
///
/// CSS->Flutter approximation: Flutter has no inset box-shadow, so the well's
/// `inset 0 10px 26px -18px black@0.9` and `inset 0 0 46px -24px glow@30%` are
/// approximated with a top-weighted vertical fade and an edge-tinted radial. The
/// conic arc converts exactly: CSS conic 0deg points UP and sweeps clockwise,
/// Flutter's SweepGradient starts at +x, so `flutterAngle = radians(cssDeg - 90)`.
class BezelPainter extends CustomPainter {
  BezelPainter({required this.glow});

  final Color glow;

  @override
  void paint(Canvas canvas, Size size) {
    final d = math.min(size.width, size.height);
    final r = d / 2;
    if (r <= 0) return;
    final centre = Offset(size.width / 2, size.height / 2);
    final rect = Rect.fromCircle(center: centre, radius: r);

    // --- the well: inner tint from the orb's glow, seated at the ring ---
    canvas.drawCircle(
      centre,
      r,
      Paint()
        ..shader = RadialGradient(
          colors: [glow.withValues(alpha: 0.0), glow.withValues(alpha: 0.30)],
          stops: const [0.72, 1.0],
        ).createShader(rect),
    );

    // --- the well: top-weighted inner darkening ---
    canvas.save();
    canvas.clipPath(Path()..addOval(rect));
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xE6000000), Color(0x00000000)],
          stops: [0.0, 0.30],
        ).createShader(rect),
    );
    canvas.restore();

    // --- the hairline border ---
    canvas.drawCircle(
      centre,
      r - 0.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.085),
    );

    // --- the lit arc, tinted by the orb, with its drop-shadow glow ---
    final shader = SweepGradient(
      startAngle: 0,
      endAngle: 2 * math.pi,
      transform: GradientRotation(_radians(215 - 90)),
      colors: [
        glow.withValues(alpha: 0.0),
        glow.withValues(alpha: 0.85),
        glow.withValues(alpha: 0.0),
        glow.withValues(alpha: 0.0),
      ],
      stops: const [0.0, 55 / 360, 130 / 360, 1.0],
    ).createShader(rect);

    // opacity: 0.65 on ::after — applied once to the arc AND its glow together.
    canvas.saveLayer(
        rect.inflate(12), Paint()..color = Colors.white.withValues(alpha: 0.65));
    canvas.drawCircle(
      centre,
      r - 0.75,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..shader = shader
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5), // drop-shadow 5px
    );
    canvas.drawCircle(
      centre,
      r - 0.75,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..shader = shader,
    );
    canvas.restore();
  }

  static double _radians(num degrees) => degrees * math.pi / 180.0;

  @override
  bool shouldRepaint(covariant BezelPainter oldDelegate) => oldDelegate.glow != glow;
}

/// One machined control on the bezel's rim (`.detent`). PTT/ABI get the amber
/// "on" ring (`:has(input:checked)`); power is a plain button whose ON state only
/// recolours the icon (`setPower()` toggles `.text-success` / `.opacity-50`).
class OrbDetent extends StatelessWidget {
  const OrbDetent({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.label,
    this.on = false,
    this.iconColor,
    this.dimmed = false,
    this.enabled = true,
  });

  final HeroIcon icon;
  final String tooltip;
  final VoidCallback onTap;
  final String? label;
  final bool on;
  final Color? iconColor;
  final bool dimmed;

  /// A detent whose action cannot land yet — the connection is not up. Inert
  /// AND visibly dimmed: a live-looking control that does nothing reads as a
  /// bug, which is exactly what the pre-join power tap did.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final body = GestureDetector(
      onTap: enabled ? onTap : null,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 37,
            height: 37,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF0A0C14),
              gradient: const RadialGradient(
                center: Alignment(-0.24, -0.40), // circle at 38% 30%
                radius: 0.65,
                colors: [Color(0x12FFFFFF), Color(0x03FFFFFF)],
              ),
              border: Border.all(
                color: on
                    ? M.you.withValues(alpha: 0.55)
                    : const Color(0xFFFFFFFF).withValues(alpha: 0.1),
              ),
              boxShadow: [
                if (on)
                  BoxShadow(
                    color: M.you.withValues(alpha: 0.8),
                    blurRadius: 16,
                    spreadRadius: -4,
                  ),
                const BoxShadow(
                  color: Color(0xE6000000),
                  offset: Offset(0, 3),
                  blurRadius: 9,
                  spreadRadius: -3,
                ),
              ],
            ),
            child: Center(
              child: HeroIconView(
                icon,
                size: 15,
                color: iconColor ?? (on ? M.you : M.chrome.withValues(alpha: 0.55)),
              ),
            ),
          ),
          if (label != null)
            Positioned(
              top: 41, // calc(100% + 4px)
              left: -20,
              right: -20,
              child: Text(
                label!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: kDisplayFamily,
                  fontSize: 7.36, // 0.46rem
                  fontWeight: FontWeight.w600,
                  fontVariations: MType.wght(650), // CSS 650, exactly
                  letterSpacing: MType.track(7.36, 0.3),
                  color: on
                      ? M.you.withValues(alpha: 0.7)
                      : M.chromeDim.withValues(alpha: 0.36),
                ),
              ),
            ),
        ],
      ),
    );

    final wrapped = Tooltip(message: tooltip, child: body);
    return (dimmed || !enabled) ? Opacity(opacity: 0.5, child: wrapped) : wrapped;
  }
}

/// The portrait-only light-pipe bridging the bezel's glow toward the transcript
/// spine. `viewBox="0 0 100 30" preserveAspectRatio="none"` with a NON-SCALING
/// 1.5px stroke — so the path is built in the scaled space and stroked at a
/// constant width, never wrapped in a Transform (which would scale the stroke).
/// The CSS `margin-top: -6px` is folded into the box height by the caller.
class ElbowPainter extends CustomPainter {
  ElbowPainter({required this.glow});

  final Color glow;

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 100.0;
    final sy = size.height / 30.0;
    Offset p(double x, double y) => Offset(x * sx, y * sy);

    // d="M50 0 C 50 18, 36 10, 36 30"
    final path = Path()
      ..moveTo(p(50, 0).dx, p(50, 0).dy)
      ..cubicTo(p(50, 18).dx, p(50, 18).dy, p(36, 10).dx, p(36, 10).dy, p(36, 30).dx,
          p(36, 30).dy);

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = glow.withValues(alpha: 0.6)
        ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 2.5), // drop-shadow 5px
    );
  }

  @override
  bool shouldRepaint(covariant ElbowPainter oldDelegate) => oldDelegate.glow != glow;
}
