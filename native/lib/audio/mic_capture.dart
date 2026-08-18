import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

/// The slice of `record`'s [AudioRecorder] that [MicCapture] drives.
///
/// It is a seam so that tests exercise MicCapture's REAL session rules against
/// a fake RECORDER, rather than a fake MicCapture reimplementing those rules.
/// The rules below are the load-bearing part; a fake that reimplements them
/// cannot fail when they break.
abstract interface class MicRecorder {
  Future<bool> hasPermission();
  Future<Stream<Uint8List>> startStream(RecordConfig config);
  Future<void> stop();
}

class _PluginRecorder implements MicRecorder {
  final AudioRecorder _recorder = AudioRecorder();

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) =>
      _recorder.startStream(config);

  @override
  Future<void> stop() async {
    await _recorder.stop();
  }
}

/// INVARIANT B, made structural: every platform call is bounded, here, at the
/// only place the microphone is reachable from.
///
/// [MicCapture] wraps whatever recorder it is given in one of these and keeps
/// no reference to the raw one, so no code inside MicCapture — present or
/// future — can issue an unbounded platform call, and no caller further out
/// has to remember to add a `.timeout()`. Two callers forgot, twice, and each
/// time the microphone was lost with no error to debug from: a wedged
/// platform-channel call is worse than a throwing one, because there is
/// nothing to catch.
class _BoundedRecorder implements MicRecorder {
  _BoundedRecorder(
    this._inner, {
    required this.platformTimeout,
    required this.permissionTimeout,
  });

  final MicRecorder _inner;
  final Duration platformTimeout;
  final Duration permissionTimeout;

  @override
  Future<bool> hasPermission() =>
      _inner.hasPermission().timeout(permissionTimeout);

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) =>
      _inner.startStream(config).timeout(platformTimeout);

  @override
  Future<void> stop() => _inner.stop().timeout(platformTimeout);
}

/// What the microphone hardware is doing, as far as this process can know.
///
/// [unknown] is the honest answer between "we asked the platform to change
/// something" and "the platform told us it did", and it is a state in its own
/// right rather than an optimistic guess in either direction: a `stop()` that
/// throws or never answers leaves the recorder possibly still streaming, and
/// recording that as [idle] is exactly how a later `startStream` ended up
/// issued on a live recorder.
enum MicHardware { idle, streaming, unknown }

/// Thrown when the microphone is refused because somebody else already holds
/// it — and, crucially, WITHOUT taking anything.
///
/// It is a distinct type because the correct response is distinct: a borrower
/// that catches this must NOT run its release, or it ends a loan it never
/// held and deafens the conversation that loan belongs to. Extends
/// [StateError] so it still reads as the programming error it is.
class MicAlreadyLoaned extends StateError {
  MicAlreadyLoaned() : super('the microphone is already on loan');
}

/// One recording session on [MicCapture]'s single recorder.
///
/// A session has an identity from the instant it is REQUESTED — [MicCapture.start]
/// is synchronous and hands the handle back before the platform has opened
/// anything. That is the whole point. The gap between "asked the platform for
/// the microphone" and "the platform answered" is where six bugs of the same
/// class lived: with only a `bool _recording` (set after `startStream`
/// resolved) there was no way to *name* the session in flight, so a caller who
/// had given up could not tell its own session from a newer one, and its
/// `stop()` killed whichever session happened to be live.
///
/// With a session handle, [stop] stops the session it names and nothing else:
/// once a newer session owns the recorder, an older handle's stop is a no-op.
/// A stale caller is therefore *structurally* unable to deafen a live one —
/// there is no guard to forget, because there is no reachable code path.
class MicSession {
  MicSession._(this._owner, this._id, this.stream);

  final MicCapture _owner;
  final int _id;

  /// The session's 16 kHz PCM16LE frames, once the platform has handed them
  /// over. Completes with a [StateError] if the session was stopped or
  /// superseded before the platform answered, or if permission was refused,
  /// and with a [TimeoutException] if the platform never answered at all.
  final Future<Stream<Uint8List>> stream;

  /// Whether this session still owns the recorder.
  bool get isActive => _owner._owns(_id);

  /// Stop this session. A no-op — deliberately — once it no longer owns the
  /// recorder.
  ///
  /// NEVER throws and never hangs: it is bounded (see [_BoundedRecorder]) and
  /// it reports a platform failure rather than propagating it. Teardown is
  /// the one thing that must always finish — a rethrow here used to abort
  /// `VoiceController.stopMic()` half-way through, leaving `micOn` true over
  /// a dead microphone, and became an unhandled async error on the
  /// fire-and-forget `dispose()` path.
  Future<void> stop() => _owner._stopSession(_id);
}

/// 16 kHz mono PCM16LE mic stream, matching the server's stt_sample_rate.
/// Requests platform echo-cancel / noise-suppress / auto-gain and the
/// voice-communication audio source (which itself engages the platform AEC).
///
/// ONE [AudioRecorder] is the whole contended resource: everything that wants
/// the microphone goes through here, so this class — not its callers — is
/// where "who owns the recorder right now" has to be decided. See [MicSession].
class MicCapture {
  MicCapture({
    MicRecorder? recorder,
    Duration? platformTimeout,
    Duration? permissionTimeout,
  })  : platformTimeout = platformTimeout ?? defaultPlatformTimeout,
        _recorder = _BoundedRecorder(
          recorder ?? _PluginRecorder(),
          platformTimeout: platformTimeout ?? defaultPlatformTimeout,
          permissionTimeout: permissionTimeout ?? defaultPermissionTimeout,
        );

  /// The bound every platform call in here is subject to, exposed for the one
  /// microphone-shaped call that does NOT come through this class: the
  /// `cancel()` of the subscription a caller attaches to a session's stream.
  /// That subscription belongs to the plugin's own stream, so a caller has to
  /// bound it — and the honest bound is the same one the hardware gets.
  final Duration platformTimeout;

  /// How long `startStream`/`stop` may take before we stop believing in them.
  /// Comfortably longer than either takes on a healthy device, and strictly
  /// shorter than `VoiceLockClient.acquireTimeout` so the borrower's own
  /// bound is the outer one.
  static const Duration defaultPlatformTimeout = Duration(seconds: 4);

  /// `hasPermission()` can put a system dialog in front of the user on first
  /// run, so it gets a human-scale bound rather than a hardware-scale one —
  /// bounded all the same, because a dialog the platform never resolves is
  /// still a wedge.
  static const Duration defaultPermissionTimeout = Duration(seconds: 60);

  /// Always a [_BoundedRecorder]. The raw recorder is not stored anywhere:
  /// see Invariant B on [_BoundedRecorder].
  final MicRecorder _recorder;

  int _seq = 0;

  /// The session that owns the recorder, or null when nobody does.
  ///
  /// Claimed SYNCHRONOUSLY by [start], before `startStream` resolves. This is
  /// the optimistic half of the state, and the one that matters: it is what
  /// makes an in-flight session nameable, and therefore stoppable by its own
  /// owner and untouchable by anybody else.
  int? _activeId;

  /// The session whose `startStream` is in flight RIGHT NOW, if any.
  ///
  /// While ANY open is inside `startStream`, no stop may touch the hardware or
  /// the [_ops] chain — see [_stopSession]. It is tracked explicitly rather
  /// than inferred from [_hardware], because "unknown" has a second cause — a
  /// stop that failed — and the two need opposite handling.
  int? _startInFlight;

  /// What the hardware is doing. Deliberately NOT optimistic in either
  /// direction: every write happens BEFORE the platform call it describes and
  /// is true whatever that call goes on to do. The only write that depends on
  /// a call returning moves [MicHardware.unknown] to a MORE precise value,
  /// never to a less true one.
  MicHardware _hardware = MicHardware.idle;

  /// Serialises platform work on the recorder, so two `startStream` calls are
  /// never in flight at once.
  Future<void> _ops = Future<void>.value();

  /// Whether the platform is, as far as we know, streaming.
  bool get isRecording => _hardware == MicHardware.streaming;

  /// The full three-valued answer, including "we asked and were not told".
  MicHardware get hardware => _hardware;

  /// Claim the recorder and begin opening a session on it.
  ///
  /// Synchronous on purpose: the caller gets a handle it can name — and stop —
  /// immediately, including while the platform is still thinking about it.
  MicSession start() {
    final id = ++_seq;
    _activeId = id;
    final previous = _ops;
    final open = _open(id, previous);
    // Attaching the handler here also means a caller that never awaits
    // [MicSession.stream] cannot produce an unhandled async error.
    _ops = _settled(open);
    return MicSession._(this, id, open);
  }

  Future<Stream<Uint8List>> _open(int id, Future<void> previous) async {
    try {
      // Wait for whatever the recorder was already doing. Only one
      // `startStream` may ever be in flight: two concurrent ones on a single
      // AudioRecorder is undefined behaviour on the plugin side (it either
      // throws or tears the first stream down), and issuing a "recovery"
      // start on top of a wedged one is precisely how the microphone used to
      // be lost.
      await previous;
      if (_activeId != id) throw _superseded(id);
      if (!await _recorder.hasPermission()) {
        throw StateError('microphone permission denied');
      }
      if (_activeId != id) throw _superseded(id);
      // Defensive: a start that supersedes a still-streaming session must
      // close it first, or `startStream` runs on a live recorder. `unknown`
      // counts as still-streaming — that is the whole point of the state.
      if (_hardware != MicHardware.idle) {
        await _stopHardware();
        if (_hardware != MicHardware.idle) {
          // We asked the platform to stop and it would not say that it did.
          // Refusing to open is the only honest move: `startStream` on a
          // recorder that may still be live is the undefined behaviour this
          // whole class exists to prevent, and a session that cannot be
          // opened safely must fail loudly rather than half-open.
          throw StateError('the microphone would not stop; refusing to start');
        }
        if (_activeId != id) throw _superseded(id);
      }
      // Written BEFORE the call, and true whatever it does: from here the
      // platform may or may not be streaming, and a start that throws or
      // never answers must leave the NEXT open knowing that.
      _hardware = MicHardware.unknown;
      _startInFlight = id;
      final Stream<Uint8List> stream;
      try {
        stream = await _recorder.startStream(_config);
      } finally {
        if (_startInFlight == id) _startInFlight = null;
      }
      if (_activeId != id) {
        // Superseded (or stopped) while the platform was opening. Whoever
        // took the claim is QUEUED BEHIND this future and has not touched the
        // recorder yet, so closing our own orphan here cannot close theirs —
        // which is exactly the move that used to kill a live session.
        await _stopHardware();
        throw _superseded(id);
      }
      _hardware = MicHardware.streaming;
      return stream;
    } catch (_) {
      // A session that failed to open owns nothing.
      if (_activeId == id) _activeId = null;
      rethrow;
    }
  }

  Future<void> _stopSession(int id) async {
    // Not ours to stop. THE invariant: a stale caller cannot reach the
    // hardware a newer session owns.
    if (_activeId != id) return;
    _activeId = null;
    if (_startInFlight != null) {
      // SOME open is inside `startStream` — not necessarily ours. Whichever it
      // is, it now finds itself unowned (we just cleared the claim, and an
      // open that still owned it would have to BE `id`) and closes its own
      // orphan, so a platform stop here would only race it.
      //
      // The reason this is deliberately the BROAD test and not `== id`: the
      // lines below REPLACE `_ops`. When the in-flight open belongs to another
      // session, replacing the chain drops that still-running open out of the
      // queue, the next start issues `startStream` on top of it (Rule 2
      // broken, measured maxConcurrentStarts == 2), and the stale open's
      // orphan-close then stops the recorder that newer session is using
      // (Rule 3, whose safety argument rests on Rule 2). That is the seventh
      // Critical of this class: `micOn == true` over a stopped recorder, with
      // only a double power tap recovering. `_hardware` still moves BEFORE any
      // platform call — this restores the old guard's BREADTH, not its
      // dishonest timing.
      //
      // Every OTHER await inside `_open` re-checks `_activeId` before it
      // touches the recorder, so the window where a dropped chain can produce
      // overlapping `startStream` calls is exactly this one.
      return;
    }
    if (_hardware == MicHardware.idle) return;
    final stopped = _stopHardware();
    // The next start waits for this stop to land before it opens anything.
    _ops = _settled(stopped);
    await stopped;
  }

  /// Ask the platform to stop, and never lie about the result.
  ///
  /// INVARIANT A at its sharpest: `_hardware` moves to [MicHardware.unknown]
  /// on the near side of the await, because from the instant we ask, we do
  /// not know. The old code set `false` here and it was simply not true when
  /// the call threw — the recorder kept streaming while the next `start()`
  /// skipped its defensive stop and issued `startStream` on top of it
  /// (measured). Never throws: teardown is the one thing that must always
  /// finish.
  Future<void> _stopHardware() async {
    _hardware = MicHardware.unknown;
    try {
      await _recorder.stop();
      _hardware = MicHardware.idle;
    } catch (error, stack) {
      FlutterError.reportError(FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'mic_capture',
        context: ErrorDescription(
            'the platform would not stop the microphone; treating the '
            'recorder as possibly still streaming'),
      ));
    }
  }

  bool _owns(int id) => _activeId == id;

  static StateError _superseded(int id) =>
      StateError('mic session $id was superseded before it opened');

  static Future<void> _settled(Future<Object?> f) =>
      f.then<void>((_) {}, onError: (Object _, StackTrace __) {});

  static const RecordConfig _config = RecordConfig(
    encoder: AudioEncoder.pcm16bits,
    sampleRate: 16000,
    numChannels: 1,
    echoCancel: true,
    noiseSuppress: true,
    autoGain: true,
    androidConfig: AndroidRecordConfig(
      audioSource: AndroidAudioSource.voiceCommunication,
    ),
  );
}
