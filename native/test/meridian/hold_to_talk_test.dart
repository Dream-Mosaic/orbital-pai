import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/meridian/hold_to_talk.dart';
import 'package:henry_wall/meridian/tokens.dart';

void main() {
  Widget host({
    required bool enabled,
    required bool held,
    VoidCallback? onPress,
    VoidCallback? onRelease,
  }) =>
      MaterialApp(
        home: Scaffold(
          body: HoldToTalkBar(
            enabled: enabled,
            held: held,
            onPress: onPress ?? () {},
            onRelease: onRelease ?? () {},
          ),
        ),
      );

  testWidgets('shows the uppercase engraved label', (tester) async {
    await tester.pumpWidget(host(enabled: true, held: false));
    final style = tester.widget<Text>(find.text('HOLD TO TALK')).style!;
    expect(style.fontSize, 8.32); // 0.52rem
    expect(style.letterSpacing, closeTo(3.328, 1e-6)); // 0.4em
  });

  testWidgets('press and release fire on pointer down/up', (tester) async {
    var pressed = 0, released = 0;
    await tester.pumpWidget(host(
      enabled: true,
      held: false,
      onPress: () => pressed++,
      onRelease: () => released++,
    ));
    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(HoldToTalkBar)));
    await tester.pump();
    expect(pressed, 1);
    await gesture.up();
    await tester.pump();
    expect(released, 1);
  });

  testWidgets('a cancelled pointer releases too — a slid thumb must not stick',
      (tester) async {
    var released = 0;
    await tester.pumpWidget(host(
      enabled: true,
      held: true,
      onRelease: () => released++,
    ));
    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(HoldToTalkBar)));
    await tester.pump();
    await gesture.cancel();
    await tester.pump();
    expect(released, 1, reason: 'a stuck-open mic is the failure that started A2');
  });

  testWidgets('a disabled bar is inert', (tester) async {
    var pressed = 0;
    await tester
        .pumpWidget(host(enabled: false, held: false, onPress: () => pressed++));
    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(HoldToTalkBar)));
    await tester.pump();
    await gesture.up();
    expect(pressed, 0);
    expect(tester.widget<Text>(find.text('HOLD TO TALK')).style!.color!.a,
        closeTo(0.2, 0.01));
  });

  testWidgets('held brightens the label to --you-soft', (tester) async {
    await tester.pumpWidget(host(enabled: true, held: true));
    expect(tester.widget<Text>(find.text('HOLD TO TALK')).style!.color, M.youSoft);
  });

  testWidgets('armed-but-not-held is the dim chrome label', (tester) async {
    await tester.pumpWidget(host(enabled: true, held: false));
    expect(tester.widget<Text>(find.text('HOLD TO TALK')).style!.color!.a,
        closeTo(0.38, 0.01));
  });
}
