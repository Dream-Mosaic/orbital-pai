import 'package:flutter/widgets.dart';

import 'device_role.dart';

/// How long a wall must have been at rest (no turn, no touch, nothing
/// ringing) before the thread gives way to the Today board (spec 2026-10-23,
/// wall tablet, phase 3).
const Duration kTodayAfterRest = Duration(minutes: 2);

/// The board policy, pure: a wall that has been at rest for at least
/// [kTodayAfterRest]. Unlike the night dim it keeps no hours and has no
/// switch of its own — being a wall is the opt-in. A personal device never
/// shows it.
bool shouldShowToday(
        {required DeviceSettings settings, required Duration atRest}) =>
    settings.role == DeviceRole.wall && atRest >= kTodayAfterRest;

/// What `WallModeHost`'s activity tracker tells the screen it wraps — the
/// one tracker that also drives the night dim, so a touch, a turn or a ringing
/// timer means the same thing to both.
///
/// Written only by `WallModeHost`; read through [WallActivityScope].
class WallActivity extends ChangeNotifier {
  WallActivity({bool wall = false, bool rested = false})
      : _wall = wall,
        _rested = rested;

  bool _wall;
  bool _rested;

  /// Whether this device is a wall at all. False means no board, ever — the
  /// screen need not even mount one.
  bool get wall => _wall;

  /// Whether the wall has been at rest for [kTodayAfterRest]: true once it
  /// has, false again at the next touch, turn or ringing timer. Always false
  /// when [wall] is.
  bool get rested => _wall && _rested;

  /// Notifies only on a change, so the 5 s policy tick costs nothing at rest.
  void set({required bool wall, required bool rested}) {
    if (wall == _wall && rested == _rested) return;
    _wall = wall;
    _rested = rested;
    notifyListeners();
  }
}

/// Provides a [WallActivity] to the voice screen. Absent (a test, a screen
/// built without `WallModeHost`) reads as "not a wall".
class WallActivityScope extends InheritedNotifier<WallActivity> {
  const WallActivityScope(
      {super.key, required WallActivity activity, required super.child})
      : super(notifier: activity);

  /// The nearest scope's activity, or null when there is none. Rebuilds the
  /// caller when it changes.
  static WallActivity? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WallActivityScope>()?.notifier;
}
