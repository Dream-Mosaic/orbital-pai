import 'dart:convert';
import 'dart:typed_data';
import 'decoded_message.dart';

/// Phoenix V2 wire-format serializer. Text frames are JSON arrays
/// `[join_ref, ref, topic, event, payload]`. Binary frames carry a kind byte
/// (push=0, reply=1, broadcast=2), size bytes, the utf8 meta strings, then raw
/// payload bytes. Matches assets/js/phoenix/serializer.js exactly.
class V2Serializer {
  const V2Serializer();

  static const int _kindPush = 0;
  static const int _kindReply = 1;
  static const int _kindBroadcast = 2;

  String encodeText(
    String? joinRef,
    String? ref,
    String topic,
    String event,
    Object? payload,
  ) {
    return jsonEncode([joinRef, ref, topic, event, payload ?? const {}]);
  }

  Uint8List encodeBinary(
    String joinRef,
    String ref,
    String topic,
    String event,
    Uint8List payload,
  ) {
    final jr = utf8.encode(joinRef);
    final rf = utf8.encode(ref);
    final tp = utf8.encode(topic);
    final ev = utf8.encode(event);
    final header = <int>[
      _kindPush,
      jr.length,
      rf.length,
      tp.length,
      ev.length,
      ...jr,
      ...rf,
      ...tp,
      ...ev,
    ];
    final out = Uint8List(header.length + payload.length);
    out.setRange(0, header.length, header);
    out.setRange(header.length, out.length, payload);
    return out;
  }

  DecodedMessage decode(dynamic frame) {
    if (frame is String) return _decodeText(frame);
    final bytes = frame is Uint8List ? frame : Uint8List.fromList(frame as List<int>);
    return _decodeBinary(bytes);
  }

  DecodedMessage _decodeText(String frame) {
    final list = jsonDecode(frame) as List;
    final joinRef = list[0] as String?;
    final ref = list[1] as String?;
    final topic = list[2] as String;
    final event = list[3] as String;
    final payload = list[4];
    String? status;
    Map<String, dynamic>? json;
    if (payload is Map) {
      json = payload.cast<String, dynamic>();
      if (event == 'phx_reply') status = json['status'] as String?;
    }
    return DecodedMessage(
      joinRef: joinRef,
      ref: ref,
      topic: topic,
      event: event,
      json: json,
      replyStatus: status,
    );
  }

  DecodedMessage _decodeBinary(Uint8List b) {
    final kind = b[0];
    switch (kind) {
      case _kindPush:
        {
          final joinRefSize = b[1];
          final topicSize = b[2];
          final eventSize = b[3];
          var off = 4;
          final joinRef = utf8.decode(b.sublist(off, off + joinRefSize));
          off += joinRefSize;
          final topic = utf8.decode(b.sublist(off, off + topicSize));
          off += topicSize;
          final event = utf8.decode(b.sublist(off, off + eventSize));
          off += eventSize;
          final data = Uint8List.sublistView(b, off);
          return DecodedMessage(
            joinRef: joinRef,
            ref: null,
            topic: topic,
            event: event,
            binary: data,
          );
        }
      case _kindReply:
        {
          final joinRefSize = b[1];
          final refSize = b[2];
          final topicSize = b[3];
          final statusSize = b[4];
          var off = 5;
          final joinRef = utf8.decode(b.sublist(off, off + joinRefSize));
          off += joinRefSize;
          final ref = utf8.decode(b.sublist(off, off + refSize));
          off += refSize;
          final topic = utf8.decode(b.sublist(off, off + topicSize));
          off += topicSize;
          final status = utf8.decode(b.sublist(off, off + statusSize));
          off += statusSize;
          final data = Uint8List.sublistView(b, off);
          return DecodedMessage(
            joinRef: joinRef,
            ref: ref,
            topic: topic,
            event: 'phx_reply',
            binary: data,
            replyStatus: status,
          );
        }
      case _kindBroadcast:
        {
          final topicSize = b[1];
          final eventSize = b[2];
          var off = 3;
          final topic = utf8.decode(b.sublist(off, off + topicSize));
          off += topicSize;
          final event = utf8.decode(b.sublist(off, off + eventSize));
          off += eventSize;
          final data = Uint8List.sublistView(b, off);
          return DecodedMessage(
            joinRef: null,
            ref: null,
            topic: topic,
            event: event,
            binary: data,
          );
        }
      default:
        throw FormatException('unknown Phoenix binary kind $kind');
    }
  }
}
