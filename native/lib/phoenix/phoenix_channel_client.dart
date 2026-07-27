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

  /// Test seam (this file stays flutter-free, hence no @visibleForTesting):
  /// close() is the ONLY thing that cancels the heartbeat, so this is how a test
  /// proves a discarded client was actually closed and not just dereferenced —
  /// a leaked Timer.periodic keeps the whole client graph alive.
  bool get debugHeartbeatActive => _heartbeatTimer?.isActive ?? false;

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
    _failJoin(err, st);
    if (!_messages.isClosed) _messages.addError(err, st);
  }

  void _onDone() {
    _failJoin(StateError('socket closed before the join reply'));
    if (!_messages.isClosed) _messages.close();
  }

  /// The transport died before (or instead of) the join reply. Without this the
  /// [onJoin] completer stays pending FOREVER, so `await onJoin` never returns
  /// and the caller's `finally` never runs — which is how a server bounce (or a
  /// disconnect) in the ready→ack window used to latch VoiceController's
  /// `_connecting` flag true and kill every later reconnect.
  void _failJoin(Object err, [StackTrace? st]) {
    if (_joined.isCompleted) return;
    _joined.completeError(err, st ?? StackTrace.current);
    // Nobody is required to be awaiting onJoin (a caller can bail out before it
    // gets there), and an unobserved completeError would surface as an unhandled
    // async error. ignore() only adds a swallowing listener — anyone who does
    // await onJoin still sees the error.
    _joined.future.ignore();
  }

  Future<void> close() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    // Closing the sink normally makes the stream emit done (→ _onDone), but a
    // caller closing us mid-handshake must never be able to leave onJoin parked.
    _failJoin(StateError('client closed before the join reply'));
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
