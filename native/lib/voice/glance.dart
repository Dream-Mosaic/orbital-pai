import 'package:flutter/foundation.dart';

/// The server's `glance` push: what the idle orb shows besides the clock, and
/// what a wall's Today board shows when it has been at rest a while.
///
/// Every string arrives display-ready (the server formats; the client lays
/// out). Each part is optional — a user with no calendar connected still gets
/// the weather, and a failed weather fetch still leaves the next event. The
/// board's three ([agenda], [forecast], [reminders]) arrived later: an older
/// server sends only [weather] and [next], and those parse exactly as before.
@immutable
class Glance {
  const Glance({
    this.weather,
    this.next,
    this.agenda = const [],
    this.forecast,
    this.reminders = const [],
  });

  final GlanceWeather? weather;
  final GlanceEvent? next;

  /// Now through the end of tomorrow, soonest first, each day's all-day
  /// events leading it (the server's order and cap of 6). An event in
  /// progress stays until it ends.
  final List<GlanceAgendaItem> agenda;

  /// The next hours and the days after today; null when there is none.
  final GlanceForecast? forecast;

  /// Today's unfired reminders, own and household, soonest first.
  final List<GlanceReminder> reminders;

  static const empty = Glance();

  bool get isEmpty => weather == null && next == null && !hasBoard;

  /// Whether the Today board has anything to show besides "nothing else".
  bool get hasBoard =>
      agenda.isNotEmpty || forecast != null || reminders.isNotEmpty;

  /// Tolerant parse: a malformed part (or a malformed row of a list) is
  /// dropped, never thrown.
  factory Glance.fromJson(Map<String, dynamic> json) {
    GlanceWeather? weather;
    final w = json['weather'];
    if (w is Map && w['temp'] is String) {
      weather = GlanceWeather(
        temp: w['temp'] as String,
        condition: _str(w['condition']),
        icon: _str(w['icon']),
      );
    }
    GlanceEvent? next;
    final e = json['next_event'];
    if (e is Map && e['title'] is String && e['time'] is String) {
      next = GlanceEvent(
        title: e['title'] as String,
        time: e['time'] as String,
        day: _str(e['day']),
        at: _instant(e['at']),
      );
    }
    return Glance(
      weather: weather,
      next: next,
      agenda: _rows(json['agenda'], GlanceAgendaItem._parse),
      forecast: GlanceForecast._parse(json['forecast']),
      reminders: _rows(json['reminders'], GlanceReminder._parse),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Glance &&
      other.weather == weather &&
      other.next == next &&
      listEquals(other.agenda, agenda) &&
      other.forecast == forecast &&
      listEquals(other.reminders, reminders);

  @override
  int get hashCode => Object.hash(weather, next, Object.hashAll(agenda),
      forecast, Object.hashAll(reminders));
}

/// A string field, or '' when it is missing or not a string.
String _str(Object? v) => v is String ? v : '';

/// A string field that is worth showing, or null.
String? _opt(Object? v) => v is String && v.isNotEmpty ? v : null;

DateTime? _instant(Object? v) => v is String ? DateTime.tryParse(v) : null;

/// The rows of a list field that parse; anything else (not a list, a row that
/// is not an object, a row missing what it needs) is skipped.
List<T> _rows<T>(Object? v, T? Function(Map<Object?, Object?>) parse) {
  if (v is! List) return const [];
  return List.unmodifiable([
    for (final row in v)
      if (row is Map)
        if (parse(row) case final T parsed) parsed,
  ]);
}

@immutable
class GlanceWeather {
  const GlanceWeather(
      {required this.temp, required this.condition, required this.icon});

  /// e.g. "64°"
  final String temp;

  /// e.g. "Partly cloudy"
  final String condition;

  /// A coarse glyph key (clear-day, partly-night, rain, …); '' = none.
  final String icon;

  @override
  bool operator ==(Object other) =>
      other is GlanceWeather &&
      other.temp == temp &&
      other.condition == condition &&
      other.icon == icon;

  @override
  int get hashCode => Object.hash(temp, condition, icon);
}

@immutable
class GlanceEvent {
  const GlanceEvent(
      {required this.title, required this.time, required this.day, this.at});

  /// When it starts (UTC), if the server said — the face drops it once this has passed rather
  /// than calling a meeting that's already under way "next".
  final DateTime? at;

  bool startedBy(DateTime now) => at != null && !now.toUtc().isBefore(at!);

  final String title;

  /// e.g. "7:30 PM" or "All day"
  final String time;

  /// "Today" / "Tomorrow" / a weekday; '' when the server omits it.
  final String day;

  @override
  bool operator ==(Object other) =>
      other is GlanceEvent &&
      other.title == title &&
      other.time == time &&
      other.day == day &&
      other.at == at;

  @override
  int get hashCode => Object.hash(title, time, day, at);
}

/// One line of the board's "Coming up".
@immutable
class GlanceAgendaItem {
  const GlanceAgendaItem({
    required this.title,
    required this.time,
    this.day = '',
    this.allDay = false,
    this.at,
  });

  final String title;

  /// e.g. "9:00 AM", or "All day".
  final String time;

  /// "Today" / "Tomorrow" / a weekday; '' when the server omits it.
  final String day;

  final bool allDay;

  /// When it starts (UTC); null for an all-day event.
  final DateTime? at;

  static GlanceAgendaItem? _parse(Map<Object?, Object?> m) {
    final title = m['title'];
    final time = m['time'];
    if (title is! String || time is! String) return null;
    return GlanceAgendaItem(
      title: title,
      time: time,
      day: _str(m['day']),
      allDay: m['all_day'] == true,
      at: _instant(m['at']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GlanceAgendaItem &&
      other.title == title &&
      other.time == time &&
      other.day == day &&
      other.allDay == allDay &&
      other.at == at;

  @override
  int get hashCode => Object.hash(title, time, day, allDay, at);
}

/// The weather card's own rows: the next hours, then the days after today
/// (today's high and low ride the orb's headline, not this).
@immutable
class GlanceForecast {
  const GlanceForecast({this.hourly = const [], this.daily = const []});

  final List<GlanceHour> hourly;
  final List<GlanceDay> daily;

  /// Null when [v] is not an object or neither list has a row that parses.
  static GlanceForecast? _parse(Object? v) {
    if (v is! Map) return null;
    final hourly = _rows(v['hourly'], GlanceHour._parse);
    final daily = _rows(v['daily'], GlanceDay._parse);
    if (hourly.isEmpty && daily.isEmpty) return null;
    return GlanceForecast(hourly: hourly, daily: daily);
  }

  @override
  bool operator ==(Object other) =>
      other is GlanceForecast &&
      listEquals(other.hourly, hourly) &&
      listEquals(other.daily, daily);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(hourly), Object.hashAll(daily));
}

/// One hour of the forecast strip.
@immutable
class GlanceHour {
  const GlanceHour({
    required this.label,
    required this.temp,
    this.icon = '',
    this.condition = '',
    this.precip,
  });

  /// e.g. "3PM"
  final String label;

  /// e.g. "64°"
  final String temp;

  /// A glyph key (WeatherGlyph); '' = none.
  final String icon;
  final String condition;

  /// e.g. "30%" — present only when the chance is worth showing.
  final String? precip;

  static GlanceHour? _parse(Map<Object?, Object?> m) {
    final label = m['label'];
    final temp = m['temp'];
    if (label is! String || temp is! String) return null;
    return GlanceHour(
      label: label,
      temp: temp,
      icon: _str(m['icon']),
      condition: _str(m['condition']),
      precip: _opt(m['precip']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GlanceHour &&
      other.label == label &&
      other.temp == temp &&
      other.icon == icon &&
      other.condition == condition &&
      other.precip == precip;

  @override
  int get hashCode => Object.hash(label, temp, icon, condition, precip);
}

/// One day of the forecast.
@immutable
class GlanceDay {
  const GlanceDay({
    required this.label,
    required this.hi,
    this.lo = '',
    this.icon = '',
    this.condition = '',
    this.precip,
  });

  /// e.g. "Sun"
  final String label;

  /// e.g. "68°" / "50°"; [lo] is '' when the server left it out.
  final String hi;
  final String lo;

  final String icon;
  final String condition;
  final String? precip;

  static GlanceDay? _parse(Map<Object?, Object?> m) {
    final label = m['label'];
    final hi = m['hi'];
    if (label is! String || hi is! String) return null;
    return GlanceDay(
      label: label,
      hi: hi,
      lo: _str(m['lo']),
      icon: _str(m['icon']),
      condition: _str(m['condition']),
      precip: _opt(m['precip']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GlanceDay &&
      other.label == label &&
      other.hi == hi &&
      other.lo == lo &&
      other.icon == icon &&
      other.condition == condition &&
      other.precip == precip;

  @override
  int get hashCode => Object.hash(label, hi, lo, icon, condition, precip);
}

/// One of today's pending reminders.
@immutable
class GlanceReminder {
  const GlanceReminder(
      {required this.text, this.time = '', this.household = false});

  final String text;

  /// e.g. "8:00 PM"; '' when the server omits it.
  final String time;

  /// The household's (shared by everyone at home) rather than yours alone.
  final bool household;

  static GlanceReminder? _parse(Map<Object?, Object?> m) {
    final text = m['text'];
    if (text is! String || text.trim().isEmpty) return null;
    return GlanceReminder(
      text: text,
      time: _str(m['time']),
      household: m['household'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GlanceReminder &&
      other.text == text &&
      other.time == time &&
      other.household == household;

  @override
  int get hashCode => Object.hash(text, time, household);
}
