import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:henry_wall/phoenix/phoenix_channel_client.dart';

void main() {
  late StreamChannelController<dynamic> ctrl;
  late PhoenixChannelClient client;
  late List<dynamic> serverInbox; // frames the client sent (seen on the foreign end)

  setUp(() {
    ctrl = StreamChannelController<dynamic>();
    serverInbox = [];
    ctrl.foreign.stream.listen(serverInbox.add);
    client = PhoenixChannelClient(
      ctrl.local,
      topic: 'voice:henry',
      joinPayload: {'kiosk': false},
      heartbeatInterval: const Duration(milliseconds: 50),
    );
    client.start();
  });

  test('sends a phx_join text frame on start', () async {
    await Future<void>.delayed(Duration.zero);
    expect(serverInbox, isNotEmpty);
    expect(serverInbox.first, '["1","1","voice:henry","phx_join",{"kiosk":false}]');
  });

  test('resolves onJoin when the server replies ok', () async {
    await Future<void>.delayed(Duration.zero);
    ctrl.foreign.sink.add(
        '["1","1","voice:henry","phx_reply",{"status":"ok","response":{"hello":1}}]');
    final resp = await client.onJoin;
    expect(resp, {'hello': 1});
  });

  test('dispatches a server push onto the messages stream', () async {
    await Future<void>.delayed(Duration.zero);
    final next = client.messages.firstWhere((m) => m.event == 'partial');
    ctrl.foreign.sink.add('[null,null,"voice:henry","partial",{"text":"hi"}]');
    final m = await next;
    expect(m.json!['text'], 'hi');
  });

  test('push encodes an event as a text frame with an incrementing ref', () async {
    await Future<void>.delayed(Duration.zero); // ref 1 = join
    client.push('played', {'ms': 1200});
    await Future<void>.delayed(Duration.zero);
    expect(serverInbox.last, '["1","2","voice:henry","played",{"ms":1200}]');
  });

  test('pushBinary encodes a binary audio frame (kind=0, raw bytes tail)', () async {
    await Future<void>.delayed(Duration.zero);
    client.pushBinary('audio', Uint8List.fromList([0x01, 0x02]));
    await Future<void>.delayed(Duration.zero);
    final frame = serverInbox.last;
    expect(frame, isA<Uint8List>());
    final bytes = frame as Uint8List;
    expect(bytes[0], 0); // kind push
    expect(bytes.sublist(bytes.length - 2), equals(Uint8List.fromList([0x01, 0x02])));
  });

  test('emits a heartbeat text frame on the interval', () async {
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final hb = serverInbox.whereType<String>().firstWhere(
        (f) => f.contains('"heartbeat"'), orElse: () => '');
    expect(hb, contains('[null,'));
    expect(hb, contains('"phoenix","heartbeat",{}]'));
  });

  tearDown(() async {
    await client.close();
  });
}
