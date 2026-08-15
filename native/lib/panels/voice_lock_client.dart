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

  PhoenixChannel? _channel;
  StreamSubscription<DecodedMessage>? _sub;
  VoiceLockState? _state;
  bool _open = false;
  bool _disposed = false;

  int? _recordingSlot;
  (int, String)? _enrollError;

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
  /// death mid-record, and an acquireMic() that throws. A path that skips it
  /// leaves the assistant deaf with no visible cause. Do not add a second
  /// release site to shave the reply latency — two sites is how one gets
  /// missed.
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

    PhoenixChannel? ch;
    try {
      ch = _connection.openChannel(enrollTopic, onChannel: (c) => ch = c);
      if (ch == null) {
        // openChannel returns null when there is no socket up.
        _enrollError = (slot, 'failed: not_connected');
        return;
      }
      final enroll = ch!;

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
        stream = await acquireMic();
      } catch (_) {
        // Matches the web hook's own reason string for a refused mic
        // (assets/js/voice/enroll.js:37).
        _enrollError = (slot, 'failed: mic_blocked');
        return;
      }
      micSub = stream.listen((chunk) {
        if (enroll.isJoined) enroll.pushBinary('audio', chunk);
      });

      capTimer = Timer(clipLimit, () {
        // Stop feeding BEFORE closing the clip, so nothing lands after it.
        unawaited(micSub?.cancel());
        micSub = null;
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
          _enrollError = (slot, 'failed: $rejectReason');
        case _Ending.aborted:
          // Discard the partial clip: without this, the next clip on this
          // topic would be prefixed with the stale audio.
          if (enroll.isJoined) enroll.push('clip_reset', const {});
      }
    } finally {
      capTimer?.cancel();
      replyTimer?.cancel();
      await micSub?.cancel();
      // THE one and only release site. Guarded on micAttempted: a bail-out
      // before acquireMic() was ever called (not_connected) took nothing, so
      // there is nothing to give back.
      if (micAttempted) await releaseMic();
      await chSub?.cancel();
      _connection.closeChannel(enrollTopic);
      _abortRecording = null;
      _recordingSlot = null;
      _notify();
    }
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
