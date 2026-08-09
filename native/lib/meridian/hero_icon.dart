import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// The nine heroicons the web actually renders, bundled from the SAME source the
/// server uses (`deps/heroicons/optimized/24/outline`) rather than approximated
/// with Material lookalikes. The two sets differ in stroke weight and terminals,
/// which reads as "not quite the same app" when you put the screens side by side.
///
/// 24/outline is what Phoenix's `hero-*` classes inline: a 24-unit viewBox with a
/// 1.5 stroke and `stroke="currentColor"`, so the tint is applied here.
enum HeroIcon {
  bell,
  bookOpen,
  check,
  cog6Tooth,
  handRaised,
  link,
  magnifyingGlass,
  microphone,
  power,
  trash,
  xMark;

  /// The heroicons file name, which is also the web's `hero-<name>` class.
  String get asset => switch (this) {
        HeroIcon.bell => 'bell',
        HeroIcon.bookOpen => 'book-open',
        HeroIcon.check => 'check',
        HeroIcon.cog6Tooth => 'cog-6-tooth',
        HeroIcon.handRaised => 'hand-raised',
        HeroIcon.link => 'link',
        HeroIcon.magnifyingGlass => 'magnifying-glass',
        HeroIcon.microphone => 'microphone',
        HeroIcon.power => 'power',
        HeroIcon.trash => 'trash',
        HeroIcon.xMark => 'x-mark',
      };
}

/// Drop-in for [Icon], so callers read the same as they did with Material icons.
class HeroIconView extends StatelessWidget {
  const HeroIconView(this.icon, {super.key, required this.size, this.color});

  final HeroIcon icon;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? IconTheme.of(context).color;
    return SvgPicture.asset(
      'assets/icons/${icon.asset}.svg',
      width: size,
      height: size,
      colorFilter: tint == null ? null : ColorFilter.mode(tint, BlendMode.srcIn),
      // The finder in tests keys off this; it also gives the screen reader the
      // same affordance the web's aria-hidden SVG gets from its button label.
      semanticsLabel: icon.name,
    );
  }
}
