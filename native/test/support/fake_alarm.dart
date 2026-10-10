import 'package:orbital_pai/audio/alarm_sound.dart';

/// Counts start/stop calls and tracks whether it is currently sounding.
class FakeAlarm implements AlarmSound {
  int starts = 0;
  int stops = 0;
  bool sounding = false;

  @override
  Future<void> start() async {
    starts++;
    sounding = true;
  }

  @override
  Future<void> stop() async {
    stops++;
    sounding = false;
  }
}

/// A hand-cranked monotonic clock.
class FakeClock {
  Duration now = const Duration(seconds: 100);
  Duration call() => now;
  void advance(Duration d) => now += d;
}
