import 'dart:async';

import 'package:flutter/widgets.dart';

import '../voice/timers_model.dart';
import 'notifier.dart';

/// Turns what arrives on `voice:henry` while nobody is looking at the app into
/// local notifications — a timer going off, a household message, a reminder, a
/// calendar heads-up, a follow-up.
///
/// **Only while the app is not resumed.** In front, the thread and the orb
/// already show all of it, and a notification on top would be the same thing
/// twice. Coming back to the app cancels every notification this posted: the
/// thread now shows them. `inactive` and `hidden` count as away, like `paused`
/// (the shade pulled down, the app switcher open).
///
/// **The live socket only.** This is not push: a socket the OS has frozen or
/// killed delivers nothing, so nothing is posted (FCM and a foreground service
/// are their own pieces of work, #15/#18).
///
/// Fed by [VoiceController] (`onEvent` for every JSON push, [timerDismissed]
/// for a tap on a ringing chip); owned and disposed by the shell in `main.dart`.
class BackgroundNotices with WidgetsBindingObserver {
  /// [binding] is observed for lifecycle changes until [dispose]; null (tests)
  /// observes nothing and starts in front — drive it with
  /// [didChangeAppLifecycleState] directly.
  BackgroundNotices({
    required Notifier notifier,
    WidgetsBinding? binding,
    this.pairWindow = const Duration(seconds: 3),
  })  : _notifier = notifier,
        _binding = binding {
    final b = binding;
    if (b != null) {
      // Null before the first frame: the app is coming up in front.
      final state = b.lifecycleState;
      _foreground = state == null || state == AppLifecycleState.resumed;
      b.addObserver(this);
    }
  }

  final Notifier _notifier;
  final WidgetsBinding? _binding;

  /// How long a lead waits for the line that completes it. A canned body (a
  /// message, a heads-up) follows its lead within a TTS round trip; a reminder's
  /// brain answer can take longer, and then the lead goes alone and the answer,
  /// when it lands, replaces it in place (see [_late]).
  final Duration pairWindow;

  bool _foreground = true;
  bool _disposed = false;

  /// Whether the app is in front (resumed). Nothing is posted while it is.
  bool get foreground => _foreground;

  /// A lead that is waiting for its body.
  _Lead? _pending;
  Timer? _pairTimer;

  /// A lead that already went out ALONE (the window closed first), still open
  /// to the answer it was waiting for until the turn ends.
  _Lead? _late;

  /// Agenda notification ids. Timers use their own range ([_timerNoticeId]).
  int _nextId = 1;

  /// Every timer id seen ringing, in front or not — "once per timer id", and a
  /// timer the user already watched ring in the app is not announced again when
  /// they leave it. Bounded like TimersModel's: ids that left the list go.
  final Set<int> _rang = <int>{};

  /// Timer ids with a notification up.
  final Set<int> _notifiedTimers = <int>{};

  static const Map<String, String> _leadTitles = {
    'message': 'Message',
    'reminder': 'Reminder',
    'heads_up': 'Heads up',
    'followup': 'Follow-up',
  };

  /// One JSON push from `voice:henry`, as it arrived.
  void onEvent(String event, Map<String, dynamic> payload) {
    if (_disposed) return;
    switch (event) {
      case 'speak_start':
        final source = (payload['source'] as String?) ?? 'brain';
        final text = (payload['text'] as String?) ?? '';
        if (source == 'brain') {
          _onBody(text);
        } else {
          _onLead(source, text);
        }
      case 'listening':
        // The turn is over: whatever brain line comes next is a new turn's.
        _late = null;
      case 'timers':
        _onTimers(payload);
    }
  }

  /// The user stopped timer [id] in the app.
  void timerDismissed(int id) {
    if (_disposed) return;
    if (_notifiedTimers.remove(id)) unawaited(_notifier.cancel(_timerNoticeId(id)));
  }

  /// Ask for the notification permission (once per install; the platform side
  /// remembers). A "no" just means no notifications.
  Future<bool> requestPermission() => _notifier.requestPermission();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    final front = state == AppLifecycleState.resumed;
    if (front == _foreground) return;
    _foreground = front;
    if (front) {
      _dropPairing();
      _notifiedTimers.clear();
      unawaited(_notifier.cancelAll());
    }
  }

  void _onLead(String source, String text) {
    // Any other speaker means the previous lead's body is not coming.
    _flushPending();
    _late = null;
    final title = _leadTitles[source];
    if (title == null || _foreground) return;
    _pending = _Lead(
      id: _takeId(),
      title: source == 'message' ? _messageTitle(text) : title,
      lead: source == 'message' ? '' : _cleanLead(text),
      channel: source == 'message' ? NoticeChannel.messages : NoticeChannel.alerts,
    );
    _pairTimer = Timer(pairWindow, _flushPending);
  }

  void _onBody(String text) {
    final lead = _pending ?? _late;
    _pairTimer?.cancel();
    _pairTimer = null;
    _pending = null;
    _late = null;
    if (lead == null || _foreground) return;
    final body = plainText(text);
    _post(lead, body.isEmpty ? lead.lead : body);
  }

  /// Post the waiting lead without a body, and keep it open to a late one.
  void _flushPending() {
    _pairTimer?.cancel();
    _pairTimer = null;
    final lead = _pending;
    _pending = null;
    if (lead == null || _foreground) return;
    _post(lead, lead.lead);
    _late = lead;
  }

  void _dropPairing() {
    _pairTimer?.cancel();
    _pairTimer = null;
    _pending = null;
    _late = null;
  }

  void _post(_Lead lead, String body) => unawaited(_notifier.show(
        id: lead.id,
        title: lead.title,
        body: body,
        channel: lead.channel,
      ));

  int _takeId() {
    final id = _nextId;
    _nextId = _nextId >= _timerIdBase - 1 ? 1 : _nextId + 1;
    return id;
  }

  void _onTimers(Map<String, dynamic> payload) {
    final raw = payload['timers'];
    final entries = <TimerEntry?>[
      if (raw is List)
        for (final m in raw)
          if (m is Map) TimerEntry.fromWire(m.cast<String, dynamic>(), Duration.zero),
    ].whereType<TimerEntry>().toList();
    final present = {for (final t in entries) t.id};
    final ringing = {for (final t in entries) if (t.ringing) t.id};

    // Dismissed on another device, or settled by the server: take it down.
    for (final id in _notifiedTimers.difference(ringing).toList()) {
      _notifiedTimers.remove(id);
      unawaited(_notifier.cancel(_timerNoticeId(id)));
    }
    _rang.retainAll(present);

    for (final t in entries) {
      if (!t.ringing || _rang.contains(t.id)) continue;
      _rang.add(t.id);
      if (_foreground) continue;
      _notifiedTimers.add(t.id);
      unawaited(_notifier.show(
        id: _timerNoticeId(t.id),
        title: "Timer's done",
        body: timerNoticeBody(t),
        channel: NoticeChannel.alerts,
      ));
    }
  }

  /// Stop observing, drop any half-paired lead and take down everything this
  /// posted — a sign-out must not leave the last user's messages in the shade.
  void dispose() {
    if (_disposed) return;
    _dropPairing();
    _binding?.removeObserver(this);
    _disposed = true;
    unawaited(_notifier.cancelAll());
  }
}

class _Lead {
  const _Lead({
    required this.id,
    required this.title,
    required this.lead,
    required this.channel,
  });

  final int id;
  final String title;

  /// The body to use when no line completes it ('' for a message: its title
  /// already says everything the lead did).
  final String lead;
  final NoticeChannel channel;
}

/// Timers get the top of the 31-bit id space, agenda notices the bottom.
const int _timerIdBase = 0x40000000;
int _timerNoticeId(int timerId) => _timerIdBase | (timerId & (_timerIdBase - 1));

/// "Message from David —" / "Oh — a message from David —" → "Message from David".
String _messageTitle(String lead) {
  final m = RegExp(r'message from (.+?)[\s—–-]*$', caseSensitive: false).firstMatch(lead);
  final from = m?.group(1)?.trim();
  return (from == null || from.isEmpty) ? 'Message' : 'Message from $from';
}

/// "Quick one —" → "Quick one": a spoken lead trails off into its body.
String _cleanLead(String lead) => lead.replaceAll(RegExp(r'[\s—–-]+$'), '').trim();

/// The same words the server speaks for a timer going off (`App.Timers`'s
/// spoken notice): "Your pasta timer is up." / "Your 10-minute timer is up."
@visibleForTesting
String timerNoticeBody(TimerEntry t) {
  final label = t.label?.trim();
  if (label != null && label.isNotEmpty) {
    return RegExp(r'\btimer$').hasMatch(label.toLowerCase())
        ? 'Your $label is up.'
        : 'Your $label timer is up.';
  }
  final s = t.duration.inSeconds;
  final parts = <(int, String)>[(s ~/ 3600, 'hour'), ((s % 3600) ~/ 60, 'minute'), (s % 60, 'second')]
      .where((p) => p.$1 != 0)
      .toList();
  final phrase = switch (parts) {
    [] => 'short',
    [(final n, final unit)] => '$n-$unit',
    _ => parts.map((p) => '${p.$1} ${p.$2}').join(' '),
  };
  return 'Your $phrase timer is up.';
}

/// A brain answer is markdown; the shade is plain text. Links keep their text,
/// emphasis and code marks go, heading hashes go.
@visibleForTesting
String plainText(String md) => md
    .replaceAllMapped(RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m.group(1) ?? '')
    .replaceAll(RegExp(r'^#{1,6}\s+', multiLine: true), '')
    .replaceAll(RegExp(r'\*\*|__|`|~~'), '')
    .replaceAll(RegExp(r'(?<![\w*])\*(?=\S)|(?<=\S)\*(?![\w*])'), '')
    .trim();
