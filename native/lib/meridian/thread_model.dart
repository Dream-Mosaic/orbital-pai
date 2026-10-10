import 'package:flutter/foundation.dart';

/// Friendly labels for the live tool-call chip, keyed by App.Tools registry
/// names. The first nine are ported verbatim from TOOL_LABELS in the old web
/// client (index.js:57-67); the rest cover every tool registered since, so no
/// chip falls back to a raw function name.
const Map<String, String> kToolLabels = {
  'get_weather': 'checking the weather',
  'get_calendar_events': 'checking your calendar',
  'create_event': 'adding to your calendar',
  'create_reminder': 'setting a reminder',
  'list_reminders': 'checking your reminders',
  'search_email': 'checking your email',
  'read_email': 'checking your email',
  'send_email': 'sending an email',
  'recall_memory': 'thinking back',
  // household messages
  'send_household_message': 'sending a message',
  'check_household_messages': 'checking messages',
  // timers
  'set_timer': 'setting a timer',
  'list_timers': 'checking your timers',
  'cancel_timer': 'stopping a timer',
  'add_to_timer': 'adding time to a timer',
  // reminders
  'acknowledge_reminder': 'clearing that reminder',
  'create_followup': 'setting a follow-up',
  'cancel_reminder': 'cancelling a reminder',
  // lists
  'add_to_list': 'adding to your list',
  'check_off': 'checking that off',
  'read_list': 'checking your list',
  'clear_checked': 'clearing done items',
  'remove_item': 'removing from your list',
  // garden
  'add_plant': 'adding to the garden',
  'note_plant': 'noting that in the garden',
  'list_garden': 'checking the garden',
  'archive_plant': 'archiving a plant',
  'close_season': 'closing out the season',
  'remove_plant': 'removing a plant',
  'update_plant': 'updating the garden',
  // home assistant
  'home_index': 'checking the house',
  'home_find': 'looking around the house',
  'home_control': 'adjusting the house',
  'play_music': 'starting the music',
  // trackers
  'log_tracker_entry': 'logging that',
  'get_tracker_entries': 'looking at your log',
  'list_trackers': 'checking your trackers',
  'undo_tracker_entry': 'scratching that',
  'delete_tracker': 'deleting a tracker',
  // routines
  'save_routine': 'saving a routine',
  'list_routines': 'checking your routines',
  'delete_routine': 'deleting a routine',
  'run_routine': 'running your routine',
  // recipes
  'save_recipe': 'saving the recipe',
  'get_recipe': 'pulling up the recipe',
  'list_recipes': 'checking your recipes',
  'edit_recipe': 'updating the recipe',
  'delete_recipe': 'deleting a recipe',
};

String toolLabel(String name) => kToolLabels[name] ?? name.replaceAll('_', ' ');

/// The speakers the server actually emits: `speak_start`'s `source` is one of
/// brain / reflex / reminder / briefing / followup / timer / message / heads_up
/// (an agenda item's `kind` via reflex_source/1), and the history backfill adds
/// `you`.
enum LineKind {
  you,
  brain,
  reflex,
  reminder,
  briefing,
  followup,
  timer,
  message,
  headsUp,
  news
}

LineKind? lineKindFromSource(String source) => switch (source) {
      'you' => LineKind.you,
      'brain' => LineKind.brain,
      'reflex' => LineKind.reflex,
      'reminder' => LineKind.reminder,
      'briefing' => LineKind.briefing,
      'followup' => LineKind.followup,
      'timer' => LineKind.timer,
      'message' => LineKind.message,
      'heads_up' => LineKind.headsUp,
      'news' => LineKind.news,
      _ => null,
    };

enum AckState { none, offered, acked }

@immutable
sealed class ThreadItem {
  const ThreadItem();

  /// The item's own CSS vertical margin, in logical px. Adjacent margins COLLAPSE
  /// to the larger of the two, which [Thread] resolves when laying items out —
  /// a uniform gap would put 16.8px between stacked tool chips, which have no
  /// margin rule at all, and between two reflex asides, which set their own.
  double get margin => 16.8; // .voice-line margin: 1.05rem 0
}

@immutable
class ThreadLine extends ThreadItem {
  const ThreadLine({
    required this.kind,
    required this.label,
    required this.text,
    this.markdown = false,
    this.thinking = false,
    this.ack = AckState.none,
    this.ackId,
  });

  final LineKind kind;

  /// `brain`/`reflex` show the assistant's name; every other source shows its own
  /// key (index.js:687). The CSS lowercases it.
  final String label;
  final String text;

  /// Brain answers render markdown once the turn completes; while deltas stream
  /// they stay plaintext so a half-open `**` can't flicker.
  final bool markdown;

  /// The faint italic "Henry: thinking…" placeholder.
  final bool thinking;

  final AckState ack;
  final int? ackId;

  // .who-reflex { margin: 0.55rem 0 } overrides .voice-line's 1.05rem.
  @override
  double get margin => kind == LineKind.reflex ? 8.8 : 16.8;

  ThreadLine copyWith({String? text, bool? markdown, AckState? ack, int? ackId}) =>
      ThreadLine(
        kind: kind,
        label: label,
        text: text ?? this.text,
        markdown: markdown ?? this.markdown,
        thinking: thinking,
        ack: ack ?? this.ack,
        ackId: ackId ?? this.ackId,
      );
}

/// The one-shot `— earlier —` rule after the history backfill.
@immutable
class ThreadDivider extends ThreadItem {
  const ThreadDivider();

  @override
  double get margin => 5.6; // .voice-divider margin: 0.35rem 0
}

/// The latency HUD: one dim line per turn, updated in place as ttfa then ttb land.
@immutable
class ThreadMetrics extends ThreadItem {
  const ThreadMetrics({this.ttfaMs, this.ttbMs});

  final int? ttfaMs;
  final int? ttbMs;

  /// `.voice-metrics` sets no margin, so it inherits the browser's 0 for a div.
  @override
  double get margin => 0;

  /// Words, not the web's ⚡/🧠: the bundled fonts carry no emoji, so those
  /// rendered in whatever emoji font a desktop happened to have.
  String get text {
    final parts = <String>[];
    if (ttfaMs != null) parts.add('audio ${(ttfaMs! / 1000).toStringAsFixed(1)}s');
    if (ttbMs != null) parts.add('brain ${(ttbMs! / 1000).toStringAsFixed(1)}s');
    return parts.join(' · ');
  }
}

/// The visual twin of the audio tool-bridge filler.
@immutable
class ThreadToolChip extends ThreadItem {
  const ThreadToolChip({required this.name, this.resolved = false});

  final String name;
  final bool resolved;

  /// `.voice-tool-chip` sets no margin either.
  @override
  double get margin => 0;

  String get text => '⚙ ${toolLabel(name)}${resolved ? ' ✓' : '…'}';

  ThreadToolChip resolve() => ThreadToolChip(name: name, resolved: true);
}

/// A visual answer: a tool result the server has already shaped into display
/// strings (`App.Cards`). [type] picks the layout and [data] is the card map
/// exactly as the channel sent it — the client lays it out, never reformats it.
@immutable
class ThreadCard extends ThreadItem {
  const ThreadCard({required this.type, required this.data});

  final String type;
  final Map<String, dynamic> data;

  /// The card types this build can lay out. Anything else is skipped at the
  /// router, never rendered as a guess.
  static const Set<String> knownTypes = {
    'weather',
    'agenda',
    'list',
    'reminders',
    'email',
    'tracker',
    'tracker_logged',
    'recipe',
    'cook_step',
  };

  /// A card as the channel sends it (the live `card` push and each history
  /// turn's `cards`), or null when it is not a map or its type is not one
  /// this build can lay out.
  static ThreadCard? fromWire(Object? raw) {
    if (raw is! Map) return null;
    final data = raw.cast<String, dynamic>();
    final type = data['type'];
    if (type is String && knownTypes.contains(type)) {
      return ThreadCard(type: type, data: data);
    }
    return null;
  }

  /// Tighter than a line's rhythm against the tool chip above it; the
  /// collapse rule still gives the answer line below its own 16.8.
  @override
  double get margin => 10.0;
}
