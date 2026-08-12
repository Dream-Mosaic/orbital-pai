import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/connection/app_connection.dart';
import 'package:henry_wall/meridian/settings_panel.dart';
import 'package:henry_wall/panels/settings_client.dart';
import 'package:henry_wall/voice/voice_controller.dart';

import '../support/fake_socket.dart';

const String _stateFrame = '[null,null,"panel:settings:henry","state",'
    '{"default_abi":true,"default_ptt":false,"voice_activation":true,'
    '"briefing_time":null,"relock_seconds":15,"app_version":"0.4.19"}]';

const String _briefingOnFrame = '[null,null,"panel:settings:henry","state",'
    '{"default_abi":true,"default_ptt":false,"voice_activation":true,'
    '"briefing_time":"07:00","relock_seconds":15,"app_version":"0.4.19"}]';

void main() {
  // Same rationale as reminders_panel_test.dart: the socket's heartbeat is a
  // 24h periodic Timer still pending right after connect(), which races
  // flutter_test's pending-timer invariant check if left to addTearDown — so
  // each test explicitly awaits conn.disconnect() once done with the client.
  Future<(SettingsClient, AppConnection, FakeSocket)> openedClient(
      WidgetTester tester, String frame) async {
    final fake = FakeSocket(joinPushes: {'panel:settings:henry': frame});
    final conn = AppConnection(
      connector: () async => fake.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final client = SettingsClient(connection: conn);
    addTearDown(() {
      client.dispose();
      conn.dispose();
    });
    await conn.connect();
    client.open();
    await tester.pump(Duration.zero);
    return (client, conn, fake);
  }

  Future<void> pumpPanel(WidgetTester tester, SettingsClient client) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SettingsPanelView(client: client)),
    ));
    await tester.pumpAndSettle();
  }

  List<Object?> lastPush(FakeSocket fake) {
    final frame = jsonDecode(fake.sent.last as String) as List<dynamic>;
    return [frame[2], frame[3], frame[4]];
  }

  bool anyPushOf(FakeSocket fake, String event) => fake.sent
      .map((f) => jsonDecode(f as String) as List<dynamic>)
      .any((p) => p[3] == event);

  testWidgets('the copy renders verbatim from the server', (tester) async {
    final (client, conn, _) = await openedClient(tester, _stateFrame);
    await pumpPanel(tester, client);

    expect(find.text('Voice'), findsOneWidget);
    expect(find.text('Default ABI (allow barge-in)'), findsOneWidget);
    expect(find.text('Default PTT (push-to-talk)'), findsOneWidget);
    expect(find.text('Voice activation (say the wake word; wall only)'),
        findsOneWidget);
    expect(find.text('Morning briefing (spoken your first turn that morning)'),
        findsOneWidget);
    expect(find.text('Danger zone'), findsOneWidget);
    expect(find.text('About'), findsOneWidget);
    expect(find.text('P.A.I v0.4.19'), findsOneWidget);

    await conn.disconnect();
  });

  testWidgets('the toggles reflect state: ABI on, PTT off', (tester) async {
    final (client, conn, _) = await openedClient(tester, _stateFrame);
    await pumpPanel(tester, client);

    final abi =
        tester.widget<Switch>(find.byKey(const ValueKey('toggle-default_abi')));
    final ptt =
        tester.widget<Switch>(find.byKey(const ValueKey('toggle-default_ptt')));
    expect(abi.value, isTrue);
    expect(ptt.value, isFalse);

    await conn.disconnect();
  });

  testWidgets('Briefing time is absent when briefing_time is null',
      (tester) async {
    final (client, conn, _) = await openedClient(tester, _stateFrame);
    await pumpPanel(tester, client);

    expect(find.text('Briefing time'), findsNothing);

    await conn.disconnect();
  });

  testWidgets('Briefing time is present when briefing_time is set',
      (tester) async {
    final (client, conn, _) = await openedClient(tester, _briefingOnFrame);
    await pumpPanel(tester, client);

    expect(find.text('Briefing time'), findsOneWidget);

    await conn.disconnect();
  });

  testWidgets('the lockdown row shows the relock seconds with its s suffix',
      (tester) async {
    final (client, conn, _) = await openedClient(tester, _stateFrame);
    await pumpPanel(tester, client);

    expect(find.text('Lockdown timeout (wall)'), findsOneWidget);
    expect(find.text('15s'), findsOneWidget);

    await conn.disconnect();
  });

  testWidgets('flipping the PTT switch pushes set_pref default_ptt true',
      (tester) async {
    final (client, conn, fake) = await openedClient(tester, _stateFrame);
    await pumpPanel(tester, client);

    await tester.tap(find.byKey(const ValueKey('toggle-default_ptt')));
    await tester.pump();

    expect(lastPush(fake), [
      'panel:settings:henry',
      'set_pref',
      {'pref': 'default_ptt', 'value': true},
    ]);

    await conn.disconnect();
  });

  testWidgets(
      'Clear conversation shows the web\'s confirm text; dismissing it '
      'pushes nothing', (tester) async {
    final (client, conn, fake) = await openedClient(tester, _stateFrame);
    await pumpPanel(tester, client);

    await tester.tap(find.text('Clear conversation'));
    await tester.pumpAndSettle();
    expect(find.text('Clear this conversation?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(anyPushOf(fake, 'clear_turns'), isFalse,
        reason: 'dismissing the confirm dialog must push nothing');

    await conn.disconnect();
  });

  testWidgets('confirming Clear conversation pushes clear_turns',
      (tester) async {
    final (client, conn, fake) = await openedClient(tester, _stateFrame);
    await pumpPanel(tester, client);

    await tester.tap(find.text('Clear conversation'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(lastPush(fake), ['panel:settings:henry', 'clear_turns', {}]);

    await conn.disconnect();
  });

  testWidgets(
      'Wipe memory shows a confirm built from the assistant name; dismissing '
      'it pushes nothing', (tester) async {
    final (client, conn, fake) = await openedClient(tester, _stateFrame);
    await pumpPanel(tester, client);

    await tester.tap(find.text('Wipe memory'));
    await tester.pumpAndSettle();
    // Built from VoiceController.assistantName, not a hardcoded literal, so a
    // rename of the assistant cannot silently fork the confirm copy.
    expect(
        find.text(
            'Forget everything ${VoiceController.assistantName} knows about you?'),
        findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(anyPushOf(fake, 'forget_me'), isFalse,
        reason: 'dismissing the confirm dialog must push nothing');

    await conn.disconnect();
  });

  testWidgets(
      'turning the briefing toggle on pushes set_briefing with the web\'s '
      '07:00 default', (tester) async {
    final (client, conn, fake) = await openedClient(tester, _stateFrame);
    await pumpPanel(tester, client);

    await tester.tap(find.byKey(const ValueKey('toggle-briefing')));
    await tester.pump();

    expect(lastPush(fake), [
      'panel:settings:henry',
      'set_briefing',
      {'time': '07:00'},
    ]);

    await conn.disconnect();
  });

  testWidgets(
      'turning the briefing toggle off pushes set_briefing with a null time',
      (tester) async {
    final (client, conn, fake) = await openedClient(tester, _briefingOnFrame);
    await pumpPanel(tester, client);

    await tester.tap(find.byKey(const ValueKey('toggle-briefing')));
    await tester.pump();

    expect(lastPush(fake), [
      'panel:settings:henry',
      'set_briefing',
      {'time': null},
    ]);

    await conn.disconnect();
  });

  testWidgets('the lockdown slider cannot offer a value outside 10..30',
      (tester) async {
    final (client, conn, _) = await openedClient(tester, _stateFrame);
    await pumpPanel(tester, client);

    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.min, 10);
    expect(slider.max, 30);
    expect(slider.divisions, 20);

    await conn.disconnect();
  });

  testWidgets('dragging the lockdown slider pushes set_relock exactly once',
      (tester) async {
    final (client, conn, fake) = await openedClient(tester, _stateFrame);
    await pumpPanel(tester, client);
    fake.sent.clear();

    // A single continuous drag: WidgetTester.drag() simulates a full
    // down/move/up gesture, so the Slider fires onChanged many times along
    // the way and onChangeEnd exactly once on release — that release is the
    // only moment this view is expected to push.
    await tester.drag(find.byType(Slider), const Offset(150, 0));
    await tester.pump();

    final relockPushes = fake.sent
        .map((f) => jsonDecode(f as String) as List<dynamic>)
        .where((p) => p[3] == 'set_relock')
        .toList();
    expect(relockPushes.length, 1,
        reason: 'a drag must debounce to a single write on release, not one '
            'push per pixel of travel');

    await conn.disconnect();
  });

  testWidgets('confirming Wipe memory pushes forget_me', (tester) async {
    final (client, conn, fake) = await openedClient(tester, _stateFrame);
    await pumpPanel(tester, client);

    await tester.tap(find.text('Wipe memory'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(lastPush(fake), ['panel:settings:henry', 'forget_me', {}]);

    await conn.disconnect();
  });

  testWidgets('renders without throwing before the first push lands',
      (tester) async {
    // No joinPushes entry for the topic: the join reply arrives but no
    // `state` frame ever does, so client.state stays null — the drawer can
    // open before the panel's first push lands.
    final fake = FakeSocket(joinPushes: const {});
    final conn = AppConnection(
      connector: () async => fake.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final client = SettingsClient(connection: conn);
    addTearDown(() {
      client.dispose();
      conn.dispose();
    });
    await conn.connect();
    client.open();
    await tester.pump(Duration.zero);

    expect(client.state, isNull);
    await pumpPanel(tester, client);

    expect(tester.takeException(), isNull);

    await conn.disconnect();
  });
}
