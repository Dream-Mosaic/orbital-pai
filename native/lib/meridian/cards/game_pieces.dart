import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../tokens.dart';
import 'card_frame.dart';

/// The pieces game night's cards are drawn with: a die, a coin, and the scale
/// they share.
///
/// These cards are read from across a table, so they are drawn LARGE at the
/// width Henry's column gives a card on the wall (378dp, [kGameCardInner]
/// inside its padding) and scaled down, never up, for a narrower column — a
/// phone's 184dp card gets the same layout at [_minScale].
const double kGameCardInner = 354;
const double _minScale = 0.6;

/// How much of the wall-size drawing fits in [innerWidth].
double gameScale(double innerWidth) =>
    (innerWidth / kGameCardInner).clamp(_minScale, 1.0).toDouble();

/// Space Grotesk figures for a number read on its own — a total, a score, a
/// die. Proportional, not [CardStyle.numeral]'s tabular: the tabular 1 carries
/// a foot serif that, at display size, reads as a stray mark beside the digit.
TextStyle gameFigure(double size, {Color colour = M.ink, double weight = 500}) =>
    CardStyle.numeral(size, colour: colour, weight: weight).copyWith(fontFeatures: const []);

/// The side of each of [count] square tiles laid in [width] with [gap]
/// between them: one row while each stays at least [min], else as few rows as
/// keep them there; never larger than [max]. Floored, so a [Wrap] of them
/// never breaks a row early on a rounding error.
double tileSize(double width, int count,
    {required double max, required double min, double gap = 8}) {
  if (count <= 0 || width <= 0) return min;
  var rows = 1;
  while (true) {
    final perRow = (count / rows).ceil();
    final size = (width - gap * (perRow - 1)) / perRow;
    if (size >= min || perRow == 1) return math.min(max, size).floorToDouble();
    rows++;
  }
}

/// One die, as you'd see it on the table: an ivory face with pips when the
/// server says so (a d6), else its number.
class DieFace extends StatelessWidget {
  const DieFace({super.key, required this.value, required this.size, this.pips = false});

  final int value;
  final double size;

  /// Draw pips (only a d6's 1–6 has them); otherwise the number.
  final bool pips;

  @override
  Widget build(BuildContext context) => Semantics(
        label: '$value',
        child: SizedBox.square(
          dimension: size,
          child: CustomPaint(
              painter: _DiePainter(value: value, pips: pips && value >= 1 && value <= 6)),
        ),
      );
}

class _DiePainter extends CustomPainter {
  _DiePainter({required this.value, required this.pips});

  final int value;
  final bool pips;

  static const Color _pip = Color(0xFF151824);
  static const Color _ink = Color(0xFF1A1D29);

  // Pip centres on a 3×3 grid, by face. Two and three run corner to corner.
  static const double _a = 0.27, _b = 0.5, _c = 0.73;
  static const Map<int, List<Offset>> _faces = {
    1: [Offset(_b, _b)],
    2: [Offset(_c, _a), Offset(_a, _c)],
    3: [Offset(_c, _a), Offset(_b, _b), Offset(_a, _c)],
    4: [Offset(_a, _a), Offset(_c, _a), Offset(_a, _c), Offset(_c, _c)],
    5: [Offset(_a, _a), Offset(_c, _a), Offset(_b, _b), Offset(_a, _c), Offset(_c, _c)],
    6: [
      Offset(_a, _a),
      Offset(_c, _a),
      Offset(_a, _b),
      Offset(_c, _b),
      Offset(_a, _c),
      Offset(_c, _c),
    ],
  };

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final rect = Offset.zero & size;
    final face = RRect.fromRectAndRadius(rect, Radius.circular(s * 0.2));

    // The shadow it casts on the glass, then the ivory, lit from the top left.
    canvas.drawRRect(
      face.shift(Offset(0, s * 0.05)),
      Paint()
        ..color = const Color(0x8C000000)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.07),
    );
    canvas.drawRRect(
      face,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFCFAF4), Color(0xFFE9E4D7), Color(0xFFCCC5B4)],
          stops: [0, 0.55, 1],
        ).createShader(rect),
    );
    canvas.drawRRect(
      face.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0x33000000),
    );

    if (pips) {
      final r = s * (value == 1 ? 0.12 : 0.085);
      for (final o in _faces[value]!) {
        final c = Offset(o.dx * s, o.dy * s);
        // A lit lower lip, so each pip reads as drilled into the face.
        canvas.drawCircle(c.translate(0, s * 0.012), r, Paint()..color = const Color(0x99FFFFFF));
        canvas.drawCircle(
          c,
          r,
          Paint()
            ..shader = const RadialGradient(
              center: Alignment(-0.3, -0.35),
              colors: [Color(0xFF3B4054), _pip],
            ).createShader(Rect.fromCircle(center: c, radius: r)),
        );
      }
      return;
    }

    final digits = '$value';
    final tp = TextPainter(
      text: TextSpan(
        text: digits,
        style: TextStyle(
          fontFamily: kDisplayFamily,
          fontSize: s * (digits.length >= 3 ? 0.36 : 0.48),
          height: 1.0,
          fontWeight: FontWeight.w600,
          fontVariations: MType.wght(620),
          letterSpacing: digits.length >= 3 ? -s * 0.015 : 0,
          color: _ink,
          shadows: [Shadow(offset: Offset(0, s * 0.012), color: const Color(0x99FFFFFF))],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset((s - tp.width) / 2, (s - tp.height) / 2));
  }

  @override
  bool shouldRepaint(_DiePainter old) => old.value != value || old.pips != pips;
}

/// One coin: heads gold, tails silver — the side is legible by colour before
/// the letter on it is — with a raised rim and its mark struck in the middle.
class CoinDisc extends StatelessWidget {
  const CoinDisc({super.key, required this.heads, required this.mark, required this.size});

  final bool heads;
  final String mark;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: CustomPaint(painter: _CoinPainter(heads: heads, mark: mark)),
      );
}

class _CoinPainter extends CustomPainter {
  _CoinPainter({required this.heads, required this.mark});

  final bool heads;
  final String mark;

  static const List<Color> _gold = [Color(0xFFFCEBB4), Color(0xFFE4BF5E), Color(0xFFAD842B)];
  static const List<Color> _silver = [Color(0xFFF7F9FC), Color(0xFFCBD1DB), Color(0xFF8A92A1)];

  @override
  void paint(Canvas canvas, Size size) {
    final d = size.width;
    final c = Offset(d / 2, d / 2);
    final r = d / 2;
    final rect = Rect.fromCircle(center: c, radius: r);
    final metal = heads ? _gold : _silver;
    final deep = heads ? const Color(0xFF6B4F12) : const Color(0xFF3D4351);

    canvas.drawCircle(
      c.translate(0, d * 0.05),
      r,
      Paint()
        ..color = const Color(0x8C000000)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, d * 0.07),
    );
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.35, -0.4),
          radius: 1.05,
          colors: metal,
          stops: const [0, 0.55, 1],
        ).createShader(rect),
    );
    // The raised rim: a dark groove with a lit edge just inside it.
    canvas.drawCircle(
      c,
      r * 0.83,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, d * 0.022)
        ..color = deep.withValues(alpha: 0.45),
    );
    canvas.drawCircle(
      c.translate(0, d * 0.012),
      r * 0.83,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(0.75, d * 0.01)
        ..color = const Color(0x80FFFFFF),
    );
    canvas.drawCircle(
      c,
      r - 0.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = deep.withValues(alpha: 0.5),
    );

    final tp = TextPainter(
      text: TextSpan(
        text: mark,
        style: TextStyle(
          fontFamily: kDisplayFamily,
          fontSize: d * 0.42,
          height: 1.0,
          fontWeight: FontWeight.w700,
          fontVariations: MType.wght(680),
          color: deep,
          shadows: [Shadow(offset: Offset(0, d * 0.014), color: const Color(0x8CFFFFFF))],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(c.dx - tp.width / 2, c.dy - tp.height / 2));
  }

  @override
  bool shouldRepaint(_CoinPainter old) => old.heads != heads || old.mark != mark;
}
