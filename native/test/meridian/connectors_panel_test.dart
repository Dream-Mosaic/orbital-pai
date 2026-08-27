import 'dart:convert';

import 'package:flutter/material.dart' hide FormField;
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

/// One `FormField` wire entry — the shape `connectors_channel.ex`'s
/// `catalog/0` sends. `options` defaults to empty: only `choice` fields need
/// it, and `account_select` gets none from the server at all (the client
/// builds that list itself — see connectors_client.dart's `FormField` doc).
Map<String, Object?> _fieldJson({
  required String name,
  String label = '',
  required String type,
  bool required = true,
  List<Map<String, Object?>> options = const [],
}) =>
    {
      'name': name,
      'label': label,
      'type': type,
      'required': required,
      'options': options,
    };

Map<String, Object?> _optionJson(String value, [String? label]) =>
    {'value': value, 'label': label ?? value};

/// One `ConnectorSpec` wire entry.
Map<String, Object?> _catalogEntry({
  required String key,
  String label = '',
  String provider = 'google',
  String kind = 'oauth_redirect',
  List<Map<String, Object?>> fields = const [],
}) =>
    {
      'key': key,
      'label': label,
      'provider': provider,
      'kind': kind,
      'fields': fields,
    };

/// A catalog entry shaped exactly like the REAL ones `catalog/0` builds for
/// Google today (`connectors_channel.ex:140-162`): an `account_select` field
/// plus a `choice` field offering none/read/write. Used by tests that are
/// about the real Google shape specifically — the load-bearing genericity
/// test below deliberately does NOT use this, because a fixture built only
/// from this shape could not tell a generic renderer apart from one
/// hardcoded to it.
Map<String, Object?> _googleConnector(String key, String label) =>
    _catalogEntry(
      key: key,
      label: label,
      fields: [
        _fieldJson(name: 'account', label: 'Account', type: 'account_select'),
        _fieldJson(
          name: 'level',
          label: 'Access',
          type: 'choice',
          options: [
            _optionJson('none'),
            _optionJson('read'),
            _optionJson('write'),
          ],
        ),
      ],
    );

String _stateFrame(
  List<Map<String, Object?>> connections, {
  List<Map<String, Object?>> catalog = const [],
}) =>
    jsonEncode([
      null,
      null,
      'panel:connectors:henry',
      'state',
      {'connections': connections, 'catalog': catalog},
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

  group('Disconnect is unconditional now — the server decides what it means',
      () {
    // Both dead ends this panel used to explain away are real actions now
    // (see the moduledoc in connectors_panel.dart): Disconnect always
    // pushes, whether or not the row is `only_grant`. The server re-derives
    // `only_grant` itself and either deletes locally or replies with a
    // consent URL for the reduction — there is nothing left for this view to
    // fork on client-side, and no dialog left to show either way.
    testWidgets('only_grant: true pushes disconnect and shows no dialog',
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
        'only_grant: false ALSO pushes disconnect and shows no dialog — no '
        'client-side fork any more', (tester) async {
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
        'killing the socket right after a Disconnect push does not crash '
        'the panel', (tester) async {
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

      await tester
          .tap(find.byKey(ConnectorsPanelView.disconnectKey(1, 'calendar')));
      await tester.pump();
      await fake.kill();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(AlertDialog), findsNothing);

      await conn.disconnect();
    });
  });

  group('the generic grant form', () {
    testWidgets(
        'renders a connector the client has never heard of — proof the form '
        'is generic over the catalog, not hardcoded to calendar/gmail',
        (tester) async {
      // A catalog entry invented HERE — not calendar, not gmail — with its
      // own label, its own field name, and its own options. A form hardcoded
      // to Google's two connectors cannot render this under ANY selection; a
      // generic one renders it exactly like any other entry. A fixture
      // carrying only the two real Google connectors could not tell those
      // two implementations apart — this is why a real connector shares the
      // catalog here rather than being the only entry.
      final catalog = [
        _googleConnector('calendar', 'Google Calendar'),
        _catalogEntry(
          key: 'toaster',
          label: 'Toaster Squad',
          provider: 'acme',
          fields: [
            _fieldJson(
              name: 'crumb_tray',
              label: 'Crumb tray size',
              type: 'choice',
              options: [
                _optionJson('small', 'Small'),
                _optionJson('large', 'Large'),
              ],
            ),
          ],
        ),
      ];
      final (client, conn, _) = await openedClient(
          tester, _stateFrame(const [], catalog: catalog));
      await pumpPanel(tester, client);

      await tester.tap(find.byKey(ConnectorsPanelView.connectKey));
      await tester.pumpAndSettle();

      // The connector picker lists both entries by their own label...
      expect(find.text('Google Calendar'), findsOneWidget);
      expect(find.text('Toaster Squad'), findsOneWidget);
      // ...but the invented connector's own field is not drawn until IT is
      // selected — the default selection is the first catalog entry.
      expect(find.text('Crumb tray size'), findsNothing);

      await tester
          .tap(find.byKey(ConnectorsPanelView.formConnectorKey('toaster')));
      await tester.pumpAndSettle();

      expect(find.text('Crumb tray size'), findsOneWidget);
      expect(find.text('Small'), findsOneWidget);
      expect(find.text('Large'), findsOneWidget);
      // And Google's own field is gone — fields are rebuilt per selection,
      // never merged across connectors.
      expect(find.text('Access'), findsNothing);
      expect(find.text('Account'), findsNothing);

      await conn.disconnect();
    });

    testWidgets(
        'selecting a connector, an existing account and a level, then '
        'submitting, pushes exactly that grant_url payload', (tester) async {
      final catalog = [
        _googleConnector('calendar', 'Google Calendar'),
        _googleConnector('gmail', 'Gmail'),
      ];
      final (client, conn, fake) = await openedClient(
        tester,
        _stateFrame([
          _conn(
            accountId: 7,
            email: 'a@b.com',
            connector: 'calendar',
            label: 'Google Calendar',
            access: 'read',
          ),
        ], catalog: catalog),
      );
      await pumpPanel(tester, client);
      fake.sent.clear();

      await tester.tap(find.byKey(ConnectorsPanelView.connectKey));
      await tester.pumpAndSettle();

      // Every choice below is the NON-default one, so a mutation that
      // submits whatever the form opened with (first connector, "new"
      // account, first level) cannot coincidentally pass.
      await tester
          .tap(find.byKey(ConnectorsPanelView.formConnectorKey('gmail')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(ConnectorsPanelView.formOptionKey('account', '7')));
      await tester.pumpAndSettle();
      await tester.tap(
          find.byKey(ConnectorsPanelView.formOptionKey('level', 'write')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(ConnectorsPanelView.grantSubmitKey));
      await tester.pump();

      expect(lastPush(fake), [
        'panel:connectors:henry',
        'grant_url',
        {
          'connector': 'gmail',
          'fields': {'account': 7, 'level': 'write'},
        },
      ]);

      await conn.disconnect();
    });

    testWidgets(
        'the account select offers every existing account exactly once, '
        'plus a New account option', (tester) async {
      final catalog = [_googleConnector('calendar', 'Google Calendar')];
      final (client, conn, _) = await openedClient(
        tester,
        _stateFrame([
          // Account 1 holds BOTH calendar and gmail, so it appears TWICE in
          // `connections` — it must still render as exactly one row here.
          _conn(
            accountId: 1,
            email: 'a@b.com',
            connector: 'calendar',
            label: 'Google Calendar',
            access: 'read',
          ),
          _conn(
            accountId: 1,
            email: 'a@b.com',
            connector: 'gmail',
            label: 'Gmail',
            access: 'read',
          ),
          _conn(
            accountId: 2,
            email: 'c@d.com',
            connector: 'calendar',
            label: 'Google Calendar',
            access: 'write',
          ),
        ], catalog: catalog),
      );
      await pumpPanel(tester, client);

      await tester.tap(find.byKey(ConnectorsPanelView.connectKey));
      await tester.pumpAndSettle();

      expect(
          find.byKey(ConnectorsPanelView.formOptionKey('account', 'new')),
          findsOneWidget);
      expect(find.text('New Google account'), findsOneWidget);
      expect(find.byKey(ConnectorsPanelView.formOptionKey('account', '1')),
          findsOneWidget);
      expect(find.byKey(ConnectorsPanelView.formOptionKey('account', '2')),
          findsOneWidget);
      // Plain "a@b.com" (the picker's own row text) renders exactly once,
      // despite account 1 appearing twice in `connections` above.
      expect(find.text('a@b.com'), findsOneWidget);
      expect(find.text('c@d.com'), findsOneWidget);

      await conn.disconnect();
    });

    testWidgets(
        'level-shaped options come from the catalog, never a hardcoded '
        'none/read/write', (tester) async {
      final catalog = [
        _catalogEntry(
          key: 'widget',
          label: 'Widget Connector',
          fields: [
            _fieldJson(
              name: 'tier',
              label: 'Tier',
              type: 'choice',
              options: [
                _optionJson('bronze', 'Bronze'),
                _optionJson('gold', 'Gold'),
              ],
            ),
          ],
        ),
      ];
      final (client, conn, _) = await openedClient(
          tester, _stateFrame(const [], catalog: catalog));
      await pumpPanel(tester, client);

      await tester.tap(find.byKey(ConnectorsPanelView.connectKey));
      await tester.pumpAndSettle();

      expect(
          find.byKey(ConnectorsPanelView.formOptionKey('tier', 'bronze')),
          findsOneWidget);
      expect(find.byKey(ConnectorsPanelView.formOptionKey('tier', 'gold')),
          findsOneWidget);
      expect(find.text('Bronze'), findsOneWidget);
      expect(find.text('Gold'), findsOneWidget);
      // A hardcoded none/read/write set would render these regardless of
      // what the catalog actually sent.
      expect(find.text('none'), findsNothing);
      expect(find.text('read'), findsNothing);
      expect(find.text('write'), findsNothing);

      await conn.disconnect();
    });

    testWidgets(
        'an unknown field type fails visibly rather than rendering nothing',
        (tester) async {
      final catalog = [
        _catalogEntry(
          key: 'vault',
          label: 'Vault Connector',
          fields: [
            _fieldJson(name: 'passphrase', label: 'Passphrase', type: 'secret'),
          ],
        ),
      ];
      final (client, conn, _) = await openedClient(
          tester, _stateFrame(const [], catalog: catalog));
      await pumpPanel(tester, client);

      await tester.tap(find.byKey(ConnectorsPanelView.connectKey));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // Some visible text must name the field that failed to render — never
      // a silent gap where an input should be.
      expect(find.textContaining('Passphrase'), findsOneWidget);
      expect(find.textContaining('secret'), findsOneWidget);

      await conn.disconnect();
    });

    testWidgets('tapping Cancel closes the form and pushes nothing',
        (tester) async {
      final catalog = [_googleConnector('calendar', 'Google Calendar')];
      final (client, conn, fake) = await openedClient(
          tester, _stateFrame(const [], catalog: catalog));
      await pumpPanel(tester, client);

      await tester.tap(find.byKey(ConnectorsPanelView.connectKey));
      await tester.pumpAndSettle();
      fake.sent.clear();

      await tester.tap(find.byKey(ConnectorsPanelView.grantCancelKey));
      await tester.pumpAndSettle();

      expect(find.text('Add a connection'), findsNothing);
      expect(fake.textFrames, isEmpty,
          reason: 'Cancel must never push — there is nothing to submit');

      await conn.disconnect();
    });

    testWidgets(
        'the grant form copy is byte-exact with voice_modals.ex\'s '
        'connectors_panel/1', (tester) async {
      final catalog = [_googleConnector('calendar', 'Google Calendar')];
      final (client, conn, _) = await openedClient(
          tester, _stateFrame(const [], catalog: catalog));
      await pumpPanel(tester, client);

      expect(find.text('+ Connect account'), findsOneWidget);

      await tester.tap(find.byKey(ConnectorsPanelView.connectKey));
      await tester.pumpAndSettle();

      // Every one of these is copy-pasted, byte for byte (verified with a
      // Python code-point dump against voice_modals.ex, not eyeballed), from
      // the web's connectors_panel/1 grant block. All seven strings are
      // plain ASCII on the web side too — there is no U+2026/U+2014 here to
      // silently normalise.
      for (final s in const [
        'Add a connection',
        'Connector',
        'Account',
        'Access',
        'New Google account',
        'Cancel',
      ]) {
        expect(find.text(s), findsOneWidget, reason: 'copy mismatch: "$s"');
      }

      await conn.disconnect();
    });

    testWidgets(
        'killing the socket right after grant_url does not crash the panel',
        (tester) async {
      final catalog = [_googleConnector('calendar', 'Google Calendar')];
      final (client, conn, fake) = await openedClient(
          tester, _stateFrame(const [], catalog: catalog));
      await pumpPanel(tester, client);

      await tester.tap(find.byKey(ConnectorsPanelView.connectKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ConnectorsPanelView.grantSubmitKey));
      await tester.pump();
      await fake.kill();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);

      await conn.disconnect();
    });
  });

  testWidgets(
      'no text inherits the missing-Material underline, on the panel or the '
      'open grant form', (tester) async {
    // The same guard settings_drawer_host_test.dart:526-546 uses — this bug
    // has shipped twice in this codebase.
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

    final catalog = [_googleConnector('calendar', 'Google Calendar')];
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
      ], catalog: catalog),
    );
    await pumpPanel(tester, client);
    expectNoUnderline(); // The panel itself.

    await tester.tap(find.byKey(ConnectorsPanelView.connectKey));
    await tester.pumpAndSettle();
    expectNoUnderline(); // The open "Add a connection" form.

    await conn.disconnect();
  });
}
