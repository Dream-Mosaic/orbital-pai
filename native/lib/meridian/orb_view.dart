import 'package:flutter/scheduler.dart';
import 'package:flutter/material.dart';
import 'orb_painter.dart';
import 'orb_state.dart';

/// Hosts the orb's animation clock. Runs a Ticker, advances the frame, and paints
/// under a RepaintBoundary so the orb never rebuilds the surrounding tree.
///
/// The clock runs ONLY when there is something to animate: `off` is frozen by
/// contract (OrbFrame.advance returns early) and reduced motion holds a still
/// frame. In both cases the Ticker is STOPPED, so the engine can actually idle
/// instead of servicing a vsync callback 60x/second forever — the real power
/// lever on a 24/7 wall device (M-T3c). This must stay paired with
/// MeridianSurface's breathe controller: gating one without the other buys
/// nothing, because either alone keeps the frame pipeline awake.
class OrbView extends StatefulWidget {
  const OrbView({
    super.key,
    required this.frame,
    this.fallbackSize = const Size(280, 280),
  });

  final OrbFrame frame;

  /// Size used on an axis whose incoming constraint is UNBOUNDED. `Size.infinite`
  /// asserts there (M-T3e); an unbounded axis is always a layout mistake, but it
  /// must not crash the app.
  final Size fallbackSize;

  @override
  State<OrbView> createState() => _OrbViewState();
}

class _OrbViewState extends State<OrbView> with SingleTickerProviderStateMixin {
  Ticker? _ticker;
  Duration _last = Duration.zero;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    widget.frame.addListener(_syncTicker);
    _syncTicker();
  }

  @override
  void didUpdateWidget(OrbView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.frame, widget.frame)) {
      oldWidget.frame.removeListener(_syncTicker);
      widget.frame.addListener(_syncTicker);
    }
    _syncTicker();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _syncTicker();
  }

  void _syncTicker() {
    final ticker = _ticker;
    if (ticker == null) return;
    final shouldRun = !_reduceMotion && widget.frame.state != OrbState.off;
    if (shouldRun && !ticker.isActive) {
      _last = Duration.zero;
      ticker.start();
    } else if (!shouldRun && ticker.isActive) {
      ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    final dtRaw = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    // Clamp like orb.js (max 0.05s) so a stalled frame doesn't jump the clock.
    final dt = dtRaw <= 0 ? 0.016 : (dtRaw > 0.05 ? 0.05 : dtRaw);
    widget.frame.advance(dt);
  }

  @override
  void dispose() {
    // ChangeNotifier.removeListener is explicitly safe on a disposed instance,
    // which matters because VoiceController.dispose() disposes the OrbFrame.
    widget.frame.removeListener(_syncTicker);
    _ticker?.dispose();
    _ticker = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.hasBoundedWidth
              ? constraints.maxWidth
              : widget.fallbackSize.width;
          final h = constraints.hasBoundedHeight
              ? constraints.maxHeight
              : widget.fallbackSize.height;
          return CustomPaint(
            painter: OrbPainter(widget.frame),
            size: Size(w, h),
          );
        },
      ),
    );
  }
}
