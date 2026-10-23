import 'package:flutter/material.dart';

import '../tokens.dart';
import 'card_frame.dart';
import 'game_pieces.dart';

/// `keep_score`: the board as rows of rank · name · points, leader first and
/// lit, the points large and right-aligned so the column reads like a real
/// scoreboard. The points just added ride beside that player as a small "+3".
class ScoreboardCard extends StatelessWidget {
  const ScoreboardCard({super.key, required this.data});

  final Map<String, dynamic> data;

  static const Color accent = M.game;

  @override
  Widget build(BuildContext context) {
    final rows = data.rows('rows');
    return CardFrame(
      accent: accent,
      label: data.str('title') ?? '',
      trailing: data.str('trailing'),
      footerTrailing: data.str('more'),
      child: LayoutBuilder(builder: (context, c) {
        final k = gameScale(c.maxWidth);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [for (final r in rows) _Row(r, k: k)],
        );
      }),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.row, {required this.k});

  final Map<String, dynamic> row;
  final double k;

  @override
  Widget build(BuildContext context) {
    const a = ScoreboardCard.accent;
    final leader = row.flag('leader');
    final delta = row.str('delta');
    return Container(
      margin: EdgeInsets.only(bottom: 3 * k),
      padding: EdgeInsets.fromLTRB(9 * k, 5 * k, 11 * k, 5 * k),
      decoration: leader
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(10 * k),
              color: a.withValues(alpha: 0.11),
              border: Border.all(color: a.withValues(alpha: 0.38)),
              boxShadow: [BoxShadow(color: a.withValues(alpha: 0.12), blurRadius: 16 * k)],
            )
          : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 28 * k,
            child: Text(
              row.str('rank') ?? '',
              style: gameFigure(16 * k,
                  colour: leader ? a : M.inkDim.withValues(alpha: 0.7), weight: 560),
            ),
          ),
          Expanded(
            child: Text(
              row.str('name') ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: CardStyle.body(20 * k,
                  colour: M.ink.withValues(alpha: leader ? 1 : 0.88),
                  weight: leader ? 600 : 480,
                  height: 1.15),
            ),
          ),
          if (delta != null) ...[
            SizedBox(width: 8 * k),
            Container(
              key: const ValueKey('score-delta'),
              padding: EdgeInsets.symmetric(horizontal: 6 * k, vertical: 2.5 * k),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6 * k),
                color: a.withValues(alpha: 0.12),
                border: Border.all(color: a.withValues(alpha: 0.4)),
              ),
              child: Text(
                delta,
                style: gameFigure(13 * k, colour: a, weight: 600),
              ),
            ),
          ],
          SizedBox(width: 12 * k),
          Text(
            row.str('points') ?? '',
            maxLines: 1,
            style: gameFigure(30 * k, colour: leader ? a : M.ink, weight: 540)
                .copyWith(letterSpacing: -0.4 * k),
          ),
        ],
      ),
    );
  }
}
