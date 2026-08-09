import 'dart:async';
import 'dart:convert';

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
      final parts = jsonDecode(f as String) as List<dynamic>;
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

  List<String> get joinedTopics => sent
      .map((f) => jsonDecode(f as String) as List<dynamic>)
      .where((p) => p[3] == 'phx_join')
      .map((p) => p[2] as String)
      .toList();

  Future<void> kill() async {
    closed = true;
    await ctrl.foreign.sink.close();
  }
}
