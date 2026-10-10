import 'package:flutter/material.dart';

import '../panels/books_client.dart';
import 'books_shelf.dart';
import 'books_tracker_chart.dart';
import 'cards/card_frame.dart';
import 'hero_icon.dart';
import 'tokens.dart';

/// The detail layers `BooksDrawerHost` opens from the recipe and tracker
/// books: one recipe to cook from, one tracker to read. Each is handed the
/// row from the CURRENT state (null when the channel no longer sends it —
/// deleted by voice, by the other person, or the current book moved) and
/// re-renders live with every push.
///
/// Every string is the channel's, verbatim; the only copy that is this
/// file's own is the section labels and the gone-nudges.

TextStyle _title() => const TextStyle(
      fontFamily: kDisplayFamily,
      fontSize: 23,
      height: 1.15,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.3,
      color: M.ink,
    ).copyWith(fontVariations: MType.wght(620));

/// What a detail shows when its row is gone from the state.
class _Gone extends StatelessWidget {
  const _Gone(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: CardStyle.body(14, colour: M.inkDim),
        ),
      );
}

// ---------------------------------------------------------------------------
// Recipe

/// One recipe: its title and whose it is, then ingredients, numbered steps
/// and notes — laid out to cook from — and a Delete that names this recipe.
class RecipeDetailView extends StatelessWidget {
  const RecipeDetailView(
      {super.key, required this.recipe, required this.onDelete});

  final RecipeRow? recipe;

  /// Called with the recipe's id once the user has confirmed ITS dialog.
  final ValueChanged<int> onDelete;

  static const Key deleteKey = ValueKey('recipe-detail-delete');

  static const String goneText = 'That recipe is gone — head back to the book.';

  static const Color _accent = ShelfAccent.recipe;

  Future<void> _delete(BuildContext context, RecipeRow r) async {
    if (await shelfConfirmDelete(context, r.deleteConfirm)) onDelete(r.id);
  }

  @override
  Widget build(BuildContext context) {
    final r = recipe;
    if (r == null) return const _Gone(goneText);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(r),
        const SizedBox(height: 18),
        if (r.ingredients.isNotEmpty) ...[
          ShelfCard(
            accent: _accent,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const ShelfLabel('Ingredients', accent: _accent),
                const SizedBox(height: 10),
                for (final i in r.ingredients) _ingredient(i),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (r.steps.isNotEmpty) ...[
          ShelfCard(
            accent: _accent,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const ShelfLabel('Steps', accent: _accent),
                const SizedBox(height: 12),
                for (var n = 0; n < r.steps.length; n++)
                  _step(n + 1, r.steps[n]),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (r.notes.isNotEmpty) ...[
          ShelfCard(
            accent: _accent,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const ShelfLabel('Notes', accent: _accent),
                const SizedBox(height: 9),
                Text(
                  r.notes,
                  style: CardStyle.body(13.5,
                      colour: M.brainBody.withValues(alpha: 0.9), height: 1.55),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        const SizedBox(height: 6),
        Center(
          child: TextButton.icon(
            key: deleteKey,
            onPressed: () => _delete(context, r),
            style: TextButton.styleFrom(
              foregroundColor: ShelfAccent.danger.withValues(alpha: 0.9),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            ),
            icon: HeroIconView(HeroIcon.trash,
                size: 16, color: ShelfAccent.danger.withValues(alpha: 0.9)),
            label: Text('Delete recipe',
                style: CardStyle.body(13,
                    colour: ShelfAccent.danger.withValues(alpha: 0.9),
                    weight: 520)),
          ),
        ),
      ],
    );
  }

  Widget _header(RecipeRow r) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(r.title, style: _title()),
          const SizedBox(height: 9),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (r.tag.isNotEmpty)
                ShelfPill(r.tag, colour: r.shared ? M.henry : M.you, size: 10),
              if (r.detailMeta.isNotEmpty)
                Text(r.detailMeta, style: CardStyle.meta(12.5)),
              if (r.meta.isNotEmpty)
                Text(r.meta,
                    style: CardStyle.body(12.5,
                        colour: M.inkDim.withValues(alpha: 0.6))),
            ],
          ),
        ],
      );

  Widget _ingredient(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 7, right: 11, left: 1),
              child: Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _accent.withValues(alpha: 0.85),
                ),
              ),
            ),
            Expanded(
              child: Text(text,
                  style: CardStyle.body(14, colour: M.brainBody, height: 1.4)),
            ),
          ],
        ),
      );

  Widget _step(int n, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              margin: const EdgeInsets.only(right: 11),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _accent.withValues(alpha: 0.1),
                border: Border.all(color: _accent.withValues(alpha: 0.35)),
              ),
              child: Text('$n',
                  style: CardStyle.numeral(11, colour: _accent, weight: 600)),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(text,
                    style:
                        CardStyle.body(14, colour: M.brainBody, height: 1.45)),
              ),
            ),
          ],
        ),
      );
}

// ---------------------------------------------------------------------------
// Tracker

/// One tracker: the month as a chart with its headline numbers, the tags
/// that keep coming up, and the newest entries.
class TrackerDetailView extends StatelessWidget {
  const TrackerDetailView({super.key, required this.tracker});

  final TrackerRow? tracker;

  static const String goneText =
      'That tracker is gone — head back to the book.';

  static const Color _accent = ShelfAccent.tracker;

  @override
  Widget build(BuildContext context) {
    final t = tracker;
    if (t == null) return const _Gone(goneText);
    final meta = [t.unit, t.count].where((s) => s.isNotEmpty).join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(t.label, style: _title()),
        if (meta.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(meta, style: CardStyle.meta(12.5)),
        ],
        const SizedBox(height: 18),
        ShelfCard(
          accent: _accent,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TrackerChart(
                points: t.series,
                colour: _accent,
                caption: t.range,
                axisFrom: t.axisFrom,
                axisTo: t.axisTo,
              ),
              if (t.stats.isNotEmpty) ...[
                const SizedBox(height: 14),
                Container(height: 1, color: CardStyle.rule),
                const SizedBox(height: 12),
                _stats(t.stats),
              ],
              if (t.quiet.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(t.quiet,
                    textAlign: TextAlign.center,
                    style: CardStyle.body(12.5, colour: M.inkDim)),
              ],
            ],
          ),
        ),
        if (t.tags.isNotEmpty) ...[
          const SizedBox(height: 18),
          const ShelfLabel('Comes up most', accent: _accent),
          const SizedBox(height: 9),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final tag in t.tags)
                ShelfPill(tag.tag, colour: _accent, trailing: tag.tally),
            ],
          ),
        ],
        if (t.recent.isNotEmpty) ...[
          const SizedBox(height: 20),
          const ShelfLabel('Recent', accent: _accent),
          const SizedBox(height: 8),
          ShelfCard(
            accent: _accent,
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Server-ordered (newest first) — never re-sort here.
                for (var i = 0; i < t.recent.length; i++) ...[
                  if (i > 0) const ShelfRule(),
                  _entry(t.recent[i]),
                ],
              ],
            ),
          ),
          if (t.more.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(t.more,
                textAlign: TextAlign.center, style: CardStyle.meta(11.5)),
          ],
        ],
      ],
    );
  }

  /// The month's headline numbers across the card. Each takes room in
  /// proportion to its value's length, so "181.6–184.6 lb" gets the width it
  /// needs beside "21", and three short numbers still split evenly; all share
  /// one size, a step down when any is long.
  Widget _stats(List<TrackerStat> stats) {
    final longest =
        stats.map((s) => s.value.length).fold(0, (a, b) => a > b ? a : b);
    final size = longest <= 6 ? 20.0 : 17.0;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < stats.length; i++) ...[
          if (i > 0) const SizedBox(width: 10),
          Expanded(
            flex: stats[i].value.length < 5 ? 5 : stats[i].value.length,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  stats[i].label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  softWrap: false,
                  style: CardStyle.label(M.chromeDim.withValues(alpha: 0.5),
                      size: 7.4),
                ),
                const SizedBox(height: 7),
                // Scale down rather than clip if a value still outruns
                // its share: a stat is never cut off mid-number.
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    stats[i].value,
                    maxLines: 1,
                    softWrap: false,
                    style: CardStyle.numeral(size, weight: 460)
                        .copyWith(letterSpacing: -0.3),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// One entry: its value tile; the note, if any, as the headline with the
  /// day and time under it (or the day and time as the headline when there
  /// is no note); its tags as pills.
  Widget _entry(TrackerEntryRow e) {
    final headline = e.note;
    final when = [e.day, e.time].where((s) => s.isNotEmpty).join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _ValueTile(value: e.value),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (headline.isNotEmpty) ...[
                  Text(headline,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: CardStyle.body(13.5,
                          colour: M.brainBody, height: 1.3)),
                  const SizedBox(height: 3),
                ],
                Text(
                  when,
                  style: CardStyle.numeral(headline.isEmpty ? 12 : 10.8,
                      colour: headline.isEmpty
                          ? M.ink.withValues(alpha: 0.85)
                          : M.inkDim.withValues(alpha: 0.8),
                      weight: 500),
                ),
                if (e.tags.isNotEmpty) ...[
                  const SizedBox(height: 7),
                  Wrap(
                    spacing: 5,
                    runSpacing: 5,
                    children: [
                      for (final tag in e.tags)
                        ShelfPill(tag, colour: _accent, size: 9.8),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// An entry's value in a small tinted tile; a habit entry (no value) holds a
/// single soft dot — the entry itself is the data point.
class _ValueTile extends StatelessWidget {
  const _ValueTile({required this.value});

  final String value;

  static const Color _c = ShelfAccent.tracker;

  @override
  Widget build(BuildContext context) => Container(
        constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(9),
          color: _c.withValues(alpha: 0.1),
          border: Border.all(color: _c.withValues(alpha: 0.3)),
        ),
        child: value.isEmpty
            ? Container(
                width: 6,
                height: 6,
                decoration:
                    const BoxDecoration(shape: BoxShape.circle, color: _c),
              )
            : Text(
                value,
                maxLines: 1,
                softWrap: false,
                style: CardStyle.numeral(value.length > 4 ? 11.5 : 14,
                    colour: M.ink, weight: 540),
              ),
      );
}
