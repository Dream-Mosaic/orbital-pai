import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'meridian_surface.dart';
import 'wall_layout.dart';

/// How big and how bright the voice screen's type is drawn, for where the
/// screen is READ from.
///
/// The Meridian sizes are a verbatim port of the web's CSS, tuned for a phone
/// held at arm's length: engraved labels at 6–9px and 30–40% opacity, which
/// read as quiet chrome in the hand and as nothing at all on a tablet across
/// a kitchen. A wall layout (medium or expanded, [WallLayout]) is read from
/// 2–3 m, so there the same parts are drawn through a floor:
///
/// * [chrome] — the engraved labels and their icons (the nav, the header's
///   meta, the hold-to-talk label, the detents' PTT/ABI, the thread's rail
///   labels and asides, a timer's name) — scaled up, and never below a
///   readable floor;
/// * [ink] — those labels' opacity, lifted in proportion so the dim stay
///   dimmer than the bright (a disabled control still reads disabled), and
///   never past a ceiling, so chrome stays chrome rather than turning into
///   body text;
/// * [body] — the conversation itself, raised moderately;
/// * [footShade] — and the glass's shadow at its foot, lightened, because the
///   nav and the hold-to-talk bar sit in it.
///
/// Every widget keeps its phone value written where it always was (the CSS
/// comments stay true) and passes it through these; [hand] is the identity,
/// so a phone draws exactly what it drew before, pixel for pixel. ONE place
/// decides the wall's numbers — no widget asks how wide the screen is.
@immutable
class WallType {
  const WallType._({
    required this.chromeScale,
    required this.chromeFloor,
    required this.inkLift,
    required this.inkCeiling,
    required this.bodyScale,
    required this.footShade,
  });

  /// A phone in the hand: the CSS port, untouched. Also what any widget built
  /// outside a [WallTypeScope] gets — a drawer, a test, a golden.
  static const hand = WallType._(
    chromeScale: 1,
    chromeFloor: 0,
    inkLift: 1,
    inkCeiling: 1,
    bodyScale: 1,
    footShade: MeridianSurface.defaultFootShade,
  );

  /// A wall or counter tablet, read from across the room. Tuned against the
  /// Lenovo (711×1191 dp, font scale 1.08): the nav's 6.4px labels land at
  /// 11, and their 0.3 opacity at 0.6.
  static const wall = WallType._(
    chromeScale: 1.3,
    chromeFloor: 11,
    inkLift: 2,
    inkCeiling: 0.8,
    bodyScale: 1.2,
    footShade: 0.35,
  );

  /// The phone's value is multiplied by this ...
  final double chromeScale;

  /// ... and never drawn smaller than this.
  final double chromeFloor;

  /// An engraved label's opacity is multiplied by this ...
  final double inkLift;

  /// ... up to this (an opacity already above it is left alone, never dimmed).
  final double inkCeiling;

  /// The thread's reading text, every kind of line alike.
  final double bodyScale;

  /// How dark the glass's inner shadow gets at its foot (MeridianSurface),
  /// where the hold-to-talk bar and the nav sit. Its band is a share of the
  /// screen's height, so on a tall wall it is deep as well as dark: at the
  /// phone's 0.85 it took about 70% off the nav's labels — more than any
  /// opacity lift could give back.
  final double footShade;

  static WallType forLayout(WallLayout layout) =>
      layout == WallLayout.compact ? hand : wall;

  /// The nearest [WallTypeScope]'s, or [hand] when there is none.
  static WallType of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WallTypeScope>()?.type ?? hand;

  /// An engraved label's (or its icon's) size, from the phone's [size].
  double chrome(double size) => math.max(size * chromeScale, chromeFloor);

  /// An engraved label's opacity, from the phone's [alpha].
  double ink(double alpha) =>
      math.max(alpha, math.min(alpha * inkLift, inkCeiling));

  /// A line of the conversation's size, from the phone's [size].
  double body(double size) => size * bodyScale;
}

/// Provides a [WallType] to the voice screen's parts. The screen picks it from
/// the same [WallLayout] that picks its arrangement.
class WallTypeScope extends InheritedWidget {
  const WallTypeScope({super.key, required this.type, required super.child});

  final WallType type;

  @override
  bool updateShouldNotify(WallTypeScope oldWidget) => type != oldWidget.type;
}
