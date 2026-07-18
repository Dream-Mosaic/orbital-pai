import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import '../config.dart';
import '../phoenix/decoded_message.dart';
import '../phoenix/phoenix_channel_client.dart';

enum ConnState { idle, connecting, joined, error }

class VoiceController extends ChangeNotifier {
  PhoenixChannelClient? _client;
  ConnState _state = ConnState.idle;
  String _caption = '';
  final List<String> _transcript = [];
  final List<String> _eventLog = [];

  ConnState get state => _state;
  String get caption => _caption;
  List<String> get transcript => List.unmodifiable(_transcript);
  List<String> get eventLog => List.unmodifiable(_eventLog);

  void _log(String line) {
    _eventLog.add(line);
    if (_eventLog.length > 200) _eventLog.removeAt(0);
  }

  Future<void> connect() async {
    if (_state == ConnState.connecting || _state == ConnState.joined) return;
    _state = ConnState.connecting;
    _log('connecting…');
    notifyListeners();
    try {
      final client = await connectVoice(
        kSocketUrl(kSocketToken),
        topic: 'voice:henry',
        joinPayload: const {'kiosk': false},
      );
      _client = client;
      client.messages.listen(_onMessage,
          onError: (e) {
            _state = ConnState.error;
            _log('stream error: $e');
            notifyListeners();
          },
          onDone: () {
            _state = ConnState.idle;
            _log('socket closed');
            notifyListeners();
          });
      final resp = await client.onJoin;
      _state = ConnState.joined;
      _log('joined voice:henry — reply: $resp');
      notifyListeners();
    } catch (e) {
      _state = ConnState.error;
      _log('connect/join failed: $e');
      notifyListeners();
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
        break;
      case 'state':
        _log('state snapshot: phase=${p['phase']} locked=${p['locked']}');
        break;
      default:
        _log('event: ${m.event} $p');
    }
    notifyListeners();
  }

  // ---- audio seams, implemented in Tasks 5–6 ----
  void _handleAudio(Uint8List pcm) {}
  void _handleStopPlayback() {}
  void _handleDuck(bool on) {}

  Future<void> disconnect() async {
    await _client?.close();
    _client = null;
    _state = ConnState.idle;
    _log('disconnected');
    notifyListeners();
  }

  @override
  void dispose() {
    _client?.close();
    super.dispose();
  }
}
