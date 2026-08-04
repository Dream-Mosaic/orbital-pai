import 'package:flutter/material.dart';
import 'tokens.dart';

/// The PTT hold tray: an engraved slit and label. Ported from `#ptt-hold`,
/// `.slit` and `.plabel` in app.css. `enabled` mirrors the web's `disabled` attr
/// (PTT mode off/on); `held` mirrors the `.ptt-held` class the hook toggles while
/// the button is physically held.
class HoldToTalkBar extends StatelessWidget {
  const HoldToTalkBar({
    super.key,
    required this.enabled,
    required this.held,
    required this.onPress,
    required this.onRelease,
  });

  final bool enabled;
  final bool held;
  final VoidCallback onPress;
  final VoidCallback onRelease;

  static const double _labelSize = 8.32; // 0.52rem

  @override
  Widget build(BuildContext context) {
    final slitColour = !enabled
        ? const Color(0xFFFFFFFF).withValues(alpha: 0.14)
        : (held ? M.youSoft : M.you);
    final labelColour = !enabled
        ? M.chromeDim.withValues(alpha: 0.2)
        : (held ? M.youSoft : M.chromeDim.withValues(alpha: 0.38));

    return Listener(
      onPointerDown: enabled ? (_) => onPress() : null,
      onPointerUp: enabled ? (_) => onRelease() : null,
      // The web also releases on pointerleave; a cancelled pointer is the same
      // intent on a touch screen.
      onPointerCancel: enabled ? (_) => onRelease() : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: double.infinity,
        padding: const EdgeInsets.only(top: 9, bottom: 11),
        decoration: BoxDecoration(
          color: const Color(0xFFFFFFFF).withValues(alpha: 0.016),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: held
                ? M.you.withValues(alpha: 0.55)
                : const Color(0xFFFFFFFF).withValues(alpha: 0.055),
          ),
          boxShadow: [
            if (held)
              BoxShadow(
                color: M.you.withValues(alpha: 0.8),
                blurRadius: 20,
                spreadRadius: -4,
              ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FractionallySizedBox(
              widthFactor: 0.42, // .slit width
              child: Container(
                height: 2,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(2),
                  gradient: LinearGradient(
                    colors: [
                      slitColour.withValues(alpha: 0.0),
                      slitColour,
                      slitColour,
                      slitColour.withValues(alpha: 0.0),
                    ],
                    stops: const [0.0, 0.22, 0.78, 1.0],
                  ),
                  boxShadow: [
                    if (enabled)
                      BoxShadow(
                        color: M.you.withValues(alpha: held ? 0.85 : 0.65),
                        blurRadius: held ? 16 : 9,
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 7), // #ptt-hold gap
            Text(
              'HOLD TO TALK',
              style: TextStyle(
                fontFamily: kDisplayFamily,
                fontSize: _labelSize,
                fontWeight: FontWeight.w600,
                letterSpacing: MType.track(_labelSize, 0.4),
                color: labelColour,
                shadows: MType.engraved,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
