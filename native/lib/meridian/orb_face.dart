import 'dart:async';

import 'package:flutter/material.dart';

import '../voice/glance.dart';
import 'tokens.dart';

/// The orb at rest: a quiet clock face in the glass.
///
/// The orb is the biggest thing on the screen and, between conversations, it
/// used to be empty glass. Now it tells the time, the weather and what's next —
/// the at-a-glance read a wall tablet or a phone on the counter should give
/// without anyone saying a word. It yields the instant there is something
/// better to show: your live words (the caption) or Henry's voice (the line).
///
/// Laid out inside the same inscribed box the caption uses, so it can never
/// spill over the glass edge. Every size derives from that box.
class OrbFace extends StatefulWidget {
  const OrbFace({
    super.key,
    required this.width,
    required this.height,
    this.glance = Glance.empty,
    this.hint = '',
    this.glyph,
    this.dimmed = false,
    this.clock = DateTime.now,
  });

  final double width;
  final double height;
  final Glance glance;

  /// The resting prompt ("Say “Henry”") on a wake-locked device; '' otherwise.
  final String hint;

  /// Paints the weather glyph for an icon key, or null for none.
  final Widget Function(String icon, double size, Color color)? glyph;

  /// Powered off: the face stays, but recedes.
  final bool dimmed;

  /// Injectable for tests.
  final DateTime Function() clock;

  @override
  State<OrbFace> createState() => _OrbFaceState();
}

class _OrbFaceState extends State<OrbFace> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  // Re-render on the minute boundary, not every second: the face shows no
  // seconds, and a once-a-minute rebuild is free.
  void _schedule() {
    final now = widget.clock();
    final untilNext =
        Duration(seconds: 60 - now.second, milliseconds: -now.millisecond);
    _tick = Timer(untilNext.isNegative ? const Duration(seconds: 1) : untilNext,
        () {
      if (!mounted) return;
      setState(() {});
      _schedule();
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  static const _days = [
    'MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY', 'FRIDAY', 'SATURDAY',
    'SUNDAY' //
  ];
  static const _months = [
    'JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV',
    'DEC' //
  ];

  @override
  Widget build(BuildContext context) {
    final now = widget.clock();
    final use24 = MediaQuery.maybeAlwaysUse24HourFormatOf(context) ?? false;
    final h = use24 ? now.hour : (now.hour % 12 == 0 ? 12 : now.hour % 12);
    final time =
        '${use24 ? h.toString().padLeft(2, '0') : h}:${now.minute.toString().padLeft(2, '0')}';
    final meridiem = use24 ? '' : (now.hour < 12 ? 'AM' : 'PM');
    final date =
        '${_days[now.weekday - 1]} · ${_months[now.month - 1]} ${now.day}';

    final w = widget.width;
    final timeSize = (w * 0.30).clamp(28.0, 64.0);
    final small = (w * 0.058).clamp(8.0, 11.0);
    final body = (w * 0.068).clamp(10.0, 13.5);
    final fade = widget.dimmed ? 0.45 : 1.0;

    final weather = widget.glance.weather;
    final next = widget.glance.next;

    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: Opacity(
        opacity: fade,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: SizedBox(
            width: widget.width,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  date,
                  key: const ValueKey('face-date'),
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  softWrap: false,
                  style: TextStyle(
                    fontFamily: kDisplayFamily,
                    fontSize: small,
                    fontWeight: FontWeight.w600,
                    fontVariations: MType.wght(600),
                    letterSpacing: MType.track(small, 0.32),
                    color: M.chromeDim.withValues(alpha: 0.5),
                    shadows: MType.engraved,
                  ),
                ),
                SizedBox(height: timeSize * 0.06),
                // Scales down rather than overflowing a narrow glass (or a
                // wide fallback font): the clock is the one row that may
                // never ellipsize.
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        time,
                        key: const ValueKey('face-time'),
                        style: TextStyle(
                          fontFamily: kDisplayFamily,
                          fontSize: timeSize,
                          height: 1.0,
                          fontWeight: FontWeight.w300,
                          fontVariations: MType.wght(320),
                          letterSpacing: -timeSize * 0.02,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: M.chrome.withValues(alpha: 0.88),
                          shadows: [
                            Shadow(
                                color: M.chrome.withValues(alpha: 0.18),
                                blurRadius: 18),
                          ],
                        ),
                      ),
                      if (meridiem.isNotEmpty) ...[
                        SizedBox(width: timeSize * 0.07),
                        Text(
                          meridiem,
                          style: TextStyle(
                            fontFamily: kDisplayFamily,
                            fontSize: small,
                            fontWeight: FontWeight.w600,
                            fontVariations: MType.wght(600),
                            letterSpacing: MType.track(small, 0.2),
                            color: M.chromeDim.withValues(alpha: 0.55),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (weather != null) ...[
                  SizedBox(height: timeSize * 0.16),
                  Row(
                    key: const ValueKey('face-weather'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.glyph != null && weather.icon.isNotEmpty) ...[
                        widget.glyph!(weather.icon, body * 1.35,
                            M.ink.withValues(alpha: 0.75)),
                        SizedBox(width: body * 0.45),
                      ],
                      Text(
                        weather.temp,
                        style: TextStyle(
                          fontFamily: kDisplayFamily,
                          fontSize: body * 1.05,
                          fontWeight: FontWeight.w500,
                          fontVariations: MType.wght(500),
                          color: M.ink.withValues(alpha: 0.82),
                        ),
                      ),
                      if (weather.condition.isNotEmpty) ...[
                        SizedBox(width: body * 0.45),
                        Flexible(
                          child: Text(
                            weather.condition,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: kBodyFamily,
                              fontSize: body,
                              color: M.inkDim.withValues(alpha: 0.85),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
                if (next != null) ...[
                  SizedBox(height: body * 0.5),
                  Row(
                    key: const ValueKey('face-next'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 5,
                        height: 5,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: M.henry.withValues(alpha: 0.85),
                          boxShadow: [
                            BoxShadow(
                                color: M.henry.withValues(alpha: 0.6),
                                blurRadius: 6),
                          ],
                        ),
                      ),
                      SizedBox(width: body * 0.5),
                      Text(
                        next.day.isEmpty || next.day == 'Today'
                            ? next.time
                            : '${next.day} ${next.time}',
                        style: TextStyle(
                          fontFamily: kBodyFamily,
                          fontSize: body * 0.92,
                          fontWeight: FontWeight.w600,
                          color: M.henry.withValues(alpha: 0.85),
                        ),
                      ),
                      SizedBox(width: body * 0.45),
                      Flexible(
                        child: Text(
                          next.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: kBodyFamily,
                            fontSize: body * 0.92,
                            color: M.ink.withValues(alpha: 0.7),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                if (widget.hint.isNotEmpty) ...[
                  SizedBox(height: timeSize * 0.2),
                  Text(
                    widget.hint,
                    key: const ValueKey('face-hint'),
                    style: TextStyle(
                      fontFamily: kBodyFamily,
                      fontSize: body,
                      fontStyle: FontStyle.italic,
                      color: M.chromeDim.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
