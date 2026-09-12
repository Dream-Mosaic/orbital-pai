import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/auth/device_id.dart';

/// An in-memory [DeviceIdStore] that genuinely counts writes, so a bug that
/// writes on every read (not just the first) can actually fail the tests
/// that assert against [writes].
///
/// [read] resolves on a later microtask turn rather than synchronously or via
/// a [Timer]. That matters: a `Future.delayed(Duration.zero)` read gets
/// serialized by the event loop (each delayed read's Timer fires only after
/// the previous caller's entire continuation — including its write — has
/// drained), which would make several concurrent [DeviceId.get] calls appear
/// safe even without a race guard. Resolving via [scheduleMicrotask] instead
/// lets every concurrent caller's read reflect the store's state at the
/// moment each of them actually called it, exposing the real race.
class FakeDeviceIdStore implements DeviceIdStore {
  String? _value;
  int writes = 0;
  final List<Completer<String?>> _pendingReads = [];

  @override
  Future<String?> read() {
    final completer = Completer<String?>();
    _pendingReads.add(completer);
    scheduleMicrotask(() {
      if (_pendingReads.remove(completer)) {
        completer.complete(_value);
      }
    });
    return completer.future;
  }

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

/// A store whose [read] succeeds (finding nothing persisted yet) but whose
/// [write] throws — e.g. a keystore that can be queried but has gone
/// read-only. Pins that [DeviceId.get] still returns the id it generated
/// (in memory, unpersisted) rather than losing it in the catch block.
class WriteThrowingDeviceIdStore implements DeviceIdStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) => throw StateError('keystore read-only');
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

    test('concurrent first calls generate and persist exactly one id', () async {
      final store = FakeDeviceIdStore();
      final d = DeviceId(store: store);
      final ids = await Future.wait([d.get(), d.get(), d.get()]);
      expect(ids.toSet(), hasLength(1), reason: 'all callers must see the same id');
      expect(store.writes, 1, reason: 'a concurrent call must not generate a second id');
    });

    test('a store whose write throws still yields a stable usable id', () async {
      final d = DeviceId(store: WriteThrowingDeviceIdStore());
      final a = await d.get();
      final b = await d.get();
      expect(a, isNotEmpty);
      expect(b, a, reason: 'the generated id must survive a write failure, not be lost');
    });
  });
}
