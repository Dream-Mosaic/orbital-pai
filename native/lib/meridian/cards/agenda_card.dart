import 'package:flutter/material.dart';

import '../tokens.dart';
import 'card_frame.dart';

/// `get_calendar_events` as an agenda: a time column, the event, and a quiet
/// line under it (where, and whose calendar when more than one was read). A
/// multi-day range groups under the server's day labels.
class AgendaCard extends StatelessWidget {
  const AgendaCard({super.key, required this.data});

  final Map<String, dynamic> data;

  static const Color accent = M.henry;

  /// Wide enough for "11:30 AM" — with its meridiem set small — and air
  /// before the title. The title column is what's scarce on a phone.
  static const double _timeColumn = 48;

  @override
  Widget build(BuildContext context) {
    final events = data.rows('events');
    final rows = <Widget>[];
    String? lastDay;
    for (final e in events) {
      final day = e.str('day');
      if (day != null && day != lastDay) {
        rows.add(Padding(
          padding: EdgeInsets.only(top: rows.isEmpty ? 0 : 5, bottom: 2),
          child: Text(
            day.toUpperCase(),
            style: CardStyle.label(M.chromeDim.withValues(alpha: 0.46), size: 6.6),
          ),
        ));
        lastDay = day;
      }
      rows.add(_event(e));
    }
    return CardFrame(
      accent: accent,
      label: data.str('title') ?? '',
      trailing: data.str('subtitle'),
      footer: data.str('note'),
      footerTrailing: data.str('more'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: rows,
      ),
    );
  }

  Widget _event(Map<String, dynamic> e) {
    final location = e.str('location');
    final account = e.str('account');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _timeColumn,
            child: Padding(
              // sit the time on the title's first line
              padding: const EdgeInsets.only(top: 2.6),
              child: _time(e.str('time') ?? ''),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  e.str('title') ?? '',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: CardStyle.body(12.5, colour: M.brainBody, weight: 460),
                ),
                if (location != null || account != null) ...[
                  const SizedBox(height: 2),
                  // Whose calendar leads, set as a small engraved label so it
                  // reads as a tag without a pill's width; where follows and
                  // is what yields to an ellipsis.
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      if (account != null) CardSource(account),
                      if (location != null && account != null) const SizedBox(width: 7),
                      if (location != null)
                        Flexible(
                          child: Text(
                            location,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: CardStyle.meta(10.2),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The server's time label, set with its meridiem small ("5:30" + "PM") so
  /// the column stays narrow. Anything that isn't a clock time ("All day")
  /// renders whole, dimmed.
  Widget _time(String time) {
    final clock = RegExp(r'^(.*\d)\s*([AaPp][Mm])$').firstMatch(time);
    if (clock == null) {
      return Text(
        time,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.fade,
        style: CardStyle.numeral(10, colour: M.inkDim.withValues(alpha: 0.7), weight: 520),
      );
    }
    final colour = accent.withValues(alpha: 0.92);
    return Text.rich(
      TextSpan(children: [
        TextSpan(
          text: clock.group(1),
          style: CardStyle.numeral(10.6, colour: colour, weight: 560),
        ),
        TextSpan(
          text: ' ${clock.group(2)}',
          style: CardStyle.numeral(7.2, colour: colour.withValues(alpha: 0.75), weight: 600)
              .copyWith(letterSpacing: 0.3),
        ),
      ]),
      maxLines: 1,
      softWrap: false,
    );
  }
}
