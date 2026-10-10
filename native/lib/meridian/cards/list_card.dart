import 'package:flutter/material.dart';

import '../tokens.dart';
import 'card_frame.dart';

/// `read_list` as the list itself: open items first, done ones struck through
/// and dimmed, the server's tally underneath.
class ListCard extends StatelessWidget {
  const ListCard({super.key, required this.data});

  final Map<String, dynamic> data;

  static const Color accent = M.you;

  @override
  Widget build(BuildContext context) {
    final items = data.rows('items');
    return CardFrame(
      accent: accent,
      label: data.str('title') ?? '',
      trailing: data.str('scope'),
      footer: data.str('summary'),
      footerTrailing: data.str('more'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [for (final i in items) _item(i)],
      ),
    );
  }

  Widget _item(Map<String, dynamic> i) {
    final done = i.flag('done');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3.2),
      child: Row(
        children: [
          CardCheck(done: done, colour: accent),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              i.str('text') ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: CardStyle.body(
                12.5,
                colour: done ? M.ink.withValues(alpha: 0.38) : M.brainBody,
                weight: done ? 400 : 440,
              ).copyWith(
                decoration: done ? TextDecoration.lineThrough : null,
                decorationColor: M.ink.withValues(alpha: 0.32),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A small rounded checkbox: an outline while open, a filled accent tile with
/// a painted tick once done. Display only — the card is a read-back.
class CardCheck extends StatelessWidget {
  const CardCheck({super.key, required this.done, required this.colour});

  final bool done;
  final Color colour;

  @override
  Widget build(BuildContext context) => Container(
        width: 13,
        height: 13,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          color: done ? colour.withValues(alpha: 0.55) : colour.withValues(alpha: 0.05),
          border: Border.all(
            color: done ? colour.withValues(alpha: 0.0) : colour.withValues(alpha: 0.55),
            width: 1.2,
          ),
        ),
        child: done ? const CustomPaint(painter: _TickPainter()) : null,
      );
}

class _TickPainter extends CustomPainter {
  const _TickPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final path = Path()
      ..moveTo(w * 0.22, w * 0.52)
      ..lineTo(w * 0.42, w * 0.71)
      ..lineTo(w * 0.78, w * 0.3);
    canvas.drawPath(
      path,
      Paint()
        ..color = M.bg.withValues(alpha: 0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_TickPainter oldDelegate) => false;
}
