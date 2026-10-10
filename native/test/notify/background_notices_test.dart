import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/notify/background_notices.dart';
import 'package:orbital_pai/notify/notifier.dart';

import '../support/fake_notifier.dart';

Map<String, dynamic> speak(String source, String text) => {'source': source, 'text': text};

Map<String, dynamic> timer(
  int id, {
  String state = 'running',
  String? label = 'pasta',
  int durationMs = 600000,
}) =>
    {
      'id': id,
      'label': label,
      'state': state,
      'duration_ms': durationMs,
      'remaining_ms': state == 'ringing' ? 0 : 30000,
    };

Map<String, dynamic> timers(List<Map<String, dynamic>> list) => {'timers': list};

void main() {
  late FakeNotifier notifier;
  late BackgroundNotices notices;

  setUp(() {
    notifier = FakeNotifier();
    notices = BackgroundNotices(notifier: notifier);
    // the start-up clear (its own test below) is not what these tests count
    notifier.cancelAlls = 0;
  });
  tearDown(() => notices.dispose());

  void background() => notices.didChangeAppLifecycleState(AppLifecycleState.paused);
  void foreground() => notices.didChangeAppLifecycleState(AppLifecycleState.resumed);

  group('while the app is in front', () {
    test('nothing is ever posted — the thread already shows it', () {
      notices.onEvent('speak_start', speak('message', 'Message from David —'));
      notices.onEvent('speak_start', speak('brain', "Dinner's ready."));
      notices.onEvent('timers', timers([timer(1, state: 'ringing')]));
      expect(notifier.shown, isEmpty);
    });

    test('a fresh start clears what a killed process left in the shade (ids restart at 1)', () {
      final fresh = FakeNotifier();
      final n = BackgroundNotices(notifier: fresh);
      expect(fresh.cancelAlls, 1);
      n.dispose();
    });

    test('a fresh controller assumes it is in front (no binding to ask)', () {
      expect(notices.foreground, isTrue);
    });
  });

  group('a lead paired with the line after it', () {
    setUp(background);

    test('a household message: "Message from <sender>" over the message text', () {
      notices.onEvent('speak_start', speak('message', 'Message from David —'));
      notices.onEvent('speak_start', speak('brain', "Dinner's ready."));
      expect(notifier.shown, hasLength(1));
      final n = notifier.shown.single;
      expect(n.title, 'Message from David');
      expect(n.body, "Dinner's ready.");
      expect(n.channel, NoticeChannel.messages);
    });

    test('the interjected wording still names the sender', () {
      notices.onEvent('speak_start', speak('message', 'Oh — a message from Tanya —'));
      notices.onEvent('speak_start', speak('brain', 'Running late.'));
      expect(notifier.shown.single.title, 'Message from Tanya');
    });

    test('reminder, heads-up and follow-up titles, all on the alerts channel', () {
      notices.onEvent('speak_start', speak('reminder', 'Quick one —'));
      notices.onEvent('speak_start', speak('brain', 'Take the bins out.'));
      notices.onEvent('listening', const {});
      notices.onEvent('speak_start', speak('heads_up', 'Heads up —'));
      notices.onEvent('speak_start', speak('brain', 'Dentist starts in 10 minutes.'));
      notices.onEvent('listening', const {});
      notices.onEvent('speak_start', speak('followup', 'By the way —'));
      notices.onEvent('speak_start', speak('brain', 'How did the interview go?'));

      expect(notifier.shown.map((n) => n.title), ['Reminder', 'Heads up', 'Follow-up']);
      expect(notifier.shown.map((n) => n.body), [
        'Take the bins out.',
        'Dentist starts in 10 minutes.',
        'How did the interview go?',
      ]);
      expect(notifier.shown.map((n) => n.channel).toSet(), {NoticeChannel.alerts});
      expect(notifier.shown.map((n) => n.id).toSet(), hasLength(3),
          reason: 'each event is its own notification, not one overwriting the last');
    });

    test('markdown in a brain answer is flattened for the shade', () {
      notices.onEvent('speak_start', speak('reminder', 'Heads up —'));
      notices.onEvent('speak_start',
          speak('brain', '**Call** the [vet](https://vet.example) about `Max`.'));
      expect(notifier.shown.single.body, 'Call the vet about Max.');
    });

    test('a brain line with no lead before it posts nothing', () {
      notices.onEvent('speak_start', speak('brain', 'Sure, done.'));
      expect(notifier.shown, isEmpty);
    });

    test('timer, briefing and ordinary turns are not paired leads', () {
      // A timer's own spoken notice is covered by the `timers` push instead —
      // pairing its lead too would post it twice.
      for (final source in ['timer', 'briefing', 'reflex', 'you']) {
        notices.onEvent('speak_start', speak(source, 'whatever —'));
        notices.onEvent('speak_start', speak('brain', 'a line'));
      }
      expect(notifier.shown, isEmpty);
    });
  });

  group('the pairing window', () {
    testWidgets('no body within the window: the lead alone', (tester) async {
      background();
      notices.onEvent('speak_start', speak('reminder', 'Quick one —'));
      await tester.pump(const Duration(milliseconds: 2900));
      expect(notifier.shown, isEmpty);
      await tester.pump(const Duration(milliseconds: 200));
      expect(notifier.shown.single.title, 'Reminder');
      expect(notifier.shown.single.body, 'Quick one');
    });

    testWidgets('a message lead alone carries the sender and no body', (tester) async {
      background();
      notices.onEvent('speak_start', speak('message', 'Message from David —'));
      await tester.pump(const Duration(seconds: 3));
      expect(notifier.shown.single.title, 'Message from David');
      expect(notifier.shown.single.body, '');
    });

    testWidgets('a body that lands late replaces the lead-only notice in place',
        (tester) async {
      background();
      notices.onEvent('speak_start', speak('reminder', 'Heads up, for the house —'));
      await tester.pump(const Duration(seconds: 3));
      notices.onEvent('speak_start', speak('brain', 'The plumber comes at 2.'));
      expect(notifier.shown, hasLength(2));
      expect(notifier.shown[1].id, notifier.shown[0].id);
      expect(notifier.active.values.single.body, 'The plumber comes at 2.');
    });

    testWidgets('the turn ending closes the late window', (tester) async {
      background();
      notices.onEvent('speak_start', speak('reminder', 'Quick one —'));
      await tester.pump(const Duration(seconds: 3));
      notices.onEvent('listening', const {});
      notices.onEvent('speak_start', speak('brain', 'an unrelated answer'));
      expect(notifier.shown, hasLength(1));
      expect(notifier.active.values.single.body, 'Quick one');
    });

    testWidgets('a second lead flushes the first one alone', (tester) async {
      background();
      notices.onEvent('speak_start', speak('reminder', 'Quick one —'));
      notices.onEvent('speak_start', speak('message', 'Message from David —'));
      expect(notifier.shown.single.title, 'Reminder');
      notices.onEvent('speak_start', speak('brain', 'Hi.'));
      expect(notifier.shown.map((n) => n.title), ['Reminder', 'Message from David']);
      expect(notifier.shown.last.body, 'Hi.');
      await tester.pump(const Duration(seconds: 5));
      expect(notifier.shown, hasLength(2), reason: 'no stray timeout repost');
    });
  });

  group('timers', () {
    setUp(background);

    test('running -> ringing posts "Timer\'s done" once per timer id', () {
      notices.onEvent('timers', timers([timer(4)]));
      expect(notifier.shown, isEmpty);
      notices.onEvent('timers', timers([timer(4, state: 'ringing')]));
      notices.onEvent('timers', timers([timer(4, state: 'ringing')]));
      notices.onEvent('timers', timers([timer(4, state: 'ringing'), timer(5)]));
      expect(notifier.shown, hasLength(1));
      expect(notifier.shown.single.title, "Timer's done");
      expect(notifier.shown.single.body, 'Your pasta timer is up.');
      expect(notifier.shown.single.channel, NoticeChannel.alerts);
    });

    test('a second timer ringing gets its own notification', () {
      notices.onEvent('timers', timers([timer(4, state: 'ringing')]));
      notices.onEvent('timers',
          timers([timer(4, state: 'ringing'), timer(5, state: 'ringing', label: 'eggs')]));
      expect(notifier.active, hasLength(2));
      expect(notifier.shown.last.body, 'Your eggs timer is up.');
    });

    test('the spoken wording: a label already ending in "timer", and none', () {
      notices.onEvent('timers', timers([
        timer(1, state: 'ringing', label: 'egg timer'),
        timer(2, state: 'ringing', label: null, durationMs: 600000),
        timer(3, state: 'ringing', label: null, durationMs: 5400000),
        timer(4, state: 'ringing', label: '  ', durationMs: 45000),
      ]));
      expect(notifier.shown.map((n) => n.body), [
        'Your egg timer is up.',
        'Your 10-minute timer is up.',
        'Your 1 hour 30 minute timer is up.',
        'Your 45-second timer is up.',
      ]);
    });

    test('a timer the user already saw ringing in the app is not re-announced', () {
      foreground();
      notices.onEvent('timers', timers([timer(4, state: 'ringing')]));
      background();
      notices.onEvent('timers', timers([timer(4, state: 'ringing'), timer(5)]));
      expect(notifier.shown, isEmpty);
    });

    test('dismissed elsewhere (no longer ringing, or gone) cancels its notification', () {
      notices.onEvent('timers',
          timers([timer(4, state: 'ringing'), timer(5, state: 'ringing')]));
      final ids = notifier.active.keys.toList();
      notices.onEvent('timers', timers([timer(5, state: 'ringing')]));
      expect(notifier.cancelled, [ids[0]]);
      notices.onEvent('timers', timers(const []));
      expect(notifier.cancelled, ids);
      expect(notifier.active, isEmpty);
    });

    test('dismissed in the app cancels its notification', () {
      notices.onEvent('timers', timers([timer(4, state: 'ringing')]));
      notices.timerDismissed(4);
      expect(notifier.active, isEmpty);
      notices.timerDismissed(4);
      expect(notifier.cancelled, hasLength(1), reason: 'nothing left to cancel twice');
    });

    test('timer notification ids never collide with message ids', () {
      notices.onEvent('speak_start', speak('message', 'Message from David —'));
      notices.onEvent('speak_start', speak('brain', 'One.'));
      notices.onEvent('timers', timers([timer(1, state: 'ringing')]));
      expect(notifier.active, hasLength(2));
    });
  });

  group('coming back to the app', () {
    testWidgets('cancels everything and drops a half-paired lead', (tester) async {
      background();
      notices.onEvent('timers', timers([timer(4, state: 'ringing')]));
      notices.onEvent('speak_start', speak('message', 'Message from David —'));
      foreground();
      expect(notifier.cancelAlls, 1);
      expect(notifier.active, isEmpty);
      await tester.pump(const Duration(seconds: 5));
      notices.onEvent('speak_start', speak('brain', "Dinner's ready."));
      expect(notifier.shown, hasLength(1), reason: 'only the timer, from before');
    });

    test('inactive and hidden count as away, like paused', () {
      notices.didChangeAppLifecycleState(AppLifecycleState.inactive);
      expect(notices.foreground, isFalse);
      notices.didChangeAppLifecycleState(AppLifecycleState.hidden);
      expect(notices.foreground, isFalse);
      foreground();
      expect(notices.foreground, isTrue);
    });

    test('going away again does not cancel anything', () {
      background();
      background();
      expect(notifier.cancelAlls, 0);
    });
  });

  group('lifecycle wiring', () {
    testWidgets('observes the binding it was handed, until disposed', (tester) async {
      final mine = BackgroundNotices(notifier: notifier, binding: tester.binding);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(mine.foreground, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(mine.foreground, isTrue);
      mine.dispose();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(mine.foreground, isTrue, reason: 'a disposed observer hears nothing');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });

    testWidgets('dispose cancels what it posted (a sign-out leaves no stale notice)',
        (tester) async {
      final mine = BackgroundNotices(notifier: notifier);
      notifier.cancelAlls = 0; // its start-up clear is tested on its own
      mine.didChangeAppLifecycleState(AppLifecycleState.paused);
      mine.onEvent('speak_start', speak('reminder', 'Quick one —'));
      mine.dispose();
      expect(notifier.cancelAlls, 1);
      await tester.pump(const Duration(seconds: 5));
      expect(notifier.shown, isEmpty, reason: 'the pairing timer died with it');
    });

    test('requestPermission asks the platform', () async {
      expect(await notices.requestPermission(), isTrue);
      expect(notifier.permissionRequests, 1);
    });
  });
}
