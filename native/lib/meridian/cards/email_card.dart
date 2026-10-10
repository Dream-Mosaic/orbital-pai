import 'package:flutter/material.dart';

import '../tokens.dart';
import 'card_frame.dart';

/// `search_email` as an inbox peek: who, when, and the subject under it.
class EmailCard extends StatelessWidget {
  const EmailCard({super.key, required this.data});

  final Map<String, dynamic> data;

  static const Color accent = M.chrome;

  @override
  Widget build(BuildContext context) {
    final rows = data.rows('rows');
    return CardFrame(
      accent: accent,
      label: data.str('title') ?? '',
      trailing: data.str('subtitle'),
      footerTrailing: data.str('more'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var n = 0; n < rows.length; n++) ...[
            if (n > 0) const CardRule(vertical: 6),
            _row(rows[n]),
          ],
        ],
      ),
    );
  }

  Widget _row(Map<String, dynamic> m) {
    final when = m.str('when');
    final account = m.str('account');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                m.str('from') ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: CardStyle.body(12, colour: M.ink.withValues(alpha: 0.94), weight: 560),
              ),
            ),
            if (when != null) ...[
              const SizedBox(width: 8),
              Text(
                when,
                style: CardStyle.numeral(9.8, colour: M.inkDim.withValues(alpha: 0.72), weight: 500),
              ),
            ],
          ],
        ),
        const SizedBox(height: 2),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                m.str('subject') ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: CardStyle.body(11, colour: M.inkDim.withValues(alpha: 0.9)),
              ),
            ),
            if (account != null) ...[
              const SizedBox(width: 8),
              CardSource(account),
            ],
          ],
        ),
      ],
    );
  }
}
