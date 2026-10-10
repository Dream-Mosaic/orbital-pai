import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../tokens.dart';
import 'card_frame.dart';

/// Cook mode's one step (`get_recipe` with a `step`), for a tablet propped on
/// the counter: where you are in the recipe, the step itself as large as the
/// column allows, its times as timer suggestions, and a glance at what's next.
class CookStepCard extends StatelessWidget {
  const CookStepCard({super.key, required this.data});

  final Map<String, dynamic> data;

  static const Color accent = M.recipe;

  /// The step text's room. It starts at [_maxSize] and steps down until it
  /// fits, so a short step is big and a long one is still all there.
  static const double _textRoom = 168;
  static const double _maxSize = 25;
  static const double _minSize = 15;

  @override
  Widget build(BuildContext context) {
    final progress = data.str('progress');
    final step = data['step'];
    final count = data['step_count'];
    final timers = data.strs('timers');
    final nextLabel = data.str('next_label');
    final next = data.str('next');
    return CardFrame(
      accent: accent,
      label: data.str('title') ?? '',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // In ink, not the accent: the header already carries the recipe's
          // colour, and the bar under this says the same thing in it.
          if (progress != null)
            Text(
              progress.toUpperCase(),
              style: CardStyle.label(M.ink.withValues(alpha: 0.86), size: 9.6),
            ),
          if (step is int && count is int && count > 0) ...[
            const SizedBox(height: 7),
            StepProgress(step: step, count: count, colour: accent),
          ],
          const SizedBox(height: 12),
          FitText(
            data.str('text') ?? '',
            maxHeight: _textRoom,
            maxSize: _maxSize,
            minSize: _minSize,
            style: CardStyle.body(_maxSize, colour: M.ink, weight: 470, height: 1.26)
                .copyWith(letterSpacing: -0.15),
          ),
          if (timers.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [for (final t in timers) TimerPill(t)],
            ),
          ],
          if (nextLabel != null) ...[
            const CardRule(vertical: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  nextLabel.toUpperCase(),
                  style: CardStyle.label(M.chromeDim.withValues(alpha: 0.5), size: 7),
                ),
                if (next != null) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      next,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: CardStyle.body(10.8, colour: M.inkDim.withValues(alpha: 0.85)),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The recipe as a row of segments, one per step: done ones filled, the
/// current one lit, the rest a hairline track.
class StepProgress extends StatelessWidget {
  const StepProgress({super.key, required this.step, required this.count, required this.colour});

  final int step;
  final int count;
  final Color colour;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 4,
        child: CustomPaint(
          painter: _ProgressPainter(step: step, count: count, colour: colour),
          size: Size.infinite,
        ),
      );
}

class _ProgressPainter extends CustomPainter {
  _ProgressPainter({required this.step, required this.count, required this.colour});

  final int step;
  final int count;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    // Many-step recipes fall back to a thin gap so the segments stay readable.
    final gap = count > 12 ? 1.5 : 3.0;
    final w = math.max(1.0, (size.width - gap * (count - 1)) / count);
    final h = size.height;
    for (var i = 0; i < count; i++) {
      final n = i + 1;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(i * (w + gap), 0, w, h),
        Radius.circular(h / 2),
      );
      if (n == step) {
        canvas.drawRRect(
          rect,
          Paint()
            ..color = colour.withValues(alpha: 0.7)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
        );
        canvas.drawRRect(rect, Paint()..color = colour);
      } else {
        canvas.drawRRect(
          rect,
          Paint()
            ..color = n < step ? colour.withValues(alpha: 0.42) : const Color(0x17FFFFFF),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_ProgressPainter old) =>
      old.step != step || old.count != count || old.colour != colour;
}

/// A step's time, offered as a timer: a coral pill with a small stopwatch.
class TimerPill extends StatelessWidget {
  const TimerPill(this.text, {super.key});

  final String text;

  static const Color colour = M.timer;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(7, 4.5, 9, 4.5),
        decoration: BoxDecoration(
          color: colour.withValues(alpha: 0.1),
          border: Border.all(color: colour.withValues(alpha: 0.4)),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 11,
              height: 11,
              child: CustomPaint(painter: _StopwatchPainter(colour)),
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: CardStyle.numeral(11, colour: colour, weight: 560),
              ),
            ),
          ],
        ),
      );
}

class _StopwatchPainter extends CustomPainter {
  const _StopwatchPainter(this.colour);

  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final stroke = Paint()
      ..color = colour
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    final centre = Offset(s / 2, s * 0.57);
    final r = s * 0.39;
    canvas.drawCircle(centre, r, stroke);
    // crown
    canvas.drawLine(Offset(s * 0.4, s * 0.05), Offset(s * 0.6, s * 0.05), stroke);
    canvas.drawLine(Offset(s / 2, s * 0.05), Offset(s / 2, centre.dy - r), stroke);
    // hand
    canvas.drawLine(centre, Offset(centre.dx + r * 0.42, centre.dy - r * 0.5), stroke);
  }

  @override
  bool shouldRepaint(_StopwatchPainter old) => old.colour != colour;
}

/// Text that takes the largest size from [maxSize] down to [minSize] at which it
/// fits [maxHeight] at the width it's given; at [minSize] it ellipsizes.
class FitText extends StatelessWidget {
  const FitText(
    this.text, {
    super.key,
    required this.style,
    required this.maxHeight,
    required this.maxSize,
    required this.minSize,
  });

  final String text;
  final TextStyle style;
  final double maxHeight;
  final double maxSize;
  final double minSize;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final scaler = MediaQuery.textScalerOf(context);
        var size = maxSize;
        while (size > minSize) {
          final tp = TextPainter(
            text: TextSpan(text: text, style: style.copyWith(fontSize: size)),
            textDirection: TextDirection.ltr,
            textScaler: scaler,
          )..layout(maxWidth: c.maxWidth);
          if (tp.height <= maxHeight) break;
          size -= 1;
        }
        final fitted = style.copyWith(fontSize: math.max(size, minSize));
        final line = scaler.scale(fitted.fontSize!) * (fitted.height ?? 1.2);
        return Text(
          text,
          style: fitted,
          maxLines: math.max(1, (maxHeight / line).floor()),
          overflow: TextOverflow.ellipsis,
        );
      });
}
