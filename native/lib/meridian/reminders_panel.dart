import 'package:flutter/material.dart';

import '../panels/reminders_client.dart';
import 'hero_icon.dart';
import 'tokens.dart';

/// The Reminders drawer's contents — the port of `reminders_panel/1`:
/// a "Needs your attention" section (only when something is due) above
/// "Upcoming", each row carrying its badges, body, due label and controls.
class RemindersPanelView extends StatelessWidget {
  const RemindersPanelView({super.key, required this.client});

  final RemindersClient client;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: client,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (client.due.isNotEmpty) ...[
              const _SectionLabel('Needs your attention'),
              for (var i = 0; i < client.due.length; i++)
                _Row(
                  row: client.due[i],
                  due: true,
                  isFirst: i == 0,
                  onAck: () => client.ack(client.due[i].id),
                  onDismiss: () => client.dismiss(client.due[i].id),
                ),
              const SizedBox(height: 12), // space-y-3 between the two sections
            ],
            const _SectionLabel('Upcoming'),
            if (client.upcoming.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  'Nothing scheduled.',
                  style: TextStyle(
                    fontSize: 14,
                    color: M.ink.withValues(alpha: 0.5),
                  ),
                ),
              ),
            for (var i = 0; i < client.upcoming.length; i++)
              _Row(
                row: client.upcoming[i],
                isFirst: i == 0,
                onDismiss: () => client.dismiss(client.upcoming[i].id),
              ),
          ],
        ),
      );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12, // text-xs
            color: M.ink.withValues(alpha: 0.6), // opacity-60
          ),
        ),
      );
}

/// One reminder. `due` adds the amber "due" badge and the ack control; the
/// dismiss ✕ is on every row, and on a recurring one it cancels the series —
/// the row IS the series, same as the web.
class _Row extends StatelessWidget {
  const _Row({
    required this.row,
    required this.onDismiss,
    this.due = false,
    this.onAck,
    this.isFirst = false,
  });

  final ReminderRow row;
  final bool due;
  final VoidCallback? onAck;
  final VoidCallback onDismiss;

  /// Whether this is the first row in its section. Mirrors the web's
  /// `<ul class="space-y-1">`, which puts margin-top only BEFORE items after
  /// the first — the first row's gap above it comes entirely from the
  /// section label's own bottom padding (4px), so this row must add none of
  /// its own or the two would stack to 8px where the web has 4px.
  final bool isFirst;

  @override
  Widget build(BuildContext context) => Padding(
        // gap-y-1 = 0.25rem = 4px, applied only above non-first rows — see
        // isFirst's doc.
        padding: EdgeInsets.only(top: isFirst ? 0 : 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (due) const _Badge('due', tint: M.you),
            if (row.isFollowup) const _Badge('follow-up'),
            if (row.household) const _Badge('shared', tint: M.henry),
            if (row.recurrenceLabel != null)
              _Badge(row.recurrenceLabel!, tint: M.briefing),
            Expanded(
              child: Text(
                row.body,
                style: const TextStyle(fontSize: 14, color: M.ink),
              ),
            ),
            const SizedBox(width: 8), // gap-2 = 0.5rem = 8px
            Text(
              row.dueLabel,
              style: TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                color: M.ink.withValues(alpha: 0.6),
              ),
            ),
            if (onAck != null)
              _IconButton(
                key: ValueKey('ack-${row.id}'),
                icon: HeroIcon.check,
                tooltip: 'acknowledge reminder',
                onTap: onAck!,
              ),
            _IconButton(
              key: ValueKey('dismiss-${row.id}'),
              icon: HeroIcon.xMark,
              tooltip: row.recurrenceLabel != null
                  ? 'cancel repeating reminder'
                  : 'delete reminder',
              onTap: onDismiss,
            ),
          ],
        ),
      );
}

/// The web's `badge badge-sm`, in Meridian's pill recipe (the same one the
/// transcript's ack chip uses).
class _Badge extends StatelessWidget {
  const _Badge(this.text, {this.tint});

  final String text;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final c = tint ?? M.chromeDim;
    return Padding(
      padding: const EdgeInsets.only(right: 8), // gap-2 = 0.5rem = 8px
      child: Container(
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
      ),
    );
  }
}

class _IconButton extends StatelessWidget {
  const _IconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final HeroIcon icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: HeroIconView(icon, size: 16, color: M.inkDim),
          ),
        ),
      );
}
