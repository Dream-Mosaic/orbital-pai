import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'tokens.dart';

/// Your live speech, centred IN the orb. Ported from `#orb-caption` in app.css
/// and `setCaption()` in index.js — **with the overflow fixed**.
///
/// The box it is given comes from `OrbBezel._captionBox`, which inscribes it in
/// the glass sphere. It used to be a strip under the orb, kept clear of the
/// middle so it would not cover the waveform while you talked; the waveform is
/// Henry's voice only now, and this is only ever yours, so the two can never be
/// on screen at once.
///
/// The web sets an inline font-size from a three-step length ladder
/// (index.js:485) and nothing else, so a long partial transcript spills out of
/// the ring and over the detents. Here the ladder is only the STARTING size: the
/// text is then measured against a real box and stepped down 1px at a time until
/// it fits, floored at 11px with an ellipsis. It never scales UP, so a short
/// caption keeps its 25.6px hero size exactly as the web does.
class LiveCaption extends StatefulWidget {
  const LiveCaption({
    super.key,
    required this.text,
    required this.width,
    required this.height,
    this.pending = false,
  });

  final String text;
  final double width;
  final double height;

  /// Whether Ink-2 is still holding words it has not sent yet.
  ///
  /// Ink-2 never revises text it has already emitted, so it withholds each
  /// trailing word until enough right-context makes it unrevisable. Mid-
  /// sentence the last word or two has genuinely not arrived, and the whole
  /// tail lands at once on `turn.end` — which is why the caption always looked
  /// a beat behind your mouth and then caught up when you stopped. That is a
  /// property of the model, not a latency we can tune away: there is no
  /// unstable-hypothesis mode to switch on, and `min_volume` /
  /// `max_silence_duration_secs` are ink-whisper parameters that ink-2 ignores.
  /// The ellipsis is the honest fix — it makes the withheld tail read as
  /// "still transcribing" instead of as dropped words.
  ///
  /// It must NEVER trail the resting wake prompt, which is not pending
  /// anything. `VoiceController` therefore keys this on the caption's
  /// PROVENANCE — set only by a `partial` message — rather than on a turn
  /// phase, which would also be true while the prompt is showing.
  final bool pending;

  static const double _lineHeight = 1.22;
  static const double _minFontSize = 11.0;

  /// The withheld tail, as glyphs. Three, so the pulse has somewhere to travel.
  static const String pendingDots = '...';

  static const Duration _dotCycle = Duration(milliseconds: 1200);

  /// Dimmest a dot gets. Above zero on purpose: the dots are part of the
  /// measured layout, and one blinking out entirely reads as a glitch rather
  /// than as waiting.
  static const double _dotMinOpacity = 0.28;

  /// index.js:485 — `len > 80 ? 0.95 : len > 40 ? 1.2 : 1.6` rem.
  static double startFontSize(int length) =>
      length > 80 ? 15.2 : (length > 40 ? 19.2 : 25.6);

  /// Opacity of dot [i] of three at [phase], one full cycle over `0..1`.
  ///
  /// A travelling pulse: each dot peaks a third of a cycle after the one
  /// before it. Opacity ONLY — never a dot's presence — because all three
  /// glyphs are laid out and measured whether they are lit or not. Animating
  /// presence instead would change the advance width every frame, and the
  /// font-size ladder would re-step under it.
  static double dotOpacity(int i, double phase) {
    var p = (phase - i / 3) % 1.0;
    if (p < 0) p += 1.0;
    final pulse = math.max(0.0, math.cos(2 * math.pi * p));
    return _dotMinOpacity + (1 - _dotMinOpacity) * pulse;
  }

  static TextStyle _style(double size) => TextStyle(
        fontFamily: kBodyFamily,
        fontSize: size,
        height: _lineHeight,
        fontWeight: FontWeight.w500,
        color: M.youSoft,
        shadows: [
          Shadow(color: M.you.withValues(alpha: 0.4), blurRadius: 16),
          const Shadow(offset: Offset(0, 1), blurRadius: 3, color: Color(0xB3000000)),
        ],
      );

  /// Largest size <= [start] whose laid-out height fits [maxHeight] at [maxWidth].
  static double fitFontSize(
    String text,
    double maxWidth,
    double maxHeight, {
    double? start,
  }) {
    final s0 = start ?? startFontSize(text.length);
    if (text.isEmpty || maxWidth <= 0 || maxHeight <= 0) return s0;
    for (var size = s0; size >= _minFontSize; size -= 1.0) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: _style(size)),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      )..layout(maxWidth: maxWidth);
      if (painter.height <= maxHeight) return size;
    }
    return _minFontSize;
  }

  @override
  State<LiveCaption> createState() => _LiveCaptionState();
}

class _LiveCaptionState extends State<LiveCaption>
    with SingleTickerProviderStateMixin {
  late final AnimationController _dots = AnimationController(
    vsync: this,
    duration: LiveCaption._dotCycle,
  );

  bool _reduceMotion = false;

  bool get _animate =>
      widget.pending && widget.text.isNotEmpty && !_reduceMotion;

  @override
  void initState() {
    super.initState();
    _syncDots();
  }

  @override
  void didUpdateWidget(LiveCaption oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncDots();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _syncDots();
  }

  /// The clock runs ONLY while there are dots to move — mirrors OrbView's
  /// ticker gating, for the same reason and on the same device: a caption that
  /// is empty, settled, or showing the wake prompt has nothing to animate, and
  /// this thing is awake 24/7.
  void _syncDots() {
    if (_animate && !_dots.isAnimating) {
      _dots.repeat();
    } else if (!_animate && _dots.isAnimating) {
      _dots.stop();
      _dots.value = 0;
    }
  }

  @override
  void dispose() {
    _dots.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.text;
    if (text.isEmpty) {
      return SizedBox(width: widget.width, height: widget.height);
    }
    final pending = widget.pending;
    // Measured WITH the dots, so the type is sized for the widest state the
    // caption takes and cannot re-step mid-utterance. Fitted FROM the ladder
    // rung of the caption alone, so three dots can never knock a 40- or
    // 80-character partial down a rung it would otherwise have kept.
    final size = LiveCaption.fitFontSize(
      pending ? text + LiveCaption.pendingDots : text,
      widget.width,
      widget.height,
      start: LiveCaption.startFontSize(text.length),
    );
    final maxLines =
        (widget.height / (size * LiveCaption._lineHeight)).floor().clamp(1, 99);
    final style = LiveCaption._style(size);

    Widget caption(double phase) => Text.rich(
          TextSpan(
            text: text,
            children: pending
                ? [
                    for (var i = 0; i < LiveCaption.pendingDots.length; i++)
                      TextSpan(
                        text: LiveCaption.pendingDots[i],
                        // Unstyled when motion is off: a plain, fully-lit
                        // ellipsis still says "there is more coming", which is
                        // the whole message. Only the travelling pulse goes.
                        style: _animate
                            ? TextStyle(
                                color: M.youSoft.withValues(
                                  alpha: LiveCaption.dotOpacity(i, phase),
                                ),
                              )
                            : null,
                      ),
                  ]
                : null,
          ),
          textAlign: TextAlign.center,
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
          style: style,
        );

    return SizedBox(
      width: widget.width,
      height: widget.height,
      // Centred vertically, not top-aligned. The box is now the sphere's
      // inscribed rectangle rather than a strip under the orb, so a one-line
      // caption in a top-aligned box would sit visibly high of the glass's
      // centre instead of in it.
      child: Center(
        child: _animate
            // Confined to its own layer: the dots rebuild every frame and the
            // bezel behind them has no reason to repaint with them. The
            // font-size fit stays OUTSIDE the builder — it runs a TextPainter
            // loop, which must not run per frame.
            ? RepaintBoundary(
                child: AnimatedBuilder(
                  animation: _dots,
                  builder: (_, __) => caption(_dots.value),
                ),
              )
            : caption(0),
      ),
    );
  }
}
