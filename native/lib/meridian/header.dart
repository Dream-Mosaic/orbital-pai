import 'package:flutter/material.dart';
import 'tokens.dart';

/// `main:has(#voice) > header` — wordmark + connection dot on the left, the quiet
/// version/user meta block on the right (spec §3).
class MeridianHeader extends StatelessWidget {
  const MeridianHeader({
    super.key,
    required this.assistantName,
    required this.status,
    required this.version,
    required this.userName,
    this.onVersionLongPress,
  });

  final String assistantName;
  final ConnStatus status;
  final String version;
  final String userName;

  /// Dev-only entry for PorcupineSpikeScreen, which lost its home when the debug
  /// UI's AppBar was deleted.
  final VoidCallback? onVersionLongPress;

  static const double _wordmarkSize = 15.2; // 0.95rem
  static const double _metaSize = 8.32; // 0.52rem

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: M.headerMinHeight),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                assistantName.toUpperCase(),
                style: TextStyle(
                  fontFamily: kDisplayFamily,
                  fontSize: _wordmarkSize,
                  fontWeight: FontWeight.w600,
                  letterSpacing: MType.track(_wordmarkSize, 0.42),
                  color: M.chrome.withValues(alpha: 0.82),
                  shadows: MType.wordmark,
                ),
              ),
              const SizedBox(width: 10), // .hd-l gap
              ConnDot(status: status),
            ],
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: onVersionLongPress,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('P.A.I V${version.toUpperCase()}', style: _metaStyle),
                Text(userName.toUpperCase(), style: _metaStyle),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static final TextStyle _metaStyle = TextStyle(
    fontFamily: kDisplayFamily,
    fontSize: _metaSize,
    height: 1.5, // .meta line-height
    letterSpacing: MType.track(_metaSize, 0.3),
    color: M.chromeDim.withValues(alpha: 0.34),
    shadows: MType.engraved,
  );
}

/// 7x7 status dot. Steady when connected or offline; breathes (opacity 1 -> 0.4
/// -> 1 over 1.4s, easeInOut) only while RECONNECTING, so the movement is
/// informative rather than a constant idle distraction (app.css:298-322).
class ConnDot extends StatefulWidget {
  const ConnDot({super.key, required this.status});

  final ConnStatus status;

  @override
  State<ConnDot> createState() => _ConnDotState();
}

class _ConnDotState extends State<ConnDot> with SingleTickerProviderStateMixin {
  late final AnimationController _breathe = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700), // half of the 1.4s cycle
  );
  late final Animation<double> _opacity = Tween<double>(begin: 1.0, end: 0.4)
      .animate(CurvedAnimation(parent: _breathe, curve: Curves.easeInOut));

  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _sync();
  }

  @override
  void didUpdateWidget(ConnDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status != widget.status) _sync();
  }

  void _sync() {
    final shouldRun = !_reduceMotion && widget.status == ConnStatus.connecting;
    if (shouldRun && !_breathe.isAnimating) {
      _breathe.repeat(reverse: true);
    } else if (!shouldRun && _breathe.isAnimating) {
      _breathe.stop();
      _breathe.value = 0.0;
    }
  }

  @override
  void dispose() {
    _breathe.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = connDotColors(widget.status);
    final dot = Container(
      key: const ValueKey('conn-dot'),
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        color: c.fill,
        shape: BoxShape.circle,
        // box-shadow: 0 0 9px dot@75%. The CSS `inset 0 -1px 1px black@0.4` is
        // dropped — Flutter has no inset shadow and it is sub-pixel on a 7px dot.
        boxShadow: [
          BoxShadow(color: c.glow.withValues(alpha: 0.75), blurRadius: 9)
        ],
      ),
    );
    if (widget.status != ConnStatus.connecting || _reduceMotion) return dot;
    return FadeTransition(opacity: _opacity, child: dot);
  }
}
