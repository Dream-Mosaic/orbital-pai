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
    _connection.closeChannel(topic);
    unawaited(_sub?.cancel());
    _sub = null;
    _channel = null;
    _state = null;
    _enrollError = null;
    _notify();
  }

  void setMode(String mode) => _push('set_mode', {'mode': mode});

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
    if (_open) _connection.closeChannel(topic);
    unawaited(_sub?.cancel());
    super.dispose();
  }
}
