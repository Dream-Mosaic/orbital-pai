import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/meridian/drawer.dart';
import 'package:henry_wall/meridian/hero_icon.dart';

/// heroicons are SVGs, not IconData, so `find.byIcon` does not apply.
Finder findHero(HeroIcon icon) =>
    find.byWidgetPredicate((w) => w is HeroIconView && w.icon == icon);

void main() {
  Future<void> pumpDrawer(WidgetTester tester, Size surface,
      {VoidCallback? onClose, VoidCallback? onBack}) async {
    await tester.binding.setSurfaceSize(surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: MeridianDrawer(
        title: 'Reminders',
        animation: const AlwaysStoppedAnimation<double>(1),
        onClose: onClose ?? () {},
        onBack: onBack,
        child: const Text('panel body'),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('no text inherits the missing-Material underline', (tester) async {
    // Shipped twice now. The voice screen hit it and was fixed with a
    // transparent Material — but the drawer is its own ROUTE, pushed with no
    // Scaffold, so it never inherited that one and the bug came straight back
    // on the first panel. With no Material ancestor, WidgetsApp's fallback
    // DefaultTextStyle applies, and our styles override its colour/size/family
    // but NOT its `decoration`, so every label wears a yellow double underline.
    // The DECLARED style is clean either way, so this has to assert the MERGED
    // style RichText actually paints.
    await pumpDrawer(tester, const Size(360, 800));

    final painted = tester.widgetList<RichText>(find.byType(RichText));
    expect(painted, isNotEmpty);
    for (final rich in painted) {
      final style = (rich.text as TextSpan).style;
      expect(style?.decoration ?? TextDecoration.none, TextDecoration.none,
          reason: 'decoration leaked into "${rich.text.toPlainText()}"');
    }
  });

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

  testWidgets('the scrim fades and the panel slides — not swapped',
      (tester) async {
    await pumpDrawer(tester, const Size(800, 800));

    // `find.byType(FadeTransition)`/`SlideTransition` alone is not specific
    // enough: MaterialApp's own Navigator wraps EVERYTHING (including this
    // drawer) in its default page-transition Fade/SlideTransition too, so a
    // bare type search matches those ambient ones as well as the drawer's
    // own. Pin to the drawer's own keyed transitions instead, and assert
    // their concrete type — that's what actually catches a Fade/Slide swap.
    expect(tester.widget(find.byKey(MeridianDrawer.scrimFadeKey)),
        isA<FadeTransition>());
    expect(tester.widget(find.byKey(MeridianDrawer.panelSlideKey)),
        isA<SlideTransition>());

    // The scrim's BackdropFilter is a descendant of the drawer's own
    // fade transition (also catches the BackdropFilter being deleted
    // outright) ...
    expect(
      find.descendant(
        of: find.byKey(MeridianDrawer.scrimFadeKey),
        matching: find.byType(BackdropFilter),
      ),
      findsOneWidget,
    );

    // ... the panel is a descendant of the drawer's own slide transition ...
    expect(
      find.descendant(
        of: find.byKey(MeridianDrawer.panelSlideKey),
        matching: find.byKey(MeridianDrawer.panelKey),
      ),
      findsOneWidget,
    );

    // ... and the negative that actually discriminates a swap: the panel is
    // NOT inside the drawer's own fade transition.
    expect(
      find.descendant(
        of: find.byKey(MeridianDrawer.scrimFadeKey),
        matching: find.byKey(MeridianDrawer.panelKey),
      ),
      findsNothing,
    );
  });

  testWidgets('no chevron at the root layer', (tester) async {
    await pumpDrawer(tester, const Size(360, 800));
    expect(findHero(HeroIcon.chevronLeft), findsNothing);
  });

  testWidgets('a sub-layer shows a back chevron that reports its tap',
      (tester) async {
    var backs = 0;
    await pumpDrawer(tester, const Size(360, 800), onBack: () => backs++);
    expect(findHero(HeroIcon.chevronLeft), findsOneWidget);
    await tester.tap(findHero(HeroIcon.chevronLeft));
    await tester.pump();
    expect(backs, 1);
  });

  testWidgets('the back chevron is not the close control', (tester) async {
    var backs = 0, closes = 0;
    await pumpDrawer(tester, const Size(360, 800),
        onClose: () => closes++, onBack: () => backs++);
    await tester.tap(findHero(HeroIcon.chevronLeft));
    await tester.pump();
    expect(backs, 1);
    expect(closes, 0, reason: 'back pops the layer; only ✕ and the scrim close');
  });
}
