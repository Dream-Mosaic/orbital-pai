import 'package:flutter/services.dart';

/// The timer alarm: a sound plus haptics, started when a timer goes off and
/// stopped on dismiss / when the server says it is no longer ringing / after a
/// cap (see `TimersModel`). A seam so the ring logic is testable headless.
abstract interface class AlarmSound {
  Future<void> start();
  Future<void> stop();
}

/// Android: `MethodChannel('henry/alarm')` → `AlarmPlayer.kt`, which plays the
/// device's own alarm tone (`RingtoneManager` TYPE_ALARM, USAGE_ALARM) and
/// vibrates. It deliberately takes NO audio focus and never touches the audio
/// mode or route — those belong to `AudioRouteOwner.kt` for as long as the
/// voice session is live, and a second owner is exactly the bug commit 1828d70
/// removed. It also caps itself, so a Dart side that dies mid-ring cannot leave
/// the phone ringing.
///
/// Platforms without the channel (desktop for now) get a system alert sound and
/// a haptic instead of nothing. Every failure is swallowed: an alarm that cannot
/// sound must never take the voice screen down with it.
class PlatformAlarmSound implements AlarmSound {
  static const MethodChannel _ch = MethodChannel('henry/alarm');

  @override
  Future<void> start() async {
    try {
      await _ch.invokeMethod<void>('start');
    } on MissingPluginException {
      try {
        await SystemSound.play(SystemSoundType.alert);
        await HapticFeedback.heavyImpact();
      } catch (_) {}
    } catch (_) {}
  }

  @override
  Future<void> stop() async {
    try {
      await _ch.invokeMethod<void>('stop');
    } catch (_) {}
  }
}
