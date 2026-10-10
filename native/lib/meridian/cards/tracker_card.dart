import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../tokens.dart';
import 'card_frame.dart';

/// `get_tracker_entries` as a glance: the headline stats, a month of days as a
/// bar strip (one bar per day with an entry, a faint tick for a day without,
/// the peak called out), the commonest tags, and the newest few entries.
class TrackerCard extends StatelessWidget {
  const TrackerCard({super.key, required this.data});

  final Map<String, dynamic> data;

  static const Color accent = M.tracker;

  @override
  Widget build(BuildContext context) {
    final stats = data.rows('stats');
    final series = data.rows('series');
    final tags = data.strs('top_tags');
    final recent = data.rows('recent');
    return CardFrame(
      accent: accent,
      label: data.str('title') ?? '',
      trailing: data.str('range'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (stats.isNotEmpty) _stats(stats),
          if (series.isNotEmpty) ...[
            const SizedBox(height: 11),
            TrackerStrip(series: series, colour: accent),
          ],
          if (tags.isNotEmpty) ...[
            const SizedBox(height: 9),
            TagRun(tags, colour: accent),
          ],
          if (recent.isNotEmpty) ...[
            const CardRule(vertical: 8),
            for (var n = 0; n < recent.length; n++) ...[
              if (n > 0) const SizedBox(height: 6),
              _entry(recent[n]),
            ],
          ],
        ],
      ),
    );
  }

  /// The weather card's labelled stats, set larger: here they ARE the headline.
  Widget _stats(List<Map<String, dynamic>> stats) {
    final last = stats.length - 1;
    return Row(
      mainAxisAlignment:
          stats.length == 1 ? MainAxisAlignment.start : MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < stats.length; i++)
          Flexible(
            child: Column(
              crossAxisAlignment: i == 0
                  ? CrossAxisAlignment.start
                  : i == last
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  (stats[i].str('label') ?? '').toUpperCase(),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.fade,
                  style: CardStyle.label(M.chromeDim.withValues(alpha: 0.42), size: 6.4),
                ),
                const SizedBox(height: 5),
                Text(
                  stats[i].str('value') ?? '',
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.fade,
                  style: CardStyle.numeral(17, weight: 420).copyWith(letterSpacing: -0.3),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// One entry: its value in a small tinted tile, the note beside it and when
  /// under that. A habit entry (no value) gets a quiet dot in the tile.
  Widget _entry(Map<String, dynamic> e) {
    final value = e.str('value');
    final note = e.str('note');
    final when = e.str('when');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _ValueTile(value: value, colour: accent),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (note != null)
                Text(
                  note,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CardStyle.body(11.5, colour: M.brainBody, weight: 440),
                ),
              if (when != null) ...[
                if (note != null) const SizedBox(height: 1.5),
                Text(
                  when,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CardStyle.numeral(
                    note == null ? 10.6 : 9.6,
                    colour: note == null
                        ? M.ink.withValues(alpha: 0.8)
                        : M.inkDim.withValues(alpha: 0.72),
                    weight: 500,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// `log_tracker_entry`: what was just saved — value, tracker, note and tags —
/// so a mishearing ("a 6" heard as "a 16") is caught at a glance.
class TrackerLoggedCard extends StatelessWidget {
  const TrackerLoggedCard({super.key, required this.data});

  final Map<String, dynamic> data;

  static const Color accent = M.tracker;

  @override
  Widget build(BuildContext context) {
    final note = data.str('note');
    final tags = data.strs('tags');
    return CardFrame(
      accent: accent,
      label: data.str('label') ?? '',
      trailing: data.str('when'),
      footer: data.str('summary'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _ValueTile(value: data.str('value'), colour: accent, size: 38),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      data.str('title') ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: CardStyle.body(14, colour: M.ink, weight: 560, height: 1.2),
                    ),
                    if (note != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        note,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: CardStyle.body(11, colour: M.inkDim.withValues(alpha: 0.92)),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (tags.isNotEmpty) ...[
            const SizedBox(height: 9),
            Wrap(
              spacing: 5,
              runSpacing: 5,
              children: [for (final t in tags) TagPill(t, colour: accent)],
            ),
          ],
        ],
      ),
    );
  }
}

/// A tag the user gave ("skipped lunch") as a soft lowercase pill: their own
/// words, so they keep their case rather than being engraved in capitals.
class TagPill extends StatelessWidget {
  const TagPill(this.text, {super.key, required this.colour});

  final String text;
  final Color colour;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(7, 2.5, 7, 3),
        decoration: BoxDecoration(
          color: colour.withValues(alpha: 0.08),
          border: Border.all(color: colour.withValues(alpha: 0.24)),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: CardStyle.body(10.2,
              colour: colour.withValues(alpha: 0.95), weight: 500, height: 1.2),
        ),
      );
}

/// The commonest tags as one flowing run ("skipped lunch ×3   poor sleep ×2
/// …"): pills would stack one per row in a phone's column. The server's tally
/// suffix is set as a dimmer numeral, which is also what separates one tag from
/// the next — no dots left dangling at a line's end.
class TagRun extends StatelessWidget {
  const TagRun(this.tags, {super.key, required this.colour});

  final List<String> tags;
  final Color colour;

  static final RegExp _tally = RegExp(r'^(.*?)(\s×\d+)$');

  @override
  Widget build(BuildContext context) {
    final word = CardStyle.body(10.8, colour: colour.withValues(alpha: 0.95), weight: 500);
    final tally = CardStyle.numeral(9.8, colour: colour.withValues(alpha: 0.55), weight: 560);
    return Text.rich(
      TextSpan(children: [
        for (var n = 0; n < tags.length; n++) ...[
          if (n > 0) TextSpan(text: '    ', style: word),
          // no-break spaces inside a tag: a line wraps between tags, not in one
          for (final m in [_tally.firstMatch(tags[n])])
            if (m == null)
              TextSpan(text: tags[n].replaceAll(' ', '\u00A0'), style: word)
            else ...[
              TextSpan(text: m.group(1)!.replaceAll(' ', '\u00A0'), style: word),
              TextSpan(text: m.group(2)!.replaceAll(' ', '\u00A0'), style: tally),
            ],
        ],
      ]),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// A value in a small rounded tile tinted with the tracker's colour; with no
/// value (a habit, "no soda today") the tile holds a tick — the entry itself
/// is the data point.
class _ValueTile extends StatelessWidget {
  const _ValueTile({required this.value, required this.colour, this.size = 26});

  final String? value;
  final Color colour;
  final double size;

  @override
  Widget build(BuildContext context) {
    final big = size >= 34;
    return Container(
      constraints: BoxConstraints(minWidth: size, minHeight: size),
      padding: EdgeInsets.symmetric(horizontal: big ? 6 : 4),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(big ? 10 : 7),
        color: colour.withValues(alpha: 0.1),
        border: Border.all(color: colour.withValues(alpha: 0.3)),
      ),
      child: value == null
          ? SizedBox.square(
              dimension: big ? 16 : 11,
              child: CustomPaint(painter: _TickPainter(colour)),
            )
          : Text(
              value!,
              maxLines: 1,
              softWrap: false,
              style: CardStyle.numeral(big ? 19 : 12.5, colour: colour, weight: big ? 460 : 560),
            ),
    );
  }
}

class _TickPainter extends CustomPainter {
  const _TickPainter(this.colour);

  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final path = Path()
      ..moveTo(w * 0.16, w * 0.54)
      ..lineTo(w * 0.4, w * 0.76)
      ..lineTo(w * 0.84, w * 0.26);
    canvas.drawPath(
      path,
      Paint()
        ..color = colour
        ..style = PaintingStyle.stroke
        ..strokeWidth = w >= 14 ? 2 : 1.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_TickPainter old) => old.colour != colour;
}

/// One bar per day, oldest left. A day with a value is a bar scaled to it; a
/// day with only an entry (a habit) is a full-height bar; an empty day is a
/// faint tick on the baseline, so the gaps read as gaps rather than as nothing.
/// The server marks the peak, which is drawn brighter with its value above.
class TrackerStrip extends StatelessWidget {
  const TrackerStrip({super.key, required this.series, required this.colour});

  final List<Map<String, dynamic>> series;
  final Color colour;

  static const double barsHeight = 40;

  @override
  Widget build(BuildContext context) {
    final first = series.first.str('label');
    final last = series.length > 1 ? series.last.str('label') : null;
    final axis = CardStyle.numeral(8.4, colour: M.inkDim.withValues(alpha: 0.6), weight: 500);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: barsHeight,
          child: CustomPaint(
            painter: TrackerStripPainter(
              points: [for (final p in series) StripPoint.from(p)],
              colour: colour,
              peakStyle: CardStyle.numeral(8.6, colour: colour, weight: 600),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            if (first != null) Text(first, style: axis),
            const Spacer(),
            if (last != null) Text(last, style: axis),
          ],
        ),
      ],
    );
  }
}

@immutable
class StripPoint {
  const StripPoint({this.value, this.count = 0, this.peak});

  /// Lenient: a missing or mistyped field reads as an empty day.
  factory StripPoint.from(Map<String, dynamic> p) {
    final v = p['value'];
    final c = p['count'];
    return StripPoint(
      value: v is num ? v.toDouble() : null,
      count: c is num ? c.toInt() : (v is num ? 1 : 0),
      peak: p.str('peak'),
    );
  }

  final double? value;
  final int count;
  final String? peak;

  bool get logged => count > 0 || value != null;
}

class TrackerStripPainter extends CustomPainter {
  TrackerStripPainter({required this.points, required this.colour, required this.peakStyle});

  final List<StripPoint> points;
  final Color colour;
  final TextStyle peakStyle;

  /// Room above the tallest bar for the peak's value.
  static const double _headroom = 11;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final slot = size.width / points.length;
    final barW = (slot * 0.58).clamp(2.0, 9.0);
    final floor = size.height - 0.5;
    final room = floor - _headroom;

    // Baseline hairline.
    canvas.drawLine(
      Offset(0, floor + 0.5),
      Offset(size.width, floor + 0.5),
      Paint()
        ..color = const Color(0x14FFFFFF)
        ..strokeWidth = 1,
    );

    final values = [for (final p in points) if (p.value != null) p.value!];
    final hi = values.isEmpty ? 1.0 : values.reduce(math.max);
    final lo = values.isEmpty ? 0.0 : values.reduce(math.min);
    // A tight band far from zero (weight: 181–184) would draw as a row of equal
    // bars from a zero base; lift the base under it so the movement shows.
    final double base;
    if (lo > 0 && hi - lo < hi * 0.5) {
      base = hi == lo ? lo * 0.5 : lo - (hi - lo) * 0.8;
    } else {
      base = 0;
    }

    double fraction(StripPoint p) {
      if (p.value == null) return 0.72; // a habit day: present, not measured
      if (hi <= base) return 1;
      return ((p.value! - base) / (hi - base)).clamp(0.14, 1.0);
    }

    final rr = Radius.circular(math.min(barW / 2, 2.2));
    for (var i = 0; i < points.length; i++) {
      final p = points[i];
      final cx = slot * (i + 0.5);
      if (!p.logged) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset(cx, floor - 1.2), width: math.min(barW, 3), height: 2.4),
            const Radius.circular(1.2),
          ),
          Paint()..color = const Color(0x24FFFFFF),
        );
        continue;
      }
      final h = room * fraction(p);
      final rect = Rect.fromLTWH(cx - barW / 2, floor - h, barW, h);
      final peak = p.peak != null;
      if (peak) {
        canvas.drawRRect(
          RRect.fromRectAndCorners(rect, topLeft: rr, topRight: rr),
          Paint()
            ..color = colour.withValues(alpha: 0.55)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
        );
      }
      canvas.drawRRect(
        RRect.fromRectAndCorners(rect, topLeft: rr, topRight: rr),
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: peak
                ? [colour, colour.withValues(alpha: 0.62)]
                : [colour.withValues(alpha: 0.62), colour.withValues(alpha: 0.2)],
          ).createShader(rect),
      );
      if (peak) {
        final tp = TextPainter(
          text: TextSpan(text: p.peak, style: peakStyle),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();
        final x = (cx - tp.width / 2).clamp(0.0, size.width - tp.width);
        tp.paint(canvas, Offset(x, rect.top - tp.height - 2));
      }
    }
  }

  @override
  bool shouldRepaint(TrackerStripPainter old) =>
      old.points != points || old.colour != colour || old.peakStyle != peakStyle;
}
