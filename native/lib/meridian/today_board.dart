import 'package:flutter/material.dart';

import '../voice/glance.dart';
import 'cards/card_frame.dart';
import 'cards/forecast_strip.dart';
import 'tokens.dart';
import 'wall_type.dart';

/// The wall's Today board (spec 2026-10-23, wall tablet, phase 3): what takes
/// the thread's place once a wall has been at rest for a while — what's
/// coming up today and tomorrow, the next hours and days of weather, and
/// today's reminders. Any touch or turn brings the thread straight back (the
/// voice screen crossfades the two; see `MeridianVoiceScreen`).
///
/// Everything it shows is the server's `glance`, display-ready; this only
/// lays it out. Each section is omitted when the server sent nothing for it,
/// and with nothing at all it says so in one quiet line rather than leaving
/// a blank pane. It is only ever shown on a wall layout, so its sizes go
/// through [WallType] like every other part of the voice screen — set a step
/// larger than the thread, because at rest the board IS the screen's reading.
///
/// It never scrolls (nobody is touching it — a touch puts the thread back),
/// so a day fuller than the pane is scaled down to fit rather than cut off.
class TodayBoard extends StatelessWidget {
  const TodayBoard({super.key, required this.glance});

  final Glance glance;

  /// The crossfade: the board eases in, and gives way faster than it came.
  static const Duration fadeIn = Duration(milliseconds: 300);
  static const Duration fadeOut = Duration(milliseconds: 150);

  /// So tests can find the sections.
  static const Key agendaKey = ValueKey('today-agenda');
  static const Key weatherKey = ValueKey('today-weather');
  static const Key remindersKey = ValueKey('today-reminders');
  static const Key emptyKey = ValueKey('today-empty');

  static const String emptyLine = 'Nothing else today.';

  // Sizes, as the phone's would be; [WallType] raises them for the wall.
  static const double _sectionLabel = 9.6; // chrome → 12.5 on a wall
  static const double _dayLabel = 7.6; // chrome → the 11 floor
  static const double _title = 16; // body → 19.2
  static const double _time = 15; // body → 18
  static const double _meridiem = 10; // body → 12
  static const double _allDay = 12.5; // body → 15
  static const double _tag = 6.6; // chrome → the 11 floor
  static const double _empty = 15; // body → 18

  /// The time column: "12:30 PM" at the wall's size, and air before the
  /// title. Shared by the agenda and the reminders so their text aligns.
  static const double _timeColumn = 80; // body → 96

  /// The forecast strip's scale over the weather card's: 1.56 on a wall.
  static const double _strip = 1.3; // body → 1.56

  static const double _sectionGap = 18; // body → 21.6
  static const double _rowPad = 3.5; // body → 4.2

  @override
  Widget build(BuildContext context) {
    final type = WallType.of(context);
    final forecast = glance.forecast;
    final sections = <Widget>[
      if (glance.agenda.isNotEmpty)
        _Section(
          key: agendaKey,
          label: 'Coming up',
          accent: M.henry,
          child: _agenda(type),
        ),
      if (forecast != null)
        _Section(
          key: weatherKey,
          label: 'Weather',
          accent: M.briefing,
          child: _weather(type, forecast),
        ),
      if (glance.reminders.isNotEmpty)
        _Section(
          key: remindersKey,
          label: 'Reminders today',
          accent: M.followup,
          child: _reminders(type),
        ),
    ];

    if (sections.isEmpty) {
      return Center(
        child: Text(
          emptyLine,
          key: emptyKey,
          textAlign: TextAlign.center,
          style: CardStyle.body(type.body(_empty),
                  colour: M.chromeDim.withValues(alpha: 0.55))
              .copyWith(fontStyle: FontStyle.italic),
        ),
      );
    }

    final gap = type.body(_sectionGap);
    return LayoutBuilder(
      builder: (context, constraints) => Align(
        alignment: Alignment.topCenter,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: constraints.maxWidth,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < sections.length; i++) ...[
                    if (i > 0) SizedBox(height: gap),
                    sections[i],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---- coming up ----

  /// Grouped under the server's day labels, in the server's order.
  Widget _agenda(WallType type) {
    final rows = <Widget>[];
    String? lastDay;
    for (final item in glance.agenda) {
      if (item.day.isNotEmpty && item.day != lastDay) {
        rows.add(Padding(
          padding: EdgeInsets.only(
              top: rows.isEmpty ? 0 : type.body(8), bottom: type.body(3)),
          child: Text(
            item.day.toUpperCase(),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.fade,
            style: CardStyle.label(
                M.chromeDim.withValues(alpha: type.ink(0.36)),
                size: type.chrome(_dayLabel)),
          ),
        ));
        lastDay = item.day;
      }
      rows.add(_row(
        type,
        time: item.allDay
            ? _allDayLabel(type, item.time)
            : _clock(type, item.time, M.henry),
        text: item.title,
      ));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: rows,
    );
  }

  /// "All day" is not a time, so it is set quietly rather than in the accent
  /// (the agenda card's rule).
  Widget _allDayLabel(WallType type, String time) => Text(
        time.isEmpty ? 'All day' : time,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.fade,
        style: CardStyle.numeral(type.body(_allDay),
            colour: M.inkDim.withValues(alpha: 0.7), weight: 520),
      );

  // ---- weather ----

  /// The next hours, then the days after today, as one row of columns — the
  /// weather card's own strips side by side, a hairline between them.
  Widget _weather(WallType type, GlanceForecast f) {
    final scale = type.body(_strip);
    final hourly = [
      for (final h in f.hourly)
        ForecastColumn(
            label: h.label, value: h.temp, icon: h.icon, precip: h.precip),
    ];
    final daily = [
      for (final d in f.daily)
        ForecastColumn(
            label: d.label,
            value: d.hi,
            low: d.lo,
            icon: d.icon,
            precip: d.precip),
    ];
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hourly.isNotEmpty)
            Expanded(
              flex: hourly.length,
              child: ForecastStrip(columns: hourly, daily: false, scale: scale),
            ),
          if (hourly.isNotEmpty && daily.isNotEmpty)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: type.body(6)),
              child: Container(width: 1, color: CardStyle.edge),
            ),
          if (daily.isNotEmpty)
            Expanded(
              flex: daily.length,
              child: ForecastStrip(columns: daily, daily: true, scale: scale),
            ),
        ],
      ),
    );
  }

  // ---- reminders ----

  Widget _reminders(WallType type) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final r in glance.reminders)
            _row(
              type,
              time: _clock(type, r.time, M.followup),
              text: r.text,
              tag: r.household
                  ? CardTag('Shared',
                      colour: M.chromeDim, size: type.chrome(_tag))
                  : null,
            ),
        ],
      );

  // ---- shared ----

  /// A time column and the text beside it, on one baseline.
  Widget _row(WallType type,
          {required Widget time, required String text, Widget? tag}) =>
      Padding(
        padding: EdgeInsets.symmetric(vertical: type.body(_rowPad)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            SizedBox(width: type.body(_timeColumn), child: time),
            // Loose, so a tag follows its words rather than the far edge; a
            // long line still wraps before it.
            Flexible(
              child: Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: CardStyle.body(type.body(_title),
                    colour: M.brainBody, weight: 460),
              ),
            ),
            if (tag != null) ...[
              SizedBox(width: type.body(8)),
              tag,
            ],
          ],
        ),
      );

  /// The server's clock time with its meridiem set small ("7:30" + "PM"), in
  /// [accent] — the orb face's next event is the green the agenda takes. A
  /// string that is not a clock time renders whole.
  Widget _clock(WallType type, String time, Color accent) {
    final colour = accent.withValues(alpha: 0.92);
    final clock = RegExp(r'^(.*\d)\s*([AaPp][Mm])$').firstMatch(time);
    if (clock == null) {
      return Text(
        time,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.fade,
        style: CardStyle.numeral(type.body(_time), colour: colour, weight: 560),
      );
    }
    return Text.rich(
      TextSpan(children: [
        TextSpan(
          text: clock.group(1),
          style:
              CardStyle.numeral(type.body(_time), colour: colour, weight: 560),
        ),
        TextSpan(
          text: ' ${clock.group(2)!.toUpperCase()}',
          style: CardStyle.numeral(type.body(_meridiem),
                  colour: colour.withValues(alpha: 0.75), weight: 600)
              .copyWith(letterSpacing: 0.4),
        ),
      ]),
      maxLines: 1,
      softWrap: false,
    );
  }
}

/// A section: its accent's glowing dot, its engraved name, a hairline running
/// out to the edge, and what it holds underneath.
class _Section extends StatelessWidget {
  const _Section({
    super.key,
    required this.label,
    required this.accent,
    required this.child,
  });

  final String label;
  final Color accent;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final type = WallType.of(context);
    final size = type.chrome(TodayBoard._sectionLabel);
    final dot = size * 0.46;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Container(
              width: dot,
              height: dot,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: accent,
                boxShadow: [
                  BoxShadow(color: accent.withValues(alpha: 0.7), blurRadius: 7)
                ],
              ),
            ),
            SizedBox(width: size * 0.7),
            Text(
              label.toUpperCase(),
              maxLines: 1,
              softWrap: false,
              style:
                  CardStyle.label(accent.withValues(alpha: 0.92), size: size),
            ),
            SizedBox(width: size),
            Expanded(child: Container(height: 1, color: CardStyle.rule)),
          ],
        ),
        SizedBox(height: size * 0.8),
        child,
      ],
    );
  }
}
