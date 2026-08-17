import 'dart:async';
import 'dart:typed_data';

import 'package:henry_wall/audio/audio_track_player.dart';
import 'package:henry_wall/audio/mic_capture.dart';
import 'package:record/record.dart';

/// What one platform call does. The `record` plugin can refuse (a throw) and
/// can simply never answer (a wedged audio subsystem, another app holding the
/// mic) — a fake that only ever succeeds cannot catch a bug whose whole shape
/// is "what does the state machine claim when the hardware misbehaves".
enum FakeCall { ok, throws, hangs }

/// Headless [MicRecorder]: the platform half of MicCapture, and nothing else.
///
/// The fake stops HERE, one layer lower than it used to. [FakeMic] is now the
/// REAL [MicCapture] driving this, so every controller test exercises the real
/// session rules (ownership, supersession, one-start-at-a-time) instead of a
/// fake's re-statement of them — a fake that reimplements the rules cannot
/// fail when the rules break. No AudioRecorder, and therefore no platform
/// channel, is ever constructed.
///
/// It models three things a real recorder does and this fake did not:
/// a successful `stop()` **ends the session's stream**; a failing `stop()`
/// leaves the hardware **streaming**; and any call can throw or simply never
/// return. Six Criticals of one class all lived on exactly those axes.
class FakeRecorder implements MicRecorder {
  FakeRecorder({
    this.startDelay = Duration.zero,
    List<Duration>? startDelays,
    this.stopDelay = Duration.zero,
    this.permitted = true,
    this.stopEndsStream = true,
    List<FakeCall>? startBehaviour,
    List<FakeCall>? stopBehaviour,
    this.permissionBehaviour = FakeCall.ok,
  })  : _startDelays = List.of(startDelays ?? const <Duration>[]),
        _startBehaviour = List.of(startBehaviour ?? const <FakeCall>[]),
        _stopBehaviour = List.of(stopBehaviour ?? const <FakeCall>[]);

  /// How long `startStream` takes when [startDelays] has nothing to say.
  final Duration startDelay;

  /// Per-call `startStream` delays, indexed by call number. The realistic
  /// shape is asymmetric — one start wedges while the next is instant — and a
  /// single shared delay cannot express it.
  final List<Duration> _startDelays;
  final Duration stopDelay;
  final bool permitted;

  /// A successful `AudioRecorder.stop()` closes the stream it handed out. A
  /// FAILING one does not: the hardware keeps streaming, which is the whole
  /// reason a state machine may not record "stopped" until it knows.
  final bool stopEndsStream;

  /// Per-call outcomes, indexed by call number; anything past the end is
  /// [FakeCall.ok]. `hangs` returns a future that never completes — a wedge,
  /// with no timer to leak.
  final List<FakeCall> _startBehaviour;
  final List<FakeCall> _stopBehaviour;
  final FakeCall permissionBehaviour;

  /// ONE controller per start(). A real recorder opens a new session each
  /// time; a single-subscription StreamController cannot be listened to
  /// twice, so a shared one made every SECOND mic session throw "Stream has
  /// already been listened to" inside startMic's try/catch — silently, with
  /// micOn still true. Measured 2026-08-15.
  final List<StreamController<Uint8List>> sessions =
      <StreamController<Uint8List>>[];

  int startCalls = 0;
  int stopCalls = 0;
  int permissionCalls = 0;
  bool listening = false;
  bool cancelled = false;

  /// The most `startStream` calls that were ever in flight at once. Two
  /// concurrent starts on one AudioRecorder is undefined behaviour on the
  /// plugin side; this is how a test can prove we never issue them.
  int maxConcurrentStarts = 0;
  int _startsInFlight = 0;

  /// True if `startStream` was ever called while a previous session was still
  /// streaming. The SEQUENTIAL form of the same undefined behaviour
  /// [maxConcurrentStarts] catches concurrently — and the one a failing
  /// `stop()` produces.
  bool startedOnLiveRecorder = false;

  /// The session the hardware is currently streaming, or null.
  StreamController<Uint8List>? _live;

  /// Whether the fake HARDWARE is streaming, independent of anything
  /// MicCapture believes.
  bool get platformStreaming => _live != null;

  FakeCall _behaviour(List<FakeCall> list, int call) =>
      call < list.length ? list[call] : FakeCall.ok;

  @override
  Future<bool> hasPermission() async {
    permissionCalls++;
    switch (permissionBehaviour) {
      case FakeCall.hangs:
        return Completer<bool>().future;
      case FakeCall.throws:
        throw StateError('platform refused to answer about permission');
      case FakeCall.ok:
        return permitted;
    }
  }

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    final behaviour = _behaviour(_startBehaviour, startCalls);
    final delay =
        startCalls < _startDelays.length ? _startDelays[startCalls] : startDelay;
    if (_live != null) startedOnLiveRecorder = true;
    startCalls++;
    if (behaviour == FakeCall.hangs) return Completer<Stream<Uint8List>>().future;
    _startsInFlight++;
    if (_startsInFlight > maxConcurrentStarts) {
      maxConcurrentStarts = _startsInFlight;
    }
    try {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      if (behaviour == FakeCall.throws) {
        throw StateError('platform refused to start');
      }
      final c = StreamController<Uint8List>(
        onListen: () => listening = true,
        onCancel: () => cancelled = true,
      );
      sessions.add(c);
      _live = c;
      return c.stream;
    } finally {
      _startsInFlight--;
    }
  }

  @override
  Future<void> stop() async {
    final behaviour = _behaviour(_stopBehaviour, stopCalls);
    stopCalls++;
    if (behaviour == FakeCall.hangs) return Completer<void>().future;
    if (stopDelay > Duration.zero) await Future<void>.delayed(stopDelay);
    if (behaviour == FakeCall.throws) {
      // The hardware keeps streaming: `_live` is deliberately NOT cleared.
      throw StateError('platform refused to stop');
    }
    final live = _live;
    _live = null;
    if (stopEndsStream && live != null && !live.isClosed) live.close();
  }
}

/// A real [MicCapture] over a [FakeRecorder], with the recorder's counters
/// proxied so the existing tests read the same as before.
class FakeMic extends MicCapture {
  FakeMic({
    Duration startDelay = Duration.zero,
    List<Duration>? startDelays,
    Duration stopDelay = Duration.zero,
    List<FakeCall>? startBehaviour,
    List<FakeCall>? stopBehaviour,
    FakeCall permissionBehaviour = FakeCall.ok,
    Duration? platformTimeout,
    Duration? permissionTimeout,
  }) : this.withRecorder(
          FakeRecorder(
            startDelay: startDelay,
            startDelays: startDelays,
            stopDelay: stopDelay,
            startBehaviour: startBehaviour,
            stopBehaviour: stopBehaviour,
            permissionBehaviour: permissionBehaviour,
          ),
          platformTimeout: platformTimeout,
          permissionTimeout: permissionTimeout,
        );

  FakeMic.withRecorder(this.recorder, {super.platformTimeout, super.permissionTimeout})
      : super(recorder: recorder);

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
