import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../meridian/orb_state.dart';
import '../voice/voice_controller.dart';
import 'device_role.dart';
import 'night_dim.dart';
import 'wall_activity.dart';
import 'window_control.dart';

/// Applies this device's role to the window around the voice screen (spec
/// 2026-10-23, wall tablet, phase 1), and runs the night dim.
///
/// While the device is a wall: the screen is held on and the system bars are
/// hidden. Between 22:00 and 07:00, once nothing has happened for
/// [kDimAfterRest], the window brightness drops to [kDimBrightness] and a
/// black overlay fades the UI. A touch, a wake, a turn, a ringing timer or
/// anything Henry says brings it back at once.
///
/// The same activity tracker tells the voice screen when a wall has been at
/// rest for [kTodayAfterRest] (phase 3, the Today board), through a
/// [WallActivityScope] around [child] — one notion of "at rest", not two.
///
/// Touches are seen through a GLOBAL pointer route, not a `Listener` around
/// [child]: the drawers (Settings, Books, …) are routes on the app's
/// navigator, outside this subtree, and a `Listener` here never hears a tap
/// in them — so a wall would dim under someone using Settings at night. A
/// global route observes every pointer event without taking part in hit
/// testing, so it can never swallow one either.
///
/// Leaving wall mode (or this widget leaving the tree, e.g. a sign-out)
/// restores all of it: the screen-on flag cleared, the bars back, the
/// brightness the system's again, the overlay gone. A personal device that
/// was never a wall is never touched — a phone keeps exactly the window it
/// had before wall mode existed.
class WallModeHost extends StatefulWidget {
  const WallModeHost({
    super.key,
    required this.device,
    required this.vc,
    required this.window,
    this.clock,
    required this.child,
  });

  final DeviceController device;
  final VoiceController vc;
  final WindowControl window;

  /// Local wall-clock time. Null is [DateTime.now]; a test injects a fake.
  final DateTime Function()? clock;

  final Widget child;

  /// How often the dim policy is re-checked while a wall can dim at all.
  static const Duration tick = Duration(seconds: 5);

  /// Dimming eases down; waking is near-instant ("restores it at once").
  static const Duration dimFade = Duration(milliseconds: 1500);
  static const Duration wakeFade = Duration(milliseconds: 150);

  /// So a test can find the overlay and read its opacity.
  static const Key overlayKey = ValueKey('wall-dim-overlay');

  @override
  State<WallModeHost> createState() => _WallModeHostState();
}

class _WallModeHostState extends State<WallModeHost> {
  /// The last role this widget applied to the window; null before the first.
  bool? _appliedWall;
  bool _dimmed = false;
  late DateTime _lastActivity;

  /// What the voice screen reads: a wall, and whether it has rested long
  /// enough for the Today board.
  late final WallActivity _rest = WallActivity(wall: widget.device.isWall);
  late OrbState _lastOrb;
  Timer? _ticker;

  DateTime _now() => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _lastActivity = _now();
    _lastOrb = widget.vc.orbState;
    widget.device.addListener(_onDevice);
    widget.vc.addListener(_onVc);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    _applyRole();
    _syncTicker();
  }

  @override
  void didUpdateWidget(WallModeHost old) {
    super.didUpdateWidget(old);
    if (!identical(old.vc, widget.vc)) {
      old.vc.removeListener(_onVc);
      widget.vc.addListener(_onVc);
      _lastOrb = widget.vc.orbState;
    }
    if (!identical(old.device, widget.device)) {
      old.device.removeListener(_onDevice);
      widget.device.addListener(_onDevice);
      _onDevice();
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _ticker = null;
    _rest.dispose();
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    widget.device.removeListener(_onDevice);
    widget.vc.removeListener(_onVc);
    // Hand the window back: nothing outside this widget owns it, and a login
    // screen on a dimmed, locked-on panel is nobody's idea of signed out.
    if (_appliedWall == true) _restoreWindow();
    super.dispose();
  }

  void _onDevice() {
    _applyRole();
    _syncTicker();
    _evaluate();
  }

  /// Turns the window knobs only on a CHANGE of role (and once at start for a
  /// wall), so dim-at-night flips and rebuilds never re-send them.
  void _applyRole() {
    final wall = widget.device.isWall;
    if (wall == _appliedWall) return;
    final first = _appliedWall == null;
    _appliedWall = wall;
    if (wall) {
      unawaited(widget.window.setKeepScreenOn(true));
      unawaited(widget.window.setImmersive(true));
    } else if (!first) {
      _restoreWindow();
      if (_dimmed) setState(() => _dimmed = false);
    }
  }

  void _restoreWindow() {
    unawaited(widget.window.setKeepScreenOn(false));
    unawaited(widget.window.setImmersive(false));
    unawaited(widget.window.setBrightness(null));
  }

  /// The ticker runs only on a wall — the Today board can come up at any
  /// hour, dim-at-night or not — so a phone carries no periodic timer.
  void _syncTicker() {
    final want = widget.device.isWall;
    if (want && _ticker == null) {
      _ticker = Timer.periodic(WallModeHost.tick, (_) => _onTick());
    } else if (!want) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  bool get _busy => !widget.vc.orbAtRest || widget.vc.timers.any((t) => t.ringing);

  void _onVc() {
    final orb = widget.vc.orbState;
    final changed = orb != _lastOrb;
    _lastOrb = orb;
    if (changed || _busy) _activity();
  }

  void _onTick() {
    // A long answer or a ringing timer that sends no notifications for a
    // while is still not rest.
    if (_busy) _lastActivity = _now();
    _evaluate();
  }

  void _onPointer(PointerEvent event) {
    if (event is PointerDownEvent) _activity();
  }

  void _activity() {
    _lastActivity = _now();
    if (_dimmed) _setDimmed(false);
    // At once, not at the next tick: a touch or a turn brings the thread
    // straight back.
    _rest.set(wall: widget.device.isWall, rested: false);
  }

  void _evaluate() {
    final now = _now();
    final atRest = now.difference(_lastActivity);
    final settings = widget.device.settings;
    final want = shouldDim(localNow: now, atRest: atRest, settings: settings);
    if (want != _dimmed) _setDimmed(want);
    _rest.set(
      wall: widget.device.isWall,
      rested: shouldShowToday(settings: settings, atRest: atRest),
    );
  }

  void _setDimmed(bool dimmed) {
    if (!mounted) return;
    setState(() => _dimmed = dimmed);
    unawaited(widget.window.setBrightness(dimmed ? kDimBrightness : null));
  }

  /// The overlay covers the voice screen; an open drawer sits above it (its
  /// own route) and is dimmed by the window brightness alone. While dimmed it
  /// takes the touch (the global pointer route still sees it and wakes the
  /// wall), so the first tap at night only wakes the screen rather than also
  /// pressing whatever was under the finger; awake, it lets every touch by.
  @override
  Widget build(BuildContext context) => Stack(
        // Passthrough, so the voice screen lays out against exactly the
        // constraints it had before this widget wrapped it.
        fit: StackFit.passthrough,
        children: [
          WallActivityScope(activity: _rest, child: widget.child),
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !_dimmed,
              child: AnimatedOpacity(
                key: WallModeHost.overlayKey,
                opacity: _dimmed ? 1 : 0,
                duration: _dimmed ? WallModeHost.dimFade : WallModeHost.wakeFade,
                child: ColoredBox(color: Colors.black.withValues(alpha: kDimOverlayAlpha)),
              ),
            ),
          ),
        ],
      );
}
