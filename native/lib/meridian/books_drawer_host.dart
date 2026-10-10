import 'package:flutter/material.dart';

import '../panels/books_client.dart';
import 'books_details.dart';
import 'books_panel.dart';
import 'drawer.dart';

/// Hosts the Books drawer's layers — the panel, and the recipe or tracker a
/// row opens onto — inside the ONE route `meridianHostedDrawerRoute` pushes,
/// exactly like `SettingsDrawerHost` does for Settings/Memory/Voice Lock:
/// swapping the layer swaps the drawer's title/onBack/child in place, so
/// there is one scrim and one slide, and system back pops a detail back to
/// the book instead of closing the whole drawer.
///
/// Unlike Settings' layers, a detail opens no topic of its own: it reads its
/// row out of the same `panel:books` state the book came from, by id, on
/// every push — so a recipe edited by voice while it is open re-renders, and
/// one deleted elsewhere shows its gone-nudge rather than a stale copy.
class BooksDrawerHost extends StatefulWidget {
  const BooksDrawerHost({
    super.key,
    required this.animation,
    required this.onClose,
    required this.client,
    this.title = 'Books',
  });

  final Animation<double> animation;
  final VoidCallback onClose;
  final BooksClient client;

  /// The drawer's title at the root layer (the nav station's label).
  final String title;

  @override
  State<BooksDrawerHost> createState() => _BooksDrawerHostState();
}

/// Which detail is open. A kind + an id, never the row itself: the row is
/// re-read from the latest state on every build.
enum _Kind { recipe, tracker }

class _Detail {
  const _Detail(this.kind, this.id);
  final _Kind kind;
  final int id;
}

class _BooksDrawerHostState extends State<BooksDrawerHost> {
  _Detail? _detail;

  void _open(_Kind kind, int id) => setState(() => _detail = _Detail(kind, id));

  void _back() => setState(() => _detail = null);

  // The last row each open detail saw. The server sends a collection's body only while it is the
  // CURRENT book, and "current" is a pref every device shares: another device picking Groceries
  // makes the next push here arrive with no recipes at all. An ABSENT body is "not told", not
  // "deleted" — keep showing what we had; only a present body without the row means it's gone.
  RecipeRow? _lastRecipe;
  TrackerRow? _lastTracker;

  RecipeRow? _recipeFor(int id) {
    final rows = widget.client.state?.recipes;
    if (rows == null) return _lastRecipe?.id == id ? _lastRecipe : null;
    return _lastRecipe = rows.find(id);
  }

  TrackerRow? _trackerFor(int id) {
    final rows = widget.client.state?.trackers;
    if (rows == null) return _lastTracker?.id == id ? _lastTracker : null;
    return _lastTracker = rows.find(id);
  }

  /// The detail layer's title: the book's own label, as the channel sent it.
  String _bookLabel(String kind, String fallback) {
    for (final b in widget.client.state?.books ?? const <BookRef>[]) {
      if (b.kind == kind) return b.label;
    }
    return fallback;
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return PopScope(
      // At a detail a pop is blocked and handled as a layer-back instead —
      // system back returns to the book before it ever reaches the route.
      canPop: detail == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: AnimatedBuilder(
        animation: widget.client,
        builder: (context, _) => MeridianDrawer(
          // Keyed per layer, so a detail opens scrolled to its top rather
          // than wherever the book's list had been scrolled to.
          key: ValueKey(
              detail == null ? 'books' : '${detail.kind.name}:${detail.id}'),
          title: switch (detail?.kind) {
            null => widget.title,
            _Kind.recipe => _bookLabel('recipes', 'Recipes'),
            _Kind.tracker => _bookLabel('trackers', 'Trackers'),
          },
          animation: widget.animation,
          onClose: widget.onClose,
          onBack: detail == null ? null : _back,
          child: switch (detail?.kind) {
            null => BooksPanelView(
                client: widget.client,
                onOpenRecipe: (id) => _open(_Kind.recipe, id),
                onOpenTracker: (id) => _open(_Kind.tracker, id),
              ),
            _Kind.recipe => RecipeDetailView(
                recipe: _recipeFor(detail!.id),
                onDelete: (id) {
                  widget.client.deleteRecipe(id);
                  // Back to the book at once: the next push drops the row,
                  // and the book is where the user goes next anyway.
                  _back();
                },
              ),
            _Kind.tracker => TrackerDetailView(
                tracker: _trackerFor(detail!.id),
              ),
          },
        ),
      ),
    );
  }
}
