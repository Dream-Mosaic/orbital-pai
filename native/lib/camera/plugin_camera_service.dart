import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'camera_service.dart';

/// [CameraService] on the official `camera` plugin (CameraX on Android).
///
/// Inert until asked: constructing one touches no platform channel, so every
/// controller a test builds without a fake still gets one for free.
///
/// `enableAudio: false` is load-bearing, not a preference: the microphone
/// belongs to the conversation (`MicCapture`), which keeps streaming while the
/// camera is open, and the audio route belongs to `AudioRouteOwner`.
class PluginCameraService implements CameraService {
  PluginCameraService({MethodChannel? jpeg})
      : _jpeg = jpeg ?? const MethodChannel('henry/jpeg');

  /// A "no" to the camera permission, remembered for the rest of the PROCESS
  /// rather than this instance: a sign-out builds a new controller and with it
  /// a new service, and "does not ask again this launch" has to survive that.
  static bool _deniedThisLaunch = false;

  /// The JPEG the server is promised (spec §1): ≤ 800 px on its long edge,
  /// quality about 80.
  static const int maxEdge = 800;
  static const int quality = 80;

  /// `JpegChannel.kt`: bakes the EXIF rotation into the pixels, downscales
  /// only past [maxEdge], re-encodes at [quality]. Off Android it is missing,
  /// and the plugin's own JPEG goes as it is.
  final MethodChannel _jpeg;

  /// The camera the viewfinder shows; null while nothing is open.
  final ValueNotifier<CameraController?> _live =
      ValueNotifier<CameraController?>(null);

  /// A camera still initializing (the permission prompt can sit here). A
  /// [close] in that window clears it, and [open] then disposes what it built
  /// rather than adopting it.
  CameraController? _opening;

  List<CameraDescription>? _cameras;

  /// Every teardown, chained. The CameraX implementation's dispose ignores
  /// which camera it is given and unbinds EVERYTHING, so a dispose landing
  /// after the next [open] would kill that camera; [open] waits on this.
  Future<void> _retiring = Future<void>.value();

  @override
  Future<void> open({required String facing}) async {
    if (_deniedThisLaunch) {
      throw const CameraFailure(CameraFailure.denied, 'denied earlier this launch');
    }
    await close();
    final description = _pick(await _list(), facing);
    if (description == null) {
      throw const CameraFailure(CameraFailure.noCamera, 'no cameras');
    }
    final c = CameraController(
      description,
      ResolutionPreset.medium,
      enableAudio: false,
    );
    _opening = c;
    try {
      // Asks for the CAMERA permission on first use (the plugin does it).
      await c.initialize();
    } on CameraException catch (e) {
      if (identical(_opening, c)) _opening = null;
      _retire(c);
      if (_isDenial(e.code)) {
        _deniedThisLaunch = true;
        throw CameraFailure(CameraFailure.denied, e.code);
      }
      throw CameraFailure(CameraFailure.failed, '${e.code}: ${e.description}');
    } catch (e) {
      if (identical(_opening, c)) _opening = null;
      _retire(c);
      throw CameraFailure(CameraFailure.failed, '$e');
    }
    if (!identical(_opening, c)) {
      // Closed while the permission prompt (or the hardware) was answering.
      _retire(c);
      throw const CameraFailure(CameraFailure.failed, 'closed while opening');
    }
    _opening = null;
    _live.value = c;
  }

  @override
  Widget preview() => ValueListenableBuilder<CameraController?>(
        valueListenable: _live,
        builder: (context, c, _) =>
            c == null ? const SizedBox.expand() : _CoverPreview(controller: c),
      );

  @override
  Future<Uint8List> capture() async {
    final c = _live.value;
    if (c == null || !c.value.isInitialized) {
      throw const CameraFailure(CameraFailure.failed, 'no open camera');
    }
    final XFile file;
    final Uint8List raw;
    try {
      file = await c.takePicture();
      raw = await file.readAsBytes();
    } on CameraException catch (e) {
      throw CameraFailure(CameraFailure.failed, '${e.code}: ${e.description}');
    } catch (e) {
      throw CameraFailure(CameraFailure.failed, '$e');
    }
    // The plugin saved it to the cache dir; the picture lives in memory only.
    unawaited(_delete(file.path));
    return _normalize(raw);
  }

  @override
  Future<void> close() {
    _opening = null;
    final c = _live.value;
    if (c != null) {
      _live.value = null;
      // Let the frame that drops the viewfinder land before its texture
      // goes. A timer, not endOfFrame: a backgrounded app produces no
      // frames, and a camera must never stay held waiting for one.
      _retire(c, after: const Duration(milliseconds: 150));
    }
    return _retiring;
  }

  /// Queue [c]'s dispose behind every earlier one.
  void _retire(CameraController c, {Duration after = Duration.zero}) {
    _retiring = _retiring.then((_) async {
      if (after > Duration.zero) await Future<void>.delayed(after);
      await _dispose(c);
    });
  }

  Future<List<CameraDescription>> _list() async {
    final known = _cameras;
    if (known != null) return known;
    try {
      return _cameras = await availableCameras();
    } catch (e) {
      // No implementation on this platform (desktop), or no camera service.
      throw CameraFailure(CameraFailure.noCamera, '$e');
    }
  }

  /// The lens asked for; failing that, any camera at all — a picture from
  /// the other side beats "I can't see".
  static CameraDescription? _pick(List<CameraDescription> cams, String facing) {
    final want =
        facing == 'front' ? CameraLensDirection.front : CameraLensDirection.back;
    for (final c in cams) {
      if (c.lensDirection == want) return c;
    }
    return cams.isEmpty ? null : cams.first;
  }

  static bool _isDenial(String code) =>
      code.contains('AccessDenied') || code.contains('AccessRestricted');

  Future<Uint8List> _normalize(Uint8List raw) async {
    try {
      final out = await _jpeg.invokeMethod<Uint8List>('normalize', {
        'bytes': raw,
        'maxEdge': maxEdge,
        'quality': quality,
      });
      return out ?? raw;
    } catch (_) {
      // Still a JPEG the server can use; just not the tidy one.
      return raw;
    }
  }

  /// Bounded: the plugin's dispose waits on an initialize still in flight
  /// (a permission prompt nobody answered), and [_retiring] must never wedge
  /// every later [open] behind it.
  static Future<void> _dispose(CameraController c) async {
    try {
      await c.dispose().timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  static Future<void> _delete(String path) async {
    try {
      await File(path).delete();
    } catch (_) {}
  }
}

/// The plugin's [CameraPreview], cropped to fill its box. [CameraPreview] is
/// an AspectRatio (landscape: the preview's own ratio; portrait: its inverse,
/// exactly as it decides internally); a [FittedBox] covering the box with it
/// is what lets the circular glass show no bars.
class _CoverPreview extends StatelessWidget {
  const _CoverPreview({required this.controller});

  final CameraController controller;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<CameraValue>(
        valueListenable: controller,
        builder: (context, v, _) {
          final size = v.previewSize;
          if (!v.isInitialized || size == null || size.height == 0) {
            return const SizedBox.expand();
          }
          final o = v.previewPauseOrientation ??
              v.lockedCaptureOrientation ??
              v.deviceOrientation;
          final landscape = o == DeviceOrientation.landscapeLeft ||
              o == DeviceOrientation.landscapeRight;
          final ratio = size.width / size.height;
          final aspect = landscape ? ratio : 1 / ratio;
          return FittedBox(
            fit: BoxFit.cover,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: 100 * aspect,
              height: 100,
              child: CameraPreview(controller),
            ),
          );
        },
      );
}
