import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/connection/app_connection.dart';
import 'package:orbital_pai/phoenix/decoded_message.dart';
import 'package:orbital_pai/voice/camera_relay.dart';
import 'package:orbital_pai/voice/voice_controller.dart';

import 'support/fake_camera.dart';
import 'support/fake_socket.dart';
import 'support/fakes.dart';

/// "Henry, look at this" — the app half of the wire protocol (spec
/// 2026-10-23, game night §1): `camera_capture` in, `camera_frame` out,
/// `camera_done` in. The camera is a fake; the channel is a real joined one.
void main() {
  late FakeSocket fake;
  late AppConnection conn;
  late FakeCamera camera;
  late VoiceController vc;

  const timings = CameraTimings(
    hold: Duration(milliseconds: 120),
    openTimeout: Duration(milliseconds: 120),
    captureTimeout: Duration(milliseconds: 120),
  );

  setUp(() async {
    fake = FakeSocket();
    conn = AppConnection(connector: () async => fake.socket);
    camera = FakeCamera(jpeg: Uint8List.fromList([0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9]));
    vc = VoiceController(
      connection: conn,
      mic: FakeMic(),
      player: FakePlayer(),
      spotter: FakeSpotter(),
      camera: camera,
      cameraTimings: timings,
    );
    await conn.connect();
    await settle();
  });
  tearDown(() {
    vc.dispose();
    conn.dispose();
  });

  DecodedMessage msg(String event, Map<String, dynamic> p) =>
      DecodedMessage(topic: 'voice:henry', event: event, json: p);

  void captureReq(String id, {String facing = 'front', int countdown = 0}) =>
      vc.debugHandleMessage(msg('camera_capture',
          {'id': id, 'facing': facing, 'countdown_ms': countdown}));

  void doneFor(String id) => vc.debugHandleMessage(msg('camera_done', {'id': id}));

  /// The `camera_frame` pushes this client sent, decoded, in order.
  List<Map<String, dynamic>> frames() => fake.sent
      .whereType<String>()
      .map((f) => jsonDecode(f) as List<dynamic>)
      .where((p) => p[3] == 'camera_frame')
      .map((p) => (p[4] as Map).cast<String, dynamic>())
      .toList();

  Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

  test('a capture opens the asked-for lens and pushes the JPEG as base64', () async {
    captureReq('c1', facing: 'front');
    expect(vc.camera?.id, 'c1');
    await settle();

    expect(camera.opens, ['front']);
    expect(frames(), [
      {'id': 'c1', 'jpeg': base64Encode(camera.jpeg)},
    ]);
    // The picture is in hand: the camera is let go of, the snapshot stays.
    expect(camera.isOpen, isFalse);
    expect(camera.closes, greaterThan(0));
    expect(vc.camera!.phase, CameraPhase.frozen);
    expect(vc.camera!.snapshot, camera.jpeg);
    expect(vc.snapshotFor('c1'), camera.jpeg);
  });

  test('the back lens is asked for when the server says back', () async {
    captureReq('c1', facing: 'back');
    await settle();
    expect(camera.opens, ['back']);
  });

  test('the countdown steps 3, 2, 1, then the shutter, then the snapshot', () async {
    final seen = <String>[];
    vc.addListener(() {
      final s = vc.camera;
      final step = s == null
          ? 'none'
          : s.phase == CameraPhase.countdown
              ? '${s.count}'
              : s.phase.name;
      if (seen.isEmpty || seen.last != step) seen.add(step);
    });
    captureReq('c1', countdown: 150);
    expect(vc.camera!.count, 3);
    // Nothing goes out before the countdown is over.
    await wait(20);
    expect(frames(), isEmpty);
    await wait(250);

    expect(seen, ['3', '2', '1', 'shutter', 'frozen']);
    expect(frames().single['id'], 'c1');
  });

  test('the viewfinder is flagged once the camera is open', () async {
    camera.openGate = Completer<void>();
    captureReq('c1', countdown: 1000);
    await settle();
    expect(vc.camera!.previewing, isFalse);
    camera.openGate!.complete();
    await settle();
    expect(vc.camera!.previewing, isTrue);
  });

  test('a refused permission answers denied and closes the camera', () async {
    camera.openFailure = 'denied';
    captureReq('c1', countdown: 1000);
    await settle();

    expect(frames(), [
      {'id': 'c1', 'error': 'denied'},
    ]);
    expect(vc.camera, isNull);
    expect(camera.closes, greaterThan(0));
    expect(camera.captures, 0);
  });

  test('no camera answers no_camera', () async {
    camera.openFailure = 'no_camera';
    captureReq('c1');
    await settle();
    expect(frames(), [
      {'id': 'c1', 'error': 'no_camera'},
    ]);
    expect(vc.camera, isNull);
  });

  test('anything else going wrong answers failed', () async {
    camera.captureThrows = StateError('boom');
    captureReq('c1');
    await settle();
    expect(frames(), [
      {'id': 'c1', 'error': 'failed'},
    ]);
    expect(vc.camera, isNull);
    expect(camera.isOpen, isFalse);
    expect(vc.snapshotFor('c1'), isNull);
  });

  test('a camera that never opens answers failed when the wait runs out', () async {
    camera.openHangs = true;
    captureReq('c1');
    await wait(60);
    expect(frames(), isEmpty);
    await wait(150);

    expect(frames(), [
      {'id': 'c1', 'error': 'failed'},
    ]);
    expect(vc.camera, isNull);
    expect(camera.closes, greaterThan(0));
  });

  test('a shutter that never answers answers failed', () async {
    camera.captureHangs = true;
    captureReq('c1');
    await wait(200);
    expect(frames(), [
      {'id': 'c1', 'error': 'failed'},
    ]);
    expect(vc.camera, isNull);
  });

  test('a second capture while one is in flight is refused as failed', () async {
    captureReq('c1', countdown: 120);
    captureReq('c2', countdown: 0);
    await settle();
    expect(frames(), [
      {'id': 'c2', 'error': 'failed'},
    ]);
    // The first is untouched and finishes.
    expect(vc.camera!.id, 'c1');
    await wait(200);
    expect(frames().last['id'], 'c1');
    expect(frames().last['jpeg'], isNotNull);
    expect(camera.opens, ['front']);
  });

  test('a frozen snapshot is not busy: a new capture replaces it', () async {
    captureReq('c1');
    await settle();
    expect(vc.camera!.phase, CameraPhase.frozen);
    captureReq('c2');
    await settle();
    expect(frames().map((f) => f['id']), ['c1', 'c2']);
    expect(frames().every((f) => f['jpeg'] != null), isTrue);
    expect(vc.camera!.id, 'c2');
  });

  test('camera_done releases the snapshot from the glass, not from memory', () async {
    captureReq('c1');
    await settle();
    doneFor('c1');
    expect(vc.camera, isNull);
    expect(vc.snapshotFor('c1'), camera.jpeg);
  });

  test('camera_done for another id is ignored', () async {
    captureReq('c1');
    await settle();
    doneFor('other');
    expect(vc.camera?.id, 'c1');
  });

  test('without camera_done the snapshot lets go on its own', () async {
    captureReq('c1');
    await settle();
    expect(vc.camera, isNotNull);
    await wait(200);
    expect(vc.camera, isNull);
    expect(vc.snapshotFor('c1'), isNotNull);
  });

  test('camera_done mid-countdown drops the capture: no frame, camera closed', () async {
    captureReq('c1', countdown: 120);
    await settle();
    expect(camera.isOpen, isTrue);
    doneFor('c1');
    expect(vc.camera, isNull);
    await wait(200);
    expect(frames(), isEmpty);
    expect(camera.isOpen, isFalse);
    expect(camera.captures, 0);
  });

  test('the channel going down mid-countdown closes the camera, sends nothing', () async {
    captureReq('c1', countdown: 120);
    await settle();
    await fake.kill();
    await settle();
    expect(vc.camera, isNull);
    expect(camera.isOpen, isFalse);
    await wait(200);
    expect(camera.captures, 0);
    expect(frames(), isEmpty);
  });

  test('only the last ten snapshots are kept', () async {
    for (var i = 0; i < 12; i++) {
      camera.jpeg = Uint8List.fromList([i]);
      captureReq('c$i');
      await settle();
    }
    expect(vc.snapshotFor('c0'), isNull);
    expect(vc.snapshotFor('c1'), isNull);
    expect(vc.snapshotFor('c2'), Uint8List.fromList([2]));
    expect(vc.snapshotFor('c11'), Uint8List.fromList([11]));
  });

  test('a request without an id answers nothing and opens nothing', () async {
    vc.debugHandleMessage(msg('camera_capture', {'facing': 'front'}));
    vc.debugHandleMessage(msg('camera_capture', {'id': '', 'facing': 'front'}));
    await settle();
    expect(frames(), isEmpty);
    expect(camera.opens, isEmpty);
    expect(vc.camera, isNull);
  });

  test('every step notifies, so the orb redraws', () async {
    var notified = 0;
    vc.addListener(() => notified++);
    captureReq('c1');
    expect(notified, greaterThan(0));
  });

  test('dispose mid-capture closes the camera', () async {
    captureReq('c1', countdown: 120);
    await settle();
    expect(camera.isOpen, isTrue);
    vc.dispose();
    await settle();
    expect(camera.isOpen, isFalse);
    // tearDown disposes again: must be harmless.
    vc = VoiceController(
        connection: conn, mic: FakeMic(), player: FakePlayer(), camera: FakeCamera());
  });
}
