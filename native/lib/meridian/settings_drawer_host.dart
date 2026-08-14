import 'package:flutter/material.dart';

import '../panels/memory_client.dart';
import '../panels/settings_client.dart';
import 'drawer.dart';
import 'memory_panel.dart';
import 'settings_panel.dart';

/// Hosts the Settings drawer's two layers — Settings and Memory — inside the
/// ONE route `meridianHostedDrawerRoute` pushes. Swapping `_memory` swaps the
/// drawer's title/onBack/child in place rather than pushing a second route:
/// one scrim, one slide, and system back can pop a layer instead of the whole
/// drawer.
///
/// Exactly one panel topic is open at a time: [_openMemory] closes Settings
/// before opening Memory, and [_back] reverses it. The caller is expected to
/// have already opened [settings] before pushing this widget (main.dart's
/// `_openPanel` does, matching every other drawer) — this widget only ever
/// toggles between the two, it never performs the very first open.
class SettingsDrawerHost extends StatefulWidget {
  const SettingsDrawerHost({
    super.key,
    required this.animation,
    required this.onClose,
    required this.settings,
    required this.memory,
  });

  final Animation<double> animation;
  final VoidCallback onClose;
  final SettingsClient settings;
  final MemoryClient memory;

  @override
  State<SettingsDrawerHost> createState() => _SettingsDrawerHostState();
}

class _SettingsDrawerHostState extends State<SettingsDrawerHost> {
  bool _memory = false;

  void _openMemory() {
    widget.settings.close();
    widget.memory.open();
    setState(() => _memory = true);
  }

  void _back() {
    widget.memory.close();
    widget.settings.open();
    setState(() => _memory = false);
  }

  @override
  Widget build(BuildContext context) => PopScope(
        // At the Memory layer, a pop is blocked (canPop: false) and handled
        // as a layer-back instead — system back pops Memory -> Settings
        // before it ever reaches the route. At the Settings layer, canPop is
        // true and the pop proceeds normally, closing the drawer.
        canPop: !_memory,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          _back();
        },
        child: MeridianDrawer(
          title: _memory ? 'Memory' : 'Settings',
          animation: widget.animation,
          onClose: widget.onClose,
          onBack: _memory ? _back : null,
          child: _memory
              ? MemoryPanelView(client: widget.memory)
              : SettingsPanelView(
                  client: widget.settings,
                  onOpenMemory: _openMemory,
                ),
        ),
      );
}
