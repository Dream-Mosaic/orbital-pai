import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/meridian/header.dart';
import 'package:henry_wall/meridian/tokens.dart';

void main() {
  Widget host(ConnStatus status,
          {VoidCallback? onLongPress, bool reduceMotion = false}) =>
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: Scaffold(
            body: MeridianHeader(
              assistantName: 'Henry',
              status: status,
              version: '0.1.0',
              userName: 'David',
              onVersionLongPress: onLongPress,
            ),
          ),
        ),
      );

  testWidgets('renders the wordmark, version and user', (tester) async {
    await tester.pumpWidget(host(ConnStatus.connected));
    expect(find.text('HENRY'), findsOneWidget);
    expect(find.text('P.A.I V0.1.0'), findsOneWidget);
    expect(find.text('DAVID'), findsOneWidget);
  });

  testWidgets('the wordmark carries the 0.42em tracking', (tester) async {
    await tester.pumpWidget(host(ConnStatus.connected));
    final style = tester.widget<Text>(find.text('HENRY')).style!;
    expect(style.fontSize, 15.2);
    expect(style.letterSpacing, closeTo(6.384, 1e-6));
    expect(style.fontWeight, FontWeight.w600);
  });

  testWidgets('the meta block carries the 0.3em tracking at 0.52rem',
      (tester) async {
    await tester.pumpWidget(host(ConnStatus.connected));
    final style = tester.widget<Text>(find.text('DAVID')).style!;
    expect(style.fontSize, 8.32);
    expect(style.letterSpacing, closeTo(2.496, 1e-6));
  });

  testWidgets('the dot tracks CONNECTION status', (tester) async {
    for (final s in ConnStatus.values) {
      await tester.pumpWidget(host(s));
      await tester.pump();
      final box = tester.widget<Container>(find.byKey(const ValueKey('conn-dot')));
      final decoration = box.decoration! as BoxDecoration;
      expect(decoration.color, connDotColors(s).fill, reason: '$s fill');
      expect(decoration.boxShadow!.single.color.a, closeTo(0.75, 0.01),
          reason: '$s glow alpha (box-shadow 0 0 9px dot@75%)');
      expect(decoration.boxShadow!.single.blurRadius, 9.0, reason: '$s glow blur');
    }
  });

  testWidgets('only `connecting` animates', (tester) async {
    await tester.pumpWidget(host(ConnStatus.connected));
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.transientCallbackCount, 0,
        reason: 'a steady dot — movement is reserved for reconnecting');

    await tester.pumpWidget(host(ConnStatus.connecting));
    await tester.pump();
    expect(tester.binding.transientCallbackCount, greaterThan(0));

    // ...and it stops again, rather than running for the life of the app.
    await tester.pumpWidget(host(ConnStatus.connected));
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('reduced motion holds the dot still even while connecting',
      (tester) async {
    await tester.pumpWidget(host(ConnStatus.connecting, reduceMotion: true));
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0,
        reason: 'the same accessibility contract the orb already honours');
  });

  testWidgets('long-pressing the version fires the dev hook', (tester) async {
    var fired = false;
    await tester
        .pumpWidget(host(ConnStatus.connected, onLongPress: () => fired = true));
    await tester.longPress(find.text('P.A.I V0.1.0'));
    expect(fired, isTrue,
        reason: 'PorcupineSpikeScreen must survive the debug-UI deletion');
  });
}
