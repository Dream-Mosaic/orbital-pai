import 'dart:async';
import 'package:flutter/foundation.dart';
import '../audio/audio_track_player.dart';
import '../audio/mic_capture.dart';
import '../connection/app_connection.dart';
import '../meridian/audio_levels.dart';
import '../meridian/orb_painter.dart';
import '../meridian/orb_state.dart';
import '../meridian/thread_model.dart';
import '../meridian/tokens.dart';
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
    _channel = _connection.openChannel(_topic, joinPayload: _joinPayload);
    _wireChannel();
    // Re-announce the local toggles after every (re)join: a rejoin lands on a
    // conversation that may have been re-pointed at another client meanwhile.
    _joinSub = _connection.onJoined.listen((_) {
      _channel = _connection.openChannel(_topic, joinPayload: _joinPayload);
      _wireChannel();
      _announceToggles();
      unawaited(_initPlayer());
      _reArmMic();
    });
    // The other half of the mic-restore contract: a deliberate teardown that
    // happens while the mic is ALREADY down (i.e. mid-outage, so there is no
    // second channel death to notice it) must still disarm the flag.
    _connection.addListener(_onConnectionChanged);
  }

  static const String _topic = 'voice:henry';
  static const Map<String, dynamic> _joinPayload = {'kiosk': false};

  final AppConnection _connection;
  PhoenixChannel? _channel;
  StreamSubscription<void>? _joinSub;
  StreamSubscription<DecodedMessage>? _msgSub;

  // `_micWanted` is intent, `_micOn` is fact. They differ exactly inside
  // startMic()'s await, which is where the 5th post-dispose variant lives.
  bool _micWanted = false;

  // Set by _onChannelDown when it tears a LIVE mic down, so a successful rejoin
  // can restore it (owner decision, A2: the web client never stops getUserMedia
  // on a socket death; we do, to keep the orb honest mid-turn, so WE must be
  // the one to undo it — otherwise a wall device goes silently deaf after
  // every server bounce). Deliberately separate from `_micWanted`: a user's
  // explicit stopMic() clears this too, so a mic switched off mid-outage is
  // never resurrected by a later reconnect.
  bool _micWasOn = false;

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
  StreamSubscription<Uint8List>? _micSub;
  bool _micOn = false;
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
  bool get micOn => _micOn;
  bool get pttHeld => _pttHeld;

  List<ThreadItem> get thread => List.unmodifiable(_thread);
  bool get pttEnabled => _pttEnabled;
  bool get abiEnabled => _abiEnabled;

  /// TEMPORARY passthrough. The header dot is CONNECTION status and now lives
  /// on [AppConnection]; `MeridianVoiceScreen` still reads it off the
  /// controller, and repointing the screen (with the `connection` parameter it
  /// needs) is Task 4. Delete this with that change.
  ConnStatus get connStatus => _connection.connStatus;

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
    if (_micOn || _micWanted) {
      await stopMic();
    } else {
      _caption = '';
      await startMic();
    }
  }

  void setPtt(bool enabled) {
    _pttEnabled = enabled;
    _channel?.push('ptt', {'enabled': enabled});
    _safeNotify();
    // index.js:396 — enabling PTT mode while powered off starts the mic.
    if (enabled && !_micOn && !_micWanted) unawaited(startMic());
  }

  void pttPress() {
    if (!_pttEnabled || _pttHeld) return;
    _pttHeld = true;
    _turnState = TurnState.listening; // amber while held (ambient if wake-locked)
    _channel?.push('ptt_press', const {});
    _syncOrb();
  }

  void pttRelease() {
    if (!_pttHeld) return;
    _pttHeld = false;
    _turnState = TurnState.idle;
    _channel?.push('ptt_release', const {});
    _syncOrb();
  }

  void setAllowInterruptions(bool enabled) {
    _abiEnabled = enabled;
    _channel?.push('allow_interruptions', {'enabled': enabled});
    _safeNotify();
  }

  // ---- transport seam (the connection owns the socket; we own one topic) ----

  void _wireChannel() {
    unawaited(_msgSub?.cancel());
    _msgSub = _channel?.messages.listen(
      _onMessage,
      onError: (Object e) => _log('channel error: $e'),
      onDone: _onChannelDown,
    );
  }

  void _announceToggles() {
    _channel?.push('allow_interruptions', {'enabled': _abiEnabled});
    _channel?.push('ptt', {'enabled': _pttEnabled});
  }

  /// The channel died under us. The orb must never keep showing a live colour
  /// over a dead channel (A1 final review, "Important 2"): reset the turn state
  /// and stop the mic, which was streaming into nothing. Reconnecting is
  /// AppConnection's job now — this is only the conversation's half.
  void _onChannelDown() {
    if (_disposed) return;
    // Drop the handle as well: pushing into a dead channel is a silent no-op,
    // and startMic()'s `_channel == null` guard is what keeps the mic from
    // opening into an outage.
    _channel = null;
    _log('channel down');
    _talking = false;
    _turnState = TurnState.idle;
    if (_micOn || _micWanted) {
      // Only a TRANSPORT failure earns a restore. disconnect()/dispose() clear
      // the connection's intent BEFORE they close anything, so this reads false
      // exactly when the user asked to go down — and a mic that went down with
      // a deliberate teardown must stay down, same as an explicit stopMic().
      _micWasOn = _connection.wantConnected;
      _micWanted = false;
      _micOn = false;
      unawaited(_micSub?.cancel());
      _micSub = null;
      unawaited(_mic.stop());
    }
    orbFrame.audioTarget = 0.0;
    _syncOrb();
  }

  /// A deliberate teardown while the mic is already down (mid-outage: the
  /// channel is long dead, so `_onChannelDown` will not fire again) must still
  /// disarm the restore flag, or the next connect switches the microphone back
  /// on by itself.
  void _onConnectionChanged() {
    if (!_connection.wantConnected) _micWasOn = false;
  }

  /// Restore a mic that a channel death tore down. Deliberately separate from
  /// `_micWanted`: a user's explicit stopMic() clears `_micWasOn` too, so a mic
  /// switched off mid-outage is never resurrected by a later reconnect.
  void _reArmMic() {
    if (_micWasOn) {
      _micWasOn = false;
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
    _channel?.push('played', {'ms': ms});
    _log('stop_playback → played ${ms}ms');
    _safeNotify();
  }

  void _handleDuck(bool on) {
    if (_playerReady) _player.setVolume(on ? 0.35 : 1.0);
  }

  Future<void> startMic() async {
    if (_disposed || _micOn || _micWanted || _channel == null) return;
    _micWanted = true;
    try {
      final stream = await _mic.start();
      // 5th post-dispose variant: a dispose() OR a stopMic() landing inside this
      // await would otherwise register _micSub on a live recorder that nothing
      // will ever stop — the mic records forever.
      if (_disposed || !_micWanted) {
        unawaited(_mic.stop());
        return;
      }
      _micOn = true;
      _talking = true;
      _turnState = TurnState.idle;
      _syncOrb();
      _log('mic started (16k PCM16)');
      _micSub = stream.listen((chunk) {
        // Same race as _handleAudio: cancelling the subscription is async, so a
        // chunk can still arrive after orbFrame.dispose() ran synchronously.
        if (_disposed) return;
        _channel?.pushBinary('audio', chunk);
        // Set the TARGET only — OrbFrame.advance() smooths it once per frame, so
        // the orb's responsiveness never depends on the device's audio buffer size.
        if (orbFrame.state == OrbState.listening) {
          orbFrame.audioTarget = rmsFromPcm16(chunk);
          orbFrame.feedPcm(chunk, sampleRate: 16000); // mic rate
        }
      }, onError: (Object e) => _log('mic error: $e'));
      _safeNotify();
    } catch (e) {
      _micWanted = false;
      _log('mic start failed: $e');
      _safeNotify();
    }
  }

  Future<void> stopMic() async {
    _micWanted = false;
    // A deliberate stop must never be resurrected by a later reconnect, even
    // if a socket death upstream had already armed the restore flag.
    _micWasOn = false;
    await _micSub?.cancel();
    _micSub = null;
    await _mic.stop();
    _micOn = false;
    _talking = false;
    _turnState = TurnState.idle;
    orbFrame.audioTarget = 0.0; // advance() decays the level from here
    _syncOrb();
    _log('mic stopped');
    _safeNotify();
  }

  @override
  void dispose() {
    _disposed = true;
    // The socket belongs to AppConnection: drop our handles on it, never close
    // it. Its own dispose() is the app's job.
    _connection.removeListener(_onConnectionChanged);
    unawaited(_joinSub?.cancel());
    unawaited(_msgSub?.cancel());
    _channel = null;
    stopMic();
    if (_playerReady) {
      _player.dispose();
      _playerReady = false;
    }
    orbFrame.dispose();
    super.dispose();
  }
}
