import 'dart:async';
import 'dart:typed_data';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'decoded_message.dart';
import 'v2_serializer.dart';

/// Minimal Phoenix V2 channel client over a StreamChannel. Owns one topic,
/// a monotonic ref counter, the join handshake, a heartbeat, and a broadcast
/// stream of decoded frames. Deliberately tiny — a spike-grade replacement for
/// phoenix_socket's uncertain binary support.
class PhoenixChannelClient {
  PhoenixChannelClient(
    this._channel, {
    required this.topic,
    this.joinPayload = const {},
    this.heartbeatInterval = const Duration(seconds: 30),
  });

  final StreamChannel<dynamic> _channel;
  final String topic;
  final Map<String, dynamic> joinPayload;
  final Duration heartbeatInterval;

  final _serializer = const V2Serializer();
  final _messages = StreamController<DecodedMessage>.broadcast();
  final _joined = Completer<Map<String, dynamic>>();

  int _refCounter = 0;
  String? _joinRef;
  Timer? _heartbeatTimer;

  Stream<DecodedMessage> get messages => _messages.stream;
  Future<Map<String, dynamic>> get onJoin => _joined.future;

  String _nextRef() => (++_refCounter).toString();

  void start() {
    _channel.stream.listen(_onFrame, onError: _onError, onDone: _onDone);
    _sendJoin();
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) => _sendHeartbeat());
  }

  void _sendJoin() {
    final ref = _nextRef();
    _joinRef = ref;
    _channel.sink.add(
        _serializer.encodeText(_joinRef, ref, topic, 'phx_join', joinPayload));
  }

  void _sendHeartbeat() {
    final ref = _nextRef();
    _channel.sink
        .add(_serializer.encodeText(null, ref, 'phoenix', 'heartbeat', const {}));
  }

  void push(String event, Map<String, dynamic> payload) {
    final ref = _nextRef();
    _channel.sink.add(_serializer.encodeText(_joinRef, ref, topic, event, payload));
  }

  void pushBinary(String event, Uint8List payload) {
    final ref = _nextRef();
    _channel.sink
        .add(_serializer.encodeBinary(_joinRef!, ref, topic, event, payload));
  }

  void _onFrame(dynamic frame) {
    final DecodedMessage msg;
    try {
      msg = _serializer.decode(frame);
    } catch (e, st) {
      _messages.addError(e, st);
      return;
    }
    if (msg.event == 'phx_reply' &&
        msg.ref == _joinRef &&
        !_joined.isCompleted) {
      if (msg.replyStatus == 'ok') {
        final resp = (msg.json?['response'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{};
        _joined.complete(resp);
      } else {
        _joined.completeError(StateError('join failed: ${msg.json}'));
      }
      return;
    }
    _messages.add(msg);
  }

  void _onError(Object err, StackTrace st) {
    if (!_messages.isClosed) _messages.addError(err, st);
  }

  void _onDone() {
    if (!_messages.isClosed) _messages.close();
  }

  Future<void> close() async {
    _heartbeatTimer?.cancel();
    await _channel.sink.close();
    if (!_messages.isClosed) await _messages.close();
  }
}

/// Production connect: opens a real WebSocket, waits for readiness, wires the client.
Future<PhoenixChannelClient> connectVoice(
  String url, {
  required String topic,
  Map<String, dynamic> joinPayload = const {},
}) async {
  final ws = WebSocketChannel.connect(Uri.parse(url));
  await ws.ready;
  final client = PhoenixChannelClient(ws, topic: topic, joinPayload: joinPayload);
  client.start();
  return client;
}
