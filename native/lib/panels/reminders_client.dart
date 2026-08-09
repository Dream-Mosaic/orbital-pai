import 'dart:async';

import 'package:flutter/foundation.dart';

import '../connection/app_connection.dart';
import '../phoenix/decoded_message.dart';
import '../phoenix/phoenix_channel.dart';

/// One row of the panel, already rendered for display.
///
/// `dueLabel` and `recurrenceLabel` arrive as strings from the server: both
/// depend on the configured timezone, and humanising them again in Dart would
/// be a second implementation of the same copy, free to drift.
class ReminderRow {
  const ReminderRow({
    required this.id,
    required this.body,
    required this.dueLabel,
    this.recurrenceLabel,
    this.household = false,
    this.kind = 'reminder',
  });

  final int id;
  final String body;
  final String dueLabel;

  /// null for a one-shot — the web shows no cadence badge for those.
  final String? recurrenceLabel;
  final bool household;
  final String kind;

  bool get isFollowup => kind == 'followup';

  static ReminderRow fromJson(Map<String, dynamic> j) => ReminderRow(
        id: (j['id'] as num).toInt(),
        body: j['body'] as String? ?? '',
        dueLabel: j['due_label'] as String? ?? '',
        recurrenceLabel: j['recurrence_label'] as String?,
        household: j['household'] == true,
        kind: j['kind'] as String? ?? 'reminder',
      );
}

/// The Reminders drawer's data path.
///
/// Joined only while the drawer is on screen: [open] registers the topic,
/// [close] leaves it, and the server stops computing state for a panel nobody
/// is looking at. Server-authoritative — [ack] and [dismiss] push and wait for
/// the next `state`, exactly like the web re-rendering from its own broadcast.
class RemindersClient extends ChangeNotifier {
  RemindersClient({required AppConnection connection}) : _connection = connection;

  /// The suffix is ignored server-side; the user comes from the token.
  static const String topic = 'panel:reminders:henry';

  final AppConnection _connection;
  PhoenixChannel? _channel;
  StreamSubscription<DecodedMessage>? _sub;
  List<ReminderRow> _due = const [];
  List<ReminderRow> _upcoming = const [];
  bool _open = false;
  bool _disposed = false;

  List<ReminderRow> get due => _due;
  List<ReminderRow> get upcoming => _upcoming;
  bool get isOpen => _open;

  void open() {
    if (_open) return;
    _open = true;
    _connection.openChannel(topic, onChannel: _adopt);
  }

  void close() {
    if (!_open) return;
    _open = false;
    // closeChannel drops the topic AND its listeners, so there is no
    // dropListener to pair with this.
    _connection.closeChannel(topic);
    unawaited(_sub?.cancel());
    _sub = null;
    _channel = null;
    // Drop the rows: a reopen re-fetches, and rendering the old list for the
    // frame before the new state lands reads as a ghost.
    _due = const [];
    _upcoming = const [];
    if (!_disposed) notifyListeners();
  }

  void ack(int id) => _write('ack', id);
  void dismiss(int id) => _write('dismiss', id);

  void _write(String event, int id) {
    final ch = _channel;
    // Phoenix answers a frame on a topic it has not joined with "unmatched
    // topic", so a write in the window between open() and the join reply is
    // silently lost. Same rule as VoiceController's live-channel guard.
    if (ch == null || !ch.isJoined) return;
    ch.push(event, {'id': id});
  }

  /// Delivery is at channel CREATION, not at join: the server pushes `state`
  /// straight behind its join reply and `messages` is unbuffered.
  void _adopt(PhoenixChannel ch) {
    _channel = ch;
    unawaited(_sub?.cancel());
    _sub = ch.messages.listen(_onMessage);
  }

  void _onMessage(DecodedMessage m) {
    if (m.event != 'state') return;
    final json = m.json ?? const <String, dynamic>{};
    _due = _rows(json['due']);
    _upcoming = _rows(json['upcoming']);
    if (!_disposed) notifyListeners();
  }

  static List<ReminderRow> _rows(Object? raw) => raw is List
      ? raw
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          // id is the handle ack/dismiss push, so a row without a usable
          // integer id cannot be rendered — drop just that row rather than
          // inventing a sentinel id, or letting fromJson's cast throw and
          // blank the rest of a perfectly good payload with it.
          .where((m) => m['id'] is num)
          .map(ReminderRow.fromJson)
          .toList(growable: false)
      : const [];

  @override
  void dispose() {
    _disposed = true;
    if (_open) _connection.closeChannel(topic);
    unawaited(_sub?.cancel());
    super.dispose();
  }
}
