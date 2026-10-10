import 'dart:async';

import 'package:flutter/foundation.dart';

import '../audio/alarm_sound.dart';

/// A monotonic "now" — elapsed time on a clock that never jumps. Timers are
/// anchored to it, never to wall time.
typedef MonoClock = Duration Function();

final Stopwatch _monotonic = Stopwatch()..start();

/// The process-wide monotonic clock (the default [MonoClock]).
Duration monotonicNow() => _monotonic.elapsed;

/// One timer as this device sees it. The server sends `remaining_ms` computed
/// at push time; the entry turns that into a [deadline] on the LOCAL monotonic
/// clock the moment it arrives, so the countdown is immune to any skew between
/// the server's clock and this device's (only transit latency remains).
@immutable
class TimerEntry {
  const TimerEntry({
    required this.id,
    required this.label,
    required this.ringing,
    required this.duration,
    required this.deadline,
  });

  final int id;

  /// As the user said it ("Pasta"), or null for an unnamed timer.
  final String? label;

  /// Went off and nobody has stopped it yet.
  final bool ringing;
  final Duration duration;

  /// When it ends, on the [MonoClock] it was anchored to.
  final Duration deadline;

  /// Parse one wire entry, or null when it is malformed (skipped, never guessed).
  static TimerEntry? fromWire(Map<String, dynamic> m, Duration now) {
    final id = m['id'];
    final state = m['state'];
    final duration = m['duration_ms'];
    final remaining = m['remaining_ms'];
    if (id is! int || state is! String || duration is! num || remaining is! num) return null;
    if (state != 'running' && state != 'ringing') return null;
    final label = m['label'];
    return TimerEntry(
      id: id,
      label: label is String && label.trim().isNotEmpty ? label : null,
      ringing: state == 'ringing',
      duration: Duration(milliseconds: duration.round()),
      deadline: now + Duration(milliseconds: remaining.round()),
    );
  }

  Duration remainingAt(Duration now) {
    if (ringing) return Duration.zero;
    final left = deadline - now;
    return left.isNegative ? Duration.zero : left;
  }

  /// 0 at the start, 1 when done (or ringing).
  double progressAt(Duration now) {
    if (ringing || duration <= Duration.zero) return 1.0;
    final left = remainingAt(now).inMicroseconds / duration.inMicroseconds;
    return (1.0 - left).clamp(0.0, 1.0);
  }
}

/// `m:ss`, or `h:mm:ss` from an hour up — rounded UP to the next whole second,
/// so a running timer never reads 0:00 and a fresh 10-minute one reads 10:00.
String formatCountdown(Duration d) {
  final ms = d.inMilliseconds;
  final total = ms <= 0 ? 0 : (ms + 999) ~/ 1000;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

/// The device's view of the user's timers, plus the alarm that goes with them.
///
/// The server is the truth: every `timers` push REPLACES the list. What lives
/// here is only what is per-device — the clock anchor, and the alarm.
///
/// **The alarm rings once per timer id.** Every device re-receives the whole
/// list on every change (a second timer being set, another device dismissing),
/// so "is something ringing" would re-ring on each push; "did a timer I have not
/// rung for start ringing" does not. It stops when the user silences it here,
/// when no un-silenced timer is ringing any more (dismissed on another device,
/// auto-settled server-side), or after [alarmCap] — an alarm that rings forever
/// in an empty kitchen is worse than one that gives up. The chip keeps pulsing
/// after the sound stops; the server settles it a few minutes later.
class TimersModel {
  TimersModel({
    MonoClock? clock,
    AlarmSound? alarm,
    this.alarmCap = const Duration(seconds: 30),
  })  : now = clock ?? monotonicNow,
        _alarm = alarm ?? PlatformAlarmSound();

  /// The clock entries are anchored to; the strip reads the same one.
  final MonoClock now;
  final AlarmSound _alarm;
  final Duration alarmCap;

  List<TimerEntry> _timers = const <TimerEntry>[];
  List<TimerEntry> get timers => _timers;

  final Set<int> _rang = <int>{};
  final Set<int> _silenced = <int>{};
  Timer? _cap;
  bool _alarmOn = false;
  bool _disposed = false;

  bool get alarmOn => _alarmOn;

  /// Apply a server `timers` push (`{timers: [...]}`).
  void apply(Map<String, dynamic> payload) {
    if (_disposed) return;
    final at = now();
    final raw = payload['timers'];
    _timers = List<TimerEntry>.unmodifiable([
      if (raw is List)
        for (final m in raw)
          if (m is Map) TimerEntry.fromWire(m.cast<String, dynamic>(), at),
    ].whereType<TimerEntry>());
    _syncAlarm();
  }

  /// The user stopped timer [id] on this device: hush now, without waiting for
  /// the server's echo (which then cannot re-ring it — it already rang).
  void silence(int id) {
    _silenced.add(id);
    if (_alarmOn && _unsilencedRinging().isEmpty) _hush();
  }

  Set<int> _unsilencedRinging() =>
      {for (final t in _timers) if (t.ringing && !_silenced.contains(t.id)) t.id};

  void _syncAlarm() {
    final present = {for (final t in _timers) t.id};
    final ringing = {for (final t in _timers) if (t.ringing) t.id};
    // Ids never come back once gone, so forgetting them keeps the sets bounded.
    _rang.retainAll(present);
    _silenced.retainAll(ringing);
    final fresh = ringing.difference(_rang);
    if (fresh.isNotEmpty) {
      _rang.addAll(fresh);
      _ring();
    } else if (_alarmOn && _unsilencedRinging().isEmpty) {
      _hush();
    }
  }

  void _ring() {
    _alarmOn = true;
    _cap?.cancel();
    _cap = Timer(alarmCap, _hush);
    unawaited(_alarm.start());
  }

  void _hush() {
    _cap?.cancel();
    _cap = null;
    if (!_alarmOn) return;
    _alarmOn = false;
    unawaited(_alarm.stop());
  }

  void dispose() {
    _hush();
    _disposed = true;
  }
}
