import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/voice/voice_controller.dart';

void main() {
  test('dispose() does not notifyListeners() after disposal', () async {
    // Regression test for: dispose() calls stopMic() unawaited, then
    // super.dispose() synchronously — but stopMic()'s tail (awaited
    // mic-subscription cancel/stop) resolves in a later microtask, i.e.
    // after disposal, and used to call notifyListeners() post-dispose,
    // throwing `FlutterError: A ChangeNotifier was used after being
    // disposed.` in debug/test builds.
    //
    // We don't need a real platform mic to reproduce this: stopMic() runs
    // unconditionally regardless of whether the mic was ever started, and
    // MicCapture.stop() short-circuits synchronously (no platform call)
    // when it was never recording — but it's still an `async` method
    // reached via two `await`s, so its notifyListeners() call still lands
    // on a later microtask than dispose()'s synchronous continuation.
    final controller = VoiceController();

    var uncaughtError = false;
    final zoneDone = runZonedGuarded(() async {
      controller.dispose();
      // Flush the microtask queue so stopMic()'s awaited tail
      // (`_micSub?.cancel()` then `_mic.stop()`) gets a chance to run.
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }, (error, stack) {
      uncaughtError = true;
    });
    await zoneDone;

    expect(uncaughtError, isFalse,
        reason: 'stopMic() must not notifyListeners() after dispose()');
  });
}
