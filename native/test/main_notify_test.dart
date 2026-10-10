import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/connection/app_connection.dart';
import 'package:orbital_pai/main.dart';

import 'support/fake_browser_session.dart';
import 'support/fake_notifier.dart';
import 'support/fake_socket.dart';

/// The PRODUCTION wiring of background notifications — `main.dart`'s
/// `_buildShell` — driven through a real [HenryHome] on a fake socket.
///
/// `background_notices_test.dart` pins the decisions and
/// `voice_controller_notify_test.dart` the controller hook; neither can see
/// whether the shell actually builds the notices, hands them to the
/// controller, registers them for lifecycle changes and asks for the
/// permission. A seam that supplies its own wiring is how `onRejected` once
/// shipped fully tested and completely inert.
///
/// As in main_routing_test.dart: never `pumpAndSettle` (the orb animates
/// forever), and always pass a connection.
void main() {
  late FakeNotifier notifier;

  Future<FakeSocket> pumpHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    FlutterSecureStoragePlatform.instance =
        TestFlutterSecureStoragePlatform(<String, String>{});
    notifier = FakeNotifier();
    final fake = FakeSocket();
    final conn = AppConnection(
      connector: () async => fake.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    await tester.pumpWidget(MaterialApp(
      home: HenryHome(
        connection: conn,
        session: FakeBrowserSession(),
        notifier: notifier,
      ),
    ));
    await tester.pump();
    await tester.pump();
    return fake;
  }

  void serverPush(FakeSocket fake, String event, Map<String, dynamic> payload) =>
      fake.ctrl.foreign.sink.add(jsonEncode([null, null, 'voice:henry', event, payload]));

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  testWidgets('the shell asks for the notification permission once it is up',
      (tester) async {
    await pumpHome(tester);
    expect(notifier.permissionRequests, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(notifier.permissionRequests, 1, reason: 'once, not per frame');
    await unmount(tester);
  });

  testWidgets('backgrounded, a pushed message reaches the shade; back in front, '
      'it is taken down', (tester) async {
    final fake = await pumpHome(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    addTearDown(() =>
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));

    serverPush(fake, 'speak_start', {'source': 'message', 'text': 'Message from Tanya —'});
    serverPush(fake, 'speak_start', {'source': 'brain', 'text': "Dinner's ready."});
    await tester.pump();
    expect(notifier.active.values.single.title, 'Message from Tanya');
    expect(notifier.active.values.single.body, "Dinner's ready.");

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(notifier.active, isEmpty);
    await unmount(tester);
  });

  testWidgets('tearing the shell down takes its notifications with it', (tester) async {
    final fake = await pumpHome(tester);
    // `inactive`, not `paused`: the test binding stops producing frames while
    // paused, so the unmount below would never rebuild the tree. Inactive
    // counts as away all the same.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    addTearDown(() =>
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
    serverPush(fake, 'timers', {
      'timers': [
        {'id': 1, 'label': 'pasta', 'state': 'ringing', 'duration_ms': 60000, 'remaining_ms': 0},
      ],
    });
    await tester.pump();
    expect(notifier.active, hasLength(1));

    await unmount(tester);
    expect(notifier.active, isEmpty);
  });
}
