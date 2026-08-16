import 'dart:async';
import 'dart:typed_data';

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

/// One recording session on [MicCapture]'s single recorder.
///
/// A session has an identity from the instant it is REQUESTED — [MicCapture.start]
/// is synchronous and hands the handle back before the platform has opened
/// anything. That is the whole point. The gap between "asked the platform for
/// the microphone" and "the platform answered" is where five bugs of the same
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
  /// superseded before the platform answered, or if permission was refused.
  final Future<Stream<Uint8List>> stream;

  /// Whether this session still owns the recorder.
  bool get isActive => _owner._owns(_id);

  /// Stop this session. A no-op — deliberately — once it no longer owns the
  /// recorder.
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
  MicCapture({MicRecorder? recorder})
      : _recorder = recorder ?? _PluginRecorder();

  final MicRecorder _recorder;

  int _seq = 0;

  /// The session that owns the recorder, or null when nobody does.
  ///
  /// Claimed SYNCHRONOUSLY by [start], before `startStream` resolves. This is
  /// the optimistic half of the state, and the one that matters: it is what
  /// makes an in-flight session nameable, and therefore stoppable by its own
  /// owner and untouchable by anybody else.
  int? _activeId;

  /// Whether the platform is actually streaming. Deliberately NOT optimistic:
  /// this tracks the hardware, and a value set before `startStream` resolved
  /// would make [_stopSession] issue a platform stop against a recorder that
  /// never started. Ownership answers "may I?"; this answers "is it on?".
  bool _running = false;

  /// Serialises platform work on the recorder, so two `startStream` calls are
  /// never in flight at once.
  Future<void> _ops = Future<void>.value();

  bool get isRecording => _running;

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
      // close it first, or `startStream` runs on a live recorder.
      if (_running) {
        _running = false;
        await _recorder.stop();
        if (_activeId != id) throw _superseded(id);
      }
      final stream = await _recorder.startStream(_config);
      if (_activeId != id) {
        // Superseded (or stopped) while the platform was opening. Whoever
        // took the claim is QUEUED BEHIND this future and has not touched the
        // recorder yet, so closing our own orphan here cannot close theirs —
        // which is exactly the move that used to kill a live session.
        await _recorder.stop();
        throw _superseded(id);
      }
      _running = true;
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
    if (!_running) {
      // Our own open is still in flight. It will find itself unowned and
      // close its own orphan; issuing a platform stop now would race it.
      return;
    }
    _running = false;
    final stopped = _recorder.stop();
    // The next start waits for this stop to land before it opens anything.
    _ops = _settled(stopped);
    await stopped;
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
