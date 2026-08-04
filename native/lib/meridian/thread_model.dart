import 'package:flutter/foundation.dart';

/// Friendly labels for the live tool-call chip, ported verbatim from TOOL_LABELS
/// in server/assets/js/voice/index.js:57-67 (keyed by App.Tools registry names).
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
};

String toolLabel(String name) => kToolLabels[name] ?? name.replaceAll('_', ' ');

/// The speakers the server actually emits: `speak_start`'s `source` is one of
/// brain / reflex / reminder / briefing / followup (conversation.ex:544, 552,
/// 1287, 1516 + reflex_source/1), and the history backfill adds `you`.
enum LineKind { you, brain, reflex, reminder, briefing, followup }

LineKind? lineKindFromSource(String source) => switch (source) {
      'you' => LineKind.you,
      'brain' => LineKind.brain,
      'reflex' => LineKind.reflex,
      'reminder' => LineKind.reminder,
      'briefing' => LineKind.briefing,
      'followup' => LineKind.followup,
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

  String get text {
    final parts = <String>[];
    if (ttfaMs != null) parts.add('⚡ ${(ttfaMs! / 1000).toStringAsFixed(1)}s');
    if (ttbMs != null) parts.add('🧠 ${(ttbMs! / 1000).toStringAsFixed(1)}s');
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
