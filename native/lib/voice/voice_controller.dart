import 'dart:async';
import 'package:flutter/foundation.dart';
import '../audio/audio_track_player.dart';
import '../audio/keyword_spotter.dart';
import '../audio/mic_capture.dart';
import '../audio/playback_levels.dart';
import '../audio/wake_gate.dart';
import '../auth/device_id.dart';
import '../connection/app_connection.dart';
import '../meridian/audio_levels.dart';
import '../meridian/orb_painter.dart';
import '../meridian/orb_state.dart';
import '../meridian/thread_model.dart';
import 'mic_state.dart';
import '../phoenix/decoded_message.dart';
import '../phoenix/phoenix_channel.dart';

/// The conversation. It no longer owns a socket: [AppConnection] does, and this
/// is a CONSUMER of one topic on it. What stays here is conversation policy —
/// the turn router, the orb, the thread, PTT/ABI, and the mic re-arm, which is
/// about what the user asked the microphone to do rather than about transport.
class VoiceController extends ChangeNotifier {
  VoiceController({
    required AppConnection connection,
    MicCapture? mic,
    AudioTrackPlayer? player,
    WakeSpotter? spotter,
    WakeGate? gate,
    DeviceId? deviceId,
  })  : _connection = connection,
        _mic = mic ?? MicCapture(),
        _player = player ?? AudioTrackPlayer(),
        _spotter = spotter ?? SherpaWakeSpotter(),
        _gate = gate ?? WakeGate(),
        _deviceId = deviceId ?? DeviceId() {
    // The other half of the mic-restore contract: a deliberate teardown that
    // happens while the mic is ALREADY down (i.e. mid-outage, so there is no
    // second channel death to notice it) must still disarm the flag.
    _connection.addListener(_onConnectionChanged);
    // Register the topic SYNCHRONOUSLY, in the constructor, exactly as
    // before device ids existed — see _enrichJoinWithDeviceId's doc for why
    // the device id itself is layered on separately, afterward, rather than
    // gating this registration at all.
    //
    // Delivery is at channel CREATION, not at join, and that is
    // load-bearing: the server pushes `state` and `history` immediately
    // behind its join reply, so a listener attached on a "joined" signal
    // misses both on every single connect. `essential: true` because a
    // refused `voice:henry` means a dead token — there is nothing to stay
    // connected for. Being registered HERE, synchronously, is equally
    // load-bearing: `AppConnection.connect()` only waits for (and escalates
    // on) essential topics that are already in its registry the moment its
    // join sweep runs, which happens synchronously inside the SAME
    // constructor call for every production caller (`main.dart`'s
    // `_buildShell` calls `connect()` right after building this
    // controller) — an async registration would miss that sweep every
    // time, silently downgrading `voice:henry` from "gates the connection"
    // to "joins whenever it gets around to it," with no escalation if it
    // never does.
    _connection.openChannel(
      _topic,
      joinPayload: const {'kiosk': false},
      essential: true,
      onChannel: _adoptChannel,
    );
    // Stored, not fire-and-forgotten: see [deviceIdReady]'s doc. A caller
    // about to call `AppConnection.connect()` (main.dart's `_buildShell`)
    // can await this FIRST, bounded, to make the very first join
    // deterministically carry the device id rather than relying on which of
    // two independent async chains (this one, and connect()'s own socket
    // handshake) happens to resolve first.
    _deviceIdReady = _enrichJoinWithDeviceId();
  }

  static const String _topic = 'voice:henry';

  /// Resolved once and injected, never read directly elsewhere: everything
  /// this controller knows about "which device am I" lives in the join
  /// payload it sends and the `bound` state the server answers with.
  final DeviceId _deviceId;

  /// Resolves once [_enrichJoinWithDeviceId] has applied (or given up
  /// waiting for) the device id. NOT awaited by anything in this class —
  /// the join itself never depends on it, by design (see
  /// [_enrichJoinWithDeviceId]'s doc). Exposed so a caller that is ABOUT TO
  /// call `AppConnection.connect()` can choose to wait for it first,
  /// bounded, to make the very first join of a fresh connection
  /// deterministically carry the device id whenever the store answers in
  /// time — see `main.dart`'s `_connectOnceDeviceIdKnown`, the one
  /// production caller. Without a caller racing it against `connect()`
  /// like that, whether the FIRST join carries the device id is a coin
  /// flip between two independent async chains (this one, and connect()'s
  /// own socket handshake) — fine for the join itself (a legacy join is
  /// always valid), but not for the specific promise this feature makes: a
  /// second device that cold-launches while the first is mid-conversation
  /// must not silently steal it by winning that race with a nil id.
  Future<void> get deviceIdReady => _deviceIdReady;
  late final Future<void> _deviceIdReady;

  /// Widen `voice:henry`'s registered join payload with the device id, once
  /// (if ever) `DeviceId.get()` resolves — for every join FROM HERE ON.
  /// `openChannel`'s payload update only takes effect on the NEXT join
  /// (`AppConnection`'s own widen-never-narrow contract), so a join already
  /// in flight when this resolves is unaffected; every join after that —
  /// the one a caller deliberately delayed via [deviceIdReady], or simply a
  /// later reconnect — carries it.
  ///
  /// Deliberately off the join's critical path, and deliberately with NO
  /// timeout OF ITS OWN: an EARLIER version of this fix bounded
  /// `DeviceId.get()`'s await right here with a `Timer` and fell back to a
  /// legacy join on expiry — sound in isolation, but empirically wrong for
  /// two reasons found while verifying it. First, the constructor was the
  /// ONLY call site for `openChannel('voice:henry', …)`; deferring
  /// registration itself behind ANY await — bounded or not — means it can
  /// no longer be part of `AppConnection.connect()`'s SYNCHRONOUS
  /// essential-join sweep (see the constructor's doc), which broke three
  /// `voice_controller_reconnect_test.dart` cases that pin `connect()`
  /// correctly reporting `connecting`/`error` while `voice:henry`'s join
  /// hangs or is refused — a real production regression, not just a test
  /// artifact: a dead-token refusal would have gone unescalated. Second,
  /// that bounding `Timer` fired unconditionally on every construction
  /// rather than only when something explicit (like `startMic`) exercises
  /// it, which broke EVERY `testWidgets` test building a bare
  /// `VoiceController` (`voice_screen_test.dart`, 10 cases):
  /// `flutter_test` asserts no `Timer` is left pending once a test's widget
  /// tree is disposed, and disposal there runs through `addTearDown` —
  /// which, confirmed by reading `flutter_test`'s `_runTestBody`, executes
  /// AFTER the invariant check, not before, so cancelling the `Timer` in
  /// `dispose()` cannot save it. Registering the join unconditionally,
  /// synchronously, and leaving THIS METHOD free to complete (or never
  /// complete) as a pure side task fixes both: nothing HERE depends on it
  /// finishing, so there is nothing to bound inside this method itself —
  /// the bound belongs to whoever chooses to race it against `connect()`
  /// (see [deviceIdReady]), where a `.timeout()`'s `Timer` is safe because
  /// it is scoped to that ONE await, not to every construction.
  Future<void> _enrichJoinWithDeviceId() async {
    final id = await _deviceId.get();
    if (_disposed) return;
    _connection.openChannel(
      _topic,
      joinPayload: {'kiosk': false, 'device_id': id},
      essential: true,
      onChannel: _adoptChannel,
    );
  }

  final AppConnection _connection;
  PhoenixChannel? _channel;
  StreamSubscription<DecodedMessage>? _msgSub;

  /// The channel only when the server has actually let us in.
  ///
  /// We now adopt at channel CREATION (so nothing pushed behind the join reply
  /// is lost), which means holding a handle no longer implies a live topic.
  /// Everything that PUSHES must go through this, or a toggle / mic frame
  /// would be written into a channel Phoenix has not joined yet — and, on a
  /// refused join, into one it never will.
  PhoenixChannel? get _live {
    final ch = _channel;
    return (ch != null && ch.isJoined) ? ch : null;
  }

  /// EVERYTHING this controller knows about the microphone, in ONE immutable
  /// value. See [MicState] for why: six Criticals of one class were all "a
  /// state flag written on the far side of a platform await", and eight
  /// separate fields made "the transition" a convention about the order you
  /// assigned them in.
  ///
  /// **Invariant A, and the rule this file is held to:** every write to this
  /// field is a single synchronous whole-value assignment, and it happens
  /// ENTIRELY BEFORE or ENTIRELY AFTER a platform call — never straddling one
  /// and never conditional on one returning. There is no half-applied
  /// transition for an `await` to land inside, and nothing left over to
  /// forget: `micOn` is derived from the handles rather than tracked beside
  /// them, so dropping the subscription IS switching the microphone off.
  ///
  /// Supersession is read off the value too. A stale continuation asks
  /// "is the session I am holding still the one this state names?" —
  /// `identical(_micState.session, mine)` — rather than comparing a counter
  /// it has to remember to bump. The handle IS the generation token.
  MicState _micState = MicState.idle;

  /// Backoff for a mic the PLATFORM ended without being asked (an alarm or
  /// any app taking audio focus, revoked permission, another app seizing the
  /// recorder) — see [_onMicStreamEnded]. Visible for tests, and for Task 5's
  /// restart behaviour to build on. Three tries, then give up and log: a
  /// permanently unavailable microphone must not become a hot loop hammering
  /// the platform forever.
  static const List<Duration> micRestartBackoff = [
    Duration(milliseconds: 400),
    Duration(seconds: 2),
    Duration(seconds: 8),
  ];

  Timer? _micRestartTimer;

  /// Index into [micRestartBackoff] for the NEXT attempt. Reset to 0 by any
  /// successful [startMic] — including a manual one — so a mic that recovers
  /// on its own, or that the user restarts by hand, does not inherit a stale
  /// backoff position from an earlier outage.
  int _micRestartAttempt = 0;

  // Mirrors index.js's `this.pttHeld`: read by the `state` snapshot merge and
  // written by pttPress/pttRelease.
  bool _pttHeld = false;

  String _caption = '';
  bool _captionPending = false;
  final List<String> _transcript = [];
  final List<String> _eventLog = [];

  // Injected (defaulted to the real implementations in the constructor) so the
  // mic/player teardown paths are testable headless — a real MicCapture or
  // AudioTrackPlayer needs a device.
  final MicCapture _mic;

  bool _disposed = false;

  final AudioTrackPlayer _player;
  bool _playerReady = false;

  /// On-device wake-word spotter and the pure gate that decides, per PCM
  /// chunk, whether it may leave the device. Both are injected (defaulted to
  /// the real implementations) so gating is testable headless — see the
  /// mic `listen` callback in [startMic] for where they meet the audio.
  final WakeSpotter _spotter;
  final WakeGate _gate;

  /// Bound on [startMic]'s `await _spotter.start()`. The spotter's own
  /// fail-open (a `throw` inside `start()`) is unconditional and needs no
  /// timeout; this is the OTHER failure shape — a wedged loader that never
  /// resolves either way — which would otherwise park `startMic` (and every
  /// later call, and the auto-restart backoff riding on it) forever.
  static const Duration _wakeSpotterStartTimeout = Duration(seconds: 5);

  // ---- Meridian chrome state ----
  /// index.js reads this from a data attribute; the native client has no such
  /// channel, and the server-side default is "Henry".
  static const String assistantName = 'Henry';

  final List<ThreadItem> _thread = <ThreadItem>[];

  // Turn-scoped handles, all reset on `listening`/`state` exactly as index.js
  // resets brainEl / metricsEl / toolChips / thinkingEl.
  int? _brainIndex;
  // The line `_brainIndex` points at holds the turn's FINAL answer (a speak_start landed on
  // it), so nothing more may be appended to it and no second brain line may be opened for
  // this turn. Cleared with `_brainIndex`, on exactly the same events.
  bool _brainFinalized = false;
  int? _metricsIndex;
  int? _thinkingIndex;
  final List<int> _toolChipIndexes = <int>[];
  bool _historyBackfilled = false;

  bool _pttEnabled = false;
  bool _abiEnabled = false;

  /// Whether the PTT/ABI question is closed for this session — either the
  /// stored defaults have been applied, or the user has made their own choice,
  /// whichever came first. Once true, no `state` snapshot may re-apply a
  /// default over it. See [_applyStoredDefaults].
  bool _prefsSettled = false;

  // ---- Meridian orb state ----
  bool _talking = false;
  bool _wakeLocked = false;

  /// Whether the server says THIS device currently owns the conversation.
  /// Defaults true — see [WakeGate]'s `_bound` doc — so a client that has
  /// never heard a `bound` push (an old server, or one not yet received)
  /// behaves exactly as it did before this feature existed.
  bool _bound = true;
  TurnState _turnState = TurnState.idle;
  final OrbFrame orbFrame = OrbFrame();
  final PlaybackLevels _levels = PlaybackLevels();

  String get caption => _caption;

  /// Whether [caption] is a live partial transcript that Ink-2 is still
  /// extending — i.e. whether the trailing ellipsis belongs on it.
  ///
  /// Keyed on the caption's PROVENANCE, not on a turn phase: the only thing
  /// that sets it true is a `partial` message carrying text. Every other
  /// writer of the caption — the resting wake prompt, the clear on
  /// `transcript`, the end-of-turn reset — sets it false. A phase test would
  /// have been wrong in the one case that matters, since a wake-locked device
  /// sits in `listening` for hours showing a prompt that is not pending
  /// anything.
  bool get captionPending => _captionPending;

  /// Single writer for the pair, so the flag cannot drift from the text it
  /// describes. Empty text is never pending — there is nothing to be the tail
  /// of.
  void _setCaption(String text, {bool pending = false}) {
    _caption = text;
    _captionPending = pending && text.isNotEmpty;
  }

  List<String> get transcript => List.unmodifiable(_transcript);
  List<String> get eventLog => List.unmodifiable(_eventLog);
  /// Derived, never stored: the microphone is on iff the conversation is
  /// subscribed to a session it holds. See [MicState.on].
  bool get micOn => _micState.on;
  bool get pttHeld => _pttHeld;

  List<ThreadItem> get thread => List.unmodifiable(_thread);
  bool get pttEnabled => _pttEnabled;
  bool get abiEnabled => _abiEnabled;

  bool get talking => _talking;
  bool get wakeLocked => _wakeLocked;
  TurnState get turnState => _turnState;
  OrbState get orbState => resolveOrbState(
        talking: _talking,
        wakeLocked: _wakeLocked,
        turnState: _turnState,
      );

  void _log(String line) {
    _eventLog.add(line);
    if (_eventLog.length > 200) _eventLog.removeAt(0);
  }

  /// Notify listeners unless we've already been disposed. Guards against
  /// async tails (e.g. stopMic's awaited cancel/stop) resolving after
  /// dispose() has run, which would otherwise throw in debug/test builds.
  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  void _syncOrb() {
    // Guard against the same class of post-dispose async tail as _safeNotify:
    // dispose() fires stopMic() without awaiting it, so its awaited
    // cancel/stop can resolve after orbFrame.dispose() has already run.
    if (_disposed) return;
    orbFrame.state = orbState;
    _syncLevelPoll();
    _safeNotify();
  }

  /// The single place `_wakeLocked` is assigned. Reached from BOTH paths the
  /// server uses to tell us it locked — the `locked` event and the `state`
  /// reconnect snapshot — so the gate can never see one without the other.
  ///
  /// Always feeds `_gate.onLocked`, UNCONDITIONALLY on spotter availability.
  /// A `state` snapshot lands on every (re)bind — milliseconds after join,
  /// before the mic is ever asked to start and long before the on-device
  /// model finishes loading — so a guard here that skipped the call while
  /// `!_spotter.available` would drop that lock on the floor with nothing to
  /// ever replay it: the next `locked` push only arrives on a server
  /// *transition*, which does not happen until a turn is heard, which is
  /// exactly the paid streaming this whole feature exists to avoid. The gate
  /// itself is inert bookkeeping (no sockets, no timers) so recording a lock
  /// it cannot yet act on costs nothing.
  ///
  /// **Fail open** therefore lives entirely in the SEND path (the mic
  /// listener in [startMic]), not here: while `!_spotter.available` every
  /// chunk streams regardless of what the gate thinks, and the instant the
  /// spotter finishes loading the gate already holds the correct lock state
  /// — recorded here, whenever it actually arrived — so there is no separate
  /// resync to forget and no ordering between "the lock arrived" and "the
  /// model finished loading" that can desync it.
  void _applyWakeLocked(bool locked) {
    _wakeLocked = locked;
    _gate.onLocked(locked);
  }

  /// The single place the "am I the bound device" fact is applied, reached
  /// from BOTH the `bound` event and the `state` reconnect snapshot — same
  /// shape as [_applyWakeLocked] and for the same reason: the snapshot is
  /// the reconnect path, so a gate wired only to the event desyncs on every
  /// reconnect. `locked` and `bound` are deliberately separate facts ("the
  /// conversation is locked" vs. "I am not the owner") and are never folded
  /// into each other here.
  ///
  /// A false→true transition re-announces this device's toggles
  /// (`_announceToggles`, same call `_onJoined` makes on every fresh join).
  /// The server drops control casts from a client that isn't bound
  /// (`conversation.ex`), so a standby device's `ptt`/`allow_interruptions`
  /// pushed at join time was silently discarded — without this, claiming
  /// the conversation (by wake or by PTT) leaves the server still running
  /// whatever mode it was already in, e.g. auto-endpointing while this
  /// device believes PTT is on, so `ptt_release`'s `finalize` is a no-op.
  /// Gated on the TRANSITION, not on every `bound: true`, for the same
  /// reason [WakeGate.onBound] is: the cold-start path emits two `state`
  /// pushes, both `bound: true`, and only the real transition should
  /// re-announce.
  void _applyBound(bool bound) {
    final wasBound = _bound;
    _bound = bound;
    _gate.onBound(bound);
    if (bound && !wasBound) _announceToggles();
  }

  /// Map a server turn-state event onto the orb, ported from index.js.
  void _applyTurnEvent(String event) {
    switch (event) {
      case 'speak_start':
      case 'speaking':
        _turnState = TurnState.speaking;
      case 'listening':
        // The server pushes `listening` on every transition back INTO its
        // listening phase — i.e. after each turn completes. Hands-free, that is
        // exactly right: the mic really is hot again.
        //
        // In PTT mode it is not. The phase means "ready for input"; the mic is
        // only live while the button is held. Taking it at face value turned
        // the orb amber after the first turn of a PTT session and left it
        // there, telling the user they were being heard when nothing was
        // leaving the device.
        _turnState = _pttEnabled && !_pttHeld
            ? TurnState.idle
            : TurnState.listening;
      case 'thinking':
        _turnState = TurnState.thinking;
      default:
        return;
    }
    _syncOrb();
  }

  // Test seams (no platform channels involved).
  @visibleForTesting
  void debugSetTalking(bool v) {
    _talking = v;
    if (!v) _turnState = TurnState.idle;
    _syncOrb();
  }

  @visibleForTesting
  void debugSetWakeLocked(bool v) {
    _wakeLocked = v;
    _syncOrb();
  }

  @visibleForTesting
  void debugApplyEvent(String event) => _applyTurnEvent(event);

  // ---- thread construction (the port of index.js's addLine/appendBrainDelta/
  // showThinking/addToolChip/resolveToolChips/renderMetrics/offerAck) ----

  void _addLine(String source, String text) {
    final kind = lineKindFromSource(source);
    if (kind == null) {
      _log('unknown speak_start source: $source');
      return;
    }
    final label =
        (kind == LineKind.brain || kind == LineKind.reflex) ? assistantName : source;
    _thread.add(ThreadLine(
      kind: kind,
      label: label,
      text: text,
      markdown: kind != LineKind.you,
    ));
  }

  void _showThinking() {
    if (_thinkingIndex != null) return;
    _thread.add(const ThreadLine(
      kind: LineKind.brain,
      label: assistantName,
      text: '$assistantName: thinking…',
      thinking: true,
    ));
    _thinkingIndex = _thread.length - 1;
  }

  void _clearThinking() {
    final i = _thinkingIndex;
    _thinkingIndex = null;
    if (i == null || i >= _thread.length) return;
    _thread.removeAt(i);
    _shiftHandlesAfter(i);
  }

  void _resolveToolChips() {
    for (final i in _toolChipIndexes) {
      if (i < _thread.length && _thread[i] is ThreadToolChip) {
        _thread[i] = (_thread[i] as ThreadToolChip).resolve();
      }
    }
    _toolChipIndexes.clear();
  }

  /// A turn barged mid-tool-call: drop the chips that never resolved. Resolved ✓
  /// chips are already out of the list and stay in the log as the turn's story.
  void _dropUnresolvedToolChips() {
    final doomed = _toolChipIndexes.toList()..sort((a, b) => b.compareTo(a));
    for (final i in doomed) {
      if (i < _thread.length && _thread[i] is ThreadToolChip) {
        _thread.removeAt(i);
        _shiftHandlesAfter(i);
      }
    }
    _toolChipIndexes.clear();
  }

  void _shiftHandlesAfter(int removed) {
    if (_brainIndex != null && _brainIndex! > removed) _brainIndex = _brainIndex! - 1;
    if (_metricsIndex != null && _metricsIndex! > removed) {
      _metricsIndex = _metricsIndex! - 1;
    }
    if (_thinkingIndex != null && _thinkingIndex! > removed) {
      _thinkingIndex = _thinkingIndex! - 1;
    }
    for (var i = 0; i < _toolChipIndexes.length; i++) {
      if (_toolChipIndexes[i] > removed) _toolChipIndexes[i] -= 1;
    }
  }

  void _endTurn() {
    _clearThinking();
    _dropUnresolvedToolChips();
    _brainIndex = null;
    _brainFinalized = false;
    _metricsIndex = null;
    // A `partial` that never reached `transcript` — a barge-in, an endpoint the
    // server resolved another way — would otherwise leave your half-finished
    // words on screen for the whole of the next turn. Harmless until the orb's
    // line got taller: the caption box and the line now overlap geometrically
    // during `thinking`, so stale text sits UNDER the wave.
    _setCaption(_restingCaption);
  }

  /// What the caption reads when nobody is mid-utterance: the wake prompt on a
  /// locked device, nothing otherwise. Locked is not a turn state — clearing it
  /// at end of turn would strand a locked device with no way to know the words
  /// that unlock it.
  String get _restingCaption =>
      _wakeLocked ? 'Say \u201CWake up $assistantName\u201D' : '';

  /// Drop the local transcript. NOTE: the web's trash button fires the LiveView's
  /// `clear_conversation` handler, which also clears server-side memory — the
  /// voice CHANNEL has no equivalent handle_in, and A2 makes no server changes
  /// beyond the panel route. So this is local-only; clearing memory stays a panel
  /// action.
  void clearThread() {
    _thread.clear();
    _brainIndex = null;
    _brainFinalized = false;
    _metricsIndex = null;
    _thinkingIndex = null;
    _toolChipIndexes.clear();
    _safeNotify();
  }

  /// The inline Ack chip. The push rides `voice:henry` -- the one topic this
  /// client always holds -- because `panel:reminders` is joined only while
  /// that drawer is open. Before this push existed the chip flipped local
  /// state only: the reminder stayed due on the server, the badge stayed lit,
  /// and the nudge re-asked on the next connect (issue #4). The local flip is
  /// optimistic; the server's `not_found` reply (already acked elsewhere) is
  /// harmless, since the chip would read "acked" either way.
  void ackReminder(int id) {
    _live?.push('ack_reminder', {'id': id});
    for (var i = _thread.length - 1; i >= 0; i--) {
      final item = _thread[i];
      if (item is ThreadLine && item.ackId == id) {
        _thread[i] = item.copyWith(ack: AckState.acked);
        break;
      }
    }
    _safeNotify();
  }

  // ---- controls ----

  /// The native twin of index.js's startTalking()/stopTalking().
  ///
  /// While the recorder is LENT OUT the conversation holds nothing, so `on`
  /// and `wanted` both read false and comparing them made every tap mean ON —
  /// two taps left the microphone on, and [stopMic]'s "a deliberate stop
  /// during a loan cancels the restore", pinned since Task 2, was unreachable
  /// from the UI. The restore intent is the only thing there is to toggle in
  /// that window, so it is what the button toggles.
  Future<void> togglePower() async {
    final on = _micState.loaned
        ? _micState.resumeWanted
        : _micState.on || _micState.wanted;
    if (on) {
      await stopMic();
    } else {
      _setCaption('');
      await startMic();
    }
  }

  /// The user flipped the PTT switch. Their choice settles the question for
  /// this session — a later `state` snapshot must not undo it.
  void setPtt(bool enabled) {
    _prefsSettled = true;
    _applyPtt(enabled, startMicIfOff: true);
  }

  /// The one path into PTT mode, user-driven or default-driven.
  ///
  /// PTT is NOT a flag: the `ptt` push is what makes the server tear the
  /// Cartesia Ink-2 socket down and bring it back up on the manual-finalize
  /// endpoint (`set_ptt` -> `restart_stt`). Setting `_pttEnabled` without it
  /// leaves the socket auto-endpointing and nothing says so until someone
  /// tries to talk.
  ///
  /// [startMicIfOff] is the ONE thing a stored default does differently, and
  /// index.js:179 made the same call for the same reason: applying a default
  /// at launch must not throw a microphone-permission prompt at someone who
  /// has not touched anything yet. The user powers on with the power button,
  /// which already respects PTT mode.
  void _applyPtt(bool enabled, {required bool startMicIfOff}) {
    _pttEnabled = enabled;
    // The gate has to know about the MODE, not only about the button: in PTT
    // mode an unlocked conversation must not hold it open on its own.
    _gate.onPttMode(enabled);
    // Switching modes mid-hold leaves `_pttHeld` set with no button under it,
    // and the server is told `holding: false` by its own set_ptt handler — so
    // clear ours to match rather than let the two disagree.
    if (!enabled) _pttHeld = false;
    _live?.push('ptt', {'enabled': enabled});
    _safeNotify();
    // index.js:396 — enabling PTT mode while powered off starts the mic.
    if (startMicIfOff && enabled && !_micState.on && !_micState.wanted) {
      unawaited(startMic());
    }
  }

  void pttPress() {
    if (!_pttEnabled || _pttHeld) return;
    _pttHeld = true;
    _turnState = TurnState.listening; // amber while held (ambient if wake-locked)
    _gate.onPttHeld(true);
    _live?.push('ptt_press', const {});
    _syncOrb();
  }

  void pttRelease() {
    if (!_pttHeld) return;
    _pttHeld = false;
    _turnState = TurnState.idle;
    _gate.onPttHeld(false);
    _live?.push('ptt_release', const {});
    _syncOrb();
  }

  /// The user flipped the allow-barge-in switch; same settling rule as [setPtt].
  void setAllowInterruptions(bool enabled) {
    _prefsSettled = true;
    _applyAllowInterruptions(enabled);
  }

  void _applyAllowInterruptions(bool enabled) {
    _abiEnabled = enabled;
    _live?.push('allow_interruptions', {'enabled': enabled});
    _safeNotify();
  }

  /// Apply the user's STORED voice defaults, which ride the `state` snapshot.
  ///
  /// Once, and never over a choice the user has already made. The snapshot is
  /// re-sent on every (re)bind — a wifi blip, a redeploy, another device
  /// claiming and handing back — so an unguarded apply would silently undo a
  /// mid-session PTT toggle every time the socket came back. This is the same
  /// hazard the snapshot's absent-key rule guards against, one level up: there
  /// the server's silence must not clobber the client, here the server's
  /// *defaults* must not clobber the user.
  void _applyStoredDefaults(Map<String, dynamic> p) {
    if (_prefsSettled) return;
    final abi = p['default_abi'] as bool?;
    final ptt = p['default_ptt'] as bool?;
    // An old server sends neither. Stay unsettled so the first snapshot from a
    // server that DOES carry them still lands.
    if (abi == null && ptt == null) return;
    _prefsSettled = true;
    if (abi != null && abi != _abiEnabled) _applyAllowInterruptions(abi);
    // Through the real mode switch — see [_applyPtt] — minus the mic auto-start.
    if (ptt != null && ptt != _pttEnabled) _applyPtt(ptt, startMicIfOff: false);
  }

  // ---- transport seam (the connection owns the socket; we own one topic) ----

  /// Take (or re-take) the voice channel the connection just made for us.
  ///
  /// This runs BEFORE the join is even on the wire, so the only thing it may
  /// do is start listening — everything the server has to be *told*, and
  /// everything the device owes a live session, waits for [_onJoined].
  ///
  /// Safe to call repeatedly, which is what lets the connection re-offer a
  /// channel we already hold: re-adopting is a no-op, so nothing here can
  /// double-announce or double-init.
  void _adoptChannel(PhoenixChannel ch) {
    if (_disposed || identical(ch, _channel)) return;
    _channel = ch;
    _wireChannel(ch);
    unawaited(ch.onJoin.then(
      (_) => _onJoined(ch),
      // A refused join is the connection's problem (it escalates an essential
      // refusal into a reconnect); ours is only to not do the join work.
      onError: (Object _, StackTrace __) {},
    ));
  }

  /// The join landed: do everything a fresh join owes the server and the
  /// device — re-announce our toggles (a rejoin lands on a conversation that
  /// may have been re-pointed at another client meanwhile), bring the output
  /// track up, and restore a mic an outage tore down.
  void _onJoined(PhoenixChannel ch) {
    // A join that resolved after we were superseded (or torn down) must not
    // announce toggles onto a channel nobody is holding.
    if (_disposed || !identical(ch, _channel)) return;
    _announceToggles();
    unawaited(_initPlayer());
    _reArmMic();
  }

  void _wireChannel(PhoenixChannel ch) {
    unawaited(_msgSub?.cancel());
    _msgSub = ch.messages.listen(
      _onMessage,
      onError: (Object e) => _log('channel error: $e'),
      onDone: () => _onChannelDown(ch),
    );
  }

  void _announceToggles() {
    _live?.push('allow_interruptions', {'enabled': _abiEnabled});
    _live?.push('ptt', {'enabled': _pttEnabled});
  }

  /// The channel died under us. The orb must never keep showing a live colour
  /// over a dead channel (A1 final review, "Important 2"): reset the turn state
  /// and stop the mic, which was streaming into nothing. Reconnecting is
  /// AppConnection's job now — this is only the conversation's half.
  void _onChannelDown(PhoenixChannel ch) {
    // A superseded channel's `done` can land after we already adopted its
    // replacement; tearing the mic down for it would deafen a session that is
    // in fact alive.
    if (_disposed || !identical(ch, _channel)) return;
    // Drop the handle as well: pushing into a dead channel is a silent no-op,
    // and startMic()'s `_live == null` guard is what keeps the mic from
    // opening into an outage.
    _channel = null;
    _log('channel down');
    _talking = false;
    _turnState = TurnState.idle;
    final held = _micState;
    if (held.on || held.wanted) {
      // Only a TRANSPORT failure earns a restore. disconnect()/dispose() clear
      // the connection's intent BEFORE they close anything, so this reads false
      // exactly when the user asked to go down — and a mic that went down with
      // a deliberate teardown must stay down, same as an explicit stopMic().
      //
      // ONE synchronous whole-value transition, then the teardown of what it
      // just gave up. Never the other way round.
      _micState = held.captureOff().withWasOn(_connection.wantConnected);
      unawaited(_release(held));
    }
    orbFrame.audioTarget = 0.0;
    _syncOrb();
  }

  /// A deliberate teardown while the mic is already down (mid-outage: the
  /// channel is long dead, so `_onChannelDown` will not fire again) must still
  /// disarm the restore flag, or the next connect switches the microphone back
  /// on by itself.
  void _onConnectionChanged() {
    if (!_connection.wantConnected) _micState = _micState.withWasOn(false);
  }

  /// Give up everything a [MicState] was holding: stop the session, cancel the
  /// subscription.
  ///
  /// THE one place this controller tears a microphone handle down, and it
  /// always runs AFTER the whole-value transition that gave that handle up.
  /// That ordering is Invariant A: nothing this does — or fails to do, or
  /// never finishes doing — can leave the state machine describing a
  /// microphone that is not there, because the state machine already stopped
  /// describing it.
  ///
  /// **Invariant B.** Bounded and non-throwing end to end. [MicSession.stop]
  /// is both by construction, inside [MicCapture], where no caller can forget
  /// it. The subscription's own `cancel()` is the single microphone-shaped
  /// call that does NOT go through MicCapture — it belongs to the plugin's
  /// stream — so it is bounded here, with the same bound the hardware gets,
  /// and its failure is logged rather than allowed to skip the rest.
  Future<void> _release(MicState held) async {
    // The spotter is tied to the mic session's lifetime, not to any one
    // teardown path — this is the one place every path (deliberate stop,
    // dispose, a dead channel, a platform-ended stream, a loan-out) already
    // converges on to give up the session, so it is where the spotter gives
    // up too. startMic() calls `_spotter.start()` again on the next attempt,
    // auto-restart included, so nothing here needs its own re-arm.
    unawaited(_spotter.stop());
    // Issued FIRST and synchronously, before this method's own first await:
    // MicCapture serialises opens behind a stop, so a start requested in the
    // same breath queues correctly behind this one.
    final stopped = held.session?.stop() ?? Future<void>.value();
    final sub = held.sub;
    final cancelled = sub == null
        ? Future<void>.value()
        : Future<void>.sync(sub.cancel)
            .timeout(_mic.platformTimeout, onTimeout: () {})
            .catchError((Object e) => _log('mic cancel failed: $e'));
    await Future.wait<void>(<Future<void>>[stopped, cancelled]);
  }

  /// Restore a mic that a channel death tore down. [MicState.wasOn] is
  /// deliberately separate from [MicState.wanted]: a user's explicit stopMic()
  /// clears it too, so a mic switched off mid-outage is never resurrected by a
  /// later reconnect.
  void _reArmMic() {
    if (_micState.wasOn) {
      // NOT redundant with `_onConnectionChanged`, however much it looks it —
      // an earlier report called it that, and deleting it on those grounds
      // would put the sixth Critical's symptom back. This is a CONSUME of the
      // flag before startMic(), on the success path of a JOIN, where
      // `wantConnected` is true; `_onConnectionChanged` only clears `wasOn`
      // when `wantConnected` is FALSE, so it never fires here. Without this
      // line the flag survives the restore and the next reconnect switches
      // the microphone back on by itself.
      _micState = _micState.withWasOn(false);
      unawaited(startMic());
    }
  }

  /// Bring up the 24k output track. Best-effort: a device without a working
  /// AudioTrack still has a usable session (mic + captions), so a failure here
  /// is logged and dropped — it must never reach the reconnect machine, which
  /// is why the join listener calls this unawaited.
  ///
  /// **24000 is the SERVER's `tts_sample_rate`** (`server/lib/app/config.ex`),
  /// not a client preference — the socket carries raw PCM16 with no rate in
  /// band, so this number has to be the server's or everything Henry says
  /// plays at the wrong pitch. It is also the unit `PlaybackLevels.retainFrames`
  /// is expressed in (its default is written as `24000 * 300`, i.e. five
  /// minutes), so a server-side rate change silently mis-scales the retention
  /// window as well as the pitch. Change all three together.
  Future<void> _initPlayer() async {
    if (_disposed || _playerReady) return;
    try {
      await _player.init(24000);
    } catch (e) {
      _log('audio track init failed: $e');
      _safeNotify();
      return;
    }
    // A dispose()/disconnect() inside init() leaks an initialised AudioTrack —
    // and neither of them can clean it up, since `_playerReady` was still false.
    if (_disposed || !_connection.wantConnected) {
      unawaited(_player.dispose());
      return;
    }
    _playerReady = true;
    // `_initPlayer` is fired unawaited on join; if the orb already reached
    // `speaking` during this round trip, the last `_syncOrb()` ran while
    // `_playerReady` was still false and never started the timer. Re-sync now
    // so that utterance is not left inert.
    _syncLevelPoll();
    _log('audio track ready (24k)');
    _safeNotify();
  }

  void _onMessage(DecodedMessage m) {
    if (m.isBinary) {
      // audio bytes — handled in Task 6.
      _handleAudio(m.binary!);
      return;
    }
    final p = m.json ?? const {};
    switch (m.event) {
      case 'history':
        final turns = (p['turns'] as List?) ?? const [];
        final replace = (p['replace'] as bool?) ?? false;
        _log('history: ${turns.length} turns${replace ? ' (replace)' : ''}');
        if (replace && turns.isEmpty) {
          // A claim's history/1 can legitimately come back [] — a fresh session, or the
          // accepted persist-race where the last turn hasn't landed in the DB yet. Wiping
          // the claiming device's on-screen conversation over that would be a far worse
          // outcome than leaving it slightly stale, so an empty replace is a no-op: skip it
          // entirely and leave whatever is already on screen alone.
        } else if (replace) {
          // A claim re-syncs the thread: the conversation may have roamed to another
          // device while this one sat in standby, so its on-screen thread can be stale
          // (or, if it already caught up via its own turn events, redundant). Either
          // way, rebuild from the server's copy instead of appending to what's here.
          _thread.clear();
          _brainIndex = null;
          _brainFinalized = false;
          _metricsIndex = null;
          _thinkingIndex = null;
          _toolChipIndexes.clear();
          for (final t in turns) {
            final turn = (t as Map).cast<String, dynamic>();
            final you = turn['you'] as String?;
            final assistant = turn['assistant'] as String?;
            if (you != null) _addLine('you', you);
            if (assistant != null) _addLine('brain', assistant);
          }
          _thread.add(const ThreadDivider());
          // Leave the one-shot guard set so a later plain (unflagged) history push
          // — e.g. a stray rebind — can't re-append on top of this rebuild.
          _historyBackfilled = true;
        } else if (turns.isNotEmpty && !_historyBackfilled && _thread.isEmpty) {
          // One-shot: a plain rebind re-pushes history and must not duplicate lines.
          _historyBackfilled = true;
          for (final t in turns) {
            final turn = (t as Map).cast<String, dynamic>();
            final you = turn['you'] as String?;
            final assistant = turn['assistant'] as String?;
            if (you != null) _addLine('you', you);
            if (assistant != null) _addLine('brain', assistant);
          }
          _thread.add(const ThreadDivider());
        }
      case 'partial':
        _setCaption((p['text'] as String?) ?? '', pending: true);
      case 'transcript':
        _setCaption('');
        final text = (p['text'] as String?) ?? '';
        _transcript.add('you: $text');
        _addLine('you', text);
      case 'speak_start':
        final source = (p['source'] as String?) ?? 'brain';
        final text = (p['text'] as String?) ?? '';
        _transcript.add('$source: $text');
        _applyTurnEvent('speak_start');
        if (source == 'brain') {
          _clearThinking();
          _resolveToolChips();
          final i = _brainIndex;
          if (i != null && i < _thread.length && _thread[i] is ThreadLine) {
            // Snap the streamed plaintext to the full markdown render.
            _thread[i] = (_thread[i] as ThreadLine).copyWith(text: text, markdown: true);
            _brainFinalized = true;
            break;
          }
          // No streamed line to snap: the whole answer arrived at once. Remember WHICH line
          // it landed on and that it is final, rather than forgetting this turn had a brain
          // line at all — `_brainIndex = null` is what let a later delta open a second one.
          _addLine(source, text);
          if (_thread.isNotEmpty && _thread.last is ThreadLine) {
            _brainIndex = _thread.length - 1;
            _brainFinalized = true;
          }
          break;
        }
        _addLine(source, text);
      case 'brain_delta':
        // This turn's answer is already final — the server sent the complete text as a
        // speak_start, so a delta after it can only be a copy of what is on screen.
        // Appending would double the line; the old `_brainIndex == null` fall-through
        // opened a whole second line, which is how the server's duplicate push showed up
        // as two answers in the thread.
        if (_brainFinalized) break;
        final delta = (p['delta'] as String?) ?? '';
        var i = _brainIndex;
        if (i == null) {
          _resolveToolChips();
          _clearThinking();
          _thread.add(const ThreadLine(
            kind: LineKind.brain,
            label: assistantName,
            text: '',
          ));
          i = _thread.length - 1;
          _brainIndex = i;
        }
        final line = _thread[i] as ThreadLine;
        _thread[i] = line.copyWith(text: line.text + delta);
      case 'tool_call':
        _thread.add(ThreadToolChip(name: (p['name'] as String?) ?? 'tool'));
        _toolChipIndexes.add(_thread.length - 1);
      case 'metrics':
        final metrics = ThreadMetrics(
          ttfaMs: (p['ttfa'] as num?)?.round(),
          ttbMs: (p['ttb'] as num?)?.round(),
        );
        final i = _metricsIndex;
        if (i != null && i < _thread.length) {
          _thread[i] = metrics;
        } else {
          _thread.add(metrics);
          _metricsIndex = _thread.length - 1;
        }
      case 'reminder_ack_offer':
        final id = (p['id'] as num?)?.toInt();
        if (id != null) {
          for (var i = _thread.length - 1; i >= 0; i--) {
            final item = _thread[i];
            if (item is ThreadLine &&
                (item.kind == LineKind.reminder || item.kind == LineKind.followup)) {
              _thread[i] = item.copyWith(ack: AckState.offered, ackId: id);
              break;
            }
          }
        }
      case 'stop_playback':
        _handleStopPlayback();
      case 'duck':
        _handleDuck(true);
      case 'unduck':
        _handleDuck(false);
      case 'speaking':
        _log('state: ${m.event}');
        _applyTurnEvent(m.event);
      case 'listening':
        _log('state: ${m.event}');
        _endTurn();
        _applyTurnEvent(m.event);
      case 'thinking':
        _log('state: ${m.event}');
        _showThinking();
        _applyTurnEvent(m.event);
      case 'locked':
        _applyWakeLocked((p['locked'] as bool?) ?? false);
        _setCaption(_restingCaption);
        _log('locked: $_wakeLocked');
        _syncOrb();
      case 'bound':
        // The server's own event, deliberately NOT folded into `locked` \u2014
        // "the conversation is locked" and "I am not the owner" are
        // different facts. `bound` defaults true (see WakeGate), so this
        // only ever narrows a client that has actually been told otherwise.
        _applyBound((p['bound'] as bool?) ?? true);
        _log('bound: $_bound');
      case 'state':
        _log('state snapshot: phase=${p['phase']} locked=${p['locked']} bound=${p['bound']}');
        _clearThinking();
        _brainIndex = null;
        _brainFinalized = false;
        // The reconnect path: after a socket drop the server re-sends its
        // current lock state INSIDE the snapshot rather than as a `locked`
        // event, so this write must drive the gate exactly like the one
        // above \u2014 a gate wired only to the `locked` event desyncs on every
        // reconnect and streams while the server believes it is locked.
        _applyWakeLocked((p['locked'] as bool?) ?? _wakeLocked);
        // Same reconnect-path reasoning as `locked`, for `bound`: the
        // snapshot carries it alongside `phase`/`locked` precisely so a
        // rebind re-syncs it too. An ABSENT key must not clobber whatever
        // this client already knows, exactly like `phase` below \u2014 so this
        // reads from the gate's current state, not a hardcoded default.
        _applyBound((p['bound'] as bool?) ?? _bound);
        // The stored per-user voice defaults ride this snapshot (VoiceChannel
        // merges them in) — it is the one push every client gets on join, and
        // the Settings channel the app used to learn them from is joined only
        // while that drawer is open, so at launch nothing knew them.
        _applyStoredDefaults(p);
        _setCaption(_restingCaption);
        // index.js:268 — a (re)binding client re-derives its turn state from the
        // snapshot's phase, so a reconnect mid-turn can't hold a stale colour.
        // An ABSENT phase must not clobber what we already know.
        final phase = p['phase'] as String?;
        if (_talking && phase != null) {
          _turnState = phase == 'busy'
              ? TurnState.thinking
              : (_pttHeld ? TurnState.listening : TurnState.idle);
        }
        _syncOrb();
      default:
        _log('event: ${m.event} $p');
    }
    _safeNotify();
  }

  /// Test seam: drive the real event router without a socket. Nothing else in the
  /// suite covers the literal event strings, so a typo would ship silently (M-T5d).
  @visibleForTesting
  void debugHandleMessage(DecodedMessage m) => _onMessage(m);

  /// Test seam: whether this controller currently holds a channel. Used to
  /// prove a disposed controller stops being handed new ones.
  @visibleForTesting
  bool get debugHasChannel => _channel != null;

  /// Test seam: whether the microphone is currently on loan.
  @visibleForTesting
  bool get debugMicLoaned => _micState.loaned;

  // ---- audio seams ----
  void _handleAudio(Uint8List pcm) {
    // dispose() closes the socket fire-and-forget, so frames already in flight
    // can land after orbFrame.dispose().
    if (_disposed) return;
    // Gated on `_playerReady`, same as the write just below: a chunk the
    // player never received must not advance `_levels`' `_written` either —
    // indexing a chunk that was dropped on the floor would permanently offset
    // every later lookup from the head by that chunk's frame count.
    if (_playerReady) {
      _player.write(pcm);
      // INDEXED, not applied. Audio arrives far faster than it plays, so the
      // chunk in hand is not the chunk being heard; _pollPlaybackLevel asks
      // the player which frame is actually leaving the speaker and looks up
      // this chunk's loudness when it gets there.
      _levels.add(pcm);
    }
  }

  @visibleForTesting
  void debugHandleAudio(Uint8List pcm) => _handleAudio(pcm);

  /// Returns the underlying lookup's Future so a test can `await` past the
  /// platform-channel round trip (`_player.playedFrames()` is genuinely
  /// async — even a fake's `async =>` returns a Future that only resolves on
  /// a later microtask, never inline) instead of racing it. The periodic
  /// timer below ignores the return value; nothing production-side awaits it.
  @visibleForTesting
  Future<void> debugPollPlaybackLevel() => _pollPlaybackLevel();

  @visibleForTesting
  void debugResetPlaybackLevels() => _levels.reset();

  /// Test seam: flip `_playerReady` without a real join round trip. Production
  /// only ever sets it inside `_initPlayer`'s success path; tests that never
  /// connect a socket have no other way to reach it.
  @visibleForTesting
  void debugSetPlayerReady() {
    _playerReady = true;
    _syncOrb();
  }

  /// How often the orb's level is refreshed from the real playback position.
  /// 20Hz: syllables move on a ~100ms scale, so 50ms granularity is ample, and
  /// unlike the cursor this drove before, a late value here is invisible — it
  /// shapes a synthetic line rather than indexing a timeline.
  static const Duration _levelPollPeriod = Duration(milliseconds: 50);

  Timer? _levelTimer;

  /// Test seam: whether the 20Hz poll is running. A timer that outlives its
  /// reason is invisible from the level alone.
  @visibleForTesting
  bool get debugLevelTimerActive => _levelTimer?.isActive ?? false;

  /// Whether the CURRENT run of poll failures has already been logged. A
  /// persistently failing `playedFrames()` ticks at 20Hz; without this, that
  /// either floods the event log with one line per tick or (worse, if never
  /// logged at all) leaves the log silent while the orb sits inert — exactly
  /// the failure class this redesign exists to kill. Cleared on the next
  /// success, so a later, separate failure run logs again.
  bool _levelPollFailed = false;

  /// playedFrames(), never playedMs(): playedMs re-anchors per run and this
  /// consumer does not.
  Future<void> _pollPlaybackLevel() {
    if (_disposed || !_playerReady) return Future.value();
    // Two-argument `then(onValue, onError:)`, not `.then().catchError()`: the
    // latter attaches to the Future `then` RETURNS, so it would also swallow
    // anything thrown INSIDE the value callback (a type error, a null deref,
    // a ChangeNotifier used after dispose) — bugs in this method's own logic,
    // not platform-channel hiccups. `onError:` here only ever sees a failure
    // from `playedFrames()` itself.
    return _player.playedFrames().then((f) {
      if (_disposed) return;
      // Nothing left to hear? Then the level is zero, immediately — no grace
      // period, no repetition check.
      //
      // `f >= writtenFrames` is CONCLUSIVE on its own. `_levels.add(pcm)` and
      // `_player.write(pcm)` run together under one `_playerReady` gate, and
      // `write` only enqueues — the Kotlin writer thread feeds AudioTrack from
      // that queue afterwards. So `writtenFrames` is an upper bound the head
      // can never pass, and equality means the track AND the queue are empty.
      //
      // This replaces `PlaybackLevels.levelAt`'s hold-past-end for this
      // caller. That hold is right as a pure function — playback and arrival
      // are independent, and a lookup a little past the index should not
      // flicker — but wrong as the orb's behaviour across a tool round, where
      // the queue empties for seconds and the orb would sit at the last
      // syllable and then jump when audio resumes.
      //
      // An earlier version required the head to ALSO be unmoved for five
      // consecutive polls (250ms). That silently coupled the orb to the
      // server's `jitter_buffer_ms` (150ms, `app/config.ex`): `listening`
      // arrives and cancels the poll before five flat polls can accumulate,
      // so the count never completed and the next turn's first poll fell
      // through to the stale hold. One reading is enough; the hardware cannot
      // lie in the unsafe direction.
      //
      // `curvedLevel` HERE, at the one place the raw RMS becomes the orb's
      // input, rather than at each place it is consumed: amplitude, the
      // shaping anchor, the transient detector, the halos and the ring boost
      // must all agree on what "loud" means, and applying it once is how they
      // cannot drift. See kLevelCurve — without it, soft syllables sit near
      // the floor and the line reads as reacting to hard consonants rather
      // than to speech.
      // `f` is Android's playbackHeadPosition, a SIGNED Int that wraps at
      // 2^31 frames — ~24.8 h of CUMULATIVE PLAYED AUDIO since the last
      // flush(), not of uptime. Past a wrap it goes negative and both branches
      // here fail silently in the same direction: `f >= writtenFrames` is
      // false forever, and `levelAt(f)` returns 0 via its before-first branch,
      // so the orb's line parks at its rest amplitude and never tracks speech
      // again. Deliberately NOT guarded: any barge-in flushes and resets the
      // counter, and 24.8 h of uninterrupted speaking is months of real use.
      // A known cliff, not a live bug — see the note in AudioTrackPlayer.kt.
      orbFrame.audioTarget =
          f >= _levels.writtenFrames ? 0.0 : curvedLevel(_levels.levelAt(f));
      _levelPollFailed = false;
    }, onError: (Object e) {
      // A platform-channel hiccup must not take the orb down; the level holds
      // and decays through its own release. Logged once per failure run.
      if (!_levelPollFailed) {
        _levelPollFailed = true;
        _log('playback level poll failed: $e');
      }
    });
  }

  /// Runs only while Henry is speaking, and only with a live player.
  ///
  /// `flutter_test` fails a test that leaves a Timer pending and checks BEFORE
  /// tearDown disposal (see the note on [deviceIdReady]), so a timer outliving
  /// its reason breaks the suite rather than merely being untidy.
  void _syncLevelPoll() {
    final wanted = _playerReady && orbFrame.state == OrbState.speaking;
    if (!wanted) {
      _levelTimer?.cancel();
      _levelTimer = null;
      // The poll is now the only source of a NON-ZERO `audioTarget` — the mic
      // listener stopped feeding it when the level moved playback-side, and
      // the mic-teardown paths only ever zero it. `_reactive` still includes
      // `listening`, so `advance()` keeps targeting whatever was left here:
      // without this line the smoother parks on Henry's last playback loudness
      // for the whole time the user is talking (halos flared, glow wide,
      // sphere swollen), and a barge-in straight to `listening` inherits the
      // abandoned turn's level.
      orbFrame.audioTarget = 0.0;
      return;
    }
    _levelTimer ??=
        Timer.periodic(_levelPollPeriod, (_) => _pollPlaybackLevel());
  }

  void _handleStopPlayback() async {
    if (!_playerReady) return;
    // Reset BEFORE the flush round trip, not after. Method channels preserve
    // ordering, so a chunk that arrives WHILE `stopAndFlush()` is in flight is
    // written after the flush and lands at post-flush head positions 0..N —
    // resetting after the await would wipe that chunk's index entry, and the
    // next chunk would then claim 0..M while the player already has it at
    // N..N+M, offsetting every `levelAt()` for the rest of the run by N.
    // Resetting first clears exactly the entries the flush is about to
    // discard, so an in-flight chunk indexes from 0 in step with the player.
    _levels.reset();
    final ms = await _player.stopAndFlush();
    _live?.push('played', {'ms': ms});
    _log('stop_playback → played ${ms}ms');
    _safeNotify();
  }

  void _handleDuck(bool on) {
    if (_playerReady) _player.setVolume(on ? 0.35 : 1.0);
  }

  /// Hand the microphone to Voice Lock enrollment and get a fresh 16 kHz
  /// PCM16 stream for it.
  ///
  /// One [MicCapture] wraps one AudioRecorder and most platforms permit one
  /// recording session, so enrollment cannot open a second — the conversation
  /// stops first. It also MUST stop for a reason better than plumbing: with
  /// the conversation's mic live, reading an enrollment prompt aloud is a
  /// perfectly good utterance and Henry answers it. The web has that bug
  /// (assets/js/voice/enroll.js opens a SECOND getUserMedia); we are not
  /// porting it.
  ///
  /// [resumeMic] is the only thing that gives the microphone back. Call it
  /// from a `finally` — a miss leaves the assistant deaf with no visible
  /// cause. If the borrowed session below fails to open, the loan stays set
  /// on purpose: the caller's `finally` still runs resumeMic(), which ends it.
  ///
  /// **Invariant A.** The conversation gives up everything it holds in ONE
  /// synchronous whole-value assignment, taken entirely before any platform
  /// call. The sixth Critical was the opposite shape — the subscription and
  /// the session were dropped before `await conversation.stop()` and the
  /// "off" flag was set after it, behind a guard that threw — so a wedged
  /// stop left `micOn == true` over nothing at all, with every restart path
  /// bailing on that flag. There is no such flag any more: [MicState.on] is
  /// derived from the handles this line gives up.
  Future<Stream<Uint8List>> suspendMic() async {
    final held = _micState;
    if (held.loaned) throw MicAlreadyLoaned();
    // Inherit any restore intent that is still outstanding rather than
    // recomputing from scratch. A resumeMic() parked in its own platform
    // await has already ended its loan, so a second enrollment can
    // legitimately start on top of it (the borrower bounds releaseMic() at 2s
    // and moves on) — and in that window `on`/`wanted` read false PRECISELY
    // BECAUSE the first loan took the mic. Recomputing dropped "the
    // conversation had the microphone" on the floor and left the device
    // silently deaf once enrollment finished.
    _micState = held.lentOut(restore: held.on || held.wanted || held.resumeWanted);
    _talking = false;
    _turnState = TurnState.idle;
    orbFrame.audioTarget = 0.0;
    _syncOrb();
    _log('mic loaned out (enrollment)');

    // Only NOW does anything touch the platform, and nothing above waits on
    // it. MicCapture serialises the borrowed open behind this stop, so the
    // ordering the hardware needs is kept by the class that owns the
    // hardware rather than by an await here.
    unawaited(_release(held));

    // Named BEFORE the platform answers. That is what lets resumeMic() close
    // this exact session even while the open is still wedged inside the
    // plugin — and what lets the belated continuation below recognise that a
    // newer cycle has since taken the recorder.
    final session = _mic.start();
    _micState = _micState.borrowed(session);
    // A borrowed session that fails to open needs no reconciliation here: it
    // owns nothing, so resumeMic()'s stop of it is already a no-op, and the
    // error is what the borrower's `catch` is for.
    final stream = await session.stream;
    if (!identical(_micState.loan, session)) {
      // Nobody is coming back for this stream: the caller already gave up and
      // resumeMic() ran in its place. Stop the session we just (belatedly)
      // opened rather than returning — or silently leaking — a live recording
      // nobody will ever listen to. Safe by construction: if a newer cycle
      // owns the recorder, this stop is a no-op against it.
      unawaited(session.stop());
      throw StateError('mic loan superseded before the acquire completed');
    }
    return stream;
  }

  /// Give the microphone back. Idempotent, and safe to call when [suspendMic]
  /// itself threw — which is exactly why a caller's `finally` can call it
  /// unconditionally.
  ///
  /// If the conversation had the mic before the loan it is switched back on.
  /// When the channel is DOWN at that moment, startMic() would no-op on its
  /// `_live == null` guard, so the restore is handed to the same re-arm flag
  /// a socket death uses ([MicState.wasOn], consumed by `_reArmMic` on the
  /// next successful join). Without that, an outage during enrollment would
  /// leave the device deaf until somebody tapped power.
  /// **Invariant A.** Ending the loan and deciding what to do about the
  /// restore is ONE synchronous run of whole-value assignments — there is no
  /// await between them for a competing suspend, a power tap or a dispose to
  /// land inside. That is what closes Important 3: the loan session's stop
  /// used to be awaited here, and a stop that threw exited with the loan
  /// already ended and the restore intent never consumed, so the microphone
  /// simply never came back.
  ///
  /// It is also why this method needs no supersession guard of its own. The
  /// previous version bumped a generation counter and re-read it after its
  /// platform await, defending a window that no longer exists; the only
  /// remaining await is [startMic]'s, which guards itself by session
  /// identity.
  Future<void> resumeMic() async {
    final held = _micState;
    if (!held.loaned) return;
    // The loan is over, and — if the conversation is getting the microphone
    // back — the intent that says so is consumed in the same breath. No
    // `_disposed` check: dispose() sets the whole value to [MicState.idle],
    // so a disposed controller has already returned on the line above.
    final restore = held.resumeWanted;
    _micState = held.returnedFromLoan().withResumeWanted(false);
    // Close the session suspendMic() opened for the borrower, BY NAME.
    // Harmless if the open failed and there is none, and — the point of the
    // handle — a no-op rather than a catastrophe if a newer cycle has since
    // taken the recorder. Fire-and-forget: MicSession.stop() neither throws
    // nor hangs, and nothing below may wait on the hardware to find out what
    // this controller intends.
    unawaited(held.loan?.stop());
    _log('mic returned');
    if (!restore) {
      _safeNotify();
      return;
    }
    if (_live == null) {
      // startMic() would no-op on its `_live == null` guard, so hand the
      // restore to the same re-arm flag a socket death uses.
      _micState = _micState.withWasOn(_connection.wantConnected);
      _safeNotify();
      return;
    }
    await startMic();
  }

  Future<void> startMic() async {
    if (_disposed) return;
    final held = _micState;
    // The recorder is on loan to enrollment. Record the intent and let
    // resumeMic() act on it, rather than opening a second recording session
    // the platform will refuse.
    if (held.loaned) {
      _micState = held.withResumeWanted(true);
      return;
    }
    if (held.on || held.wanted || _live == null) return;
    // Claimed synchronously, and recorded synchronously with it, so every
    // exit below can say WHICH session it is talking about — including the
    // exits that run while the platform is still opening it.
    final session = _mic.start();
    _micState = held.opening(session);
    try {
      final stream = await session.stream;
      // 5th post-dispose variant: a dispose() OR a stopMic() landing inside
      // this await would otherwise subscribe to a live recorder that nothing
      // will ever stop — the mic records forever. The state no longer naming
      // OUR session means somebody else's transition has been applied since;
      // whatever it decided, this one is not it.
      //
      // DELIBERATELY UNFALSIFIABLE, and recorded as such so no cleanup pass
      // reads it as dead code. `if (false)` here leaves the whole suite green,
      // because MicCapture drops a superseded session's claim SYNCHRONOUSLY
      // and the await above therefore throws instead of arriving here. Its
      // DELETION is equally unfalsifiable, so no test can settle the question
      // either way — the only argument is what it defends: a MicCapture
      // regression that let a superseded open resolve. `MicState`'s asserts
      // are compiled out of a release build, so without this line such a
      // regression reaches production silently. The type change on
      // [MicState.listening] removes the worst outcome (a microphone claiming
      // ON with nothing to turn off); this keeps the merely-stale one out too.
      if (_disposed || !identical(_micState.session, session)) {
        unawaited(session.stop());
        return;
      }
      // Started here, not in the constructor: startMic() is called on every
      // mic acquire, auto-restart (Task 1's backoff) included, so this is
      // the seam that keeps the spotter's engine current with the recorder's
      // lifecycle. `SherpaWakeSpotter.start()` itself now caches the loaded
      // engine across calls (see keyword_spotter.dart), so a restart is
      // cheap rather than a full reload.
      //
      // BOUNDED, unlike a bare `await`: every other platform call in this
      // file is (Invariant B, see `_release`) — a wedged model loader must
      // not leave `startMic` parked forever with `_micState` stuck at
      // `wanted`, which would silently brick every later start AND the
      // auto-restart backoff along with it. A timeout does not cancel the
      // underlying load (there is nothing to cancel it with); it only frees
      // this call to move on, so a load that eventually finishes still flips
      // `available` for the NEXT chunk to see.
      await _spotter.start().timeout(_wakeSpotterStartTimeout, onTimeout: () {
        _log('wake spotter start timed out after '
            '${_wakeSpotterStartTimeout.inSeconds}s; streaming until it '
            'finishes loading');
      });
      // A dispose or a newer session superseding this one during that await
      // is the same race the identical() check above guards — checked again
      // rather than assumed, for the same reason.
      //
      // Deliberately NOT calling `_spotter.stop()` here: `_spotter` is ONE
      // instance shared across every mic session, not one per attempt, and
      // this branch's own condition already proves we are NOT the current
      // session — `identical(_micState.session, session)` is false the
      // instant we reach it. If a newer session raced ahead and is already
      // streaming, it may already be mid-decode; resetting the shared
      // decoder out from under it here would drop a wake word spoken at
      // exactly that moment. Whatever legitimately owns the CURRENT session
      // resets the spotter through `_release` when IT tears down; a
      // superseded loser has no business touching shared state at all.
      if (_disposed || !identical(_micState.session, session)) {
        unawaited(session.stop());
        return;
      }
      // Subscribe BEFORE recording that we are listening. `stream.listen` can
      // throw, and with the state flipped first that throw landed in the catch
      // below still claiming a live microphone with no subscription and not
      // one frame flowing. Streams never deliver synchronously on listen, so
      // nothing can arrive before the assignment below.
      final sub = stream.listen((chunk) {
        // Same race as _handleAudio: cancelling the subscription is async, so a
        // chunk can still arrive after orbFrame.dispose() ran synchronously.
        if (_disposed) return;
        // No orb feedback here any more: the orb's level is playback-side now
        // (see _pollPlaybackLevel), and a mic-driven target would fight it.
        // Fail-open lives HERE, not in whether the gate ever learns about a
        // lock (see `_applyWakeLocked`): while the spotter has not finished
        // loading (or failed to), there is no way to ever detect a wake word
        // and open the gate again, so every chunk streams regardless of what
        // `_gate` believes. The gate keeps recording whatever lock state
        // arrives meanwhile, so the very next chunk after `available` flips
        // true is already correctly gated — no separate resync needed.
        if (!_spotter.available) {
          _live?.pushBinary('audio', chunk);
          return;
        }
        // Only a fresh detection while the gate is still closed announces
        // itself — an already-open gate (a second false-ish fire, or the
        // gate opened by PTT instead) must not re-push wake_detected.
        if (_spotter.offer(chunk) && !_gate.open) {
          _gate.onWakeDetected();
          _live?.push('wake_detected', const {});
        }
        final decision = _gate.offer(chunk);
        if (decision.send) {
          for (final pre in decision.preRoll) {
            _live?.pushBinary('audio', pre);
          }
          _live?.pushBinary('audio', chunk);
        }
      },
          onError: (Object e) => _log('mic error: $e'),
          // The platform ending the stream is the one way the microphone goes
          // away that nothing here asked for: audio focus lost to an incoming
          // call, the OS revoking the record permission, another app taking
          // the mic. Nothing throws, so without this the assistant simply
          // stops hearing — and `on` keeps reporting TRUE, because it is
          // derived from HOLDING a subscription and a subscription to a done
          // stream is still non-null. startMic() then no-ops on that very
          // flag, so the recovery path is dead too (MEASURED). This is the one
          // hole left in "derived, therefore cannot lie".
          onDone: () => _onMicStreamEnded(session));
      _micState = _micState.listening(session, sub);
      // A successful open cancels any pending unasked-end restart and starts
      // the backoff over — this session earned it, whether it came from a
      // user tap or from _attemptMicRestart.
      _micRestartTimer?.cancel();
      _micRestartTimer = null;
      _micRestartAttempt = 0;
      _talking = true;
      _turnState = TurnState.idle;
      _syncOrb();
      _log('mic started (16k PCM16)');
      _safeNotify();
    } catch (e) {
      // A `stream.listen` that throws leaves a session running with nobody on
      // it; close it. Also a no-op against a newer owner.
      unawaited(session.stop());
      // Only OUR failure may clear the controller's intent — if a newer
      // session has taken over, the intent is its business now. The SAME
      // check gates the spotter reset: unlike `session.stop()` (this
      // attempt's own recorder, always safe to close), `_spotter` is ONE
      // instance shared across every mic session. This catch can be reached
      // by a session that was ALREADY superseded before it threw (the
      // `await session.stream`/`await _spotter.start()` guards above rethrow
      // rather than swallow that race) — resetting the shared decoder in
      // that case could drop a wake word the newer, live session is mid-way
      // through hearing.
      if (identical(_micState.session, session)) {
        _micState = _micState.captureOff();
        unawaited(_spotter.stop());
      }
      _log('mic start failed: $e');
      _safeNotify();
    }
  }

  /// The platform ended [ended]'s stream without being asked to.
  ///
  /// Three halves now, and a fix that does only the first two is the same lie
  /// a third way round: the indicator has to go off, the recorder has to
  /// actually be let go of, AND — an alarm firing, any app taking audio
  /// focus, the OS revoking the record permission, another app seizing the
  /// mic — the assistant has to try to get it back on its own. A live alarm
  /// measured what "does NOT re-open" actually cost: Henry stayed deaf until
  /// the user power-cycled the app by hand. [_scheduleMicRestart] is the
  /// bounded version of "silently re-arm on a stream the platform just took
  /// away" — bounded because that IS how a retry loop starts if it is not.
  void _onMicStreamEnded(MicSession ended) {
    if (_disposed) return;
    // Still defensive, like startMic()'s post-await guard: every DELIBERATE
    // teardown path (stopMic, the loan paths) cancels the subscription before
    // the stop that would close the stream, so a done for a session we no
    // longer hold never reaches here from any of them. Tearing down on one
    // would stop whatever session is live now — the exact move that produced
    // Criticals 5, 6 and 7 — so the guard stays even though the path that
    // reaches this point at all is no longer hypothetical: the platform
    // itself can end a session we still hold, and that is precisely the case
    // below exists to recover from.
    final held = _micState;
    if (!identical(held.session, ended)) return;
    // Read BEFORE the transition, not after: captureOff() always resets
    // `wanted` to false (it says what the conversation HAS, not what anybody
    // WANTED), so asking `_micState.wanted` on the far side of it would read
    // false unconditionally and this would never restart anything. Every
    // deliberate path that could make `wanted` false already short-circuited
    // on the `identical` guard above, so reaching here means the user's
    // intent was still "on" — but read it off `held`, not off the belief.
    final wasWanted = held.wanted;
    // Invariant A: the whole-value transition first, the teardown of what it
    // gave up second.
    _micState = held.captureOff();
    _talking = false;
    _turnState = TurnState.idle;
    orbFrame.audioTarget = 0.0;
    _syncOrb();
    _log('mic stream ended by the platform');
    _safeNotify();
    unawaited(_release(held));
    if (wasWanted) _scheduleMicRestart();
  }

  /// Arm (or re-arm) the next backoff attempt after an unasked stream end.
  /// Never fights a loan or a deliberate disconnect: [_attemptMicRestart]
  /// re-checks both right before it touches anything, and [startMic] itself
  /// already turns an attempt made during a loan into a no-op recorded
  /// intent rather than a second recording session.
  void _scheduleMicRestart() {
    if (_disposed || !_connection.wantConnected) return;
    if (_micRestartAttempt >= micRestartBackoff.length) {
      _log('mic restart exhausted after ${micRestartBackoff.length} '
          'attempts; giving up');
      return;
    }
    final delay = micRestartBackoff[_micRestartAttempt];
    _micRestartAttempt++;
    _log('mic ended unasked; restart #$_micRestartAttempt in '
        '${delay.inMilliseconds}ms');
    _micRestartTimer?.cancel();
    _micRestartTimer = Timer(delay, _attemptMicRestart);
  }

  /// One backoff attempt. Chains to the next step on failure — including a
  /// failure that is really "nothing to do yet" (the mic is on loan, or the
  /// connection is down) — so a microphone that stays unavailable for a
  /// while is retried a bounded number of times rather than just once.
  void _attemptMicRestart() {
    if (_disposed || !_connection.wantConnected) return;
    unawaited(startMic().then((_) {
      if (_disposed) return;
      // Loaned: do not chain another attempt on top of it. The loan's own
      // resumeMic() owns getting the microphone back once it ends (via
      // resumeWanted, exactly like a channel-death restore); startMic()
      // above already turned this attempt into a no-op recorded intent
      // rather than a second recording session, so there is nothing left
      // for a further backoff step to do here.
      if (_micState.on || _micState.loaned) return;
      _scheduleMicRestart();
    }));
  }

  /// **Invariant A.** One synchronous transition — the conversation holds
  /// nothing, wants nothing, and no restore of any kind survives a deliberate
  /// stop — applied in full BEFORE the hardware is touched. Nothing after the
  /// platform call depends on it having returned, so a stop that fails or
  /// never answers cannot leave the microphone claiming to be on.
  Future<void> stopMic() async {
    final held = _micState;
    // Cancel any pending unasked-end restart too, same reasoning as `wasOn`
    // below: a deliberate stop must stay stopped even if the platform had
    // already ended the stream once and armed a backoff attempt for it.
    _micRestartTimer?.cancel();
    _micRestartTimer = null;
    _micRestartAttempt = 0;
    // `wasOn`: a deliberate stop must never be resurrected by a later
    // reconnect, even if a socket death upstream had already armed it.
    // `resumeWanted`: nor by a loan cycle. Cleared unconditionally, not just
    // inside a loan — the window that mattered was resumeMic()'s own tail,
    // where the loan is ALREADY over and the restore has not happened yet.
    _micState = held.captureOff().withResumeWanted(false).withWasOn(false);
    // On loan there is no conversation recording to stop, only the intent to
    // restore one, which the line above just cleared.
    if (held.loaned) {
      _safeNotify();
      return;
    }
    _talking = false;
    _turnState = TurnState.idle;
    orbFrame.audioTarget = 0.0; // advance() decays the level from here
    _syncOrb();
    _log('mic stopped');
    _safeNotify();
    await _release(held);
  }

  @override
  void dispose() {
    _disposed = true;
    _micRestartTimer?.cancel();
    _micRestartTimer = null;
    // The socket belongs to AppConnection: drop our handles on it, never close
    // it. Its own dispose() is the app's job.
    _connection.removeListener(_onConnectionChanged);
    // Registered in the constructor; without this the connection keeps handing
    // us every channel a later reconnect creates.
    _connection.dropListener(_topic, _adoptChannel);
    unawaited(_msgSub?.cancel());
    _channel = null;
    // One synchronous transition to nothing-held-nothing-wanted, then the
    // teardown of what it just gave up — including the borrowed session,
    // which a dispose mid-enrollment still has to close by name.
    final held = _micState;
    _micState = MicState.idle;
    unawaited(held.loan?.stop());
    unawaited(_release(held));
    // THE one place `_spotter.dispose()` is called. `_release` above (and
    // every other mic-teardown path) only ever calls `_spotter.stop()` —
    // cheap, reset-only, meant to leave the engine warm for a mic that comes
    // back. This controller itself is going away for good, so its spotter
    // goes with it: otherwise a fresh sign-in building a fresh
    // `VoiceController` (and a fresh `SherpaWakeSpotter`) leaks the previous
    // one's ONNX engine for the rest of the process.
    unawaited(_spotter.dispose());
    // Cancelled BEFORE the player is disposed: the timer calls into the
    // player, so tearing the player down first would read backwards even
    // though both are synchronous today.
    _levelTimer?.cancel();
    _levelTimer = null;
    if (_playerReady) {
      _player.dispose();
      _playerReady = false;
    }
    orbFrame.dispose();
    super.dispose();
  }
}
