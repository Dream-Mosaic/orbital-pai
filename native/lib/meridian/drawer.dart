import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'hero_icon.dart';
import 'tokens.dart';

/// The port of the web's slide-in panel drawer (`#voice-modal`).
///
/// The CSS is already responsive — `absolute inset-y-0 right-0 w-full
/// max-w-[24rem]` — so this is full-bleed on a phone and a 384px right-hand
/// drawer once there is room, rather than a bottom sheet. Scrim is
/// `rgba(2,3,9,0.6)` with `blur(3px)`; the panel fill is `color-mix(in srgb,
/// var(--m-shell) 94%, transparent)` with a faint top-left gradient sheen, a
/// hairline left edge, an outer drop shadow cast back toward the
/// conversation, and the small amber tab on that edge. The web also
/// `backdrop-filter: blur(22px)`s the panel itself; skipped here — at 94%
/// fill opacity it would be imperceptible, and a second `BackdropFilter` is
/// expensive.
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
    this.onBack,
  });

  /// `max-w-[24rem]`.
  static const double maxWidth = 384;

  /// `duration-300`.
  static const Duration slide = Duration(milliseconds: 300);

  /// How far the panel must be dragged away before RELEASING it closes rather
  /// than snaps back, as a fraction of the panel's own width.
  static const double closeFraction = 0.5;

  /// A flick this fast closes (or restores) the drawer regardless of how little
  /// ground it covered, in panel-widths per second. Position only decides when
  /// the gesture ends slower than this — which is what makes a short sharp
  /// flick work the way people expect it to.
  static const double flingWidthsPerSecond = 1.0;

  /// So a test can measure the panel rather than the scrim.
  static const Key panelKey = ValueKey('meridian-drawer-panel');

  /// So a test can pin down the drawer's OWN scrim/panel transitions,
  /// distinct from the ambient Fade/SlideTransition the host Navigator's
  /// default page-transition builder also wraps everything in.
  static const Key scrimFadeKey = ValueKey('meridian-drawer-scrim-fade');
  static const Key panelSlideKey = ValueKey('meridian-drawer-panel-slide');

  final String title;
  final Animation<double> animation;
  final VoidCallback onClose;
  final Widget child;

  /// Non-null when this drawer is showing a sub-layer: renders a leading
  /// chevron that pops back to the layer above. Null at the root.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOut);
    return Stack(
      children: [
        Positioned.fill(
          child: FadeTransition(
            key: scrimFadeKey,
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
            key: panelSlideKey,
            position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
                .animate(curved),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: maxWidth),
              // width: infinity inside a max-width box == the CSS `w-full
              // max-w-[24rem]` pair.
              child: _SwipeToClose(
                child: SizedBox(
                  key: panelKey,
                  width: double.infinity,
                  child: _panel(),
                ),
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
          // -28px 0 60px -28px rgba(0,0,0,.75): the outer drop shadow the web
          // casts back onto the conversation behind the drawer.
          boxShadow: [
            BoxShadow(
              color: Color(0xBF000000),
              offset: Offset(-28, 0),
              blurRadius: 60,
              spreadRadius: -28,
            ),
          ],
        ),
        // The drawer is its own ROUTE, pushed with no Scaffold, so it does NOT
        // inherit the transparent Material that MeridianVoiceScreen wraps
        // itself in. Without a Material ancestor, WidgetsApp's fallback
        // DefaultTextStyle applies; our styles override its colour, size and
        // family but NOT its `decoration`, so every label in here wore a yellow
        // double underline. Transparent, so the frosted fill above still shows.
        child: Material(
          type: MaterialType.transparency,
          child: Stack(
            children: [
              // linear-gradient(160deg, rgba(255,255,255,.035),
              // rgba(255,255,255,0) 40%): the faint sheen layered over the fill
              // above. 160deg -> unit direction (sin160°, -cos160°) ==
              // (0.342, 0.940); begin/end are +/- that vector.
              const Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment(-0.342, -0.940),
                      end: Alignment(0.342, 0.940),
                      colors: [Color(0x09FFFFFF), Color(0x00FFFFFF)],
                      stops: [0.0, 0.4],
                    ),
                  ),
                ),
              ),
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
              // w-1.5 h-12 = 6 x 48 (Tailwind's spacing scale: 0.375rem = 6px,
              // NOT the raw digit 1.5), rounded on its right, ml-0.5, vertically
              // centred.
              Positioned(
                left: 2,
                top: 0,
                bottom: 0,
                child: Center(
                  child: Container(
                    width: 6,
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
        ),
      );

  Widget _header() => Container(
        padding: const EdgeInsets.all(16),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: M.hairline)),
        ),
        child: Row(
          children: [
            if (onBack != null)
              GestureDetector(
                onTap: onBack,
                behavior: HitTestBehavior.opaque,
                child: const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: HeroIconView(HeroIcon.chevronLeft, size: 20, color: M.inkDim),
                ),
              ),
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
                child: HeroIconView(HeroIcon.xMark, size: 20, color: M.inkDim),
              ),
            ),
          ],
        ),
      );
}

/// Drag-to-close, wrapped around the panel.
///
/// Looks the route up rather than taking a callback, because dragging has to
/// drive the ROUTE'S OWN AnimationController — the same one the scrim fade and
/// the panel slide already read. Writing that one value is what makes the whole
/// drawer track the finger for free, and what lets a release continue from
/// wherever the finger left it instead of snapping back to fully-open first.
///
/// Outside a [_MeridianDrawerRoute] (a bare `MeridianDrawer` in a test, say)
/// this is a pass-through, so the widget stays usable on its own.
class _SwipeToClose extends StatefulWidget {
  const _SwipeToClose({required this.child});

  final Widget child;

  @override
  State<_SwipeToClose> createState() => _SwipeToCloseState();
}

class _SwipeToCloseState extends State<_SwipeToClose> {
  _DrawerDragController? _drag;

  double get _width {
    final size = context.size;
    return size == null || size.width <= 0 ? 0 : size.width;
  }

  @override
  Widget build(BuildContext context) {
    final route = ModalRoute.of(context);
    if (route is! _MeridianDrawerRoute) return widget.child;
    return GestureDetector(
      // deferToChild, so buttons and scrollables inside the panel keep winning
      // the hits they should. A HORIZONTAL recognizer also loses the arena to
      // the panel's vertical SingleChildScrollView on a vertical drag, which is
      // what keeps scrolling the panel from closing it.
      behavior: HitTestBehavior.deferToChild,
      excludeFromSemantics: true,
      onHorizontalDragStart: (_) => _drag = route.startDrag(),
      onHorizontalDragUpdate: (d) =>
          _drag?.update(d.primaryDelta ?? 0, _width),
      onHorizontalDragEnd: (d) {
        _drag?.end(d.primaryVelocity ?? 0, _width);
        _drag = null;
      },
      onHorizontalDragCancel: () {
        _drag?.end(0, _width);
        _drag = null;
      },
      child: widget.child,
    );
  }
}

/// Owns one drag of the drawer, from touch-down to release.
///
/// Modelled on Flutter's own `_CupertinoBackGestureController`, including the
/// `didStartUserGesture`/`didStopUserGesture` pairing: the navigator must know a
/// gesture is driving the transition, or it finalises the pop before the release
/// animation has run and the drawer vanishes instead of sliding out.
class _DrawerDragController {
  _DrawerDragController({required this.controller, required this.navigator}) {
    navigator.didStartUserGesture();
  }

  final AnimationController controller;
  final NavigatorState navigator;
  bool _ended = false;

  void update(double deltaPx, double width) {
    if (_ended || width <= 0) return;
    // The drawer is on the RIGHT, so dragging right pushes it away: value 1 is
    // fully open, 0 is gone.
    controller.value = (controller.value - deltaPx / width).clamp(0.0, 1.0);
  }

  void end(double velocityPx, double width) {
    if (_ended) return;
    _ended = true;

    final widthsPerSecond = width <= 0 ? 0.0 : velocityPx / width;
    final bool close;
    if (widthsPerSecond.abs() >= MeridianDrawer.flingWidthsPerSecond) {
      // Velocity decides first: a fast flick closes however little ground it
      // covered, and a fast flick back OPENS however far it had already gone.
      close = widthsPerSecond > 0;
    } else {
      close = controller.value < MeridianDrawer.closeFraction;
    }

    if (close) {
      // pop() BEFORE animating, exactly as Cupertino does: while a user gesture
      // is in progress the navigator defers finalising, so the route stays alive
      // to play the rest of the slide from wherever the finger let go.
      navigator.pop();
      if (controller.isAnimating) {
        controller.animateBack(0.0,
            duration: MeridianDrawer.slide, curve: Curves.easeOut);
      }
    } else {
      controller.animateTo(1.0,
          duration: MeridianDrawer.slide, curve: Curves.easeOut);
    }

    if (controller.isAnimating) {
      late AnimationStatusListener listener;
      listener = (_) {
        navigator.didStopUserGesture();
        controller.removeStatusListener(listener);
      };
      controller.addStatusListener(listener);
    } else {
      navigator.didStopUserGesture();
    }
  }
}

/// The drawer's route, subclassed for ONE reason: `TransitionRoute.controller`
/// is `@protected`, and a drag has to write to it. A subclass may reach it;
/// anything else would be an analyzer violation and a lie about the contract.
class _MeridianDrawerRoute extends PageRouteBuilder<void> {
  _MeridianDrawerRoute(Widget Function(BuildContext, Animation<double>) page)
      : super(
          opaque: false,
          // The scrim inside the drawer is the tap target; the route's own
          // barrier would sit above it and swallow the tap.
          barrierDismissible: false,
          transitionDuration: MeridianDrawer.slide,
          reverseTransitionDuration: MeridianDrawer.slide,
          pageBuilder: (context, animation, _) => page(context, animation),
        );

  _DrawerDragController? startDrag() {
    final c = controller;
    final nav = navigator;
    if (c == null || nav == null || !isCurrent) return null;
    return _DrawerDragController(controller: c, navigator: nav);
  }
}

Route<void> _drawerRoute(
        Widget Function(BuildContext, Animation<double>) page) =>
    _MeridianDrawerRoute(page);

/// Pushes [MeridianDrawer] as a transparent route so the conversation keeps
/// rendering (and running) behind the scrim.
///
/// A single-layer drawer: the panel has nowhere to navigate to.
Route<void> meridianDrawerRoute({
  required String title,
  required Widget child,
}) =>
    _drawerRoute((context, animation) => MeridianDrawer(
          title: title,
          animation: animation,
          onClose: () => Navigator.of(context).maybePop(),
          child: child,
        ));

/// A drawer whose content navigates in place. The builder owns the layer state
/// and builds its own MeridianDrawer, so `title`, `onBack` and `child` can all
/// change without pushing a second route — one scrim, one slide, and system
/// back can pop a layer instead of the whole drawer.
///
/// [onClose] is handed `Navigator.pop`, not `maybePop`: a builder that wants
/// system back to pop a sub-layer instead of the route (e.g. via `PopScope`)
/// still needs its own close controls (✕, scrim) to close the WHOLE drawer in
/// one tap regardless of which layer is showing. `maybePop` would route
/// through that same `PopScope` and get swallowed by it — `pop` does not
/// consult `Route.popDisposition`/`PopScope.canPop` at all, so it bypasses
/// the builder's own layer interception the same way an explicit dialog
/// button bypasses a `PopScope` guarding the hardware back gesture.
Route<void> meridianHostedDrawerRoute({
  required Widget Function(BuildContext, Animation<double>, VoidCallback onClose)
      builder,
}) =>
    _drawerRoute((context, animation) =>
        builder(context, animation, () => Navigator.of(context).pop()));
