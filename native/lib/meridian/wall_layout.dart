/// The voice screen's three layouts, picked from the width the screen is
/// GIVEN — never from what the device says it is. A phone, a portrait tablet,
/// a landscape tablet and a desktop window dragged wider all land here by
/// their constraints alone, so resizing a window walks through all three.
///
/// * [compact] — the phone column, exactly as the CSS port drew it.
/// * [medium] — the same single column, sized for a portrait tablet.
/// * [expanded] — the wall display: the orb pane on the left, the thread on
///   the right.
enum WallLayout {
  compact,
  medium,
  expanded;

  /// Material's compact/medium/expanded window classes, applied to width.
  static WallLayout forWidth(double width) => width < Wall.mediumMinWidth
      ? WallLayout.compact
      : (width < Wall.expandedMinWidth
          ? WallLayout.medium
          : WallLayout.expanded);
}

/// Metrics for the two layouts the web never had. The phone's live in [M]
/// (tokens.dart), which is a verbatim CSS port; these are native decisions, so
/// they live apart from it.
abstract final class Wall {
  static const double mediumMinWidth = 600;
  static const double expandedMinWidth = 900;

  // --- medium: the phone column, scaled for a portrait tablet ---

  /// The column. Wide enough that the orb can be a centrepiece rather than a
  /// phone's orb floating in a tablet's margins; narrow enough that the
  /// thread's lines stay a comfortable read.
  static const double mediumMaxWidth = 560;

  /// [M.orbPaneMaxWidth] and [M.bezelMaxWidth], scaled together so a medium
  /// bezel can actually reach its cap (the pane's 74% clears 400 at 540).
  static const double mediumOrbPaneMaxWidth = 540;
  static const double mediumBezelMaxWidth = 400;

  // --- expanded: two panes ---

  /// The page margin. A wall display is read from across a room; a phone's
  /// 16dp edge would put the chrome hard against the bezel of the glass.
  static const double pagePad = 24;

  /// Between the orb pane and the thread pane.
  static const double gutter = 32;

  /// The orb pane's share of the width, and its bounds: never so narrow the
  /// controls crowd, never so wide that a desktop window strands the orb in
  /// empty glass while the thread is starved.
  static const double orbPaneFraction = 0.42;
  static const double orbPaneMinWidth = 360;
  static const double orbPaneMaxWidth = 600;

  /// The bezel: as large as the pane allows, up to this.
  static const double bezelMaxWidth = 520;

  /// Of the orb pane's width. The halos overscan the bezel by
  /// `kOrbScale` and are meant to spill; the rim and detents are not.
  static const double bezelPaneFraction = 0.86;

  /// The thread pane's readable measure. Wider than this and Henry's lines
  /// run past 90 characters, which nobody reads from across a kitchen.
  static const double threadMaxWidth = 760;
}
