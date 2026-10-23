import 'package:flutter/material.dart';

import '../tokens.dart';
import 'card_frame.dart';
import 'forecast_strip.dart';
import 'weather_glyph.dart';

/// `get_weather` as a glance: the headline temperature and sky, today's range,
/// three labelled stats, the next six hours and the next five days.
class WeatherCard extends StatelessWidget {
  const WeatherCard({super.key, required this.data});

  final Map<String, dynamic> data;

  static const Color accent = M.briefing;

  @override
  Widget build(BuildContext context) {
    final details = data.rows('details');
    final hourly = data.rows('hourly');
    final daily = data.rows('daily');
    return CardFrame(
      accent: accent,
      label: data.str('location') ?? '',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _headline(),
          if (details.isNotEmpty) ...[
            const SizedBox(height: 8),
            _details(details),
          ],
          if (hourly.isNotEmpty) ...[
            const CardRule(vertical: 7),
            ForecastStrip(columns: _columns(hourly, daily: false), daily: false),
          ],
          if (daily.isNotEmpty) ...[
            const CardRule(vertical: 7),
            ForecastStrip(columns: _columns(daily, daily: true), daily: true),
          ],
        ],
      ),
    );
  }

  /// The card's rows as strip columns; a missing field renders as absent.
  static List<ForecastColumn> _columns(List<Map<String, dynamic>> rows, {required bool daily}) => [
        for (final e in rows)
          ForecastColumn(
            label: e.str('label') ?? '',
            value: e.str(daily ? 'hi' : 'temp') ?? '',
            icon: e.str('icon'),
            low: e.str('lo') ?? '',
            precip: e.str('precip'),
          ),
      ];

  Widget _headline() {
    final temp = data.str('temp');
    final condition = data.str('condition');
    final hi = data.str('hi');
    final lo = data.str('lo');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (temp != null)
                Text(
                  temp,
                  style: CardStyle.numeral(36, weight: 340).copyWith(
                    letterSpacing: -1.1,
                    height: 0.95,
                  ),
                ),
              if (condition != null) ...[
                const SizedBox(height: 3),
                Text(
                  condition,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CardStyle.body(12.5, colour: M.brainBody),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            WeatherGlyph(data.str('icon'), size: 38),
            if (hi != null || lo != null) ...[
              const SizedBox(height: 3),
              Text.rich(
                TextSpan(children: [
                  if (hi != null)
                    TextSpan(
                      text: hi,
                      style: CardStyle.numeral(11.5, colour: M.ink.withValues(alpha: 0.92)),
                    ),
                  if (hi != null && lo != null)
                    TextSpan(text: '  ', style: CardStyle.numeral(11.5)),
                  if (lo != null)
                    TextSpan(
                      text: lo,
                      style: CardStyle.numeral(11.5, colour: M.inkDim.withValues(alpha: 0.62)),
                    ),
                ]),
              ),
            ],
          ],
        ),
      ],
    );
  }

  /// Natural widths, spread edge to edge: the first stat hugs the left, the
  /// last the right, so a long label never runs into its neighbour.
  Widget _details(List<Map<String, dynamic>> details) {
    final last = details.length - 1;
    return Row(
      mainAxisAlignment:
          details.length == 1 ? MainAxisAlignment.start : MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < details.length; i++)
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
                  (details[i].str('label') ?? '').toUpperCase(),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.fade,
                  style: CardStyle.label(M.chromeDim.withValues(alpha: 0.42), size: 6.4),
                ),
                const SizedBox(height: 4),
                Text(
                  details[i].str('value') ?? '',
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.fade,
                  style: CardStyle.numeral(11, colour: M.ink.withValues(alpha: 0.86)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
