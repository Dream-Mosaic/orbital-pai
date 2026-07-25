import 'dart:async';
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

class VoiceController extends ChangeNotifier {
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
    if (_state == ConnState.connecting || _state == ConnState.joined) return;
    _state = ConnState.connecting;
    _log('connecting…');
    _safeNotify();
    try {
      final client = await connectVoice(
        kSocketUrl(kSocketToken),
        topic: 'voice:henry',
        joinPayload: const {'kiosk': false},
      );
      _client = client;
      client.messages.listen(_onMessage, onError: (e) {
        _state = ConnState.error;
        _log('stream error: $e');
        _safeNotify();
      }, onDone: () {
        _state = ConnState.idle;
        _log('socket closed');
        _safeNotify();
      });
      final resp = await client.onJoin;
      _state = ConnState.joined;
      _log('joined voice:henry — reply: $resp');
      await _player.init(24000);
      _playerReady = true;
      _log('audio track ready (24k)');
      _safeNotify();
    } catch (e) {
      _state = ConnState.error;
      _log('connect/join failed: $e');
      _safeNotify();
    }
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
        _syncOrb();
      default:
        _log('event: ${m.event} $p');
    }
    _safeNotify();
  }

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
    if (_micOn || _client == null) return;
    try {
      final stream = await _mic.start();
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
      }, onError: (e) => _log('mic error: $e'));
      _safeNotify();
    } catch (e) {
      _log('mic start failed: $e');
      _safeNotify();
    }
  }

  Future<void> stopMic() async {
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
    await stopMic();
    await _client?.close();
    _client = null;
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
    stopMic();
    _client?.close();
    if (_playerReady) {
      _player.dispose();
      _playerReady = false;
    }
    orbFrame.dispose();
    super.dispose();
  }
}
