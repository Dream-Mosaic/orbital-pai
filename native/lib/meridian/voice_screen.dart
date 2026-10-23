import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../connection/app_connection.dart';
import '../device/wall_activity.dart';
import '../panels/badges_client.dart';
import '../voice/glance.dart';
import '../voice/voice_controller.dart';
import 'composer.dart';
import 'header.dart';
import 'meridian_surface.dart';
import 'nav.dart';
import 'camera_face.dart';
import 'orb_bezel.dart';
import 'cards/weather_glyph.dart';
import 'orb_face.dart';
import 'orb_state.dart';
import 'palette.dart';
import 'thread.dart';
import 'timer_strip.dart';
import 'today_board.dart';
import 'tokens.dart';
import 'wall_layout.dart';
import 'wall_type.dart';

/// The Meridian voice screen — the port of `<main>` in conversation_live.ex:
/// header / orb pane / thread / hold-to-talk / nav, on the lit MeridianSurface.
///
/// Three layouts, chosen by the width the screen is given ([WallLayout]):
/// the phone column (compact; phones are held portrait by
/// orientation_lock.dart, #8), that column sized for a portrait tablet
/// (medium), and the wall display — orb pane left, thread right — for a
/// landscape tablet or a wide desktop window (expanded). Every dimension is
/// derived from the constraints.
///
/// On a wall (a [WallActivityScope] above says so) that has been at rest for
/// a while, the thread's slot crossfades to the [TodayBoard] — in both wall
/// layouts, never on a phone. The thread stays mounted underneath, invisible
/// and untouchable, so its scroll position and history are exactly where
/// they were when a touch or a turn brings it back.
class MeridianVoiceScreen extends StatefulWidget {
  const MeridianVoiceScreen({
    super.key,
    required this.controller,
    required this.connection,
    required this.userName,
    this.onOpenPanel,
    this.appVersion = '0.0.0',
    this.badges,
    this.clock,
  });

  final VoiceController controller;
  final AppConnection connection;
  final String userName;
  final void Function(MeridianTab tab)? onOpenPanel;
  final String appVersion;

  /// Optional so the widget tests that build a screen without a connection do
  /// not all have to construct one. Null simply means no dots.
  final BadgesClient? badges;

  /// The resting face's wall clock. Injectable so a golden can pin the time.
  final DateTime Function()? clock;

  @override
  State<MeridianVoiceScreen> createState() => _MeridianVoiceScreenState();
}

class _MeridianVoiceScreenState extends State<MeridianVoiceScreen> {
  final ScrollController _scroll = ScrollController();

  /// Survive a change of layout by moving, not rebuilding — see the layouts.
  final GlobalKey _threadKey = GlobalKey(debugLabel: 'thread');
  final GlobalKey _composerKey = GlobalKey(debugLabel: 'composer');

  /// How close to the bottom still counts as "at the bottom". One thread body
  /// line is ~22px (14.88px at line-height 1.5), so this is a little over a
  /// line: enough that a rounding error, a half-scrolled line or a stray pixel
  /// of overscroll still reads as pinned, not enough to swallow a deliberate
  /// scroll away.
  static const double _anchorSlack = 32.0;

  /// Whether growing content should drag the viewport with it.
  ///
  /// Starts true — an empty thread IS at its bottom — and thereafter tracks
  /// exactly one thing: where the viewport came to rest. Scroll up and it
  /// disarms; come back to the bottom and it re-arms.
  bool _anchored = true;

  /// The extent we last anchored to. The SIGNAL this reacts to.
  ///
  /// Thread *length* is the wrong signal: `brain_delta` rewrites one existing
  /// `ThreadLine` in place, so a streaming answer grows the list's height
  /// without ever changing its length — which is precisely how the view came
  /// to sit still while the answer ran off the bottom of the screen. The
  /// height is what moved, so the height (`maxScrollExtent`) is what we watch.
  double _lastExtent = -1;

  /// True from the moment a finger takes hold of the list until the scroll it
  /// started (drag *and* the fling after it) comes to rest. We never jump
  /// during that window — the one thing worse than a list that won't follow is
  /// a list that snatches itself out from under you mid-gesture.
  bool _dragging = false;

  bool _anchorScheduled = false;

  /// The board, rebuilt only when the glance it shows changes: it stays
  /// mounted (invisible) under a streaming answer, and the screen rebuilds
  /// on every delta.
  TodayBoard? _board;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    // Read the intent off the RESULT — where the viewport ended up — rather
    // than off the gesture, so a drag, a fling and our own jump all obey one
    // rule and none of them can leave the flag disagreeing with the view.
    _anchored = p.maxScrollExtent - p.pixels <= _anchorSlack;
  }

  bool _onScrollNotification(ScrollNotification n) {
    // A fling emits no ScrollEndNotification until the ballistic simulation
    // settles, so this stays true for the whole user-owned window, not just
    // while the finger is down.
    if (n is ScrollStartNotification) {
      _dragging = n.dragDetails != null;
    } else if (n is ScrollEndNotification) {
      _dragging = false;
    }
    return false;
  }

  /// Keep the reader pinned to the bottom as the transcript grows — including
  /// while a single streaming line grows taller, which is the case the old
  /// length check missed entirely.
  ///
  /// Post-frame, because the extent we want is the one the frame we just asked
  /// for produces. `jumpTo`, not `animateTo`: the extent changes once per
  /// delta at 20–60Hz, and each new `animateTo` cancels the last, so an
  /// animated follow never actually reaches the bottom while an answer is
  /// streaming — it just lags behind it. A jump applied in the same frame as
  /// the growth that caused it is invisible; the text simply stays put and the
  /// history slides up.
  void _scheduleAnchor() {
    if (_anchorScheduled) return;
    _anchorScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _anchorScheduled = false;
      if (!mounted || !_scroll.hasClients) return;
      final p = _scroll.position;
      final extent = p.maxScrollExtent;
      // Nothing grew (or shrank) — leave the viewport exactly where it is.
      // Without this, every unrelated rebuild would re-assert the bottom.
      if (extent == _lastExtent) return;
      _lastExtent = extent;
      if (!_anchored || _dragging) return;
      if (p.pixels == extent) return;
      p.jumpTo(extent);
    });
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        // Matches the web's data-confirm copy.
        content: const Text('Clear this conversation?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Clear')),
        ],
      ),
    );
    if (ok ?? false) widget.controller.clearConversation();
  }

  @override
  Widget build(BuildContext context) {
    final vc = widget.controller;
    return AnimatedBuilder(
      // Two sources now: the conversation, and the connection under it. Merge
      // rather than nest, so a connection blip does not rebuild twice.
      animation: Listenable.merge([vc, widget.connection, widget.badges]),
      builder: (context, _) {
        final orb = vc.orbState;
        final glow = paletteFor(orb).glow;
        _scheduleAnchor();
        // The soft keyboard (Type to Henry). No Scaffold hosts this screen, so
        // nothing else makes room for it: each layout lifts its composer by
        // its height, and while it is up the nav steps aside and the orb gives
        // way.
        final keyboard = MediaQuery.viewInsetsOf(context).bottom;

        return LayoutBuilder(builder: (context, screen) {
          final size = screen.biggest;
          final layout = WallLayout.forWidth(size.width);
          // The same width that picks the arrangement picks the type: a wall
          // is read from across the room, a phone from arm's length.
          final type = WallType.forLayout(layout);
          // The Today board: null = this screen never shows one (not a wall,
          // or a phone-width window), so the thread is laid out exactly as it
          // always was; otherwise whether it shows now.
          final activity = WallActivityScope.maybeOf(context);
          final bool? board =
              activity != null && activity.wall && layout != WallLayout.compact
                  ? activity.rested
                  : null;
          return WallTypeScope(
            type: type,
            child: MeridianSurface(
              state: orb,
              bleedCentre: _bleedCentre(layout, size),
              footShade: type.footShade,
              // Without a Material ancestor, WidgetsApp's fallback
              // DefaultTextStyle applies — and our styles override its
              // colour/size/family but NOT its `decoration`, so every Text on
              // the screen inherits a yellow double underline. Transparent, so
              // MeridianSurface still owns the backdrop.
              child: Material(
                type: MaterialType.transparency,
                child: SafeArea(
                  child: switch (layout) {
                    WallLayout.compact => _singleColumn(
                        _ColumnSpec.compact, vc, glow, keyboard, board),
                    WallLayout.medium => _singleColumn(
                        _ColumnSpec.medium, vc, glow, keyboard, board),
                    WallLayout.expanded => _twoPanes(vc, glow, keyboard, board),
                  },
                ),
              ),
            ),
          );
        });
      },
    );
  }

  // ---- the layouts ----
  //
  // Three arrangements of ONE set of parts (below). The parts that hold state
  // a person would miss — the thread's scroll position, the composer's draft
  // and focus — carry GlobalKeys, so rotating the wall tablet across the
  // medium/expanded line moves them rather than rebuilding them.

  /// The phone column (compact), or the same column sized for a portrait
  /// tablet (medium): header / orb pane / timers / thread / composer / nav.
  /// On a resting wall the board takes the thread's slot under the orb.
  Widget _singleColumn(_ColumnSpec spec, VoiceController vc, Color glow,
      double keyboard, bool? board) {
    final typing = keyboard > 0;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: spec.maxWidth),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              M.pagePad, M.pagePad, M.pagePad, M.pagePad + keyboard),
          child: Column(
            children: [
              _header(),
              const SizedBox(height: M.columnGap),
              _orbPane(spec, vc, glow,
                  maxDiameter: _orbRoom(spec,
                      typing: typing, timers: vc.timers.isNotEmpty),
                  board: board),
              const SizedBox(height: M.columnGap),
              // Zero height with no timers; carries its own gap below.
              _timers(vc, glow),
              Expanded(child: _threadSlot(vc, glow, board: board)),
              const SizedBox(height: M.columnGap),
              _composer(vc),
              if (!typing) ...[
                const SizedBox(height: M.columnGap),
                _nav(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// The wall display (expanded): the orb pane on the left — header, the orb
  /// as the hero, the timers under it, the composer at its foot — and the
  /// thread on the right at full height, with the nav beneath it so the two
  /// controls share one baseline. On a resting wall the board takes the
  /// thread's place in the right pane; the nav stays.
  Widget _twoPanes(
      VoiceController vc, Color glow, double keyboard, bool? board) {
    final typing = keyboard > 0;
    final orbPane = Padding(
      // The composer rides the keyboard; the orb gives way above it.
      padding: EdgeInsets.only(bottom: keyboard),
      child: Column(
        children: [
          _header(),
          const SizedBox(height: M.columnGap),
          Expanded(child: _orbStage(vc, glow)),
          const SizedBox(height: M.columnGap),
          _timers(vc, glow, railed: false),
          _composer(vc),
        ],
      ),
    );
    final threadPane = Padding(
      // Lifted with the composer, so the answer to what you just typed lands
      // above the keyboard rather than under it.
      padding: EdgeInsets.only(bottom: keyboard),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
              child: _threadSlot(vc, glow, joinsAbove: false, board: board)),
          if (!typing) ...[
            const SizedBox(height: M.columnGap),
            _nav(),
          ],
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.all(Wall.pagePad),
      child: LayoutBuilder(builder: (context, constraints) {
        final (orbWidth, threadWidth) = _paneWidths(constraints.maxWidth);
        // Once both panes reach their caps (a big desktop window), the pair
        // is centred as one composition, rather than the orb hugging the left
        // edge while the thread floats in a field of its own.
        return Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(key: wallOrbPaneKey, width: orbWidth, child: orbPane),
              const SizedBox(width: Wall.gutter),
              SizedBox(
                  key: wallThreadPaneKey,
                  width: threadWidth,
                  child: threadPane),
            ],
          ),
        );
      }),
    );
  }

  // ---- the parts ----

  Widget _header() => MeridianHeader(
        assistantName: VoiceController.assistantName,
        status: widget.connection.connStatus,
        version: widget.appVersion,
        // The server's name for who is signed in; the widget's only until
        // the first snapshot lands.
        userName: widget.controller.userName ?? widget.userName,
        // From the controller, not the device settings: the header names the
        // household exactly when the join says `shared`, so the two can never
        // disagree.
        household: widget.controller.household,
      );

  Widget _timers(VoiceController vc, Color glow, {bool railed = true}) =>
      TimerStrip(
        timers: vc.timers,
        clock: vc.timerClock,
        glow: glow,
        onDismiss: vc.dismissTimer,
        onCancel: vc.cancelTimer,
        railed: railed,
      );

  Widget _thread(VoiceController vc, Color glow, {bool joinsAbove = true}) =>
      NotificationListener<ScrollNotification>(
        onNotification: _onScrollNotification,
        child: Thread(
          key: _threadKey,
          items: vc.thread,
          glow: glow,
          scrollController: _scroll,
          onAck: vc.ackReminder,
          onStartTimer: vc.startTimer,
          startedPills: vc.startedPills,
          photoFor: vc.snapshotFor,
          joinsAbove: joinsAbove,
        ),
      );

  /// The thread, or — on a wall at rest — the Today board in its place.
  ///
  /// [board] null: the thread alone, the tree every phone has always had.
  /// Otherwise both are mounted, one over the other, and crossfade: the
  /// hidden one ignores touches and leaves the semantics tree, but the
  /// thread is never unmounted, so nothing it holds is lost.
  Widget _threadSlot(VoiceController vc, Color glow,
      {bool joinsAbove = true, required bool? board}) {
    final thread = _thread(vc, glow, joinsAbove: joinsAbove);
    if (board == null) return thread;
    final fade = board ? TodayBoard.fadeIn : TodayBoard.fadeOut;
    return Stack(
      fit: StackFit.expand,
      children: [
        _layer(threadLayerKey, visible: !board, fade: fade, child: thread),
        _layer(todayBoardLayerKey,
            visible: board, fade: fade, child: _todayBoard(vc.glance)),
      ],
    );
  }

  static Widget _layer(Key key,
          {required bool visible,
          required Duration fade,
          required Widget child}) =>
      IgnorePointer(
        ignoring: !visible,
        child: ExcludeSemantics(
          excluding: !visible,
          child: AnimatedOpacity(
            key: key,
            opacity: visible ? 1 : 0,
            duration: fade,
            curve: Curves.easeOut,
            child: child,
          ),
        ),
      );

  TodayBoard _todayBoard(Glance glance) {
    final cached = _board;
    if (cached != null && identical(cached.glance, glance)) return cached;
    return _board = TodayBoard(glance: glance);
  }

  Widget _composer(VoiceController vc) => ComposerDock(
        key: _composerKey,
        pttEnabled: vc.pttEnabled,
        pttHeld: vc.pttHeld,
        onPttPress: vc.pttPress,
        onPttRelease: vc.pttRelease,
        onSend: vc.sendText,
      );

  Widget _nav() => MeridianNav(
        hasDue: widget.badges?.hasDue ?? false,
        onTap: (tab) => widget.onOpenPanel?.call(tab),
      );

  /// The machined bezel at diameter [d], with the face in its glass: the
  /// camera while a capture is live, else the resting clock when at rest.
  Widget _bezel(VoiceController vc, Color glow, double d) => SizedBox(
        width: d,
        height: d,
        child: OrbBezel(
          frame: vc.orbFrame,
          glow: glow,
          caption: vc.caption,
          captionPending: vc.captionPending,
          powerOn: vc.micOn,
          powerEnabled: widget.connection.connStatus == ConnStatus.connected,
          pttOn: vc.pttEnabled,
          abiOn: vc.abiEnabled,
          onPower: () => vc.togglePower(),
          onClear: _confirmClear,
          onPtt: vc.setPtt,
          onAbi: vc.setAllowInterruptions,
          face: _face(vc),
        ),
      );

  /// What the glass shows in place of the caption. ONE place for both
  /// layouts: "Henry, look at this" takes the glass from everything else,
  /// the resting clock included, for as long as its capture is live.
  Widget Function(double, double)? _face(VoiceController vc) {
    final shot = vc.camera;
    if (shot != null) {
      return (w, h) => CameraFace(
            key: cameraFaceKey,
            width: w,
            height: h,
            shot: shot,
            preview: vc.cameraPreview,
          );
    }
    return vc.orbAtRest
        ? (w, h) => OrbFace(
              width: w,
              height: h,
              glance: vc.glance,
              hint: vc.restingHint,
              dimmed: !vc.micOn,
              lit: const {OrbState.listening, OrbState.speaking, OrbState.thinking}
                  .contains(vc.orbState),
              glyph: (icon, size, _) => WeatherGlyph(icon, size: size),
              clock: widget.clock ?? DateTime.now,
            )
        : null;
  }

  /// The single column's orb: the bezel, and the elbow that carries its light
  /// down into the thread's spine — which fades with the thread when the
  /// board takes its place, since the board has no spine to carry it into.
  Widget _orbPane(_ColumnSpec spec, VoiceController vc, Color glow,
      {double? maxDiameter, bool? board}) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: spec.orbPaneMaxWidth),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // .bezel { width: min(272px, 74%) } — and smaller still where the
            // height runs short (see _orbRoom).
            final d = math.min(
              maxDiameter ?? spec.bezelMaxWidth, // never above the cap
              constraints.maxWidth * M.bezelPaneFraction,
            );
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _bezel(vc, glow, d),
                SizedBox(
                  width: constraints.maxWidth,
                  // The .elbow is 30px tall with margin-top: -6px; fold the
                  // negative margin into the box rather than translating it.
                  height: 24,
                  child: board == null
                      ? CustomPaint(painter: ElbowPainter(glow: glow))
                      : AnimatedOpacity(
                          opacity: board ? 0 : 1,
                          duration:
                              board ? TodayBoard.fadeIn : TodayBoard.fadeOut,
                          curve: Curves.easeOut,
                          child: CustomPaint(painter: ElbowPainter(glow: glow)),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// The wall's orb: as large as the pane allows (up to its cap), centred in
  /// whatever height is left above the timers and the composer — which is
  /// also how it gives way to the keyboard: that height is all it reads.
  Widget _orbStage(VoiceController vc, Color glow) => LayoutBuilder(
        builder: (context, constraints) {
          final d = math.max(
            0.0,
            math.min(
              math.min(Wall.bezelMaxWidth,
                  constraints.maxWidth * Wall.bezelPaneFraction),
              constraints.maxHeight - _detentLabelRoom,
            ),
          );
          return Center(child: _bezel(vc, glow, d));
        },
      );

  // ---- sizing ----

  /// What the column holds besides the orb while the keyboard is up: header,
  /// three gaps, the elbow, a one-line composer, and enough thread to read.
  static double _reservedWhileTyping(_ColumnSpec spec) =>
      M.headerMinHeight + 3 * M.columnGap + 24 + spec.composerHeight + 150;

  /// Below this the bezel's detents crowd the glass.
  static const double _minOrbWhileTyping = 96;

  /// The same with the keyboard down and the nav back, for a medium screen
  /// that is short (a desktop window, say): it keeps a real thread.
  static double _reservedAtRest(_ColumnSpec spec) =>
      M.headerMinHeight +
      4 * M.columnGap +
      24 +
      spec.composerHeight +
      spec.navHeight +
      240;
  static const double _minOrbAtRest = 120;

  /// The engraved PTT/ABI labels hang under the lower detents; on a small
  /// bezel they clear its square by up to this much. Only the wall's two
  /// panes ask, and a wall draws those labels larger (WallType): 16 was the
  /// phone-sized label's overhang.
  static const double _detentLabelRoom = 22;

  /// The largest orb that still leaves the conversation readable. Derived
  /// from the height the column actually gets, so while the keyboard is up it
  /// tracks the keyboard's own slide frame by frame — the orb gives way only
  /// as much as the keyboard takes, and not at all where there is room.
  ///
  /// A phone needs it only while typing (it is held portrait, #8) and keeps
  /// exactly its original arithmetic. A medium screen can be short, so there
  /// it applies always, and it also makes room for the timers when any run.
  double? _orbRoom(_ColumnSpec spec,
      {required bool typing, required bool timers}) {
    if (!typing && !spec.fitsHeight) return null;
    final mq = MediaQuery.of(context);
    final column = mq.size.height -
        mq.padding.vertical -
        mq.viewInsets.bottom -
        2 * M.pagePad -
        (spec.fitsHeight && timers ? spec.timerStripHeight : 0);
    return typing
        ? (column - _reservedWhileTyping(spec))
            .clamp(_minOrbWhileTyping, spec.bezelMaxWidth)
        : (column - _reservedAtRest(spec))
            .clamp(_minOrbAtRest, spec.bezelMaxWidth);
  }

  /// The two panes' widths in [width]: the orb pane takes its share, within
  /// its bounds; the thread takes the rest, up to its readable measure.
  static (double, double) _paneWidths(double width) {
    final orb = (width * Wall.orbPaneFraction)
        .clamp(Wall.orbPaneMinWidth, Wall.orbPaneMaxWidth);
    return (orb, math.min(Wall.threadMaxWidth, width - orb - Wall.gutter));
  }

  /// Where the orb's light should pool for [layout] on a screen of [size].
  /// An estimate from the same metrics the layouts use: the bleed is a
  /// gradient hundreds of pixels across, so a few pixels of error are
  /// invisible, and it needs no second layout pass to find the orb.
  static Alignment _bleedCentre(WallLayout layout, Size size) {
    Alignment at(double x, double y) =>
        Alignment(2 * x / size.width - 1, 2 * y / size.height - 1);
    switch (layout) {
      case WallLayout.compact:
        return MeridianSurface.defaultBleedCentre;
      case WallLayout.medium:
        final column =
            math.min(size.width, Wall.mediumMaxWidth) - 2 * M.pagePad;
        final d = math.min(Wall.mediumBezelMaxWidth,
            math.min(column, Wall.mediumOrbPaneMaxWidth) * M.bezelPaneFraction);
        return at(size.width / 2,
            M.pagePad + M.headerMinHeight + M.columnGap + d / 2);
      case WallLayout.expanded:
        final inner = size.width - 2 * Wall.pagePad;
        final (pane, thread) = _paneWidths(inner);
        final left = Wall.pagePad + (inner - (pane + Wall.gutter + thread)) / 2;
        const top = Wall.pagePad + M.headerMinHeight + M.columnGap;
        // The wall's composer: as tall as the medium column's.
        final bottom = size.height -
            Wall.pagePad -
            _ColumnSpec.medium.composerHeight -
            M.columnGap;
        return at(left + pane / 2, (top + bottom) / 2);
    }
  }
}

/// The camera's face in the orb (its own key, so it crossfades with the clock).
const Key cameraFaceKey = ValueKey('camera-face');

/// The wall display's two panes, for tests that need to tell them apart.
const Key wallOrbPaneKey = ValueKey('wall-orb-pane');
const Key wallThreadPaneKey = ValueKey('wall-thread-pane');

/// The thread slot's two crossfading layers on a wall (their AnimatedOpacity),
/// for tests that need to see which one shows.
const Key threadLayerKey = ValueKey('thread-layer');
const Key todayBoardLayerKey = ValueKey('today-board-layer');

/// The single column's sizes: the phone's, verbatim from the CSS port, or the
/// same column scaled for a portrait tablet.
class _ColumnSpec {
  const _ColumnSpec({
    required this.maxWidth,
    required this.orbPaneMaxWidth,
    required this.bezelMaxWidth,
    required this.fitsHeight,
    required this.composerHeight,
    required this.navHeight,
    required this.timerStripHeight,
  });

  final double maxWidth;
  final double orbPaneMaxWidth;
  final double bezelMaxWidth;

  /// Whether the orb also gives way to a short screen with the keyboard down.
  final bool fitsHeight;

  /// The composer tray, the nav, and a row of timer chips with its gap —
  /// near enough, for the orb's estimates (see `_orbRoom`).
  final double composerHeight;
  final double navHeight;
  final double timerStripHeight;

  static const compact = _ColumnSpec(
    maxWidth: M.maxWidth,
    orbPaneMaxWidth: M.orbPaneMaxWidth,
    bezelMaxWidth: M.bezelMaxWidth,
    fitsHeight: false,
    composerHeight: 44,
    navHeight: 56,
    timerStripHeight: 82,
  );

  /// The same parts, a little taller: a wall draws their labels larger
  /// (WallType). Measured at the Lenovo's font scale, 1.08.
  static const medium = _ColumnSpec(
    maxWidth: Wall.mediumMaxWidth,
    orbPaneMaxWidth: Wall.mediumOrbPaneMaxWidth,
    bezelMaxWidth: Wall.mediumBezelMaxWidth,
    fitsHeight: true,
    composerHeight: 48,
    navHeight: 70,
    timerStripHeight: 91,
  );
}
