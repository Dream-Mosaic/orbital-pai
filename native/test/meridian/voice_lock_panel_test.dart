import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/connection/app_connection.dart';
import 'package:henry_wall/meridian/voice_lock_panel.dart';
import 'package:henry_wall/panels/voice_lock_client.dart';

import '../support/fake_socket.dart';

String _stateFrame({
  String mode = 'off',
  List<int> enrolledSlots = const [],
  bool verifierReady = true,
  List<Map<String, dynamic>> drops = const [],
}) =>
    jsonEncode([
      null,
      null,
      'panel:voice_lock:henry',
      'state',
      {
        'user_id': 7,
        'mode': mode,
        'enrolled_slots': enrolledSlots,
        'verifier_ready': verifierReady,
        'drops': drops,
      }
    ]);

void main() {
  // Same rationale as memory_panel_test.dart / reminders_panel_test.dart /
  // settings_panel_test.dart: the socket's heartbeat is a 24h periodic Timer
  // still pending right after connect(), which races flutter_test's
  // pending-timer invariant check if left to addTearDown — so each test
  // explicitly awaits conn.disconnect() once done with the client.
  Future<
      (
        VoiceLockClient,
        AppConnection,
        FakeSocket,
        StreamController<Uint8List>
      )> openedClient(
    WidgetTester tester,
    String frame, {
    Duration clipLimit = const Duration(seconds: 12),
  }) async {
    final fake = FakeSocket(joinPushes: {'panel:voice_lock:henry': frame});
    final conn = AppConnection(
      connector: () async => fake.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final mic = StreamController<Uint8List>.broadcast();
    final client = VoiceLockClient(
      connection: conn,
      acquireMic: () async => mic.stream,
      releaseMic: () async {},
      clipLimit: clipLimit,
    );
    addTearDown(() {
      client.dispose();
      conn.dispose();
      unawaited(mic.close());
    });
    await conn.connect();
    client.open();
    await tester.pump(Duration.zero);
    return (client, conn, fake, mic);
  }

  Future<void> pumpPanel(WidgetTester tester, VoiceLockClient client) async {
    // Wrapped in a SingleChildScrollView because the real host does too
    // (drawer.dart's `Expanded(child: SingleChildScrollView(...))` around
    // its `child`) — this panel, unlike its shorter siblings
    // (memory_panel.dart, reminders_panel.dart), is tall enough with the
    // banner showing to overflow a bare fixed-height Scaffold in the test's
    // 600px surface. That overflow is a test-harness artifact, not a real
    // layout bug: on device the drawer always scrolls it, so mirroring that
    // host here (rather than shrinking assertions or padding the panel
    // itself with a scroll view it would then double up inside the real
    // drawer) is the faithful fix.
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: VoiceLockPanelView(client: client)),
      ),
    ));
    await tester.pumpAndSettle();
  }

  List<Object?> lastPush(FakeSocket fake) {
    final frame = jsonDecode(fake.sent.last as String) as List<dynamic>;
    return [frame[2], frame[3], frame[4]];
  }

  Finder cardFor(int slot) =>
      find.byKey(VoiceLockPanelView.slotKey(slot));

  // Minor from the follow-up review of 86e0ad6: the prompt strings were
  // pinned only against the test's own copies — both here (a literal
  // find.text below) and in kVoiceLockPrompts (voice_lock_panel.dart) —
  // never against the server's own @voice_lock_prompts. A server-side edit
  // to voice_modals.ex could drift silently. These are voiceprint
  // CALIBRATION INPUTS (reading a different sentence than the one enrolled
  // quietly degrades the score), so read the server source directly rather
  // than trusting a second hand copy.
  test(
      'kVoiceLockPrompts stays byte-identical to @voice_lock_prompts on the '
      'server', () {
    final source = File(
      '../server/lib/app_web/components/voice_modals.ex',
    ).readAsStringSync();
    for (final (slot, text) in kVoiceLockPrompts) {
      expect(source.contains(text), isTrue,
          reason: 'prompt $slot ("$text") no longer appears verbatim in '
              "voice_modals.ex's @voice_lock_prompts — the native copy has "
              'drifted from the server');
    }
  });

  testWidgets('the copy renders verbatim from the server', (tester) async {
    final (client, conn, _, _) = await openedClient(
      tester,
      _stateFrame(mode: 'off', enrolledSlots: const [], drops: const []),
    );
    await pumpPanel(tester, client);

    expect(find.text('Mode'), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
    expect(find.text('Shadow'), findsOneWidget);
    expect(find.text('Enforce'), findsOneWidget);
    expect(
      find.text(
          'Shadow scores every turn but blocks nothing — live with it a '
          'few days, then enforce.'),
      findsOneWidget,
    );
    expect(find.text('Enrollment — read each prompt aloud (~10s each)'),
        findsOneWidget);

    // The three enrollment prompts are calibration inputs, not decoration —
    // pasted here byte-for-byte from voice_modals.ex:686-690 (verified with
    // a Unicode dump: plain ASCII apostrophes, no em dash/curly quotes).
    expect(
      find.text(
          "Hey Remi, this is my normal speaking voice. I'm going to ask "
          'about the weather, my calendar, reminders, and the grocery '
          'list, just like I do every day.'),
      findsOneWidget,
    );
    expect(
      find.text(
          'The quick brown fox jumps over the lazy dog, while the five '
          'boxing wizards jump quickly over the frozen river behind our '
          'house.'),
      findsOneWidget,
    );
    expect(
      find.text(
          "What's on my calendar tomorrow morning? Remind me to water the "
          'garden at six, and add milk, eggs, and coffee to the '
          'groceries, please.'),
      findsOneWidget,
    );

    // No slot enrolled: all three buttons read "Record".
    expect(find.text('Record'), findsNWidgets(3));
    expect(find.text('Re-record'), findsNothing);

    expect(find.text('Recently filtered'), findsOneWidget);
    expect(find.text('Nothing filtered yet.'), findsOneWidget);

    await conn.disconnect();
  });

  testWidgets('the banner appears only when verifier_ready is false',
      (tester) async {
    const bannerText = 'Speaker model unavailable — Voice Lock is failing '
        'open (everything passes).';

    final (readyClient, readyConn, _, _) =
        await openedClient(tester, _stateFrame(verifierReady: true));
    await pumpPanel(tester, readyClient);
    expect(find.text(bannerText), findsNothing);
    await readyConn.disconnect();

    final (notReadyClient, notReadyConn, _, _) =
        await openedClient(tester, _stateFrame(verifierReady: false));
    await pumpPanel(tester, notReadyClient);
    expect(find.text(bannerText), findsOneWidget);
    await notReadyConn.disconnect();
  });

  testWidgets(
      'enrollment is still allowed while the banner is up: slot 1\'s '
      'Record button is enabled and tapping it starts a recording',
      (tester) async {
    final (client, conn, fake, _) = await openedClient(
      tester,
      _stateFrame(verifierReady: false),
    );
    await pumpPanel(tester, client);

    final gd = tester
        .widget<GestureDetector>(find.byKey(VoiceLockPanelView.recordKey(1)));
    expect(gd.onTap, isNotNull,
        reason: 'the banner must not gate enrollment — the embed fails '
            'server-side and says so, which is the intended behaviour');

    await tester.tap(find.byKey(VoiceLockPanelView.recordKey(1)));
    await tester.pump();

    expect(fake.joinedTopics, contains('enroll:7'),
        reason: 'tapping Record while the banner is up must still start '
            'a recording');

    client.close();
    // NOT pumpEventQueue(): that drains real Future.delayed/Timer chains,
    // but this whole test body runs inside flutter_test's FakeAsync zone
    // (testWidgets, not test()), where a zero-duration Timer never fires on
    // its own — it needs the fake clock advanced. pumpAndSettle() does that
    // (and is what reminders_panel_test.dart's own close()-then-settle test
    // uses), letting startRecording's aborted-cleanup `finally` (mic
    // cancel/release, channel leave) actually run to completion instead of
    // awaiting forever.
    await tester.pumpAndSettle();
    await conn.disconnect();
  });

  testWidgets(
      'the active mode button matches state.mode, and tapping Enforce '
      'pushes set_mode', (tester) async {
    final (client, conn, fake, _) =
        await openedClient(tester, _stateFrame(mode: 'shadow'));
    await pumpPanel(tester, client);

    Container containerFor(String mode) {
      final gd = tester
          .widget<GestureDetector>(find.byKey(VoiceLockPanelView.modeKey(mode)));
      return gd.child! as Container;
    }

    final active = containerFor('shadow').decoration! as BoxDecoration;
    expect(active.color, isNot(Colors.transparent),
        reason: 'the active mode button must be visually distinguished');

    final inactiveOff = containerFor('off').decoration! as BoxDecoration;
    final inactiveEnforce = containerFor('enforce').decoration! as BoxDecoration;
    expect(inactiveOff.color, Colors.transparent);
    expect(inactiveEnforce.color, Colors.transparent);

    await tester.tap(find.byKey(VoiceLockPanelView.modeKey('enforce')));
    await tester.pump();

    expect(lastPush(fake), [
      'panel:voice_lock:henry',
      'set_mode',
      {'mode': 'enforce'}
    ]);

    await conn.disconnect();
  });

  testWidgets(
      'a slot in enrolled_slots shows Re-record and ✓ enrolled; a slot '
      'that is not shows Record and neither', (tester) async {
    final (client, conn, _, _) =
        await openedClient(tester, _stateFrame(enrolledSlots: const [2]));
    await pumpPanel(tester, client);

    expect(find.text('Re-record'), findsOneWidget);
    expect(find.text('Record'), findsNWidgets(2));
    expect(find.text('✓ enrolled'), findsOneWidget);

    // Scoped: the enrolled marker belongs to slot 2's own card, not 1 or 3.
    expect(find.descendant(of: cardFor(2), matching: find.text('Re-record')),
        findsOneWidget);
    expect(find.descendant(of: cardFor(2), matching: find.text('✓ enrolled')),
        findsOneWidget);
    expect(find.descendant(of: cardFor(1), matching: find.text('✓ enrolled')),
        findsNothing);
    expect(find.descendant(of: cardFor(3), matching: find.text('✓ enrolled')),
        findsNothing);

    await conn.disconnect();
  });

  testWidgets('all three Record buttons disable while any slot is recording',
      (tester) async {
    final (client, conn, fake, _) = await openedClient(
      tester,
      _stateFrame(),
      clipLimit: const Duration(seconds: 30),
    );
    await pumpPanel(tester, client);

    GestureDetector gdFor(int slot) => tester
        .widget<GestureDetector>(find.byKey(VoiceLockPanelView.recordKey(slot)));

    expect(gdFor(1).onTap, isNotNull, reason: 'sanity: nothing recording yet');
    expect(gdFor(2).onTap, isNotNull);
    expect(gdFor(3).onTap, isNotNull);

    // Fired, not awaited: this whole test body runs inside flutter_test's
    // FakeAsync zone (testWidgets, not test()). Directly awaiting the Future
    // startRecording() returns — which itself awaits the enroll channel's
    // message-subscription cancel() inside its own `finally` — deadlocks the
    // moment a LATER, separate pump()/pumpAndSettle() call also happens in
    // the same test. Reproduced with a bare `StreamController.broadcast()`
    // and zero Phoenix code involved, so this is a flutter_test/dart:async
    // FakeAsync interaction, not a product bug (voice_lock_client_test.dart's
    // plain `test()` — real async, not FakeAsync — exercises this exact
    // `startRecording` path directly-awaited, repeatedly, with no hang).
    // Firing it and driving progress via pump()/pumpAndSettle() instead
    // sidesteps the trap entirely.
    unawaited(client.startRecording(1));
    await tester.pump();
    expect(client.recordingSlot, 1);

    // The discriminating assertion: onTap must be null for the OTHER slots
    // too, not merely "a tap on slot 2 does nothing" — the client's own
    // reentrancy guard (`_recordingSlot != null` in startRecording) would
    // silently swallow a tap on an incorrectly-enabled button too, so a
    // behavioural tap test alone cannot tell "UI disabled it" apart from
    // "the client ignored a second call." Reading onTap directly proves the
    // VIEW disabled it.
    expect(gdFor(1).onTap, isNull,
        reason: 'the recording slot itself is also disabled');
    expect(gdFor(2).onTap, isNull,
        reason: 'a non-recording slot must ALSO disable, not just the '
            'recording one');
    expect(gdFor(3).onTap, isNull);

    // Behavioural corroboration: tapping a (should-be-disabled) button
    // pushes nothing new.
    fake.sent.clear();
    await tester.tap(find.byKey(VoiceLockPanelView.recordKey(2)),
        warnIfMissed: false);
    await tester.pump();
    expect(fake.joinedTopics.where((t) => t.startsWith('enroll:')), isEmpty);

    client.close();
    // pumpAndSettle(), not a direct await of startRecording's Future — see
    // the comment above. This lets the aborted recording's cleanup `finally`
    // run without hitting the FakeAsync trap.
    await tester.pumpAndSettle();
    await conn.disconnect();
  });

  testWidgets('recording… shows against the recording slot only',
      (tester) async {
    final (client, conn, _, _) = await openedClient(
      tester,
      _stateFrame(),
      clipLimit: const Duration(seconds: 30),
    );
    await pumpPanel(tester, client);

    // Fired, not awaited — see the FakeAsync-deadlock comment on the
    // preceding test.
    unawaited(client.startRecording(2));
    await tester.pump();

    expect(
        find.descendant(of: cardFor(2), matching: find.text('recording…')),
        findsOneWidget);
    expect(
        find.descendant(of: cardFor(1), matching: find.text('recording…')),
        findsNothing);
    expect(
        find.descendant(of: cardFor(3), matching: find.text('recording…')),
        findsNothing);
    expect(find.text('recording…'), findsOneWidget);

    client.close();
    await tester.pumpAndSettle();
    await conn.disconnect();
  });

  testWidgets(
      'enrollError renders its message against its own slot and no other',
      (tester) async {
    final fake =
        FakeSocket(joinPushes: {'panel:voice_lock:henry': _stateFrame()});
    final conn = AppConnection(
      connector: () async => fake.socket,
      rejoinBackoff: const [Duration(days: 1)],
    );
    final client = VoiceLockClient(
      connection: conn,
      // Matches the web hook's own reason string for a refused mic
      // (voice_lock_client.dart's own mic_blocked path, task-5-tested).
      acquireMic: () async => throw StateError('microphone permission denied'),
      releaseMic: () async {},
      clipLimit: const Duration(milliseconds: 20),
      replyTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(() {
      client.dispose();
      conn.dispose();
    });
    await conn.connect();
    client.open();
    await tester.pump(Duration.zero);
    await pumpPanel(tester, client);

    // Fired, not awaited — see the FakeAsync-deadlock comment on the
    // "all three Record buttons disable" test above: directly awaiting
    // startRecording() here, then pumping again for the widget assertions
    // below, is exactly the shape that deadlocks.
    unawaited(client.startRecording(2));
    await tester.pumpAndSettle();

    expect(client.enrollError, (2, 'failed: mic_blocked'));
    expect(
      find.descendant(
          of: cardFor(2), matching: find.text('failed: mic_blocked')),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: cardFor(1), matching: find.text('failed: mic_blocked')),
      findsNothing,
    );
    expect(
      find.descendant(
          of: cardFor(3), matching: find.text('failed: mic_blocked')),
      findsNothing,
    );

    await conn.disconnect();
  });

  testWidgets(
      'a drop row renders decision, transcript, and score rounded to 2dp; '
      'a null score renders no score text', (tester) async {
    final (client, conn, _, _) = await openedClient(
      tester,
      _stateFrame(drops: [
        {'decision': 'would_drop', 'transcript': 'a stray line', 'score': 0.2137},
        {'decision': 'drop', 'transcript': 'music', 'score': null},
      ]),
    );
    await pumpPanel(tester, client);

    expect(find.text('would_drop'), findsOneWidget);
    expect(find.text('drop'), findsOneWidget);
    expect(find.text('a stray line'), findsOneWidget);
    expect(find.text('music'), findsOneWidget);

    expect(find.text('0.21'), findsOneWidget,
        reason: 'rounded to 2dp, not the raw 0.2137');
    expect(find.text('0.2137'), findsNothing);

    // The null-score row must render no score text at all — not "0.00",
    // which would read as a confident score on the panel people read scores
    // off during calibration.
    expect(find.text('0.00'), findsNothing);
    expect(find.text('null'), findsNothing);

    await conn.disconnect();
  });

  testWidgets('Nothing filtered yet. shows only when drops is empty',
      (tester) async {
    final (emptyClient, emptyConn, _, _) =
        await openedClient(tester, _stateFrame(drops: const []));
    await pumpPanel(tester, emptyClient);
    expect(find.text('Nothing filtered yet.'), findsOneWidget);
    await emptyConn.disconnect();

    final (client, conn, _, _) = await openedClient(
      tester,
      _stateFrame(
          drops: [
            {'decision': 'drop', 'transcript': 'x', 'score': null}
          ]),
    );
    await pumpPanel(tester, client);
    expect(find.text('Nothing filtered yet.'), findsNothing);
    expect(find.text('x'), findsOneWidget);
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
    final mic = StreamController<Uint8List>.broadcast();
    final client = VoiceLockClient(
      connection: conn,
      acquireMic: () async => mic.stream,
      releaseMic: () async {},
    );
    addTearDown(() {
      client.dispose();
      conn.dispose();
      unawaited(mic.close());
    });
    await conn.connect();
    client.open();
    await tester.pump(Duration.zero);

    expect(client.state, isNull);
    await pumpPanel(tester, client);

    expect(tester.takeException(), isNull);
    final shrunk = tester.widgetList<SizedBox>(find.descendant(
      of: find.byType(VoiceLockPanelView),
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

  // DEVIATION FROM THE BRIEF: the brief's Step 1 also asks for a
  // missing-Material-underline guard here. Not added: this file's own
  // `pumpPanel` wraps the view in `MaterialApp(home: Scaffold(body: ...))`
  // (matching memory_panel_test.dart / reminders_panel_test.dart /
  // settings_panel_test.dart), and Scaffold supplies a Material ancestor
  // unconditionally — so a guard pumped this way could never fail regardless
  // of whether the panel is correct, which is exactly the "test that passes
  // against an obviously broken implementation" anti-pattern. The real
  // hazard is host composition (a route/drawer pushed with NO Scaffold),
  // and it is already guarded where it can actually fail:
  // drawer_test.dart's generic check (any child text) and
  // settings_drawer_host_test.dart's per-layer check. drawer.dart itself
  // now wraps its child in `Material(type: MaterialType.transparency)`
  // (see its own comment), so VoiceLockPanelView inherits that guard for
  // free once it is hosted there — the same conclusion memory_panel.dart's
  // and reminders_panel.dart's own test files reached.
}
