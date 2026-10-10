import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/meridian/thread_model.dart';

void main() {
  test('TOOL_LABELS is ported verbatim, with the humanised fallback', () {
    // index.js:57-67, keyed by App.Tools registry names.
    expect(toolLabel('get_weather'), 'checking the weather');
    expect(toolLabel('get_calendar_events'), 'checking your calendar');
    expect(toolLabel('create_event'), 'adding to your calendar');
    expect(toolLabel('create_reminder'), 'setting a reminder');
    expect(toolLabel('list_reminders'), 'checking your reminders');
    expect(toolLabel('search_email'), 'checking your email');
    expect(toolLabel('read_email'), 'checking your email');
    expect(toolLabel('send_email'), 'sending an email');
    expect(toolLabel('recall_memory'), 'thinking back');
    expect(toolLabel('send_household_message'), 'sending a message');
    expect(toolLabel('check_household_messages'), 'checking messages');
    expect(toolLabel('set_timer'), 'setting a timer');
    expect(toolLabel('list_timers'), 'checking your timers');
    expect(toolLabel('cancel_timer'), 'stopping a timer');
    // index.js:578 — name.replace(/_/g, " ")
    expect(toolLabel('some_new_tool'), 'some new tool');
    expect(kToolLabels, hasLength(47));
  });

  test('every registered server tool has a friendly label', () {
    // The declarations/0 of every module in server/lib/app/tools/*.ex. A tool missing here
    // falls back to its raw name ("home control"), which reads like a log line.
    const registered = [
      'get_weather',
      'get_calendar_events', 'create_event',
      'create_reminder', 'list_reminders', 'acknowledge_reminder', 'create_followup',
      'cancel_reminder',
      'search_email', 'read_email', 'send_email',
      'recall_memory',
      'add_to_list', 'check_off', 'read_list', 'clear_checked', 'remove_item',
      'add_plant', 'note_plant', 'list_garden', 'archive_plant', 'close_season',
      'remove_plant', 'update_plant',
      'home_index', 'home_find', 'home_control', 'play_music',
      'set_timer', 'list_timers', 'cancel_timer',
      'send_household_message', 'check_household_messages',
      'log_tracker_entry', 'get_tracker_entries', 'list_trackers', 'undo_tracker_entry',
      'delete_tracker',
      'save_routine', 'list_routines', 'delete_routine', 'run_routine',
      'save_recipe', 'get_recipe', 'list_recipes', 'edit_recipe', 'delete_recipe',
    ];
    for (final name in registered) {
      expect(kToolLabels.containsKey(name), isTrue, reason: '$name has no label');
    }
  });

  test('a card keeps its type and its server map verbatim', () {
    const card = ThreadCard(type: 'list', data: {'type': 'list', 'title': 'Groceries'});
    expect(card.type, 'list');
    expect(card.data['title'], 'Groceries');
    expect(ThreadCard.knownTypes, {
      'weather', 'agenda', 'list', 'reminders', 'email', //
      'tracker', 'tracker_logged', 'recipe', 'cook_step',
    });
  });

  test('the tool chip reads like the audio bridge, then resolves', () {
    expect(const ThreadToolChip(name: 'get_weather').text,
        '⚙ checking the weather…');
    expect(const ThreadToolChip(name: 'get_weather', resolved: true).text,
        '⚙ checking the weather ✓');
    expect(const ThreadToolChip(name: 'get_weather').resolve().resolved, isTrue);
  });

  test('metrics render one decimal and drop null halves', () {
    expect(const ThreadMetrics(ttfaMs: 555, ttbMs: 3400).text, 'audio 0.6s · brain 3.4s');
    expect(const ThreadMetrics(ttfaMs: 1145).text, 'audio 1.1s');
    expect(const ThreadMetrics(ttbMs: 2000).text, 'brain 2.0s');
    expect(const ThreadMetrics().text, '');
  });

  test('every source the server can emit maps to a LineKind', () {
    // conversation.ex: speak_start sources + the history backfill.
    expect(lineKindFromSource('brain'), LineKind.brain);
    expect(lineKindFromSource('reflex'), LineKind.reflex);
    expect(lineKindFromSource('reminder'), LineKind.reminder);
    expect(lineKindFromSource('briefing'), LineKind.briefing);
    expect(lineKindFromSource('followup'), LineKind.followup);
    expect(lineKindFromSource('you'), LineKind.you);
    expect(lineKindFromSource('timer'), LineKind.timer);
    expect(lineKindFromSource('message'), LineKind.message);
    expect(lineKindFromSource('heads_up'), LineKind.headsUp);
    expect(lineKindFromSource('news'), LineKind.news);
    expect(lineKindFromSource('something_new'), isNull,
        reason: 'an unknown source must be droppable, not rendered as a guess');
  });

  test('copyWith carries the untouched fields through', () {
    const line = ThreadLine(
      kind: LineKind.brain,
      label: 'Henry',
      text: 'partial',
      thinking: true,
      ackId: 7,
    );
    final done = line.copyWith(text: 'complete', markdown: true);
    expect(done.text, 'complete');
    expect(done.markdown, isTrue);
    expect(done.kind, LineKind.brain);
    expect(done.label, 'Henry');
    expect(done.thinking, isTrue);
    expect(done.ackId, 7, reason: 'a delta must not drop the pending ack');
  });
}
