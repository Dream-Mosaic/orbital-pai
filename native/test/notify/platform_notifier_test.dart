import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/notify/notifier.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('henry/notify');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  void answer(Object? Function(MethodCall) reply) {
    calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return reply(call);
    });
  }

  test('show posts id, title, body and the Android channel id', () async {
    answer((_) => null);
    await PlatformNotifier().show(
      id: 7,
      title: "Timer's done",
      body: 'Your pasta timer is up.',
      channel: NoticeChannel.alerts,
    );
    expect(calls.single.method, 'show');
    expect(calls.single.arguments, {
      'id': 7,
      'title': "Timer's done",
      'body': 'Your pasta timer is up.',
      'channel': 'henry_alerts',
    });
  });

  test('the two channels are the ids MainActivity creates', () {
    expect(NoticeChannel.alerts.id, 'henry_alerts');
    expect(NoticeChannel.messages.id, 'henry_messages');
  });

  test('cancel and cancelAll name what they cancel', () async {
    answer((_) => null);
    final n = PlatformNotifier();
    await n.cancel(3);
    await n.cancelAll();
    expect(calls.map((c) => c.method), ['cancel', 'cancelAll']);
    expect(calls.first.arguments, {'id': 3});
  });

  test('requestPermission returns what the platform granted', () async {
    answer((_) => false);
    expect(await PlatformNotifier().requestPermission(), isFalse);
    answer((_) => true);
    expect(await PlatformNotifier().requestPermission(), isTrue);
  });

  test('no plugin (desktop, tests) is a silent no-op, never a throw', () async {
    // No mock handler: the channel answers MissingPluginException.
    final n = PlatformNotifier();
    await n.show(id: 1, title: 't', body: 'b', channel: NoticeChannel.messages);
    await n.cancel(1);
    await n.cancelAll();
    expect(await n.requestPermission(), isFalse);
  });

  test('a platform error is swallowed: a notification must never take the '
      'voice screen down', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'boom');
    });
    final n = PlatformNotifier();
    await n.show(id: 1, title: 't', body: 'b', channel: NoticeChannel.alerts);
    await n.cancelAll();
    expect(await n.requestPermission(), isFalse);
  });
}
