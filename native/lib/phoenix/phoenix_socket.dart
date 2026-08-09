import 'dart:async';
import 'dart:typed_data';

import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'decoded_message.dart';
import 'phoenix_channel.dart';
import 'v2_serializer.dart';

/// A Phoenix V2 socket that multiplexes topics. Owns the transport, the ref
/// counter, the heartbeat, and routing; knows nothing about voice or panels.
///
/// Replaces the single-topic PhoenixChannelClient. The wire format already
/// supported this — V2Serializer encodes and decodes join_ref per topic — so
/// what this adds is bookkeeping: a channel per topic, and replies routed back
/// to the channel that sent the push.
class PhoenixSocket {
  PhoenixSocket(
    this._transport, {
    this.heartbeatInterval = const Duration(seconds: 30),
  });

  final StreamChannel<dynamic> _transport;
  final Duration heartbeatInterval;

  final _serializer = const V2Serializer();
  final _channels = <String, PhoenixChannel>{};

  /// ref -> the channel that sent it, so a reply reaches its sender rather than
  /// whichever channel happens to be first. Cleared on reply.
  final _pendingRefs = <String, PhoenixChannel>{};

  final _closed = StreamController<void>.broadcast();

  int _refCounter = 0;
  Timer? _heartbeatTimer;
  bool _isClosed = false;

  /// Fires once when the transport dies. AppConnection listens to drive backoff.
  Stream<void> get onClose => _closed.stream;

  /// Test seam (this file stays flutter-free, hence no @visibleForTesting):
  /// close() is the ONLY thing that cancels the heartbeat, so this is how a test
  /// proves a discarded socket was closed and not merely dereferenced.
  bool get debugHeartbeatActive => _heartbeatTimer?.isActive ?? false;

  String _nextRef() => (++_refCounter).toString();

  void start() {
    _transport.stream.listen(_onFrame, onError: _onError, onDone: _onDone);
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) => _sendHeartbeat());
  }

  /// Open (and immediately join) a topic. Returns the existing handle if the
  /// topic is already open, so two callers cannot double-join one topic.
  ///
  /// [onCreate] runs synchronously on a FRESH channel, after it is registered
  /// but *before* its phx_join reaches the wire. That ordering is the point:
  /// Phoenix pushes frames immediately behind a join reply (VoiceChannel's
  /// `state`, from `set_client` inside `join/3`, and `history`, from
  /// `:after_join`), and [PhoenixChannel.messages] is an unbuffered broadcast
  /// stream. Anything that attaches its listener after the join went out is
  /// racing the transport for those frames — so the handover happens here,
  /// where there is no race to lose. Not called for an already-open topic;
  /// that caller already has the handle back.
  PhoenixChannel channel(
    String topic, {
    Map<String, dynamic> joinPayload = const {},
    void Function(PhoenixChannel)? onCreate,
  }) {
    final existing = _channels[topic];
    if (existing != null) return existing;

    final ch = PhoenixChannel(
      topic: topic,
      joinPayload: joinPayload,
      onLeave: _sendLeave,
      onPush: _sendPush,
      onPushBinary: _sendPushBinary,
    );
    _channels[topic] = ch;
    onCreate?.call(ch);
    _sendJoin(ch);
    return ch;
  }

  void _sendJoin(PhoenixChannel ch) {
    if (_isClosed) return;
    final ref = _nextRef();
    ch.joinRef = ref;
    _pendingRefs[ref] = ch;
    _transport.sink.add(
        _serializer.encodeText(ref, ref, ch.topic, 'phx_join', ch.joinPayload));
  }

  void _sendHeartbeat() {
    if (_isClosed) return;
    _transport.sink
        .add(_serializer.encodeText(null, _nextRef(), 'phoenix', 'heartbeat', const {}));
  }

  void _sendPush(String event, Map<String, dynamic> payload, PhoenixChannel ch) {
    if (_isClosed) return;
    final ref = _nextRef();
    _pendingRefs[ref] = ch;
    _transport.sink
        .add(_serializer.encodeText(ch.joinRef, ref, ch.topic, event, payload));
  }

  void _sendPushBinary(String event, Uint8List payload, PhoenixChannel ch) {
    if (_isClosed || ch.joinRef == null) return;
    _transport.sink.add(
        _serializer.encodeBinary(ch.joinRef!, _nextRef(), ch.topic, event, payload));
  }

  void _sendLeave(PhoenixChannel ch) {
    _channels.remove(ch.topic);
    _pendingRefs.removeWhere((_, c) => identical(c, ch));
    if (_isClosed) return;
    _transport.sink
        .add(_serializer.encodeText(ch.joinRef, _nextRef(), ch.topic, 'phx_leave', const {}));
  }

  void _onFrame(dynamic frame) {
    final DecodedMessage msg;
    try {
      msg = _serializer.decode(frame);
    } catch (_) {
      // A frame we cannot parse belongs to no channel; dropping it is better
      // than guessing a topic and waking the wrong consumer.
      return;
    }

    if (msg.event == 'phx_reply' && msg.ref != null) {
      final waiting = _pendingRefs.remove(msg.ref);
      // A join reply resolves the channel; any other reply is just delivered.
      if (waiting != null && msg.ref == waiting.joinRef) {
        if (msg.replyStatus == 'ok') {
          final resp = (msg.json?['response'] as Map?)?.cast<String, dynamic>() ??
              const <String, dynamic>{};
          waiting.internalJoined(resp);
        } else {
          // CHANNEL-level refusal. Deliberately does NOT close the socket: with
          // one channel per socket that was correct (a refused voice:henry means
          // a dead token), but here it would let a refused panel tear down the
          // conversation.
          //
          // De-register it, though. There is no channel process on the server,
          // so nothing will ever route to this handle again — and since
          // channel() returns the existing handle for an open topic, leaving it
          // here would hand the corpse to every later caller for the life of
          // the socket, with no phx_join ever reaching the wire. Dropping it
          // makes the topic retryable; closing it tells anyone already
          // listening that it is over. No phx_leave: there is nothing to leave.
          _channels.remove(waiting.topic);
          waiting.internalFailJoin(StateError('join refused: ${msg.json}'));
          unawaited(waiting.internalClose());
        }
        return;
      }
      if (waiting != null) {
        waiting.internalDeliver(msg);
        return;
      }
    }

    _channels[msg.topic]?.internalDeliver(msg);
  }

  void _onError(Object err, StackTrace st) => _teardown(err, st);

  void _onDone() => _teardown(StateError('socket closed'), null);

  /// SOCKET-level failure: every channel goes down together and onClose fires
  /// once so AppConnection can start its backoff.
  void _teardown(Object err, StackTrace? st) {
    if (_isClosed) return;
    _isClosed = true;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    for (final ch in _channels.values.toList()) {
      ch.internalFailJoin(err, st);
      unawaited(ch.internalClose());
    }
    _channels.clear();
    _pendingRefs.clear();
    if (!_closed.isClosed) {
      _closed.add(null);
      _closed.close();
    }
  }

  Future<void> close() async {
    final wasClosed = _isClosed;
    _teardown(StateError('socket closed by the client'), null);
    if (!wasClosed) await _transport.sink.close();
  }
}

/// Production connect: opens a real WebSocket, waits for readiness, starts the
/// socket. Channels are opened by the caller.
Future<PhoenixSocket> connectSocket(String url) async {
  final ws = WebSocketChannel.connect(Uri.parse(url));
  await ws.ready;
  final socket = PhoenixSocket(ws);
  socket.start();
  return socket;
}
