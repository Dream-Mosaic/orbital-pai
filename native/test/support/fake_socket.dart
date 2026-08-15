import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:henry_wall/phoenix/phoenix_socket.dart';
import 'package:stream_channel/stream_channel.dart';

/// One in-memory socket that answers joins, and can be killed to simulate a
/// server bounce.
class FakeSocket {
  FakeSocket({
    this.refuseJoins = false,
    this.refuseTopics = const <String>{},
    this.silentTopics = const <String>{},
    this.joinPushes = const <String, String>{},
  }) {
    ctrl.foreign.stream.listen((f) {
      sent.add(f);
      // Binary pushes (mic PCM, enrollment PCM) are not JSON and take part in
      // no join handshake. Without this, `f as String` throws INSIDE this
      // listener and takes the whole fake socket down the first time a test
      // streams audio.
      if (f is! String) return;
      final parts = jsonDecode(f) as List<dynamic>;
      if (parts[3] != 'phx_join') return;
      final topic = parts[2] as String;
      if (silentTopics.contains(topic)) return;
      final status = (refuseJoins || refuseTopics.contains(topic)) ? 'error' : 'ok';
      scheduleMicrotask(() {
        if (closed) return;
        ctrl.foreign.sink.add(jsonEncode(
            [null, parts[1], topic, 'phx_reply', {'status': status, 'response': {}}]));
        // Straight behind the reply, in the SAME turn — exactly what
        // VoiceChannel does (`set_client` inside join/3 pushes `state`,
        // `send(self(), :after_join)` pushes `history`).
        final behind = joinPushes[topic];
        if (status == 'ok' && behind != null) ctrl.foreign.sink.add(behind);
      });
    });
    socket = PhoenixSocket(ctrl.local, heartbeatInterval: const Duration(days: 1));
    socket.start();
  }

  final bool refuseJoins;

  /// Topics this server refuses; everything else joins normally.
  final Set<String> refuseTopics;

  /// Topics this server simply never answers.
  final Set<String> silentTopics;

  /// topic -> a raw frame pushed immediately behind that topic's join reply.
  final Map<String, String> joinPushes;

  final ctrl = StreamChannelController<dynamic>(sync: true);
  final sent = <dynamic>[];
  late final PhoenixSocket socket;
  bool closed = false;

  /// The text frames the client sent, decoded. Binary pushes are excluded —
  /// they are not JSON.
  List<List<dynamic>> get textFrames => sent
      .whereType<String>()
      .map((f) => jsonDecode(f) as List<dynamic>)
      .toList();

  /// The Phoenix V2 binary pushes the client sent.
  List<Uint8List> get binaryFrames => sent.whereType<Uint8List>().toList();

  List<String> get joinedTopics => textFrames
      .where((p) => p[3] == 'phx_join')
      .map((p) => p[2] as String)
      .toList();

  Future<void> kill() async {
    closed = true;
    await ctrl.foreign.sink.close();
  }
}
