import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/phoenix/v2_serializer.dart';

void main() {
  const s = V2Serializer();

  test('encodeText builds the [join_ref, ref, topic, event, payload] array', () {
    final out = s.encodeText('1', '1', 'voice:henry', 'phx_join', {'kiosk': false});
    expect(out, '["1","1","voice:henry","phx_join",{"kiosk":false}]');
  });

  test('encodeText emits null join_ref for heartbeat', () {
    final out = s.encodeText(null, '3', 'phoenix', 'heartbeat', {});
    expect(jsonDecode(out), [null, '3', 'phoenix', 'heartbeat', {}]);
  });

  test('encodeBinary matches phoenix.js binaryEncode (kind=push=0)', () {
    final payload = Uint8List.fromList([0xAA, 0xBB, 0xCC]);
    final out = s.encodeBinary('1', '2', 'voice:henry', 'audio', payload);
    final expected = <int>[
      0, // kind = push
      1, // joinRef len
      1, // ref len
      11, // topic len
      5, // event len
      0x31, // "1"
      0x32, // "2"
      ...utf8.encode('voice:henry'),
      ...utf8.encode('audio'),
      0xAA, 0xBB, 0xCC,
    ];
    expect(out, equals(Uint8List.fromList(expected)));
  });

  test('decode text phx_reply extracts status + response', () {
    final m = s.decode('["1","1","voice:henry","phx_reply",{"status":"ok","response":{}}]');
    expect(m.event, 'phx_reply');
    expect(m.replyStatus, 'ok');
    expect(m.ref, '1');
    expect(m.json!['response'], {});
    expect(m.isBinary, isFalse);
  });

  test('decode text push carries json payload', () {
    final m = s.decode('[null,null,"voice:henry","partial",{"text":"hi"}]');
    expect(m.event, 'partial');
    expect(m.json!['text'], 'hi');
    expect(m.binary, isNull);
  });

  test('decode binary push (server audio) yields raw bytes', () {
    final joinRef = utf8.encode('7');
    final topic = utf8.encode('voice:henry');
    final event = utf8.encode('audio');
    final data = <int>[0x01, 0x02, 0x03, 0x04];
    final frame = Uint8List.fromList([
      0, // kind = push
      joinRef.length,
      topic.length,
      event.length,
      ...joinRef, ...topic, ...event, ...data,
    ]);
    final m = s.decode(frame);
    expect(m.event, 'audio');
    expect(m.joinRef, '7');
    expect(m.ref, isNull);
    expect(m.isBinary, isTrue);
    expect(m.binary, equals(Uint8List.fromList(data)));
  });

  test('decode binary reply normalizes to phx_reply with status', () {
    final jr = utf8.encode('7');
    final rf = utf8.encode('9');
    final tp = utf8.encode('voice:henry');
    final st = utf8.encode('ok');
    final data = <int>[0xDE, 0xAD];
    final frame = Uint8List.fromList([
      1, jr.length, rf.length, tp.length, st.length,
      ...jr, ...rf, ...tp, ...st, ...data,
    ]);
    final m = s.decode(frame);
    expect(m.event, 'phx_reply');
    expect(m.replyStatus, 'ok');
    expect(m.ref, '9');
    expect(m.binary, equals(Uint8List.fromList(data)));
  });

  test('decode binary broadcast yields topic/event/bytes', () {
    final tp = utf8.encode('voice:henry');
    final ev = utf8.encode('audio');
    final data = <int>[0x11];
    final frame = Uint8List.fromList([
      2, tp.length, ev.length, ...tp, ...ev, ...data,
    ]);
    final m = s.decode(frame);
    expect(m.joinRef, isNull);
    expect(m.event, 'audio');
    expect(m.binary, equals(Uint8List.fromList(data)));
  });
}
