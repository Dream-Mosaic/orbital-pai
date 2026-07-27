import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import '../audio/audio_track_player.dart';
import '../audio/mic_capture.dart';
import '../config.dart';
import '../meridian/audio_levels.dart';
import '../meridian/orb_painter.dart';
import '../meridian/orb_state.dart';
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
  })  : _connector = connector ?? defaultVoiceConnector,
        _rejoinBackoff = rejoinBackoff ??
            const [
              Duration(seconds: 1),
              Duration(seconds: 2),
              Duration(seconds: 5),
              Duration(seconds: 10),
            ];

  final VoiceConnector _connector;
  final List<Duration> _rejoinBackoff;

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

  // Mirrors index.js's `this.pttHeld`; read by the `state` snapshot merge below
  // and written by the PTT controls (Task 9) — nothing in this task mutates it
  // yet, so it stays non-final on purpose (`prefer_final_fields` would fire
  // otherwise, then have to be reverted the moment Task 9 lands its writer).
  // ignore: prefer_final_fields
  bool _pttHeld = false;

  PhoenixChannelClient? _client;
  ConnState _state = ConnState.idle;
  String _caption = '';
  final List<String> _transcript = [];
  final List<String> _eventLog = [];

  final MicCapture _mic = MicCapture();
  StreamSubscription<Uint8List>? _micSub;
  bool _micOn = false;
  bool _disposed = false;

  final AudioTrackPlayer _player = AudioTrackPlayer();
  bool _playerReady = false;

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

  Future<void> connect() async {
    if (_disposed || _connecting || _state == ConnState.joined) return;
    _connecting = true;
    _wantConnected = true;
    _rejoinTimer?.cancel();
    _rejoinTimer = null;
    _state = ConnState.connecting;
    _log('connecting…');
    _safeNotify();
    try {
      final client = await _connector();
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
      final resp = await client.onJoin;
      if (_disposed || !identical(client, _client)) return;
      _state = ConnState.joined;
      _rejoinAttempt = 0;
      _log('joined voice:henry — reply: $resp');
      if (!_playerReady) {
        await _player.init(24000);
        // Same window: a dispose during init() leaks an initialized AudioTrack.
        if (_disposed) {
          unawaited(_player.dispose());
          return;
        }
        _playerReady = true;
        _log('audio track ready (24k)');
      }
      _safeNotify();
    } catch (e) {
      if (_disposed) return;
      _state = ConnState.error;
      _log('connect/join failed: $e');
      _safeNotify();
      _scheduleRejoin();
    } finally {
      _connecting = false;
    }
  }

  /// The socket died. The orb must never keep showing a live colour over a dead
  /// socket (A1 final review, "Important 2"): reset the turn state, stop the mic
  /// (it was streaming into nothing) and start backing off toward a rejoin.
  void _onSocketDown(String why, ConnState state) {
    if (_disposed) return;
    _client = null;
    _state = state;
    _log(why);
    _talking = false;
    _turnState = TurnState.idle;
    if (_micOn || _micWanted) {
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
        break;
      case 'partial':
        _caption = (p['text'] as String?) ?? '';
        break;
      case 'transcript':
        _caption = '';
        _transcript.add('you: ${p['text']}');
        break;
      case 'speak_start':
        _transcript.add('${p['source']}: ${p['text']}');
        _applyTurnEvent('speak_start');
        break;
      case 'brain_delta':
        _log('brain_delta: ${p['delta']}');
        break;
      case 'stop_playback':
        _handleStopPlayback(); // Task 6
        break;
      case 'duck':
        _handleDuck(true); // Task 6
        break;
      case 'unduck':
        _handleDuck(false); // Task 6
        break;
      case 'speaking':
      case 'listening':
      case 'thinking':
        _log('state: ${m.event}');
        _applyTurnEvent(m.event);
      case 'locked':
        _wakeLocked = (p['locked'] as bool?) ?? false;
        _log('locked: $_wakeLocked');
        _syncOrb();
      case 'state':
        _log('state snapshot: phase=${p['phase']} locked=${p['locked']}');
        _wakeLocked = (p['locked'] as bool?) ?? _wakeLocked;
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
      orbFrame.waveform = waveformFromPcm16(pcm, 128);
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
          orbFrame.waveform = waveformFromPcm16(chunk, 128);
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
