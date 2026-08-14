import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/connection/app_connection.dart';
import 'package:henry_wall/meridian/drawer.dart';
import 'package:henry_wall/meridian/memory_panel.dart';
import 'package:henry_wall/panels/memory_client.dart';
import 'package:henry_wall/voice/voice_controller.dart';

import '../support/fake_socket.dart';

const String _stateFrame = '[null,null,"panel:memory:henry","state",'
    '{"summary":"Likes coffee.","facts":['
    '{"id":1,"content":"Lives in Portland","source":"chat"},'
    '{"id":2,"content":"Has a dog named Biscuit","source":"chat"}'
    ']}]';

const String _emptyFactsFrame = '[null,null,"panel:memory:henry","state",'
    '{"summary":"","facts":[]}]';

void main() {
  // Same rationale as reminders_panel_test.dart / settings_panel_test.dart:
  // the socket's heartbeat is a 24h periodic Timer still pending right after
  // connect(), which races flutter_test's pending-timer invariant check if
  // left to addTearDown — so each test explicitly awaits conn.disconnect()
  // once done with the client.
  Future<(MemoryClient, AppConnection, FakeSocket)> openedClient(
      WidgetTester tester, String frame) async {
    final fake = FakeSocket(joinPushes: {'panel:memory:henry': frame});
    final conn = AppConnection(
      connector: () async => fake.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final client = MemoryClient(connection: conn);
    addTearDown(() {
      client.dispose();
      conn.dispose();
    });
    await conn.connect();
    client.open();
    await tester.pump(Duration.zero);
    return (client, conn, fake);
  }

  Future<void> pumpPanel(WidgetTester tester, MemoryClient client) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: MemoryPanelView(client: client)),
    ));
    await tester.pumpAndSettle();
  }

  // Delivers a second `state` frame on the already-open channel, simulating
  // a later server-authoritative push — e.g. the broadcast that follows the
  // user's own save, or a fact Henry added out of band while the panel is
  // open.
  Future<void> pushState(
      WidgetTester tester, FakeSocket fake, String frame) async {
    fake.ctrl.foreign.sink.add(frame);
    await tester.pump(Duration.zero);
    await tester.pump();
  }

  List<Object?> lastPush(FakeSocket fake) {
    final frame = jsonDecode(fake.sent.last as String) as List<dynamic>;
    return [frame[2], frame[3], frame[4]];
  }

  bool anyPushOf(FakeSocket fake, String event) => fake.sent
      .map((f) => jsonDecode(f as String) as List<dynamic>)
      .any((p) => p[3] == event);

  testWidgets('the copy renders verbatim from the server', (tester) async {
    final (client, conn, _) = await openedClient(tester, _emptyFactsFrame);
    await pumpPanel(tester, client);

    expect(find.text('Rolling summary'), findsOneWidget);
    expect(find.text('Profile facts'), findsOneWidget);
    expect(find.text('No facts yet.'), findsOneWidget);
    expect(find.text('Forget me'), findsOneWidget);

    // The two placeholders carry a typographic apostrophe and an ellipsis
    // character — read straight off the live decoration rather than via
    // find.text (which depends on the field being empty/settled), so this
    // asserts the exact string regardless of hint-fade timing.
    final summaryField =
        tester.widget<TextField>(find.byKey(MemoryPanelView.summaryFieldKey));
    expect(summaryField.decoration?.hintText,
        "(nothing yet — we'll build this as we talk)");
    final addFactField =
        tester.widget<TextField>(find.byKey(MemoryPanelView.addFactKey));
    expect(
        addFactField.decoration?.hintText, 'Add something I should remember…');

    await conn.disconnect();
  });

  testWidgets('the confirm text is built from the assistant name',
      (tester) async {
    final (client, conn, fake) = await openedClient(tester, _emptyFactsFrame);
    await pumpPanel(tester, client);

    await tester.tap(find.text('Forget me'));
    await tester.pumpAndSettle();
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

  testWidgets('confirming Forget me pushes forget_me', (tester) async {
    final (client, conn, fake) = await openedClient(tester, _emptyFactsFrame);
    await pumpPanel(tester, client);

    await tester.tap(find.text('Forget me'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(lastPush(fake), ['panel:memory:henry', 'forget_me', {}]);

    await conn.disconnect();
  });

  testWidgets('the summary field shows the server\'s text', (tester) async {
    final (client, conn, _) = await openedClient(tester, _stateFrame);
    await pumpPanel(tester, client);

    expect(find.text('Likes coffee.'), findsOneWidget);

    await conn.disconnect();
  });

  testWidgets(
      'a state push while the summary field is focused leaves its text alone',
      (tester) async {
    final (client, conn, fake) = await openedClient(tester, _stateFrame);
    await pumpPanel(tester, client);
    expect(find.text('Likes coffee.'), findsOneWidget);

    await tester.tap(find.byKey(MemoryPanelView.summaryFieldKey));
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.hasFocus, isTrue,
        reason: 'sanity: the tap must actually have focused the field');

    const nextFrame = '[null,null,"panel:memory:henry","state",'
        '{"summary":"Overwritten by the server.","facts":[]}]';
    await pushState(tester, fake, nextFrame);

    // This is the assertion that must fail if the hasFocus guard is
    // removed: the text must NOT have changed, not merely "some other
    // assertion elsewhere still holds".
    expect(find.text('Overwritten by the server.'), findsNothing,
        reason: 'a state push must not yank text out from under the user');
    expect(find.text('Likes coffee.'), findsOneWidget);

    await conn.disconnect();
  });

  testWidgets('a state push while unfocused updates the summary text',
      (tester) async {
    final (client, conn, fake) = await openedClient(tester, _stateFrame);
    await pumpPanel(tester, client);
    expect(find.text('Likes coffee.'), findsOneWidget);

    const nextFrame = '[null,null,"panel:memory:henry","state",'
        '{"summary":"Fresh from the server.","facts":[]}]';
    await pushState(tester, fake, nextFrame);

    expect(find.text('Fresh from the server.'), findsOneWidget);
    expect(find.text('Likes coffee.'), findsNothing);

    await conn.disconnect();
  });

  testWidgets('Save pushes save_summary with the field\'s text',
      (tester) async {
    final (client, conn, fake) = await openedClient(tester, _stateFrame);
    await pumpPanel(tester, client);

    await tester.enterText(
        find.byKey(MemoryPanelView.summaryFieldKey), 'A new summary.');
    await tester.tap(find.text('Save'));
    await tester.pump();

    expect(lastPush(fake), [
      'panel:memory:henry',
      'save_summary',
      {'summary': 'A new summary.'}
    ]);

    await conn.disconnect();
  });

  testWidgets(
      'the add-fact field pushes add_fact with its text and clears on success',
      (tester) async {
    final (client, conn, fake) = await openedClient(tester, _emptyFactsFrame);
    await pumpPanel(tester, client);

    await tester.enterText(
        find.byKey(MemoryPanelView.addFactKey), 'Likes tea.');
    await tester.tap(find.text('Add'));
    await tester.pump();

    expect(lastPush(fake), [
      'panel:memory:henry',
      'add_fact',
      {'content': 'Likes tea.'}
    ]);
    expect(
        tester
            .widget<TextField>(find.byKey(MemoryPanelView.addFactKey))
            .controller!
            .text,
        isEmpty,
        reason: 'a successful add clears the field');

    await conn.disconnect();
  });

  testWidgets('a blank add-fact does not push', (tester) async {
    final (client, conn, fake) = await openedClient(tester, _emptyFactsFrame);
    await pumpPanel(tester, client);

    await tester.enterText(find.byKey(MemoryPanelView.addFactKey), '   ');
    await tester.tap(find.text('Add'));
    await tester.pump();

    expect(anyPushOf(fake, 'add_fact'), isFalse,
        reason: 'whitespace-only content must not push');
    expect(
        tester
            .widget<TextField>(find.byKey(MemoryPanelView.addFactKey))
            .controller!
            .text,
        '   ',
        reason: 'a refused add must keep the field\'s text, not clear it');

    await conn.disconnect();
  });

  testWidgets('No facts yet. shows only when facts are empty', (tester) async {
    final (emptyClient, emptyConn, _) =
        await openedClient(tester, _emptyFactsFrame);
    await pumpPanel(tester, emptyClient);
    expect(find.text('No facts yet.'), findsOneWidget);
    await emptyConn.disconnect();

    final (client, conn, _) = await openedClient(tester, _stateFrame);
    await pumpPanel(tester, client);
    expect(find.text('No facts yet.'), findsNothing);
    expect(find.text('Lives in Portland'), findsOneWidget);
    expect(find.text('Has a dog named Biscuit'), findsOneWidget);
    await conn.disconnect();
  });

  testWidgets('each fact row\'s ✕ pushes delete_fact with that row\'s id',
      (tester) async {
    final (client, conn, fake) = await openedClient(tester, _stateFrame);
    await pumpPanel(tester, client);

    await tester.tap(find.byKey(const ValueKey('memory-delete-fact-1')));
    await tester.pump();
    expect(
        lastPush(fake),
        [
          'panel:memory:henry',
          'delete_fact',
          {'id': 1}
        ],
        reason: 'the first row\'s ✕ must push its own id');

    await tester.tap(find.byKey(const ValueKey('memory-delete-fact-2')));
    await tester.pump();
    expect(
        lastPush(fake),
        [
          'panel:memory:henry',
          'delete_fact',
          {'id': 2}
        ],
        reason:
            'the second row\'s ✕ must push its own id, not the first row\'s');

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
    final client = MemoryClient(connection: conn);
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

  testWidgets('a focused field stays on screen under a keyboard inset',
      (tester) async {
    // The brief's literal snippet assumes physical == logical pixels (a
    // FakeViewPadding of 300 reads straight through to an 800-tall logical
    // screen). On this installed Flutter (3.44), `FlutterView.viewInsets`
    // (and `tester.view.viewInsets`) are PHYSICAL, and this test binding's
    // default `devicePixelRatio` is 3.0 — so a 300 physical inset is only
    // 100 logical unless the ratio is pinned to 1. Pinning it here keeps
    // the brief's own arithmetic ("800 - 300") literally true rather than
    // silently testing a different, unintended inset. Likewise
    // `tester.binding.setSurfaceSize` (used elsewhere in this file's sibling
    // drawer_test.dart) only reshapes the render surface, not
    // `MediaQuery.of(context).size` — this view's own keyboard-avoidance
    // code reads `MediaQuery.size`, so the test must drive the same source
    // the widget reads: `tester.view.physicalSize`.
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.resetPhysicalSize);

    // Enough facts that the add-fact field's UNSCROLLED position is already
    // well past the fold — otherwise this assertion could pass by accident
    // on a short panel that never needed to scroll in the first place, which
    // would not actually be exercising the keyboard-avoidance code at all.
    final manyFacts = List.generate(
        14,
        (i) => {
              'id': i + 1,
              'content': 'Fact number $i, long enough to take a full line',
              'source': 'chat',
            });
    final longFrame = jsonEncode([
      null,
      null,
      'panel:memory:henry',
      'state',
      {'summary': 'Likes coffee.', 'facts': manyFacts},
    ]);
    final (client, conn, _) = await openedClient(tester, longFrame);

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);

    await tester.pumpWidget(MaterialApp(
      home: MeridianDrawer(
        title: 'Memory',
        animation: const AlwaysStoppedAnimation<double>(1),
        onClose: () {},
        child: MemoryPanelView(client: client),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.showKeyboard(find.byKey(MemoryPanelView.addFactKey));
    await tester.pumpAndSettle();

    final box = tester.getRect(find.byKey(MemoryPanelView.addFactKey));
    expect(box.bottom, lessThanOrEqualTo(800 - 300),
        reason: 'the field must scroll clear of the keyboard, not sit '
            'behind it');

    await conn.disconnect();
  });

  testWidgets(
      'the summary field also stays on screen under a keyboard inset '
      '(landscape)', (tester) async {
    // The summary field is the very FIRST thing in the panel (right behind
    // the drawer's fixed header), so on a portrait phone — tall screen,
    // proportionally short keyboard — its unscrolled position never reaches
    // anywhere close to the keyboard-covered zone: nothing sits above it
    // that could push it down there, and no realistic keyboard covers
    // enough of an 800-tall screen to reach a field sitting at y ~= 180.
    // Piling on content (facts, a huge summary) does not change that; it
    // only pushes fields BELOW the summary section down. The scenario where
    // this field genuinely needs the same keyboard-avoidance the add-fact
    // field gets is a SHORT viewport — landscape phone orientation, which
    // this app supports (no orientation lock; CLAUDE.md lists Android
    // phone+tablet as a target) — where the keyboard covers a much larger
    // fraction of a much shorter screen. Verified empirically: an 800x360
    // landscape screen with a 220-tall keyboard (both realistic — many
    // Android phones are ~360 logical px wide, i.e. that tall in landscape;
    // 220 is an ordinary landscape keyboard-with-suggestions height) leaves
    // only the top 140px clear, and the field's OWN unscrolled bottom (181)
    // already sits below that — so this is not a manufactured fixture, it
    // is the field's real, unmodified position in a real supported
    // orientation.
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(800, 360);
    addTearDown(tester.view.resetPhysicalSize);

    final (client, conn, _) = await openedClient(tester, _stateFrame);

    tester.view.viewInsets = const FakeViewPadding(bottom: 220);
    addTearDown(tester.view.resetViewInsets);

    await tester.pumpWidget(MaterialApp(
      home: MeridianDrawer(
        title: 'Memory',
        animation: const AlwaysStoppedAnimation<double>(1),
        onClose: () {},
        child: MemoryPanelView(client: client),
      ),
    ));
    await tester.pumpAndSettle();

    // Sanity: confirm the hazard is real BEFORE the fix gets a chance to
    // act, i.e. the field's own natural position is already past the fold.
    final unfocused =
        tester.getRect(find.byKey(MemoryPanelView.summaryFieldKey));
    expect(unfocused.bottom, greaterThan(360 - 220),
        reason: 'sanity: the field must start out behind the keyboard line, '
            'or this test could pass without the fix ever running');

    await tester.showKeyboard(find.byKey(MemoryPanelView.summaryFieldKey));
    await tester.pumpAndSettle();

    final box = tester.getRect(find.byKey(MemoryPanelView.summaryFieldKey));
    expect(box.bottom, lessThanOrEqualTo(360 - 220),
        reason: 'the summary field must scroll clear of the keyboard too, '
            'not sit behind it');

    await conn.disconnect();
  });
}
