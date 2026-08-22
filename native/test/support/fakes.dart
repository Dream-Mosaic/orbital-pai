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
    List<Duration>? stopDelays,
    this.permitted = true,
    this.stopEndsStream = true,
    List<FakeCall>? startBehaviour,
    List<FakeCall>? stopBehaviour,
    this.permissionBehaviour = FakeCall.ok,
    List<FakeCall>? permissionBehaviours,
    this.cancelBehaviour = FakeCall.ok,
  })  : _startDelays = List.of(startDelays ?? const <Duration>[]),
        _stopDelays = List.of(stopDelays ?? const <Duration>[]),
        _startBehaviour = List.of(startBehaviour ?? const <FakeCall>[]),
        _stopBehaviour = List.of(stopBehaviour ?? const <FakeCall>[]),
        _permissionBehaviours =
            List.of(permissionBehaviours ?? const <FakeCall>[]);

  /// How long `startStream` takes when [startDelays] has nothing to say.
  final Duration startDelay;

  /// Per-call `startStream` delays, indexed by call number. The realistic
  /// shape is asymmetric — one start wedges while the next is instant — and a
  /// single shared delay cannot express it.
  final List<Duration> _startDelays;

  /// How long `stop()` takes when [stopDelays] has nothing to say.
  final Duration stopDelay;

  /// Per-call `stop()` delays — the MIRROR of [startDelays], and missing until
  /// the eighth Critical needed it. A slow teardown followed by a quick one is
  /// the production shape of a wedged audio subsystem, and a single shared
  /// delay cannot express it any better on this side than on that one.
  final List<Duration> _stopDelays;
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

  /// What `hasPermission` does when [permissionBehaviours] has nothing to say.
  final FakeCall permissionBehaviour;

  /// Per-call permission outcomes, so a test can let the FIRST session open
  /// and wedge a LATER one inside the system dialog. `hasPermission` is the
  /// one platform call with a human-scale bound, so "one succeeds, the next
  /// hangs" is the only shape in which the cost of serialising it is
  /// observable at all.
  final List<FakeCall> _permissionBehaviours;

  /// What the SESSION STREAM's own `cancel()` does. That stream belongs to the
  /// plugin, not to MicCapture, so it is the one microphone-shaped call a
  /// caller has to bound itself — and a cancel that throws, or simply never
  /// returns, is what parked a teardown forever with the recorder still open.
  /// The third failure axis, beside "throws" and "ends the stream".
  final FakeCall cancelBehaviour;

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

  /// The most `stop()` calls that were ever in flight at once — the MIRROR of
  /// [maxConcurrentStarts], and unmeasurable here until the eighth Critical.
  /// Two concurrent `stop()`s on one AudioRecorder is the same undefined
  /// behaviour from the other side, and for eight rounds only one side of it
  /// could be seen.
  int maxConcurrentStops = 0;
  int _stopsInFlight = 0;

  /// True if a `stop()` and a `startStream()` were ever in flight at the same
  /// time, in EITHER order. The cross term neither counter above can see, and
  /// the one the eighth Critical actually produced: a teardown landing on top
  /// of the session a newer start had just opened.
  bool stopOverlappedStart = false;

  /// A call that HANGS is deliberately not counted as in flight by any of the
  /// three above. It never ends, so it would poison every later measurement;
  /// what a hang is for is proving the `.timeout()` bounds, and those tests
  /// assert on settling rather than on overlap.
  void _enteringStart() {
    _startsInFlight++;
    if (_startsInFlight > maxConcurrentStarts) {
      maxConcurrentStarts = _startsInFlight;
    }
    if (_stopsInFlight > 0) stopOverlappedStart = true;
  }

  void _enteringStop() {
    _stopsInFlight++;
    if (_stopsInFlight > maxConcurrentStops) {
      maxConcurrentStops = _stopsInFlight;
    }
    if (_startsInFlight > 0) stopOverlappedStart = true;
  }

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

  /// Per-call override if there is one, otherwise the scalar default — the
  /// same shape [startDelay]/[startDelays] already had.
  static T _forCall<T>(List<T> perCall, int call, T fallback) =>
      call < perCall.length ? perCall[call] : fallback;

  FakeCall _behaviour(List<FakeCall> list, int call) =>
      _forCall(list, call, FakeCall.ok);

  @override
  Future<bool> hasPermission() async {
    final behaviour =
        _forCall(_permissionBehaviours, permissionCalls, permissionBehaviour);
    permissionCalls++;
    switch (behaviour) {
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
    final delay = _forCall(_startDelays, startCalls, startDelay);
    if (_live != null) startedOnLiveRecorder = true;
    startCalls++;
    if (behaviour == FakeCall.hangs) {
      return Completer<Stream<Uint8List>>().future;
    }
    _enteringStart();
    try {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      if (behaviour == FakeCall.throws) {
        throw StateError('platform refused to start');
      }
      final c = StreamController<Uint8List>(
        onListen: () => listening = true,
        onCancel: () {
          cancelled = true;
          switch (cancelBehaviour) {
            case FakeCall.hangs:
              return Completer<void>().future;
            case FakeCall.throws:
              throw StateError('the platform refused to cancel');
            case FakeCall.ok:
              return null;
          }
        },
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
    final delay = _forCall(_stopDelays, stopCalls, stopDelay);
    stopCalls++;
    if (behaviour == FakeCall.hangs) return Completer<void>().future;
    _enteringStop();
    try {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      if (behaviour == FakeCall.throws) {
        // The hardware keeps streaming: `_live` is deliberately NOT cleared.
        throw StateError('platform refused to stop');
      }
      final live = _live;
      _live = null;
      if (stopEndsStream && live != null && !live.isClosed) live.close();
    } finally {
      _stopsInFlight--;
    }
  }
}

/// A real [MicCapture] over a [FakeRecorder], with the recorder's counters
/// proxied so the existing tests read the same as before.
class FakeMic extends MicCapture {
  FakeMic({
    Duration startDelay = Duration.zero,
    List<Duration>? startDelays,
    Duration stopDelay = Duration.zero,
    List<Duration>? stopDelays,
    List<FakeCall>? startBehaviour,
    List<FakeCall>? stopBehaviour,
    FakeCall permissionBehaviour = FakeCall.ok,
    List<FakeCall>? permissionBehaviours,
    FakeCall cancelBehaviour = FakeCall.ok,
    Duration? platformTimeout,
    Duration? permissionTimeout,
  }) : this.withRecorder(
          FakeRecorder(
            startDelay: startDelay,
            startDelays: startDelays,
            stopDelay: stopDelay,
            stopDelays: stopDelays,
            startBehaviour: startBehaviour,
            stopBehaviour: stopBehaviour,
            permissionBehaviour: permissionBehaviour,
            permissionBehaviours: permissionBehaviours,
            cancelBehaviour: cancelBehaviour,
          ),
          platformTimeout: platformTimeout,
          permissionTimeout: permissionTimeout,
        );

  FakeMic.withRecorder(this.recorder,
      {super.platformTimeout, super.permissionTimeout})
      : super(recorder: recorder);

  final FakeRecorder recorder;

  int get startCalls => recorder.startCalls;
  int get stopCalls => recorder.stopCalls;
  int get maxConcurrentStarts => recorder.maxConcurrentStarts;
  int get maxConcurrentStops => recorder.maxConcurrentStops;
  bool get stopOverlappedStart => recorder.stopOverlappedStart;
  bool get platformStreaming => recorder.platformStreaming;
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
