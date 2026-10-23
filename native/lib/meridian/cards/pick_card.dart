import 'package:flutter/material.dart';

import '../tokens.dart';
import 'card_frame.dart';
import 'game_pieces.dart';

/// `pick_one`: the pick, large, over every option as a chip with the chosen
/// lit in the accent — or, for a shuffle, the turn order as numbered rows with
/// whoever goes first lit.
class PickCard extends StatelessWidget {
  const PickCard({super.key, required this.data});

  final Map<String, dynamic> data;

  static const Color accent = M.game;

  /// More turns than this split into two columns, so a full table still fits
  /// the thread without a scroll.
  static const int _oneColumnMax = 6;

  @override
  Widget build(BuildContext context) {
    final order = data.rows('order');
    return CardFrame(
      accent: accent,
      label: data.str('title') ?? '',
      trailing: data.str('trailing'),
      child: LayoutBuilder(builder: (context, c) {
        final k = gameScale(c.maxWidth);
        return order.isNotEmpty ? _order(order, k) : _pick(k);
      }),
    );
  }

  Widget _pick(double k) {
    final headline = data.str('headline');
    final options = data.rows('options');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (headline != null)
          Text(
            headline,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: CardStyle.body(34 * k, colour: M.ink, weight: 600, height: 1.12)
                .copyWith(letterSpacing: -0.5 * k),
          ),
        if (headline != null && options.isNotEmpty) SizedBox(height: 14 * k),
        Wrap(
          spacing: 7 * k,
          runSpacing: 7 * k,
          children: [
            for (final o in options) _Chip(o.str('label') ?? '', chosen: o.flag('chosen'), k: k),
          ],
        ),
      ],
    );
  }

  Widget _order(List<Map<String, dynamic>> order, double k) {
    final split = order.length > _oneColumnMax ? (order.length + 1) ~/ 2 : order.length;
    Widget column(Iterable<Map<String, dynamic>> rows) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [for (final r in rows) _Turn(r, first: r.str('rank') == '1', k: k)],
        );
    if (split == order.length) return column(order);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: column(order.take(split))),
        SizedBox(width: 10 * k),
        Expanded(child: column(order.skip(split))),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.label, {required this.chosen, required this.k});

  final String label;
  final bool chosen;
  final double k;

  @override
  Widget build(BuildContext context) {
    const a = PickCard.accent;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 13 * k, vertical: 7 * k),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: chosen ? a.withValues(alpha: 0.16) : const Color(0x08FFFFFF),
        border: Border.all(
          color: chosen ? a.withValues(alpha: 0.75) : const Color(0x1FFFFFFF),
          width: chosen ? 1.5 : 1,
        ),
        boxShadow:
            chosen ? [BoxShadow(color: a.withValues(alpha: 0.28), blurRadius: 14 * k)] : null,
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: CardStyle.body(
          16 * k,
          colour: chosen ? a : M.inkDim.withValues(alpha: 0.75),
          weight: chosen ? 620 : 450,
          height: 1.15,
        ),
      ),
    );
  }
}

/// One place in the turn order: its number in the accent, the name large.
/// Whoever goes first sits on a lit band.
class _Turn extends StatelessWidget {
  const _Turn(this.row, {required this.first, required this.k});

  final Map<String, dynamic> row;
  final bool first;
  final double k;

  @override
  Widget build(BuildContext context) {
    const a = PickCard.accent;
    return Container(
      margin: EdgeInsets.only(bottom: 3 * k),
      padding: EdgeInsets.symmetric(horizontal: 9 * k, vertical: 6 * k),
      decoration: first
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(9 * k),
              color: a.withValues(alpha: 0.11),
              border: Border.all(color: a.withValues(alpha: 0.35)),
            )
          : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 30 * k,
            child: Text(
              row.str('rank') ?? '',
              style: gameFigure(22 * k, colour: a.withValues(alpha: first ? 1 : 0.7), weight: 560),
            ),
          ),
          Expanded(
            child: Text(
              row.str('label') ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: CardStyle.body(20 * k,
                  colour: M.ink.withValues(alpha: first ? 1 : 0.88),
                  weight: first ? 600 : 480,
                  height: 1.15),
            ),
          ),
        ],
      ),
    );
  }
}
