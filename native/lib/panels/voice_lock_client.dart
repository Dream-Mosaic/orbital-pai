import 'dart:async';

import 'package:flutter/foundation.dart';

import '../connection/app_connection.dart';
import '../phoenix/decoded_message.dart';
import '../phoenix/phoenix_channel.dart';

/// One row of "Recently filtered", already rendered for display.
class GateDrop {
  const GateDrop({
    required this.decision,
    required this.transcript,
    required this.score,
  });

  final String decision;
  final String transcript;

  /// Nullable on the wire: GateEvent.score is a nullable float, and the web
  /// renders it conditionally (`e.score && Float.round(e.score, 2)`). Tolerate
  /// null; do NOT coerce it to 0.0, which would read as a confident score.
  final double? score;

  static GateDrop fromJson(Map<String, dynamic> j) => GateDrop(
        decision: j['decision'] as String? ?? '',
        transcript: j['transcript'] as String? ?? '',
        score: (j['score'] as num?)?.toDouble(),
      );
}

/// The Voice Lock drawer's state, as the server rendered it.
class VoiceLockState {
  const VoiceLockState({
    required this.userId,
    required this.mode,
    required this.enrolledSlots,
    required this.verifierReady,
    required this.drops,
  });

  /// The token user's id. The enrollment topic is `enroll:<user_id>` and is
  /// SELF-ONLY on the server, so without this there is nothing to join — the
  /// native client has no other source of its own id.
  final int? userId;

  /// The raw string the server stores: "off" | "shadow" | "enforce".
  final String mode;
  final List<int> enrolledSlots;
  final bool verifierReady;
  final List<GateDrop> drops;

  static VoiceLockState fromJson(Map<String, dynamic> j) => VoiceLockState(
        userId: (j['user_id'] as num?)?.toInt(),
        mode: j['mode'] as String? ?? 'off',
        enrolledSlots: j['enrolled_slots'] is List
            ? (j['enrolled_slots'] as List)
                .whereType<num>()
                .map((n) => n.toInt())
                .toList(growable: false)
            : const <int>[],
        verifierReady: j['verifier_ready'] as bool? ?? false,
        drops: _drops(j['drops']),
      );

  // A row without a decision cannot be rendered as a badge. Drop just that
  // row rather than letting a cast throw inside the stream listener and blank
  // an otherwise good payload — the same tolerance reminders_client.dart and
  // memory_client.dart apply to their own list rows.
  static List<GateDrop> _drops(Object? raw) => raw is List
      ? raw
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .where((m) => m['decision'] is String)
          .map(GateDrop.fromJson)
          .toList(growable: false)
      : const [];
}

/// How a recording ended. `rejected` carries its reason out through
/// `_rejectReason`, kept beside the completer so the enum stays a plain enum.
enum _Ending { ok, rejected, aborted }

/// Joined only while the Voice Lock drawer layer is on screen.
/// Server-authoritative for everything the server owns: a mode tap pushes and
/// the UI re-renders from the next `state`.
///
/// [recordingSlot] and [enrollError] are CLIENT-LOCAL UI state — exactly as
/// they are `prev`-preserved LiveView assigns on the web (conversation_live.ex
/// load_voice_lock/1) — and are not on the wire.
///
/// The microphone is injected as two callbacks rather than reached for via
/// VoiceController: main.dart has no dependency injection, and the resume
/// guarantee is the thing most worth testing headless.
class VoiceLockClient extends ChangeNotifier {
  VoiceLockClient({
    required AppConnection connection,
    required this.acquireMic,
    required this.releaseMic,
    this.clipLimit = const Duration(seconds: 12),
    this.replyTimeout = const Duration(seconds: 10),
    this.teardownTimeout = const Duration(seconds: 2),
    this.acquireTimeout = const Duration(seconds: 5),
  }) : _connection = connection;

  static const String topic = 'panel:voice_lock:henry';

  final AppConnection _connection;

  /// VoiceController.suspendMic — stops the conversation's capture and hands
  /// back a fresh 16 kHz PCM16 stream for the clip.
  final Future<Stream<Uint8List>> Function() acquireMic;

  /// VoiceController.resumeMic. Called from exactly one place: the `finally`
  /// in [startRecording].
  final Future<void> Function() releaseMic;

  /// How long one clip records. The prompts are ~10s; the server caps
  /// accumulation at 15s (App.Speaker.max_clip_bytes/0) and needs at least 6s.
  final Duration clipLimit;

  /// How long to wait for the `clip_done` reply before giving up on it.
  final Duration replyTimeout;

  /// How long the mic subscription's cancel() is allowed to hang before the
  /// teardown gives up waiting on it and moves on anyway. A cancel() that
  /// never completes must not be able to trap the finally forever — that is
  /// silent, permanent deafness, worse than a thrown exception because there
  /// is nothing to catch.
  final Duration teardownTimeout;

  /// How long [acquireMic] (VoiceController.suspendMic) is allowed to hang
  /// before [startRecording] gives up on it. suspendMic's own platform-
  /// channel awaits — stopping the conversation's recorder, then starting
  /// the loaned one — are unbounded: a wedged audio subsystem or another
  /// app holding the mic can park them forever. Unlike a thrown exception,
  /// a hang there is invisible to the `catch` below: `await acquireMic()`
  /// simply never returns, so the `finally` never runs, `_micLoaned` is
  /// already latched, and the conversation's own capture is already
  /// stopped — deaf, permanently, silently. This bound turns that hang into
  /// an ordinary `TimeoutException`, which the existing `catch` already
  /// treats exactly like a refused mic.
  final Duration acquireTimeout;

  PhoenixChannel? _channel;
  StreamSubscription<DecodedMessage>? _sub;
  VoiceLockState? _state;
  bool _open = false;
  bool _disposed = false;

  int? _recordingSlot;
  (int, String)? _enrollError;

  /// Which recording the UI state belongs to. [startRecording]'s `finally`
  /// runs long after [close] has already ended the clip (up to teardownTimeout
  /// per bounded step), so by then a NEWER recording may own `_recordingSlot`
  /// and `_abortRecording` — and a stale teardown clearing them would
  /// re-enable the Record buttons mid-clip and, worse, unhook the abort the
  /// next close() needs.
  int _recordingSeq = 0;

  /// Set while a recording is in flight; close()/dispose() call it to end the
  /// clip early. Null the rest of the time.
  void Function()? _abortRecording;

  VoiceLockState? get state => _state;
  bool get isOpen => _open;

  /// The slot currently recording, or null. The view disables ALL THREE
  /// Record buttons while this is non-null (the web's
  /// `disabled={@vl.recording_slot != nil}`).
  int? get recordingSlot => _recordingSlot;

  /// `(slot, message)` for the last failed enrollment, or null.
  (int, String)? get enrollError => _enrollError;

  void open() {
    if (_open) return;
    _open = true;
    _connection.openChannel(topic, onChannel: _adopt);
  }

  void close() {
    if (!_open) return;
    _open = false;
    // A recording in flight ends here; its own `finally` is what gives the
    // microphone back, so this must not try to do it too.
    _abortRecording?.call();
    // …but the UI state is ours, and nothing is recording once the layer is
    // gone. Without this, leaving and re-entering Voice Lock inside the
    // finally's window (up to ~4s if both bounded steps time out) showed all
    // three Record buttons disabled with no explanation.
    _recordingSlot = null;
    _connection.closeChannel(topic);
    unawaited(_sub?.cancel());
    _sub = null;
    _channel = null;
    _state = null;
    _enrollError = null;
    _notify();
  }

  void setMode(String mode) => _push('set_mode', {'mode': mode});

  /// Record one enrollment clip into [slot] (1..3) and hand it to
  /// `AppWeb.EnrollChannel`.
  ///
  /// EVERY exit from here runs the `finally`, and the `finally` is the ONE
  /// place that releases the microphone: success, a server rejection, a reply
  /// that never comes, the clip cap, close()/dispose() mid-record, a socket
  /// death mid-record, and an acquireMic() that throws — with one exception,
  /// `not_connected` (openChannel found no live socket), where acquireMic()
  /// was never even called and there is nothing to give back. A path that
  /// skips the release it OWES leaves the assistant deaf with no visible
  /// cause. Do not add a second release site to shave the reply latency —
  /// two sites is how one gets missed.
  ///
  /// The `finally` itself must not be a single point of failure: no one
  /// cleanup step (cancelling the mic, releasing it, leaving the channel) may
  /// stop the others from running just because it threw or hung. A
  /// `micSub.cancel()` that throws must not skip `releaseMic()`; a
  /// `releaseMic()` that throws must not skip clearing `recordingSlot` or
  /// leaving `enroll:<uid>` — either failure mode reproduces this task's
  /// worst case (a stuck mic, or Record buttons dead forever) by a different
  /// door. See [_guardStep].
  ///
  /// `enroll:<uid>` is joined PER RECORDING, not per panel: it accumulates PCM
  /// in channel state, so holding it open across a panel session would hold a
  /// buffer for nothing. Join on record, clip_done, leave.
  Future<void> startRecording(int slot) async {
    if (_disposed || _recordingSlot != null) return;
    final uid = _state?.userId;
    // No state yet means no user id, and enroll:<uid> is self-only on the
    // server. Nothing to join; the panel renders nothing in this state anyway.
    if (uid == null) return;
    final enrollTopic = 'enroll:$uid';

    final recordingId = ++_recordingSeq;
    _recordingSlot = slot;
    _enrollError = null;
    _notify();

    StreamSubscription<Uint8List>? micSub;
    StreamSubscription<DecodedMessage>? chSub;
    Timer? capTimer;
    Timer? replyTimer;
    final ended = Completer<_Ending>();
    var rejectReason = 'unknown';
    // Set right before acquireMic() is called — even if it throws — so the
    // finally releases only a mic that was actually (attempted to be) taken.
    // Without this, a not_connected bail-out (which returns before ever
    // calling acquireMic) would still call releaseMic(), resuming a
    // conversation mic that was never suspended.
    var micAttempted = false;
    void end(_Ending e) {
      if (!ended.isCompleted) ended.complete(e);
    }

    _abortRecording = () => end(_Ending.aborted);

    try {
      // No onChannel listener: the socket is already up by the time a
      // recording can start (open() joined the panel topic first), so
      // openChannel's return value already IS the channel — a listener would
      // just be handed the same instance a second time, for a topic we tear
      // down ourselves before any reconnect could recreate it.
      final enroll = _connection.openChannel(enrollTopic);
      if (enroll == null) {
        // openChannel returns null when there is no socket up. Guarded on
        // _open: if the panel was closed while this was resolving, close()
        // already cleared enrollError, and a stale write here would
        // reappear on the next open().
        if (_open) _enrollError = (slot, 'failed: not_connected');
        return;
      }

      // The enroll channel replies to exactly ONE event, `clip_done`: binary
      // `audio` frames carry no ref, `clip_reset` returns {:noreply, socket}
      // and Phoenix sends no frame for that at all, and the join reply is
      // consumed by PhoenixSocket before it reaches `messages`. So any
      // phx_reply arriving here IS the clip_done reply, and no ref
      // bookkeeping is needed — PhoenixChannel.push hands none out.
      chSub = enroll.messages.listen(
        (m) {
          if (m.event != 'phx_reply') return;
          if (m.replyStatus == 'ok') {
            // Nothing to set locally: enroll_clip/3 broadcasts, so the panel
            // channel re-pushes `state` with this slot in enrolled_slots.
            end(_Ending.ok);
          } else {
            final resp = m.json?['response'];
            rejectReason =
                (resp is Map ? resp['reason'] : null)?.toString() ?? 'unknown';
            end(_Ending.rejected);
          }
        },
        // The socket died under us: the partial clip dies with the channel.
        onDone: () => end(_Ending.aborted),
      );

      final Stream<Uint8List> stream;
      try {
        micAttempted = true;
        // Bounded the same way releaseMic() is bounded below: a hang must
        // become a catchable failure, not a permanently parked await. See
        // [acquireTimeout] for why this exists.
        stream = await acquireMic().timeout(acquireTimeout);
      } catch (_) {
        // Matches the web hook's own reason string for a refused mic
        // (assets/js/voice/enroll.js:37). A timed-out acquire lands here
        // too now (TimeoutException), not just an outright throw.
        if (_open) _enrollError = (slot, 'failed: mic_blocked');
        return;
      }
      micSub = stream.listen((chunk) {
        if (enroll.isJoined) enroll.pushBinary('audio', chunk);
      });

      capTimer = Timer(clipLimit, () {
        // Stop feeding BEFORE closing the clip, so nothing lands after it.
        // Left non-null on purpose (not micSub = null): the finally
        // re-cancels the same subscription, which is what actually
        // guarantees release waits for the teardown to finish — cancel() is
        // idempotent, but an unawaited fire-and-forget call here on its own
        // gives no such guarantee.
        unawaited(micSub?.cancel());
        if (!enroll.isJoined) {
          end(_Ending.aborted);
          return;
        }
        enroll.push('clip_done', {'slot': slot});
        replyTimer = Timer(replyTimeout, () {
          rejectReason = 'timeout';
          end(_Ending.rejected);
        });
      });

      switch (await ended.future) {
        case _Ending.ok:
          break;
        case _Ending.rejected:
          if (_open) _enrollError = (slot, 'failed: $rejectReason');
        case _Ending.aborted:
          // Discard the partial clip: without this, the next clip on this
          // topic would be prefixed with the stale audio.
          if (enroll.isJoined) enroll.push('clip_reset', const {});
      }
    } finally {
      capTimer?.cancel();
      replyTimer?.cancel();

      // Each step is independently fault-tolerant: cancel, release, leave —
      // none may stop the others from running, whether it throws or (for the
      // mic, which is real hardware behind a plugin) simply never completes.
      // Both the cancel AND the release are bounded by teardownTimeout: an
      // earlier version only bounded the cancel, and a releaseMic() that
      // never completes (VoiceController.resumeMic awaits _mic.stop(), a
      // platform-channel call) parked this finally forever — recordingSlot
      // stuck, enroll:<uid> leaked, every Record button dead for the life of
      // the app. Same cure as the cancel: stop waiting, keep going.
      await _guardStep(
        'cancel mic subscription',
        () =>
            micSub?.cancel().timeout(teardownTimeout, onTimeout: () {}) ??
            Future<void>.value(),
      );
      // THE one and only release site. Guarded on micAttempted: a bail-out
      // before acquireMic() was ever called (not_connected) took nothing, so
      // there is nothing to give back.
      if (micAttempted) {
        await _guardStep(
          'release mic',
          () => releaseMic().timeout(teardownTimeout, onTimeout: () {}),
        );
      }
      await _guardStep(
        'cancel channel subscription',
        () => chSub?.cancel() ?? Future<void>.value(),
      );
      // Everything below belongs to THIS recording only. close() clears the
      // slot up front so a re-entered panel is usable immediately, which
      // means a NEWER recording can already be under way by the time this
      // teardown gets here — and `enroll:<uid>` is per-USER, not per-clip, so
      // it is the very channel that clip is streaming into. Leaving it would
      // kill the live clip (its own chSub sees `onDone` and aborts);
      // clobbering `_recordingSlot` would light the Record buttons up
      // mid-clip; clobbering `_abortRecording` would leave the next close()
      // with no way to end it. The newer recording's own finally does all
      // three when its turn comes.
      if (_recordingSeq == recordingId) {
        _guardSync(
            'close channel', () => _connection.closeChannel(enrollTopic));
        _abortRecording = null;
        _recordingSlot = null;
      }
      _notify();
    }
  }

  /// Runs one `finally` cleanup step, catching anything it throws —
  /// synchronously or via its Future — and reporting it via [_reportStepError]
  /// instead of letting it stop the ones after it: see [startRecording]'s own
  /// doc for why silently losing track of "did the mic actually come back" is
  /// the failure this whole task exists to prevent. [step] is a short label
  /// (e.g. "release mic") used only for the report.
  ///
  /// This deliberately never rethrows, `Error` included. `startRecording` is
  /// called fire-and-forget from a button's `onTap`
  /// (`meridian/voice_lock_panel.dart`) with no `await`, no `catch`, and this
  /// app installs no zone/`PlatformDispatcher` error handler — so a rethrow
  /// here (even one deferred until after every step has run) would surface
  /// as an unhandled Future rejection at that call site, not a caught,
  /// reportable error. For the one subsystem whose entire job is "the mic
  /// must always come back, and nothing about that process may go further
  /// wrong," trading a silent bug for a possible crash is not a win — swap a
  /// try/catch for an uncaught throw and Critical #2 (the last review) comes
  /// back by a different door. `StateError`, which several tests below throw
  /// to simulate realistic plugin/platform failures, is itself an `Error`
  /// subtype in Dart, not an `Exception` — so an Error/Exception split does
  /// not even cleanly separate "expected hardware failure" from "programming
  /// bug" here. Observability (report, keep going) is the fix for a silent
  /// bug; propagation is not.
  Future<void> _guardStep(String step, Future<void> Function() action) async {
    try {
      await action();
    } catch (error, stack) {
      _reportStepError(step, error, stack);
    }
  }

  /// Synchronous counterpart to [_guardStep], for a cleanup step (like
  /// closeChannel) that isn't async.
  void _guardSync(String step, void Function() action) {
    try {
      action();
    } catch (error, stack) {
      _reportStepError(step, error, stack);
    }
  }

  /// Reports a caught cleanup-step failure through Flutter's normal
  /// already-caught-error channel (`FlutterError.onError`, which defaults to
  /// dumping to the console and is where a future crash-reporting hook would
  /// attach) instead of dropping it. Before this, `_guardStep`/`_guardSync`
  /// used a bare `catch (_) {}`: a review measured a `TypeError` thrown from
  /// `releaseMic` producing zero zone errors and no output at all — a
  /// genuine programming bug vanishing without trace in the one subsystem
  /// whose whole failure mode is silence.
  void _reportStepError(String step, Object error, StackTrace stack) {
    FlutterError.reportError(FlutterErrorDetails(
      exception: error,
      stack: stack,
      library: 'voice_lock_client',
      context: ErrorDescription('startRecording cleanup step "$step" failed'),
    ));
  }

  bool _push(String event, Map<String, dynamic> payload) {
    final ch = _channel;
    // Phoenix answers a frame on a topic it has not joined with "unmatched
    // topic", so a write between open() and the join reply is silently lost.
    if (ch == null || !ch.isJoined) return false;
    ch.push(event, payload);
    return true;
  }

  /// Delivery is at channel CREATION, not join: the server pushes `state`
  /// straight behind its join reply and `messages` is unbuffered.
  void _adopt(PhoenixChannel ch) {
    _channel = ch;
    unawaited(_sub?.cancel());
    _sub = ch.messages.listen(_onMessage);
  }

  void _onMessage(DecodedMessage m) {
    if (m.event != 'state') return;
    _state = VoiceLockState.fromJson(m.json ?? const <String, dynamic>{});
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    // A recording in flight ends here; its own `finally` is what gives the
    // microphone back, so this must not try to do it too.
    _abortRecording?.call();
    if (_open) _connection.closeChannel(topic);
    unawaited(_sub?.cancel());
    super.dispose();
  }
}
