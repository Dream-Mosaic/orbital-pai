import 'dart:async';

import 'package:flutter/foundation.dart';

import '../connection/app_connection.dart';
import '../phoenix/decoded_message.dart';
import '../phoenix/phoenix_channel.dart';

/// The Settings drawer's state, as the server rendered it.
class SettingsState {
  const SettingsState({
    required this.defaultAbi,
    required this.defaultPtt,
    required this.voiceActivation,
    required this.briefingTime,
    required this.relockSeconds,
    required this.appVersion,
  });

  final bool defaultAbi;
  final bool defaultPtt;
  final bool voiceActivation;

  /// null when the morning briefing is off — the toggle derives from exactly
  /// this, as the web's `checked={@briefing_time != nil}` does.
  final String? briefingTime;
  final int relockSeconds;

  /// The SERVER's version, distinct from the Flutter build's kAppVersion in
  /// the header. Seeing the deployed version is the point of the About line.
  final String appVersion;

  bool get briefingOn => briefingTime != null;

  static SettingsState fromJson(Map<String, dynamic> j) => SettingsState(
        defaultAbi: j['default_abi'] == true,
        defaultPtt: j['default_ptt'] == true,
        voiceActivation: j['voice_activation'] == true,
        briefingTime: j['briefing_time'] as String?,
        relockSeconds: (j['relock_seconds'] as num?)?.toInt() ?? 15,
        appVersion: j['app_version'] as String? ?? '',
      );
}

/// Joined only while the Settings drawer is on screen. Server-authoritative:
/// a control pushes and the UI re-renders from the next `state`.
class SettingsClient extends ChangeNotifier {
  SettingsClient({required AppConnection connection, this.onLocalClear})
      : _connection = connection;

  static const String topic = 'panel:settings:henry';

  final AppConnection _connection;

  /// The native counterpart of the web's `push_event("clear_log")`: after a
  /// destructive write the on-screen transcript has to go too. main.dart wires
  /// this to VoiceController.clearThread.
  final VoidCallback? onLocalClear;

  PhoenixChannel? _channel;
  StreamSubscription<DecodedMessage>? _sub;
  SettingsState? _state;
  bool _open = false;
  bool _disposed = false;

  SettingsState? get state => _state;
  bool get isOpen => _open;

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
    if (!_disposed) notifyListeners();
  }

  void setPref(String pref, bool value) =>
      _push('set_pref', {'pref': pref, 'value': value});

  void setBriefing(String? time) => _push('set_briefing', {'time': time});

  void setRelock(int seconds) => _push('set_relock', {'seconds': seconds});

  void clearTurns() {
    // Gated: a socket drop closes every channel (_isJoined -> false) without
    // clearing this client's cached _state, so an unguarded call would wipe
    // the on-screen transcript while the server (and its memory) never hears
    // about it. Only count it as cleared if the write actually went out.
    if (_push('clear_turns', const {})) onLocalClear?.call();
  }

  void forgetMe() {
    if (_push('forget_me', const {})) onLocalClear?.call();
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
    _state = SettingsState.fromJson(m.json ?? const <String, dynamic>{});
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
