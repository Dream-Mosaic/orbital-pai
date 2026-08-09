import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/phoenix/phoenix_socket.dart';
import 'package:stream_channel/stream_channel.dart';

/// Decodes what the client wrote, so assertions read as protocol rather than as
/// string matching.
List<dynamic> sent(Object frame) => jsonDecode(frame as String) as List<dynamic>;

/// `[join_ref, ref, topic, event, payload]`
String topicOf(Object frame) => sent(frame)[2] as String;
String eventOf(Object frame) => sent(frame)[3] as String;
String refOf(Object frame) => sent(frame)[1] as String;

/// Decodes an OUTBOUND binary push the way the Elixir V2 serializer does.
///
/// It cannot go through `V2Serializer.decode`: that one decodes INBOUND frames,
/// and a server→client push has no ref, so its push branch has no field for the
/// one `encodeBinary` writes. This reads `encodeBinary`'s own documented
/// layout: `[kind=0, jrLen, refLen, topicLen, evLen, jr, ref, topic, event,
/// payload]`.
({String joinRef, String ref, String topic, String event, List<int> payload})
    sentBinary(Object frame) {
  final b = frame as Uint8List;
  expect(b[0], 0, reason: 'a client push is kind 0');
  final sizes = [b[1], b[2], b[3], b[4]];
  var off = 5;
  String take(int n) {
    final s = utf8.decode(b.sublist(off, off + n));
    off += n;
    return s;
  }

  final joinRef = take(sizes[0]);
  final ref = take(sizes[1]);
  final topic = take(sizes[2]);
  final event = take(sizes[3]);
  return (
    joinRef: joinRef,
    ref: ref,
    topic: topic,
    event: event,
    payload: b.sublist(off),
  );
}

String okReply(String ref, String topic) => jsonEncode(
    [null, ref, topic, 'phx_reply', {'status': 'ok', 'response': {}}]);
String errReply(String ref, String topic) => jsonEncode(
    [null, ref, topic, 'phx_reply', {'status': 'error', 'response': {'reason': 'unauthorized'}}]);
String push(String topic, String event, Map<String, dynamic> payload) =>
    jsonEncode([null, null, topic, event, payload]);

void main() {
  late StreamChannelController<dynamic> ctrl;
  late List<dynamic> wire;
  late PhoenixSocket socket;

  setUp(() {
    ctrl = StreamChannelController<dynamic>(sync: true);
    wire = <dynamic>[];
    ctrl.foreign.stream.listen(wire.add);
    socket = PhoenixSocket(ctrl.local, heartbeatInterval: const Duration(days: 1));
    socket.start();
  });

  /// Answer every outstanding phx_join on the wire.
  Future<void> ackJoins() async {
    for (final f in wire.where((f) => eventOf(f) == 'phx_join')) {
      ctrl.foreign.sink.add(okReply(refOf(f), topicOf(f)));
    }
    await pumpEventQueue();
  }

  test('two channels on one socket route to the right listener', () async {
    final voice = socket.channel('voice:henry');
    final panel = socket.channel('panel:reminders:1');
    await ackJoins();

    final heardVoice = <String>[];
    final heardPanel = <String>[];
    voice.messages.listen((m) => heardVoice.add(m.event));
    panel.messages.listen((m) => heardPanel.add(m.event));

    ctrl.foreign.sink.add(push('voice:henry', 'speak_start', {'source': 'brain'}));
    ctrl.foreign.sink.add(push('panel:reminders:1', 'reminders:state', {'due': []}));
    await pumpEventQueue();

    expect(heardVoice, ['speak_start'],
        reason: 'a panel frame must not reach the conversation');
    expect(heardPanel, ['reminders:state']);
  });

  test('a reply routes to the channel that sent the push', () async {
    final voice = socket.channel('voice:henry');
    final panel = socket.channel('panel:reminders:1');
    await ackJoins();

    final heardVoice = <String>[];
    final heardPanel = <String>[];
    voice.messages.listen((m) => heardVoice.add(m.event));
    panel.messages.listen((m) => heardPanel.add(m.event));

    wire.clear();
    panel.push('reminders:ack', {'id': 42});
    final ref = refOf(wire.single);
    // Phoenix addresses the reply to the topic, but a socket that routed by
    // insertion order (or to "the first channel") would hand it to voice.
    ctrl.foreign.sink.add(okReply(ref, 'panel:reminders:1'));
    await pumpEventQueue();

    expect(heardVoice, isEmpty);
    expect(heardPanel, ['phx_reply']);
  });

  test('a reply is matched by the ref of the push that sent it, not by its own topic label', () async {
    final voice = socket.channel('voice:henry');
    final panel = socket.channel('panel:reminders:1');
    await ackJoins();

    final heardVoice = <String>[];
    final heardPanel = <String>[];
    voice.messages.listen((m) => heardVoice.add(m.event));
    panel.messages.listen((m) => heardPanel.add(m.event));

    wire.clear();
    panel.push('reminders:ack', {'id': 42});
    final ref = refOf(wire.single);
    // A reply is correlated to the request that sent it by ref; a socket that
    // instead re-derived the destination from the reply's own topic field
    // would misdeliver this to voice.
    ctrl.foreign.sink.add(okReply(ref, 'voice:henry'));
    await pumpEventQueue();

    expect(heardVoice, isEmpty,
        reason: 'the reply belongs to the pusher (panel), not to whatever topic label rides along');
    expect(heardPanel, ['phx_reply']);
  });

  test('a refused channel join leaves the socket and its siblings alive', () async {
    final voice = socket.channel('voice:henry');
    final panel = socket.channel('panel:reminders:1');

    for (final f in wire.where((f) => eventOf(f) == 'phx_join')) {
      if (topicOf(f) == 'voice:henry') {
        ctrl.foreign.sink.add(okReply(refOf(f), topicOf(f)));
      } else {
        ctrl.foreign.sink.add(errReply(refOf(f), topicOf(f)));
      }
    }
    await pumpEventQueue();

    await expectLater(panel.onJoin, throwsA(isA<StateError>()));
    expect(await voice.onJoin, isA<Map<String, dynamic>>(),
        reason: 'a refused PANEL must never tear down the conversation');
    expect(voice.isJoined, isTrue);
    expect(socket.debugHeartbeatActive, isTrue,
        reason: 'the socket is still healthy — only one channel was refused');
  });

  test('a refused channel is de-registered, so the topic can be retried', () async {
    // channel() hands back the existing handle for an open topic, so a refused
    // channel left in the registry is handed to every later caller for the life
    // of the socket: dead, un-rejoinable, and with nothing on the wire to show
    // for the retry. Only matters once a topic CAN be refused without taking
    // the socket with it — i.e. now that panels exist.
    final panel = socket.channel('panel:reminders:1');
    var done = false;
    panel.messages.listen((_) {}, onDone: () => done = true);

    ctrl.foreign.sink.add(errReply(refOf(wire.single), 'panel:reminders:1'));
    await pumpEventQueue();

    expect(done, isTrue,
        reason: 'a channel nothing will ever route to again must say so');

    wire.clear();
    final retry = socket.channel('panel:reminders:1');
    expect(identical(retry, panel), isFalse,
        reason: 'the corpse used to be handed back instead of a fresh channel');
    expect(wire.map((f) => eventOf(f as Object)), ['phx_join'],
        reason: 'a retry has to reach the wire, not stop at a stale registry entry');
  });

  test('transport death fails every pending join', () async {
    final voice = socket.channel('voice:henry');
    final panel = socket.channel('panel:reminders:1');

    await ctrl.foreign.sink.close();
    await pumpEventQueue();

    await expectLater(voice.onJoin, throwsA(isA<StateError>()));
    await expectLater(panel.onJoin, throwsA(isA<StateError>()));
  });

  test('onClose fires once when the transport dies', () async {
    var closes = 0;
    socket.onClose.listen((_) => closes++);
    await ctrl.foreign.sink.close();
    await pumpEventQueue();
    expect(closes, 1);
    // Used to be VoiceController's job (it close()d the dead client by hand);
    // a socket that tears itself down owns this now, and a leaked
    // Timer.periodic keeps calling sink.add on a dead socket every 30s forever.
    expect(socket.debugHeartbeatActive, isFalse,
        reason: 'a transport death must cancel the heartbeat, not just the joins');
  });

  test('leave() stops delivery to that channel only', () async {
    final voice = socket.channel('voice:henry');
    final panel = socket.channel('panel:reminders:1');
    await ackJoins();

    final heardVoice = <String>[];
    final heardPanel = <String>[];
    voice.messages.listen((m) => heardVoice.add(m.event));
    panel.messages.listen((m) => heardPanel.add(m.event));

    await panel.leave();
    ctrl.foreign.sink.add(push('panel:reminders:1', 'reminders:state', {'due': []}));
    ctrl.foreign.sink.add(push('voice:henry', 'speak_start', {'source': 'brain'}));
    await pumpEventQueue();

    expect(heardPanel, isEmpty, reason: 'a closed panel must stop receiving state');
    expect(heardVoice, ['speak_start']);
  });

  test('leave() tells the server, so it stops pushing', () async {
    final panel = socket.channel('panel:reminders:1');
    await ackJoins();
    wire.clear();
    await panel.leave();
    expect(wire.map((f) => eventOf(f)), contains('phx_leave'));
    expect(topicOf(wire.first), 'panel:reminders:1');
  });

  test('each channel pushes under its own join_ref', () async {
    final voice = socket.channel('voice:henry');
    final panel = socket.channel('panel:reminders:1');
    await ackJoins();
    wire.clear();

    voice.push('ptt', {'enabled': true});
    panel.push('reminders:open', const {});

    final voiceJoinRef = sent(wire[0])[0] as String;
    final panelJoinRef = sent(wire[1])[0] as String;
    expect(voiceJoinRef, isNot(panelJoinRef),
        reason: 'Phoenix rejects a frame whose join_ref does not match its topic');
  });

  test('binary frames carry their own topic and join_ref', () async {
    // Mic audio is the ONLY binary push we make, and Phoenix drops a frame
    // whose join_ref does not match the topic it joined under — so getting
    // either wrong makes the device silently deaf while everything else about
    // the session still looks healthy. A sibling channel is open so that
    // "whatever the socket happened to pick" is not right by luck.
    final voice = socket.channel('voice:henry');
    socket.channel('panel:reminders:1');
    await ackJoins();
    final voiceJoinRef = refOf(wire.firstWhere(
        (f) => eventOf(f) == 'phx_join' && topicOf(f) == 'voice:henry'));
    final panelJoinRef = refOf(wire.firstWhere(
        (f) => eventOf(f) == 'phx_join' && topicOf(f) == 'panel:reminders:1'));
    wire.clear();

    voice.pushBinary('audio', Uint8List.fromList([1, 2, 3]));

    final frame = sentBinary(wire.single as Object);
    expect(frame.topic, 'voice:henry');
    expect(frame.joinRef, voiceJoinRef,
        reason: 'Phoenix drops a frame whose join_ref is not the one this topic '
            'joined under — the mic goes nowhere');
    expect(frame.joinRef, isNot(panelJoinRef));
    expect(frame.event, 'audio');
    expect(frame.payload, <int>[1, 2, 3]);
    expect(frame.ref, isNot(voiceJoinRef),
        reason: 'each push gets a fresh ref; only join_ref is reused');
  });

  test('emits a heartbeat text frame on the interval', () async {
    // The shared `socket` from setUp() is deliberately pinned at a 1-day
    // interval so it never fires during the other tests here — so this needs
    // its own transport and a short interval to actually observe a beat land
    // on the wire. A socket that silently stops heart-beating looks connected
    // right up until Phoenix closes it around the 60s server timeout.
    final ctrl2 = StreamChannelController<dynamic>(sync: true);
    final wire2 = <dynamic>[];
    ctrl2.foreign.stream.listen(wire2.add);
    final hbSocket =
        PhoenixSocket(ctrl2.local, heartbeatInterval: const Duration(milliseconds: 20));
    hbSocket.start();

    await Future<void>.delayed(const Duration(milliseconds: 70));

    final heartbeats =
        wire2.whereType<String>().map(sent).where((f) => f[3] == 'heartbeat').toList();
    expect(heartbeats, isNotEmpty,
        reason: 'a socket that stops heart-beating is closed by Phoenix at ~60s');
    final hb = heartbeats.first;
    expect(hb[0], isNull, reason: 'a heartbeat carries no join_ref');
    expect(hb[2], 'phoenix');
    expect(hb[4], <String, dynamic>{});

    await hbSocket.close();
  });

  test('close() closes every channel and cancels the heartbeat', () async {
    final voice = socket.channel('voice:henry');
    final panel = socket.channel('panel:reminders:1');
    await ackJoins();

    var voiceDone = false, panelDone = false;
    voice.messages.listen((_) {}, onDone: () => voiceDone = true);
    panel.messages.listen((_) {}, onDone: () => panelDone = true);

    await socket.close();
    await pumpEventQueue();

    expect(voiceDone, isTrue);
    expect(panelDone, isTrue);
    expect(socket.debugHeartbeatActive, isFalse,
        reason: 'a leaked Timer.periodic keeps the whole socket graph alive');
  });
}
