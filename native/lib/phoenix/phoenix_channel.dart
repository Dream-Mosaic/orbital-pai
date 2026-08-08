import 'dart:async';
import 'dart:typed_data';

import 'decoded_message.dart';

/// One topic's handle on a [PhoenixSocket]. Created by `socket.channel(topic)`,
/// never directly — the socket has to know about it to route frames.
///
/// The socket drives this class through the `internal*` methods; they are not
/// part of the consumer-facing surface.
class PhoenixChannel {
  PhoenixChannel({
    required this.topic,
    required this.joinPayload,
    required void Function(PhoenixChannel) onLeave,
    required void Function(String event, Map<String, dynamic> payload, PhoenixChannel ch)
        onPush,
    required void Function(String event, Uint8List payload, PhoenixChannel ch)
        onPushBinary,
  })  : _onLeave = onLeave,
        _onPush = onPush,
        _onPushBinary = onPushBinary;

  final String topic;
  final Map<String, dynamic> joinPayload;

  final void Function(PhoenixChannel) _onLeave;
  final void Function(String, Map<String, dynamic>, PhoenixChannel) _onPush;
  final void Function(String, Uint8List, PhoenixChannel) _onPushBinary;

  final _messages = StreamController<DecodedMessage>.broadcast();
  final _joined = Completer<Map<String, dynamic>>();

  /// The ref of this channel's phx_join. Every later frame on this topic must
  /// carry it as join_ref or Phoenix drops the frame.
  String? joinRef;
  bool _isJoined = false;

  Stream<DecodedMessage> get messages => _messages.stream;
  Future<Map<String, dynamic>> get onJoin => _joined.future;
  bool get isJoined => _isJoined;

  void push(String event, Map<String, dynamic> payload) =>
      _onPush(event, payload, this);

  void pushBinary(String event, Uint8List payload) =>
      _onPushBinary(event, payload, this);

  Future<void> leave() async {
    _onLeave(this);
    await internalClose();
  }

  // ---- driven by PhoenixSocket ----

  void internalDeliver(DecodedMessage m) {
    if (!_messages.isClosed) _messages.add(m);
  }

  void internalJoined(Map<String, dynamic> response) {
    _isJoined = true;
    if (!_joined.isCompleted) _joined.complete(response);
  }

  /// This CHANNEL was refused, or the socket under it died. Either way the join
  /// completer must resolve: a pending completer means `await onJoin` never
  /// returns and the caller's `finally` never runs — the bug that latched
  /// VoiceController's `_connecting` flag and killed every later reconnect.
  void internalFailJoin(Object err, [StackTrace? st]) {
    _isJoined = false;
    if (_joined.isCompleted) return;
    _joined.completeError(err, st ?? StackTrace.current);
    // Nobody is required to await onJoin; an unobserved completeError would
    // surface as an unhandled async error. ignore() only adds a swallowing
    // listener — anyone who does await still sees the error.
    _joined.future.ignore();
  }

  Future<void> internalClose() async {
    internalFailJoin(StateError('channel closed before the join reply'));
    _isJoined = false;
    if (!_messages.isClosed) await _messages.close();
  }
}
