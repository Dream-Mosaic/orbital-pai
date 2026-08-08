import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../config.dart';
import '../meridian/tokens.dart';
import '../phoenix/phoenix_channel.dart';
import '../phoenix/phoenix_socket.dart';

enum ConnState { idle, connecting, joined, error }

/// Opens (or re-opens) the socket. Injectable so the reconnect logic is testable
/// headless; production uses [defaultSocketConnector].
typedef SocketConnector = Future<PhoenixSocket> Function();

Future<PhoenixSocket> defaultSocketConnector() =>
    connectSocket(kSocketUrl(kSocketToken));

/// Owns THE connection: one socket, the reconnect machine, and the registry of
/// open topics. Consumers (VoiceController, panel clients) ask for a channel and
/// never touch the transport.
///
/// Reconnect lives here rather than in VoiceController so that every channel
/// inherits it. Left in the conversation, each panel would either reinvent it
/// badly or silently have none.
class AppConnection extends ChangeNotifier {
  AppConnection({
    SocketConnector? connector,
    List<Duration>? rejoinBackoff,
    Duration joinTimeout = const Duration(seconds: 15),
  })  : _connector = connector ?? defaultSocketConnector,
        _joinTimeout = joinTimeout,
        _rejoinBackoff = rejoinBackoff ??
            const [
              Duration(seconds: 1),
              Duration(seconds: 2),
              Duration(seconds: 5),
              Duration(seconds: 10),
            ];

  final SocketConnector _connector;
  final List<Duration> _rejoinBackoff;
  final Duration _joinTimeout;

  /// The user's intent, set by connect() and cleared by disconnect()/dispose().
  /// Without it a deliberate teardown races the backoff straight back onto the
  /// wire.
  bool _wantConnected = false;
  bool _connecting = false;
  Timer? _rejoinTimer;
  int _rejoinAttempt = 0;
  bool _disposed = false;

  PhoenixSocket? _socket;
  ConnState _state = ConnState.idle;

  /// Topics to (re)open on every successful connect, and their payloads.
  final _wanted = <String, Map<String, dynamic>>{};
  final _channels = <String, PhoenixChannel>{};

  final _joined = StreamController<void>.broadcast();

  ConnState get state => _state;
  Stream<void> get onJoined => _joined.stream;

  /// The header dot is CONNECTION status. It lives here because the socket does;
  /// on the conversation it would be reporting the health of something it no
  /// longer owns.
  ConnStatus get connStatus => switch (_state) {
        ConnState.joined => ConnStatus.connected,
        ConnState.idle => ConnStatus.connecting,
        ConnState.connecting => ConnStatus.connecting,
        ConnState.error => ConnStatus.offline,
      };

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> connect() async {
    if (_disposed || _connecting || _state == ConnState.joined) return;
    _connecting = true;
    _wantConnected = true;
    _rejoinTimer?.cancel();
    _rejoinTimer = null;
    _state = ConnState.connecting;
    _safeNotify();

    PhoenixSocket? opened;
    try {
      final socket = await _connector();
      opened = socket;
      // dispose()/disconnect() can land inside that await; without the re-check
      // the socket stays open forever behind a dead connection.
      if (_disposed || !_wantConnected) {
        unawaited(socket.close());
        return;
      }
      _socket = socket;
      socket.onClose.listen((_) {
        if (!identical(socket, _socket)) return; // superseded — not our problem
        _onSocketDown();
      });

      // Re-open every wanted topic and wait for their joins together. A join
      // that never resolves would park this method and latch _connecting.
      _channels.clear();
      final joins = <Future<void>>[];
      for (final entry in _wanted.entries) {
        final ch = socket.channel(entry.key, joinPayload: entry.value);
        _channels[entry.key] = ch;
        joins.add(ch.onJoin);
      }
      if (joins.isNotEmpty) {
        await Future.wait(joins).timeout(_joinTimeout);
      }
      if (_disposed || !identical(socket, _socket)) return;

      _state = ConnState.joined;
      _rejoinAttempt = 0;
      if (!_joined.isClosed) _joined.add(null);
      _safeNotify();
    } catch (e) {
      // Close the socket THIS invocation opened. Phoenix does not close the
      // socket when a join is refused, so without this every backoff retry
      // strands a live socket and its heartbeat timer.
      final failed = opened;
      if (failed != null) {
        if (identical(failed, _socket)) _socket = null;
        unawaited(failed.close());
      }
      if (_disposed || !_wantConnected) return;
      _state = ConnState.error;
      _safeNotify();
      _scheduleRejoin();
    } finally {
      _connecting = false;
    }
  }

  /// Open a topic now (if connected) and on every later reconnect.
  PhoenixChannel? openChannel(String topic,
      {Map<String, dynamic> joinPayload = const {}}) {
    if (_disposed) return null;
    _wanted[topic] = joinPayload;
    final live = _channels[topic];
    if (live != null) return live;
    final socket = _socket;
    if (socket == null) return null;
    final ch = socket.channel(topic, joinPayload: joinPayload);
    _channels[topic] = ch;
    // A topic opened against an already-joined socket bypasses connect()'s
    // batch join/timeout below, so its refusal would otherwise go unwatched
    // and leave the connection stuck half-joined forever. Once this fails,
    // the topic is already in _wanted, so every later retry rejoins it
    // through the normal connect() sweep — this only has to catch the first.
    unawaited(ch.onJoin.then((_) {}, onError: (Object _, StackTrace __) {
      _failConnection(socket);
    }));
    return ch;
  }

  /// A channel opened on a live socket was refused. Treat it like a failed
  /// (re)connect: close this socket, drop every channel on it, and fall back
  /// onto the backoff.
  void _failConnection(PhoenixSocket socket) {
    if (_disposed || !identical(socket, _socket)) return; // superseded already
    _socket = null;
    _channels.clear();
    unawaited(socket.close());
    if (!_wantConnected) return;
    _state = ConnState.error;
    _safeNotify();
    _scheduleRejoin();
  }

  void closeChannel(String topic) {
    _wanted.remove(topic);
    final ch = _channels.remove(topic);
    unawaited(ch?.leave());
  }

  void _onSocketDown() {
    if (_disposed) return;
    _socket = null;
    _channels.clear();
    _state = ConnState.idle;
    _safeNotify();
    _scheduleRejoin();
  }

  void _scheduleRejoin() {
    if (_disposed || !_wantConnected) return;
    _rejoinTimer?.cancel();
    final delay = _rejoinBackoff[math.min(_rejoinAttempt, _rejoinBackoff.length - 1)];
    _rejoinAttempt++;
    _rejoinTimer = Timer(delay, () {
      _rejoinTimer = null;
      if (_disposed || !_wantConnected) return;
      if (_state == ConnState.joined) return; // already back up
      unawaited(connect());
    });
  }

  /// Drop and immediately re-open the socket.
  Future<void> rejoin() async {
    final old = _socket;
    _socket = null;
    _channels.clear();
    await old?.close();
    _state = ConnState.idle;
    _safeNotify();
    await connect();
  }

  Future<void> disconnect() async {
    _wantConnected = false;
    _rejoinTimer?.cancel();
    _rejoinTimer = null;
    _rejoinAttempt = 0;
    final old = _socket;
    _socket = null;
    _channels.clear();
    await old?.close();
    _state = ConnState.idle;
    _safeNotify();
  }

  @override
  void dispose() {
    _disposed = true;
    _wantConnected = false;
    _rejoinTimer?.cancel();
    _rejoinTimer = null;
    unawaited(_socket?.close());
    _socket = null;
    _channels.clear();
    if (!_joined.isClosed) _joined.close();
    super.dispose();
  }
}
