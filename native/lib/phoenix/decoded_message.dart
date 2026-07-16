import 'dart:typed_data';

class DecodedMessage {
  final String? joinRef;
  final String? ref;
  final String topic;
  final String event;
  final Map<String, dynamic>? json;
  final Uint8List? binary;
  final String? replyStatus;

  const DecodedMessage({
    this.joinRef,
    this.ref,
    required this.topic,
    required this.event,
    this.json,
    this.binary,
    this.replyStatus,
  });

  bool get isBinary => binary != null;
}
