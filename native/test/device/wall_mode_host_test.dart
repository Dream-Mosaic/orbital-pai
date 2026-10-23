import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/auth/device_id.dart';
import 'package:orbital_pai/connection/app_connection.dart';
import 'package:orbital_pai/device/device_role.dart';
import 'package:orbital_pai/device/night_dim.dart';
import 'package:orbital_pai/device/wall_activity.dart';
import 'package:orbital_pai/device/wall_mode_host.dart';
import 'package:orbital_pai/phoenix/decoded_message.dart';
import 'package:orbital_pai/voice/voice_controller.dart';

import '../support/fake_alarm.dart';
import '../support/fake_window.dart';
import '../support/fakes.dart';

class _FixedIds implements DeviceIdStore {
  @override
  Future<String?> read() async => 'wall-1';
  @override
  Future<void> write(String value) async {}
}

const _wall = DeviceSettings(role: DeviceRole.wall);
const _personal = DeviceSettings(role: DeviceRole.personal);

void main() {
  late DateTime now;
  late FakeWindow window;

  /// Builds an unconnected controller (no socket, no mic) — enough to drive
  /// turn events through [VoiceController.debugHandleMessage].
  VoiceController buildVc() {
    final conn = AppConnection(connector: () async => throw StateError('never dialed'));
    final vc = VoiceController(
      connection: conn,
      mic: FakeMic(),
      player: FakePlayer(),
      spotter: FakeSpotter(),
      alarm: FakeAlarm(),
      deviceId: DeviceId(store: _FixedIds()),
    );
    addTearDown(() {
      vc.dispose();
      conn.dispose();
    });
    return vc;
  }

  Future<void> pumpHost(WidgetTester tester, DeviceController device, VoiceController vc) =>
      tester.pumpWidget(MaterialApp(
        home: WallModeHost(
          device: device,
          vc: vc,
          window: window,
          clock: () => now,
          child: const Scaffold(body: SizedBox.expand()),
        ),
      ));

  double overlayOpacity(WidgetTester tester) =>
      tester.widget<AnimatedOpacity>(find.byKey(WallModeHost.overlayKey)).opacity;

  /// Moves the fake wall clock and lets one dim tick run.
  Future<void> advance(WidgetTester tester, Duration d) async {
    now = now.add(d);
    await tester.pump(WallModeHost.tick);
    await tester.pump(WallModeHost.dimFade);
  }

  setUp(() {
    now = DateTime(2026, 10, 23, 23, 0);
    window = FakeWindow();
  });

  testWidgets('a wall holds the screen on and hides the bars', (tester) async {
    await pumpHost(tester, DeviceController.fixed(_wall), buildVc());

    expect(window.calls, ['keepOn(true)', 'immersive(true)']);
  });

  testWidgets('a personal device is never touched', (tester) async {
    now = DateTime(2026, 10, 23, 13, 0);
    await pumpHost(tester, DeviceController.fixed(_personal), buildVc());
    await advance(tester, const Duration(minutes: 5));

    expect(window.calls, isEmpty);
    // And leaving the tree hands nothing back, because nothing was taken.
    await tester.pumpWidget(const SizedBox());
    expect(window.calls, isEmpty);
  });

  testWidgets('switching to personal restores everything', (tester) async {
    final device = DeviceController.fixed(_wall);
    await pumpHost(tester, device, buildVc());
    window.calls.clear();

    await device.setWall(false);
    await tester.pump();

    expect(window.calls, ['keepOn(false)', 'immersive(false)', 'brightness(null)']);
  });

  testWidgets('switching a phone to wall applies it at once', (tester) async {
    final device = DeviceController.fixed(_personal);
    await pumpHost(tester, device, buildVc());

    await device.setWall(true);
    await tester.pump();

    expect(window.calls, ['keepOn(true)', 'immersive(true)']);
  });

  testWidgets('at 23:00, 60 s at rest dims; a touch undims', (tester) async {
    await pumpHost(tester, DeviceController.fixed(_wall), buildVc());
    window.calls.clear();

    await advance(tester, const Duration(seconds: 55));
    expect(window.calls, isEmpty, reason: 'not yet a minute at rest');
    expect(overlayOpacity(tester), 0);

    await advance(tester, const Duration(seconds: 5));
    expect(window.calls, ['brightness($kDimBrightness)']);
    expect(overlayOpacity(tester), 1);

    await tester.tapAt(const Offset(10, 10));
    await tester.pump();
    expect(window.calls.last, 'brightness(null)');
    expect(overlayOpacity(tester), 0);

    // And it dims again after another minute at rest.
    window.calls.clear();
    await advance(tester, const Duration(seconds: 60));
    expect(window.calls, ['brightness($kDimBrightness)']);
  });

  testWidgets('the daytime never dims', (tester) async {
    now = DateTime(2026, 10, 23, 14, 0);
    await pumpHost(tester, DeviceController.fixed(_wall), buildVc());
    window.calls.clear();

    await advance(tester, const Duration(minutes: 10));

    expect(window.calls, isEmpty);
    expect(overlayOpacity(tester), 0);
  });

  testWidgets('a turn undims and holds it awake while Henry is busy', (tester) async {
    final vc = buildVc();
    await pumpHost(tester, DeviceController.fixed(_wall), vc);
    await advance(tester, const Duration(seconds: 60));
    expect(overlayOpacity(tester), 1, reason: 'sanity: dimmed');
    window.calls.clear();

    vc.debugHandleMessage(
        const DecodedMessage(topic: 'voice:henry', event: 'thinking', json: {}));
    await tester.pump();
    expect(window.calls, ['brightness(null)']);
    expect(overlayOpacity(tester), 0);

    // A long think sends nothing new, but it is still not rest.
    await advance(tester, const Duration(seconds: 90));
    expect(overlayOpacity(tester), 0);

    // Back to listening: a minute later it dims again.
    vc.debugHandleMessage(
        const DecodedMessage(topic: 'voice:henry', event: 'listening', json: {}));
    await tester.pump();
    await advance(tester, const Duration(seconds: 30));
    expect(overlayOpacity(tester), 0);
    await advance(tester, const Duration(seconds: 30));
    expect(overlayOpacity(tester), 1);
  });

  testWidgets('turning dim-at-night off while dimmed undims', (tester) async {
    final device = DeviceController.fixed(_wall);
    await pumpHost(tester, device, buildVc());
    await advance(tester, const Duration(seconds: 60));
    window.calls.clear();

    await device.setDimAtNight(false);
    await tester.pump();

    expect(window.calls, ['brightness(null)']);
    expect(overlayOpacity(tester), 0);
    await advance(tester, const Duration(minutes: 5));
    expect(overlayOpacity(tester), 0);
  });

  testWidgets('a touch in a drawer (a route above the host) undims too', (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: WallModeHost(
        device: DeviceController.fixed(_wall),
        vc: buildVc(),
        window: window,
        clock: () => now,
        child: const Scaffold(body: SizedBox.expand()),
      ),
    ));
    navKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Center(child: Text('settings'))),
    ));
    await tester.pumpAndSettle();
    await advance(tester, const Duration(seconds: 60));
    expect(window.calls.last, 'brightness($kDimBrightness)', reason: 'sanity: dimmed');

    await tester.tap(find.text('settings'));
    await tester.pump();

    expect(window.calls.last, 'brightness(null)');
  });

  testWidgets('the first tap on a dimmed wall only wakes it', (tester) async {
    // David: a tap at night should wake the screen, not also press whatever
    // happened to be under the finger.
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: WallModeHost(
        device: DeviceController.fixed(_wall),
        vc: buildVc(),
        window: window,
        clock: () => now,
        child: Scaffold(
          body: Center(
            child: TextButton(onPressed: () => taps++, child: const Text('press')),
          ),
        ),
      ),
    ));
    await advance(tester, const Duration(seconds: 60));
    expect(overlayOpacity(tester), 1, reason: 'dimmed');

    await tester.tap(find.text('press'), warnIfMissed: false);
    await tester.pump();
    expect(taps, 0, reason: 'the waking tap is swallowed');
    expect(overlayOpacity(tester), 0, reason: 'but it does wake the wall');
    expect(window.calls.last, 'brightness(null)');

    await tester.tap(find.text('press'));
    await tester.pump();
    expect(taps, 1, reason: 'awake, the next tap reaches the UI');
  });

  testWidgets('a touch on an undimmed wall still reaches the UI', (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: WallModeHost(
        device: DeviceController.fixed(_wall),
        vc: buildVc(),
        window: window,
        clock: () => now,
        child: Scaffold(
          body: Center(
            child: TextButton(onPressed: () => taps++, child: const Text('press')),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('press'));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('leaving the tree hands the window back', (tester) async {
    await pumpHost(tester, DeviceController.fixed(_wall), buildVc());
    await advance(tester, const Duration(seconds: 60));
    window.calls.clear();

    await tester.pumpWidget(const SizedBox());

    expect(window.calls, ['keepOn(false)', 'immersive(false)', 'brightness(null)']);
  });

  group('the Today board\'s rest', () {
    /// The activity the host gives the screen it wraps, as that screen sees it.
    WallActivity? seen;

    Future<void> pumpWatched(WidgetTester tester, DeviceController device, VoiceController vc) {
      seen = null;
      return tester.pumpWidget(MaterialApp(
        home: WallModeHost(
          device: device,
          vc: vc,
          window: window,
          clock: () => now,
          child: Scaffold(
            body: Builder(builder: (context) {
              seen = WallActivityScope.maybeOf(context);
              return const SizedBox.expand();
            }),
          ),
        ),
      ));
    }

    /// The afternoon: no night dim to muddle the picture.
    setUp(() => now = DateTime(2026, 10, 23, 14, 0));

    test('the policy: a wall, two minutes at rest', () {
      expect(kTodayAfterRest, const Duration(minutes: 2));
      expect(shouldShowToday(settings: _wall, atRest: const Duration(seconds: 119)), isFalse);
      expect(shouldShowToday(settings: _wall, atRest: kTodayAfterRest), isTrue);
      expect(shouldShowToday(settings: _personal, atRest: const Duration(hours: 3)), isFalse);
    });

    testWidgets('a wall rests after two minutes, at any hour, dim-at-night or not',
        (tester) async {
      await pumpWatched(
          tester, DeviceController.fixed(_wall.copyWith(dimAtNight: false)), buildVc());
      expect(seen!.wall, isTrue);
      expect(seen!.rested, isFalse);

      await advance(tester, const Duration(seconds: 115));
      expect(seen!.rested, isFalse, reason: 'not yet two minutes');
      await advance(tester, const Duration(seconds: 5));
      expect(seen!.rested, isTrue);
      expect(window.calls.where((c) => c.startsWith('brightness')), isEmpty,
          reason: 'the board is not the dim');
    });

    testWidgets('a personal device never rests', (tester) async {
      await pumpWatched(tester, DeviceController.fixed(_personal), buildVc());
      expect(seen!.wall, isFalse);
      await advance(tester, const Duration(minutes: 10));
      expect(seen!.rested, isFalse);
    });

    testWidgets('a touch ends the rest at once, and it comes back two minutes later',
        (tester) async {
      await pumpWatched(tester, DeviceController.fixed(_wall), buildVc());
      await advance(tester, const Duration(minutes: 2));
      expect(seen!.rested, isTrue, reason: 'sanity: resting');

      await tester.tapAt(const Offset(10, 10));
      await tester.pump();
      expect(seen!.rested, isFalse, reason: 'no waiting for the next tick');

      await advance(tester, const Duration(seconds: 115));
      expect(seen!.rested, isFalse);
      await advance(tester, const Duration(seconds: 5));
      expect(seen!.rested, isTrue);
    });

    testWidgets('a turn ends it, and a long one holds it off', (tester) async {
      final vc = buildVc();
      await pumpWatched(tester, DeviceController.fixed(_wall), vc);
      await advance(tester, const Duration(minutes: 2));
      expect(seen!.rested, isTrue, reason: 'sanity: resting');

      vc.debugHandleMessage(
          const DecodedMessage(topic: 'voice:henry', event: 'thinking', json: {}));
      await tester.pump();
      expect(seen!.rested, isFalse);

      await advance(tester, const Duration(minutes: 3));
      expect(seen!.rested, isFalse, reason: 'still thinking is not rest');

      vc.debugHandleMessage(
          const DecodedMessage(topic: 'voice:henry', event: 'listening', json: {}));
      await tester.pump();
      await advance(tester, const Duration(minutes: 2));
      expect(seen!.rested, isTrue);
    });

    testWidgets('a ringing timer holds it off', (tester) async {
      final vc = buildVc();
      await pumpWatched(tester, DeviceController.fixed(_wall), vc);
      vc.debugHandleMessage(const DecodedMessage(topic: 'voice:henry', event: 'timers', json: {
        'timers': [
          {'id': 1, 'label': 'pasta', 'state': 'ringing', 'duration_ms': 600000, 'remaining_ms': 0},
        ],
      }));
      await tester.pump();

      await advance(tester, const Duration(minutes: 5));
      expect(seen!.rested, isFalse);

      // Dismissed: the controller's own countdown stops with it.
      vc.debugHandleMessage(const DecodedMessage(
          topic: 'voice:henry', event: 'timers', json: {'timers': []}));
      await tester.pump();
      await advance(tester, const Duration(minutes: 2));
      expect(seen!.rested, isTrue);
    });

    testWidgets('becoming personal ends it; becoming a wall starts the clock', (tester) async {
      final device = DeviceController.fixed(_wall);
      await pumpWatched(tester, device, buildVc());
      await advance(tester, const Duration(minutes: 2));
      expect(seen!.rested, isTrue, reason: 'sanity: resting');

      await device.setWall(false);
      await tester.pump();
      expect(seen!.wall, isFalse);
      expect(seen!.rested, isFalse);

      await device.setWall(true);
      await tester.pump();
      expect(seen!.wall, isTrue);
      await advance(tester, const Duration(minutes: 2));
      expect(seen!.rested, isTrue);
    });
  });
}
