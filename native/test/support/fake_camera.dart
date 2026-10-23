import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:orbital_pai/camera/camera_service.dart';

/// Headless [CameraService]: no plugin, no platform channel. Each step can
/// succeed, fail with a [CameraFailure] code, throw something else, or never
/// answer — the shapes a real camera has.
class FakeCamera implements CameraService {
  FakeCamera({
    Uint8List? jpeg,
    this.openFailure,
    this.openThrows,
    this.openHangs = false,
    this.captureFailure,
    this.captureThrows,
    this.captureHangs = false,
  }) : jpeg = jpeg ?? Uint8List.fromList(List<int>.generate(64, (i) => i));

  /// What [capture] returns.
  Uint8List jpeg;

  /// A [CameraFailure] code [open] throws, if set.
  String? openFailure;

  /// Anything else [open] throws, if set.
  Object? openThrows;
  bool openHangs;

  String? captureFailure;
  Object? captureThrows;
  bool captureHangs;

  /// Holds [open] until completed, when set — the permission prompt.
  Completer<void>? openGate;

  final List<String> opens = <String>[];
  int captures = 0;
  int closes = 0;
  bool isOpen = false;

  static const Key previewKey = ValueKey('fake-camera-preview');

  @override
  Future<void> open({required String facing}) async {
    opens.add(facing);
    if (openHangs) return Completer<void>().future;
    final gate = openGate;
    if (gate != null) await gate.future;
    final failure = openFailure;
    if (failure != null) throw CameraFailure(failure, 'fake');
    final other = openThrows;
    if (other != null) throw other;
    isOpen = true;
  }

  @override
  Widget preview() => const SizedBox.expand(key: previewKey);

  @override
  Future<Uint8List> capture() async {
    captures++;
    if (captureHangs) return Completer<Uint8List>().future;
    final failure = captureFailure;
    if (failure != null) throw CameraFailure(failure, 'fake');
    final other = captureThrows;
    if (other != null) throw other;
    return jpeg;
  }

  @override
  Future<void> close() async {
    closes++;
    isOpen = false;
  }
}

/// A 1×1 transparent PNG: real image bytes the test engine can decode.
final Uint8List kPixel = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);
