import 'package:orbital_pai/device/window_control.dart';

/// Records every window knob turned, in order, as a short string.
class FakeWindow implements WindowControl {
  final List<String> calls = [];

  @override
  Future<void> setKeepScreenOn(bool on) async => calls.add('keepOn($on)');

  @override
  Future<void> setBrightness(double? level) async => calls.add('brightness($level)');

  @override
  Future<void> setImmersive(bool on) async => calls.add('immersive($on)');
}
