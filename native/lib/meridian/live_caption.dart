import 'package:flutter/material.dart';
import 'tokens.dart';

/// Your live speech, over the orb. Ported from `#orb-caption` in app.css and
/// `setCaption()` in index.js — **with the overflow fixed**.
///
/// The web sets an inline font-size from a three-step length ladder
/// (index.js:485) and nothing else, so a long partial transcript spills out of
/// the ring and over the detents. Here the ladder is only the STARTING size: the
/// text is then measured against a real box and stepped down 1px at a time until
/// it fits, floored at 11px with an ellipsis. It never scales UP, so a short
/// caption keeps its 25.6px hero size exactly as the web does.
class LiveCaption extends StatelessWidget {
  const LiveCaption({
    super.key,
    required this.text,
    required this.width,
    required this.height,
  });

  final String text;
  final double width;
  final double height;

  static const double _lineHeight = 1.22;
  static const double _minFontSize = 11.0;

  /// index.js:485 — `len > 80 ? 0.95 : len > 40 ? 1.2 : 1.6` rem.
  static double startFontSize(int length) =>
      length > 80 ? 15.2 : (length > 40 ? 19.2 : 25.6);

  static TextStyle _style(double size) => TextStyle(
        fontFamily: kBodyFamily,
        fontSize: size,
        height: _lineHeight,
        fontWeight: FontWeight.w500,
        color: M.youSoft,
        shadows: [
          Shadow(color: M.you.withValues(alpha: 0.4), blurRadius: 16),
          const Shadow(offset: Offset(0, 1), blurRadius: 3, color: Color(0xB3000000)),
        ],
      );

  /// Largest size <= [start] whose laid-out height fits [maxHeight] at [maxWidth].
  static double fitFontSize(
    String text,
    double maxWidth,
    double maxHeight, {
    double? start,
  }) {
    final s0 = start ?? startFontSize(text.length);
    if (text.isEmpty || maxWidth <= 0 || maxHeight <= 0) return s0;
    for (var size = s0; size >= _minFontSize; size -= 1.0) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: _style(size)),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      )..layout(maxWidth: maxWidth);
      if (painter.height <= maxHeight) return size;
    }
    return _minFontSize;
  }

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return SizedBox(width: width, height: height);
    final size = fitFontSize(text, width, height);
    final maxLines = (height / (size * _lineHeight)).floor().clamp(1, 99);
    return SizedBox(
      width: width,
      height: height,
      child: Text(
        text,
        textAlign: TextAlign.center,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: _style(size),
      ),
    );
  }
}
