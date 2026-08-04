import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/meridian/orb_bezel.dart';
import 'package:henry_wall/meridian/orb_painter.dart';
import 'package:henry_wall/meridian/orb_view.dart';
import 'package:henry_wall/meridian/tokens.dart';

void main() {
  late OrbFrame frame;
  late List<String> taps;

  Widget host({bool powerOn = false, bool pttOn = false, bool abiOn = false}) =>
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
    Offset centreOf(IconData icon) => tester.getCenter(find.byIcon(icon)) - origin;

    // app.css: .d-power 8%/8%, .d-clear 92%/8%, .d-ptt 8%/92%, .d-abi 92%/92%
    expect(centreOf(Icons.power_settings_new).dx, closeTo(240 * 0.08, 0.6));
    expect(centreOf(Icons.power_settings_new).dy, closeTo(240 * 0.08, 0.6));
    expect(centreOf(Icons.delete_outline).dx, closeTo(240 * 0.92, 0.6));
    expect(centreOf(Icons.delete_outline).dy, closeTo(240 * 0.08, 0.6));
    expect(centreOf(Icons.mic_none).dx, closeTo(240 * 0.08, 0.6));
    expect(centreOf(Icons.mic_none).dy, closeTo(240 * 0.92, 0.6));
    expect(centreOf(Icons.pan_tool_outlined).dx, closeTo(240 * 0.92, 0.6));
    expect(centreOf(Icons.pan_tool_outlined).dy, closeTo(240 * 0.92, 0.6));
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
    await tester.tap(find.byIcon(Icons.power_settings_new));
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.tap(find.byIcon(Icons.mic_none));
    await tester.tap(find.byIcon(Icons.pan_tool_outlined));
    expect(taps, ['power', 'clear', 'ptt:true', 'abi:true']);
  });

  testWidgets('a toggle that is ON reports turning OFF', (tester) async {
    await tester.pumpWidget(host(pttOn: true, abiOn: true));
    await tester.tap(find.byIcon(Icons.mic_none));
    await tester.tap(find.byIcon(Icons.pan_tool_outlined));
    expect(taps, ['ptt:false', 'abi:false'],
        reason: 'the detent must report the INTENT, not its current state');
  });

  testWidgets('power ON tints the icon success-teal; OFF dims the whole detent',
      (tester) async {
    await tester.pumpWidget(host(powerOn: true));
    expect(tester.widget<Icon>(find.byIcon(Icons.power_settings_new)).color, M.success);

    await tester.pumpWidget(host());
    await tester.pump();
    final opacity = tester.widget<Opacity>(find
        .ancestor(
          of: find.byIcon(Icons.power_settings_new),
          matching: find.byType(Opacity),
        )
        .first);
    expect(opacity.opacity, 0.5);
  });

  testWidgets('PTT/ABI ON use the amber ring, not the power recipe', (tester) async {
    await tester.pumpWidget(host(pttOn: true));
    expect(tester.widget<Icon>(find.byIcon(Icons.mic_none)).color, M.you);
    expect(tester.widget<Text>(find.text('PTT')).style!.color!.a, closeTo(0.7, 0.02));

    // ...and OFF is the unlit chrome grey, not the amber.
    await tester.pumpWidget(host());
    expect(tester.widget<Icon>(find.byIcon(Icons.mic_none)).color!.a,
        closeTo(0.55, 0.02));
    expect(tester.widget<Text>(find.text('PTT')).style!.color!.a, closeTo(0.36, 0.02));
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
}
