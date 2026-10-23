import 'device_role.dart';

/// Night dim (spec 2026-10-23, wall tablet, phase 1): the same quiet hours as
/// the server's rain heads-ups, 22:00 until 07:00 local.
const int kDimFromHour = 22;
const int kDimUntilHour = 7;

/// How long the orb must have been at rest (no turn, no touch, nothing
/// ringing) before a wall dims.
const Duration kDimAfterRest = Duration(seconds: 60);

/// The window brightness while dimmed: near the panel's floor, not off — the
/// orb should still be findable in a dark kitchen.
const double kDimBrightness = 0.02;

/// The black laid over the UI while dimmed, so it fades to about a third.
const double kDimOverlayAlpha = 0.65;

/// Whether [localNow] falls in the night window. Wall-clock hours, so the
/// window follows a DST change the way a person does.
bool isQuietHours(DateTime localNow) =>
    localNow.hour >= kDimFromHour || localNow.hour < kDimUntilHour;

/// The whole dim policy, pure: a wall with dim-at-night on, in quiet hours,
/// at rest for at least [kDimAfterRest]. A personal device never dims.
bool shouldDim({
  required DateTime localNow,
  required Duration atRest,
  required DeviceSettings settings,
}) =>
    settings.role == DeviceRole.wall &&
    settings.dimAtNight &&
    isQuietHours(localNow) &&
    atRest >= kDimAfterRest;
