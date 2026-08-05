import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/meridian/header.dart';
import 'package:henry_wall/meridian/hold_to_talk.dart';
import 'package:henry_wall/meridian/hero_icon.dart';
import 'package:henry_wall/meridian/nav.dart';
import 'package:henry_wall/meridian/orb_bezel.dart';
import 'package:henry_wall/meridian/thread.dart';
import 'package:henry_wall/meridian/voice_screen.dart';
import 'package:henry_wall/phoenix/decoded_message.dart';
import 'package:henry_wall/voice/voice_controller.dart';

/// heroicons are SVGs, not IconData, so `find.byIcon` does not apply.
Finder findHero(HeroIcon icon) =>
    find.byWidgetPredicate((w) => w is HeroIconView && w.icon == icon);

void main() {
  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('the whole chrome mounts and lays out without overflow',
      (tester) async {
    phone(tester);
    final vc = VoiceController();
    addTearDown(vc.dispose);

    await tester.pumpWidget(MaterialApp(
      home: MeridianVoiceScreen(controller: vc, userName: 'David'),
    ));
    await tester.pump();

    expect(find.byType(MeridianHeader), findsOneWidget);
    expect(find.byType(OrbBezel), findsOneWidget);
    expect(find.byType(Thread), findsOneWidget);
    expect(find.byType(HoldToTalkBar), findsOneWidget);
    expect(find.byType(MeridianNav), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no text inherits the missing-Material underline', (tester) async {
    // Shipped once: with no Material ancestor, WidgetsApp's fallback
    // DefaultTextStyle applies, and our styles override its colour/size/family
    // but NOT its `decoration` — so every label wore a yellow double underline.
    // The declared style is clean either way, so this has to assert the MERGED
    // style the RichText actually paints.
    phone(tester);
    final vc = VoiceController();
    addTearDown(vc.dispose);

    await tester.pumpWidget(MaterialApp(
      home: MeridianVoiceScreen(controller: vc, userName: 'David'),
    ));
    await tester.pump();

    final painted = tester.widgetList<RichText>(find.byType(RichText));
    expect(painted, isNotEmpty);
    for (final rich in painted) {
      final style = (rich.text as TextSpan).style;
      expect(style?.decoration ?? TextDecoration.none, TextDecoration.none,
          reason: 'decoration leaked into "${rich.text.toPlainText()}"');
    }
  });

  testWidgets('a live turn flows through to the thread', (tester) async {
    phone(tester);
    final vc = VoiceController();
    addTearDown(vc.dispose);

    await tester.pumpWidget(MaterialApp(
      home: MeridianVoiceScreen(controller: vc, userName: 'David'),
    ));
    vc.debugHandleMessage(const DecodedMessage(
      topic: 'voice:henry',
      event: 'transcript',
      json: {'text': 'hello henry'},
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('hello henry'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long transcript scrolls instead of overflowing',
      (tester) async {
    phone(tester);
    final vc = VoiceController();
    addTearDown(vc.dispose);

    await tester.pumpWidget(MaterialApp(
      home: MeridianVoiceScreen(controller: vc, userName: 'David'),
    ));
    for (var i = 0; i < 40; i++) {
      vc.debugHandleMessage(DecodedMessage(
        topic: 'voice:henry',
        event: 'transcript',
        json: {'text': 'turn number $i with a reasonably long body to wrap'},
      ));
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull,
        reason: 'the thread is the only flexible row — it must absorb the growth');
  });

  testWidgets('the nav reports taps up to the host', (tester) async {
    phone(tester);
    final vc = VoiceController();
    addTearDown(vc.dispose);
    final opened = <MeridianTab>[];

    await tester.pumpWidget(MaterialApp(
      home: MeridianVoiceScreen(
        controller: vc,
        userName: 'David',
        onOpenPanel: opened.add,
      ),
    ));
    await tester.tap(findHero(MeridianTab.settings.icon));
    expect(opened, [MeridianTab.settings]);
  });

  testWidgets('the header shows the app version and user', (tester) async {
    phone(tester);
    final vc = VoiceController();
    addTearDown(vc.dispose);

    await tester.pumpWidget(MaterialApp(
      home: MeridianVoiceScreen(
        controller: vc,
        userName: 'David',
        appVersion: '9.9.9',
      ),
    ));
    expect(find.text('P.A.I V9.9.9'), findsOneWidget);
    expect(find.text('DAVID'), findsOneWidget);
    expect(find.text('HENRY'), findsOneWidget);
  });
}
