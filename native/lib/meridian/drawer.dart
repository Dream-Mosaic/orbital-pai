import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'hero_icon.dart';
import 'tokens.dart';

/// The port of the web's slide-in panel drawer (`#voice-modal`).
///
/// The CSS is already responsive — `absolute inset-y-0 right-0 w-full
/// max-w-[24rem]` — so this is full-bleed on a phone and a 384px right-hand
/// drawer once there is room, rather than a bottom sheet. Scrim is
/// `rgba(2,3,9,0.6)` with `blur(3px)`; the panel is frosted dark glass with a
/// hairline left edge and the small amber tab on it.
///
/// The scrim FADES and the panel SLIDES, both off the route's animation, so a
/// dismiss reverses cleanly.
class MeridianDrawer extends StatelessWidget {
  const MeridianDrawer({
    super.key,
    required this.title,
    required this.animation,
    required this.onClose,
    required this.child,
  });

  /// `max-w-[24rem]`.
  static const double maxWidth = 384;

  /// `duration-300`.
  static const Duration slide = Duration(milliseconds: 300);

  /// So a test can measure the panel rather than the scrim.
  static const Key panelKey = ValueKey('meridian-drawer-panel');

  final String title;
  final Animation<double> animation;
  final VoidCallback onClose;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOut);
    return Stack(
      children: [
        Positioned.fill(
          child: FadeTransition(
            opacity: curved,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onClose,
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 3, sigmaY: 3),
                child: const ColoredBox(color: Color(0x99020309)),
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: SlideTransition(
            position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
                .animate(curved),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: maxWidth),
              // width: infinity inside a max-width box == the CSS `w-full
              // max-w-[24rem]` pair.
              child: SizedBox(
                key: panelKey,
                width: double.infinity,
                child: _panel(),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _panel() => DecoratedBox(
        decoration: const BoxDecoration(
          // color-mix(in srgb, var(--m-shell) 94%, transparent)
          color: Color(0xF007080F),
          border: Border(left: BorderSide(color: M.hairline)),
        ),
        child: Stack(
          children: [
            SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: child,
                    ),
                  ),
                ],
              ),
            ),
            // The decorative amber tab on the left edge (`.bg-base-300`):
            // 1.5 x 48, rounded on its right, ml-0.5, vertically centred.
            Positioned(
              left: 2,
              top: 0,
              bottom: 0,
              child: Center(
                child: Container(
                  width: 1.5,
                  height: 48,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [M.youSoft, M.you],
                    ),
                    borderRadius:
                        BorderRadius.horizontal(right: Radius.circular(2)),
                  ),
                ),
              ),
            ),
          ],
        ),
      );

  Widget _header() => Container(
        padding: const EdgeInsets.all(16),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: M.hairline)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontFamily: kDisplayFamily,
                  fontSize: 18, // text-lg
                  fontWeight: FontWeight.w600,
                  color: M.ink,
                ),
              ),
            ),
            GestureDetector(
              onTap: onClose,
              behavior: HitTestBehavior.opaque,
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: HeroIconView(HeroIcon.xMark, size: 18, color: M.inkDim),
              ),
            ),
          ],
        ),
      );
}

/// Pushes [MeridianDrawer] as a transparent route so the conversation keeps
/// rendering (and running) behind the scrim.
Route<void> meridianDrawerRoute({
  required String title,
  required Widget child,
}) =>
    PageRouteBuilder<void>(
      opaque: false,
      // The scrim inside the drawer is the tap target; the route's own barrier
      // would sit above it and swallow the tap.
      barrierDismissible: false,
      transitionDuration: MeridianDrawer.slide,
      reverseTransitionDuration: MeridianDrawer.slide,
      pageBuilder: (context, animation, _) => MeridianDrawer(
        title: title,
        animation: animation,
        onClose: () => Navigator.of(context).maybePop(),
        child: child,
      ),
    );
