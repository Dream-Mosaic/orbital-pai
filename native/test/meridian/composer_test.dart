import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/meridian/composer.dart';
import 'package:orbital_pai/meridian/hero_icon.dart';
import 'package:orbital_pai/meridian/hold_to_talk.dart';

/// heroicons are SVGs, not IconData, so `find.byIcon` does not apply.
Finder findHero(HeroIcon icon) =>
    find.byWidgetPredicate((w) => w is HeroIconView && w.icon == icon);

void main() {
  late List<String> sent;
  late bool accept;

  setUp(() {
    sent = <String>[];
    accept = true;
  });

  Widget host({bool pttEnabled = false}) => MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ComposerDock(
              pttEnabled: pttEnabled,
              pttHeld: false,
              onPttPress: () {},
              onPttRelease: () {},
              onSend: (text) {
                sent.add(text);
                return accept;
              },
            ),
          ),
        ),
      );

  bool fieldFocused(WidgetTester tester) =>
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus;

  String fieldText(WidgetTester tester) =>
      tester.widget<EditableText>(find.byType(EditableText)).controller.text;

  Future<void> openComposer(WidgetTester tester) async {
    await tester.tap(find.byKey(ComposerDock.keyboardKey));
    await tester.pumpAndSettle();
  }

  testWidgets('the tray keeps hold-to-talk, with a keyboard key beside it',
      (tester) async {
    await tester.pumpWidget(host());
    expect(find.byType(HoldToTalkBar), findsOneWidget);
    expect(findHero(HeroIcon.chatBubbleBottomCenterText), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets(
      'the keyboard key swaps the tray for a focused composer — PTT off or not',
      (tester) async {
    for (final ptt in [false, true]) {
      await tester.pumpWidget(host(pttEnabled: ptt));
      await openComposer(tester);

      expect(find.byType(HoldToTalkBar), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
      expect(fieldFocused(tester), isTrue, reason: 'ptt=$ptt');

      // reset for the next pass
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('the keyboard send action submits, clears and keeps focus',
      (tester) async {
    await tester.pumpWidget(host());
    await openComposer(tester);

    await tester.enterText(find.byType(TextField), 'what is the weather');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();

    expect(sent, ['what is the weather']);
    expect(fieldText(tester), isEmpty);
    expect(fieldFocused(tester), isTrue,
        reason: 'a follow-up should not need another tap on the field');
  });

  testWidgets('the send key submits too', (tester) async {
    await tester.pumpWidget(host());
    await openComposer(tester);

    await tester.enterText(find.byType(TextField), 'hello');
    await tester.tap(find.byKey(ComposerDock.sendKey));
    await tester.pump();

    expect(sent, ['hello']);
    expect(fieldText(tester), isEmpty);
  });

  testWidgets('a blank message sends nothing', (tester) async {
    await tester.pumpWidget(host());
    await openComposer(tester);

    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.byKey(ComposerDock.sendKey));
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();

    expect(sent, isEmpty);
  });

  testWidgets('a send the controller refused keeps the draft', (tester) async {
    accept = false; // e.g. not joined: nothing left the device
    await tester.pumpWidget(host());
    await openComposer(tester);

    await tester.enterText(find.byType(TextField), 'hello');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();

    expect(sent, ['hello']);
    expect(fieldText(tester), 'hello');
  });

  testWidgets('the mic key swaps back to the tray', (tester) async {
    await tester.pumpWidget(host());
    await openComposer(tester);

    await tester.tap(find.byKey(ComposerDock.micKey));
    await tester.pumpAndSettle();

    expect(find.byType(HoldToTalkBar), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('the field grows with its text, to a cap', (tester) async {
    await tester.pumpWidget(host());
    await openComposer(tester);
    final one = tester.getSize(find.byType(TextField)).height;

    await tester.enterText(
        find.byType(TextField), List.filled(40, 'many words').join(' '));
    await tester.pump();
    final capped = tester.getSize(find.byType(TextField)).height;

    expect(capped, greaterThan(one));
    expect(tester.widget<TextField>(find.byType(TextField)).maxLines, 4);
  });
}
