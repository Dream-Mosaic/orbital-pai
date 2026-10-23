import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The three window knobs wall mode turns (spec 2026-10-23, phase 1). A seam
/// so `WallModeHost` is testable headless.
abstract interface class WindowControl {
  /// Hold the screen on while this window is in front (`FLAG_KEEP_SCREEN_ON`).
  Future<void> setKeepScreenOn(bool on);

  /// Override this window's brightness, 0.0–1.0; null hands it back to the
  /// system (and to the user's own brightness setting).
  Future<void> setBrightness(double? level);

  /// Hide the system bars (sticky immersive: an edge swipe shows them
  /// briefly) or bring them back.
  Future<void> setImmersive(bool on);
}

/// Android: `MethodChannel('henry/window')` → `WindowChannel.kt` for the
/// screen-on flag and the brightness override (neither needs a permission);
/// the system bars go through [SystemChrome], which Flutter re-applies itself
/// on every resume.
///
/// Leaving immersive restores [SystemUiMode.edgeToEdge], not the bars' old
/// "manual" overlays: the app targets SDK 35, where Android already draws it
/// edge to edge, so that IS the normal mode.
///
/// Platforms without the channel (desktop, tests) get a no-op. Every failure
/// is swallowed: a window knob that cannot turn must never take the voice
/// screen down with it.
class PlatformWindowControl implements WindowControl {
  const PlatformWindowControl();

  static const MethodChannel _ch = MethodChannel('henry/window');

  @override
  Future<void> setKeepScreenOn(bool on) => _invoke('setKeepScreenOn', {'on': on});

  @override
  Future<void> setBrightness(double? level) => _invoke('setBrightness', {'level': level});

  @override
  Future<void> setImmersive(bool on) async {
    try {
      await SystemChrome.setEnabledSystemUIMode(
          on ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
    } catch (e) {
      debugPrint('[window] setImmersive($on) failed: $e');
    }
  }

  Future<void> _invoke(String method, Map<String, Object?> args) async {
    try {
      await _ch.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // No channel on this platform: nothing to turn.
    } catch (e) {
      debugPrint('[window] $method failed: $e');
    }
  }
}
