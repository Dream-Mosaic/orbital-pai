import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../connection/app_connection.dart';
import '../panels/badges_client.dart';
import '../voice/voice_controller.dart';
import 'header.dart';
import 'hold_to_talk.dart';
import 'meridian_surface.dart';
import 'nav.dart';
import 'orb_bezel.dart';
import 'palette.dart';
import 'thread.dart';
import 'tokens.dart';

/// The Meridian voice screen — the port of `<main>` in conversation_live.ex:
/// header / orb pane / thread / hold-to-talk / nav, on the lit MeridianSurface.
/// Phone portrait; every dimension is derived from the constraints, so a later
/// landscape pass is a layout change here and nowhere else.
class MeridianVoiceScreen extends StatefulWidget {
  const MeridianVoiceScreen({
    super.key,
    required this.controller,
    required this.connection,
    required this.userName,
    this.onOpenPanel,
    this.onDevEntry,
    this.appVersion = '0.0.0',
    this.badges,
  });

  final VoiceController controller;
  final AppConnection connection;
  final String userName;
  final void Function(MeridianTab tab)? onOpenPanel;
  final VoidCallback? onDevEntry;
  final String appVersion;

  /// Optional so the widget tests that build a screen without a connection do
  /// not all have to construct one. Null simply means no dots.
  final BadgesClient? badges;

  @override
  State<MeridianVoiceScreen> createState() => _MeridianVoiceScreenState();
}

class _MeridianVoiceScreenState extends State<MeridianVoiceScreen> {
  final ScrollController _scroll = ScrollController();

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
    if (ok ?? false) widget.controller.clearThread();
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

        return MeridianSurface(
          state: orb,
          // Without a Material ancestor, WidgetsApp's fallback DefaultTextStyle
          // applies — and our styles override its colour/size/family but NOT its
          // `decoration`, so every Text on the screen inherits a yellow double
          // underline. Transparent, so MeridianSurface still owns the backdrop.
          child: Material(
            type: MaterialType.transparency,
            child: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: M.maxWidth),
                  child: Padding(
                    padding: const EdgeInsets.all(M.pagePad),
                    child: Column(
                      children: [
                        MeridianHeader(
                          assistantName: VoiceController.assistantName,
                          status: widget.connection.connStatus,
                          version: widget.appVersion,
                          userName: widget.userName,
                          onVersionLongPress: widget.onDevEntry,
                        ),
                        const SizedBox(height: M.columnGap),
                        _orbPane(vc, glow),
                        const SizedBox(height: M.columnGap),
                        Expanded(
                          child: NotificationListener<ScrollNotification>(
                            onNotification: _onScrollNotification,
                            child: Thread(
                              items: vc.thread,
                              glow: glow,
                              scrollController: _scroll,
                              onAck: vc.ackReminder,
                            ),
                          ),
                        ),
                        const SizedBox(height: M.columnGap),
                        HoldToTalkBar(
                          enabled: vc.pttEnabled,
                          held: vc.pttHeld,
                          onPress: vc.pttPress,
                          onRelease: vc.pttRelease,
                        ),
                        const SizedBox(height: M.columnGap),
                        MeridianNav(
                          hasDue: widget.badges?.hasDue ?? false,
                          onTap: (tab) => widget.onOpenPanel?.call(tab),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _orbPane(VoiceController vc, Color glow) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: M.orbPaneMaxWidth),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // .bezel { width: min(272px, 74%) }
            final d = math.min(
              M.bezelMaxWidth,
              constraints.maxWidth * M.bezelPaneFraction,
            );
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: d,
                  height: d,
                  child: OrbBezel(
                    frame: vc.orbFrame,
                    glow: glow,
                    caption: vc.caption,
                    powerOn: vc.micOn,
                    powerEnabled:
                        widget.connection.connStatus == ConnStatus.connected,
                    pttOn: vc.pttEnabled,
                    abiOn: vc.abiEnabled,
                    onPower: () => vc.togglePower(),
                    onClear: _confirmClear,
                    onPtt: vc.setPtt,
                    onAbi: vc.setAllowInterruptions,
                  ),
                ),
                SizedBox(
                  width: constraints.maxWidth,
                  // The .elbow is 30px tall with margin-top: -6px; fold the
                  // negative margin into the box rather than translating it.
                  height: 24,
                  child: CustomPaint(painter: ElbowPainter(glow: glow)),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
