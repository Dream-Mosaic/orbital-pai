import 'dart:async';

import 'package:flutter/foundation.dart';

import '../connection/app_connection.dart';
import '../phoenix/decoded_message.dart';
import '../phoenix/phoenix_channel.dart';

/// One entry in the book switcher: a personal/household list, or the garden.
class BookRef {
  const BookRef({
    required this.key,
    this.label = '',
    this.kind = '',
    this.icon = '',
  });

  /// "list:<id>" or "garden" — the handle [BooksClient.selectBook] pushes.
  final String key;
  final String label;

  /// "list" | "garden" — `Atom.to_string/1` server-side.
  final String kind;

  /// The bare hero-icon name (server already stripped the `hero-` prefix).
  final String icon;

  static BookRef fromJson(Map<String, dynamic> j) => BookRef(
        key: j['key'] as String,
        label: j['label'] as String? ?? '',
        kind: j['kind'] as String? ?? '',
        icon: j['icon'] as String? ?? '',
      );
}

/// One row of a list book.
class ListItem {
  const ListItem({
    required this.id,
    required this.text,
    this.checked = false,
  });

  final int id;
  final String text;
  final bool checked;

  static ListItem fromJson(Map<String, dynamic> j) => ListItem(
        id: (j['id'] as num).toInt(),
        text: j['text'] as String,
        checked: j['checked'] == true,
      );
}

/// The currently-selected list book's full body.
class ListBookBody {
  const ListBookBody({
    required this.id,
    this.name = '',
    this.household = false,
    this.items = const [],
  });

  final int id;
  final String name;
  final bool household;

  /// Server-ordered (`BookFormat.sorted_items/1`); never re-sort here.
  final List<ListItem> items;

  static ListBookBody fromJson(Map<String, dynamic> j) => ListBookBody(
        id: (j['id'] as num).toInt(),
        name: j['name'] as String? ?? '',
        household: j['household'] == true,
        items: _items(j['items']),
      );

  static List<ListItem> _items(Object? raw) => raw is List
      ? raw
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          // id is the handle toggle_item pushes; a row missing it, or with no
          // usable text, cannot be rendered — drop just that row rather than
          // letting fromJson's cast throw inside the stream listener and
          // blank an otherwise good payload.
          .where((m) => m['id'] is num && m['text'] is String)
          .map(ListItem.fromJson)
          .toList(growable: false)
      : const [];
}

/// One note left on an active plant.
class PlantNote {
  const PlantNote({this.body = '', this.noted = ''});

  final String body;
  final String noted;

  static PlantNote fromJson(Map<String, dynamic> j) => PlantNote(
        body: j['body'] as String? ?? '',
        noted: j['noted'] as String? ?? '',
      );
}

/// A plant, active or archived. `meta`/`notes` are blank for an archived
/// (Past-season) row — the server never sends them there.
class GardenPlant {
  const GardenPlant({
    required this.id,
    this.name = '',
    this.household = false,
    this.meta = '',
    this.notes = const [],
  });

  final int id;
  final String name;
  final bool household;
  final String meta;
  final List<PlantNote> notes;

  static GardenPlant fromJson(Map<String, dynamic> j) => GardenPlant(
        id: (j['id'] as num).toInt(),
        name: j['name'] as String? ?? '',
        household: j['household'] == true,
        meta: j['meta'] as String? ?? '',
        notes: _notes(j['notes']),
      );

  static List<PlantNote> _notes(Object? raw) => raw is List
      ? raw
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .map(PlantNote.fromJson)
          .toList(growable: false)
      : const [];
}

/// One archived season's plants. `past` is a LIST of these, in the server's
/// own newest-first order — never re-sorted, never read as a map.
class PastSeason {
  const PastSeason({this.season = '', this.plants = const []});

  final String season;
  final List<GardenPlant> plants;

  static PastSeason fromJson(Map<String, dynamic> j) => PastSeason(
        season: j['season'] as String? ?? '',
        plants: _plants(j['plants']),
      );

  static List<GardenPlant> _plants(Object? raw) => raw is List
      ? raw
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .where((m) => m['id'] is num)
          .map(GardenPlant.fromJson)
          .toList(growable: false)
      : const [];
}

/// The currently-selected garden book's full body.
class GardenBody {
  const GardenBody({this.active = const [], this.past = const []});

  final List<GardenPlant> active;

  /// A LIST of {season, plants}, sorted newest-first by the server. Reading
  /// this as a Map would lose that order entirely — JSON object key order
  /// does not survive to Dart.
  final List<PastSeason> past;

  static GardenBody fromJson(Map<String, dynamic> j) => GardenBody(
        active: _active(j['active']),
        past: _past(j['past']),
      );

  static List<GardenPlant> _active(Object? raw) => raw is List
      ? raw
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .where((m) => m['id'] is num)
          .map(GardenPlant.fromJson)
          .toList(growable: false)
      : const [];

  static List<PastSeason> _past(Object? raw) => raw is List
      ? raw
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .map(PastSeason.fromJson)
          .toList(growable: false)
      : const [];
}

/// The Books drawer's state, as the server rendered it.
class BooksState {
  const BooksState({
    this.books = const [],
    this.currentKey = '',
    this.clearConfirm = '',
    this.list,
    this.garden,
  });

  /// Server-ordered; never re-sort here.
  final List<BookRef> books;
  final String currentKey;
  final String clearConfirm;

  /// Non-null only when the current book is a list.
  final ListBookBody? list;

  /// Non-null only when the current book is the garden.
  final GardenBody? garden;

  static BooksState fromJson(Map<String, dynamic> j) => BooksState(
        books: _books(j['books']),
        currentKey: j['current_key'] as String? ?? '',
        clearConfirm: j['clear_confirm'] as String? ?? '',
        list: _list(j['list']),
        garden: _garden(j['garden']),
      );

  static List<BookRef> _books(Object? raw) => raw is List
      ? raw
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          // key is the handle select_book pushes, so a row without one
          // cannot be acted on — drop just that row, its siblings still land.
          .where((m) => m['key'] is String)
          .map(BookRef.fromJson)
          .toList(growable: false)
      : const [];

  static ListBookBody? _list(Object? raw) =>
      raw is Map && raw['id'] is num
          ? ListBookBody.fromJson(raw.cast<String, dynamic>())
          : null;

  static GardenBody? _garden(Object? raw) =>
      raw is Map ? GardenBody.fromJson(raw.cast<String, dynamic>()) : null;
}

/// Joined only while the Books drawer is on screen: join MEANS open.
/// Server-authoritative: a control pushes and the UI re-renders from the next
/// `state` — this channel rides eight of its ten writes' broadcasts and only
/// re-pushes itself for `select_book`/`new_list` (see the channel's
/// moduledoc), but that distinction is entirely server-side; every push here
/// looks the same from the client.
class BooksClient extends ChangeNotifier {
  BooksClient({required AppConnection connection}) : _connection = connection;

  /// The suffix is ignored server-side; the user comes from the token.
  static const String topic = 'panel:books:henry';

  final AppConnection _connection;

  PhoenixChannel? _channel;
  StreamSubscription<DecodedMessage>? _sub;
  BooksState? _state;
  bool _open = false;
  bool _disposed = false;

  BooksState? get state => _state;
  bool get isOpen => _open;

  void open() {
    if (_open) return;
    _open = true;
    _connection.openChannel(topic, onChannel: _adopt);
  }

  void close() {
    if (!_open) return;
    _open = false;
    _connection.closeChannel(topic);
    unawaited(_sub?.cancel());
    _sub = null;
    _channel = null;
    _state = null;
    _notify();
  }

  void selectBook(String key) => _push('select_book', {'key': key});

  void newList(String name) => _push('new_list', {'name': name});

  /// No book argument on purpose: the server acts on the book it has stored
  /// as current, because this is the panel's most destructive control. A
  /// client-supplied key would let a stale panel empty the wrong list.
  /// Clear the current book. [key] is the key of the book the user was LOOKING
  /// AT when they confirmed — it is a precondition, not a target: the server
  /// resolves the book itself and refuses with `stale` if the two disagree.
  ///
  /// Pass the key from the SAME state snapshot that produced the confirmation
  /// text you showed. The pref is shared with the web, `update_prefs` broadcasts
  /// nothing, and this is the panel's most destructive control — so consent has
  /// to name what it consented to.
  void clearBook(String key) => _push('clear_book', {'key': key});

  void toggleItem(int id) => _push('toggle_item', {'id': id});

  void addItem({required int listId, required String text}) =>
      _push('add_item', {'list_id': listId, 'text': text});

  void clearDone(int listId) => _push('clear_done', {'list_id': listId});

  void deleteList(int listId) => _push('delete_list', {'list_id': listId});

  void addNote({required int plantId, required String body}) =>
      _push('add_note', {'plant_id': plantId, 'body': body});

  void archivePlant(int id) => _push('archive_plant', {'id': id});

  void revivePlant(int id) => _push('revive_plant', {'id': id});

  bool _push(String event, Map<String, dynamic> payload) {
    final ch = _channel;
    // Phoenix answers a frame on a topic it has not joined with "unmatched
    // topic", so a write between open() and the join reply is silently lost.
    if (ch == null || !ch.isJoined) return false;
    ch.push(event, payload);
    return true;
  }

  /// Delivery is at channel CREATION, not join: the server pushes `state`
  /// straight behind its join reply and `messages` is unbuffered.
  void _adopt(PhoenixChannel ch) {
    _channel = ch;
    unawaited(_sub?.cancel());
    _sub = ch.messages.listen(_onMessage);
  }

  void _onMessage(DecodedMessage m) {
    if (m.event != 'state') return;
    _state = BooksState.fromJson(m.json ?? const <String, dynamic>{});
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    if (_open) _connection.closeChannel(topic);
    unawaited(_sub?.cancel());
    super.dispose();
  }
}
