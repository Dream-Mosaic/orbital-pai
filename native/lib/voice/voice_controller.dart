import 'dart:async';
import 'package:flutter/foundation.dart';
import '../audio/audio_track_player.dart';
import '../audio/mic_capture.dart';
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
  })  : _connection = connection,
        _mic = mic ?? MicCapture(),
        _player = player ?? AudioTrackPlayer() {
    // Register the topic once and take delivery of every channel the
    // connection makes for it — the one that already exists if we were built
    // after the connect, and a fresh one after every reconnect. Both, because
    // a consumer that only works when it is built first is a trap for every
    // future panel client.
    //
    // Delivery is at channel CREATION, not at join, and that is load-bearing:
    // the server pushes `state` and `history` immediately behind its join
    // reply, so a listener attached on a "joined" signal misses both on every
    // single connect. `essential: true` because a refused `voice:henry` means
    // a dead token — there is nothing to stay connected for.
    _connection.openChannel(
      _topic,
      joinPayload: _joinPayload,
      essential: true,
      onChannel: _adoptChannel,
    );
    // The other half of the mic-restore contract: a deliberate teardown that
    // happens while the mic is ALREADY down (i.e. mid-outage, so there is no
    // second channel death to notice it) must still disarm the flag.
    _connection.addListener(_onConnectionChanged);
  }

  static const String _topic = 'voice:henry';
  static const Map<String, dynamic> _joinPayload = {'kiosk': false};

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

  // Mirrors index.js's `this.pttHeld`: read by the `state` snapshot merge and
  // written by pttPress/pttRelease.
  bool _pttHeld = false;

  String _caption = '';
  final List<String> _transcript = [];
  final List<String> _eventLog = [];

  // Injected (defaulted to the real implementations in the constructor) so the
  // mic/player teardown paths are testable headless — a real MicCapture or
  // AudioTrackPlayer needs a device.
  final MicCapture _mic;

  bool _disposed = false;

  final AudioTrackPlayer _player;
  bool _playerReady = false;

  // ---- Meridian chrome state ----
  /// index.js reads this from a data attribute; the native client has no such
  /// channel, and the server-side default is "Henry".
  static const String assistantName = 'Henry';

  final List<ThreadItem> _thread = <ThreadItem>[];

  // Turn-scoped handles, all reset on `listening`/`state` exactly as index.js
  // resets brainEl / metricsEl / toolChips / thinkingEl.
  int? _brainIndex;
  int? _metricsIndex;
  int? _thinkingIndex;
  final List<int> _toolChipIndexes = <int>[];
  bool _historyBackfilled = false;

  bool _pttEnabled = false;
  bool _abiEnabled = false;

  // ---- Meridian orb state ----
  bool _talking = false;
  bool _wakeLocked = false;
  TurnState _turnState = TurnState.idle;
  final OrbFrame orbFrame = OrbFrame();

  String get caption => _caption;
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
    _safeNotify();
  }

  /// Map a server turn-state event onto the orb, ported from index.js.
  void _applyTurnEvent(String event) {
    switch (event) {
      case 'speak_start':
      case 'speaking':
        _turnState = TurnState.speaking;
      case 'listening':
        _turnState = TurnState.listening;
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
    _metricsIndex = null;
  }

  /// Drop the local transcript. NOTE: the web's trash button fires the LiveView's
  /// `clear_conversation` handler, which also clears server-side memory — the
  /// voice CHANNEL has no equivalent handle_in, and A2 makes no server changes
  /// beyond the panel route. So this is local-only; clearing memory stays a panel
  /// action.
  void clearThread() {
    _thread.clear();
    _brainIndex = null;
    _metricsIndex = null;
    _thinkingIndex = null;
    _toolChipIndexes.clear();
    _safeNotify();
  }

  void ackReminder(int id) {
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
  Future<void> togglePower() async {
    if (_micState.on || _micState.wanted) {
      await stopMic();
    } else {
      _caption = '';
      await startMic();
    }
  }

  void setPtt(bool enabled) {
    _pttEnabled = enabled;
    _live?.push('ptt', {'enabled': enabled});
    _safeNotify();
    // index.js:396 — enabling PTT mode while powered off starts the mic.
    if (enabled && !_micState.on && !_micState.wanted) unawaited(startMic());
  }

  void pttPress() {
    if (!_pttEnabled || _pttHeld) return;
    _pttHeld = true;
    _turnState = TurnState.listening; // amber while held (ambient if wake-locked)
    _live?.push('ptt_press', const {});
    _syncOrb();
  }

  void pttRelease() {
    if (!_pttHeld) return;
    _pttHeld = false;
    _turnState = TurnState.idle;
    _live?.push('ptt_release', const {});
    _syncOrb();
  }

  void setAllowInterruptions(bool enabled) {
    _abiEnabled = enabled;
    _live?.push('allow_interruptions', {'enabled': enabled});
    _safeNotify();
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
      _micState = _micState.withWasOn(false);
      unawaited(startMic());
    }
  }

  /// Bring up the 24k output track. Best-effort: a device without a working
  /// AudioTrack still has a usable session (mic + captions), so a failure here
  /// is logged and dropped — it must never reach the reconnect machine, which
  /// is why the join listener calls this unawaited.
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
        _log('history: ${turns.length} turns');
        // One-shot: a rebind re-pushes history and must not duplicate lines.
        if (turns.isNotEmpty && !_historyBackfilled && _thread.isEmpty) {
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
        _caption = (p['text'] as String?) ?? '';
      case 'transcript':
        _caption = '';
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
            _brainIndex = null;
            break;
          }
        }
        _addLine(source, text);
      case 'brain_delta':
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
        _wakeLocked = (p['locked'] as bool?) ?? false;
        _caption = _wakeLocked ? 'Say \u201CWake up $assistantName\u201D' : '';
        _log('locked: $_wakeLocked');
        _syncOrb();
      case 'state':
        _log('state snapshot: phase=${p['phase']} locked=${p['locked']}');
        _clearThinking();
        _brainIndex = null;
        _wakeLocked = (p['locked'] as bool?) ?? _wakeLocked;
        _caption = _wakeLocked ? 'Say \u201CWake up $assistantName\u201D' : '';
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
    // dispose() closes the socket fire-and-forget, so frames already in flight can
    // land after orbFrame.dispose(); the waveform setter notifies, which would throw.
    if (_disposed) return;
    if (_playerReady) _player.write(pcm);
    // Target only; advance() smooths per frame (see the mic listener).
    if (orbFrame.state == OrbState.speaking) {
      orbFrame.audioTarget = rmsFromPcm16(pcm);
      orbFrame.feedPcm(pcm, sampleRate: 24000); // TTS rate
    }
  }

  void _handleStopPlayback() async {
    if (!_playerReady) return;
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
        _live?.pushBinary('audio', chunk);
        // Set the TARGET only — OrbFrame.advance() smooths it once per frame, so
        // the orb's responsiveness never depends on the device's audio buffer size.
        if (orbFrame.state == OrbState.listening) {
          orbFrame.audioTarget = rmsFromPcm16(chunk);
          orbFrame.feedPcm(chunk, sampleRate: 16000); // mic rate
        }
      }, onError: (Object e) => _log('mic error: $e'));
      _micState = _micState.listening(sub);
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
      // session has taken over, the intent is its business now.
      if (identical(_micState.session, session)) {
        _micState = _micState.captureOff();
      }
      _log('mic start failed: $e');
      _safeNotify();
    }
  }

  /// **Invariant A.** One synchronous transition — the conversation holds
  /// nothing, wants nothing, and no restore of any kind survives a deliberate
  /// stop — applied in full BEFORE the hardware is touched. Nothing after the
  /// platform call depends on it having returned, so a stop that fails or
  /// never answers cannot leave the microphone claiming to be on.
  Future<void> stopMic() async {
    final held = _micState;
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
    if (_playerReady) {
      _player.dispose();
      _playerReady = false;
    }
    orbFrame.dispose();
    super.dispose();
  }
}
