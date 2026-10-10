import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/meridian/orb_bezel.dart';
import 'package:orbital_pai/meridian/thread.dart';
import 'package:orbital_pai/meridian/thread_model.dart';
import 'package:orbital_pai/meridian/timer_strip.dart';
import 'package:orbital_pai/meridian/tokens.dart';
import 'package:orbital_pai/voice/timers_model.dart';

/// The strip IN CONTEXT: the orb pane's elbow above, the real thread below, so
/// the golden pins the part that is easiest to break — the meridian running
/// unbroken from the elbow, through the strip, into the thread's spine.
///
/// Regenerate after an intentional visual change:
///   flutter test --update-goldens test/meridian/timer_strip_golden_test.dart
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    for (final (family, file) in [
      ('Space Grotesk', 'assets/fonts/SpaceGrotesk.ttf'),
      ('Inter', 'assets/fonts/Inter.ttf'),
    ]) {
      final loader = FontLoader(family)..addFont(rootBundle.load(file));
      await loader.load();
    }
  });

  testWidgets('a running and a ringing chip on the meridian', (tester) async {
    const now = Duration(seconds: 100);
    // The ringing pulse is mid-cycle in a frozen frame; pin it by not pumping
    // past the first frame.
    final timers = [
      TimerEntry(
        id: 1,
        label: 'Pasta',
        ringing: false,
        duration: const Duration(minutes: 10),
        deadline: now + const Duration(minutes: 6, seconds: 12),
      ),
      const TimerEntry(
        id: 2,
        label: 'Eggs',
        ringing: true,
        duration: Duration(minutes: 7),
        deadline: now,
      ),
      TimerEntry(
        id: 3,
        label: null,
        ringing: false,
        duration: const Duration(hours: 2),
        deadline: now + const Duration(hours: 1, minutes: 4, seconds: 9),
      ),
    ];
    const glow = M.henry;
    const key = ValueKey<String>('strip-golden');

    await tester.binding.setSurfaceSize(const Size(360, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      // The voice screen's transparent Material: without it every Text inherits
      // WidgetsApp's fallback yellow underline.
      home: Material(
        type: MaterialType.transparency,
        child: RepaintBoundary(
          key: key,
          child: Container(
            color: M.bg,
            padding: const EdgeInsets.all(M.pagePad),
            child: Column(
              children: [
                // The bottom of the orb pane: just its elbow, at its real width.
                Center(
                  child: SizedBox(
                    width: M.orbPaneMaxWidth,
                    height: 24,
                    child: CustomPaint(painter: ElbowPainter(glow: glow)),
                  ),
                ),
                const SizedBox(height: M.columnGap),
                TimerStrip(timers: timers, clock: () => now, glow: glow),
                const Expanded(
                  child: Thread(
                    glow: glow,
                    items: [
                      ThreadLine(
                          kind: LineKind.you,
                          label: 'you',
                          text: 'set an eggs timer for 7 minutes'),
                      ThreadLine(
                          kind: LineKind.brain,
                          label: 'Henry',
                          text: 'Eggs timer, 7 minutes.'),
                      ThreadLine(
                          kind: LineKind.timer,
                          label: 'timer',
                          text: 'Your eggs timer is up.'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ));
    await tester.pump();

    await expectLater(
        find.byKey(key), matchesGoldenFile('goldens/timer_strip.png'));

    await tester.pumpWidget(const SizedBox());
  });
}
