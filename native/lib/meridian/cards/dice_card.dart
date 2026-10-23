import 'package:flutter/material.dart';

import '../tokens.dart';
import 'card_frame.dart';
import 'game_pieces.dart';

/// `roll_dice`: every die as a face you could pick up — pips on a d6, the
/// number on anything else — the modifier as a tile of its own, and the total
/// large at the right, with the arithmetic under the dice. A single die with
/// nothing added IS the answer, so it stands alone, larger.
class DiceCard extends StatelessWidget {
  const DiceCard({super.key, required this.data});

  final Map<String, dynamic> data;

  static const Color accent = M.game;

  /// A die's side at the wall's width, and the least it shrinks to before
  /// the dice wrap onto another row.
  static const double _maxDie = 72;
  static const double _minDie = 36;

  /// Below this the total moves under the dice (see build).
  static const double _sideBySideMinWidth = 250;

  @override
  Widget build(BuildContext context) {
    final raw = data['dice'];
    final dice = [
      if (raw is List)
        for (final d in raw)
          if (d is int) d,
    ];
    final pips = data.flag('pips');
    final modifier = data.str('modifier');
    final total = data.str('total');
    final sum = data.str('math');
    return CardFrame(
      accent: accent,
      label: data.str('title') ?? '',
      child: LayoutBuilder(builder: (context, c) {
        final k = gameScale(c.maxWidth);
        if (total == null) {
          return Center(
            child: Wrap(
              spacing: 10 * k,
              runSpacing: 10 * k,
              children: [
                for (final d in dice) DieFace(value: d, size: 100 * k, pips: pips),
              ],
            ),
          );
        }
        final gap = 8 * k;
        final tiles = dice.length + (modifier != null ? 1 : 0);
        final faces = [
          for (final d in dice) (double size) => DieFace(value: d, size: size, pips: pips),
          if (modifier != null) (double size) => _ModifierTile(modifier, size: size),
        ];
        Widget wrap(double size) => Wrap(
              spacing: gap,
              runSpacing: gap,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [for (final f in faces) f(size)],
            );
        final equals = _Total(total, k: k);
        final arithmetic = sum == null
            ? null
            : Text(
                sum,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: gameFigure(14 * k, colour: M.inkDim.withValues(alpha: 0.8), weight: 500),
              );

        // A narrow column (a phone) can't spare the total's width beside a
        // handful of dice: they'd stack four rows deep. There the dice take
        // the full width and the total sits under them, by the arithmetic.
        if (c.maxWidth < _sideBySideMinWidth && tiles > 3) {
          final size = tileSize(c.maxWidth, tiles, max: _maxDie * k, min: _minDie * k, gap: gap);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              wrap(size),
              SizedBox(height: 8 * k),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(child: arithmetic ?? const SizedBox.shrink()),
                  SizedBox(width: 8 * k),
                  equals,
                ],
              ),
            ],
          );
        }

        final totalWidth = 96 * k;
        final area = c.maxWidth - totalWidth - 12 * k;
        final size = tileSize(area, tiles, max: _maxDie * k, min: _minDie * k, gap: gap);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: wrap(size)),
                SizedBox(width: 12 * k),
                SizedBox(
                  width: totalWidth,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: equals,
                  ),
                ),
              ],
            ),
            if (arithmetic != null) ...[
              SizedBox(height: 9 * k),
              arithmetic,
            ],
          ],
        );
      }),
    );
  }
}

/// "= 16": the sign quiet, the number the largest thing on the card.
class _Total extends StatelessWidget {
  const _Total(this.total, {required this.k});

  final String total;
  final double k;

  @override
  Widget build(BuildContext context) => Text.rich(
        key: const ValueKey('dice-total'),
        TextSpan(children: [
          TextSpan(
            text: '= ',
            style: gameFigure(26 * k, colour: M.inkDim.withValues(alpha: 0.6), weight: 400),
          ),
          TextSpan(
            text: total,
            style: gameFigure(54 * k, weight: 560).copyWith(letterSpacing: -0.6 * k),
          ),
        ]),
        maxLines: 1,
        textAlign: TextAlign.right,
      );
}

/// "+2" beside the dice, the size of one: what the roll adds, outlined in the
/// accent so it never reads as one more die.
class _ModifierTile extends StatelessWidget {
  const _ModifierTile(this.text, {required this.size});

  final String text;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size * 0.2),
          color: DiceCard.accent.withValues(alpha: 0.07),
          border: Border.all(color: DiceCard.accent.withValues(alpha: 0.55), width: 1.5),
        ),
        child: Padding(
          padding: EdgeInsets.all(size * 0.08),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              text,
              maxLines: 1,
              style: gameFigure(size * 0.4, colour: DiceCard.accent, weight: 560),
            ),
          ),
        ),
      );
}
