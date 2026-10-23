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

/// Applies [allowedOrientations] to the first view. Call once, after the
/// binding is initialized. Desktop platforms ignore the request.
Future<void> applyOrientationLock() {
  final size = firstViewLogicalSize();
  if (size == null) return Future.value();
  return SystemChrome.setPreferredOrientations(allowedOrientations(size));
}
