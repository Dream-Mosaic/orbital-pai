import 'package:flutter/material.dart';

import '../tokens.dart';
import 'card_frame.dart';

/// `list_reminders` / `create_reminder` / `create_followup`: what, when, how
/// often, and for whom — each row the task first, its timing under it.
class RemindersCard extends StatelessWidget {
  const RemindersCard({super.key, required this.data});

  final Map<String, dynamic> data;

  static const Color accent = M.followup;

  @override
  Widget build(BuildContext context) {
    final items = data.rows('items');
    return CardFrame(
      accent: accent,
      label: data.str('title') ?? '',
      footerTrailing: data.str('more'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var n = 0; n < items.length; n++) ...[
            if (n > 0) const CardRule(vertical: 6.5),
            _item(items[n]),
          ],
        ],
      ),
    );
  }

  Widget _item(Map<String, dynamic> r) {
    final when = r.str('when');
    final cadence = r.str('cadence');
    final tag = r.str('tag');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          r.str('text') ?? '',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: CardStyle.body(12.5, colour: M.brainBody, weight: 460),
        ),
        const SizedBox(height: 3.5),
        Wrap(
          spacing: 7,
          runSpacing: 3,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (when != null)
              Text(
                when,
                style: CardStyle.numeral(10.4, colour: accent.withValues(alpha: 0.95), weight: 540),
              ),
            if (cadence != null) Text(cadence, style: CardStyle.meta(10.2)),
            if (tag != null) CardTag(tag, colour: M.chromeDim),
          ],
        ),
      ],
    );
  }
}
