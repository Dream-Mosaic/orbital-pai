import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../voice/timers_model.dart';
import 'tokens.dart';

/// The live timers, between the orb pane and the thread: one chip per timer,
/// hung off the meridian in Henry's field (right of the rail, where his lines
/// sit), with the spine carried through so the elbow still meets the thread.
///
/// Zero height when there are no timers — no gap, no rail segment, nothing.
///
/// A chip: an engraved label ("PASTA", or "TIMER" when unnamed), a big tabular
/// countdown, and a hairline of elapsed time in [M.timer] — the hold-to-talk
/// tray's glowing slit, in coral. A ringing chip pulses coral and reads "TAP TO
/// STOP"; a tap dismisses it. A running chip cancels on long-press (with a
/// haptic) — no dialog, the gesture is deliberate enough on its own.
///
/// Ticks once a second, and only while a timer is running: the wake-up is
/// aligned to the soonest timer's next whole second, so its digits flip on
/// time rather than up to a second late.
class TimerStrip extends StatefulWidget {
  const TimerStrip({
    super.key,
    required this.timers,
    required this.clock,
    required this.glow,
    this.onDismiss,
    this.onCancel,
  });

  final List<TimerEntry> timers;

  /// The monotonic clock the entries were anchored to.
  final MonoClock clock;

  /// `paletteFor(orbState).glow` — the rail segment recolours with the orb,
  /// like the elbow above it and the spine below.
  final Color glow;
  final void Function(int id)? onDismiss;
  final void Function(int id)? onCancel;

  @override
  State<TimerStrip> createState() => _TimerStripState();
}

class _TimerStripState extends State<TimerStrip>
    with SingleTickerProviderStateMixin {
  Timer? _tick;

  /// Whether the second-tick is armed — what the "stops ticking" test asserts on, since the
  /// binding's pending-timer check only runs after teardown has already cancelled everything.
  @visibleForTesting
  bool get debugTicking => _tick != null;
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(TimerStrip old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  /// Run the second-tick and the ringing pulse only while they have work.
  void _sync() {
    _tick?.cancel();
    _tick = null;
    _scheduleTick();

    final ringing = widget.timers.any((t) => t.ringing);
    if (ringing && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!ringing && _pulse.isAnimating) {
      _pulse
        ..stop()
        ..value = 0;
    }
  }

  void _scheduleTick() {
    final now = widget.clock();
    final left = [
      for (final t in widget.timers)
        if (!t.ringing) t.remainingAt(now),
    ].where((d) => d > Duration.zero);
    // Nothing counting down: nothing to redraw until the server pushes again.
    if (left.isEmpty) return;
    final soonest = left.reduce((a, b) => a < b ? a : b);
    final intoSecond = soonest.inMicroseconds % Duration.microsecondsPerSecond;
    final wait = Duration(
        microseconds:
            intoSecond == 0 ? Duration.microsecondsPerSecond : intoSecond);
    _tick = Timer(wait + const Duration(milliseconds: 5), () {
      if (!mounted) return;
      setState(() {});
      _scheduleTick();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.timers.isEmpty) return const SizedBox.shrink();
    final now = widget.clock();

    return LayoutBuilder(builder: (context, constraints) {
      final w = constraints.maxWidth;
      // The thread's two rail bases (see Thread): the spine at 36% of the column
      // plus 8, and Henry's field at rail + 18 of the scroller's content box.
      final spineX = w * 0.36 + 8;
      final fieldX = 6 + (w - 12) * 0.36 + 18;

      // Full column width, ALWAYS: the voice screen's Column centres loose
      // children, so a Stack left to shrink-wrap its chips would be centred
      // too — and its rail would land right of the thread's spine.
      return Padding(
        padding: const EdgeInsets.only(bottom: M.columnGap),
        child: SizedBox(
          width: w,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // Up into the gap above to meet the elbow; down to where the
              // thread's own spine (which reaches 12px above the thread) takes over.
              Positioned(
                left: spineX,
                width: 1.5,
                top: -M.columnGap,
                bottom: 0,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: widget.glow.withValues(alpha: 0.6),
                      boxShadow: [
                        BoxShadow(
                            color: widget.glow.withValues(alpha: 0.35),
                            blurRadius: 5),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                left: spineX + 0.75 - 3.5,
                top: _TimerChip._padTop + 2,
                child: const _Node(),
              ),
              Padding(
                padding: EdgeInsets.only(left: fieldX),
                // Overflowing chips stop at the column edge; a ringing chip's glow
                // still gets room above, below and to its left.
                child: ClipRect(
                  clipper: const _GlowRoom(),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    clipBehavior: Clip.none,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final (i, t) in widget.timers.indexed) ...[
                          if (i > 0) const SizedBox(width: 8),
                          _TimerChip(
                            key: ValueKey('timer-${t.id}'),
                            entry: t,
                            now: now,
                            pulse: _pulse,
                            onDismiss: widget.onDismiss,
                            onCancel: widget.onCancel,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    });
  }
}

/// The chips' clip: exact at the right (the column edge), generous elsewhere,
/// so the ringing glow is not sliced off while overflow still is.
class _GlowRoom extends CustomClipper<Rect> {
  const _GlowRoom();

  static const double _bleed = 20;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTRB(-_bleed, -_bleed, size.width, size.height + _bleed);

  @override
  bool shouldReclip(_GlowRoom oldClipper) => false;
}

/// The strip's node on the spine — a thread line's filled dot, in coral.
class _Node extends StatelessWidget {
  const _Node();

  @override
  Widget build(BuildContext context) => Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: M.timer,
          boxShadow: [
            BoxShadow(color: M.timer.withValues(alpha: 0.8), blurRadius: 9)
          ],
        ),
      );
}

class _TimerChip extends StatelessWidget {
  const _TimerChip({
    super.key,
    required this.entry,
    required this.now,
    required this.pulse,
    this.onDismiss,
    this.onCancel,
  });

  final TimerEntry entry;
  final Duration now;
  final Animation<double> pulse;
  final void Function(int id)? onDismiss;
  final void Function(int id)? onCancel;

  static const double _labelSize = 8.32; // the hold-to-talk label's 0.52rem
  static const double _timeSize = 22;
  static const double _footer = 11;

  /// Two chips fit Henry's field on a 360dp phone.
  static const double _minWidth = 84;
  static const double _padX = 11;

  /// The label row's top inset — the strip's node lines up with it, the way a
  /// thread line's node lines up with its speaker label.
  static const double _padTop = 8;

  @override
  Widget build(BuildContext context) {
    final ringing = entry.ringing;
    final label = (entry.label ?? 'timer').toUpperCase();
    final time = formatCountdown(entry.remainingAt(now));

    return Semantics(
      button: true,
      label: ringing
          ? '$label ringing. Tap to stop.'
          : '$label, $time left. Long-press to cancel.',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: ringing ? () => onDismiss?.call(entry.id) : null,
        onLongPress: ringing
            ? null
            : () {
                HapticFeedback.mediumImpact();
                onCancel?.call(entry.id);
              },
        child: AnimatedBuilder(
          animation: pulse,
          builder: (context, _) {
            // 0..1 while ringing (eased both ways), 0 at rest.
            final p = ringing ? Curves.easeInOut.transform(pulse.value) : 0.0;
            return Container(
              constraints: const BoxConstraints(minWidth: _minWidth),
              padding: const EdgeInsets.fromLTRB(_padX, _padTop, _padX, 8),
              decoration: BoxDecoration(
                // Ringing: OPAQUE dark glass with a coral tint — a translucent
                // fill lets the glow below show through and floods the chip red.
                color: ringing
                    ? Color.alphaBlend(
                        M.timer.withValues(alpha: 0.05 + 0.05 * p), M.shell)
                    : const Color(0xFFFFFFFF).withValues(alpha: 0.016),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: ringing
                      ? M.timer.withValues(alpha: 0.4 + 0.4 * p)
                      : const Color(0xFFFFFFFF).withValues(alpha: 0.055),
                ),
                boxShadow: [
                  if (ringing)
                    BoxShadow(
                      color: M.timer.withValues(alpha: 0.2 + 0.45 * p),
                      blurRadius: 18,
                      spreadRadius: -5,
                    ),
                ],
              ),
              child: IntrinsicWidth(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ConstrainedBox(
                      // A long spoken label must not stretch the chip.
                      constraints: const BoxConstraints(maxWidth: 120),
                      child: Text(
                        label,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.fade,
                        style: _engraved(ringing
                            ? M.timer.withValues(alpha: 0.9)
                            : M.chromeDim.withValues(alpha: 0.42)),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      time,
                      maxLines: 1,
                      style: TextStyle(
                        fontFamily: kDisplayFamily,
                        fontSize: _timeSize,
                        height: 1.1,
                        fontWeight: FontWeight.w500,
                        fontVariations: MType.wght(500),
                        fontFeatures: const [FontFeature.tabularFigures()],
                        letterSpacing: MType.track(_timeSize, 0.01),
                        color:
                            ringing ? M.timer : M.ink.withValues(alpha: 0.92),
                        shadows: [
                          if (ringing)
                            Shadow(
                                color:
                                    M.timer.withValues(alpha: 0.35 + 0.35 * p),
                                blurRadius: 12),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    // One fixed-height footer for both states, so a timer going
                    // off never changes the strip's height under the thread.
                    SizedBox(
                      height: _footer,
                      child: ringing
                          ? Text(
                              'TAP TO STOP',
                              maxLines: 1,
                              softWrap: false,
                              // Smaller and tighter than the label: it has
                              // to fit the chip, not widen it.
                              style: _engraved(
                                  M.chromeDim.withValues(alpha: 0.5 + 0.25 * p),
                                  size: 7.2,
                                  track: 0.26),
                            )
                          : Center(
                              child: _Slit(progress: entry.progressAt(now))),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  static TextStyle _engraved(Color colour,
          {double size = _labelSize, double track = 0.4}) =>
      TextStyle(
        fontFamily: kDisplayFamily,
        fontSize: size,
        fontWeight: FontWeight.w600,
        fontVariations: MType.wght(600),
        letterSpacing: MType.track(size, track),
        color: colour,
        shadows: MType.engraved,
      );
}

/// Elapsed time as a coral hairline on a faint track — the hold-to-talk slit.
class _Slit extends StatelessWidget {
  const _Slit({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 2,
      width: double.infinity,
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFFFFFFFF).withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          FractionallySizedBox(
            widthFactor: math.max(progress, 0.0),
            heightFactor: 1,
            alignment: Alignment.centerLeft,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: M.timer,
                borderRadius: BorderRadius.circular(2),
                boxShadow: [
                  BoxShadow(
                      color: M.timer.withValues(alpha: 0.6), blurRadius: 7),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
