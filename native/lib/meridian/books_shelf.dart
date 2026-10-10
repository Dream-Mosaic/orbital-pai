import 'package:flutter/material.dart';

import '../panels/books_client.dart';
import 'books_tracker_chart.dart';
import 'cards/card_frame.dart';
import 'hero_icon.dart';
import 'tokens.dart';

/// The Books panel's three COLLECTION bodies — the recipe book, the user's
/// trackers and their routines — shown under the header when one of them is
/// the current book. Their detail views (a recipe, a tracker) live in
/// `books_details.dart` and are layered in by `BooksDrawerHost`.
///
/// Every string is the channel's (`AppWeb.CollectionFormat`), rendered
/// verbatim, row order included — this file formats nothing and sorts
/// nothing. The visual language is the thread cards' (`CardStyle`): the same
/// faces, the same engraved labels, the same accent wash, set a little
/// larger because here they are the page rather than a glance in a column.

/// One accent per collection, so each book reads as its own thing at a
/// glance. Recipe and tracker match the thread cards' hues for the same data;
/// routines take Henry's green, since a routine is Henry acting.
abstract final class ShelfAccent {
  /// The recipe card's parchment — the same token the thread's recipe cards use.
  static const Color recipe = M.recipe;

  /// The tracker card's cornflower — shared with the thread's tracker cards.
  static const Color tracker = M.tracker;

  /// Henry's own green.
  static const Color routine = M.henry;

  /// Delete, quietly: a muted coral that reads "careful" without alarm.
  static const Color danger = Color(0xFFF2877A);
}

/// The collections' container: the panel's hairline card, with the thread
/// cards' faint glass and a wash of the accent from the top-left corner.
class ShelfCard extends StatelessWidget {
  const ShelfCard({
    super.key,
    required this.accent,
    required this.child,
    this.padding = const EdgeInsets.all(14),
  });

  final Color accent;
  final Widget child;
  final EdgeInsetsGeometry padding;

  static const double radius = 14;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: CardStyle.edge),
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [CardStyle.fillTop, CardStyle.fillBottom],
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius - 1),
          child: Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(-1.05, -1.1),
                        radius: 1.3,
                        colors: [
                          accent.withValues(alpha: 0.09),
                          accent.withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Padding(padding: padding, child: child),
            ],
          ),
        ),
      );
}

/// A small engraved section label ("INGREDIENTS"), in the accent.
class ShelfLabel extends StatelessWidget {
  const ShelfLabel(this.text, {super.key, required this.accent});

  final String text;
  final Color accent;

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: CardStyle.label(accent.withValues(alpha: 0.9), size: 8.6),
      );
}

/// A soft rounded pill: a recipe's "shared"/"yours", a routine's phrase, a
/// tracker tag. [trailing] (a tally such as "×4") is set dimmer.
class ShelfPill extends StatelessWidget {
  const ShelfPill(
    this.text, {
    super.key,
    required this.colour,
    this.trailing = '',
    this.size = 10.5,
  });

  final String text;
  final Color colour;
  final String trailing;
  final double size;

  @override
  Widget build(BuildContext context) {
    final style = CardStyle.body(size,
        colour: colour.withValues(alpha: 0.95), weight: 520, height: 1.2);
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 3, 8, 3.5),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.09),
        border: Border.all(color: colour.withValues(alpha: 0.26)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text.rich(
        TextSpan(children: [
          TextSpan(text: text, style: style),
          if (trailing.isNotEmpty)
            TextSpan(
              text: ' $trailing',
              style: CardStyle.numeral(size - 0.6,
                  colour: colour.withValues(alpha: 0.6), weight: 560),
            ),
        ]),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// A collection's empty state: what is missing, and what to SAY to fill it.
class ShelfEmpty extends StatelessWidget {
  const ShelfEmpty({
    super.key,
    required this.icon,
    required this.accent,
    required this.title,
    required this.hint,
  });

  final HeroIcon icon;
  final Color accent;
  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) => ShelfCard(
        accent: accent,
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 22),
        child: Column(
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: accent.withValues(alpha: 0.1),
                border: Border.all(color: accent.withValues(alpha: 0.28)),
              ),
              child: HeroIconView(icon, size: 19, color: accent),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: CardStyle.body(14.5, colour: M.ink, weight: 560),
            ),
            if (hint.isNotEmpty) ...[
              const SizedBox(height: 5),
              Text(
                hint,
                textAlign: TextAlign.center,
                style: CardStyle.body(13,
                    colour: M.inkDim.withValues(alpha: 0.9), height: 1.45),
              ),
            ],
          ],
        ),
      );
}

/// A hairline between rows inside a [ShelfCard].
class ShelfRule extends StatelessWidget {
  const ShelfRule({super.key, this.indent = 14});

  final double indent;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.symmetric(horizontal: indent),
        child: Container(height: 1, color: CardStyle.rule),
      );
}

/// The confirmation every delete on the shelf goes through. [question] is the
/// ROW's own server copy; acts only on an explicit Delete — a dismissed
/// dialog is a no.
Future<bool> shelfConfirmDelete(BuildContext context, String question) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: const Color(0xFF12141D),
      content: Text(
        question,
        style: CardStyle.body(14.5, colour: M.ink, height: 1.45),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          style: TextButton.styleFrom(foregroundColor: M.inkDim),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: TextButton.styleFrom(foregroundColor: ShelfAccent.danger),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// A trailing chevron: this row opens a detail.
class _Chevron extends StatelessWidget {
  const _Chevron();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 6),
        child: HeroIconView(HeroIcon.chevronRight,
            size: 15, color: M.inkDim.withValues(alpha: 0.6)),
      );
}

// ---------------------------------------------------------------------------
// Recipes

/// The recipe book: one card, a row per recipe (title, counts, whose it is).
/// Tapping a row opens its detail through [onOpen]; with no [onOpen] the rows
/// are read-only.
class RecipesShelfBody extends StatelessWidget {
  const RecipesShelfBody({super.key, required this.body, this.onOpen});

  final RecipesBody body;
  final ValueChanged<int>? onOpen;

  static Key rowKey(int id) => ValueKey('recipe-row-$id');

  @override
  Widget build(BuildContext context) {
    if (body.items.isEmpty) {
      return ShelfEmpty(
        icon: HeroIcon.cake,
        accent: ShelfAccent.recipe,
        title: body.empty,
        hint: body.hint,
      );
    }
    return ShelfCard(
      accent: ShelfAccent.recipe,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Server-ordered (by name) — never re-sort here.
          for (var i = 0; i < body.items.length; i++) ...[
            if (i > 0) const ShelfRule(),
            _row(body.items[i]),
          ],
        ],
      ),
    );
  }

  Widget _row(RecipeRow r) => GestureDetector(
        key: rowKey(r.id),
        behavior: HitTestBehavior.opaque,
        onTap: onOpen == null ? null : () => onOpen!(r.id),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 11, 10, 11),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      r.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: CardStyle.body(14.5,
                          colour: M.ink, weight: 560, height: 1.25),
                    ),
                    if (r.meta.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(r.meta, style: CardStyle.meta(12)),
                    ],
                  ],
                ),
              ),
              if (r.tag.isNotEmpty) ...[
                const SizedBox(width: 10),
                ShelfPill(r.tag, colour: r.shared ? M.henry : M.you, size: 10),
              ],
              if (onOpen != null) const _Chevron(),
            ],
          ),
        ),
      );
}

// ---------------------------------------------------------------------------
// Trackers

/// The trackers book: one card, a row per tracker — its name, unit and
/// count, its last entry, and a month of days in miniature.
class TrackersShelfBody extends StatelessWidget {
  const TrackersShelfBody({super.key, required this.body, this.onOpen});

  final TrackersBody body;
  final ValueChanged<int>? onOpen;

  static Key rowKey(int id) => ValueKey('tracker-row-$id');

  @override
  Widget build(BuildContext context) {
    if (body.items.isEmpty) {
      return ShelfEmpty(
        icon: HeroIcon.chartBar,
        accent: ShelfAccent.tracker,
        title: body.empty,
        hint: body.hint,
      );
    }
    return ShelfCard(
      accent: ShelfAccent.tracker,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Server-ordered (most recently active first) — never re-sort here.
          for (var i = 0; i < body.items.length; i++) ...[
            if (i > 0) const ShelfRule(),
            _row(body.items[i]),
          ],
        ],
      ),
    );
  }

  Widget _row(TrackerRow t) {
    final meta = [t.unit, t.count].where((s) => s.isNotEmpty).join(' · ');
    return GestureDetector(
      key: rowKey(t.id),
      behavior: HitTestBehavior.opaque,
      onTap: onOpen == null ? null : () => onOpen!(t.id),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: CardStyle.body(14.5,
                        colour: M.ink, weight: 560, height: 1.25),
                  ),
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: CardStyle.meta(12)),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (t.series.isNotEmpty)
                  SizedBox(
                    width: 62,
                    height: 18,
                    child: CustomPaint(
                      painter: TrackerSparkPainter(
                        points: t.series,
                        colour: ShelfAccent.tracker,
                      ),
                    ),
                  ),
                const SizedBox(height: 5),
                Text(
                  t.last,
                  maxLines: 1,
                  style: CardStyle.numeral(11,
                      colour: M.ink.withValues(alpha: 0.82), weight: 480),
                ),
              ],
            ),
            if (onOpen != null) const _Chevron(),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Routines

/// The routines book: a card per routine — its name, the phrases that run it,
/// what it does, when it last ran — each with its own Delete.
class RoutinesShelfBody extends StatelessWidget {
  const RoutinesShelfBody(
      {super.key, required this.body, required this.onDelete});

  final RoutinesBody body;

  /// Called with the routine's id once the user has confirmed ITS dialog.
  final ValueChanged<int> onDelete;

  static Key deleteKey(int id) => ValueKey('routine-delete-$id');
  static Key cardKey(int id) => ValueKey('routine-card-$id');

  @override
  Widget build(BuildContext context) {
    if (body.items.isEmpty) {
      return ShelfEmpty(
        icon: HeroIcon.bolt,
        accent: ShelfAccent.routine,
        title: body.empty,
        hint: body.hint,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Server-ordered (alphabetical) — never re-sort here.
        for (var i = 0; i < body.items.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          _card(context, body.items[i]),
        ],
      ],
    );
  }

  Future<void> _delete(BuildContext context, RoutineRow r) async {
    if (await shelfConfirmDelete(context, r.deleteConfirm)) onDelete(r.id);
  }

  Widget _card(BuildContext context, RoutineRow r) => ShelfCard(
        key: cardKey(r.id),
        accent: ShelfAccent.routine,
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const HeroIconView(HeroIcon.bolt,
                    size: 15, color: ShelfAccent.routine),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    r.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: CardStyle.body(14.5,
                        colour: M.ink, weight: 580, height: 1.25),
                  ),
                ),
                Tooltip(
                  message: 'Delete routine',
                  child: GestureDetector(
                    key: deleteKey(r.id),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _delete(context, r),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: HeroIconView(HeroIcon.trash,
                          size: 16, color: M.inkDim.withValues(alpha: 0.75)),
                    ),
                  ),
                ),
              ],
            ),
            if (r.say.isNotEmpty) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 2),
                      child: ShelfLabel('Say',
                          accent: M.chromeDim.withValues(alpha: 0.6)),
                    ),
                    for (final p in r.say)
                      ShelfPill('“$p”', colour: ShelfAccent.routine),
                  ],
                ),
              ),
            ],
            if (r.steps.isNotEmpty) ...[
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  r.steps,
                  style: CardStyle.body(13.5, colour: M.brainBody, height: 1.5),
                ),
              ),
            ],
            if (r.lastRun.isNotEmpty) ...[
              const SizedBox(height: 9),
              Text(r.lastRun, style: CardStyle.meta(11.5)),
            ],
          ],
        ),
      );
}
