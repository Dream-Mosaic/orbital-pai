import 'dart:async';
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/device/device_role.dart';

/// A store whose read throws, as a corrupt file does.
class _ThrowingStore implements DeviceStore {
  @override
  Future<Map<String, Object?>?> read() async => throw const FormatException('corrupt');
  @override
  Future<void> write(Map<String, Object?> json) async {}
}

/// A store whose write fails, as a full disk does.
class _FailingWriteStore extends MemoryDeviceStore {
  @override
  Future<void> write(Map<String, Object?> json) async => throw const FileSystemLike();
}

class FileSystemLike implements Exception {
  const FileSystemLike();
}

const _phone = Size(360, 800);
const _lenovoPortrait = Size(711, 1191);
const _lenovoLandscape = Size(1191, 711);

void main() {
  group('defaultRoleFor', () {
    test('a phone is personal', () {
      expect(defaultRoleFor(_phone), DeviceRole.personal);
    });

    test('the Lenovo is a wall in either orientation', () {
      expect(defaultRoleFor(_lenovoPortrait), DeviceRole.wall);
      expect(defaultRoleFor(_lenovoLandscape), DeviceRole.wall);
    });
  });

  group('DeviceSettings.fromJson', () {
    test('round-trips', () {
      const s = DeviceSettings(role: DeviceRole.wall, dimAtNight: false);
      expect(DeviceSettings.fromJson(s.toJson(), fallbackRole: DeviceRole.personal), s);
    });

    test('round-trips the shared choice', () {
      const s = DeviceSettings(role: DeviceRole.wall, shared: false);
      final back = DeviceSettings.fromJson(s.toJson(), fallbackRole: DeviceRole.personal);
      expect(back, s);
      expect(back.shared, isFalse);
    });

    test('a device.json from before shared existed: a wall is shared', () {
      // Phase 1 wrote only role and dim_at_night.
      final wall = DeviceSettings.fromJson(const {'role': 'wall', 'dim_at_night': false},
          fallbackRole: DeviceRole.personal);
      expect(wall.shared, isTrue, reason: 'shared is on by default for a wall');
      expect(wall.dimAtNight, isFalse);

      final phone = DeviceSettings.fromJson(const {'role': 'personal'},
          fallbackRole: DeviceRole.wall);
      expect(phone.shared, isFalse);
    });

    test('a personal device is never shared, whatever was stored', () {
      final s = DeviceSettings.fromJson(const {'role': 'personal', 'shared': true},
          fallbackRole: DeviceRole.wall);
      expect(s.shared, isFalse);
      expect(const DeviceSettings(role: DeviceRole.personal, shared: true).shared, isFalse);
    });

    test('a personal device keeps the stored choice, so going back to wall restores it', () {
      const wall = DeviceSettings(role: DeviceRole.wall, shared: false);
      final personal = wall.copyWith(role: DeviceRole.personal);
      expect(personal.toJson()['shared'], isFalse, reason: 'stored as chosen');
      expect(personal.copyWith(role: DeviceRole.wall).shared, isFalse);

      final reread = DeviceSettings.fromJson(personal.toJson(), fallbackRole: DeviceRole.wall);
      expect(reread.copyWith(role: DeviceRole.wall).shared, isFalse);
    });

    test('a non-bool shared falls back to on', () {
      final s = DeviceSettings.fromJson(const {'role': 'wall', 'shared': 'yes'},
          fallbackRole: DeviceRole.personal);
      expect(s.shared, isTrue);
    });

    test('unknown or missing keys fall back to defaults', () {
      final s = DeviceSettings.fromJson(const {'role': 'toaster', 'dim_at_night': 'yes'},
          fallbackRole: DeviceRole.wall);
      expect(s.role, DeviceRole.wall);
      expect(s.dimAtNight, isTrue);

      final empty = DeviceSettings.fromJson(const {}, fallbackRole: DeviceRole.personal);
      expect(empty,
          const DeviceSettings(role: DeviceRole.personal, dimAtNight: true, shared: true));
    });
  });

  group('DeviceController.load', () {
    test('with nothing stored, the default comes from the screen size', () async {
      final phone = await DeviceController.load(store: MemoryDeviceStore(), logicalSize: _phone);
      expect(phone.isWall, isFalse);
      expect(phone.settings.dimAtNight, isTrue);

      final tablet =
          await DeviceController.load(store: MemoryDeviceStore(), logicalSize: _lenovoPortrait);
      expect(tablet.isWall, isTrue);

      final rotated =
          await DeviceController.load(store: MemoryDeviceStore(), logicalSize: _lenovoLandscape);
      expect(rotated.isWall, isTrue);
    });

    test('a stored choice beats the size default', () async {
      final store = MemoryDeviceStore({'role': 'personal', 'dim_at_night': false});
      final c = await DeviceController.load(store: store, logicalSize: _lenovoPortrait);
      expect(c.isWall, isFalse);
      expect(c.settings.dimAtNight, isFalse);

      final phone = await DeviceController.load(
          store: MemoryDeviceStore({'role': 'wall'}), logicalSize: _phone);
      expect(phone.isWall, isTrue);
    });

    test('a read that throws (corrupt file) falls back to defaults, never throws', () async {
      final c = await DeviceController.load(store: _ThrowingStore(), logicalSize: _lenovoPortrait);
      expect(c.settings, const DeviceSettings(role: DeviceRole.wall));
    });

    test('a read that never answers falls back to defaults after the bound', () async {
      final c = await DeviceController.load(
        store: _NeverStore(),
        logicalSize: _lenovoPortrait,
        readTimeout: const Duration(milliseconds: 20),
      );
      expect(c.isWall, isTrue);
    });
  });

  group('DeviceController changes', () {
    test('setWall persists and notifies', () async {
      final store = MemoryDeviceStore();
      final c = await DeviceController.load(store: store, logicalSize: _phone);
      var notified = 0;
      c.addListener(() => notified++);

      await c.setWall(true);

      expect(c.isWall, isTrue);
      expect(notified, 1);
      expect(store.stored, {'role': 'wall', 'dim_at_night': true, 'shared': true});

      // And a reload reads it back.
      final again = await DeviceController.load(store: store, logicalSize: _phone);
      expect(again.isWall, isTrue);
    });

    test('setDimAtNight persists and notifies', () async {
      final store = MemoryDeviceStore();
      final c = await DeviceController.load(store: store, logicalSize: _lenovoPortrait);
      var notified = 0;
      c.addListener(() => notified++);

      await c.setDimAtNight(false);

      expect(c.settings.dimAtNight, isFalse);
      expect(notified, 1);
      expect(store.stored, {'role': 'wall', 'dim_at_night': false, 'shared': true});
    });

    test('a wall is shared by default; a phone never is', () async {
      final wall =
          await DeviceController.load(store: MemoryDeviceStore(), logicalSize: _lenovoPortrait);
      expect(wall.isShared, isTrue);

      final phone = await DeviceController.load(store: MemoryDeviceStore(), logicalSize: _phone);
      expect(phone.isShared, isFalse);

      final old = await DeviceController.load(
          store: MemoryDeviceStore({'role': 'wall', 'dim_at_night': true}), logicalSize: _phone);
      expect(old.isShared, isTrue, reason: 'a phase-1 device.json, without the key');
    });

    test('setShared persists and notifies', () async {
      final store = MemoryDeviceStore();
      final c = await DeviceController.load(store: store, logicalSize: _lenovoPortrait);
      var notified = 0;
      c.addListener(() => notified++);

      await c.setShared(false);

      expect(c.isShared, isFalse);
      expect(notified, 1);
      expect(store.stored, {'role': 'wall', 'dim_at_night': true, 'shared': false});

      final again = await DeviceController.load(store: store, logicalSize: _phone);
      expect(again.isShared, isFalse);
    });

    test('a personal device never reports shared, even when told to be', () async {
      final store = MemoryDeviceStore({'role': 'personal', 'shared': true});
      final c = await DeviceController.load(store: store, logicalSize: _lenovoPortrait);
      expect(c.isShared, isFalse, reason: 'the stored value says shared; the role says no');

      await c.setShared(true);
      expect(c.isShared, isFalse);

      await c.setWall(true);
      expect(c.isShared, isTrue, reason: 'a wall again: the stored choice comes back');
      await c.setWall(false);
      expect(c.isShared, isFalse);
    });

    test('a no-op change neither notifies nor writes', () async {
      final store = MemoryDeviceStore();
      final c = await DeviceController.load(store: store, logicalSize: _lenovoPortrait);
      var notified = 0;
      c.addListener(() => notified++);

      await c.setWall(true);
      await c.setDimAtNight(true);
      await c.setShared(true);

      expect(notified, 0);
      expect(store.writes, 0);
    });

    test('a failed write still applies the change for this launch', () async {
      final c = await DeviceController.load(store: _FailingWriteStore(), logicalSize: _phone);
      await c.setWall(true);
      expect(c.isWall, isTrue);
    });

    test('a fixed controller changes without a store', () async {
      final c = DeviceController.fixed(const DeviceSettings(role: DeviceRole.personal));
      await c.setWall(true);
      expect(c.isWall, isTrue);
    });
  });
}

class _NeverStore implements DeviceStore {
  final Completer<Map<String, Object?>?> _never = Completer();
  @override
  Future<Map<String, Object?>?> read() => _never.future;
  @override
  Future<void> write(Map<String, Object?> json) async {}
}
