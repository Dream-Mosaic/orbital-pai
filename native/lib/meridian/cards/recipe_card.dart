import 'package:flutter/material.dart';

import '../tokens.dart';
import 'card_frame.dart';

/// `get_recipe` / `save_recipe` / `edit_recipe` as a recipe card: the title in
/// the header (with what a write did, or whose book it's in), the serves/source
/// line, the ingredients with their quantities set apart, the method as a
/// cookbook's run-in numbered paragraph, and the notes underneath.
///
/// The ingredients get the room: they're what "what do I need for…" is asking,
/// and a phone column fits a dozen of them. The method is a glance — cook mode
/// is where the steps are read one at a time, large.
class RecipeCard extends StatelessWidget {
  const RecipeCard({super.key, required this.data});

  final Map<String, dynamic> data;

  static const Color accent = M.recipe;

  /// How much of the method the card shows before it trails off.
  static const int methodLines = 3;

  @override
  Widget build(BuildContext context) {
    final meta = data.str('meta');
    final ingredients = data.rows('ingredients');
    final steps = data.rows('steps');
    return CardFrame(
      accent: accent,
      label: data.str('title') ?? '',
      trailing: data.str('status') ?? data.str('scope'),
      footer: data.str('notes'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (meta != null) ...[
            Text(
              meta,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: CardStyle.body(11, colour: M.inkDim.withValues(alpha: 0.92), weight: 440),
            ),
            const SizedBox(height: 8),
          ],
          if (ingredients.isNotEmpty) ...[
            _SectionHead(
                label: data.str('ingredients_label'), more: data.str('more_ingredients')),
            const SizedBox(height: 4),
            IngredientGrid(ingredients: ingredients, colour: accent),
          ],
          if (steps.isNotEmpty) ...[
            SizedBox(height: ingredients.isEmpty ? 0 : 8),
            _SectionHead(label: data.str('steps_label'), more: data.str('more_steps')),
            const SizedBox(height: 5),
            Text.rich(
              TextSpan(children: [
                for (var n = 0; n < steps.length; n++) ...[
                  TextSpan(
                    text: '${n == 0 ? '' : '   '}${steps[n].str('number') ?? ''}',
                    style: CardStyle.numeral(10.4, colour: accent, weight: 640),
                  ),
                  // No-break spaces tie each number to its step, so a number
                  // never ends a line with its words on the next.
                  TextSpan(
                    text: '\u00A0\u00A0${steps[n].str('text') ?? ''}',
                    style: CardStyle.body(11.2,
                        colour: M.brainBody.withValues(alpha: 0.9), height: 1.34),
                  ),
                ],
              ]),
              maxLines: methodLines,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

/// "11 INGREDIENTS ———— +3 more": an engraved label, a hairline to the edge,
/// and the server's overflow note at the end of it.
class _SectionHead extends StatelessWidget {
  const _SectionHead({required this.label, required this.more});

  final String? label;
  final String? more;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          if (label != null) ...[
            Text(
              label!.toUpperCase(),
              style: CardStyle.label(M.chromeDim.withValues(alpha: 0.5), size: 6.6),
            ),
            const SizedBox(width: 7),
          ],
          Expanded(child: Container(height: 1, color: CardStyle.rule)),
          if (more != null) ...[
            const SizedBox(width: 7),
            Text(
              more!,
              style: CardStyle.body(9.6,
                  colour: RecipeCard.accent.withValues(alpha: 0.85), weight: 500),
            ),
          ],
        ],
      );
}

/// The ingredients in two columns where they fit and one where they don't:
/// walking the list in order, two neighbours that each fit half the width share
/// a row; anything longer takes the row. Short lists pair up into tidy columns,
/// and a long "3 cups shredded mozzarella" is never cut to "shredded moz…".
class IngredientGrid extends StatelessWidget {
  const IngredientGrid({super.key, required this.ingredients, required this.colour});

  final List<Map<String, dynamic>> ingredients;
  final Color colour;

  static const double _gap = 10;
  static const double _dot = 3.2;
  static const double _bullet = 9; // the dot and the space after it

  TextSpan _span(Map<String, dynamic> i) {
    final qty = i.str('qty');
    return TextSpan(children: [
      if (qty != null)
        TextSpan(
          text: '$qty ',
          style: CardStyle.numeral(10.3, colour: colour.withValues(alpha: 0.95), weight: 560),
        ),
      TextSpan(
        text: i.str('item') ?? '',
        style: CardStyle.body(10.9, colour: M.brainBody, weight: 430, height: 1.22),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final half = (c.maxWidth - _gap) / 2;
        final scaler = MediaQuery.textScalerOf(context);
        bool fits(Map<String, dynamic> i) {
          final tp = TextPainter(
            text: _span(i),
            textDirection: TextDirection.ltr,
            textScaler: scaler,
            maxLines: 1,
          )..layout();
          return tp.width + _bullet <= half;
        }

        final rows = <Widget>[];
        var n = 0;
        while (n < ingredients.length) {
          final a = ingredients[n];
          final b = n + 1 < ingredients.length ? ingredients[n + 1] : null;
          if (b != null && fits(a) && fits(b)) {
            rows.add(Row(children: [
              SizedBox(width: half, child: _cell(a)),
              const SizedBox(width: _gap),
              SizedBox(width: half, child: _cell(b)),
            ]));
            n += 2;
          } else {
            rows.add(_cell(a));
            n += 1;
          }
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final r in rows)
              Padding(padding: const EdgeInsets.symmetric(vertical: 0.9), child: r),
          ],
        );
      });

  Widget _cell(Map<String, dynamic> i) => Row(
        children: [
          Container(
            width: _dot,
            height: _dot,
            decoration: BoxDecoration(shape: BoxShape.circle, color: colour.withValues(alpha: 0.5)),
          ),
          const SizedBox(width: _bullet - _dot),
          Flexible(
            child: Text.rich(_span(i), maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      );
}
