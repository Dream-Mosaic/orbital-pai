import 'dart:async';
import 'dart:typed_data';

import 'package:henry_wall/audio/audio_track_player.dart';
import 'package:henry_wall/audio/mic_capture.dart';

/// Headless MicCapture. `implements` (not `extends`) so no AudioRecorder — and
/// therefore no platform channel — is ever constructed.
class FakeMic implements MicCapture {
  FakeMic({this.startDelay = Duration.zero}) {
    _chunks = StreamController<Uint8List>(
      onListen: () => listening = true,
      onCancel: () => cancelled = true,
    );
  }

  final Duration startDelay;
  late final StreamController<Uint8List> _chunks;
  int startCalls = 0;
  int stopCalls = 0;
  bool listening = false;
  bool cancelled = false;
  bool _recording = false;

  @override
  bool get isRecording => _recording;

  @override
  Future<Stream<Uint8List>> start() async {
    startCalls++;
    if (startDelay > Duration.zero) await Future<void>.delayed(startDelay);
    _recording = true;
    return _chunks.stream;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _recording = false;
  }
}

/// Headless AudioTrackPlayer (the real one is a MethodChannel facade).
class FakePlayer implements AudioTrackPlayer {
  FakePlayer({this.failInit = false, this.onInit});

  final bool failInit;

  /// Runs *inside* `init()`'s await. The real one is a platform-channel call
  /// taking tens of ms, so this is the honest way to land an event in that
  /// window — deterministically, instead of racing a sleep against it.
  final Future<void> Function()? onInit;

  int initCalls = 0;
  int disposeCalls = 0;
  final List<Uint8List> writes = <Uint8List>[];

  @override
  Future<void> init(int sampleRate) async {
    initCalls++;
    if (onInit != null) await onInit!();
    if (failInit) throw StateError('no audio device');
  }

  @override
  Future<void> write(Uint8List pcm) async => writes.add(pcm);

  @override
  Future<int> stopAndFlush() async => 0;

  @override
  Future<int> playedMs() async => 0;

  @override
  Future<void> setVolume(double v) async {}

  @override
  Future<void> dispose() async => disposeCalls++;
}

/// Drain a handful of event-loop turns. `Future.delayed(Duration.zero)` (not
/// `pumpEventQueue`) because these paths hop through real zero-duration timers
/// as well as microtasks.
Future<void> settle([int turns = 8]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
