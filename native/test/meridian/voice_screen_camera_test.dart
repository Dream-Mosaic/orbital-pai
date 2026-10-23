import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/connection/app_connection.dart';
import 'package:orbital_pai/meridian/camera_face.dart';
import 'package:orbital_pai/meridian/cards/photo_card.dart';
import 'package:orbital_pai/meridian/orb_face.dart';
import 'package:orbital_pai/meridian/voice_screen.dart';
import 'package:orbital_pai/phoenix/decoded_message.dart';
import 'package:orbital_pai/voice/voice_controller.dart';

import '../support/fake_camera.dart';
import '../support/fakes.dart';

/// The camera takes the orb's glass — in the ONE place the face is built, so
/// on every layout — and gives it back to the clock when it is done.
void main() {
  late AppConnection conn;

  setUp(() =>
      conn = AppConnection(connector: () async => throw StateError('no socket')));
  tearDown(() => conn.dispose());

  DecodedMessage msg(String event, Map<String, dynamic> p) =>
      DecodedMessage(topic: 'voice:henry', event: event, json: p);

  Future<VoiceController> mount(WidgetTester tester, Size dp, double dpr) async {
    tester.view.physicalSize = dp * dpr;
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.reset);
    final vc = VoiceController(
      connection: conn,
      mic: FakeMic(),
      player: FakePlayer(),
      camera: FakeCamera(jpeg: kPixel),
    );
    addTearDown(vc.dispose);
    await tester.pumpWidget(MaterialApp(
      home: MeridianVoiceScreen(controller: vc, connection: conn, userName: 'David'),
    ));
    await tester.pump();
    return vc;
  }

  for (final (name, size, dpr) in [
    ('the wall (1191x711)', const Size(1191, 711), 1.125),
    ('a phone', const Size(360, 800), 3.0),
  ]) {
    testWidgets('$name: the capture replaces the clock face, then gives it back',
        (tester) async {
      final vc = await mount(tester, size, dpr);
      expect(find.byType(OrbFace), findsOneWidget);
      expect(find.byType(CameraFace), findsNothing);

      vc.debugHandleMessage(msg('camera_capture',
          {'id': 'c1', 'facing': 'front', 'countdown_ms': 900}));
      await tester.pump();
      expect(find.byType(CameraFace), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      // Past the crossfade, the clock is gone.
      await tester.pump(const Duration(milliseconds: 280));
      expect(find.byType(OrbFace), findsNothing);

      // The countdown runs out; the snapshot freezes in the glass.
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      expect(vc.camera?.snapshot, kPixel);
      expect(find.byKey(cameraSnapshotKey), findsOneWidget);

      // The server is done with it: the clock comes back.
      vc.debugHandleMessage(msg('camera_done', {'id': 'c1'}));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(CameraFace), findsNothing);
      expect(find.byType(OrbFace), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the photo card in the thread shows the snapshot this device took',
      (tester) async {
    final vc = await mount(tester, const Size(1191, 711), 1.125);
    vc.debugHandleMessage(msg('camera_capture',
        {'id': 'c1', 'facing': 'front', 'countdown_ms': 0}));
    await tester.pump();
    await tester.pump();
    vc.debugHandleMessage(msg('card', {
      'card': {'type': 'photo', 'capture_id': 'c1', 'caption': 'what am I holding'},
    }));
    vc.debugHandleMessage(msg('camera_done', {'id': 'c1'}));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(PhotoCard), findsOneWidget);
    expect(find.byKey(const ValueKey('photo-image')), findsOneWidget);
    expect(find.text('photo not kept'), findsNothing);
  });
}
