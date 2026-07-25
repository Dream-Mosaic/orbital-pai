import 'package:flutter/material.dart';
import 'orb_state.dart';
import 'palette.dart';

/// The lit "device" surface. Ported from `main:has(#voice)` (+ ::before/::after)
/// in server/assets/css/app.css:
///   * base: a top-anchored dark radial with a 160deg white sheen painted over it
///   * bleed: an oversized radial glow seated at the orb (50%, 27%), tinted by the
///     live state colour, opacity = that state's `bleed`, cross-fading over 0.8s
///     and breathing scale(1.05) on a 9s loop
///   * sheen: inner top highlight + inner bottom shadow so it reads as glass
class MeridianSurface extends StatefulWidget {
  const MeridianSurface({
    super.key,
    required this.state,
    required this.child,
  });

  final OrbState state;
  final Widget child;

  @override
  State<MeridianSurface> createState() => _MeridianSurfaceState();
}

class _MeridianSurfaceState extends State<MeridianSurface>
    with SingleTickerProviderStateMixin {
  // `bleed-breathe 9s ease-in-out infinite` -> a 4.5s half-cycle, reversing.
  late final AnimationController _breathe = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 4500),
  );
  late final Animation<double> _scale = Tween<double>(begin: 1.0, end: 1.05)
      .animate(CurvedAnimation(parent: _breathe, curve: Curves.easeInOut));

  @override
  void initState() {
    super.initState();
    _breathe.repeat(reverse: true);
  }

  @override
  void dispose() {
    _breathe.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pal = paletteFor(widget.state);
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    return DecoratedBox(
      // base: top-anchored dark radial, painted first (farthest back)
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0.0, -1.0),
          radius: 1.4,
          colors: [Color(0xFF090A12), Color(0xFF060710)],
          stops: [0.0, 0.6],
        ),
      ),
      child: DecoratedBox(
        // linear white sheen, painted over the dark radial
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0x05FFFFFF), Color(0x00FFFFFF)],
            stops: [0.0, 0.35],
          ),
        ),
        child: ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              // --- orb-light bleed ---
              IgnorePointer(
                child: AnimatedOpacity(
                  opacity: pal.bleed,
                  duration: reduceMotion
                      ? Duration.zero
                      : const Duration(milliseconds: 800),
                  curve: Curves.easeInOut,
                  child: AnimatedBuilder(
                    animation: _breathe,
                    builder: (context, _) {
                      final s = reduceMotion ? 1.0 : _scale.value;
                      return Transform.scale(
                        scale: s,
                        alignment: const Alignment(0.0, -0.46), // (50%, 27%)
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: RadialGradient(
                              center: const Alignment(0.0, -0.46),
                              radius: 1.28, // ~ the -28% inset overscan
                              colors: [
                                pal.glow.withValues(alpha: 0.20),
                                pal.glow.withValues(alpha: 0.07),
                                pal.glow.withValues(alpha: 0.0),
                              ],
                              stops: const [0.0, 0.32, 0.62],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),

              // --- content ---
              widget.child,

              // --- glass sheen: inner top highlight + inner bottom shadow ---
              IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.white.withValues(alpha: 0.055),
                        Colors.white.withValues(alpha: 0.0),
                        Colors.black.withValues(alpha: 0.0),
                        Colors.black.withValues(alpha: 0.85),
                      ],
                      stops: const [0.0, 0.004, 0.86, 1.0],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
