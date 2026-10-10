/// The Books panel's three COLLECTION books — recipes, trackers, routines —
/// as `AppWeb.CollectionFormat` renders them. Each rides the `state` push like
/// the list and garden bodies do, non-null only while it is the current book.
///
/// Every string here is the server's, rendered verbatim: dates, counts,
/// stats, empty states and each row's own delete confirmation. Parsing is
/// lenient the same way `books_client.dart` is: a row missing the id the
/// panel acts on is dropped, a missing string reads as empty, and a body of
/// the wrong shape is null rather than a throw inside the stream listener.
library;

String _s(Object? v) => v is String ? v : '';

List<String> _strs(Object? raw) =>
    raw is List ? raw.whereType<String>().toList(growable: false) : const [];

List<Map<String, dynamic>> _maps(Object? raw) => raw is List
    ? raw
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList(growable: false)
    : const [];

/// Rows the panel acts on by id: one without a numeric id is dropped.
List<T> _rows<T>(Object? raw, T Function(Map<String, dynamic>) parse) =>
    _maps(raw).where((m) => m['id'] is num).map(parse).toList(growable: false);

T? _find<T>(List<T> items, int id, int Function(T) idOf) {
  for (final i in items) {
    if (idOf(i) == id) return i;
  }
  return null;
}

// ---- recipes ----

/// One recipe: its list row and the full detail it opens onto.
class RecipeRow {
  const RecipeRow({
    required this.id,
    this.title = '',
    this.shared = false,
    this.tag = '',
    this.meta = '',
    this.detailMeta = '',
    this.ingredients = const [],
    this.steps = const [],
    this.notes = '',
    this.deleteConfirm = '',
  });

  final int id;
  final String title;

  /// Household (true) or private to this user. Display only: the delete's
  /// scope is derived server-side from the row, never sent from here.
  final bool shared;

  /// "shared" | "yours".
  final String tag;

  /// "9 ingredients · 6 steps".
  final String meta;

  /// "Serves 6 · From Grandma", or empty.
  final String detailMeta;
  final List<String> ingredients;

  /// Un-numbered: the detail view numbers them.
  final List<String> steps;
  final String notes;

  /// Bound to THIS row: the dialog reads it and the delete names this id.
  final String deleteConfirm;

  static RecipeRow fromJson(Map<String, dynamic> j) => RecipeRow(
        id: (j['id'] as num).toInt(),
        title: _s(j['title']),
        shared: j['shared'] == true,
        tag: _s(j['tag']),
        meta: _s(j['meta']),
        detailMeta: _s(j['detail_meta']),
        ingredients: _strs(j['ingredients']),
        steps: _strs(j['steps']),
        notes: _s(j['notes']),
        deleteConfirm: _s(j['delete_confirm']),
      );
}

class RecipesBody {
  const RecipesBody({this.items = const [], this.empty = '', this.hint = ''});

  /// Server-ordered (by name); never re-sort here.
  final List<RecipeRow> items;
  final String empty;
  final String hint;

  RecipeRow? find(int id) => _find(items, id, (r) => r.id);

  static RecipesBody? fromJson(Object? raw) => raw is Map
      ? RecipesBody(
          items: _rows(raw['items'], RecipeRow.fromJson),
          empty: _s(raw['empty']),
          hint: _s(raw['hint']),
        )
      : null;
}

// ---- trackers ----

/// One day of a tracker's 30-day chart, oldest first. Same shape as the
/// thread's tracker card series.
class TrackerPoint {
  const TrackerPoint({
    this.label = '',
    this.count = 0,
    this.value,
    this.peak = '',
    this.tip = '',
  });

  final String label;

  /// What the chart reads out when this day is touched
  /// ("Thu, Oct 8 · up to 8 · 2 entries").
  final String tip;

  /// Entries that day; 0 is a day with nothing logged.
  final int count;

  /// The day's worst value, or null (nothing logged, or a habit entry).
  final double? value;

  /// The highest day's value as display text, on that one day only.
  final String peak;

  bool get logged => count > 0 || value != null;

  static TrackerPoint fromJson(Map<String, dynamic> j) {
    final v = j['value'];
    final c = j['count'];
    return TrackerPoint(
      label: _s(j['label']),
      count: c is num ? c.toInt() : (v is num ? 1 : 0),
      value: v is num ? v.toDouble() : null,
      peak: _s(j['peak']),
      tip: _s(j['tip']),
    );
  }
}

class TrackerStat {
  const TrackerStat({this.label = '', this.value = ''});

  final String label;
  final String value;

  static TrackerStat fromJson(Map<String, dynamic> j) =>
      TrackerStat(label: _s(j['label']), value: _s(j['value']));
}

class TrackerTag {
  const TrackerTag({this.tag = '', this.tally = ''});

  final String tag;

  /// "×4", or empty for a tag seen once.
  final String tally;

  static TrackerTag fromJson(Map<String, dynamic> j) =>
      TrackerTag(tag: _s(j['tag']), tally: _s(j['tally']));
}

class TrackerEntryRow {
  const TrackerEntryRow({
    this.day = '',
    this.time = '',
    this.value = '',
    this.note = '',
    this.tags = const [],
  });

  /// "Today" | "Yesterday" | "Wed, Oct 7" | "Oct 7, 2025".
  final String day;

  /// "2:15 PM".
  final String time;

  /// "6" | "182.4 lb", or empty for a habit entry.
  final String value;
  final String note;
  final List<String> tags;

  static TrackerEntryRow fromJson(Map<String, dynamic> j) => TrackerEntryRow(
        day: _s(j['day']),
        time: _s(j['time']),
        value: _s(j['value']),
        note: _s(j['note']),
        tags: _strs(j['tags']),
      );
}

/// One tracker: its list row and its detail.
class TrackerRow {
  const TrackerRow({
    required this.id,
    this.label = '',
    this.unit = '',
    this.count = '',
    this.last = '',
    this.range = '',
    this.series = const [],
    this.axisFrom = '',
    this.axisTo = '',
    this.stats = const [],
    this.tags = const [],
    this.recent = const [],
    this.more = '',
    this.quiet = '',
  });

  final int id;
  final String label;
  final String unit;

  /// "14 entries".
  final String count;

  /// "2 days ago · 6" | "No entries yet".
  final String last;

  /// "Last 30 days".
  final String range;
  final List<TrackerPoint> series;
  final String axisFrom;
  final String axisTo;
  final List<TrackerStat> stats;
  final List<TrackerTag> tags;

  /// Newest first.
  final List<TrackerEntryRow> recent;

  /// "Showing the latest 20 of 48", or empty.
  final String more;

  /// "Nothing logged in the last 30 days.", or empty.
  final String quiet;

  static TrackerRow fromJson(Map<String, dynamic> j) => TrackerRow(
        id: (j['id'] as num).toInt(),
        label: _s(j['label']),
        unit: _s(j['unit']),
        count: _s(j['count']),
        last: _s(j['last']),
        range: _s(j['range']),
        series: _maps(j['series'])
            .map(TrackerPoint.fromJson)
            .toList(growable: false),
        axisFrom: _s(j['axis_from']),
        axisTo: _s(j['axis_to']),
        stats:
            _maps(j['stats']).map(TrackerStat.fromJson).toList(growable: false),
        tags: _maps(j['tags']).map(TrackerTag.fromJson).toList(growable: false),
        recent: _maps(j['recent'])
            .map(TrackerEntryRow.fromJson)
            .toList(growable: false),
        more: _s(j['more']),
        quiet: _s(j['quiet']),
      );
}

class TrackersBody {
  const TrackersBody({this.items = const [], this.empty = '', this.hint = ''});

  /// Server-ordered (most recently active first); never re-sort here.
  final List<TrackerRow> items;
  final String empty;
  final String hint;

  TrackerRow? find(int id) => _find(items, id, (t) => t.id);

  static TrackersBody? fromJson(Object? raw) => raw is Map
      ? TrackersBody(
          items: _rows(raw['items'], TrackerRow.fromJson),
          empty: _s(raw['empty']),
          hint: _s(raw['hint']),
        )
      : null;
}

// ---- routines ----

class RoutineRow {
  const RoutineRow({
    required this.id,
    this.name = '',
    this.say = const [],
    this.steps = '',
    this.lastRun = '',
    this.deleteConfirm = '',
  });

  final int id;
  final String name;

  /// The phrases that run it, the name first.
  final List<String> say;

  /// Free text, as the user said it.
  final String steps;

  /// "Ran yesterday" | "Not run yet".
  final String lastRun;
  final String deleteConfirm;

  static RoutineRow fromJson(Map<String, dynamic> j) => RoutineRow(
        id: (j['id'] as num).toInt(),
        name: _s(j['name']),
        say: _strs(j['say']),
        steps: _s(j['steps']),
        lastRun: _s(j['last_run']),
        deleteConfirm: _s(j['delete_confirm']),
      );
}

class RoutinesBody {
  const RoutinesBody({this.items = const [], this.empty = '', this.hint = ''});

  /// Server-ordered (alphabetical); never re-sort here.
  final List<RoutineRow> items;
  final String empty;
  final String hint;

  static RoutinesBody? fromJson(Object? raw) => raw is Map
      ? RoutinesBody(
          items: _rows(raw['items'], RoutineRow.fromJson),
          empty: _s(raw['empty']),
          hint: _s(raw['hint']),
        )
      : null;
}
