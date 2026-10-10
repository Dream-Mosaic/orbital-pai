import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/meridian/orb_face.dart';
import 'package:orbital_pai/voice/glance.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final display = FontLoader('Space Grotesk')
      ..addFont(rootBundle.load('assets/fonts/SpaceGrotesk.ttf'));
    final body = FontLoader('Inter')..addFont(rootBundle.load('assets/fonts/Inter.ttf'));
    await Future.wait([display.load(), body.load()]);
  });

  group('Glance.fromJson', () {
    test('parses both halves', () {
      final g = Glance.fromJson(const {
        'weather': {'temp': '64°', 'condition': 'Partly cloudy', 'icon': 'partly-day'},
        'next_event': {'title': 'Dinner with Mom', 'time': '7:30 PM', 'day': 'Today'},
      });
      expect(g.weather!.temp, '64°');
      expect(g.weather!.icon, 'partly-day');
      expect(g.next!.title, 'Dinner with Mom');
      expect(g.next!.day, 'Today');
    });

    test('a malformed half is dropped, never thrown', () {
      final g = Glance.fromJson(const {
        'weather': {'temp': 64},
        'next_event': 'nope',
      });
      expect(g.isEmpty, isTrue);
      expect(Glance.fromJson(const {}).isEmpty, isTrue);
    });
  });

  Widget host(Widget child) => MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFF05070C),
          body: Center(child: child),
        ),
      );

  testWidgets('shows the injected time, date, weather, next event and hint', (tester) async {
    await tester.pumpWidget(host(OrbFace(
      width: 220,
      height: 180,
      clock: () => DateTime(2026, 10, 9, 21, 4),
      glance: const Glance(
        weather: GlanceWeather(temp: '64°', condition: 'Partly cloudy', icon: 'partly-night'),
        next: GlanceEvent(title: 'Dentist', time: '9:00 AM', day: 'Tomorrow'),
      ),
      hint: 'Say “Henry”',
    )));

    expect(find.text('9:04'), findsOneWidget);
    expect(find.text('PM'), findsOneWidget);
    expect(find.text('FRIDAY · OCT 9'), findsOneWidget);
    expect(find.text('64°'), findsOneWidget);
    expect(find.text('Partly cloudy'), findsOneWidget);
    expect(find.text('Tomorrow 9:00 AM'), findsOneWidget);
    expect(find.text('Dentist'), findsOneWidget);
    expect(find.text('Say “Henry”'), findsOneWidget);
  });

  testWidgets('an event that has already started is not "next"', (tester) async {
    final glance = Glance.fromJson(const {
      'next_event': {
        'title': 'Standup',
        'time': '9:00 AM',
        'day': 'Today',
        'at': '2026-10-10T14:00:00Z',
      },
    });
    await tester.pumpWidget(host(OrbFace(
      width: 220,
      height: 180,
      clock: () => DateTime.utc(2026, 10, 10, 13, 55),
      glance: glance,
    )));
    expect(find.text('Standup'), findsOneWidget);

    await tester.pumpWidget(host(OrbFace(
      width: 220,
      height: 180,
      clock: () => DateTime.utc(2026, 10, 10, 14, 1),
      glance: glance,
    )));
    expect(find.text('Standup'), findsNothing);
  });

  testWidgets('with no glance it is just the clock — no empty rows', (tester) async {
    await tester.pumpWidget(host(OrbFace(
      width: 220,
      height: 180,
      clock: () => DateTime(2026, 10, 10, 9, 30),
    )));
    expect(find.text('9:30'), findsOneWidget);
    expect(find.byKey(const ValueKey('face-weather')), findsNothing);
    expect(find.byKey(const ValueKey('face-next')), findsNothing);
    expect(find.byKey(const ValueKey('face-hint')), findsNothing);
  });

  testWidgets('golden: the face in an orb-sized box', (tester) async {
    await tester.binding.setSurfaceSize(const Size(300, 260));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(host(RepaintBoundary(
      key: const ValueKey('shot'),
      child: Container(
        width: 260,
        height: 220,
        alignment: Alignment.center,
        decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF1A1F2A)),
        child: OrbFace(
          width: 190,
          height: 150,
          clock: () => DateTime(2026, 10, 10, 18, 42),
          glance: const Glance(
            weather: GlanceWeather(temp: '64°', condition: 'Partly cloudy', icon: 'partly-night'),
            next: GlanceEvent(title: 'Dinner with Mom', time: '7:30 PM', day: 'Today'),
          ),
        ),
      ),
    )));
    await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('goldens/orb_face.png'));
  });
}
