import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/meridian/drawer.dart';

void main() {
  Future<void> pumpDrawer(WidgetTester tester, Size surface,
      {VoidCallback? onClose}) async {
    await tester.binding.setSurfaceSize(surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: MeridianDrawer(
        title: 'Reminders',
        animation: const AlwaysStoppedAnimation<double>(1),
        onClose: onClose ?? () {},
        child: const Text('panel body'),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('full-bleed on a phone', (tester) async {
    await pumpDrawer(tester, const Size(360, 800));
    expect(tester.getSize(find.byKey(MeridianDrawer.panelKey)).width, 360,
        reason: 'the web drawer is w-full below its max-width');
  });

  testWidgets('a 384px drawer once there is room', (tester) async {
    await pumpDrawer(tester, const Size(800, 800));
    expect(tester.getSize(find.byKey(MeridianDrawer.panelKey)).width,
        MeridianDrawer.maxWidth,
        reason: 'max-w-[24rem]');
  });

  testWidgets('it sits against the right edge', (tester) async {
    await pumpDrawer(tester, const Size(800, 800));
    final rect = tester.getRect(find.byKey(MeridianDrawer.panelKey));
    expect(rect.right, 800, reason: 'inset-y-0 right-0');
  });

  testWidgets('tapping the scrim closes it', (tester) async {
    var closes = 0;
    await pumpDrawer(tester, const Size(800, 800), onClose: () => closes++);
    // Well clear of the 384px panel on the right.
    await tester.tapAt(const Offset(100, 400));
    await tester.pump();
    expect(closes, 1);
  });

  testWidgets('tapping inside the panel does not close it', (tester) async {
    var closes = 0;
    await pumpDrawer(tester, const Size(800, 800), onClose: () => closes++);
    await tester.tap(find.text('panel body'));
    await tester.pump();
    expect(closes, 0, reason: 'the scrim is the dismiss target, not the drawer');
  });

  testWidgets('the title and the body both render', (tester) async {
    await pumpDrawer(tester, const Size(360, 800));
    expect(find.text('Reminders'), findsOneWidget);
    expect(find.text('panel body'), findsOneWidget);
  });
}
