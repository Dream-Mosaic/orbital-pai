import 'dart:async';

import 'package:flutter/foundation.dart';

import '../connection/app_connection.dart';
import '../phoenix/decoded_message.dart';
import '../phoenix/phoenix_channel.dart';

/// One (account, granted connector) pair, already derived for display.
///
/// Every field here is computed SERVER-SIDE, including the three booleans, and
/// the list arrives pre-sorted by {label, email}. Do not re-derive or re-sort
/// any of it: [onlyGrant] in particular is what decides whether Disconnect can
/// work at all, and a client that recomputes it from a stale payload is the
/// exact bug the channel's re-derivation defends against.
class Connection {
  const Connection({
    required this.accountId,
    required this.email,
    required this.connector,
    required this.label,
    required this.access,
    required this.isDefault,
    required this.showsDefault,
    required this.onlyGrant,
  });

  /// The google_accounts row id. The handle both writes push.
  final int accountId;
  final String email;

  /// "calendar" | "gmail" — the registry key as a string. Pushed back verbatim
  /// on disconnect and matched against the server's own allowlist there.
  final String connector;

  /// "Google Calendar" | "Gmail" — Connectors.label/1.
  final String label;

  /// "read" | "write". Never "none": a row only exists for a granted connector.
  final String access;

  /// This account is the user's write default.
  final bool isDefault;

  /// At least two accounts can reach this connector, so there is a choice to
  /// make and the default badge/button is worth showing. The web's
  /// connector_multi?/2.
  final bool showsDefault;

  /// This connector is the account's ONLY grant, so disconnecting it means
  /// deleting the account — which is pure DB and works natively. False means
  /// the reduction needs Google's consent page; see ConnectorsPanelView.
  final bool onlyGrant;

  static Connection fromJson(Map<String, dynamic> j) => Connection(
        accountId: (j['account_id'] as num).toInt(),
        email: j['email'] as String? ?? '',
        connector: j['connector'] as String,
        label: j['label'] as String? ?? '',
        access: j['access'] as String? ?? '',
        isDefault: j['is_default'] as bool? ?? false,
        showsDefault: j['shows_default'] as bool? ?? false,
        onlyGrant: j['only_grant'] as bool? ?? false,
      );
}

/// The Connectors drawer's state, as the server rendered it.
class ConnectorsState {
  const ConnectorsState({required this.connections});

  final List<Connection> connections;

  static ConnectorsState fromJson(Map<String, dynamic> j) =>
      ConnectorsState(connections: _connections(j['connections']));

  // account_id and connector are the two handles a write pushes, so a row
  // missing either cannot be acted on — drop just that row rather than letting
  // a cast throw inside the stream listener and blank an otherwise good
  // payload, the same tolerance memory_client.dart and voice_lock_client.dart
  // apply to their own list rows.
  static List<Connection> _connections(Object? raw) => raw is List
      ? raw
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .where((m) => m['account_id'] is num && m['connector'] is String)
          .map(Connection.fromJson)
          .toList(growable: false)
      : const [];
}

/// Joined only while the Connectors drawer is on screen.
/// Server-authoritative: a control pushes and the UI re-renders from the next
/// `state`.
class ConnectorsClient extends ChangeNotifier {
  ConnectorsClient({required AppConnection connection})
      : _connection = connection;

  static const String topic = 'panel:connectors:henry';

  final AppConnection _connection;

  PhoenixChannel? _channel;
  StreamSubscription<DecodedMessage>? _sub;
  ConnectorsState? _state;
  bool _open = false;
  bool _disposed = false;
  bool _needsWeb = false;

  ConnectorsState? get state => _state;
  bool get isOpen => _open;

  /// The server refused the last `disconnect` because that account holds
  /// another connector, so reducing it needs Google's consent page.
  ///
  /// A FLAG rather than a Future, because PhoenixChannel.push returns void:
  /// there is no ref to correlate a reply with, and this topic answers two
  /// events. The `needs_web` REASON is unambiguous though — only the
  /// disconnect handler produces it — and a transport failure produces no
  /// reply at all, so this stays false for one. That is the distinction the
  /// view needs: a sentence about the browser, not a generic error.
  bool get needsWeb => _needsWeb;

  /// The view calls this once it has shown the explanation, so a later
  /// rebuild does not show it again.
  void ackNeedsWeb() {
    if (!_needsWeb) return;
    _needsWeb = false;
    _notify();
  }

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
    _needsWeb = false;
    _notify();
  }

  void setDefault(int accountId) => _push('set_default', {'account_id': accountId});

  /// Push a disconnect. The payload carries NO `only_grant`: the server
  /// re-derives it, and a client that volunteers one is only offering a stale
  /// answer to a question it cannot answer.
  void disconnect({required int accountId, required String connector}) =>
      _push('disconnect', {'account_id': accountId, 'connector': connector});

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
    if (m.event == 'state') {
      _state = ConnectorsState.fromJson(m.json ?? const <String, dynamic>{});
      _notify();
      return;
    }
    if (m.event != 'phx_reply' || m.replyStatus == 'ok') return;
    final resp = m.json?['response'];
    if (resp is Map && resp['reason'] == 'needs_web') {
      _needsWeb = true;
      _notify();
    }
  }

  void _notify() {
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
