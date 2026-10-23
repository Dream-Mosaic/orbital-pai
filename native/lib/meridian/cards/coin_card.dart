import 'package:flutter/material.dart';

import '../tokens.dart';
import 'card_frame.dart';
import 'game_pieces.dart';

/// `flip_coin`: one flip is a big coin and the word beside it; several are a
/// row of coins in the order they fell, with the tally under them large enough
/// to read from the far end of the table.
class CoinCard extends StatelessWidget {
  const CoinCard({super.key, required this.data});

  final Map<String, dynamic> data;

  static const Color accent = M.game;

  @override
  Widget build(BuildContext context) {
    final flips = data.rows('flips');
    final summary = data.str('summary');
    return CardFrame(
      accent: accent,
      label: data.str('title') ?? '',
      child: LayoutBuilder(builder: (context, c) {
        final k = gameScale(c.maxWidth);
        if (flips.length == 1) {
          final f = flips.single;
          return Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _coin(f, 96 * k),
                SizedBox(width: 20 * k),
                Flexible(
                  child: Text(
                    f.str('label') ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: gameFigure(44 * k, weight: 540).copyWith(letterSpacing: -0.6 * k),
                  ),
                ),
              ],
            ),
          );
        }
        final gap = 8 * k;
        final size = tileSize(c.maxWidth, flips.length, max: 64 * k, min: 40 * k, gap: gap);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [for (final f in flips) _coin(f, size)],
            ),
            if (summary != null) ...[
              SizedBox(height: 12 * k),
              Text(
                summary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: CardStyle.body(20 * k, colour: M.ink, weight: 520, height: 1.1),
              ),
            ],
          ],
        );
      }),
    );
  }

  static Widget _coin(Map<String, dynamic> f, double size) => Semantics(
        label: f.str('label'),
        child: CoinDisc(
          heads: f.str('side') == 'heads',
          mark: f.str('mark') ?? '',
          size: size,
        ),
      );
}
