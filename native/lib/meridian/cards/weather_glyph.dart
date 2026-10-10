import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The weather glyph vocabulary `App.Cards.weather_icon/4` speaks. The server
/// sends the key; the client owns the drawing. Painted rather than looked up:
/// the bundled fonts carry no emoji and this build ships no icon font, and a
/// painted glyph stays crisp from the 16px hourly strip to the 36px headline.
enum WeatherKind { clear, clearNight, partly, partlyNight, cloudy, rain, storm, snow, fog, wind }

WeatherKind? weatherKindFor(String? key) => switch (key) {
      'clear' => WeatherKind.clear,
      'clear_night' => WeatherKind.clearNight,
      'partly' => WeatherKind.partly,
      'partly_night' => WeatherKind.partlyNight,
      'cloudy' => WeatherKind.cloudy,
      'rain' => WeatherKind.rain,
      'storm' => WeatherKind.storm,
      'snow' => WeatherKind.snow,
      'fog' => WeatherKind.fog,
      'wind' => WeatherKind.wind,
      _ => null,
    };

class WeatherGlyph extends StatelessWidget {
  const WeatherGlyph(this.icon, {super.key, this.size = 18});

  /// The server's icon key. Unknown or absent draws nothing — an empty slot
  /// is honest; a guessed sun is not.
  final String? icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final kind = weatherKindFor(icon);
    return SizedBox.square(
      dimension: size,
      child: kind == null ? null : CustomPaint(painter: WeatherGlyphPainter(kind)),
    );
  }
}

class WeatherGlyphPainter extends CustomPainter {
  WeatherGlyphPainter(this.kind);

  final WeatherKind kind;

  static const Color sun = Color(0xFFF7C66B);
  static const Color moon = Color(0xFFDDE3F4);
  static const Color cloudTop = Color(0xFFE3E8F3);
  static const Color cloudBottom = Color(0xFFB4BDD2);
  static const Color stormTop = Color(0xFFB9C1D4);
  static const Color stormBottom = Color(0xFF7F889F);
  static const Color rain = Color(0xFF5CC3F0);
  static const Color bolt = Color(0xFFF5C451);
  static const Color snow = Color(0xFFF0F4FF);
  static const Color mist = Color(0xFFAEB7CC);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    switch (kind) {
      case WeatherKind.clear:
        _sun(canvas, s, Offset(.5 * s, .5 * s), .2 * s, rays: true);
      case WeatherKind.clearNight:
        _moon(canvas, s, Offset(.5 * s, .5 * s), .3 * s);
      case WeatherKind.partly:
      case WeatherKind.partlyNight:
        // Behind-then-in-front, with a cut so the cloud reads as nearer.
        canvas.saveLayer(Offset.zero & size, Paint());
        if (kind == WeatherKind.partly) {
          _sun(canvas, s, Offset(.36 * s, .36 * s), .15 * s, rays: true, rayScale: .78);
        } else {
          _moon(canvas, s, Offset(.38 * s, .36 * s), .22 * s);
        }
        final cloud = _cloud(s, dx: .1, dy: .16, scale: .86);
        canvas.drawPath(
          cloud,
          Paint()
            ..blendMode = BlendMode.clear
            ..style = PaintingStyle.stroke
            ..strokeWidth = .09 * s,
        );
        _fillCloud(canvas, cloud, s, dark: false);
        canvas.restore();
      case WeatherKind.cloudy:
        _fillCloud(canvas, _cloud(s), s, dark: false);
      case WeatherKind.rain:
        _fillCloud(canvas, _cloud(s, dy: -.1), s, dark: true);
        final p = _stroke(rain, .07 * s);
        for (final x in [.36, .54, .72]) {
          canvas.drawLine(Offset(x * s, .76 * s), Offset((x - .06) * s, .92 * s), p);
        }
      case WeatherKind.storm:
        _fillCloud(canvas, _cloud(s, dy: -.12), s, dark: true);
        final b = Path()
          ..moveTo(.56 * s, .6 * s)
          ..lineTo(.4 * s, .8 * s)
          ..lineTo(.51 * s, .8 * s)
          ..lineTo(.44 * s, .97 * s)
          ..lineTo(.65 * s, .73 * s)
          ..lineTo(.54 * s, .73 * s)
          ..lineTo(.62 * s, .6 * s)
          ..close();
        canvas.drawPath(b, Paint()..color = bolt);
      case WeatherKind.snow:
        _fillCloud(canvas, _cloud(s, dy: -.1), s, dark: false);
        for (final (x, y) in [(.34, .84), (.53, .9), (.72, .84)]) {
          _flake(canvas, Offset(x * s, y * s), .065 * s, s);
        }
      case WeatherKind.fog:
        final p = _stroke(mist, .075 * s);
        canvas.drawLine(Offset(.24 * s, .36 * s), Offset(.76 * s, .36 * s), p);
        canvas.drawLine(Offset(.14 * s, .52 * s), Offset(.86 * s, .52 * s), p);
        canvas.drawLine(Offset(.2 * s, .68 * s), Offset(.62 * s, .68 * s), p);
        canvas.drawLine(Offset(.74 * s, .68 * s), Offset(.82 * s, .68 * s), p);
      case WeatherKind.wind:
        final p = _stroke(mist, .07 * s)..style = PaintingStyle.stroke;
        canvas.drawPath(
          Path()
            ..moveTo(.12 * s, .38 * s)
            ..lineTo(.6 * s, .38 * s)
            ..arcToPoint(Offset(.6 * s, .2 * s),
                radius: Radius.circular(.09 * s), clockwise: false)
            ..arcToPoint(Offset(.52 * s, .27 * s), radius: Radius.circular(.065 * s), clockwise: false),
          p,
        );
        canvas.drawPath(
          Path()
            ..moveTo(.12 * s, .54 * s)
            ..lineTo(.78 * s, .54 * s)
            ..arcToPoint(Offset(.78 * s, .36 * s),
                radius: Radius.circular(.09 * s), clockwise: false),
          p,
        );
        canvas.drawPath(
          Path()
            ..moveTo(.12 * s, .7 * s)
            ..lineTo(.56 * s, .7 * s)
            ..arcToPoint(Offset(.56 * s, .86 * s), radius: Radius.circular(.08 * s)),
          p,
        );
    }
  }

  Paint _stroke(Color c, double w) => Paint()
    ..color = c
    ..strokeWidth = w
    ..strokeCap = StrokeCap.round
    ..style = PaintingStyle.stroke;

  void _sun(Canvas canvas, double s, Offset c, double r,
      {bool rays = false, double rayScale = 1}) {
    canvas.drawCircle(
      c,
      r * 1.5,
      Paint()
        ..color = sun.withValues(alpha: .22)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * .55),
    );
    canvas.drawCircle(c, r, Paint()..color = sun);
    if (!rays) return;
    final p = _stroke(sun, math.max(1.0, .065 * s));
    for (var i = 0; i < 8; i++) {
      final a = i * math.pi / 4;
      final dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(c + dir * (r + .11 * s * rayScale), c + dir * (r + .2 * s * rayScale), p);
    }
  }

  void _moon(Canvas canvas, double s, Offset c, double r) {
    final crescent = Path.combine(
      PathOperation.difference,
      Path()..addOval(Rect.fromCircle(center: c, radius: r)),
      Path()..addOval(Rect.fromCircle(center: c + Offset(r * .55, -r * .4), radius: r * .86)),
    );
    canvas.drawPath(
      crescent,
      Paint()
        ..color = moon.withValues(alpha: .25)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * .3),
    );
    canvas.drawPath(crescent, Paint()..color = moon);
  }

  /// A cumulus silhouette in the unit box, optionally shifted and scaled.
  Path _cloud(double s, {double dx = 0, double dy = 0, double scale = 1}) {
    Offset at(double x, double y) =>
        Offset((dx + .5 + (x - .5) * scale) * s, (dy + .5 + (y - .5) * scale) * s);
    double r(double v) => v * scale * s;

    var path = Path()
      ..addRRect(RRect.fromRectAndRadius(
        Rect.fromPoints(at(.13, .5), at(.89, .8)),
        Radius.circular(r(.15)),
      ));
    for (final (c, rad) in [
      (at(.34, .55), .17),
      (at(.55, .44), .22),
      (at(.73, .57), .15),
    ]) {
      path = Path.combine(
        PathOperation.union,
        path,
        Path()..addOval(Rect.fromCircle(center: c, radius: r(rad))),
      );
    }
    return path;
  }

  void _fillCloud(Canvas canvas, Path cloud, double s, {required bool dark}) {
    final b = cloud.getBounds();
    canvas.drawPath(
      cloud,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: dark ? const [stormTop, stormBottom] : const [cloudTop, cloudBottom],
        ).createShader(b),
    );
  }

  void _flake(Canvas canvas, Offset c, double r, double s) {
    final p = _stroke(snow, math.max(.8, .035 * s));
    for (var i = 0; i < 3; i++) {
      final a = i * math.pi / 3 + math.pi / 2;
      final d = Offset(math.cos(a), math.sin(a)) * r;
      canvas.drawLine(c - d, c + d, p);
    }
  }

  @override
  bool shouldRepaint(WeatherGlyphPainter old) => old.kind != kind;
}
