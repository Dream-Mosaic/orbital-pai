import 'package:flutter/material.dart';

import 'tokens.dart';

/// Search has no channel: the web renders a single "coming soon" line, so
/// there is no data path to build. It is here to keep the nav station honest —
/// and as the proof that a panel need not have a client at all.
class SearchPanelView extends StatelessWidget {
  const SearchPanelView({super.key});

  @override
  Widget build(BuildContext context) => Text(
        // voice_modals.ex:849, verbatim — `text-sm opacity-60`.
        'Search is coming soon.',
        style: TextStyle(fontSize: 14, color: M.ink.withValues(alpha: 0.6)),
      );
}
