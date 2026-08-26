import 'package:flutter/material.dart';

import '../panels/books_client.dart';
import 'tokens.dart';

/// The Books drawer's GARDEN body — the port of `garden_panel/1` in
/// `lib/app_web/components/voice_modals.ex` (~216-295): one card per active
/// plant (name, the household `shared` badge, an Archive control, an
/// optional meta line, an optional notes disclosure, and an add-note field),
/// a fallback line when nothing is planted, and a collapsed "Past seasons"
/// disclosure grouping archived plants by season with a read-only Revive
/// control.
///
/// Split out of `books_panel.dart` (Task 5) because the list body and the
/// garden body share nothing but the frame — see that file's own doc comment
/// for the split rationale and the ~450-line threshold that motivated it.
///
/// Server-authoritative, same pattern as the rest of Books: every write
/// pushes and the UI re-renders from the next `state`. `garden.active`,
/// `garden.past`, each season's `plants`, and each plant's `notes` all arrive
/// already ordered by the server — this view must NOT re-sort any of them.
///
/// `meta` and each note's `noted` date are pre-formatted server-side
/// (`AppWeb.BookFormat.plant_meta/1`, `.fmt_noted/1`) — rendered here exactly
/// as given.
class BooksGardenBody extends StatefulWidget {
  const BooksGardenBody({
    super.key,
    required this.garden,
    required this.client,
    required this.bottomInset,
  });

  final GardenBody garden;
  final BooksClient client;
  final double bottomInset;

  /// The "Past seasons" summary row's toggle.
  static const Key pastSeasonsToggleKey = ValueKey('garden-past-toggle');

  /// A plant's meta line, keyed on the plant's own id so a test can assert
  /// its absence (blank `meta`) as precisely as its presence.
  static Key metaKey(int plantId) => ValueKey('garden-meta-$plantId');

  /// A plant's notes-disclosure summary row — absent entirely for a plant
  /// with no notes.
  static Key notesToggleKey(int plantId) =>
      ValueKey('garden-notes-toggle-$plantId');

  /// A plant's add-note field.
  static Key noteFieldKey(int plantId) => ValueKey('garden-note-field-$plantId');

  /// A plant's add-note submit button.
  static Key noteButtonKey(int plantId) =>
      ValueKey('garden-note-button-$plantId');

  /// A plant's Archive control.
  static Key archiveKey(int plantId) => ValueKey('garden-archive-$plantId');

  /// An archived plant's Revive control (inside "Past seasons").
  static Key reviveKey(int plantId) => ValueKey('garden-revive-$plantId');

  @override
  State<BooksGardenBody> createState() => _BooksGardenBodyState();
}

class _BooksGardenBodyState extends State<BooksGardenBody> {
  bool _pastExpanded = false;
  final Set<int> _notesExpanded = {};

  // One controller per active plant's add-note field, created lazily and
  // disposed together below — unlike the list body's single add-item field,
  // the garden shows every active plant's card (and its own add-note field)
  // at once, so a single shared controller would not work here.
  final Map<int, TextEditingController> _noteCtrls = {};

  TextEditingController _noteCtrl(int plantId) =>
      _noteCtrls.putIfAbsent(plantId, TextEditingController.new);

  @override
  void dispose() {
    for (final c in _noteCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _submitNote(GardenPlant plant) {
    final ctrl = _noteCtrl(plant.id);
    final body = ctrl.text.trim();
    if (body.isEmpty) return;
    widget.client.addNote(plantId: plant.id, body: body);
    ctrl.clear();
  }

  Future<void> _archive(BuildContext context, GardenPlant plant) async {
    if (await _confirm(context, 'Move ${plant.name} to past seasons?')) {
      widget.client.archivePlant(plant.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final garden = widget.garden;
    final sections = <Widget>[
      for (final plant in garden.active) _plantCard(context, plant),
      if (garden.active.isEmpty)
        Text(
          'Nothing growing yet — just say what you planted.',
          style: TextStyle(fontSize: 14, color: M.ink.withValues(alpha: 0.5)),
        ),
      if (garden.past.isNotEmpty) _pastSeasons(garden.past),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < sections.length; i++) ...[
          sections[i],
          if (i != sections.length - 1) const SizedBox(height: 12),
        ],
      ],
    );
  }

  Widget _plantCard(BuildContext context, GardenPlant plant) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: M.hairline),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    plant.name,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: M.ink,
                    ),
                  ),
                ),
                if (plant.household) ...[
                  const _Badge('shared', tint: M.henry),
                  const SizedBox(width: 4),
                ],
                _ghostTextButton(
                  'Archive',
                  key: BooksGardenBody.archiveKey(plant.id),
                  onTap: () => _archive(context, plant),
                ),
              ],
            ),
            if (plant.meta.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                plant.meta,
                key: BooksGardenBody.metaKey(plant.id),
                style: TextStyle(fontSize: 12, color: M.ink.withValues(alpha: 0.6)),
              ),
            ],
            if (plant.notes.isNotEmpty) ...[
              const SizedBox(height: 4),
              _notesDisclosure(plant),
            ],
            const SizedBox(height: 8),
            _addNoteRow(plant),
          ],
        ),
      );

  Widget _notesDisclosure(GardenPlant plant) {
    final expanded = _notesExpanded.contains(plant.id);
    // The caller only reaches here when plant.notes is non-empty (mirroring
    // the web's own `:if={plant.notes != []}` guard on the <details>,
    // voice_modals.ex:248), so the summary is always the LAST note's body.
    final summary = _latestNoteLine(plant.notes);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          key: BooksGardenBody.notesToggleKey(plant.id),
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() {
            if (expanded) {
              _notesExpanded.remove(plant.id);
            } else {
              _notesExpanded.add(plant.id);
            }
          }),
          child: Text(
            summary,
            style: const TextStyle(fontSize: 14, color: M.inkDim),
          ),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              // Server-ordered (oldest-first) — never re-sort here.
              children: [for (final note in plant.notes) _noteRow(note)],
            ),
          ),
      ],
    );
  }

  Widget _noteRow(PlantNote note) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                note.body,
                style: const TextStyle(fontSize: 14, color: M.ink),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              note.noted,
              style: TextStyle(
                fontSize: 12,
                color: M.ink.withValues(alpha: 0.6),
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
      );

  Widget _addNoteRow(GardenPlant plant) => Row(
        children: [
          Expanded(
            child: TextField(
              key: BooksGardenBody.noteFieldKey(plant.id),
              controller: _noteCtrl(plant.id),
              style: const TextStyle(fontSize: 14, color: M.ink),
              decoration: _fieldDecoration('Check in on ${plant.name}…'),
              onSubmitted: (_) => _submitNote(plant),
              // Same idiom as books_panel.dart's fields — see this body's
              // bottomInset param, threaded from the shared Padding in
              // books_panel.dart's own build().
              scrollPadding: EdgeInsets.only(bottom: widget.bottomInset + 64),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            key: BooksGardenBody.noteButtonKey(plant.id),
            onPressed: () => _submitNote(plant),
            style: OutlinedButton.styleFrom(foregroundColor: M.ink),
            child: const Text('Note'),
          ),
        ],
      );

  Widget _pastSeasons(List<PastSeason> seasons) => _card(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GestureDetector(
              key: BooksGardenBody.pastSeasonsToggleKey,
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _pastExpanded = !_pastExpanded),
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'Past seasons',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: M.inkDim,
                  ),
                ),
              ),
            ),
            if (_pastExpanded)
              Container(
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: M.hairline)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Server-ordered (newest-first) — never re-sort here.
                    for (final season in seasons) ...[
                      _seasonSection(season),
                      const SizedBox(height: 8),
                    ],
                  ],
                ),
              ),
          ],
        ),
      );

  Widget _seasonSection(PastSeason season) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            season.season,
            style: TextStyle(fontSize: 12, color: M.ink.withValues(alpha: 0.6)),
          ),
          const SizedBox(height: 4),
          // Server-ordered — never re-sort here.
          for (final plant in season.plants) _archivedPlantRow(plant),
        ],
      );

  Widget _archivedPlantRow(GardenPlant plant) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                plant.name,
                style: TextStyle(fontSize: 14, color: M.ink.withValues(alpha: 0.7)),
              ),
            ),
            if (plant.household) ...[
              const _Badge('shared', tint: M.henry),
              const SizedBox(width: 4),
            ],
            _ghostTextButton(
              'Revive',
              key: BooksGardenBody.reviveKey(plant.id),
              onTap: () => widget.client.revivePlant(plant.id),
            ),
          ],
        ),
      );

  Widget _card({Widget? child, EdgeInsetsGeometry? padding}) => Container(
        padding: padding ?? const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: M.hairline),
          borderRadius: BorderRadius.circular(12),
        ),
        child: child,
      );

  Widget _ghostTextButton(String label, {Key? key, required VoidCallback onTap}) =>
      TextButton(
        key: key,
        onPressed: onTap,
        style: TextButton.styleFrom(
          foregroundColor: M.inkDim,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(label, style: const TextStyle(fontSize: 13)),
      );

  InputDecoration _fieldDecoration(String hint) => InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: TextStyle(fontSize: 14, color: M.ink.withValues(alpha: 0.4)),
        filled: true,
        fillColor: M.bg.withValues(alpha: 0.3),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: M.hairline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: M.hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: M.you.withValues(alpha: 0.6)),
        ),
      );
}

/// Mirrors `AppWeb.BookFormat.latest_note_line/1` verbatim, including its
/// empty-list "Notes" fallback. That branch is dead code on the web too:
/// `garden_panel/1` only renders the notes `<details>` `:if={plant.notes !=
/// []}` (voice_modals.ex:248), so `latest_note_line/1` is never actually
/// invoked there with an empty list — and every call site in this file
/// (see `_notesDisclosure`) is guarded the same way. Reproduced in full
/// anyway so this stays an honest port of the source function, rather than
/// silently dropping a branch a future edit might come to rely on.
String _latestNoteLine(List<PlantNote> notes) =>
    notes.isEmpty ? 'Notes' : notes.last.body;

/// Mirrors the web's `data-confirm`, and books_panel.dart's own `_confirm`
/// (and memory_panel.dart's, and settings_panel.dart's) — duplicated rather
/// than shared because it is `_`-private to that library. Acts only on an
/// explicit true — a dismissed dialog returns false.
Future<bool> _confirm(BuildContext context, String question) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      content: Text(question),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel')),
        TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('OK')),
      ],
    ),
  );
  return ok ?? false;
}

/// The web's `badge badge-sm badge-accent` "shared" pill — the same recipe as
/// reminders_panel.dart's `_Badge` (`:148-178`) and books_panel.dart's own
/// copy of it, duplicated for the same library-privacy reason as `_confirm`
/// above. Do not invent a second pill style for this panel.
class _Badge extends StatelessWidget {
  const _Badge(this.text, {this.tint});

  final String text;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final c = tint ?? M.chromeDim;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        border: Border.all(color: c.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9.92,
          fontWeight: FontWeight.w600,
          letterSpacing: MType.track(9.92, 0.18),
          color: c,
        ),
      ),
    );
  }
}
