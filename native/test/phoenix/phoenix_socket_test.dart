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
    final voice = socket.channel('voice:henry');
    await ackJoins();
    wire.clear();
    voice.pushBinary('audio', Uint8List.fromList([1, 2, 3]));
    expect(wire.single, isA<Uint8List>());
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
