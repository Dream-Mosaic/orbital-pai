import 'package:flutter/services.dart';

/// Thin Dart facade over the Kotlin `AudioTrack`-backed player registered on
/// `MethodChannel('henry/audio_track')`. Downstream TTS is 24 kHz PCM16LE
/// mono — never resample, never assume the device-native rate.
class AudioTrackPlayer {
  static const MethodChannel _ch = MethodChannel('henry/audio_track');

  Future<void> init(int sampleRate) =>
      _ch.invokeMethod('init', {'sampleRate': sampleRate});

  Future<void> write(Uint8List pcm) => _ch.invokeMethod('write', pcm);

  Future<int> stopAndFlush() async =>
      (await _ch.invokeMethod<int>('stopAndFlush')) ?? 0;

  Future<int> playedMs() async =>
      (await _ch.invokeMethod<int>('playedMs')) ?? 0;

  Future<void> setVolume(double v) =>
      _ch.invokeMethod('setVolume', {'volume': v});

  Future<void> dispose() => _ch.invokeMethod('dispose');
}
