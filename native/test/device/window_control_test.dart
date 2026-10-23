import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/device/window_control.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('henry/window');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> windowCalls;
  late List<MethodCall> platformCalls;

  setUp(() {
    windowCalls = [];
    platformCalls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      windowCalls.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      platformCalls.add(call);
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  const window = PlatformWindowControl();

  test('setKeepScreenOn sends the flag', () async {
    await window.setKeepScreenOn(true);
    await window.setKeepScreenOn(false);

    expect(windowCalls.map((c) => c.method), ['setKeepScreenOn', 'setKeepScreenOn']);
    expect(windowCalls.map((c) => c.arguments), [
      {'on': true},
      {'on': false},
    ]);
  });

  test('setBrightness sends the level, and null hands it back to the system', () async {
    await window.setBrightness(0.02);
    await window.setBrightness(null);

    expect(windowCalls.map((c) => c.method), ['setBrightness', 'setBrightness']);
    expect(windowCalls.map((c) => c.arguments), [
      {'level': 0.02},
      {'level': null},
    ]);
  });

  test('setImmersive hides the bars sticky, and leaving restores edge to edge', () async {
    await window.setImmersive(true);
    await window.setImmersive(false);

    final modes = platformCalls
        .where((c) => c.method == 'SystemChrome.setEnabledSystemUIMode')
        .map((c) => c.arguments)
        .toList();
    expect(modes, ['SystemUiMode.immersiveSticky', 'SystemUiMode.edgeToEdge']);
    expect(windowCalls, isEmpty, reason: 'the bars go through SystemChrome, not henry/window');
  });

  test('a platform without the channel is a no-op, never a throw', () async {
    messenger.setMockMethodCallHandler(channel, null);

    await expectLater(window.setKeepScreenOn(true), completes);
    await expectLater(window.setBrightness(0.02), completes);
  });

  test('a platform error is swallowed too', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'boom');
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      throw PlatformException(code: 'boom');
    });

    await expectLater(window.setKeepScreenOn(true), completes);
    await expectLater(window.setBrightness(null), completes);
    await expectLater(window.setImmersive(true), completes);
  });
}
