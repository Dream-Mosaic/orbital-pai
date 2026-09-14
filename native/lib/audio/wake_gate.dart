import 'dart:collection';
import 'dart:typed_data';

/// Result of offering one audio chunk to a [WakeGate].
class GateDecision {
  const GateDecision({required this.send, this.preRoll = const <Uint8List>[]});

  /// Whether this chunk should go to the socket.
  final bool send;

  /// Buffered chunks to flush ahead of the current one, in the order they
  /// arrived. Non-empty only on the offer that just opened the gate via a
  /// wake detection.
  final List<Uint8List> preRoll;
}

/// Pure decision layer for wake-word gating.
///
/// Decides, per audio chunk, whether it should stream to the server. No
/// sherpa, no sockets, no microphone, no timers — this is testable in
/// milliseconds and carries the entire policy for when audio leaves the
/// device.
///
/// The keyword spotter fires partway through the wake word itself, so by the
/// time the gate opens the word (and often the next syllables) are already
/// in the past. [WakeGate] keeps a ring buffer of the recent audio so it can
/// flush that history to the server ahead of live audio the moment a wake
/// is detected — otherwise the server would receive a sentence with its
/// opening amputated.
class WakeGate {
  WakeGate({
    Duration preRoll = const Duration(milliseconds: 1500),
    int sampleRate = 16000,
    int bytesPerSample = 2,
  }) : _maxPreRollBytes =
            sampleRate * bytesPerSample * preRoll.inMilliseconds ~/ 1000;

  final int _maxPreRollBytes;

  bool _locked = false;
  bool _pttMode = false;
  bool _ptt = false;
  bool _wakeOpen = false;
  bool _flushPending = false;

  /// Whether the server says THIS device owns the conversation. Defaults
  /// true so a client never told about binding (an old server, or a client
  /// that hasn't heard from the new one yet) behaves exactly as before this
  /// feature existed.
  bool _bound = true;

  final Queue<Uint8List> _ring = Queue<Uint8List>();
  int _ringBytes = 0;

  /// Whether audio currently passes through.
  ///
  /// `_bound` gates ahead of everything else, deliberately including PTT: a
  /// standby device's PTT press is a *claim* on the conversation, not proof
  /// it already holds it. The gate only opens once the server answers that
  /// claim with `bound: true` — overriding it here would let a second
  /// device's audio race the first device's live turn onto the wire.
  ///
  /// **In push-to-talk MODE, only the held button opens the gate.** Neither
  /// an unlocked conversation nor a wake detection does, because the whole
  /// contract of PTT is that nothing leaves the device unless the user is
  /// holding the button. Before this distinction existed the gate knew only
  /// whether PTT was *held*, so `!_locked` alone held it open — and a PTT
  /// session streamed continuously to Ink-2 (3 credits/second) from the
  /// moment a wake unlocked the conversation until it relocked, while the
  /// server correctly refused to endpoint any of it. Audio nobody asked for,
  /// billed, and discarded.
  bool get open {
    if (!_bound) return false;
    if (_pttMode) return _ptt;
    return !_locked || _ptt || _wakeOpen;
  }

  /// Mirrors the server's lock state. A relock (`locked == true`) must close
  /// a gate a prior wake detection opened, and drops any buffered pre-roll —
  /// it is now stale relative to whatever wakes the gate next. Unlocking
  /// also clears `_wakeOpen`: there is nothing left to hold open once the
  /// conversation is unlocked on its own.
  void onLocked(bool locked) {
    _locked = locked;
    _wakeOpen = false;
    if (locked) {
      _ring.clear();
      _ringBytes = 0;
      _flushPending = false;
    }
  }

  /// Mirrors push-to-talk state; held-down PTT opens the gate regardless of
  /// lock state.
  void onPttHeld(bool held) {
    _ptt = held;
  }

  /// Mirrors whether push-to-talk MODE is switched on — distinct from
  /// [onPttHeld], which is whether the button is down right now.
  ///
  /// Leaving PTT mode drops any stale held flag: the button cannot still be
  /// down in a mode that no longer has one, and a stuck `_ptt` would hold the
  /// gate open for the whole of the next hands-free session.
  void onPttMode(bool enabled) {
    _pttMode = enabled;
    if (!enabled) _ptt = false;
  }

  /// Mirrors the server's `bound` fact: whether THIS device currently owns
  /// the conversation. A standby device (`bound == false`) must not stream
  /// even while unlocked or mid-PTT-press — see [open]'s doc for why PTT
  /// does not override this.
  ///
  /// A false→true transition arms the same one-time pre-roll flush a wake
  /// detection does: a standby PTT press is a claim on the conversation, and
  /// speech spoken between that press and the server's `bound: true` answer
  /// was buffered into the ring while the gate sat closed — without this it
  /// would sit there until silently trimmed, clipping the front of the very
  /// utterance that claimed the conversation. Deliberately gated on the
  /// transition, not on every `bound: true`: the cold-start path (two `state`
  /// pushes, both `bound: true`) and any other redundant re-affirmation must
  /// not re-flush an already-drained (and by then stale) ring.
  void onBound(bool bound) {
    if (bound && !_bound) _flushPending = true;
    _bound = bound;
  }

  /// The on-device keyword spotter fired. Opens the gate and arms a
  /// one-time flush of the pre-roll ring on the next [offer].
  void onWakeDetected() {
    _wakeOpen = true;
    _flushPending = true;
  }

  /// Offer one chunk of PCM audio to the gate.
  ///
  /// While closed, the chunk is appended to the pre-roll ring and the ring
  /// is trimmed from the front (oldest first) until it holds no more than
  /// `preRoll` worth of audio. While open, the first offer after a wake
  /// detection drains the ring into the returned decision (oldest first,
  /// ahead of this chunk) and clears the pending flush so it fires exactly
  /// once; every other open offer just passes the chunk through.
  GateDecision offer(Uint8List pcm) {
    if (!open) {
      _ring.addLast(pcm);
      _ringBytes += pcm.length;
      while (_ringBytes > _maxPreRollBytes && _ring.isNotEmpty) {
        _ringBytes -= _ring.removeFirst().length;
      }
      return const GateDecision(send: false);
    }

    if (_flushPending) {
      final preRoll = List<Uint8List>.unmodifiable(_ring);
      _ring.clear();
      _ringBytes = 0;
      _flushPending = false;
      return GateDecision(send: true, preRoll: preRoll);
    }

    return const GateDecision(send: true);
  }
}
