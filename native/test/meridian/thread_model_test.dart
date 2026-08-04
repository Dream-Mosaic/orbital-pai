import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/meridian/thread_model.dart';

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
    // index.js:578 — name.replace(/_/g, " ")
    expect(toolLabel('some_new_tool'), 'some new tool');
    expect(kToolLabels, hasLength(9));
  });

  test('the tool chip reads like the audio bridge, then resolves', () {
    expect(const ThreadToolChip(name: 'get_weather').text,
        '⚙ checking the weather…');
    expect(const ThreadToolChip(name: 'get_weather', resolved: true).text,
        '⚙ checking the weather ✓');
    expect(const ThreadToolChip(name: 'get_weather').resolve().resolved, isTrue);
  });

  test('metrics render one decimal and drop null halves', () {
    expect(const ThreadMetrics(ttfaMs: 555, ttbMs: 3400).text, '⚡ 0.6s · 🧠 3.4s');
    expect(const ThreadMetrics(ttfaMs: 1145).text, '⚡ 1.1s');
    expect(const ThreadMetrics(ttbMs: 2000).text, '🧠 2.0s');
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
