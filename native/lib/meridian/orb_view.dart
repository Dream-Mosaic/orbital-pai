import 'package:flutter/scheduler.dart';
import 'package:flutter/material.dart';
import 'orb_painter.dart';

/// Hosts the orb's animation clock. Runs a Ticker, advances the frame, and paints
/// under a RepaintBoundary so the orb never rebuilds the surrounding tree.
///
/// Honours reduced-motion (MediaQuery.disableAnimations): the clock stops, so the
/// orb holds a still frame in the correct colours.
class OrbView extends StatefulWidget {
  const OrbView({super.key, required this.frame});

  final OrbFrame frame;

  @override
  State<OrbView> createState() => _OrbViewState();
}

class _OrbViewState extends State<OrbView>
    with SingleTickerProviderStateMixin {
  Ticker? _ticker;
  Duration _last = Duration.zero;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  }

  void _onTick(Duration elapsed) {
    final dtRaw = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    if (_reduceMotion) return;
    // Clamp like orb.js (max 0.05s) so a stalled frame doesn't jump the clock.
    final dt = dtRaw <= 0 ? 0.016 : (dtRaw > 0.05 ? 0.05 : dtRaw);
    widget.frame.advance(dt);
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _ticker = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: OrbPainter(widget.frame),
        size: Size.infinite,
      ),
    );
  }
}
