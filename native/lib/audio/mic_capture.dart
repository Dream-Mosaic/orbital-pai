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
    required this.onAbandonedCallLanded,
  });

  final MicRecorder _inner;
  final Duration platformTimeout;
  final Duration permissionTimeout;

  /// Told when a platform call this wrapper GAVE UP ON finally completes.
  final void Function() onAbandonedCallLanded;

  @override
  Future<bool> hasPermission() =>
      _inner.hasPermission().timeout(permissionTimeout);

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) =>
      _bounded(_inner.startStream(config));

  @override
  Future<void> stop() => _bounded(_inner.stop());

  /// [platformTimeout] — plus a watch on what the call does AFTER the bound
  /// expires, because it goes on doing it.
  ///
  /// `.timeout()` stops WAITING for a platform call; it cannot cancel one.
  /// Dart has no way to reach into a platform channel and withdraw a request,
  /// so the recorder is still inside an abandoned `startStream`/`stop` when
  /// the next operation is issued, and will still act on it whenever it
  /// finishes. That is the limit of this design (see [MicCapture]). The one
  /// thing still knowable is WHEN it lands, so keep listening and say so.
  Future<T> _bounded<T>(Future<T> call) async {
    try {
      return await call.timeout(platformTimeout);
    } on TimeoutException {
      call.then<void>(
        (_) => onAbandonedCallLanded(),
        onError: (Object _, StackTrace __) => onAbandonedCallLanded(),
      );
      rethrow;
    }
  }
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
/// A session has an identity from the instant it is REQUESTED —
/// [MicCapture.start] is synchronous and hands the handle back before the
/// platform has opened anything. The gap between asking for the microphone
/// and being given it is where six bugs of one class lived: with only a
/// `bool _recording`, set after `startStream` resolved, an in-flight session
/// had no NAME, so a caller who had given up could not tell its own session
/// from a newer one and its `stop()` killed whichever happened to be live.
///
/// With a handle, [stop] stops the session it names and nothing else: once a
/// newer session owns the recorder, an older handle's stop is a no-op. A
/// stale caller is *structurally* unable to deafen a live one — no guard to
/// forget, because no reachable code path.
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
  /// recorder, and the CLAIM is given up synchronously, so nothing a caller
  /// does next waits on the platform.
  ///
  /// Never throws and always finishes: bounded by [MicCapture._stopSession],
  /// and it reports a platform failure rather than propagating it. A rethrow
  /// here used to abort `VoiceController.stopMic()` half-way through, leaving
  /// `micOn` true over a dead microphone, and became an unhandled async error
  /// on the fire-and-forget `dispose()` path.
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
  }) : platformTimeout = platformTimeout ?? defaultPlatformTimeout {
    _recorder = _BoundedRecorder(
      recorder ?? _PluginRecorder(),
      platformTimeout: platformTimeout ?? defaultPlatformTimeout,
      permissionTimeout: permissionTimeout ?? defaultPermissionTimeout,
      onAbandonedCallLanded: _abandonedCallLanded,
    );
  }

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
  /// see Invariant B on [_BoundedRecorder]. `late` only because the wrapper
  /// is handed a callback into this object.
  late final MicRecorder _recorder;

  int _seq = 0;

  /// The session that owns the recorder, or null when nobody does. Claimed
  /// synchronously by [start], given up synchronously by [_stopSession] —
  /// both BEFORE anything is queued, which is what lets an operation already
  /// in [_ops] find on its first line that nobody wants it and step aside
  /// without touching the platform.
  int? _activeId;

  /// What the hardware is doing. Deliberately NOT optimistic in either
  /// direction: every write happens BEFORE the platform call it describes and
  /// is true whatever that call goes on to do. The only write that depends on
  /// a call returning moves [MicHardware.unknown] to a MORE precise value,
  /// never to a less true one.
  MicHardware _hardware = MicHardware.idle;

  /// THE queue, and the only route to the recorder.
  ///
  /// Everything that changes what the recorder is doing — `startStream` and
  /// `stop`, opens and teardowns alike — goes through [_queue]. No fast path,
  /// no short-circuit, no bypass, and that is the whole design: eight defects
  /// of one class came out of there being TWO ways to reach one
  /// `AudioRecorder`. The seventh was a stop REPLACING this chain and
  /// dropping a running open out of it; the eighth was the same stop reaching
  /// the platform without joining the chain at all, whenever no `startStream`
  /// happened to be in flight for its guard to see. Both fixes were guards
  /// about who may interrupt whom. Neither sentence is writable now: a second
  /// concurrent platform call would have to be issued from outside [_queue],
  /// and there is nowhere outside it left to issue one from.
  ///
  /// The one platform call NOT in here is `hasPermission`, and its absence is
  /// load-bearing. It does not change what the recorder is doing, and it can
  /// put a system dialog in front of the user, so its bound is
  /// [defaultPermissionTimeout] — a MINUTE, against four seconds for
  /// everything else. That is the objection that kept stops out of this queue
  /// for two rounds, and asking permission outside it is the answer: see
  /// [_stopSession] for the resulting bound.
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
    final open = _open(id);
    // A caller that never awaits [MicSession.stream] must not turn a refused
    // permission into an unhandled async error.
    open.ignore();
    return MicSession._(this, id, open);
  }

  Future<Stream<Uint8List>> _open(int id) async {
    try {
      // Outside the queue on purpose, and the only call that is — see [_ops].
      if (!await _recorder.hasPermission()) {
        throw StateError('microphone permission denied');
      }
      return await _queue(() async {
        // FIRST, before touching anything: are we still wanted? This reads as
        // redundant against the identical check below and is load-bearing —
        // it is the ninth defect of this class, and deleting it as redundant
        // is how the ninth happened.
        //
        // JOIN ORDER IS NOT START ORDER. `hasPermission` is awaited OUTSIDE
        // the queue (see [_ops]), so an open joins only when its permission
        // check answers, and permission is the one call that can sit in front
        // of a human. A slow dialog for this session and a fast one for the
        // next puts this open into the queue BEHIND the very session that
        // superseded it. The proof that once justified deleting this line —
        // "a superseded open wants the recorder idle just as much, since that
        // is what whoever replaced us queued behind us to do" — assumed the
        // superseder is always queued behind. It is not, and when it is
        // queued ahead the reconcile below is not housekeeping: it is the
        // teardown of a live session. An open holding no claim owns no
        // hardware, so it must not reconcile any.
        if (_activeId != id) throw _superseded(id);
        // Now, and unconditionally for an open that IS still wanted: a start
        // that supersedes a live session must close it, or `startStream` runs
        // on a live recorder.
        await _ensureIdle();
        if (_hardware != MicHardware.idle) {
          // We asked the platform to stop and it would not say that it did.
          // Refusing to open is the only honest move: `startStream` on a
          // recorder that may still be live is the undefined behaviour this
          // whole class exists to prevent, and a session that cannot be
          // opened safely must fail loudly rather than half-open.
          throw StateError('the microphone would not stop; refusing to start');
        }
        // And AGAIN, because the reconcile above is an await like any other:
        // a session that was still wanted at the head of the queue can have
        // been superseded inside its own defensive stop. The two checks cover
        // two different windows and each has its own test; neither is the
        // other's spare.
        if (_activeId != id) throw _superseded(id);
        // Written BEFORE the call, and true whatever it does: from here the
        // platform may or may not be streaming, and a start that throws or
        // never answers must leave the NEXT operation knowing that.
        _hardware = MicHardware.unknown;
        final stream = await _recorder.startStream(_config);
        _hardware = MicHardware.streaming;
        if (_activeId != id) {
          // Superseded while the platform was opening. Closing our own orphan
          // is safe for a reason it did not used to be: we are INSIDE the
          // queue, so it cannot overlap anybody else's platform call. It has
          // to happen HERE rather than be left to whoever comes next, because
          // a superseding start that then fails its permission check never
          // joins the queue at all, and nobody would close this.
          await _ensureIdle();
          throw _superseded(id);
        }
        return stream;
      });
    } catch (_) {
      // A session that failed to open owns nothing.
      if (_activeId == id) _activeId = null;
      rethrow;
    }
  }

  /// Give up [id]'s claim and bring the hardware down with it. The claim goes
  /// synchronously; the platform work joins the queue like everything else.
  ///
  /// **It does not park behind a wedged open.** Nothing guards against that;
  /// three facts leave no room for it. A system dialog holds no queue slot
  /// (`hasPermission` is asked outside — see [_ops]). Every operation already
  /// queued has just been disowned by the line below, so the most any of them
  /// does before stepping aside is bring the hardware to idle, which is this
  /// teardown's own work. And whatever IS in flight is bounded by
  /// [platformTimeout]. Worst case: one `startStream` plus the close of the
  /// session it opened — 2 × [platformTimeout], and never the minute-long
  /// bound.
  Future<void> _stopSession(int id) {
    // Not ours to stop. THE invariant: a stale caller cannot reach the
    // hardware a newer session owns.
    if (_activeId != id) return Future<void>.value();
    _activeId = null;
    return _queue(_ensureIdle);
  }

  /// Run [body] once every platform call already asked for has finished, and
  /// make the next one wait for it in turn.
  Future<T> _queue<T>(Future<T> Function() body) {
    final result = _ops.then((_) => body());
    _ops = _settled(result);
    return result;
  }

  /// Bring the hardware to [MicHardware.idle] if it is not already there —
  /// the one reconciliation a teardown, the head of an open and an orphan
  /// close all perform. Callers must be inside [_queue].
  Future<void> _ensureIdle() async {
    if (_hardware != MicHardware.idle) await _stopHardware();
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

  /// A platform call we gave up waiting for has finally landed.
  ///
  /// It cannot be prevented — `.timeout()` abandons, it does not cancel — but
  /// the moment it lands, any precise belief held here is one the platform has
  /// just had the chance to falsify: an abandoned `stop()` may have taken down
  /// the session that replaced it, an abandoned `startStream` may have opened
  /// the hardware after we recorded it idle. [MicHardware.unknown] is the only
  /// honest answer, and it is the USEFUL one — it is what makes the next
  /// [_ensureIdle] reconcile the recorder instead of skipping it and opening a
  /// second stream on top.
  ///
  /// Deliberately unconditional. It may be overwritten moments later by a
  /// platform call that is still in flight, and that is correct: that call's
  /// answer is the more recent news.
  void _abandonedCallLanded() => _hardware = MicHardware.unknown;

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
