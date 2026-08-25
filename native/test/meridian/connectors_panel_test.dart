import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/connection/app_connection.dart';
import 'package:henry_wall/meridian/connectors_panel.dart';
import 'package:henry_wall/panels/connectors_client.dart';

import '../support/fake_socket.dart';

Map<String, Object?> _conn({
  required int accountId,
  required String email,
  required String connector,
  required String label,
  required String access,
  bool isDefault = false,
  bool showsDefault = false,
  bool onlyGrant = true,
}) =>
    {
      'account_id': accountId,
      'email': email,
      'connector': connector,
      'label': label,
      'access': access,
      'is_default': isDefault,
      'shows_default': showsDefault,
      'only_grant': onlyGrant,
    };

String _stateFrame(List<Map<String, Object?>> connections) => jsonEncode([
      null,
      null,
      'panel:connectors:henry',
      'state',
      {'connections': connections},
    ]);

/// Answer a frame the client just pushed, echoing its own ref so the socket
/// routes the reply back to that channel. Duplicated from
/// connectors_client_test.dart (same rationale as `_conn`/`_stateFrame`
/// above): FakeSocket only auto-answers phx_join, so this is how a test
/// drives a handler's reply.
void replyTo(FakeSocket fake, String event, String status,
    Map<String, dynamic> response) {
  final frame = fake.textFrames.lastWhere((p) => p[3] == event);
  fake.ctrl.foreign.sink.add(jsonEncode([
    frame[0],
    frame[1],
    frame[2],
    'phx_reply',
    {'status': status, 'response': response},
  ]));
}

void main() {
  // Same rationale as memory_panel_test.dart / reminders_panel_test.dart /
  // voice_lock_panel_test.dart: the socket's heartbeat is a 24h periodic
  // Timer still pending right after connect(), which races flutter_test's
  // pending-timer invariant check if left to addTearDown — so each test
  // explicitly awaits conn.disconnect() once done with the client.
  Future<(ConnectorsClient, AppConnection, FakeSocket)> openedClient(
      WidgetTester tester, String frame) async {
    final fake = FakeSocket(joinPushes: {'panel:connectors:henry': frame});
    final conn = AppConnection(
      connector: () async => fake.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final client = ConnectorsClient(connection: conn);
    addTearDown(() {
      client.dispose();
      conn.dispose();
    });
    await conn.connect();
    client.open();
    await tester.pump(Duration.zero);
    return (client, conn, fake);
  }

  Future<void> pumpPanel(WidgetTester tester, ConnectorsClient client) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ConnectorsPanelView(client: client)),
    ));
    await tester.pumpAndSettle();
  }

  List<Object?> lastPush(FakeSocket fake) {
    final frame = jsonDecode(fake.sent.last as String) as List<dynamic>;
    return [frame[2], frame[3], frame[4]];
  }

  testWidgets('the copy renders verbatim from the server', (tester) async {
    final (client, conn, _) = await openedClient(
      tester,
      _stateFrame([
        _conn(
          accountId: 1,
          email: 'a@b.com',
          connector: 'calendar',
          label: 'Google Calendar',
          access: 'read',
        ),
      ]),
    );
    await pumpPanel(tester, client);

    expect(find.text('Google Calendar'), findsOneWidget);
    expect(find.text('(a@b.com)'), findsOneWidget);
    expect(find.text('read'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);
    expect(find.text('+ Connect account'), findsOneWidget);

    await conn.disconnect();
  });

  testWidgets('renders SizedBox.shrink() while client.state is null',
      (tester) async {
    // No joinPushes entry for the topic: the join reply arrives but no
    // `state` frame ever does, so client.state stays null — the drawer can
    // open before the panel's first push lands.
    final fake = FakeSocket(joinPushes: const {});
    final conn = AppConnection(
      connector: () async => fake.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final client = ConnectorsClient(connection: conn);
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
    final shrunk = tester.widgetList<SizedBox>(find.descendant(
      of: find.byType(ConnectorsPanelView),
      matching: find.byType(SizedBox),
    ));
    expect(
      shrunk.where((s) => s.width == 0 && s.height == 0 && s.child == null),
      isNotEmpty,
      reason: 'must render an actual SizedBox.shrink(), not just "nothing '
          'throws"',
    );

    await conn.disconnect();
  });

  testWidgets('No connections. shows only when the list is empty',
      (tester) async {
    final (emptyClient, emptyConn, _) =
        await openedClient(tester, _stateFrame(const []));
    await pumpPanel(tester, emptyClient);
    expect(find.text('No connections.'), findsOneWidget);
    await emptyConn.disconnect();

    final (client, conn, _) = await openedClient(
      tester,
      _stateFrame([
        _conn(
          accountId: 1,
          email: 'a@b.com',
          connector: 'calendar',
          label: 'Google Calendar',
          access: 'read',
        ),
      ]),
    );
    await pumpPanel(tester, client);
    expect(find.text('No connections.'), findsNothing);
    expect(find.text('Google Calendar'), findsOneWidget);
    await conn.disconnect();
  });

  group('the default badge/button appear only when shows_default', () {
    // Three cases, not two — a mutation that ORs the two conditions (e.g.
    // `if (c.showsDefault || c.isDefault)`) passes any single case but fails
    // at least one of these three.
    testWidgets(
        'shows_default: false, is_default: true shows NEITHER default nor '
        'Set default', (tester) async {
      final (client, conn, _) = await openedClient(
        tester,
        _stateFrame([
          _conn(
            accountId: 1,
            email: 'a@b.com',
            connector: 'calendar',
            label: 'Google Calendar',
            access: 'write',
            isDefault: true,
            showsDefault: false,
          ),
        ]),
      );
      await pumpPanel(tester, client);

      expect(find.text('default'), findsNothing);
      expect(find.text('Set default'), findsNothing);

      await conn.disconnect();
    });

    testWidgets(
        'shows_default: true, is_default: true shows default and NOT Set '
        'default', (tester) async {
      final (client, conn, _) = await openedClient(
        tester,
        _stateFrame([
          _conn(
            accountId: 1,
            email: 'a@b.com',
            connector: 'calendar',
            label: 'Google Calendar',
            access: 'write',
            isDefault: true,
            showsDefault: true,
          ),
        ]),
      );
      await pumpPanel(tester, client);

      expect(find.text('default'), findsOneWidget);
      expect(find.text('Set default'), findsNothing);

      await conn.disconnect();
    });

    testWidgets(
        'shows_default: true, is_default: false shows Set default and NOT '
        'default', (tester) async {
      final (client, conn, _) = await openedClient(
        tester,
        _stateFrame([
          _conn(
            accountId: 1,
            email: 'a@b.com',
            connector: 'calendar',
            label: 'Google Calendar',
            access: 'write',
            isDefault: false,
            showsDefault: true,
          ),
        ]),
      );
      await pumpPanel(tester, client);

      expect(find.text('Set default'), findsOneWidget);
      expect(find.text('default'), findsNothing);

      await conn.disconnect();
    });
  });

  testWidgets(
      "tapping a row's Set default pushes set_default with that row's own "
      'account_id, not a hardcoded one', (tester) async {
    final (client, conn, fake) = await openedClient(
      tester,
      _stateFrame([
        _conn(
          accountId: 11,
          email: 'a@b.com',
          connector: 'calendar',
          label: 'Google Calendar',
          access: 'write',
          showsDefault: true,
        ),
        _conn(
          accountId: 22,
          email: 'c@d.com',
          connector: 'gmail',
          label: 'Gmail',
          access: 'read',
          showsDefault: true,
        ),
      ]),
    );
    await pumpPanel(tester, client);
    fake.sent.clear();

    // Tap the SECOND row's Set default. A single-row test cannot tell a
    // per-row id from a hardcoded one — this can, because tapping the
    // second row must push the second row's id, not the first's.
    await tester.tap(find.byKey(ConnectorsPanelView.setDefaultKey(22)));
    await tester.pump();

    expect(lastPush(fake), [
      'panel:connectors:henry',
      'set_default',
      {'account_id': 22},
    ]);

    await conn.disconnect();
  });

  testWidgets(
      "tapping a row's Disconnect pushes disconnect with that row's own "
      'account_id AND connector, not hardcoded ones', (tester) async {
    final (client, conn, fake) = await openedClient(
      tester,
      _stateFrame([
        _conn(
          accountId: 11,
          email: 'a@b.com',
          connector: 'calendar',
          label: 'Google Calendar',
          access: 'write',
        ),
        _conn(
          accountId: 22,
          email: 'c@d.com',
          connector: 'gmail',
          label: 'Gmail',
          access: 'read',
        ),
      ]),
    );
    await pumpPanel(tester, client);
    fake.sent.clear();

    // Tap the SECOND row's Disconnect. A hardcoded connector (e.g. always
    // 'calendar') would fail this: the second row is 'gmail'.
    await tester.tap(find.byKey(ConnectorsPanelView.disconnectKey(22, 'gmail')));
    await tester.pump();

    expect(lastPush(fake), [
      'panel:connectors:henry',
      'disconnect',
      {'account_id': 22, 'connector': 'gmail'},
    ]);

    await conn.disconnect();
  });

  testWidgets(
      'rows render in the order the server sent them, not re-sorted by '
      'email or label', (tester) async {
    // Emails are deliberately the REVERSE of label order (gmail's email
    // sorts after calendar's) — the same fixture shape connectors_client_
    // test.dart uses for the same reason: the two candidate orderings must
    // actively disagree, or a client-side sort mutation would slip through
    // undetected (a prior fixture on this same plan sorted identically
    // under both keys and the assertion was decorative).
    final (client, conn, _) = await openedClient(
      tester,
      _stateFrame([
        _conn(
          accountId: 3,
          email: 'z@b.com',
          connector: 'gmail',
          label: 'Gmail',
          access: 'read',
        ),
        _conn(
          accountId: 4,
          email: 'a@d.com',
          connector: 'calendar',
          label: 'Google Calendar',
          access: 'write',
        ),
      ]),
    );
    await pumpPanel(tester, client);

    final gmailTop = tester.getRect(find.text('Gmail')).top;
    final calendarTop = tester.getRect(find.text('Google Calendar')).top;
    expect(gmailTop, lessThan(calendarTop),
        reason: 'the server sent Gmail (z@b.com) first — a client-side '
            're-sort by label or email would put Google Calendar first '
            'instead');

    await conn.disconnect();
  });

  group('the two dead ends explain themselves', () {
    testWidgets(
        'tapping + Connect account shows the explanation and pushes NOTHING',
        (tester) async {
      final (client, conn, fake) = await openedClient(
        tester,
        _stateFrame([
          _conn(
            accountId: 1,
            email: 'a@b.com',
            connector: 'calendar',
            label: 'Google Calendar',
            access: 'read',
          ),
        ]),
      );
      await pumpPanel(tester, client);
      fake.sent.clear();

      await tester.tap(find.byKey(ConnectorsPanelView.connectKey));
      await tester.pumpAndSettle();

      expect(find.text(kConnectAccountMessage), findsOneWidget);
      expect(fake.textFrames, isEmpty,
          reason: 'a dead end explains itself; it must never also push — '
              'connecting an account is an OAuth round trip, not a local '
              'write');

      await conn.disconnect();
    });

    testWidgets(
        'tapping Disconnect on an only_grant: false row shows '
        'kReduceAccessMessage and pushes NOTHING', (tester) async {
      final (client, conn, fake) = await openedClient(
        tester,
        _stateFrame([
          _conn(
            accountId: 1,
            email: 'a@b.com',
            connector: 'calendar',
            label: 'Google Calendar',
            access: 'write',
            onlyGrant: false,
          ),
        ]),
      );
      await pumpPanel(tester, client);
      fake.sent.clear();

      await tester
          .tap(find.byKey(ConnectorsPanelView.disconnectKey(1, 'calendar')));
      await tester.pumpAndSettle();

      expect(find.text(kReduceAccessMessage), findsOneWidget);
      expect(fake.textFrames, isEmpty,
          reason: 'this is the local fork — a round trip whose only '
              'possible answer is needs_web is a round trip worth skipping');

      await conn.disconnect();
    });

    testWidgets(
        'tapping Disconnect on an only_grant: true row pushes disconnect '
        'and shows NO dialog', (tester) async {
      final (client, conn, fake) = await openedClient(
        tester,
        _stateFrame([
          _conn(
            accountId: 1,
            email: 'a@b.com',
            connector: 'calendar',
            label: 'Google Calendar',
            access: 'write',
            onlyGrant: true,
          ),
        ]),
      );
      await pumpPanel(tester, client);
      fake.sent.clear();

      await tester
          .tap(find.byKey(ConnectorsPanelView.disconnectKey(1, 'calendar')));
      await tester.pump();

      expect(lastPush(fake), [
        'panel:connectors:henry',
        'disconnect',
        {'account_id': 1, 'connector': 'calendar'},
      ]);
      expect(find.byType(AlertDialog), findsNothing);

      await conn.disconnect();
    });

    testWidgets(
        'a server needs_web reply shows kReduceAccessMessage — the '
        'stale-client path, a defence distinct from the local fork above',
        (tester) async {
      final (client, conn, fake) = await openedClient(
        tester,
        _stateFrame([
          _conn(
            accountId: 1,
            email: 'a@b.com',
            connector: 'calendar',
            label: 'Google Calendar',
            access: 'write',
            onlyGrant: true, // a stale panel: the server disagrees below.
          ),
        ]),
      );
      await pumpPanel(tester, client);

      await tester
          .tap(find.byKey(ConnectorsPanelView.disconnectKey(1, 'calendar')));
      await tester.pump();
      replyTo(fake, 'disconnect', 'error', {'reason': 'needs_web'});
      await tester.pumpAndSettle();

      expect(find.text(kReduceAccessMessage), findsOneWidget);

      await conn.disconnect();
    });

    testWidgets('a bad_request reply shows NO dialog', (tester) async {
      final (client, conn, fake) = await openedClient(
        tester,
        _stateFrame([
          _conn(
            accountId: 1,
            email: 'a@b.com',
            connector: 'calendar',
            label: 'Google Calendar',
            access: 'write',
            onlyGrant: true,
          ),
        ]),
      );
      await pumpPanel(tester, client);

      await tester
          .tap(find.byKey(ConnectorsPanelView.disconnectKey(1, 'calendar')));
      await tester.pump();
      replyTo(fake, 'disconnect', 'error', {'reason': 'bad_request'});
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);

      await conn.disconnect();
    });

    testWidgets('a killed socket shows no dialog', (tester) async {
      final (client, conn, fake) = await openedClient(
        tester,
        _stateFrame([
          _conn(
            accountId: 1,
            email: 'a@b.com',
            connector: 'calendar',
            label: 'Google Calendar',
            access: 'write',
            onlyGrant: true,
          ),
        ]),
      );
      await pumpPanel(tester, client);

      await tester
          .tap(find.byKey(ConnectorsPanelView.disconnectKey(1, 'calendar')));
      await tester.pump();
      await fake.kill();
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);

      await conn.disconnect();
    });

    testWidgets(
        'the dialog is dismissible and acks: OK closes it, and a later '
        'rebuild does not reopen it', (tester) async {
      final (client, conn, fake) = await openedClient(
        tester,
        _stateFrame([
          _conn(
            accountId: 1,
            email: 'a@b.com',
            connector: 'calendar',
            label: 'Google Calendar',
            access: 'write',
            onlyGrant: true,
          ),
        ]),
      );
      await pumpPanel(tester, client);

      await tester
          .tap(find.byKey(ConnectorsPanelView.disconnectKey(1, 'calendar')));
      await tester.pump();
      replyTo(fake, 'disconnect', 'error', {'reason': 'needs_web'});
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);

      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(client.needsWeb, isFalse);

      // Force a rebuild the same way a live server would — another `state`
      // frame — and make sure the acked flag does not reopen the dialog.
      fake.ctrl.foreign.sink.add(_stateFrame([
        _conn(
          accountId: 1,
          email: 'a@b.com',
          connector: 'calendar',
          label: 'Google Calendar',
          access: 'write',
          onlyGrant: true,
        ),
      ]));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing,
          reason: 'an un-acked flag would reopen the dialog on every '
              'rebuild');

      await conn.disconnect();
    });

    testWidgets(
        'no text inherits the missing-Material underline, on the panel or '
        'in either dialog', (tester) async {
      // The same guard settings_drawer_host_test.dart:526-546 uses — this
      // bug has shipped twice in this codebase.
      void expectNoUnderline() {
        final painted = tester.widgetList<RichText>(find.byType(RichText));
        expect(painted, isNotEmpty);
        for (final rich in painted) {
          final style = (rich.text as TextSpan).style;
          expect(
              style?.decoration ?? TextDecoration.none, TextDecoration.none,
              reason: 'decoration leaked into "${rich.text.toPlainText()}"');
        }
      }

      final (client, conn, _) = await openedClient(
        tester,
        _stateFrame([
          _conn(
            accountId: 1,
            email: 'a@b.com',
            connector: 'calendar',
            label: 'Google Calendar',
            access: 'write',
            onlyGrant: false,
          ),
        ]),
      );
      await pumpPanel(tester, client);
      expectNoUnderline(); // The panel itself.

      await tester.tap(find.byKey(ConnectorsPanelView.connectKey));
      await tester.pumpAndSettle();
      expectNoUnderline(); // kConnectAccountMessage's dialog.

      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      await tester
          .tap(find.byKey(ConnectorsPanelView.disconnectKey(1, 'calendar')));
      await tester.pumpAndSettle();
      expectNoUnderline(); // kReduceAccessMessage's dialog.

      await conn.disconnect();
    });
  });
}
