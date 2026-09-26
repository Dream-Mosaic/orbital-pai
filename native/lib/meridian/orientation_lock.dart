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

/// Applies [allowedOrientations] to the first view. Call once, after the
/// binding is initialized. Desktop platforms ignore the request.
Future<void> applyOrientationLock() {
  final views = PlatformDispatcher.instance.views;
  if (views.isEmpty) return Future.value();
  final view = views.first;
  return SystemChrome.setPreferredOrientations(
      allowedOrientations(view.physicalSize / view.devicePixelRatio));
}
