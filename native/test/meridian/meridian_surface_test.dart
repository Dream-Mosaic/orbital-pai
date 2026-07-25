import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/meridian/meridian_surface.dart';
import 'package:henry_wall/meridian/orb_state.dart';

void main() {
  testWidgets('renders its child and survives a state change', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: MeridianSurface(
        state: OrbState.idle,
        child: Text('hello'),
      ),
    ));
    expect(find.text('hello'), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(
      home: MeridianSurface(
        state: OrbState.listening,
        child: Text('hello'),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 400)); // mid cross-fade
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 900)); // past the 0.8s fade
    expect(find.text('hello'), findsOneWidget);
  });

  testWidgets('paints every state without throwing', (tester) async {
    for (final s in OrbState.values) {
      await tester.pumpWidget(MaterialApp(
        home: MeridianSurface(state: s, child: const SizedBox.shrink()),
      ));
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.takeException(), isNull, reason: 'state $s');
    }
  });

  testWidgets('disposes cleanly while the breathe animation is running',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: MeridianSurface(state: OrbState.speaking, child: SizedBox.shrink()),
    ));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    expect(tester.takeException(), isNull);
  });
}
