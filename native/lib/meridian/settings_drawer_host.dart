import 'package:flutter/material.dart';

import '../panels/memory_client.dart';
import '../panels/settings_client.dart';
import '../panels/voice_lock_client.dart';
import 'drawer.dart';
import 'memory_panel.dart';
import 'settings_panel.dart';
import 'voice_lock_panel.dart';

/// Hosts the Settings drawer's three layers — Settings, Memory and Voice
/// Lock — inside the ONE route `meridianHostedDrawerRoute` pushes. Swapping
/// the layer swaps the drawer's title/onBack/child in place rather than
/// pushing another route: one scrim, one slide, and system back can pop a
/// layer instead of the whole drawer.
///
/// Exactly one panel topic is open at a time: [_openOnly] closes the current
/// layer before opening the next, and [_back] reverses it back to Settings.
/// The caller is expected to have already opened [settings] before pushing
/// this widget (main.dart's `_openPanel` does, matching every other drawer)
/// — this widget only ever toggles between the layers, it never performs the
/// very first open.
class SettingsDrawerHost extends StatefulWidget {
  const SettingsDrawerHost({
    super.key,
    required this.animation,
    required this.onClose,
    required this.settings,
    required this.memory,
    required this.voiceLock,
  });

  final Animation<double> animation;
  final VoidCallback onClose;
  final SettingsClient settings;
  final MemoryClient memory;
  final VoiceLockClient voiceLock;

  @override
  State<SettingsDrawerHost> createState() => _SettingsDrawerHostState();
}

/// The drawer's layers. An ENUM, not a pair of bools: two bools would make
/// "Memory and Voice Lock at once" representable and force every read to
/// encode a precedence rule that has no meaning.
enum _Layer { settings, memory, voiceLock }

class _SettingsDrawerHostState extends State<SettingsDrawerHost> {
  _Layer _layer = _Layer.settings;

  void _openOnly(_Layer next) {
    if (next == _layer) return;
    _close(_layer);
    _open(next);
    setState(() => _layer = next);
  }

  void _back() => _openOnly(_Layer.settings);

  void _open(_Layer l) => switch (l) {
        _Layer.settings => widget.settings.open(),
        _Layer.memory => widget.memory.open(),
        _Layer.voiceLock => widget.voiceLock.open(),
      };

  void _close(_Layer l) => switch (l) {
        _Layer.settings => widget.settings.close(),
        _Layer.memory => widget.memory.close(),
        _Layer.voiceLock => widget.voiceLock.close(),
      };

  @override
  Widget build(BuildContext context) => PopScope(
        // At a SUB-layer a pop is blocked (canPop: false) and handled as a
        // layer-back instead — system back pops the sub-layer to Settings
        // before it ever reaches the route. At Settings, canPop is true and
        // the pop proceeds normally, closing the drawer.
        canPop: _layer == _Layer.settings,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          _back();
        },
        child: MeridianDrawer(
          title: switch (_layer) {
            _Layer.settings => 'Settings',
            _Layer.memory => 'Memory',
            _Layer.voiceLock => 'Voice Lock',
          },
          animation: widget.animation,
          onClose: widget.onClose,
          onBack: _layer == _Layer.settings ? null : _back,
          child: switch (_layer) {
            _Layer.settings => SettingsPanelView(
                client: widget.settings,
                onOpenMemory: () => _openOnly(_Layer.memory),
                onOpenVoiceLock: () => _openOnly(_Layer.voiceLock),
              ),
            _Layer.memory => MemoryPanelView(client: widget.memory),
            _Layer.voiceLock => VoiceLockPanelView(client: widget.voiceLock),
          },
        ),
      );
}
