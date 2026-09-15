import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/meridian/hero_icon.dart';
import 'package:orbital_pai/meridian/live_caption.dart';
import 'package:orbital_pai/meridian/orb_bezel.dart';
import 'package:orbital_pai/meridian/orb_painter.dart';
import 'package:orbital_pai/meridian/orb_view.dart';
import 'package:orbital_pai/meridian/tokens.dart';

/// heroicons are SVGs, not IconData, so `find.byIcon` does not apply.
Finder findHero(HeroIcon icon) =>
    find.byWidgetPredicate((w) => w is HeroIconView && w.icon == icon);

void main() {
  late OrbFrame frame;
  late List<String> taps;

  Widget host({
    bool powerOn = false,
    bool pttOn = false,
    bool abiOn = false,
    bool powerEnabled = true,
  }) =>
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 240,
              height: 240,
              child: OrbBezel(
                frame: frame,
                glow: M.you,
                caption: '',
                powerOn: powerOn,
                pttOn: pttOn,
                abiOn: abiOn,
                powerEnabled: powerEnabled,
                onPower: () => taps.add('power'),
                onClear: () => taps.add('clear'),
                onPtt: (v) => taps.add('ptt:$v'),
                onAbi: (v) => taps.add('abi:$v'),
              ),
            ),
          ),
        ),
      );

  setUp(() {
    frame = OrbFrame();
    taps = <String>[];
  });

  tearDown(() => frame.dispose());

  testWidgets('the four satellites sit on the bezel diagonals at 8%/92%',
      (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();

    final origin = tester.getTopLeft(find.byType(OrbBezel));
    Offset centreOf(HeroIcon icon) => tester.getCenter(findHero(icon)) - origin;

    // app.css: .d-power 8%/8%, .d-clear 92%/8%, .d-ptt 8%/92%, .d-abi 92%/92%
    expect(centreOf(HeroIcon.power).dx, closeTo(240 * 0.08, 0.6));
    expect(centreOf(HeroIcon.power).dy, closeTo(240 * 0.08, 0.6));
    expect(centreOf(HeroIcon.trash).dx, closeTo(240 * 0.92, 0.6));
    expect(centreOf(HeroIcon.trash).dy, closeTo(240 * 0.08, 0.6));
    expect(centreOf(HeroIcon.microphone).dx, closeTo(240 * 0.08, 0.6));
    expect(centreOf(HeroIcon.microphone).dy, closeTo(240 * 0.92, 0.6));
    expect(centreOf(HeroIcon.handRaised).dx, closeTo(240 * 0.92, 0.6));
    expect(centreOf(HeroIcon.handRaised).dy, closeTo(240 * 0.92, 0.6));
  });

  testWidgets('the orb is oversized so its halos spill onto the rim',
      (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();
    final bezel = tester.getRect(find.byType(OrbBezel));
    final orb = tester.getRect(find.byType(OrbView));
    expect(orb.width, closeTo(240 * kOrbScale, 0.5), reason: '--orb-scale: 1.55');
    expect(orb.center.dx, closeTo(bezel.center.dx, 0.5), reason: 'and centred');
    expect(orb.center.dy, closeTo(bezel.center.dy, 0.5));
  });

  testWidgets('PTT and ABI carry their engraved labels', (tester) async {
    await tester.pumpWidget(host());
    expect(find.text('PTT'), findsOneWidget);
    expect(find.text('ABI'), findsOneWidget);
  });

  testWidgets('each satellite reports its own tap', (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(findHero(HeroIcon.power));
    await tester.tap(findHero(HeroIcon.trash));
    await tester.tap(findHero(HeroIcon.microphone));
    await tester.tap(findHero(HeroIcon.handRaised));
    expect(taps, ['power', 'clear', 'ptt:true', 'abi:true']);
  });

  testWidgets('a toggle that is ON reports turning OFF', (tester) async {
    await tester.pumpWidget(host(pttOn: true, abiOn: true));
    await tester.tap(findHero(HeroIcon.microphone));
    await tester.tap(findHero(HeroIcon.handRaised));
    expect(taps, ['ptt:false', 'abi:false'],
        reason: 'the detent must report the INTENT, not its current state');
  });

  testWidgets('power ON tints the icon success-teal; OFF dims the whole detent',
      (tester) async {
    await tester.pumpWidget(host(powerOn: true));
    expect(tester.widget<HeroIconView>(findHero(HeroIcon.power)).color, M.success);

    await tester.pumpWidget(host());
    await tester.pump();
    final opacity = tester.widget<Opacity>(find
        .ancestor(
          of: findHero(HeroIcon.power),
          matching: find.byType(Opacity),
        )
        .first);
    expect(opacity.opacity, 0.5);
  });

  testWidgets('PTT/ABI ON use the amber ring, not the power recipe', (tester) async {
    await tester.pumpWidget(host(pttOn: true));
    expect(tester.widget<HeroIconView>(findHero(HeroIcon.microphone)).color, M.you);
    expect(tester.widget<Text>(find.text('PTT')).style!.color!.a, closeTo(0.7, 0.02));

    // ...and OFF is the unlit chrome grey, not the amber.
    await tester.pumpWidget(host());
    expect(tester.widget<HeroIconView>(findHero(HeroIcon.microphone)).color!.a,
        closeTo(0.55, 0.02));
    expect(tester.widget<Text>(find.text('PTT')).style!.color!.a, closeTo(0.36, 0.02));
  });

  /// The disabled treatment is an Opacity(0.5) somewhere above the icon.
  Finder dimmedPower() => find.ancestor(
        of: findHero(HeroIcon.power),
        matching: find.byWidgetPredicate((w) => w is Opacity && w.opacity == 0.5),
      );

  testWidgets('a power tap before the socket has joined is refused', (tester) async {
    // The push guard drops anything written before the join reply lands, and
    // power — unlike PTT and ABI — has no re-announce to heal it. So the
    // button must not look live.
    await tester.pumpWidget(host(powerEnabled: false));
    await tester.tap(findHero(HeroIcon.power));
    await tester.pump();
    expect(taps, isEmpty);
  });

  testWidgets('the power detent is dimmed while the socket is down', (tester) async {
    // powerOn: true so `dimmed` is false and the ONLY thing that can dim this
    // is the disabled state.
    await tester.pumpWidget(host(powerOn: true, powerEnabled: false));
    expect(dimmedPower(), findsOneWidget,
        reason: 'an inert control that looks live is worse than a missing one');

    await tester.pumpWidget(host(powerOn: true));
    expect(dimmedPower(), findsNothing);
  });

  testWidgets('an armed power detent still reports its tap', (tester) async {
    // The gate must not disable the button it was meant to protect.
    await tester.pumpWidget(host());
    await tester.tap(findHero(HeroIcon.power));
    await tester.pump();
    expect(taps, ['power']);
  });

  testWidgets('the bezel paints without throwing at a degenerate size',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 0,
            height: 0,
            child: CustomPaint(painter: BezelPainter(glow: M.you)),
          ),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the caption sits inside the glass, not under it', (tester) async {
    // It used to be a strip at `top: 58%`, deliberately clear of the middle so
    // it would not cover the waveform while you talked. The waveform is Henry's
    // voice only now, and this caption is only ever yours (set from `partial`,
    // cleared on `transcript`), so the two can never be on screen together.
    await tester.pumpWidget(host());
    const d = 240.0;

    final box = tester.getRect(find.byType(LiveCaption));
    final bezel = tester.getRect(find.byType(OrbBezel));
    final cx = bezel.left + d / 2;
    final cy = bezel.top + d / 2;

    expect(box.center.dx, closeTo(cx, 0.01), reason: 'centred horizontally');
    expect(box.center.dy, closeTo(cy, 0.01),
        reason: 'centred VERTICALLY — this is the half that moved');

    // Inscribed, not merely centred: every corner must lie within the sphere,
    // or a long caption spills over the glass edge and reads as a layout bug
    // rather than as text.
    const r = kSphereRadiusOfBezel * d;
    for (final corner in [box.topLeft, box.topRight, box.bottomLeft, box.bottomRight]) {
      final dx = corner.dx - cx;
      final dy = corner.dy - cy;
      expect(math.sqrt(dx * dx + dy * dy), lessThanOrEqualTo(r + 0.01),
          reason: 'corner $corner escapes the sphere (r = $r)');
    }
  });
}
