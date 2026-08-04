import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import '../audio/audio_track_player.dart';
import '../audio/mic_capture.dart';
import '../config.dart';
import '../meridian/audio_levels.dart';
import '../meridian/orb_painter.dart';
import '../meridian/orb_state.dart';
import '../meridian/thread_model.dart';
import '../meridian/tokens.dart';
import '../phoenix/decoded_message.dart';
import '../phoenix/phoenix_channel_client.dart';

enum ConnState { idle, connecting, joined, error }

/// Opens (or re-opens) the voice channel. Injectable so the reconnect logic is
/// testable headless; production uses [defaultVoiceConnector].
typedef VoiceConnector = Future<PhoenixChannelClient> Function();

Future<PhoenixChannelClient> defaultVoiceConnector() => connectVoice(
      kSocketUrl(kSocketToken),
      topic: 'voice:henry',
      joinPayload: const {'kiosk': false},
    );

class VoiceController extends ChangeNotifier {
  VoiceController({
    VoiceConnector? connector,
    List<Duration>? rejoinBackoff,
    Duration joinTimeout = const Duration(seconds: 15),
    MicCapture? mic,
    AudioTrackPlayer? player,
  })  : _connector = connector ?? defaultVoiceConnector,
        _joinTimeout = joinTimeout,
        _mic = mic ?? MicCapture(),
        _player = player ?? AudioTrackPlayer(),
        _rejoinBackoff = rejoinBackoff ??
            const [
              Duration(seconds: 1),
              Duration(seconds: 2),
              Duration(seconds: 5),
              Duration(seconds: 10),
            ];

  final VoiceConnector _connector;
  final List<Duration> _rejoinBackoff;

  /// Upper bound on the phx_join handshake. The completer now always fails on
  /// transport death, so this only covers the other half: a server that accepts
  /// the socket and then never replies at all.
  final Duration _joinTimeout;

  // Reconnect state. `_wantConnected` is the user's intent (set by connect(),
  // cleared by disconnect()/dispose()) — without it a deliberate teardown would
  // race the backoff timer straight back onto the wire.
  bool _wantConnected = false;
  bool _connecting = false;
  Timer? _rejoinTimer;
  int _rejoinAttempt = 0;

  // `_micWanted` is intent, `_micOn` is fact. They differ exactly inside
  // startMic()'s await, which is where the 5th post-dispose variant lives.
  bool _micWanted = false;

  // Set by _onSocketDown when it tears a LIVE mic down, so a successful rejoin
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

  PhoenixChannelClient? _client;
  ConnState _state = ConnState.idle;
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

  ConnState get state => _state;
  String get caption => _caption;
  List<String> get transcript => List.unmodifiable(_transcript);
  List<String> get eventLog => List.unmodifiable(_eventLog);
  bool get micOn => _micOn;
  bool get pttHeld => _pttHeld;

  List<ThreadItem> get thread => List.unmodifiable(_thread);
  bool get pttEnabled => _pttEnabled;
  bool get abiEnabled => _abiEnabled;

  /// The header dot is CONNECTION status, not conversation state.
  ConnStatus get connStatus => switch (_state) {
        ConnState.joined => ConnStatus.connected,
        ConnState.idle => ConnStatus.connecting,
        ConnState.connecting => ConnStatus.connecting,
        ConnState.error => ConnStatus.offline,
      };

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
    _client?.push('ptt', {'enabled': enabled});
    _safeNotify();
    // index.js:396 — enabling PTT mode while powered off starts the mic.
    if (enabled && !_micOn && !_micWanted) unawaited(startMic());
  }

  void pttPress() {
    if (!_pttEnabled || _pttHeld) return;
    _pttHeld = true;
    _turnState = TurnState.listening; // amber while held (ambient if wake-locked)
    _client?.push('ptt_press', const {});
    _syncOrb();
  }

  void pttRelease() {
    if (!_pttHeld) return;
    _pttHeld = false;
    _turnState = TurnState.idle;
    _client?.push('ptt_release', const {});
    _syncOrb();
  }

  void setAllowInterruptions(bool enabled) {
    _abiEnabled = enabled;
    _client?.push('allow_interruptions', {'enabled': enabled});
    _safeNotify();
  }

  Future<void> connect() async {
    if (_disposed || _connecting || _state == ConnState.joined) return;
    _connecting = true;
    _wantConnected = true;
    _rejoinTimer?.cancel();
    _rejoinTimer = null;
    _state = ConnState.connecting;
    _log('connecting…');
    _safeNotify();
    // The client THIS invocation opened, so the catch can clean it up.
    PhoenixChannelClient? opened;
    PhoenixChannelClient? joinedClient;
    try {
      final client = await _connector();
      opened = client;
      // 5th post-dispose variant: dispose() can land inside this await. Without
      // the re-check the socket stays open forever behind a dead controller.
      if (_disposed || !_wantConnected) {
        unawaited(client.close());
        return;
      }
      _client = client;
      client.messages.listen(_onMessage, onError: (Object e) {
        // A superseded socket (rejoin already swapped it out) must NOT drive the
        // reconnect state machine.
        if (!identical(client, _client)) return;
        _onSocketDown('stream error: $e', ConnState.error);
      }, onDone: () {
        if (!identical(client, _client)) return;
        _onSocketDown('socket closed', ConnState.idle);
      });
      // Bounded on purpose. PhoenixChannelClient now fails onJoin when the
      // transport dies, which covers the bounce/disconnect races; the timeout
      // covers the remaining one — a server that accepts the socket and then
      // never answers phx_join. Either way this await MUST resolve, because the
      // `finally` below is the only thing that clears `_connecting`, and a stuck
      // `_connecting` no-ops every future connect() for the life of the app.
      final resp = await client.onJoin.timeout(_joinTimeout);
      if (_disposed || !identical(client, _client)) return;
      _state = ConnState.joined;
      _rejoinAttempt = 0;
      joinedClient = client;
      _log('joined voice:henry — reply: $resp');
      // Re-announce our local toggles: a rejoin lands on a conversation that may
      // have been re-pointed at another client in the meantime.
      client.push('allow_interruptions', {'enabled': _abiEnabled});
      client.push('ptt', {'enabled': _pttEnabled});
      _safeNotify();
    } catch (e) {
      // Close the socket THIS invocation opened. A join reply of
      // `status: "error"` (expired token, user off the allowlist) does not make
      // Phoenix close the socket, so without this every backoff retry leaked a
      // live socket plus its heartbeat timer, forever.
      final failed = opened;
      if (failed != null) {
        if (identical(failed, _client)) _client = null;
        unawaited(failed.close());
      }
      // A dispose()/disconnect() landing inside the handshake is a deliberate
      // teardown, not a failure: it owns the state it already set (and the
      // `finally` below still frees `_connecting`, which is the actual bug fix).
      if (_disposed || !_wantConnected) return;
      _state = ConnState.error;
      _log('connect/join failed: $e');
      _safeNotify();
      _scheduleRejoin();
    } finally {
      _connecting = false;
    }
    // Deliberately OUTSIDE the try above: a platform failure from the audio
    // player used to land in that catch → error state → rejoin → the same
    // failure again → an infinite reconnect loop (leaking a socket each pass).
    if (joinedClient != null) await _initPlayer(joinedClient);
    // Re-arm the mic now that the rejoin actually landed. Guarded with
    // `identical` (not just `joinedClient != null`) so a socket that died
    // AGAIN during _initPlayer's await can't have this now-superseded attempt
    // burn the flag — it stays set for the next join that actually sticks.
    if (_micWasOn && identical(joinedClient, _client)) {
      _micWasOn = false;
      await startMic();
    }
  }

  /// Bring up the 24k output track. Best-effort: a device without a working
  /// AudioTrack still has a usable session (mic + captions), so a failure here
  /// is logged and dropped — it must never reach the reconnect machine.
  Future<void> _initPlayer(PhoenixChannelClient client) async {
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
    if (_disposed || !_wantConnected) {
      unawaited(_player.dispose());
      return;
    }
    _playerReady = true;
    _log('audio track ready (24k)');
    // The player is controller-scoped, not client-scoped, so a socket swap mid-init
    // must NOT tear it down (the newer connect() would race the dispose). It only
    // means this attempt no longer owns the UI: leave the notify to the live one.
    if (!identical(client, _client)) return;
    _safeNotify();
  }

  /// The socket died. The orb must never keep showing a live colour over a dead
  /// socket (A1 final review, "Important 2"): reset the turn state, stop the mic
  /// (it was streaming into nothing) and start backing off toward a rejoin.
  void _onSocketDown(String why, ConnState state) {
    if (_disposed) return;
    final dead = _client;
    _client = null;
    // close() is the ONLY thing that cancels the heartbeat Timer.periodic, so
    // dropping the reference instead of closing leaked a timer (keeping the whole
    // client graph alive, and on a real WebSocketChannel still calling sink.add
    // on a closed sink) on every single server bounce.
    unawaited(dead?.close());
    _state = state;
    _log(why);
    _talking = false;
    _turnState = TurnState.idle;
    if (_micOn || _micWanted) {
      _micWasOn = true;
      _micWanted = false;
      _micOn = false;
      unawaited(_micSub?.cancel());
      _micSub = null;
      unawaited(_mic.stop());
    }
    orbFrame.audioTarget = 0.0;
    _syncOrb();
    _scheduleRejoin();
  }

  void _scheduleRejoin() {
    if (_disposed || !_wantConnected) return;
    _rejoinTimer?.cancel();
    final delay = _rejoinBackoff[math.min(_rejoinAttempt, _rejoinBackoff.length - 1)];
    _rejoinAttempt++;
    _log('rejoin attempt $_rejoinAttempt in ${delay.inMilliseconds}ms');
    _safeNotify();
    _rejoinTimer = Timer(delay, () {
      _rejoinTimer = null;
      if (_disposed || !_wantConnected) return;
      if (_state == ConnState.joined) return; // already back up
      if (_connecting) {
        // An attempt is already in flight, so connect() would no-op — and this
        // timer is the whole backoff chain. Re-arm instead of ending it: if that
        // in-flight attempt fails it schedules its own retry, and if it succeeds
        // the `joined` check above stops us on the next tick.
        _scheduleRejoin();
        return;
      }
      connect();
    });
  }

  /// Force a fresh join. VoiceChannel.join/3 -> bind_session/1 ->
  /// Conversation.set_client(pid, self()): the server re-points the conversation's
  /// OUTBOUND client to whoever joined LAST. Anything else that joins this session
  /// — notably a panel webview showing the web UI — therefore steals our event
  /// stream until we join again. Rejoining takes it back, and the `state` snapshot
  /// the server sends on every (re)bind re-anchors the UI.
  Future<void> rejoin() async {
    if (_disposed) return;
    _rejoinTimer?.cancel();
    _rejoinTimer = null;
    _rejoinAttempt = 0;
    final old = _client;
    _client = null; // so the old client's onDone is ignored, not retried
    _state = ConnState.connecting;
    _safeNotify();
    await old?.close();
    if (_disposed) return;
    await connect();
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
    _client?.push('played', {'ms': ms});
    _log('stop_playback → played ${ms}ms');
    _safeNotify();
  }

  void _handleDuck(bool on) {
    if (_playerReady) _player.setVolume(on ? 0.35 : 1.0);
  }

  Future<void> startMic() async {
    if (_disposed || _micOn || _micWanted || _client == null) return;
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
        _client?.pushBinary('audio', chunk);
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

  Future<void> disconnect() async {
    _wantConnected = false;
    _rejoinTimer?.cancel();
    _rejoinTimer = null;
    _rejoinAttempt = 0;
    await stopMic();
    final old = _client;
    _client = null;
    await old?.close();
    _state = ConnState.idle;
    if (_playerReady) {
      await _player.dispose();
      _playerReady = false;
    }
    _log('disconnected');
    _safeNotify();
  }

  @override
  void dispose() {
    _disposed = true;
    _wantConnected = false;
    _rejoinTimer?.cancel();
    _rejoinTimer = null;
    stopMic();
    _client?.close();
    _client = null;
    if (_playerReady) {
      _player.dispose();
      _playerReady = false;
    }
    orbFrame.dispose();
    super.dispose();
  }
}
