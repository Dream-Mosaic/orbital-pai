import 'package:flutter/material.dart';

import '../tokens.dart';
import 'card_frame.dart';
import 'weather_glyph.dart';

/// One column of a [ForecastStrip]: an hour ("3PM", its temperature) or a day
/// ("Sun", its high over its low). Every string display-ready from the server.
@immutable
class ForecastColumn {
  const ForecastColumn({
    required this.label,
    required this.value,
    this.icon,
    this.low = '',
    this.precip,
  });

  final String label;

  /// The hour's temperature, or the day's high.
  final String value;

  /// A [WeatherGlyph] key; null or unknown draws an empty slot.
  final String? icon;

  /// The day's low; drawn only by a daily strip.
  final String low;

  /// The chance of rain, when worth showing.
  final String? precip;
}

/// Six hours or five days, one column each, every row aligned across columns
/// (a missing precip leaves its slot empty rather than shifting the rest up).
///
/// The weather card's strip, shared with the wall's Today board. [scale]
/// multiplies every size and gap: the card draws it at 1, exactly as it
/// always did; the board, read from across the room, larger.
class ForecastStrip extends StatelessWidget {
  const ForecastStrip({
    super.key,
    required this.columns,
    required this.daily,
    this.scale = 1,
  });

  final List<ForecastColumn> columns;

  /// Days carry a low under the high; hours do not.
  final bool daily;

  final double scale;

  static const Color rain = Color(0xFF6CC8F2);

  @override
  Widget build(BuildContext context) {
    final s = scale;
    final anyPrecip = columns.any((c) => c.precip != null);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final c in columns)
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  c.label,
                  maxLines: 1,
                  softWrap: false,
                  style: CardStyle.numeral(
                    8.8 * s,
                    colour: M.inkDim.withValues(alpha: 0.72),
                    weight: 520,
                  ).copyWith(letterSpacing: 0.2 * s),
                ),
                SizedBox(height: 4 * s),
                WeatherGlyph(c.icon, size: 17 * s),
                SizedBox(height: 4 * s),
                Text(
                  c.value,
                  maxLines: 1,
                  softWrap: false,
                  style: CardStyle.numeral(11.5 * s,
                      colour: M.ink.withValues(alpha: 0.92)),
                ),
                if (daily) ...[
                  SizedBox(height: 2 * s),
                  Text(
                    c.low,
                    maxLines: 1,
                    softWrap: false,
                    style: CardStyle.numeral(10.5 * s,
                        colour: M.inkDim.withValues(alpha: 0.58)),
                  ),
                ],
                if (anyPrecip) ...[
                  SizedBox(height: 2.5 * s),
                  Text(
                    c.precip ?? '',
                    maxLines: 1,
                    softWrap: false,
                    style:
                        CardStyle.numeral(8.6 * s, colour: rain, weight: 560),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}
