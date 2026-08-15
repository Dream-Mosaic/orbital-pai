import 'dart:async';
import 'dart:typed_data';

import 'package:henry_wall/audio/audio_track_player.dart';
import 'package:henry_wall/audio/mic_capture.dart';

/// Headless MicCapture. `implements` (not `extends`) so no AudioRecorder — and
/// therefore no platform channel — is ever constructed.
class FakeMic implements MicCapture {
  FakeMic({this.startDelay = Duration.zero});

  final Duration startDelay;

  /// ONE controller per start(). The real MicCapture opens a new recording
  /// session each time; a single-subscription StreamController cannot be
  /// listened to twice, so a shared one made every SECOND mic session throw
  /// "Stream has already been listened to" inside startMic's try/catch —
  /// silently, with micOn still true. Measured 2026-08-15.
  final List<StreamController<Uint8List>> sessions = <StreamController<Uint8List>>[];

  int startCalls = 0;
  int stopCalls = 0;
  bool listening = false;
  bool cancelled = false;
  bool _recording = false;

  /// The stream handed out by the most recent start().
  StreamController<Uint8List> get current => sessions.last;

  /// Feed one PCM frame to the current session.
  void emit(Uint8List chunk) => current.add(chunk);

  @override
  bool get isRecording => _recording;

  @override
  Future<Stream<Uint8List>> start() async {
    startCalls++;
    if (startDelay > Duration.zero) await Future<void>.delayed(startDelay);
    final c = StreamController<Uint8List>(
      onListen: () => listening = true,
      onCancel: () => cancelled = true,
    );
    sessions.add(c);
    _recording = true;
    return c.stream;
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
