import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../voice/camera_relay.dart';
import 'tokens.dart';

/// "Henry, look at this" in the orb's glass: the live viewfinder clipped to
/// the sphere, a big 3·2·1, a white shutter flash, then the frozen snapshot
/// while Henry thinks about it (spec 2026-10-23, game night §1).
///
/// Built through the bezel's `face` slot, so it is handed the same box the
/// resting face gets — the rectangle INSCRIBED in the sphere. The glass is the
/// circle through that box's corners, so its diameter is the box's diagonal;
/// the face paints that whole circle, past its own box (nothing above it
/// clips), and needs no second copy of the bezel's geometry to do it.
class CameraFace extends StatefulWidget {
  const CameraFace({
    super.key,
    required this.width,
    required this.height,
    required this.shot,
    required this.preview,
  });

  final double width;
  final double height;
  final CameraShot shot;

  /// The camera's viewfinder, cover-fitted to whatever box it gets
  /// ([CameraService.preview]).
  final Widget Function() preview;

  @override
  State<CameraFace> createState() => _CameraFaceState();
}

/// The parts tests look for.
const Key cameraPreviewKey = ValueKey('camera-preview');
const Key cameraSnapshotKey = ValueKey('camera-snapshot');
const Key cameraFlashKey = ValueKey('camera-flash');

class _CameraFaceState extends State<CameraFace>
    with SingleTickerProviderStateMixin {
  /// Parked at 1 (spent, invisible); run from 0 at the shutter.
  late final AnimationController _flash = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 560),
    value: 1,
  );

  /// A quick white bloom, then a long fall-off that hides the swap from the
  /// moving viewfinder to the frozen picture underneath it.
  late final Animation<double> _flashOpacity = TweenSequence<double>([
    TweenSequenceItem(
        tween: Tween(begin: 0.0, end: 0.92)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 10),
    TweenSequenceItem(
        tween: Tween(begin: 0.92, end: 0.0)
            .chain(CurveTween(curve: Curves.easeInCubic)),
        weight: 90),
  ]).animate(_flash);

  /// The capture the flash last ran for: once per picture, however the
  /// shutter and the snapshot land across frames.
  String? _flashedFor;

  bool _shot(CameraShot s) =>
      s.phase == CameraPhase.shutter || s.phase == CameraPhase.frozen;

  @override
  void initState() {
    super.initState();
    switch (widget.shot.phase) {
      case CameraPhase.shutter:
        _fire();
      case CameraPhase.frozen:
        // Built after the shutter (a layout change remounted it): no flash.
        _flashedFor = widget.shot.id;
      case CameraPhase.countdown:
        break;
    }
  }

  @override
  void didUpdateWidget(CameraFace old) {
    super.didUpdateWidget(old);
    if (_shot(widget.shot) && _flashedFor != widget.shot.id) _fire();
  }

  void _fire() {
    _flashedFor = widget.shot.id;
    _flash.forward(from: 0);
  }

  @override
  void dispose() {
    _flash.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.width;
    final h = widget.height;
    final d = math.sqrt(w * w + h * h);
    final shot = widget.shot;
    final snapshot = shot.snapshot;
    final live = shot.previewing && shot.phase != CameraPhase.frozen;

    return SizedBox(
      width: w,
      height: h,
      child: OverflowBox(
        minWidth: d,
        maxWidth: d,
        minHeight: d,
        maxHeight: d,
        child: ClipOval(
          child: Stack(
            fit: StackFit.expand,
            children: [
              // The glass with nothing in it yet: the camera is opening.
              const ColoredBox(color: Color(0xFF05060B)),
              AnimatedOpacity(
                key: cameraPreviewKey,
                opacity: live ? 1 : 0,
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOut,
                child: widget.preview(),
              ),
              if (snapshot != null)
                Image.memory(
                  snapshot,
                  key: cameraSnapshotKey,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                ),
              const IgnorePointer(child: _Lens()),
              // A soft shade behind the digit, so it reads over any scene.
              IgnorePointer(
                child: AnimatedOpacity(
                  opacity: shot.count > 0 ? 1 : 0,
                  duration: const Duration(milliseconds: 220),
                  child: const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        radius: 0.5,
                        colors: [Color(0x52000000), Color(0x00000000)],
                      ),
                    ),
                  ),
                ),
              ),
              Center(child: _Countdown(count: shot.count, glass: d)),
              IgnorePointer(
                child: FadeTransition(
                  opacity: _flashOpacity,
                  child: const ColoredBox(
                      key: cameraFlashKey, color: Color(0xFFFFFFFF)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The glass over the picture: the sphere's falloff toward its rim, a
/// highlight where the room's light would catch it, and a hairline edge —
/// so what the camera sees reads as being IN the orb, not pasted on it.
class _Lens extends StatelessWidget {
  const _Lens();

  @override
  Widget build(BuildContext context) => const Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                colors: [
                  Color(0x00000000),
                  Color(0x00000000),
                  Color(0x8C000000)
                ],
                stops: [0.0, 0.66, 1.0],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(-0.38, -0.62),
                radius: 0.62,
                colors: [Color(0x1FFFFFFF), Color(0x00FFFFFF)],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.fromBorderSide(
                  BorderSide(color: Color(0x1FFFFFFF), width: 1)),
            ),
          ),
        ],
      );
}

/// The big 3·2·1, each digit landing slightly large and settling.
class _Countdown extends StatelessWidget {
  const _Countdown({required this.count, required this.glass});

  final int count;
  final double glass;

  @override
  Widget build(BuildContext context) {
    final size = glass * 0.42;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: ScaleTransition(
          scale: Tween<double>(begin: 1.3, end: 1.0).animate(anim),
          child: child,
        ),
      ),
      child: count > 0
          ? Text(
              '$count',
              key: ValueKey('camera-count-$count'),
              style: TextStyle(
                fontFamily: kDisplayFamily,
                fontSize: size,
                height: 1.0,
                fontWeight: FontWeight.w300,
                fontVariations: MType.wght(340),
                fontFeatures: const [FontFeature.tabularFigures()],
                color: const Color(0xF2FFFFFF),
                shadows: const [
                  Shadow(color: Color(0x8C000000), blurRadius: 28),
                  Shadow(color: Color(0x59000000), blurRadius: 6),
                ],
              ),
            )
          : const SizedBox.shrink(key: ValueKey('camera-count-none')),
    );
  }
}
