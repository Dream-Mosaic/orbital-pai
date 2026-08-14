import 'dart:async';

import 'package:flutter/foundation.dart';

import '../connection/app_connection.dart';
import '../phoenix/decoded_message.dart';
import '../phoenix/phoenix_channel.dart';

/// One profile fact, already rendered for display.
class MemoryFact {
  const MemoryFact({
    required this.id,
    required this.content,
    required this.source,
  });

  final int id;
  final String content;
  final String source;

  static MemoryFact fromJson(Map<String, dynamic> j) => MemoryFact(
        id: (j['id'] as num).toInt(),
        content: j['content'] as String? ?? '',
        source: j['source'] as String? ?? '',
      );
}

/// The Memory drawer's state, as the server rendered it.
class MemoryState {
  const MemoryState({required this.summary, required this.facts});

  final String summary;
  final List<MemoryFact> facts;

  static MemoryState fromJson(Map<String, dynamic> j) => MemoryState(
        summary: j['summary'] as String? ?? '',
        facts: _facts(j['facts']),
      );

  static List<MemoryFact> _facts(Object? raw) => raw is List
      ? raw
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          // id is the handle deleteFact pushes, so a row without a usable
          // integer id cannot be rendered — drop just that row rather than
          // inventing a sentinel id, or letting fromJson's cast throw and
          // blank the rest of a perfectly good payload with it.
          .where((m) => m['id'] is num)
          .map(MemoryFact.fromJson)
          .toList(growable: false)
      : const [];
}

/// Joined only while the Memory drawer is on screen. Server-authoritative: a
/// control pushes and the UI re-renders from the next `state`.
class MemoryClient extends ChangeNotifier {
  MemoryClient({required AppConnection connection, this.onLocalClear})
      : _connection = connection;

  static const String topic = 'panel:memory:henry';

  final AppConnection _connection;

  /// The native counterpart of the web's `push_event("clear_log")`: after a
  /// destructive wipe the on-screen transcript has to go too. main.dart wires
  /// this to VoiceController.clearThread.
  final VoidCallback? onLocalClear;

  PhoenixChannel? _channel;
  StreamSubscription<DecodedMessage>? _sub;
  MemoryState? _state;
  bool _open = false;
  bool _disposed = false;

  MemoryState? get state => _state;
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

  void saveSummary(String summary) =>
      _push('save_summary', {'summary': summary});

  void addFact(String content) => _push('add_fact', {'content': content});

  void deleteFact(int id) => _push('delete_fact', {'id': id});

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
    _state = MemoryState.fromJson(m.json ?? const <String, dynamic>{});
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
