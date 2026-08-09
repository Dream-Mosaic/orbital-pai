import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/connection/app_connection.dart';
import 'package:henry_wall/meridian/reminders_panel.dart';
import 'package:henry_wall/panels/reminders_client.dart';

import '../support/fake_socket.dart';

const String _stateFrame =
    '[null,null,"panel:reminders:henry","state",'
    '{"due":[{"id":42,"body":"bins out","due_label":"Aug 9 7:30am",'
    '"recurrence_label":"every Tue","household":true,"kind":"followup"}],'
    '"upcoming":[{"id":43,"body":"call the vet","due_label":"Aug 11 9:00am",'
    '"recurrence_label":null,"household":false,"kind":"reminder"}]}]';

const String _emptyFrame =
    '[null,null,"panel:reminders:henry","state",{"due":[],"upcoming":[]}]';

void main() {
  // Returns both the client AND its connection: the socket's heartbeat is a
  // 24h periodic Timer that is still pending right after connect(), and
  // addTearDown runs AFTER flutter_test's own pending-timer invariant check —
  // see the equivalent note in meridian/voice_screen_test.dart. So each test
  // must explicitly `await conn.disconnect()` in-body once it is done with
  // the client, rather than leaving the socket teardown to addTearDown.
  Future<(RemindersClient, AppConnection, FakeSocket)> openedClient(
      WidgetTester tester, String frame) async {
    final fake = FakeSocket(joinPushes: {'panel:reminders:henry': frame});
    final conn = AppConnection(
      connector: () async => fake.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final client = RemindersClient(connection: conn);
    addTearDown(() {
      client.dispose();
      conn.dispose();
    });
    await conn.connect();
    client.open();
    await tester.pump(Duration.zero);
    return (client, conn, fake);
  }

  Future<void> pumpPanel(WidgetTester tester, RemindersClient client) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: RemindersPanelView(client: client)),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('both sections render with the server\'s labels', (tester) async {
    final (client, conn, _) = await openedClient(tester, _stateFrame);
    await pumpPanel(tester, client);

    expect(find.text('Needs your attention'), findsOneWidget);
    expect(find.text('Upcoming'), findsOneWidget);
    expect(find.text('bins out'), findsOneWidget);
    expect(find.text('call the vet'), findsOneWidget);
    expect(find.text('Aug 9 7:30am'), findsOneWidget);
    expect(find.text('every Tue'), findsOneWidget,
        reason: 'the cadence badge is the server\'s string, not one we rebuilt');
    expect(find.text('shared'), findsOneWidget);
    expect(find.text('follow-up'), findsOneWidget);
    expect(find.text('Nothing scheduled.'), findsNothing,
        reason: 'there is an upcoming row; the empty-state copy must not '
            'render unconditionally alongside it');

    await conn.disconnect();
  });

  testWidgets('the attention section is hidden when nothing is due',
      (tester) async {
    final (client, conn, _) = await openedClient(tester, _emptyFrame);
    await pumpPanel(tester, client);

    expect(find.text('Needs your attention'), findsNothing);
    expect(find.text('Upcoming'), findsOneWidget);
    expect(find.text('Nothing scheduled.'), findsOneWidget);

    await conn.disconnect();
  });

  testWidgets('only a due row offers an ack', (tester) async {
    final (client, conn, _) = await openedClient(tester, _stateFrame);
    await pumpPanel(tester, client);
    // One due row, one upcoming row; only the due one gets the tick.
    expect(find.byKey(const ValueKey('ack-42')), findsOneWidget);
    expect(find.byKey(const ValueKey('ack-43')), findsNothing);
    expect(find.byKey(const ValueKey('dismiss-42')), findsOneWidget);
    expect(find.byKey(const ValueKey('dismiss-43')), findsOneWidget);

    await conn.disconnect();
  });

  testWidgets('the panel rebuilds when the client pushes new state',
      (tester) async {
    final (client, conn, _) = await openedClient(tester, _stateFrame);
    await pumpPanel(tester, client);
    expect(find.text('bins out'), findsOneWidget);

    client.close();
    await tester.pumpAndSettle();

    expect(find.text('bins out'), findsNothing,
        reason: 'the view listens to the client, it does not snapshot it');

    await conn.disconnect();
  });

  testWidgets('the tick acks and the cross dismisses — not swapped',
      (tester) async {
    // The presence/absence tests above only pin WHICH rows get a control, not
    // what tapping it actually does. A build that wires ✓ to dismiss() and ✕
    // to ack() would pass every other test in this file, so this one taps the
    // real buttons and reads the raw frame the client pushed onto the wire.
    final (client, conn, fake) = await openedClient(tester, _stateFrame);
    await pumpPanel(tester, client);

    List<Object?> lastPush() {
      final frame =
          jsonDecode(fake.sent.last as String) as List<dynamic>;
      return [frame[2], frame[3], frame[4]];
    }

    await tester.tap(find.byKey(const ValueKey('ack-42')));
    await tester.pump();
    expect(lastPush(), ['panel:reminders:henry', 'ack', {'id': 42}],
        reason: 'the tick on a due row must push ack, not dismiss');

    await tester.tap(find.byKey(const ValueKey('dismiss-42')));
    await tester.pump();
    expect(lastPush(), ['panel:reminders:henry', 'dismiss', {'id': 42}],
        reason: 'the cross on a due row must push dismiss, not ack');

    await tester.tap(find.byKey(const ValueKey('dismiss-43')));
    await tester.pump();
    expect(lastPush(), ['panel:reminders:henry', 'dismiss', {'id': 43}],
        reason: 'the cross on an upcoming row must push its own id');

    await conn.disconnect();
  });
}
