import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/connection/app_connection.dart';
import 'package:orbital_pai/meridian/thread_model.dart';
import 'package:orbital_pai/phoenix/decoded_message.dart';
import 'package:orbital_pai/voice/voice_controller.dart';

import 'support/fakes.dart';

DecodedMessage msg(String event, Map<String, dynamic> json) =>
    DecodedMessage(topic: 'voice:henry', event: event, json: json);

/// Cards survive history replay: each persisted turn carries the cards it
/// showed, and the rebuilt thread puts them where they appeared live — after
/// the question, before the answer.
void main() {
  late AppConnection conn;
  late VoiceController vc;

  setUp(() {
    conn = AppConnection(connector: () async => throw StateError('no socket'));
    vc = VoiceController(connection: conn, mic: FakeMic(), player: FakePlayer());
  });
  tearDown(() {
    vc.dispose();
    conn.dispose();
  });

  const weather = {'type': 'weather', 'temp': '72°', 'location': 'Belleville, IL'};
  const groceries = {
    'type': 'list',
    'title': 'Groceries',
    'items': [
      {'text': 'milk', 'done': false},
    ],
  };

  List<Type> shape() => vc.thread.map((i) => i.runtimeType).toList();

  test('the one-shot backfill puts a turn\'s cards between its question and its answer', () {
    vc.debugHandleMessage(msg('history', const {
      'turns': [
        {
          'you': 'weather?',
          'assistant': 'Sunny, 72.',
          'cards': [weather],
        },
        {'you': 'thanks', 'assistant': 'Any time.'},
      ],
    }));

    expect(shape(), [ThreadLine, ThreadCard, ThreadLine, ThreadLine, ThreadLine, ThreadDivider]);
    expect((vc.thread[0] as ThreadLine).kind, LineKind.you);
    final card = vc.thread[1] as ThreadCard;
    expect(card.type, 'weather');
    expect(card.data['temp'], '72°', reason: 'the card map renders verbatim');
    expect((vc.thread[2] as ThreadLine).kind, LineKind.brain);
    expect((vc.thread[2] as ThreadLine).text, 'Sunny, 72.');
  });

  test('a claim\'s replace history rebuilds the cards in the same place', () {
    vc.debugHandleMessage(msg('transcript', const {'text': 'leftover from before the claim'}));

    vc.debugHandleMessage(msg('history', const {
      'turns': [
        {
          'you': 'weather and groceries?',
          'assistant': 'Sunny; you need milk.',
          'cards': [weather, groceries],
        },
      ],
      'replace': true,
    }));

    expect(shape(), [ThreadLine, ThreadCard, ThreadCard, ThreadLine, ThreadDivider]);
    expect((vc.thread[0] as ThreadLine).text, 'weather and groceries?');
    expect([for (final c in vc.thread.whereType<ThreadCard>()) c.type], ['weather', 'list'],
        reason: 'cards keep the order they were shown in');
    expect((vc.thread[3] as ThreadLine).text, 'Sunny; you need milk.');
  });

  test('history drops unknown or malformed cards, exactly like the live card push', () {
    vc.debugHandleMessage(msg('history', const {
      'turns': [
        {
          'you': 'q',
          'assistant': 'a',
          'cards': [
            {'type': 'hologram', 'x': 1},
            'weather',
            {'no': 'type'},
            groceries,
          ],
        },
        {'you': 'q2', 'assistant': 'a2', 'cards': 'not a list'},
      ],
    }));

    expect(shape(),
        [ThreadLine, ThreadCard, ThreadLine, ThreadLine, ThreadLine, ThreadDivider]);
    expect(vc.thread.whereType<ThreadCard>().single.type, 'list');
  });

  test('a turn without cards replays exactly as before', () {
    vc.debugHandleMessage(msg('history', const {
      'turns': [
        {'you': 'hi', 'assistant': 'hello'},
      ],
    }));

    expect(shape(), [ThreadLine, ThreadLine, ThreadDivider]);
    expect((vc.thread[0] as ThreadLine).text, 'hi');
    expect((vc.thread[1] as ThreadLine).text, 'hello');
  });

  test('the one-shot guard still holds with cards: a rebind cannot duplicate them', () {
    const push = {
      'turns': [
        {
          'you': 'weather?',
          'assistant': 'Sunny.',
          'cards': [weather],
        },
      ],
    };
    vc.debugHandleMessage(msg('history', push));
    vc.debugHandleMessage(msg('history', push));
    expect(vc.thread.whereType<ThreadCard>(), hasLength(1));
  });
}
