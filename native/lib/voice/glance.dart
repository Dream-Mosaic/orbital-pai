import 'package:flutter/foundation.dart';

/// The server's `glance` push: what the idle orb shows besides the clock.
///
/// Every string arrives display-ready (the server formats; the client lays
/// out). Each half is optional — a user with no calendar connected still gets
/// the weather, and a failed weather fetch still leaves the next event.
@immutable
class Glance {
  const Glance({this.weather, this.next});

  final GlanceWeather? weather;
  final GlanceEvent? next;

  static const empty = Glance();

  bool get isEmpty => weather == null && next == null;

  /// Tolerant parse: a malformed half is dropped, never thrown.
  factory Glance.fromJson(Map<String, dynamic> json) {
    GlanceWeather? weather;
    final w = json['weather'];
    if (w is Map && w['temp'] is String) {
      weather = GlanceWeather(
        temp: w['temp'] as String,
        condition: (w['condition'] as String?) ?? '',
        icon: (w['icon'] as String?) ?? '',
      );
    }
    GlanceEvent? next;
    final e = json['next_event'];
    if (e is Map && e['title'] is String && e['time'] is String) {
      next = GlanceEvent(
        title: e['title'] as String,
        time: e['time'] as String,
        day: (e['day'] as String?) ?? '',
        at: e['at'] is String ? DateTime.tryParse(e['at'] as String) : null,
      );
    }
    return Glance(weather: weather, next: next);
  }

  @override
  bool operator ==(Object other) =>
      other is Glance && other.weather == weather && other.next == next;

  @override
  int get hashCode => Object.hash(weather, next);
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
