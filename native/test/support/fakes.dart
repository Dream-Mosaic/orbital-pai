import 'dart:async';
import 'dart:typed_data';

import 'package:henry_wall/audio/audio_track_player.dart';
import 'package:henry_wall/audio/mic_capture.dart';
import 'package:record/record.dart';

/// Headless [MicRecorder]: the platform half of MicCapture, and nothing else.
///
/// The fake stops HERE, one layer lower than it used to. [FakeMic] is now the
/// REAL [MicCapture] driving this, so every controller test exercises the real
/// session rules (ownership, supersession, one-start-at-a-time) instead of a
/// fake's re-statement of them — a fake that reimplements the rules cannot
/// fail when the rules break. No AudioRecorder, and therefore no platform
/// channel, is ever constructed.
class FakeRecorder implements MicRecorder {
  FakeRecorder({
    this.startDelay = Duration.zero,
    List<Duration>? startDelays,
    this.stopDelay = Duration.zero,
    this.permitted = true,
  }) : _startDelays = List.of(startDelays ?? const <Duration>[]);

  /// How long `startStream` takes when [startDelays] has nothing to say.
  final Duration startDelay;

  /// Per-call `startStream` delays, indexed by call number. The realistic
  /// shape is asymmetric — one start wedges while the next is instant — and a
  /// single shared delay cannot express it.
  final List<Duration> _startDelays;
  final Duration stopDelay;
  final bool permitted;

  /// ONE controller per start(). A real recorder opens a new session each
  /// time; a single-subscription StreamController cannot be listened to
  /// twice, so a shared one made every SECOND mic session throw "Stream has
  /// already been listened to" inside startMic's try/catch — silently, with
  /// micOn still true. Measured 2026-08-15.
  final List<StreamController<Uint8List>> sessions =
      <StreamController<Uint8List>>[];

  int startCalls = 0;
  int stopCalls = 0;
  bool listening = false;
  bool cancelled = false;

  /// The most `startStream` calls that were ever in flight at once. Two
  /// concurrent starts on one AudioRecorder is undefined behaviour on the
  /// plugin side; this is how a test can prove we never issue them.
  int maxConcurrentStarts = 0;
  int _startsInFlight = 0;

  @override
  Future<bool> hasPermission() async => permitted;

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    final delay =
        startCalls < _startDelays.length ? _startDelays[startCalls] : startDelay;
    startCalls++;
    _startsInFlight++;
    if (_startsInFlight > maxConcurrentStarts) {
      maxConcurrentStarts = _startsInFlight;
    }
    try {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      final c = StreamController<Uint8List>(
        onListen: () => listening = true,
        onCancel: () => cancelled = true,
      );
      sessions.add(c);
      return c.stream;
    } finally {
      _startsInFlight--;
    }
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    if (stopDelay > Duration.zero) await Future<void>.delayed(stopDelay);
  }
}

/// A real [MicCapture] over a [FakeRecorder], with the recorder's counters
/// proxied so the existing tests read the same as before.
class FakeMic extends MicCapture {
  FakeMic({
    Duration startDelay = Duration.zero,
    List<Duration>? startDelays,
    Duration stopDelay = Duration.zero,
  }) : this.withRecorder(FakeRecorder(
          startDelay: startDelay,
          startDelays: startDelays,
          stopDelay: stopDelay,
        ));

  FakeMic.withRecorder(this.recorder) : super(recorder: recorder);

  final FakeRecorder recorder;

  int get startCalls => recorder.startCalls;
  int get stopCalls => recorder.stopCalls;
  int get maxConcurrentStarts => recorder.maxConcurrentStarts;
  bool get listening => recorder.listening;
  bool get cancelled => recorder.cancelled;
  List<StreamController<Uint8List>> get sessions => recorder.sessions;

  /// The stream handed out by the most recent start().
  StreamController<Uint8List> get current => recorder.sessions.last;

  /// Feed one PCM frame to the current session.
  void emit(Uint8List chunk) => current.add(chunk);
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
