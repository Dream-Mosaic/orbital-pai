import 'dart:typed_data';

import 'package:flutter/widgets.dart';

/// Why a capture could not be taken, as `camera_frame`'s `error` says it
/// (spec 2026-10-23, game night §1). The server turns each into something
/// Henry can say, so these three strings are the whole vocabulary.
class CameraFailure implements Exception {
  const CameraFailure(this.code, [this.detail]);

  /// No camera on this device, or none this platform can open.
  static const String noCamera = 'no_camera';

  /// The user said no to the camera permission (this launch or before).
  static const String denied = 'denied';

  /// Anything else: the camera would not open, the shutter never answered.
  static const String failed = 'failed';

  final String code;

  /// For the event log only; never sent.
  final String? detail;

  @override
  String toString() =>
      'CameraFailure($code${detail == null ? '' : ': $detail'})';
}

/// The camera, as "Henry, look at this" needs it: open one lens, show what it
/// sees, take ONE picture, close. An interface so the controller and the UI
/// are tested against a fake and never touch the plugin.
///
/// The camera never takes audio. The conversation's microphone keeps
/// streaming while it is open, and [AudioRouteOwner] stays the only thing
/// that touches the audio route.
abstract class CameraService {
  /// Open the camera facing [facing] (`"front"` or `"back"`), asking for the
  /// permission the first time. Throws [CameraFailure].
  Future<void> open({required String facing});

  /// The live viewfinder of the open camera, filling (cropped, never
  /// letterboxed) whatever box it is given — or an empty box while nothing is
  /// open. Safe to keep in the tree across [close].
  Widget preview();

  /// One picture from the open camera: an upright JPEG no larger than 800 px
  /// on its long edge, quality about 80. Throws [CameraFailure].
  Future<Uint8List> capture();

  /// Let go of the camera. Idempotent, never throws, and a no-op when nothing
  /// is open.
  Future<void> close();
}
