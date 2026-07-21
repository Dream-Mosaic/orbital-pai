import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/spike/porcupine_spike_screen.dart';

void main() {
  testWidgets(
      'dispose() does not setState() after disposal '
      '(navigate away without ever pressing Start)', (tester) async {
    // Regression test for: dispose() calls _stop() unawaited, then
    // super.dispose() runs synchronously — but _stop()'s awaited tail
    // (`_sub?.cancel()`, `_mic.stop()`, `_porcupine?.delete()`) resolves in a
    // later microtask, i.e. after disposal, and its trailing
    // `setState(() => _status = 'stopped')` used to run post-dispose,
    // throwing `FlutterError: setState() called after dispose()`.
    //
    // No real mic/Porcupine plugin is needed to reproduce this: _stop() runs
    // unconditionally on navigate-away regardless of whether Start was ever
    // pressed, and both `_sub?.cancel()` (null-safe) and `MicCapture.stop()`
    // (early-returns when not recording) short-circuit before any platform
    // call — but _stop() is still `async` reached via awaits, so its
    // setState() still lands on a later microtask than dispose()'s
    // synchronous continuation.
    await tester.pumpWidget(
      const MaterialApp(home: PorcupineSpikeScreen()),
    );

    // Navigate away (unmount the screen) without ever pressing Start, then
    // let _stop()'s awaited tail run.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull,
        reason: '_stop() must not setState() after dispose()');
  });
}
