import 'dart:ui';

import 'package:flutter/services.dart';

/// Material's compact/medium breakpoint: below this shortest side the device
/// is a phone.
const double kPhoneShortestSide = 600;

/// The orientations the app allows on a screen of [logicalSize] (issue #8).
///
/// The voice screen is a column sized for a portrait phone: header, orb, PTT
/// and nav take ~437dp before the thread gets a pixel, and a landscape phone
/// is ~360dp tall, so rotating one overflowed. Phones are held to portrait
/// until the adaptive shell (#14) gives landscape a layout of its own. A
/// tablet's short side already clears that column, so it stays free. Empty
/// means "no preference" to [SystemChrome.setPreferredOrientations].
List<DeviceOrientation> allowedOrientations(Size logicalSize) =>
    logicalSize.shortestSide < kPhoneShortestSide
        ? const [DeviceOrientation.portraitUp]
        : const [];

/// The first view's size in logical pixels, or null when there is no view
/// yet. Shared with the device role's size default (`device_role.dart`), so
/// both draw the phone/tablet line from the same measurement.
Size? firstViewLogicalSize() {
  final views = PlatformDispatcher.instance.views;
  if (views.isEmpty) return null;
  final view = views.first;
  return view.physicalSize / view.devicePixelRatio;
}

/// The display the first view is on, in logical pixels, or null.
Size? firstDisplayLogicalSize() {
  final views = PlatformDispatcher.instance.views;
  if (views.isEmpty) return null;
  final display = views.first.display;
  return display.size / display.devicePixelRatio;
}

/// The first view's size once the platform has actually reported one.
///
/// On Android the view has no metrics yet when `main()` runs: its size reads
/// 0x0, which [allowedOrientations] and the device role's default both take
/// for a phone. The Lenovo came up portrait-locked and `personal` because of
/// it. So: a real view reading if there is one, else poll for [timeout], else
/// the display's size (the whole screen, which draws the same phone/tablet
/// line), else null.
Future<Size?> settledLogicalSize({
  Size? Function() read = firstViewLogicalSize,
  Size? Function() display = firstDisplayLogicalSize,
  Duration poll = const Duration(milliseconds: 16),
  Duration timeout = const Duration(seconds: 1),
}) async {
  bool real(Size? s) => s != null && !s.isEmpty;

  final deadline = DateTime.now().add(timeout);
  var size = read();
  while (!real(size) && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(poll);
    size = read();
  }
  if (real(size)) return size;
  final fallback = display();
  return real(fallback) ? fallback : null;
}

/// Applies [allowedOrientations] for [logicalSize] (see [settledLogicalSize]).
/// Desktop platforms ignore the request. No size, no lock.
Future<void> applyOrientationLock(Size? logicalSize) {
  if (logicalSize == null) return Future.value();
  return SystemChrome.setPreferredOrientations(allowedOrientations(logicalSize));
}
