import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/meridian/camera_face.dart';
import 'package:orbital_pai/voice/camera_relay.dart';

import '../support/fake_camera.dart';

void main() {
  // The box the bezel hands a face: inscribed in the sphere (see OrbBezel).
  const w = 164.0;
  const h = 114.5;

  Widget host(CameraShot shot) => MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: CameraFace(
              width: w,
              height: h,
              shot: shot,
              preview: () => const SizedBox.expand(key: FakeCamera.previewKey),
            ),
          ),
        ),
      );

  double opacityOf(WidgetTester tester, Key key) =>
      tester.widget<AnimatedOpacity>(find.byKey(key)).opacity;

  double flashOpacity(WidgetTester tester) {
    final fade = tester.widget<FadeTransition>(find
        .ancestor(of: find.byKey(cameraFlashKey), matching: find.byType(FadeTransition))
        .first);
    return fade.opacity.value;
  }

  testWidgets('the glass is the circle through the face box corners', (tester) async {
    await tester.pumpWidget(
        host(const CameraShot(id: 'c1', phase: CameraPhase.countdown, count: 3)));
    final glass = tester.getSize(find.byType(ClipOval));
    final d = math.sqrt(w * w + h * h);
    expect(glass.width, moreOrLessEquals(d));
    expect(glass.height, moreOrLessEquals(d));
    // Centred on the face's own box, which is centred on the sphere.
    expect(tester.getCenter(find.byType(ClipOval)),
        tester.getCenter(find.byType(CameraFace)));
  });

  testWidgets('the countdown shows its digit over the viewfinder', (tester) async {
    await tester.pumpWidget(host(const CameraShot(
        id: 'c1', phase: CameraPhase.countdown, count: 3, previewing: true)));
    await tester.pumpAndSettle();
    expect(find.text('3'), findsOneWidget);
    expect(find.byKey(FakeCamera.previewKey), findsOneWidget);
    expect(opacityOf(tester, cameraPreviewKey), 1);
    expect(find.byKey(cameraSnapshotKey), findsNothing);
    // No flash before the shutter.
    expect(flashOpacity(tester), 0);

    await tester.pumpWidget(host(const CameraShot(
        id: 'c1', phase: CameraPhase.countdown, count: 2, previewing: true)));
    await tester.pumpAndSettle();
    expect(find.text('2'), findsOneWidget);
    expect(find.text('3'), findsNothing);
  });

  testWidgets('the viewfinder stays dark until the camera is open', (tester) async {
    await tester.pumpWidget(
        host(const CameraShot(id: 'c1', phase: CameraPhase.countdown, count: 3)));
    await tester.pumpAndSettle();
    expect(opacityOf(tester, cameraPreviewKey), 0);
  });

  testWidgets('the shutter flashes white, then fades', (tester) async {
    await tester.pumpWidget(host(const CameraShot(
        id: 'c1', phase: CameraPhase.countdown, count: 1, previewing: true)));
    await tester.pumpAndSettle();
    await tester.pumpWidget(host(
        const CameraShot(id: 'c1', phase: CameraPhase.shutter, previewing: true)));
    await tester.pump(const Duration(milliseconds: 60));
    expect(flashOpacity(tester), greaterThan(0.5));
    await tester.pumpAndSettle();
    expect(flashOpacity(tester), 0);
    // The last digit has gone with the shutter.
    expect(find.text('1'), findsNothing);
  });

  testWidgets('the frozen snapshot replaces the viewfinder', (tester) async {
    await tester.pumpWidget(host(const CameraShot(
        id: 'c1', phase: CameraPhase.countdown, count: 1, previewing: true)));
    await tester.pumpAndSettle();
    await tester.pumpWidget(host(CameraShot(
        id: 'c1', phase: CameraPhase.frozen, snapshot: kPixel)));
    // A snapshot that lands in the same frame as the shutter still flashes.
    await tester.pump(const Duration(milliseconds: 60));
    expect(flashOpacity(tester), greaterThan(0.5));
    await tester.pumpAndSettle();

    final image = tester.widget<Image>(find.byKey(cameraSnapshotKey));
    expect((image.image as MemoryImage).bytes, kPixel);
    expect(opacityOf(tester, cameraPreviewKey), 0);
    expect(find.text('1'), findsNothing);
  });

  testWidgets('a face built already frozen does not flash', (tester) async {
    await tester.pumpWidget(host(CameraShot(
        id: 'c1', phase: CameraPhase.frozen, snapshot: kPixel)));
    await tester.pump(const Duration(milliseconds: 60));
    expect(flashOpacity(tester), 0);
    // Nor on a later rebuild of the same picture.
    await tester.pumpWidget(host(CameraShot(
        id: 'c1', phase: CameraPhase.frozen, snapshot: kPixel)));
    await tester.pump(const Duration(milliseconds: 60));
    expect(flashOpacity(tester), 0);
  });
}
