import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../connection/app_connection.dart';
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
  });

  final VoiceController controller;
  final AppConnection connection;
  final String userName;
  final void Function(MeridianTab tab)? onOpenPanel;
  final VoidCallback? onDevEntry;
  final String appVersion;

  @override
  State<MeridianVoiceScreen> createState() => _MeridianVoiceScreenState();
}

class _MeridianVoiceScreenState extends State<MeridianVoiceScreen> {
  final ScrollController _scroll = ScrollController();
  int _lastLength = 0;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// index.js scrolls the log to the bottom on every append.
  void _autoScroll(int length) {
    if (length == _lastLength) return;
    _lastLength = length;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
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
      animation: Listenable.merge([vc, widget.connection]),
      builder: (context, _) {
        final orb = vc.orbState;
        final glow = paletteFor(orb).glow;
        _autoScroll(vc.thread.length);

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
                          child: Thread(
                            items: vc.thread,
                            glow: glow,
                            scrollController: _scroll,
                            onAck: vc.ackReminder,
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
