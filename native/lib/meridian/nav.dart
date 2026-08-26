import 'package:flutter/material.dart';
import 'hero_icon.dart';
import 'tokens.dart';

/// The five bottom-nav stations, in the web's source order
/// (conversation_live.ex:904-941). **This order is fixed**: phases B–D
/// swapped a webview for a native screen one station at a time, never the
/// shape of the nav (parent spec §7). All five are native now.
enum MeridianTab { settings, reminders, books, connectors, search }

extension MeridianTabInfo on MeridianTab {
  String get label => switch (this) {
        MeridianTab.settings => 'Settings',
        MeridianTab.reminders => 'Reminders',
        MeridianTab.books => 'Books',
        MeridianTab.connectors => 'Connectors',
        MeridianTab.search => 'Search',
      };

  /// The web's own heroicon, bundled — not a Material lookalike.
  HeroIcon get icon => switch (this) {
        MeridianTab.settings => HeroIcon.cog6Tooth,
        MeridianTab.reminders => HeroIcon.bell,
        MeridianTab.books => HeroIcon.bookOpen,
        MeridianTab.connectors => HeroIcon.link,
        MeridianTab.search => HeroIcon.magnifyingGlass,
      };

  /// The `phx-value-modal` the web's nav button carries — also the `?panel=`
  /// value the now-retired native webview used to load.
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

  /// 0.44rem (7.04px) in the CSS. The web wraps "CONNECTORS" to two lines at
  /// phone width rather than shrinking it; we keep one line instead, and the
  /// widest label is what sets the size. Dropping it uniformly reads as chrome —
  /// letting FittedBox shrink only the two long ones read as a bug.
  static const double _labelSize = 6.4;

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
                  padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          HeroIconView(tab.icon,
                              size: 18, color: M.chromeDim.withValues(alpha: 0.42)),
                          const SizedBox(height: 5), // .nbtn gap
                          // The CSS lets the label wrap; at 360px that splits
                          // "REMINDERS" across two lines, which reads as broken
                          // rather than as chrome. One line, scaled down only if
                          // the station is genuinely too narrow for it.
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              tab.label.toUpperCase(),
                              maxLines: 1,
                              softWrap: false,
                              style: TextStyle(
                                fontFamily: kDisplayFamily,
                                fontSize: _labelSize,
                                fontWeight: FontWeight.w600,
                                fontVariations: MType.wght(600),
                                letterSpacing: MType.track(_labelSize, 0.34),
                                color: M.chromeDim.withValues(alpha: 0.3),
                                shadows: MType.engraved,
                              ),
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
