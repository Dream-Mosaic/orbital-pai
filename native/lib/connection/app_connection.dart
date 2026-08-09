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

/// Handed each channel a registered topic gets, the moment it is CREATED.
/// See [AppConnection.openChannel] for why creation and not join.
typedef ChannelListener = void Function(PhoenixChannel channel);

/// A topic the app wants held open: how to join it, whether the app has any
/// reason to stay connected without it, and who receives its channels.
class _WantedTopic {
  _WantedTopic(this.joinPayload, this.essential);

  Map<String, dynamic> joinPayload;

  /// Spec §5.1's split, made explicit rather than incidental. An ESSENTIAL
  /// topic is one there is no point being connected without — `voice:henry`,
  /// whose refusal means a dead token — so its refusal is escalated to a
  /// socket-level failure: close, back off, retry. Every other topic is a
  /// panel: a refusal stops that channel and touches nothing else, because a
  /// bad panel topic must never tear down the conversation.
  bool essential;

  final listeners = <ChannelListener>[];
}

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

  /// Topics to (re)open on every successful connect.
  final _wanted = <String, _WantedTopic>{};
  final _channels = <String, PhoenixChannel>{};

  final _joined = StreamController<void>.broadcast();

  ConnState get state => _state;
  Stream<void> get onJoined => _joined.stream;

  /// The user's intent, exposed so a consumer can tell a transport FAILURE
  /// (a reconnect is coming — restore what you tore down) from a DELIBERATE
  /// teardown (stay down). Both land on the same `_state`, so the state alone
  /// cannot answer it. disconnect()/dispose() clear this before they close
  /// anything, so a consumer reacting to the close already sees `false`.
  bool get wantConnected => _wantConnected;

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

      // Re-open every wanted topic and wait for the ESSENTIAL joins together. A
      // join that never resolves would park this method and latch _connecting.
      _channels.clear();
      final joins = <Future<void>>[];
      // toList(): _createChannel hands each channel to its listeners
      // synchronously, and a listener is free to re-enter openChannel — see its
      // doc. Re-entering with a NEW topic registers it in _wanted, and
      // iterating the live map would then throw ConcurrentModificationError
      // into the catch below, closing a healthy socket. The snapshot is enough:
      // a topic registered from inside the sweep opens itself against the
      // socket, which is already set.
      for (final entry in _wanted.entries.toList()) {
        final ch = _createChannel(socket, entry.key, entry.value);
        // Spec §5.2: each join resolves independently, so a panel that fails to
        // come back does not hold up the conversation. Only the essential
        // topics gate the connection — a refused (or merely slow) panel must
        // neither fail this batch nor park it behind the join timeout.
        if (entry.value.essential) joins.add(ch.onJoin);
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

  /// Register a topic: open it now (if the socket is up) and on every later
  /// reconnect.
  ///
  /// [onChannel] is how a consumer should take delivery. It fires
  /// SYNCHRONOUSLY with each channel created for this topic — and immediately,
  /// with the live one, if a channel already exists. Subscribe to
  /// `channel.messages` from there and nowhere else: the server pushes frames
  /// straight behind its join reply, so a consumer that waits for a "joined"
  /// signal is two microtask hops too late and silently loses them.
  ///
  /// [essential] marks a topic the app has no reason to stay connected
  /// without; see [_WantedTopic.essential] for the split.
  PhoenixChannel? openChannel(
    String topic, {
    Map<String, dynamic> joinPayload = const {},
    bool essential = false,
    ChannelListener? onChannel,
  }) {
    if (_disposed) return null;
    // Registration WIDENS, never narrows. Two callers legitimately open the
    // same topic — one owns it, the rest are consumers taking delivery — and
    // this used to overwrite both fields from whoever called last. A bare
    // `openChannel('voice:henry')` would then demote the conversation to a
    // panel (its refusal stops escalating, connect() stops gating on its join)
    // and rejoin it with an empty payload. So: essential latches true, and an
    // empty payload means "I am not the owner" and leaves the real one alone.
    final want = _wanted.putIfAbsent(topic, () => _WantedTopic(joinPayload, essential));
    want.essential |= essential;
    if (joinPayload.isNotEmpty) want.joinPayload = joinPayload;
    if (onChannel != null && !want.listeners.contains(onChannel)) {
      want.listeners.add(onChannel);
    }

    final live = _channels[topic];
    if (live != null) {
      // A consumer built after the connection came up gets no creation of its
      // own, so hand it the channel that already exists. Listeners must be
      // idempotent for exactly this reason.
      onChannel?.call(live);
      return live;
    }

    // Not connected yet: the topic is registered, so connect()'s sweep will
    // create the channel and notify the listener then.
    final socket = _socket;
    if (socket == null) return null;

    final ch = _createChannel(socket, topic, want);
    // A topic opened against an already-joined socket bypasses connect()'s
    // batch join/timeout above, so its refusal would otherwise go unwatched
    // and leave the connection stuck half-joined forever. Only an ESSENTIAL
    // topic escalates — spec §5.1's whole point is that a refused panel leaves
    // the conversation and its socket alone. Once this fails, the topic is
    // already in _wanted, so every later retry rejoins it through the normal
    // connect() sweep — this only has to catch the first.
    unawaited(ch.onJoin.then((_) {}, onError: (Object _, StackTrace __) {
      if (want.essential) _failConnection(socket);
    }));
    return ch;
  }

  /// Create the channel for [topic] and hand it straight to its listeners.
  ///
  /// The handover happens inside `socket.channel`'s `onCreate`, i.e. before the
  /// phx_join is even written — see [PhoenixSocket.channel]. Doing it on the
  /// join instead is what made the app drop the server's `state` and `history`
  /// pushes on every single connect.
  PhoenixChannel _createChannel(
      PhoenixSocket socket, String topic, _WantedTopic want) {
    final ch = socket.channel(
      topic,
      joinPayload: want.joinPayload,
      onCreate: (created) {
        _channels[topic] = created;
        // toList(): a listener is free to re-enter openChannel.
        for (final listener in want.listeners.toList()) {
          listener(created);
        }
      },
    );
    _channels[topic] = ch;
    // One rule: a channel de-registers itself the moment its join fails, for
    // whatever reason. Without it a refused PANEL stayed here for the life of
    // the socket — openChannel handed the dead handle to every later caller,
    // onCreate never ran again, and no phx_join ever reached the wire, so the
    // topic was un-retryable until the next reconnect. Both entry points build
    // channels through here, so both are covered. Escalating an ESSENTIAL
    // refusal is somebody else's job (connect()'s Future.wait for the sweep,
    // openChannel's watcher for a live socket); this only de-registers.
    //
    // Identity, not presence: leave() fails a still-pending join, so closing a
    // panel and immediately reopening it queues THIS callback behind a fresh
    // channel already sitting in the registry. Keyed on presence, the corpse
    // evicts its own replacement and the next consumer to ask for the topic is
    // never handed anything.
    unawaited(ch.onJoin.then((_) {}, onError: (Object _, StackTrace __) {
      if (identical(_channels[topic], ch)) _channels.remove(topic);
    }));
    return ch;
  }

  /// An ESSENTIAL channel opened on a live socket was refused. Treat it like a
  /// failed (re)connect: close this socket, drop every channel on it, and fall
  /// back onto the backoff.
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

  /// Stop handing this topic's channels to [onChannel].
  ///
  /// The counterpart to openChannel's listener registration, for a consumer
  /// that goes away while the topic stays open. [closeChannel] drops the whole
  /// topic and its listeners with it, so a panel that simply closes needs
  /// nothing here — this is for the consumer that outlives nothing, like
  /// VoiceController, whose topic is permanent.
  ///
  /// Pass the same tear-off that was registered: Dart gives instance-method
  /// tear-offs on the same receiver value equality, so `_adoptChannel` here
  /// matches the `_adoptChannel` handed to openChannel.
  void dropListener(String topic, ChannelListener onChannel) {
    _wanted[topic]?.listeners.remove(onChannel);
  }

  /// Test seam: how many listeners [topic] currently has registered. 0 for an
  /// unknown topic. Used to prove a dropped listener is actually gone from the
  /// registry, not merely masked by some consumer-side guard.
  @visibleForTesting
  int debugListenerCount(String topic) => _wanted[topic]?.listeners.length ?? 0;

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
