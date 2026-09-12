import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A stable id for this device, used so the server can tell two of a user's
/// devices apart (conversation handoff — see the design doc). Persisted so
/// it survives restarts; generated once, then read back on every later call.
///
/// Backed by the platform keystore, injectable for tests. There is exactly
/// one device id — this app has no concept of multiple profiles per device —
/// so there is no key parameter to get wrong.
abstract interface class DeviceIdStore {
  Future<String?> read();
  Future<void> write(String value);
}

/// [DeviceIdStore] backed by [FlutterSecureStorage], in the same style as
/// [TokenStore] in `token_store.dart`.
class SecureDeviceIdStore implements DeviceIdStore {
  SecureDeviceIdStore({FlutterSecureStorage? storage})
      : _s = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _s;

  static const _key = 'orbital.device_id';

  @override
  Future<String?> read() => _s.read(key: _key);

  @override
  Future<void> write(String value) => _s.write(key: _key, value: value);
}

/// Generates and caches a stable per-device id.
///
/// A device whose keystore cannot be reached (corrupted keystore, locked
/// profile, OEM lockdown) must still be able to connect — same philosophy as
/// [TokenStore.read] degrading to "signed out" rather than crashing on
/// launch. Here, a store failure degrades to an in-memory id that lives for
/// the process lifetime: unstable across restarts, but never fatal, and
/// strictly better than failing to connect at all.
class DeviceId {
  DeviceId({DeviceIdStore? store}) : _store = store ?? SecureDeviceIdStore();

  final DeviceIdStore _store;

  String? _cached;

  // The in-flight resolution, cached (not just the resolved value) so that
  // concurrent callers before the first result lands all await the SAME
  // future rather than each racing their own read-generate-write sequence.
  // Without this, `Future.wait([d.get(), d.get()])` on a fresh instance can
  // have both calls see nothing persisted, both generate a different id, and
  // both write — the loser then caches and returns an id that isn't the one
  // actually persisted, so the device's id would drift across a restart.
  Future<String>? _inflight;

  /// The device id: read from storage if already persisted, else generated
  /// and persisted on first call. Stable across calls on this instance, and
  /// (storage permitting) across fresh instances and app restarts too.
  Future<String> get() {
    final cached = _cached;
    if (cached != null) return Future.value(cached);
    return _inflight ??= _resolve();
  }

  Future<String> _resolve() async {
    String? generated;
    try {
      final existing = await _store.read();
      if (existing != null && existing.isNotEmpty) {
        _cached = existing;
        return existing;
      }

      generated = _generate();
      await _store.write(generated);
      _cached = generated;
      return generated;
    } catch (_) {
      final fallback = generated ?? _generate();
      _cached = fallback;
      return fallback;
    } finally {
      _inflight = null;
    }
  }

  static String _generate() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static final Random _random = Random.secure();
}
