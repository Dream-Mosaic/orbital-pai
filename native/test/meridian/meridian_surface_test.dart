import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/meridian/meridian_surface.dart';
import 'package:henry_wall/meridian/orb_state.dart';
import 'package:henry_wall/meridian/palette.dart';

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

  testWidgets('bleed opacity matches the palette for contrasting states',
      (tester) async {
    for (final s in [OrbState.listening, OrbState.off]) {
      await tester.pumpWidget(MaterialApp(
        home: MeridianSurface(state: s, child: const SizedBox.shrink()),
      ));
      await tester.pump(const Duration(seconds: 2)); // settle any cross-fade

      final opacityWidget =
          tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
      expect(opacityWidget.opacity, paletteFor(s).bleed, reason: 'state $s');
    }
  });

  testWidgets('bleed gradient is tinted by the palette glow colour',
      (tester) async {
    for (final s in [OrbState.listening, OrbState.off]) {
      await tester.pumpWidget(MaterialApp(
        home: MeridianSurface(state: s, child: const SizedBox.shrink()),
      ));
      await tester.pump(const Duration(seconds: 2));

      final bleedBox = tester.widget<DecoratedBox>(find.descendant(
        of: find.byType(AnimatedOpacity),
        matching: find.byType(DecoratedBox),
      ));
      final gradient = (bleedBox.decoration as BoxDecoration).gradient
          as RadialGradient;
      expect(
        gradient.colors.first,
        paletteFor(s).glow.withValues(alpha: 0.20),
        reason: 'state $s',
      );
    }
  });

  testWidgets(
      'the dark radial base is an ancestor of the sheen (sheen paints on top)',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: MeridianSurface(state: OrbState.idle, child: SizedBox.shrink()),
    ));

    bool isRadialBase(Widget w) =>
        w is DecoratedBox &&
        (w.decoration as BoxDecoration).gradient is RadialGradient &&
        ((w.decoration as BoxDecoration).gradient as RadialGradient)
                .colors
                .first ==
            const Color(0xFF090A12);

    bool isLinearSheen(Widget w) =>
        w is DecoratedBox &&
        (w.decoration as BoxDecoration).gradient is LinearGradient &&
        ((w.decoration as BoxDecoration).gradient as LinearGradient)
                .colors
                .first ==
            const Color(0x05FFFFFF);

    // The linear sheen must render as a *descendant* of the dark radial base
    // -- since a DecoratedBox paints its own decoration before its child,
    // being the descendant is what makes the sheen paint on top.
    expect(
      find.ancestor(
        of: find.byWidgetPredicate(isLinearSheen),
        matching: find.byWidgetPredicate(isRadialBase),
      ),
      findsOneWidget,
    );
  });
}
