import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/device/device_role.dart';
import 'package:orbital_pai/device/night_dim.dart';

const _wall = DeviceSettings(role: DeviceRole.wall);
const _rested = Duration(minutes: 5);

DateTime _at(int hour, int minute) => DateTime(2026, 10, 23, hour, minute);

void main() {
  test('the night window is 22:00 up to (not including) 07:00', () {
    expect(shouldDim(localNow: _at(21, 59), atRest: _rested, settings: _wall), isFalse);
    expect(shouldDim(localNow: _at(22, 0), atRest: _rested, settings: _wall), isTrue);
    expect(shouldDim(localNow: _at(0, 30), atRest: _rested, settings: _wall), isTrue);
    expect(shouldDim(localNow: _at(6, 59), atRest: _rested, settings: _wall), isTrue);
    expect(shouldDim(localNow: _at(7, 0), atRest: _rested, settings: _wall), isFalse);
    expect(shouldDim(localNow: _at(13, 0), atRest: _rested, settings: _wall), isFalse);
  });

  test('it takes a full 60 s at rest', () {
    final night = _at(23, 0);
    expect(shouldDim(localNow: night, atRest: const Duration(seconds: 59), settings: _wall),
        isFalse);
    expect(shouldDim(localNow: night, atRest: const Duration(seconds: 60), settings: _wall),
        isTrue);
  });

  test('a personal device never dims', () {
    const personal = DeviceSettings(role: DeviceRole.personal);
    expect(shouldDim(localNow: _at(23, 0), atRest: _rested, settings: personal), isFalse);
  });

  test('a wall with dim-at-night off never dims', () {
    const off = DeviceSettings(role: DeviceRole.wall, dimAtNight: false);
    expect(shouldDim(localNow: _at(23, 0), atRest: _rested, settings: off), isFalse);
  });
}
