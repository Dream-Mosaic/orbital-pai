import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/meridian/composer.dart';
import 'package:orbital_pai/meridian/tokens.dart';

/// The composer is new chrome on a screen whose every other element was ported
/// from the web pixel for pixel, so it has to be LOOKED at, not only exercised.
///
/// Regenerate deliberately (never to silence a failure you have not explained):
///   flutter test --update-goldens test/meridian/composer_golden_test.dart
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // The real faces, not the square test font, or the golden says nothing.
    final display = FontLoader(kDisplayFamily)
      ..addFont(rootBundle.load('assets/fonts/SpaceGrotesk.ttf'));
    final body = FontLoader(kBodyFamily)
      ..addFont(rootBundle.load('assets/fonts/Inter.ttf'));
    await Future.wait([display.load(), body.load()]);
  });

  setUp(() => EditableText.debugDeterministicCursor = true);
  tearDown(() => EditableText.debugDeterministicCursor = false);

  Widget dock({required bool ptt}) => ComposerDock(
        pttEnabled: ptt,
        pttHeld: false,
        onPttPress: () {},
        onPttRelease: () {},
        onSend: (_) => true,
      );

  Widget host(Key key, List<Widget> children) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Material(
          type: MaterialType.transparency,
          child: Center(
            child: RepaintBoundary(
              key: key,
              child: Container(
                width: 360,
                color: M.bg,
                padding: const EdgeInsets.all(M.pagePad),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final c in children) ...[
                      c,
                      const SizedBox(height: M.columnGap),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );

  testWidgets('the tray, with PTT off and on', (tester) async {
    const key = ValueKey('tray-golden');
    await tester.pumpWidget(host(key, [dock(ptt: false), dock(ptt: true)]));
    await tester.pump();

    await expectLater(
        find.byKey(key), matchesGoldenFile('goldens/composer_tray.png'));
  });

  testWidgets('the composer, focused, with a draft', (tester) async {
    const key = ValueKey('composer-golden');
    await tester.pumpWidget(host(key, [dock(ptt: false)]));
    await tester.tap(find.byKey(ComposerDock.keyboardKey));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField),
        'Is it going to rain before the kids get home?');
    await tester.pumpAndSettle();

    await expectLater(
        find.byKey(key), matchesGoldenFile('goldens/composer_open.png'));
  });

  testWidgets('the composer, focused, empty', (tester) async {
    const key = ValueKey('composer-empty-golden');
    await tester.pumpWidget(host(key, [dock(ptt: false)]));
    await tester.tap(find.byKey(ComposerDock.keyboardKey));
    await tester.pumpAndSettle();

    await expectLater(
        find.byKey(key), matchesGoldenFile('goldens/composer_empty.png'));
  });
}
