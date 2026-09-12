import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/auth/device_id.dart';

/// An in-memory [DeviceIdStore] that genuinely counts writes, so a bug that
/// writes on every read (not just the first) can actually fail the tests
/// that assert against [writes].
class FakeDeviceIdStore implements DeviceIdStore {
  String? _value;
  int writes = 0;

  @override
  Future<String?> read() async => _value;

  @override
  Future<void> write(String value) async {
    _value = value;
    writes++;
  }
}

/// A [DeviceIdStore] whose every method throws, standing in for a keystore
/// that cannot be reached (locked profile, corrupted keystore, OEM
/// lockdown). [DeviceId.get] must degrade to an in-memory id against this
/// rather than let the exception reach its caller.
class ThrowingDeviceIdStore implements DeviceIdStore {
  @override
  Future<String?> read() => throw StateError('keystore unavailable');

  @override
  Future<void> write(String value) => throw StateError('keystore unavailable');
}

void main() {
  group('DeviceId', () {
    test('generates once and is stable across calls', () async {
      final store = FakeDeviceIdStore();
      final d = DeviceId(store: store);
      final a = await d.get();
      final b = await d.get();
      expect(a, isNotEmpty);
      expect(b, a);
      expect(store.writes, 1, reason: 'must persist exactly once, not on every read');
    });

    test('a fresh instance reads the persisted value rather than regenerating', () async {
      final store = FakeDeviceIdStore();
      final first = await DeviceId(store: store).get();
      final second = await DeviceId(store: store).get();
      expect(second, first);
    });

    test('a store that throws still yields a usable id', () async {
      final d = DeviceId(store: ThrowingDeviceIdStore());
      final id = await d.get();
      expect(id, isNotEmpty,
          reason: 'secure storage can fail; a device with no id must still connect');
    });
  });
}
