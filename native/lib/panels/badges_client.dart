import 'dart:async';

import 'package:flutter/foundation.dart';

import '../connection/app_connection.dart';
import '../phoenix/decoded_message.dart';
import '../phoenix/phoenix_channel.dart';

/// The nav's badge counts, on their own always-open topic.
///
/// Separate from the panels because a dot has to be right while every panel is
/// CLOSED, and separate from `voice:henry` because that topic is essential — a
/// badge must never be able to escalate into a conversation reconnect.
class BadgesClient extends ChangeNotifier {
  BadgesClient({required AppConnection connection}) : _connection = connection {
    _connection.openChannel(_topic, onChannel: _adopt);
  }

  /// The suffix is ignored server-side (the user comes from the token); it is
  /// here so a wire log reads as a topic rather than a bare prefix.
  static const String _topic = 'badges:henry';

  final AppConnection _connection;
  StreamSubscription<DecodedMessage>? _sub;
  Map<String, int> _counts = const {};
  bool _disposed = false;

  int count(String panel) => _counts[panel] ?? 0;
  bool get hasDue => count('reminders') > 0;

  /// Delivery is at channel CREATION, not at join: the server pushes `badges`
  /// straight behind its join reply and `messages` is unbuffered, so a
  /// listener attached on a "joined" signal is two microtask hops too late.
  void _adopt(PhoenixChannel ch) {
    unawaited(_sub?.cancel());
    _sub = ch.messages.listen(_onMessage);
  }

  void _onMessage(DecodedMessage m) {
    if (m.event != 'badges') return;
    // Every numeric key is a panel's count; an unknown one costs nothing and
    // means the next panel adds a key rather than a channel.
    _counts = {
      for (final e in (m.json ?? const <String, dynamic>{}).entries)
        if (e.value is num) e.key: (e.value as num).toInt(),
    };
    if (!_disposed) notifyListeners();
  }

  /// Test seam: feed a frame without a transport.
  @visibleForTesting
  void debugHandleMessage(DecodedMessage m) => _onMessage(m);

  @override
  void dispose() {
    _disposed = true;
    _connection.dropListener(_topic, _adopt);
    unawaited(_sub?.cancel());
    super.dispose();
  }
}
