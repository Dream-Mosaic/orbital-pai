import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../panels/books_client.dart';
import 'cards/card_frame.dart';
import 'tokens.dart';

/// A tracker's month: one slot per day, oldest left.
///
/// Its FORM follows the data. Bars, growing from a zero baseline, for counts
/// and for scores that live near zero (pain 2–8): a measured tracker's bar is
/// that day's worst value against the month's highest; a habit tracker's (no
/// values at all) is that day's count against its busiest day. But a measure
/// that lives in a tight band far from zero (weight, 181–184 lb) is a LINE
/// scaled to that band: zero-based bars would flatten it into a row of equal
/// columns, and bars from a lifted base would lie about magnitude — a line
/// carries change over time honestly without either.
///
/// A day logged without a value on a measured tracker is a small dot —
/// present, not measured. An empty day is a faint tick on the baseline, so a
/// gap reads as a gap rather than as nothing. The highest day is drawn
/// full-strength with its value above it, in ink — the one direct label;
/// every other day is a touch away ([TrackerChart]'s readout). A [selected]
/// day lifts the same way.
class TrackerBarsPainter extends CustomPainter {
  TrackerBarsPainter({
    required this.points,
    required this.colour,
    this.selected,
    this.peakStyle,
  });

  final List<TrackerPoint> points;
  final Color colour;
  final int? selected;

  /// The peak's label; null draws none.
  final TextStyle? peakStyle;

  static const Color _baseline = Color(0x1AFFFFFF);
  static const Color _empty = Color(0x2EFFFFFF);

  /// True when the values sit in a band narrower than half their height
  /// above zero — the case bars from zero cannot show.
  static bool isBand(List<TrackerPoint> points) {
    final vs = [
      for (final p in points)
        if (p.value != null) p.value!
    ];
    if (vs.length < 2) return false;
    final lo = vs.reduce(math.min);
    final hi = vs.reduce(math.max);
    return lo > 0 && hi - lo < hi * 0.5;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty || size.width <= 0) return;
    final n = points.length;
    final slot = size.width / n;
    // Never fill the slot: the leftover is the 2px+ gap between bars.
    final barW = (slot - math.max(2.0, slot * 0.36)).clamp(2.0, 12.0);
    final floor = size.height - 0.5;
    final headroom = peakStyle != null ? 15.0 : 0.0;
    final room = floor - headroom - 1;

    canvas.drawLine(
      Offset(0, floor + 0.5),
      Offset(size.width, floor + 0.5),
      Paint()
        ..color = _baseline
        ..strokeWidth = 1,
    );

    if (isBand(points)) {
      _paintLine(canvas, size, slot, floor, headroom);
      return;
    }

    final valued = points.any((p) => p.value != null);
    final hi = valued
        ? points.map((p) => p.value ?? 0).reduce(math.max)
        : points.map((p) => p.count).reduce(math.max).toDouble();

    double? fraction(TrackerPoint p) {
      if (valued) {
        final v = p.value;
        if (v == null) return null;
        if (hi <= 0) return 0.06;
        return (v / hi).clamp(0.06, 1.0);
      }
      if (p.count <= 0 || hi <= 0) return null;
      // A habit day is present; more entries that day stand taller.
      return 0.4 + 0.6 * (p.count / hi);
    }

    final peakIndex = points.indexWhere((p) => p.peak.isNotEmpty);
    final r = Radius.circular(math.min(barW / 2, 3.0));

    for (var i = 0; i < n; i++) {
      final p = points[i];
      final cx = slot * (i + 0.5);
      final f = fraction(p);
      final lifted = i == peakIndex || i == selected;

      if (i == selected) _paintSelection(canvas, cx, slot, floor);

      if (f == null) {
        if (p.logged) {
          // Logged, but nothing measured: a dot just off the baseline.
          canvas.drawCircle(Offset(cx, floor - 4.1), 2.6,
              Paint()..color = colour.withValues(alpha: lifted ? 1 : 0.7));
        } else {
          _paintEmpty(canvas, cx, floor, barW);
        }
        continue;
      }

      final h = math.max(3.0, room * f);
      final rect = Rect.fromLTWH(cx - barW / 2, floor - h, barW, h);
      final rr = RRect.fromRectAndCorners(rect, topLeft: r, topRight: r);
      if (lifted) {
        canvas.drawRRect(
          rr,
          Paint()
            ..color = colour.withValues(alpha: 0.45)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
        );
      }
      canvas.drawRRect(
        rr,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: lifted
                ? [colour, colour.withValues(alpha: 0.72)]
                : [
                    colour.withValues(alpha: 0.66),
                    colour.withValues(alpha: 0.3)
                  ],
          ).createShader(rect),
      );

      if (i == peakIndex) _paintPeakLabel(canvas, size, p.peak, cx, rect.top);
    }
  }

  /// The band case: a 2px line through the measured days over a 10% wash,
  /// each reading a small dot, the peak and the touched day a full marker.
  void _paintLine(
      Canvas canvas, Size size, double slot, double floor, double headroom) {
    final idx = [
      for (var i = 0; i < points.length; i++)
        if (points[i].value != null) i,
    ];
    final vs = [for (final i in idx) points[i].value!];
    final lo = vs.reduce(math.min);
    final hi = vs.reduce(math.max);
    final top = headroom + 4;
    final bottom = floor - 10;
    double x(int i) => slot * (i + 0.5);
    double y(double v) => hi == lo
        ? (top + bottom) / 2
        : bottom - (bottom - top) * (v - lo) / (hi - lo);

    for (var i = 0; i < points.length; i++) {
      if (i == selected) _paintSelection(canvas, x(i), slot, floor);
      if (!points[i].logged) _paintEmpty(canvas, x(i), floor, 3);
    }

    final line = Path()..moveTo(x(idx.first), y(vs.first));
    for (var k = 1; k < idx.length; k++) {
      line.lineTo(x(idx[k]), y(vs[k]));
    }
    final area = Path.from(line)
      ..lineTo(x(idx.last), floor)
      ..lineTo(x(idx.first), floor)
      ..close();
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            colour.withValues(alpha: 0.16),
            colour.withValues(alpha: 0.0)
          ],
        ).createShader(Rect.fromLTWH(0, top, size.width, floor - top)),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = colour.withValues(alpha: 0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );

    final peakIndex = points.indexWhere((p) => p.peak.isNotEmpty);
    for (final i in idx) {
      final c = Offset(x(i), y(points[i].value!));
      final big = i == peakIndex || i == selected || i == idx.last;
      if (big) {
        // A 2px ring in the surface colour keeps the marker legible on the line.
        canvas.drawCircle(c, 5.5, Paint()..color = const Color(0xFF0F1119));
        canvas.drawCircle(c, 3.6, Paint()..color = colour);
      } else {
        canvas.drawCircle(
            c, 1.6, Paint()..color = colour.withValues(alpha: 0.75));
      }
      if (i == peakIndex) {
        _paintPeakLabel(canvas, size, points[i].peak, c.dx, c.dy - 5);
      }
    }
  }

  void _paintSelection(Canvas canvas, double cx, double slot, double floor) =>
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(cx - slot / 2 + 0.5, 0, slot - 1, floor),
          const Radius.circular(3),
        ),
        Paint()..color = const Color(0x0FFFFFFF),
      );

  void _paintEmpty(Canvas canvas, double cx, double floor, double barW) =>
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
              center: Offset(cx, floor - 1),
              width: math.min(barW, 3.0),
              height: 2),
          const Radius.circular(1),
        ),
        Paint()..color = _empty,
      );

  void _paintPeakLabel(
      Canvas canvas, Size size, String text, double cx, double above) {
    final style = peakStyle;
    if (style == null || text.isEmpty) return;
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final x = (cx - tp.width / 2).clamp(0.0, size.width - tp.width);
    tp.paint(canvas, Offset(x, math.max(0.0, above - tp.height - 3)));
  }

  @override
  bool shouldRepaint(TrackerBarsPainter old) =>
      old.points != points ||
      old.colour != colour ||
      old.selected != selected ||
      old.peakStyle != peakStyle;
}

/// A tracker's month in miniature, for its row in the book: a glyph of its
/// SHAPE, not a chart to read values off (the detail is that). A measured
/// tracker is a thin line through its logged days, scaled to its own
/// low–high band — the trend is the point at this size, and bars from zero
/// would flatten a weight (181–184 lb) into a barcode — with the latest
/// reading dotted. A habit tracker is a row of days: lit where logged, faint
/// where not.
class TrackerSparkPainter extends CustomPainter {
  TrackerSparkPainter({required this.points, required this.colour});

  final List<TrackerPoint> points;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty || size.width <= 0) return;
    final slot = size.width / points.length;
    double x(int i) => slot * (i + 0.5);

    final valued = [
      for (var i = 0; i < points.length; i++)
        if (points[i].value != null) i,
    ];

    if (valued.isEmpty) {
      // A habit: one tick per day, standing where it was logged.
      final w = math.max(1.0, slot * 0.62);
      for (var i = 0; i < points.length; i++) {
        final on = points[i].logged;
        final h = on ? size.height * 0.62 : 2.0;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x(i) - w / 2, size.height - 1 - h, w, h),
            Radius.circular(w / 2),
          ),
          Paint()
            ..color =
                on ? colour.withValues(alpha: 0.8) : const Color(0x2EFFFFFF),
        );
      }
      return;
    }

    final vs = [for (final i in valued) points[i].value!];
    final lo = vs.reduce(math.min);
    final hi = vs.reduce(math.max);
    const pad = 3.0;
    double y(double v) => hi == lo
        ? size.height / 2
        : pad + (size.height - 2 * pad) * (1 - (v - lo) / (hi - lo));

    // A faint baseline of every day, so the line sits on the month it spans.
    canvas.drawLine(
      Offset(0, size.height - 0.5),
      Offset(size.width, size.height - 0.5),
      Paint()
        ..color = const Color(0x14FFFFFF)
        ..strokeWidth = 1,
    );

    if (valued.length > 1) {
      final path = Path()
        ..moveTo(x(valued.first), y(points[valued.first].value!));
      for (final i in valued.skip(1)) {
        path.lineTo(x(i), y(points[i].value!));
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = colour.withValues(alpha: 0.8)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round,
      );
    }
    final last = valued.last;
    canvas.drawCircle(
        Offset(x(last), y(points[last].value!)), 2.4, Paint()..color = colour);
  }

  @override
  bool shouldRepaint(TrackerSparkPainter old) =>
      old.points != points || old.colour != colour;
}

/// The detail's chart: the bars, their axis, and a readout line above them
/// that names the touched day (the server's `tip`), or [caption] when
/// nothing is touched. Tap a day to read it; drag across to scrub; tap it
/// again to let go.
class TrackerChart extends StatefulWidget {
  const TrackerChart({
    super.key,
    required this.points,
    required this.colour,
    required this.caption,
    this.axisFrom = '',
    this.axisTo = '',
    this.height = 92,
  });

  final List<TrackerPoint> points;
  final Color colour;
  final String caption;
  final String axisFrom;
  final String axisTo;
  final double height;

  static const Key barsKey = ValueKey('tracker-chart-bars');
  static const Key readoutKey = ValueKey('tracker-chart-readout');

  @override
  State<TrackerChart> createState() => _TrackerChartState();
}

class _TrackerChartState extends State<TrackerChart> {
  int? _selected;

  int? _indexAt(double dx, double width) {
    final n = widget.points.length;
    if (n == 0 || width <= 0) return null;
    return (dx / (width / n)).floor().clamp(0, n - 1);
  }

  void _pick(double dx, double width, {bool toggle = false}) {
    final i = _indexAt(dx, width);
    setState(() => _selected = (toggle && i == _selected) ? null : i);
  }

  @override
  void didUpdateWidget(TrackerChart old) {
    super.didUpdateWidget(old);
    final s = _selected;
    if (s != null && s >= widget.points.length) _selected = null;
  }

  @override
  Widget build(BuildContext context) {
    final s = _selected;
    final tip = s == null ? '' : widget.points[s].tip;
    final axis = CardStyle.numeral(9.4,
        colour: M.inkDim.withValues(alpha: 0.7), weight: 500);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 16,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              tip.isNotEmpty ? tip : widget.caption.toUpperCase(),
              key: TrackerChart.readoutKey,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tip.isNotEmpty
                  ? CardStyle.body(12, colour: M.ink, weight: 520, height: 1.2)
                  : CardStyle.label(widget.colour.withValues(alpha: 0.9),
                      size: 8.6),
            ),
          ),
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, c) => GestureDetector(
            key: TrackerChart.barsKey,
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => _pick(d.localPosition.dx, c.maxWidth, toggle: true),
            onHorizontalDragStart: (d) => _pick(d.localPosition.dx, c.maxWidth),
            onHorizontalDragUpdate: (d) =>
                _pick(d.localPosition.dx, c.maxWidth),
            child: SizedBox(
              height: widget.height,
              width: c.maxWidth,
              child: CustomPaint(
                painter: TrackerBarsPainter(
                  points: widget.points,
                  colour: widget.colour,
                  selected: _selected,
                  peakStyle: CardStyle.numeral(10.5,
                      colour: M.ink.withValues(alpha: 0.92), weight: 560),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(widget.axisFrom, style: axis),
            const Spacer(),
            Text(widget.axisTo, style: axis),
          ],
        ),
      ],
    );
  }
}
