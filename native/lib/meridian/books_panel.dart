// `ListBody` collides with Flutter's own widget of the same name
// (flutter/src/widgets/basic.dart, re-exported via material.dart) — hidden
// here so books_client.dart's `ListBody` (the current list's body) wins.
import 'package:flutter/material.dart' hide ListBody;

import '../panels/books_client.dart';
import 'hero_icon.dart';
import 'tokens.dart';

/// The Books drawer's contents — the port of `books_panel/1` (and, for the
/// current list's body, `lists_panel/1`) in
/// `lib/app_web/components/voice_modals.ex` (~157-214, ~297-373): a header
/// showing the current book's icon/label plus a type-aware "Clear ↻", a
/// "Switch book" disclosure listing every book, and the current book's body.
///
/// **The garden body is Task 6.** `state.garden` renders `SizedBox.shrink()`
/// here — see the `// Task 6` marker below.
///
/// Server-authoritative, same pattern as the other panels: every write pushes
/// and the UI re-renders from the next `state`. `state.books` and
/// `state.list!.items` arrive already sorted by the server — this view must
/// NOT re-sort either.
///
/// **The one intentional divergence from the web:** the web nests a second
/// `<details>` inside "Switch book" for "➕ New list…"
/// (`voice_modals.ex:374-388`) — two taps to reach a text field, on a phone,
/// inside a drawer. This view FLATTENS that inner disclosure: expanding
/// "Switch book" shows every book AND the create row (label, field, button)
/// in one tap. The form is still hidden behind the outer, collapsed
/// "Switch book" section — only the *second* tap is gone. A future reader
/// should not "restore" the nested disclosure as a bug fix; it is the
/// deliberate flattening described above.
class BooksPanelView extends StatefulWidget {
  const BooksPanelView({super.key, required this.client});

  final BooksClient client;

  /// The "Switch book" summary row — toggles the expanded picker + create row.
  static const Key switchBookToggleKey = ValueKey('books-switch-toggle');

  /// The flattened create row's name field.
  static const Key newListFieldKey = ValueKey('books-new-list-field');

  /// The flattened create row's submit button.
  static const Key createButtonKey = ValueKey('books-create-button');

  /// The current list's add-item field.
  static const Key addItemFieldKey = ValueKey('books-add-item-field');

  /// One row in the expanded "Switch book" picker. Keyed on the book's own
  /// `key` (not its label) since two books could share a label.
  static Key bookRowKey(String key) => ValueKey('books-row-$key');

  /// One item row's checkbox, keyed on the item's own id so a test can
  /// target a specific row rather than "the first checkbox".
  static Key itemCheckboxKey(int id) => ValueKey('books-item-$id');

  /// The delete-list ✕, keyed on the list's own id.
  static Key deleteListKey(int id) => ValueKey('books-delete-list-$id');

  @override
  State<BooksPanelView> createState() => _BooksPanelViewState();
}

class _BooksPanelViewState extends State<BooksPanelView> {
  final _newListCtrl = TextEditingController();
  final _addItemCtrl = TextEditingController();
  bool _switchExpanded = false;

  @override
  void dispose() {
    _newListCtrl.dispose();
    _addItemCtrl.dispose();
    super.dispose();
  }

  void _createList() {
    final name = _newListCtrl.text.trim();
    if (name.isEmpty) return;
    widget.client.newList(name);
    _newListCtrl.clear();
  }

  void _submitAddItem(int listId) {
    final text = _addItemCtrl.text.trim();
    if (text.isEmpty) return;
    widget.client.addItem(listId: listId, text: text);
    _addItemCtrl.clear();
  }

  Future<void> _clearBook(BuildContext context, String question) async {
    if (await _confirm(context, question)) widget.client.clearBook();
  }

  Future<void> _deleteList(BuildContext context, int id, String name) async {
    if (await _confirm(context, 'Delete the $name list?')) {
      widget.client.deleteList(id);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: widget.client,
        builder: (context, _) {
          final state = widget.client.state;
          // The drawer can open before the panel's first `state` push lands.
          if (state == null) return const SizedBox.shrink();
          final currentBook = state.books.firstWhere(
            (b) => b.key == state.currentKey,
            orElse: () => BookRef(key: state.currentKey),
          );
          final bottomInset = MediaQuery.of(context).viewInsets.bottom;
          return Padding(
            // Same rationale as memory_panel.dart:84-90: guarantees there is
            // scroll room below the last field for a focused field's own
            // scrollPadding-driven showOnScreen to actually scroll into.
            padding: EdgeInsets.only(bottom: bottomInset),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(context, state, currentBook),
                const SizedBox(height: 12),
                _switchBook(state, currentBook, bottomInset),
                const SizedBox(height: 12),
                _body(state, currentBook, bottomInset),
              ],
            ),
          );
        },
      );

  Widget _header(BuildContext context, BooksState state, BookRef currentBook) =>
      _card(
        child: Row(
          children: [
            HeroIconView(_iconFor(currentBook.icon), size: 16, color: M.inkDim),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                currentBook.label,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: M.ink,
                ),
              ),
            ),
            _ghostTextButton(
              'Clear ↻',
              onTap: () => _clearBook(context, state.clearConfirm),
            ),
          ],
        ),
      );

  Widget _switchBook(BooksState state, BookRef currentBook, double bottomInset) =>
      _card(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GestureDetector(
              key: BooksPanelView.switchBookToggleKey,
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _switchExpanded = !_switchExpanded),
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'Switch book',
                  style: TextStyle(fontSize: 14, color: M.inkDim),
                ),
              ),
            ),
            if (_switchExpanded)
              Container(
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: M.hairline)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final book in state.books)
                      _bookRow(book, isCurrent: book.key == currentBook.key),
                    const SizedBox(height: 8),
                    _createRow(bottomInset),
                  ],
                ),
              ),
          ],
        ),
      );

  Widget _bookRow(BookRef book, {required bool isCurrent}) => GestureDetector(
        key: BooksPanelView.bookRowKey(book.key),
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.client.selectBook(book.key),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: isCurrent ? M.you.withValues(alpha: 0.12) : null,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              HeroIconView(
                _iconFor(book.icon),
                size: 16,
                color: isCurrent ? M.you : M.inkDim,
              ),
              const SizedBox(width: 8),
              Text(
                book.label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
                  color: isCurrent ? M.you : M.ink,
                ),
              ),
            ],
          ),
        ),
      );

  /// The flattened create row: no nested disclosure, just a label — "➕ New
  /// list…" is the web's own copy for the inner `<summary>` it replaces
  /// (`voice_modals.ex:348-350`) — sitting above an always-visible field +
  /// button. See this file's top doc comment for why there is no second tap.
  Widget _createRow(double bottomInset) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '➕ New list…',
              style: TextStyle(fontSize: 13, color: M.inkDim),
            ),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: BooksPanelView.newListFieldKey,
                    controller: _newListCtrl,
                    style: const TextStyle(fontSize: 14, color: M.ink),
                    decoration: _fieldDecoration('Name your list…'),
                    onSubmitted: (_) => _createList(),
                    // Same idiom as memory_panel.dart's fields — see this
                    // panel's own bottomInset Padding for the other half.
                    scrollPadding: EdgeInsets.only(bottom: bottomInset + 64),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  key: BooksPanelView.createButtonKey,
                  onPressed: _createList,
                  style: OutlinedButton.styleFrom(foregroundColor: M.ink),
                  child: const Text('Create'),
                ),
              ],
            ),
          ),
        ],
      );

  Widget _body(BooksState state, BookRef currentBook, double bottomInset) {
    final list = state.list;
    if (list != null) return _listBody(list, bottomInset);
    if (currentBook.kind == 'garden') {
      // Task 6: the garden body (active plants + past seasons) lands here.
      return const SizedBox.shrink();
    }
    if (currentBook.kind == 'list') {
      return Text(
        'That list is gone — pick another book above.',
        style: TextStyle(fontSize: 14, color: M.ink.withValues(alpha: 0.5)),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _listBody(ListBody list, double bottomInset) {
    final doneCount = list.items.where((i) => i.checked).length;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  list.name,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: M.ink,
                  ),
                ),
              ),
              if (list.household) ...[
                const _Badge('shared', tint: M.henry),
                const SizedBox(width: 4),
              ],
              if (doneCount > 0)
                _ghostTextButton(
                  'Clear done',
                  onTap: () => widget.client.clearDone(list.id),
                ),
              Tooltip(
                message: 'delete list',
                child: GestureDetector(
                  key: BooksPanelView.deleteListKey(list.id),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _deleteList(context, list.id, list.name),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    child: HeroIconView(HeroIcon.xMark, size: 16, color: M.inkDim),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // Server-ordered (ListBody.items) — never re-sort here.
          for (final item in list.items) _itemRow(item),
          if (list.items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                'Nothing on it yet.',
                style: TextStyle(fontSize: 14, color: M.ink.withValues(alpha: 0.5)),
              ),
            ),
          const SizedBox(height: 4),
          _addItemRow(list, bottomInset),
        ],
      ),
    );
  }

  Widget _itemRow(ListItem item) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: Checkbox(
                key: BooksPanelView.itemCheckboxKey(item.id),
                value: item.checked,
                onChanged: (_) => widget.client.toggleItem(item.id),
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                item.text,
                style: TextStyle(
                  fontSize: 14,
                  color: item.checked ? M.ink.withValues(alpha: 0.5) : M.ink,
                  decoration:
                      item.checked ? TextDecoration.lineThrough : TextDecoration.none,
                ),
              ),
            ),
          ],
        ),
      );

  Widget _addItemRow(ListBody list, double bottomInset) => Row(
        children: [
          Expanded(
            child: TextField(
              key: BooksPanelView.addItemFieldKey,
              controller: _addItemCtrl,
              style: const TextStyle(fontSize: 14, color: M.ink),
              decoration: _fieldDecoration('Add to ${list.name}…'),
              onSubmitted: (_) => _submitAddItem(list.id),
              // Same idiom as memory_panel.dart's fields — see this panel's
              // own bottomInset Padding for the other half.
              scrollPadding: EdgeInsets.only(bottom: bottomInset + 64),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: () => _submitAddItem(list.id),
            style: OutlinedButton.styleFrom(foregroundColor: M.ink),
            child: const Text('Add'),
          ),
        ],
      );

  HeroIcon _iconFor(String icon) => switch (icon) {
        'shopping-cart' => HeroIcon.shoppingCart,
        'clipboard-document-list' => HeroIcon.clipboardDocumentList,
        'sun' => HeroIcon.sun,
        'book-open' => HeroIcon.bookOpen,
        _ => HeroIcon.bookOpen,
      };

  Widget _card({Widget? child, EdgeInsetsGeometry? padding}) => Container(
        padding: padding ?? const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: M.hairline),
          borderRadius: BorderRadius.circular(12),
        ),
        child: child,
      );

  Widget _ghostTextButton(String label, {required VoidCallback onTap}) =>
      TextButton(
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

/// Mirrors memory_panel.dart's `_confirm` (and settings_panel.dart's, and
/// connectors_panel.dart's `_explain` minus the choice) — duplicated rather
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
/// reminders_panel.dart's `_Badge` (`:148-178`), duplicated for the same
/// library-privacy reason as `_confirm` above. Do not invent a second pill
/// style for this panel.
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
