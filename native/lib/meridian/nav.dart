import 'package:flutter/material.dart';
import 'tokens.dart';

/// The five bottom-nav stations, in the web's source order
/// (conversation_live.ex:904-941). **This order is fixed**: phases B–D swap a
/// webview for a native screen, never the shape of the nav (parent spec §7).
enum MeridianTab { settings, reminders, books, connectors, search }

extension MeridianTabInfo on MeridianTab {
  String get label => switch (this) {
        MeridianTab.settings => 'Settings',
        MeridianTab.reminders => 'Reminders',
        MeridianTab.books => 'Books',
        MeridianTab.connectors => 'Connectors',
        MeridianTab.search => 'Search',
      };

  /// heroicon -> Material equivalent (spec §8).
  IconData get icon => switch (this) {
        MeridianTab.settings => Icons.settings_outlined, // hero-cog-6-tooth
        MeridianTab.reminders => Icons.notifications_none, // hero-bell
        MeridianTab.books => Icons.menu_book_outlined, // hero-book-open
        MeridianTab.connectors => Icons.link, // hero-link
        MeridianTab.search => Icons.search, // hero-magnifying-glass
      };

  /// The `phx-value-modal` the web's nav button carries — also the `?panel=`
  /// value the webview loads.
  String get modal => switch (this) {
        MeridianTab.settings => 'settings',
        MeridianTab.reminders => 'reminders',
        MeridianTab.books => 'books',
        MeridianTab.connectors => 'connectors',
        MeridianTab.search => 'search',
      };
}

/// `#bottom-nav`: engraved stations across the foot of the screen.
class MeridianNav extends StatelessWidget {
  const MeridianNav({super.key, required this.onTap, this.hasDue = false});

  final void Function(MeridianTab tab) onTap;

  /// The web reads `@due` — a LiveView assign the channel does not carry. The
  /// badge is built and styled but stays false until a later phase feeds it.
  final bool hasDue;

  static const double _labelSize = 7.04; // 0.44rem

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 2),
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 4),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: Color(0x0EFFFFFF)), // rgba(255,255,255,0.055)
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          for (final tab in MeridianTab.values)
            // Flexible, because five engraved labels do not fit a 360px phone at
            // their natural width. The CSS gets away with it: flex items shrink
            // by default and `.nlabel` has no `nowrap`, so the browser wraps the
            // label. A plain Row would just overflow — which it did.
            Flexible(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onTap(tab),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(tab.icon,
                              size: 18, color: M.chromeDim.withValues(alpha: 0.42)),
                          const SizedBox(height: 5), // .nbtn gap
                          Text(
                            tab.label.toUpperCase(),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontFamily: kDisplayFamily,
                              fontSize: _labelSize,
                              fontWeight: FontWeight.w600,
                              letterSpacing: MType.track(_labelSize, 0.34),
                              color: M.chromeDim.withValues(alpha: 0.3),
                              shadows: MType.engraved,
                            ),
                          ),
                        ],
                      ),
                      if (hasDue && tab == MeridianTab.reminders)
                        Positioned(
                          // .duedot is top: 1px / right: 9px off .nbtn's
                          // PADDING box; this Stack sits inside that padding.
                          top: -3,
                          right: -1,
                          child: Container(
                            key: const ValueKey('due-dot'),
                            width: 6,
                            height: 6,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: M.you,
                              boxShadow: [BoxShadow(color: M.you, blurRadius: 8)],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
