import 'package:flutter/material.dart';

import '../tokens.dart';

/// The shared chrome of the thread's visual answers (`App.Cards`): a dark
/// glass panel with a hairline edge, an accent-tinted engraved header, and a
/// faint wash of the accent from the top-left corner so each card type reads
/// as its own thing at a glance without shouting.
///
/// Every string a card shows arrives formatted from the server; these widgets
/// only lay it out. That is why the accessors below are forgiving — a missing
/// or mistyped field renders as absent, never as a crash or a placeholder.
abstract final class CardStyle {
  static const double radius = 14;
  static const EdgeInsets padding = EdgeInsets.fromLTRB(12, 9, 12, 10);

  /// The glass: a whisper of white over the surface, a touch brighter at the
  /// top edge where the light would catch it.
  static const Color fillTop = Color(0x0FFFFFFF);
  static const Color fillBottom = Color(0x07FFFFFF);
  static const Color edge = Color(0x17FFFFFF);
  static const Color rule = Color(0x0FFFFFFF);

  static const List<FontFeature> tabular = [FontFeature.tabularFigures()];

  /// The tiny engraved uppercase label, the nav's voice at card scale.
  static TextStyle label(Color colour, {double size = 8}) => TextStyle(
        fontFamily: kDisplayFamily,
        fontSize: size,
        height: 1.0,
        fontWeight: FontWeight.w600,
        fontVariations: MType.wght(620),
        letterSpacing: MType.track(size, 0.24),
        color: colour,
        shadows: MType.engraved,
      );

  /// Space Grotesk numerals: temperatures, times, counts. Tabular, so a column
  /// of them lines up.
  static TextStyle numeral(double size, {Color colour = M.ink, double weight = 500}) =>
      TextStyle(
        fontFamily: kDisplayFamily,
        fontSize: size,
        height: 1.0,
        fontWeight: weight >= 600 ? FontWeight.w600 : FontWeight.w400,
        fontVariations: MType.wght(weight),
        fontFeatures: tabular,
        color: colour,
      );

  /// Inter for anything you read as words.
  static TextStyle body(double size,
          {Color colour = M.brainBody, double weight = 420, double height = 1.3}) =>
      TextStyle(
        fontFamily: kBodyFamily,
        fontSize: size,
        height: height,
        fontWeight: weight >= 600 ? FontWeight.w600 : FontWeight.w400,
        fontVariations: MType.wght(weight),
        color: colour,
      );

  static TextStyle meta(double size) =>
      body(size, colour: M.inkDim.withValues(alpha: 0.85), weight: 400);
}

/// Lenient reads of the server's card map.
extension CardData on Map<String, dynamic> {
  String? str(String key) {
    final v = this[key];
    return v is String && v.isNotEmpty ? v : null;
  }

  List<Map<String, dynamic>> rows(String key) {
    final v = this[key];
    if (v is! List) return const [];
    return [
      for (final e in v)
        if (e is Map) e.cast<String, dynamic>(),
    ];
  }

  bool flag(String key) => this[key] == true;

  /// A list of strings (tags, timer suggestions), skipping anything that isn't one.
  List<String> strs(String key) {
    final v = this[key];
    if (v is! List) return const [];
    return [
      for (final s in v)
        if (s is String && s.isNotEmpty) s,
    ];
  }
}

class CardFrame extends StatelessWidget {
  const CardFrame({
    super.key,
    required this.accent,
    required this.label,
    required this.child,
    this.trailing,
    this.footer,
    this.footerTrailing,
  });

  final Color accent;

  /// The engraved header label (uppercased here, sent in sentence case).
  final String label;

  /// A quiet right-aligned header note — a date, a location, a scope.
  final String? trailing;

  final Widget child;

  /// A dim closing line (a tally, a note) and its right-aligned partner
  /// (usually the server's "+N more").
  final String? footer;
  final String? footerTrailing;

  @override
  Widget build(BuildContext context) {
    final hasFooter = footer != null || footerTrailing != null;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(CardStyle.radius),
        border: Border.all(color: CardStyle.edge),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [CardStyle.fillTop, CardStyle.fillBottom],
        ),
        boxShadow: const [
          BoxShadow(color: Color(0x59000000), blurRadius: 18, offset: Offset(0, 8)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(CardStyle.radius - 1),
        child: Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(-1.05, -1.15),
                      radius: 1.25,
                      colors: [
                        accent.withValues(alpha: 0.11),
                        accent.withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: CardStyle.padding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _header(),
                  const SizedBox(height: 10),
                  child,
                  if (hasFooter) ...[
                    const SizedBox(height: 9),
                    _footer(),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header() => Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: accent,
              boxShadow: [BoxShadow(color: accent.withValues(alpha: 0.7), blurRadius: 6)],
            ),
          ),
          const SizedBox(width: 7),
          // The label takes the row; the note keeps its natural width (capped)
          // flush right. Two flexible children would split the row in half
          // and strand the note mid-card.
          Expanded(
            child: Text(
              label.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: CardStyle.label(accent.withValues(alpha: 0.92)),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 112),
              child: Text(
                trailing!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                textAlign: TextAlign.right,
                style: CardStyle.body(10, colour: M.inkDim.withValues(alpha: 0.75)),
              ),
            ),
          ],
        ],
      );

  Widget _footer() => Row(
        children: [
          Expanded(
            child: Text(
              footer ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: CardStyle.body(10.5, colour: M.inkDim.withValues(alpha: 0.7)),
            ),
          ),
          if (footerTrailing != null)
            Text(
              footerTrailing!,
              style: CardStyle.body(10.5,
                  colour: accent.withValues(alpha: 0.85), weight: 500),
            ),
        ],
      );
}

/// A hairline between a card's sections.
class CardRule extends StatelessWidget {
  const CardRule({super.key, this.vertical = 10});

  final double vertical;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.symmetric(vertical: vertical),
        child: Container(height: 1, color: CardStyle.rule),
      );
}

/// Whose calendar or inbox a row came from: a small engraved label, a tag's
/// meaning without a pill's width (the row's text is what's scarce).
class CardSource extends StatelessWidget {
  const CardSource(this.text, {super.key, this.maxWidth = 76});

  final String text;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Text(
          text.toUpperCase(),
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: CardStyle.label(M.chromeDim.withValues(alpha: 0.5), size: 6.6)
              .copyWith(shadows: const []),
        ),
      );
}

/// A tiny outlined tag for a category ("Household", "Follow-up").
class CardTag extends StatelessWidget {
  const CardTag(this.text, {super.key, required this.colour});

  final String text;
  final Color colour;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: colour.withValues(alpha: 0.08),
          border: Border.all(color: colour.withValues(alpha: 0.28)),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          text.toUpperCase(),
          maxLines: 1,
          softWrap: false,
          style: CardStyle.label(colour.withValues(alpha: 0.85), size: 6.6)
              .copyWith(shadows: const []),
        ),
      );
}
