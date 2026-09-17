import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/connection/app_connection.dart';
import 'package:orbital_pai/meridian/thread_model.dart';
import 'package:orbital_pai/meridian/tokens.dart';
import 'package:orbital_pai/phoenix/decoded_message.dart';
import 'package:orbital_pai/voice/voice_controller.dart';

import 'support/fakes.dart';

DecodedMessage msg(String event, Map<String, dynamic> json) =>
    DecodedMessage(topic: 'voice:henry', event: event, json: json);

void main() {
  late AppConnection conn;
  late VoiceController vc;

  setUp(() {
    // Never connected: these tests drive the router directly through
    // debugHandleMessage, so no socket is needed.
    conn = AppConnection(connector: () async => throw StateError('no socket'));
    vc = VoiceController(connection: conn, mic: FakeMic(), player: FakePlayer());
  });
  tearDown(() {
    vc.dispose();
    conn.dispose();
  });

  test('connStatus maps ConnState onto the header dot', () {
    expect(conn.connStatus, ConnStatus.connecting); // ConnState.idle
    vc.debugHandleMessage(msg('noop', const {}));
    expect(conn.connStatus, ConnStatus.connecting);
  });

  test('a transcript becomes a `you` line and clears the caption', () {
    vc.debugHandleMessage(msg('partial', const {'text': 'what is th'}));
    expect(vc.caption, 'what is th');
    vc.debugHandleMessage(msg('transcript', const {'text': 'what is the weather'}));
    expect(vc.caption, '');
    final line = vc.thread.single as ThreadLine;
    expect(line.kind, LineKind.you);
    expect(line.label, 'you');
    expect(line.text, 'what is the weather');
    expect(line.markdown, isFalse, reason: 'your own words are never markdown');
  });

  test('history backfills once, then adds the — earlier — divider', () {
    vc.debugHandleMessage(msg('history', const {
      'turns': [
        {'you': 'hi', 'assistant': 'hello'},
      ],
    }));
    expect(vc.thread, hasLength(3));
    expect(vc.thread.last, isA<ThreadDivider>());

    // A rebind re-pushes history; it must not duplicate.
    vc.debugHandleMessage(msg('history', const {
      'turns': [
        {'you': 'hi', 'assistant': 'hello'},
      ],
    }));
    expect(vc.thread, hasLength(3));
  });

  test('a claim (replace: true) rebuilds the thread instead of appending to it', () {
    // The device already has its own turn events on screen (not a backfill) —
    // a claim's replace-history must still win, clearing this first.
    vc.debugHandleMessage(msg('transcript', const {'text': 'leftover from before the claim'}));
    expect(vc.thread, hasLength(1));

    vc.debugHandleMessage(msg('history', const {
      'turns': [
        {'you': 'hi', 'assistant': 'hello'},
      ],
      'replace': true,
    }));

    expect(vc.thread, hasLength(3), reason: 'you + assistant + the — earlier — divider');
    expect((vc.thread[0] as ThreadLine).text, 'hi');
    expect((vc.thread[1] as ThreadLine).text, 'hello');
    expect(vc.thread.last, isA<ThreadDivider>());
  });

  test('a replace history leaves the one-shot guard set, so a later plain rebind cannot duplicate',
      () {
    vc.debugHandleMessage(msg('history', const {
      'turns': [
        {'you': 'hi', 'assistant': 'hello'},
      ],
      'replace': true,
    }));
    expect(vc.thread, hasLength(3));

    // Empty the thread the way the local trash button does, so the plain push below is only
    // blocked by the `_historyBackfilled` flag itself — not incidentally by `_thread.isEmpty`
    // still being false from the replace above.
    vc.clearThread();
    expect(vc.thread, isEmpty);

    // A later plain (unflagged) history push — e.g. a stray rebind — must not repopulate.
    vc.debugHandleMessage(msg('history', const {
      'turns': [
        {'you': 'hi', 'assistant': 'hello'},
      ],
    }));
    expect(vc.thread, isEmpty);
  });

  test('a replace arriving with an already-populated thread ends with exactly the payload, no leftovers',
      () {
    vc.debugHandleMessage(msg('history', const {
      'turns': [
        {'you': 'old q1', 'assistant': 'old a1'},
        {'you': 'old q2', 'assistant': 'old a2'},
      ],
    }));
    expect(vc.thread, hasLength(5));

    vc.debugHandleMessage(msg('history', const {
      'turns': [
        {'you': 'new q', 'assistant': 'new a'},
      ],
      'replace': true,
    }));

    expect(vc.thread, hasLength(3));
    expect((vc.thread[0] as ThreadLine).text, 'new q');
    expect((vc.thread[1] as ThreadLine).text, 'new a');
    expect(vc.thread.last, isA<ThreadDivider>());
  });

  test('a replace with an empty turns list is a no-op — it leaves the on-screen thread alone', () {
    // history/1 can legitimately come back [] on a claim (a fresh session, or the accepted
    // persist-race where the last turn hasn't landed in the DB yet). Wiping the claiming
    // device's own conversation over that would be worse than leaving it slightly stale.
    vc.debugHandleMessage(msg('transcript', const {'text': 'still here'}));
    expect(vc.thread, hasLength(1));

    vc.debugHandleMessage(msg('history', const {'turns': [], 'replace': true}));

    expect(vc.thread, hasLength(1));
    expect((vc.thread.single as ThreadLine).text, 'still here');
  });

  test('brain deltas stream into ONE plaintext line, then snap to markdown', () {
    vc.debugHandleMessage(msg('thinking', const {}));
    expect(vc.thread.single, isA<ThreadLine>());
    expect((vc.thread.single as ThreadLine).thinking, isTrue);

    vc.debugHandleMessage(msg('brain_delta', const {'delta': '- milk'}));
    vc.debugHandleMessage(msg('brain_delta', const {'delta': '\n- eggs'}));
    expect(vc.thread, hasLength(1),
        reason: 'the first delta replaces the thinking line');
    var line = vc.thread.single as ThreadLine;
    expect(line.text, '- milk\n- eggs');
    expect(line.markdown, isFalse, reason: 'a half-open ** must not flicker mid-stream');

    vc.debugHandleMessage(
        msg('speak_start', const {'source': 'brain', 'text': '- milk\n- eggs'}));
    line = vc.thread.single as ThreadLine;
    expect(line.markdown, isTrue);
    expect(line.label, VoiceController.assistantName);
  });

  test('a brain answer with no deltas still lands as one markdown line', () {
    // The batch path: speak_start arrives without any brain_delta first.
    vc.debugHandleMessage(msg('thinking', const {}));
    vc.debugHandleMessage(
        msg('speak_start', const {'source': 'brain', 'text': 'sunny'}));
    expect(vc.thread, hasLength(1), reason: 'the thinking placeholder is replaced');
    final line = vc.thread.single as ThreadLine;
    expect(line.text, 'sunny');
    expect(line.markdown, isTrue);
    expect(line.thinking, isFalse);
  });

  test('tool chips resolve when the answer starts and vanish on listening', () {
    vc.debugHandleMessage(msg('tool_call', const {'name': 'get_weather'}));
    vc.debugHandleMessage(msg('tool_call', const {'name': 'unknown_tool'}));
    expect(vc.thread.whereType<ThreadToolChip>(), hasLength(2));

    vc.debugHandleMessage(msg('brain_delta', const {'delta': 'sunny'}));
    expect(vc.thread.whereType<ThreadToolChip>().every((c) => c.resolved), isTrue);

    vc.debugHandleMessage(msg('tool_call', const {'name': 'send_email'}));
    vc.debugHandleMessage(msg('listening', const {}));
    final chips = vc.thread.whereType<ThreadToolChip>().toList();
    expect(chips, hasLength(2),
        reason: "resolved chips stay as the turn's story; unresolved ones are dropped");
  });

  test('dropping a chip keeps the brain line handle pointing at the right line', () {
    // The index-shifting hazard: a chip removed from BEFORE the live brain line
    // must slide _brainIndex down with it, or the next delta appends to the
    // wrong item (or throws).
    vc.debugHandleMessage(msg('tool_call', const {'name': 'get_weather'}));
    vc.debugHandleMessage(msg('brain_delta', const {'delta': 'it is '}));
    vc.debugHandleMessage(msg('tool_call', const {'name': 'send_email'}));
    vc.debugHandleMessage(msg('listening', const {}));

    // _endTurn dropped the unresolved chip; the resolved one and the line remain.
    expect(vc.thread.whereType<ThreadLine>().single.text, 'it is ');
    expect(vc.thread.whereType<ThreadToolChip>(), hasLength(1));
  });

  test('a removed line slides the other turn handles down with it', () {
    // The chip test above removes an item AFTER the brain line, so it never
    // exercises the shift. Here the thinking line is removed from BEFORE the
    // metrics handle: without the fix-up, _metricsIndex and _brainIndex both end
    // up pointing at index 1 and the next metrics event overwrites the answer.
    vc.debugHandleMessage(msg('thinking', const {}));
    vc.debugHandleMessage(msg('metrics', const {'ttfa': 555}));
    vc.debugHandleMessage(msg('brain_delta', const {'delta': 'sunny'}));
    vc.debugHandleMessage(msg('metrics', const {'ttfa': 555, 'ttb': 3400}));

    expect(vc.thread.whereType<ThreadMetrics>(), hasLength(1));
    expect(vc.thread.whereType<ThreadLine>().single.text, 'sunny',
        reason: 'a stale handle would overwrite the answer with the metrics line');
  });

  test('metrics update one line in place', () {
    vc.debugHandleMessage(msg('metrics', const {'ttfa': 555, 'ttb': null}));
    expect(vc.thread.whereType<ThreadMetrics>(), hasLength(1));
    vc.debugHandleMessage(msg('metrics', const {'ttfa': 555, 'ttb': 3400}));
    expect(vc.thread.whereType<ThreadMetrics>(), hasLength(1));
    expect(vc.thread.whereType<ThreadMetrics>().single.text, '⚡ 0.6s · 🧠 3.4s');
  });

  test('an ack offer attaches to the last reminder line', () {
    vc.debugHandleMessage(
        msg('speak_start', const {'source': 'reminder', 'text': 'bins out'}));
    vc.debugHandleMessage(msg('reminder_ack_offer', const {'id': 42}));
    final line = vc.thread.whereType<ThreadLine>().last;
    expect(line.ack, AckState.offered);
    expect(line.ackId, 42);

    vc.ackReminder(42);
    expect(vc.thread.whereType<ThreadLine>().last.ack, AckState.acked);
  });

  test('an unknown speak_start source is dropped, not guessed at', () {
    vc.debugHandleMessage(
        msg('speak_start', const {'source': 'telepathy', 'text': 'hi'}));
    expect(vc.thread, isEmpty);
    expect(vc.eventLog.any((l) => l.contains('unknown speak_start source')), isTrue);
  });

  test('a wake lock writes the canned caption', () {
    vc.debugHandleMessage(msg('locked', const {'locked': true}));
    expect(vc.caption, 'Say “Wake up ${VoiceController.assistantName}”');
    vc.debugHandleMessage(msg('locked', const {'locked': false}));
    expect(vc.caption, '');
  });

  test('a partial that never finalises is cleared at end of turn', () {
    // `transcript` clears the caption, but not every partial reaches one — a
    // barge-in, or an endpoint the server resolves another way, strands it.
    // It used to be invisible; the orb's line is taller now and the caption box
    // overlaps it during `thinking`, so stale words sit under the wave.
    vc.debugHandleMessage(msg('partial', const {'text': 'what is th'}));
    expect(vc.caption, 'what is th');
    vc.debugHandleMessage(msg('listening', const {}));
    expect(vc.caption, '');
  });

  test('ending a turn while wake-locked leaves the prompt, not a blank', () {
    // Locked is not a turn state. Blanking here would strand a locked device
    // with no on-screen clue about the words that unlock it.
    vc.debugHandleMessage(msg('locked', const {'locked': true}));
    vc.debugHandleMessage(msg('partial', const {'text': 'stray words'}));
    vc.debugHandleMessage(msg('listening', const {}));
    expect(vc.caption, 'Say “Wake up ${VoiceController.assistantName}”');
  });

  group('captionPending — the trailing ellipsis', () {
    // Ink-2 never revises text it has already sent, so it withholds the
    // trailing word or two until they are unrevisable and dumps the tail on
    // `turn.end`. Nothing here can change that; the flag exists so the UI can
    // SAY the tail is still coming. Which means the one thing it must never do
    // is claim words are pending when none are.

    test('a live partial is pending', () {
      vc.debugHandleMessage(msg('partial', const {'text': 'what is th'}));
      expect(vc.captionPending, isTrue);
    });

    test('the resting wake prompt is NOT pending', () {
      // The whole reason this is keyed on provenance and not on a turn phase.
      // A wake-locked device sits in `listening` indefinitely showing a prompt
      // that is waiting on nothing — dots there would be a lie that never
      // resolves.
      vc.debugHandleMessage(msg('locked', const {'locked': true}));
      expect(vc.caption, 'Say \u201CWake up ${VoiceController.assistantName}\u201D');
      expect(vc.captionPending, isFalse);
    });

    test('a stranded partial stops being pending at end of turn', () {
      vc.debugHandleMessage(msg('partial', const {'text': 'what is th'}));
      vc.debugHandleMessage(msg('listening', const {}));
      expect(vc.captionPending, isFalse);
    });

    test('a partial that resolves to a transcript stops being pending', () {
      vc.debugHandleMessage(msg('partial', const {'text': 'what is th'}));
      vc.debugHandleMessage(msg('transcript', const {'text': 'what is the weather'}));
      expect(vc.captionPending, isFalse);
    });

    test('a wake-locked partial that strands falls back to an unpending prompt', () {
      vc.debugHandleMessage(msg('locked', const {'locked': true}));
      vc.debugHandleMessage(msg('partial', const {'text': 'stray words'}));
      vc.debugHandleMessage(msg('listening', const {}));
      expect(vc.caption, 'Say \u201CWake up ${VoiceController.assistantName}\u201D');
      expect(vc.captionPending, isFalse);
    });

    test('an empty partial is not pending — there is no tail to be waiting on', () {
      vc.debugHandleMessage(msg('partial', const {'text': ''}));
      expect(vc.caption, '');
      expect(vc.captionPending, isFalse);
    });
  });

  test('clearThread() empties the log and its turn handles', () {
    vc.debugHandleMessage(msg('transcript', const {'text': 'hi'}));
    vc.debugHandleMessage(msg('brain_delta', const {'delta': 'hello'}));
    vc.clearThread();
    expect(vc.thread, isEmpty);
    vc.debugHandleMessage(msg('brain_delta', const {'delta': 'again'}));
    expect(vc.thread, hasLength(1), reason: 'the live brain handle must be dropped too');
  });

  test('PTT press/release drive the turn state without a socket', () {
    vc.debugSetTalking(true);
    vc.setPtt(true);
    expect(vc.pttEnabled, isTrue);
    vc.pttPress();
    expect(vc.pttHeld, isTrue);
    expect(vc.turnState.name, 'listening');
    vc.pttRelease();
    expect(vc.pttHeld, isFalse);
    expect(vc.turnState.name, 'idle');
  });

  test('pttPress does nothing while PTT mode is off', () {
    vc.debugSetTalking(true);
    vc.pttPress();
    expect(vc.pttHeld, isFalse, reason: 'the hold bar is inert until PTT is armed');
    expect(vc.turnState.name, 'idle');
  });

  test('ABI is remembered locally so a rejoin can re-announce it', () {
    expect(vc.abiEnabled, isFalse);
    vc.setAllowInterruptions(true);
    expect(vc.abiEnabled, isTrue);
  });

  test('a brain that finishes before the reflex is spoken renders its answer ONCE', () {
    // The prod sequence (conversation.ex + policy.ex), reconstructed:
    //
    //   endpoint            -> phase :awaiting_reflex, reflex + brain start together
    //   {:brain_text, _}    -> HELD in caption_buffer (reflex_sent == false), nothing pushed
    //   {:brain_done, text} -> conversation.ex:723 pushes speak_start(brain) RIGHT NOW, because
    //                          its only guard is `phase != :listening`; Policy (policy.ex:82)
    //                          just records brain_done and leaves the phase alone
    //   {:reflex_ready, _}  -> speak_reflex -> speak_start(reflex)  << the LATE reflex
    //   reflex first audio  -> metrics(ttfa), then feed(:reflex_sent) -> :draining
    //   :flush_brain        -> pushes the WHOLE held caption_buffer as one brain_delta
    //                          -> the same answer a second time
    //   brain first audio   -> metrics(ttfa, ttb), updated in place
    //
    // ttfa == ttb in the report's screenshot precisely because the brain audio is flushed in
    // the same breath as the reflex's first chunk.
    const answer =
        "Appreciate the thought. Systems are humming along fine, so I'm good to go whenever you are.";

    vc.debugHandleMessage(msg('transcript', const {'text': 'hope you are doing well'}));
    // brain_done beats the reflex: the final answer is pushed before the filler.
    vc.debugHandleMessage(msg('speak_start', const {'source': 'brain', 'text': answer}));
    vc.debugHandleMessage(
        msg('speak_start', const {'source': 'reflex', 'text': '...Touching.'}));
    vc.debugHandleMessage(msg('metrics', const {'ttfa': 4100, 'ttb': null}));
    // :flush_brain releases the held caption — the identical text, a second time.
    vc.debugHandleMessage(msg('brain_delta', const {'delta': answer}));
    vc.debugHandleMessage(msg('metrics', const {'ttfa': 4100, 'ttb': 4100}));

    final brainLines = vc.thread
        .whereType<ThreadLine>()
        .where((l) => l.kind == LineKind.brain)
        .toList();
    expect(brainLines, hasLength(1),
        reason: 'the answer is posted twice: once by speak_start, once by the flushed caption');
    expect(brainLines.single.text, answer);
  });

  test('a delta after the answer is finalized is ignored; the next turn still streams', () {
    // Idempotency in its own right, not tolerance: a finalized brain line is the turn's last
    // word, so a delta arriving after it must neither extend that line nor open another —
    // whichever order the two messages happen to arrive in.
    vc.debugHandleMessage(msg('brain_delta', const {'delta': 'it is '}));
    vc.debugHandleMessage(msg('brain_delta', const {'delta': 'sunny'}));
    vc.debugHandleMessage(
        msg('speak_start', const {'source': 'brain', 'text': 'It is **sunny**.'}));
    vc.debugHandleMessage(msg('brain_delta', const {'delta': 'it is sunny'}));

    final line = vc.thread.whereType<ThreadLine>().single;
    expect(line.text, 'It is **sunny**.', reason: 'the finalized text is not appended to');
    expect(line.markdown, isTrue);

    // The guard is turn-scoped: end the turn and the live caption works as it always did.
    vc.debugHandleMessage(msg('listening', const {}));
    vc.debugHandleMessage(msg('brain_delta', const {'delta': 'next turn'}));
    final lines = vc.thread.whereType<ThreadLine>().toList();
    expect(lines, hasLength(2));
    expect(lines.last.text, 'next turn');
  });
}
